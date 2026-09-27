#include "host_bridge.h"

#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>
#include <iptypes.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <set>
#include <sstream>
#include <thread>
#include <vector>

#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

std::wstring ExecutableDirectory() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                          static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    return L".";
  }
  return std::filesystem::path(std::wstring(path.data(), length))
      .parent_path()
      .wstring();
}

std::wstring LocalStateDirectory() {
  wchar_t path[MAX_PATH] = {};
  if (FAILED(SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr,
                              SHGFP_TYPE_CURRENT, path))) {
    return ExecutableDirectory();
  }
  const auto directory = std::filesystem::path(path) / L"Sonara";
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  return directory.wstring();
}

std::string ReadTextFile(const std::wstring& path) {
  std::ifstream input(std::filesystem::path(path), std::ios::binary);
  if (!input) {
    return {};
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

std::string FileNameFromPath(const std::wstring& path) {
  return Utf8FromUtf16(std::filesystem::path(path).stem().c_str());
}

struct WindowSource {
  DWORD pid;
  std::string name;
  std::string title;
};

BOOL CALLBACK EnumerateWindow(HWND window, LPARAM parameter) {
  if (!IsWindowVisible(window) || GetWindow(window, GW_OWNER) != nullptr) {
    return TRUE;
  }
  const int title_length = GetWindowTextLengthW(window);
  if (title_length <= 0) {
    return TRUE;
  }
  std::vector<wchar_t> title(static_cast<size_t>(title_length) + 1);
  GetWindowTextW(window, title.data(), static_cast<int>(title.size()));

  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (pid == 0 || pid == GetCurrentProcessId()) {
    return TRUE;
  }

  std::wstring executable;
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process != nullptr) {
    std::vector<wchar_t> buffer(32768);
    DWORD size = static_cast<DWORD>(buffer.size());
    if (QueryFullProcessImageNameW(process, 0, buffer.data(), &size)) {
      executable.assign(buffer.data(), size);
    }
    CloseHandle(process);
  }
  if (executable.empty()) {
    return TRUE;
  }

  auto* sources = reinterpret_cast<std::vector<WindowSource>*>(parameter);
  if (std::none_of(sources->begin(), sources->end(),
                   [pid](const WindowSource& source) {
                     return source.pid == pid;
                   })) {
    sources->push_back(
        {pid, FileNameFromPath(executable), Utf8FromUtf16(title.data())});
  }
  return TRUE;
}

EncodableList ListSources() {
  std::vector<WindowSource> sources;
  EnumWindows(EnumerateWindow, reinterpret_cast<LPARAM>(&sources));
  std::sort(sources.begin(), sources.end(),
            [](const WindowSource& left, const WindowSource& right) {
              return left.name < right.name;
            });
  EncodableList result;
  for (const auto& source : sources) {
    result.emplace_back(EncodableMap{
        {EncodableValue("pid"), EncodableValue(static_cast<int>(source.pid))},
        {EncodableValue("name"), EncodableValue(source.name)},
        {EncodableValue("title"), EncodableValue(source.title)},
    });
  }
  return result;
}

bool IsPrivateIpv4(const std::string& address) {
  unsigned int first = 0;
  unsigned int second = 0;
  if (sscanf_s(address.c_str(), "%u.%u", &first, &second) != 2) {
    return false;
  }
  return first == 10 || (first == 172 && second >= 16 && second <= 31) ||
         (first == 192 && second == 168);
}

std::string SelectLanAddress() {
  ULONG size = 0;
  if (GetAdaptersInfo(nullptr, &size) != ERROR_BUFFER_OVERFLOW || size == 0) {
    return {};
  }
  std::vector<unsigned char> buffer(size);
  auto* adapters = reinterpret_cast<IP_ADAPTER_INFO*>(buffer.data());
  if (GetAdaptersInfo(adapters, &size) != NO_ERROR) {
    return {};
  }

  std::string fallback;
  std::string private_fallback;
  for (auto* adapter = adapters; adapter != nullptr; adapter = adapter->Next) {
    if (adapter->Type == MIB_IF_TYPE_LOOPBACK) {
      continue;
    }
    for (auto* address = &adapter->IpAddressList; address != nullptr;
         address = address->Next) {
      const std::string text = address->IpAddress.String;
      if (text.empty() || text == "0.0.0.0" || text == "127.0.0.1") {
        continue;
      }
      if (IsPrivateIpv4(text)) {
        const std::string gateway = adapter->GatewayList.IpAddress.String;
        if (!gateway.empty() && gateway != "0.0.0.0") {
          return text;
        }
        if (private_fallback.empty()) {
          private_fallback = text;
        }
      }
      if (fallback.empty()) {
        fallback = text;
      }
    }
  }
  return private_fallback.empty() ? fallback : private_fallback;
}

std::wstring Quote(const std::wstring& value) {
  return L"\"" + value + L"\"";
}

bool StartupEnabled() {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER,
                    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
                    KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }
  const LONG result = RegQueryValueExW(key, L"Sonara", nullptr, nullptr,
                                       nullptr, nullptr);
  RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

bool SetStartupEnabled(bool enabled) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                      0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return false;
  }
  LONG result = ERROR_SUCCESS;
  if (enabled) {
    const std::wstring command = Quote(ExecutableDirectory() + L"\\sonara.exe") +
                                 L" --background";
    result = RegSetValueExW(
        key, L"Sonara", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    result = RegDeleteValueW(key, L"Sonara");
    if (result == ERROR_FILE_NOT_FOUND) {
      result = ERROR_SUCCESS;
    }
  }
  RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

const EncodableMap* ArgumentsOf(
    const flutter::MethodCall<EncodableValue>& call) {
  return call.arguments() == nullptr
             ? nullptr
             : std::get_if<EncodableMap>(call.arguments());
}

template <typename T>
const T* ReadArgument(const EncodableMap& arguments, const char* key) {
  const auto found = arguments.find(EncodableValue(key));
  return found == arguments.end() ? nullptr : std::get_if<T>(&found->second);
}

}  // namespace

