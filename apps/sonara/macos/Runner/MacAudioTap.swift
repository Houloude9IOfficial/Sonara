import AVFoundation
import CoreAudio
import Foundation

private struct CapturedBlock {
  let buffers: [Data]
  let channels: [Int]
  let timestamp: UInt64
}

final class MacAudioTap {
  private var tapID: AudioObjectID = 0
  private var aggregateID: AudioObjectID = 0
  private var ioProc: AudioDeviceIOProcID?
  private var format = AudioStreamBasicDescription()
  private let ioQueue = DispatchQueue(label: "dev.sonara.capture.io", qos: .userInteractive)
  private let writerQueue = DispatchQueue(label: "dev.sonara.capture.writer", qos: .userInitiated)
  private let lock = NSLock()
  private var pending = 0
  private var active = false
  private var capturedBlocks = 0
  private var sentBlocks = 0
  private var socketFD: Int32 = -1
  private var phase = 0.0
  private var previous: (Float, Float) = (0, 0)
  private let socketPath: String

  init(socketPath: String) { self.socketPath = socketPath }

  var diagnostics: [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return ["captured_blocks": capturedBlocks, "sent_blocks": sentBlocks,
            "sample_rate": format.mSampleRate]
  }

  static func processObject(pid: Int32) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var processPID = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafePointer(to: &processPID) { pointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), pointer, &size, &object)
    }
    return status == noErr && object != kAudioObjectUnknown ? object : nil
  }

  private static func audioProcesses(inTreeOf root: Int32) -> [AudioObjectID] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var byteCount = 0
    guard sysctl(&mib, u_int(mib.count), nil, &byteCount, nil, 0) == 0 else {
      return processObject(pid: root).map { [$0] } ?? []
    }
    var processes = [kinfo_proc](repeating: kinfo_proc(),
                                  count: byteCount / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, u_int(mib.count), &processes, &byteCount, nil, 0) == 0 else {
      return processObject(pid: root).map { [$0] } ?? []
    }
    let count = byteCount / MemoryLayout<kinfo_proc>.stride
    var selected: Set<Int32> = [root]
    var changed = true
    while changed {
      changed = false
      for process in processes.prefix(count) {
        let pid = process.kp_proc.p_pid
        if selected.contains(process.kp_eproc.e_ppid) && !selected.contains(pid) {
          selected.insert(pid)
          changed = true
        }
      }
    }
    return selected.sorted().compactMap { processObject(pid: $0) }
  }

  func start(sourcePID: Int32?) throws {
    let description: CATapDescription
    if let sourcePID {
      let processes = Self.audioProcesses(inTreeOf: sourcePID)
      guard !processes.isEmpty else {
        throw NSError(domain: "Sonara", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The selected application has no capturable audio process."])
      }
      description = CATapDescription(stereoMixdownOfProcesses: processes)
    } else {
      let ownProcess = Self.processObject(pid: getpid())
      description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
    }
    description.isPrivate = true
    description.muteBehavior = .unmuted
    let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
    guard tapStatus == noErr else { throw audioError("create audio tap", tapStatus) }
    do {
      let properties: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Sonara Audio Capture",
        kAudioAggregateDeviceUIDKey: "dev.sonara.tap.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        kAudioAggregateDeviceTapAutoStartKey: true,
      ]
      let aggregateStatus = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregateID)
      guard aggregateStatus == noErr else { throw audioError("create capture device", aggregateStatus) }

      var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      let formatStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
      guard formatStatus == noErr else { throw audioError("read audio format", formatStatus) }
      guard format.mFormatID == kAudioFormatLinearPCM,
            format.mBitsPerChannel == 32,
            (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            format.mSampleRate > 0 else {
        throw NSError(domain: "Sonara", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "This output device uses an unsupported audio format."])
      }

      let procStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, ioQueue) {
        [weak self] _, input, inputTime, _, _ in
        guard let self else { return }
        self.receive(input, timestamp: inputTime.pointee.mHostTime)
      }
      guard procStatus == noErr else { throw audioError("register capture callback", procStatus) }
      lock.lock(); active = true; lock.unlock()
      let startStatus = AudioDeviceStart(aggregateID, ioProc)
      guard startStatus == noErr else { throw audioError("start audio capture", startStatus) }
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    lock.lock(); active = false; lock.unlock()
    if let ioProc {
      _ = AudioDeviceStop(aggregateID, ioProc)
      _ = AudioDeviceDestroyIOProcID(aggregateID, ioProc)
      self.ioProc = nil
    }
    if aggregateID != 0 {
      _ = AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = 0
    }
    if tapID != 0 {
      _ = AudioHardwareDestroyProcessTap(tapID)
      tapID = 0
    }
    writerQueue.sync {
      if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 }
    }
  }

  private func receive(_ input: UnsafePointer<AudioBufferList>, timestamp: UInt64) {
    lock.lock()
    guard active && pending < 12 else { lock.unlock(); return }
    pending += 1
    capturedBlocks += 1
    lock.unlock()
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let buffers = list.map { buffer in
      buffer.mData.map { Data(bytes: $0, count: Int(buffer.mDataByteSize)) } ?? Data()
    }
    let channels = list.map { Int($0.mNumberChannels) }
    let block = CapturedBlock(
      buffers: buffers,
      channels: channels,
      timestamp: AudioConvertHostTimeToNanos(timestamp))
    writerQueue.async { [weak self] in
      guard let self else { return }
      self.lock.lock(); let enabled = self.active; self.lock.unlock()
      if enabled { self.convertAndSend(block) }
      self.lock.lock(); self.pending -= 1; self.lock.unlock()
    }
  }

  private func convertAndSend(_ block: CapturedBlock) {
    let channels = Int(format.mChannelsPerFrame)
    guard channels > 0, !block.buffers.isEmpty else { return }
    let interleaved = block.buffers.count == 1
    let frames = interleaved
      ? block.buffers[0].count / (MemoryLayout<Float>.size * channels)
      : block.buffers.map { $0.count / MemoryLayout<Float>.size }.min() ?? 0
    guard frames > 1 else { return }
    func sample(_ channel: Int, _ index: Int) -> Float {
      if index < 0 { return channel == 0 ? previous.0 : previous.1 }
      let data = block.buffers[interleaved ? 0 : min(channel, block.buffers.count - 1)]
      let offset = (interleaved ? index * channels + min(channel, channels - 1) : index) * 4
      return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }
    let step = format.mSampleRate / 48_000.0
    var pcm = Data()
    pcm.reserveCapacity(Int(Double(frames) / step + 2) * 4)
    while phase < Double(frames - 1) {
      let low = Int(floor(phase))
      let fraction = Float(phase - Double(low))
      for channel in 0..<2 {
        let a = sample(channel, low)
        let b = sample(channel, low + 1)
        let value = max(-1, min(1, a + (b - a) * fraction))
        var encoded = Int16(clamping: Int((value * 32767).rounded())).littleEndian
        withUnsafeBytes(of: &encoded) { pcm.append(contentsOf: $0) }
      }
      phase += step
    }
    previous = (sample(0, frames - 1), sample(1, frames - 1))
    phase -= Double(frames)
    guard !pcm.isEmpty, pcm.count <= 65_536 else { return }
    if socketFD < 0 { socketFD = connectToEngine() }
    guard socketFD >= 0 else { return }
    var length = UInt32(pcm.count).bigEndian
    var timestamp = block.timestamp.bigEndian
    let header = withUnsafeBytes(of: &length) { Data($0) } + withUnsafeBytes(of: &timestamp) { Data($0) }
    if !writeAll(header) || !writeAll(pcm) {
      Darwin.close(socketFD)
      socketFD = -1
    } else {
      lock.lock(); sentBlocks += 1; lock.unlock()
    }
  }

  private func connectToEngine() -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    var noSignal: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8CString)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(descriptor); return -1
    }
    withUnsafeMutableBytes(of: &address.sun_path) { path in
      bytes.withUnsafeBytes { source in path.copyBytes(from: source) }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, length)
      }
    }
    if status != 0 { Darwin.close(descriptor); return -1 }
    return descriptor
  }

  private func writeAll(_ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return false }
      var sent = 0
      while sent < raw.count {
        let count = Darwin.write(socketFD, base.advanced(by: sent), raw.count - sent)
        if count <= 0 { return false }
        sent += count
      }
      return true
    }
  }

  private func audioError(_ action: String, _ status: OSStatus) -> Error {
    NSError(domain: "Sonara", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(action) (Core Audio \(status)). Check System Audio Recording permission."])
  }
}
