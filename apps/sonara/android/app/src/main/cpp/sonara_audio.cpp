#include <oboe/Oboe.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace {
// These describe Sonara's negotiated wire format, not the Android device.
// Oboe selects the platform output rate and the callback resamples into it.
constexpr int32_t kSourceSampleRate = 48000;
constexpr int32_t kSourceChannels = 2;
constexpr size_t kCapacityFrames = kSourceSampleRate;

class Output final : public oboe::AudioStreamDataCallback,
                     public oboe::AudioStreamErrorCallback {
 public:
  int start(const int16_t* initial_samples, int32_t initial_frames,
            int32_t target_frames) {
    std::scoped_lock lock(lifecycle_mutex_);
    stop_locked();
    read_.store(0, std::memory_order_relaxed);
    write_.store(0, std::memory_order_relaxed);
    underruns_.store(0, std::memory_order_relaxed);
    dropped_.store(0, std::memory_order_relaxed);
    silence_frames_.store(0, std::memory_order_relaxed);
    rendered_.store(0, std::memory_order_relaxed);
    disconnected_.store(false, std::memory_order_relaxed);
    correction_ppm_.store(0.0, std::memory_order_relaxed);
    read_phase_ = 0.0;
    filtered_error_ = 0.0;
    integral_error_ = 0.0;
    controller_frames_ = 0;
    const auto base_target =
        std::clamp<int32_t>(target_frames, 120,
                            static_cast<int32_t>(kCapacityFrames / 2));
    base_target_frames_.store(base_target, std::memory_order_relaxed);
    target_frames_.store(base_target, std::memory_order_relaxed);
    max_target_frames_.store(
        std::min<int32_t>(base_target * 3,
                          static_cast<int32_t>(kCapacityFrames / 2)),
        std::memory_order_relaxed);
    rebuffering_.store(false, std::memory_order_relaxed);
    rebuffer_events_.store(0, std::memory_order_relaxed);
    stable_frames_ = 0;
    buffer_.assign(kCapacityFrames * kSourceChannels, 0);
    if (initial_samples != nullptr && initial_frames > 0) {
      const auto initial = std::min<size_t>(
          static_cast<size_t>(initial_frames), kCapacityFrames);
      std::copy_n(initial_samples, initial * kSourceChannels, buffer_.data());
      write_.store(initial, std::memory_order_relaxed);
    }

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output)
        ->setFormat(oboe::AudioFormat::I16)
        ->setChannelCount(kSourceChannels)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(oboe::SharingMode::Exclusive)
        ->setUsage(oboe::Usage::Media)
        ->setContentType(oboe::ContentType::Music)
        ->setDataCallback(this)
        ->setErrorCallback(this);
    auto result = builder.openStream(stream_);
    if (result != oboe::Result::OK) return static_cast<int>(result);
    output_sample_rate_.store(stream_->getSampleRate());
    output_channels_.store(stream_->getChannelCount());
    frames_per_burst_.store(stream_->getFramesPerBurst());
    const auto frames_per_burst = stream_->getFramesPerBurst();
    if (frames_per_burst > 0) {
      stream_->setBufferSizeInFrames(frames_per_burst * 2);
    }
    output_device_id_.store(stream_->getDeviceId());
    performance_mode_.store(static_cast<int32_t>(stream_->getPerformanceMode()));
    sharing_mode_.store(static_cast<int32_t>(stream_->getSharingMode()));
    if (output_sample_rate_.load() <= 0 ||
        output_channels_.load() != kSourceChannels) {
      stream_->close();
      stream_.reset();
      return static_cast<int>(oboe::Result::ErrorInvalidFormat);
    }
    result = stream_->requestStart();
    if (result != oboe::Result::OK) {
      stream_->close();
      stream_.reset();
      return static_cast<int>(result);
    }
    auto state = stream_->getState();
    while (state != oboe::StreamState::Started) {
      oboe::StreamState next_state = state;
      result = stream_->waitForStateChange(state, &next_state, 2000000000L);
      if (result != oboe::Result::OK) {
        stream_->requestStop();
        stream_->close();
        stream_.reset();
        return static_cast<int>(result);
      }
      state = next_state;
    }
    return 0;
  }

  void stop() {
    std::scoped_lock lock(lifecycle_mutex_);
    stop_locked();
  }

  int write(const int16_t* samples, int32_t frames) {
    if (samples == nullptr || frames <= 0) return 0;
    auto write = write_.load(std::memory_order_relaxed);
    const auto read = read_.load(std::memory_order_acquire);
    const auto available = kCapacityFrames - (write - read);
    const auto accepted = std::min<size_t>(static_cast<size_t>(frames), available);
    for (size_t frame = 0; frame < accepted; ++frame) {
      const auto slot = (write + frame) % kCapacityFrames;
      buffer_[slot * kSourceChannels] = samples[frame * kSourceChannels];
      buffer_[slot * kSourceChannels + 1] =
          samples[frame * kSourceChannels + 1];
    }
    write_.store(write + accepted, std::memory_order_release);
    return static_cast<int>(accepted);
  }

  oboe::DataCallbackResult onAudioReady(oboe::AudioStream*, void* audio_data,
                                         int32_t frames) override {
    auto* output = static_cast<int16_t*>(audio_data);
    auto read = read_.load(std::memory_order_relaxed);
    const auto write = write_.load(std::memory_order_acquire);
    auto available = write - read;
    const auto target =
        static_cast<size_t>(target_frames_.load(std::memory_order_relaxed));
    if (rebuffering_.load(std::memory_order_relaxed)) {
      if (available < target) {
        std::fill(output, output + static_cast<size_t>(frames) * kSourceChannels,
                  0);
        silence_frames_.fetch_add(frames, std::memory_order_relaxed);
        rendered_.fetch_add(static_cast<uint64_t>(frames));
        return oboe::DataCallbackResult::Continue;
      }
      rebuffering_.store(false, std::memory_order_relaxed);
    }
    const auto jitter_allowance = target;
    if (available > target + jitter_allowance) {
      const auto stale = available - target;
      read += stale;
      available = target;
      dropped_.fetch_add(stale, std::memory_order_relaxed);
    }

    controller_frames_ += frames;
    const auto output_rate = output_sample_rate_.load(std::memory_order_relaxed);
    if (controller_frames_ >= output_rate / 20) {
      const double dt = static_cast<double>(controller_frames_) / output_rate;
      const double error_seconds =
          (static_cast<double>(available) -
           target_frames_.load(std::memory_order_relaxed)) /
          kSourceSampleRate;
      const double alpha = 1.0 - std::exp(-dt);
      filtered_error_ += alpha * (error_seconds - filtered_error_);
      integral_error_ = std::clamp(integral_error_ + filtered_error_ * dt,
                                   -1.0, 1.0);
      const double requested =
          std::clamp((0.05 * filtered_error_ + 0.0005 * integral_error_) *
                         1000000.0,
                     -500.0, 500.0);
      const double previous = correction_ppm_.load(std::memory_order_relaxed);
      const double maximum_step = 20.0 * dt;
      correction_ppm_.store(
          previous + std::clamp(requested - previous, -maximum_step,
                                maximum_step),
          std::memory_order_relaxed);
      controller_frames_ = 0;
    }

    const double nominal_ratio =
        static_cast<double>(kSourceSampleRate) / output_rate;
    const double ratio = nominal_ratio *
        (1.0 + correction_ppm_.load(std::memory_order_relaxed) / 1000000.0);
    size_t produced = 0;
    for (; produced < static_cast<size_t>(frames); ++produced) {
      const auto offset = static_cast<size_t>(read_phase_);
      if (offset + 1 >= available) break;
      const double fraction = read_phase_ - static_cast<double>(offset);
      const auto first = (read + offset) % kCapacityFrames;
      const auto second = (read + offset + 1) % kCapacityFrames;
      for (size_t channel = 0; channel < kSourceChannels; ++channel) {
        const double a = buffer_[first * kSourceChannels + channel];
        const double b = buffer_[second * kSourceChannels + channel];
        output[produced * kSourceChannels + channel] =
            static_cast<int16_t>(std::clamp(
                std::lround(a + (b - a) * fraction),
                static_cast<long>(INT16_MIN), static_cast<long>(INT16_MAX)));
      }
      read_phase_ += ratio;
    }
    const auto consumed = std::min(static_cast<size_t>(read_phase_), available);
    read_phase_ -= static_cast<double>(consumed);
    read_.store(read + consumed, std::memory_order_release);
    std::fill(output + produced * kSourceChannels,
              output + static_cast<size_t>(frames) * kSourceChannels, 0);
    if (produced < static_cast<size_t>(frames)) {
      underruns_.fetch_add(1, std::memory_order_relaxed);
      silence_frames_.fetch_add(static_cast<size_t>(frames) - produced,
                                std::memory_order_relaxed);
      rebuffer_events_.fetch_add(1, std::memory_order_relaxed);
      const auto current_target =
          target_frames_.load(std::memory_order_relaxed);
      target_frames_.store(
          std::min(current_target + 240,
                   max_target_frames_.load(std::memory_order_relaxed)),
          std::memory_order_relaxed);
      rebuffering_.store(true, std::memory_order_relaxed);
      stable_frames_ = 0;
    } else {
      stable_frames_ += frames;
      if (stable_frames_ >= output_rate * 10) {
        const auto current_target =
            target_frames_.load(std::memory_order_relaxed);
        const auto base_target =
            base_target_frames_.load(std::memory_order_relaxed);
        target_frames_.store(std::max(current_target - 240, base_target),
                             std::memory_order_relaxed);
        stable_frames_ = 0;
      }
    }
    rendered_.fetch_add(static_cast<uint64_t>(frames));
    return oboe::DataCallbackResult::Continue;
  }

  void onErrorAfterClose(oboe::AudioStream*, oboe::Result) override {
    disconnected_.store(true);
  }

  uint64_t rendered() const { return rendered_.load(); }
  uint64_t underruns() const { return underruns_.load(); }
  uint64_t dropped() const { return dropped_.load(); }
  uint64_t silence_frames() const { return silence_frames_.load(); }
  uint64_t rebuffer_events() const { return rebuffer_events_.load(); }
  int32_t target_frames() const { return target_frames_.load(); }
  void reset_quality_metrics() {
    underruns_.store(0, std::memory_order_relaxed);
    dropped_.store(0, std::memory_order_relaxed);
    silence_frames_.store(0, std::memory_order_relaxed);
    rebuffer_events_.store(0, std::memory_order_relaxed);
    target_frames_.store(base_target_frames_.load(std::memory_order_relaxed),
                         std::memory_order_relaxed);
    rebuffering_.store(false, std::memory_order_relaxed);
  }
  bool disconnected() const { return disconnected_.load(); }
  double correction_ppm() const { return correction_ppm_.load(); }
  uint64_t buffered_frames() const {
    return write_.load(std::memory_order_acquire) -
           read_.load(std::memory_order_acquire);
  }
  int32_t output_sample_rate() const { return output_sample_rate_.load(); }
  int32_t output_channels() const { return output_channels_.load(); }
  int32_t frames_per_burst() const { return frames_per_burst_.load(); }
  int32_t output_device_id() const { return output_device_id_.load(); }
  int32_t performance_mode() const { return performance_mode_.load(); }
  int32_t sharing_mode() const { return sharing_mode_.load(); }

 private:
  void stop_locked() {
    if (stream_) {
      stream_->requestStop();
      stream_->close();
      stream_.reset();
    }
  }

  std::mutex lifecycle_mutex_;
  std::shared_ptr<oboe::AudioStream> stream_;
  std::vector<int16_t> buffer_ =
      std::vector<int16_t>(kCapacityFrames * kSourceChannels);
  std::atomic<size_t> read_{0};
  std::atomic<size_t> write_{0};
  std::atomic<uint64_t> rendered_{0};
  std::atomic<uint64_t> underruns_{0};
  std::atomic<uint64_t> dropped_{0};
  std::atomic<uint64_t> silence_frames_{0};
  std::atomic<uint64_t> rebuffer_events_{0};
  std::atomic<bool> disconnected_{false};
  std::atomic<double> correction_ppm_{0.0};
  std::atomic<int32_t> output_sample_rate_{0};
  std::atomic<int32_t> output_channels_{0};
  std::atomic<int32_t> frames_per_burst_{0};
  std::atomic<int32_t> output_device_id_{0};
  std::atomic<int32_t> performance_mode_{0};
  std::atomic<int32_t> sharing_mode_{0};
  std::atomic<int32_t> target_frames_{480};
  std::atomic<int32_t> base_target_frames_{480};
  std::atomic<int32_t> max_target_frames_{1440};
  std::atomic<bool> rebuffering_{false};
  double read_phase_{0.0};
  double filtered_error_{0.0};
  double integral_error_{0.0};
  int32_t controller_frames_{0};
  int32_t stable_frames_{0};
};