HostBridge::HostBridge(flutter::BinaryMessenger* messenger) {
  job_ = CreateJobObjectW(nullptr, nullptr);
  if (job_ != nullptr) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &limits,
                            sizeof(limits));
  }
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "dev.sonara/host",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

HostBridge::~HostBridge() {
  Stop();
  if (job_ != nullptr) {
    CloseHandle(job_);
    job_ = nullptr;
  }
}

bool HostBridge::IsRunning() {
  if (process_.hProcess == nullptr) {
    return false;
  }
  DWORD exit_code = 0;
  if (!GetExitCodeProcess(process_.hProcess, &exit_code) ||
      exit_code != STILL_ACTIVE) {
    CloseHandle(process_.hProcess);
    CloseHandle(process_.hThread);
    process_ = {};
    return false;
  }
  return true;
}

void HostBridge::Stop() {
  if (process_.hProcess != nullptr) {
    if (IsRunning()) {
      TerminateProcess(process_.hProcess, 0);
      WaitForSingleObject(process_.hProcess, 2000);
    }
    if (process_.hProcess != nullptr) {
      CloseHandle(process_.hProcess);
      CloseHandle(process_.hThread);
      process_ = {};
    }
  }
  invitation_.clear();
  source_pid_ = 0;
}

void HostBridge::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() == "listSources") {
    result->Success(EncodableValue(ListSources()));
    return;
  }
  if (call.method_name() == "status") {
    const bool running = IsRunning();
    if (running && invitation_.empty()) {
      invitation_ = ReadTextFile(invitation_path_);
    }
    const std::string state = !running
                                  ? "idle"
                                  : invitation_.empty()
                                        ? "starting"
                                        : "waiting_or_streaming";
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("state"), EncodableValue(state)},
        {EncodableValue("active"), EncodableValue(running)},
        {EncodableValue("source_pid"),
         EncodableValue(static_cast<int>(source_pid_))},
        {EncodableValue("address"), EncodableValue(address_)},
        {EncodableValue("invitation"), EncodableValue(invitation_)},
    }));
    return;
  }
  if (call.method_name() == "stop") {
    Stop();
    result->Success(EncodableValue(true));
    return;
  }
  if (call.method_name() == "getStartup") {
    result->Success(EncodableValue(StartupEnabled()));
    return;
  }
  if (call.method_name() == "setStartup") {
    const auto* arguments = ArgumentsOf(call);
    const bool* enabled = arguments == nullptr
                              ? nullptr
                              : ReadArgument<bool>(*arguments, "enabled");
    if (enabled == nullptr || !SetStartupEnabled(*enabled)) {
      result->Error("startup", "Could not update Windows startup settings");
    } else {
      result->Success(EncodableValue(*enabled));
    }
    return;
  }
  if (call.method_name() != "start") {
    result->NotImplemented();
    return;
  }

  const auto* arguments = ArgumentsOf(call);
  const int* pid = arguments == nullptr
                       ? nullptr
                       : ReadArgument<int>(*arguments, "pid");
  const std::string* mode = arguments == nullptr
                                ? nullptr
                                : ReadArgument<std::string>(*arguments, "mode");
  const std::string* profile =
      arguments == nullptr
          ? nullptr
          : ReadArgument<std::string>(*arguments, "profile");
  if (pid == nullptr || *pid <= 0 || mode == nullptr || profile == nullptr) {
    result->Error("arguments", "A valid source, mode, and profile are required");
    return;
  }
  if (IsRunning()) {
    result->Error("active", "A Sonara host session is already running");
    return;
  }

  address_ = SelectLanAddress();
  if (address_.empty()) {
    result->Error("network", "No active LAN IPv4 address was found");
    return;
  }
  const std::wstring state_directory = LocalStateDirectory();
  invitation_path_ = state_directory + L"\\active-invitation.txt";
  log_path_ = state_directory + L"\\host.log";
  std::error_code file_error;
  std::filesystem::remove(invitation_path_, file_error);

  const std::wstring engine = ExecutableDirectory() + L"\\sonara_engine.exe";
  if (!std::filesystem::exists(engine)) {
    result->Error("engine", "The bundled Sonara audio engine is missing");
    return;
  }
  const std::wstring address =
      std::wstring(address_.begin(), address_.end()) + L":49812";
  const std::wstring mode_w(mode->begin(), mode->end());
  const std::wstring profile_w(profile->begin(), profile->end());
  std::wstringstream command;
  command << Quote(engine) << L" host --pid " << *pid
          << L" --listen 0.0.0.0:49812 --advertise " << address
          << L" --duration 86400 --invitation-out "
          << Quote(invitation_path_) << L" --mode " << mode_w
          << L" --profile " << profile_w;
  std::wstring mutable_command = command.str();

  SECURITY_ATTRIBUTES security{};
  security.nLength = sizeof(security);
  security.bInheritHandle = TRUE;
  HANDLE log = CreateFileW(log_path_.c_str(), GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, &security,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (log == INVALID_HANDLE_VALUE) {
    result->Error("log", "Could not create the local Sonara host log");
    return;
  }
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
  startup.wShowWindow = SW_HIDE;
  startup.hStdOutput = log;
  startup.hStdError = log;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  const BOOL created = CreateProcessW(
      engine.c_str(), mutable_command.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW, nullptr, ExecutableDirectory().c_str(), &startup,
      &process_);
  CloseHandle(log);
  if (!created) {
    process_ = {};
    result->Error("engine", "Could not start the Sonara audio engine");
    return;
  }
  if (job_ != nullptr) {
    AssignProcessToJobObject(job_, process_.hProcess);
  }
  source_pid_ = static_cast<DWORD>(*pid);

  result->Success(EncodableValue(EncodableMap{
      {EncodableValue("active"), EncodableValue(true)},
      {EncodableValue("state"), EncodableValue("starting")},
      {EncodableValue("source_pid"), EncodableValue(*pid)},
      {EncodableValue("address"), EncodableValue(address_)},
      {EncodableValue("invitation"), EncodableValue("")},
  }));
}
