#ifndef RUNNER_HOST_BRIDGE_H_
#define RUNNER_HOST_BRIDGE_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

class HostBridge {
 public:
  explicit HostBridge(flutter::BinaryMessenger* messenger);
  ~HostBridge();

  HostBridge(const HostBridge&) = delete;
  HostBridge& operator=(const HostBridge&) = delete;

  bool IsRunning();
  void Stop();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  PROCESS_INFORMATION process_{};
  HANDLE job_ = nullptr;
  std::wstring invitation_path_;
  std::wstring log_path_;
  std::string invitation_;
  std::string address_;
  DWORD source_pid_ = 0;
};

#endif  // RUNNER_HOST_BRIDGE_H_