Output output;
}  // namespace

extern "C" __attribute__((visibility("default"))) int sonara_audio_start(
    const int16_t* initial_samples, int initial_frames, int target_frames) {
  return output.start(initial_samples, initial_frames, target_frames);
}
extern "C" __attribute__((visibility("default"))) void sonara_audio_stop() {
  output.stop();
}
extern "C" __attribute__((visibility("default"))) int sonara_audio_write(
    const int16_t* samples, int frames) {
  return output.write(samples, frames);
}
extern "C" __attribute__((visibility("default"))) uint64_t
sonara_audio_rendered_frames() {
  return output.rendered();
}
extern "C" __attribute__((visibility("default"))) uint64_t
sonara_audio_underruns() {
  return output.underruns();
}
extern "C" __attribute__((visibility("default"))) uint64_t
sonara_audio_dropped_frames() {
  return output.dropped();
}
extern "C" __attribute__((visibility("default"))) uint64_t
sonara_audio_silence_frames() {
  return output.silence_frames();
}
extern "C" __attribute__((visibility("default"))) uint64_t
sonara_audio_rebuffer_events() {
  return output.rebuffer_events();
}
extern "C" __attribute__((visibility("default"))) int32_t
sonara_audio_target_frames() {
  return output.target_frames();
}
extern "C" __attribute__((visibility("default"))) void
sonara_audio_reset_quality_metrics() {
  output.reset_quality_metrics();
}
extern "C" __attribute__((visibility("default"))) int
sonara_audio_disconnected() {
  return output.disconnected() ? 1 : 0;
}
extern "C" __attribute__((visibility("default"))) double
sonara_audio_correction_ppm() {
  return output.correction_ppm();
}
extern "C" __attribute__((visibility("default"))) uint64_t
sonara_audio_buffered_frames() {
  return output.buffered_frames();
}
extern "C" __attribute__((visibility("default"))) int32_t
sonara_audio_output_sample_rate() {
  return output.output_sample_rate();
}
extern "C" __attribute__((visibility("default"))) int32_t
sonara_audio_output_channels() {
  return output.output_channels();
}
extern "C" __attribute__((visibility("default"))) int32_t
sonara_audio_frames_per_burst() {
  return output.frames_per_burst();
}
extern "C" __attribute__((visibility("default"))) int32_t
sonara_audio_output_device_id() {
  return output.output_device_id();
}
extern "C" __attribute__((visibility("default"))) int32_t
sonara_audio_performance_mode() {
  return output.performance_mode();
}
extern "C" __attribute__((visibility("default"))) int32_t
sonara_audio_sharing_mode() {
  return output.sharing_mode();
}
