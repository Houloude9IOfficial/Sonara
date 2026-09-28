import Cocoa
import FlutterMacOS
import ServiceManagement

final class MacHostBridge {
  private static let loginService = SMAppService.loginItem(identifier: "com.htdevs.sonara.login")
  private let channel: FlutterMethodChannel
  private var engine: Process?
  private var audio: MacAudioTap?
  private var invitationURL: URL?
  private var logURL: URL?
  private var socketURL: URL?
  private var sourcePID = 0
  private var sourceLabel = ""
  private var mode = ""
  private var profile = ""
  private var address = ""
  private var lastError: String?
  private var starting = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.sonara/host", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  deinit { stop() }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listSources": result(listSources())
    case "status": result(status())
    case "stop": stop(); result(true)
    case "getStartup": result(Self.loginService.status == .enabled)
    case "setStartup":
      guard let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool else {
        result(FlutterError(code: "arguments", message: "Expected enabled setting", details: nil))
        return
      }
      do {
        if enabled { try Self.loginService.register() }
        else { try Self.loginService.unregister() }
        if enabled && Self.loginService.status == .requiresApproval {
          result(FlutterError(
            code: "startup",
            message: "Allow Sonara in System Settings → General → Login Items & Extensions.",
            details: nil))
          return
        }
        result(Self.loginService.status == .enabled)
      } catch {
        result(FlutterError(code: "startup", message: error.localizedDescription, details: nil))
      }
    case "start": start(call.arguments as? [String: Any], result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func listSources() -> [[String: Any]] {
    var sources: [[String: Any]] = [
      ["pid": 0, "name": "System audio", "title": "All audible applications"]
    ]
    let apps = NSWorkspace.shared.runningApplications
      .filter {
        $0.activationPolicy == .regular && $0.processIdentifier != getpid() &&
        $0.bundleIdentifier != Bundle.main.bundleIdentifier
      }
      .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    for app in apps {
      let pid = app.processIdentifier
      sources.append([
        "pid": Int(pid),
        "name": app.localizedName ?? "Application",
        "title": app.bundleIdentifier ?? "Running application",
      ])
    }
    return sources
  }

  private func start(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard let arguments,
          let pid = arguments["pid"] as? Int,
          let systemAudio = arguments["systemAudio"] as? Bool,
          let label = arguments["sourceLabel"] as? String, !label.isEmpty,
          let mode = arguments["mode"] as? String,
          let profile = arguments["profile"] as? String,
          systemAudio == (pid == 0), pid >= 0, pid <= Int32.max else {
      result(FlutterError(code: "arguments", message: "A valid source, mode, and profile are required", details: nil))
      return
    }
    guard engine?.isRunning != true && !starting else {
      result(FlutterError(code: "active", message: "A Sonara host session is already running", details: nil))
      return
    }
    guard let selectedAddress = Self.lanAddresses().first else {
      result(FlutterError(code: "network", message: "No active LAN IPv4 address was found", details: nil))
      return
    }
    guard let binary = Bundle.main.executableURL?.deletingLastPathComponent()
      .appendingPathComponent("sonara_engine"),
      FileManager.default.isExecutableFile(atPath: binary.path) else {
      result(FlutterError(code: "engine", message: "The bundled Sonara audio engine is missing", details: nil))
      return
    }
    starting = true
    let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Sonara", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      let invitation = state.appendingPathComponent("active-invitation.txt")
      let log = state.appendingPathComponent("host.log")
      let socket = FileManager.default.temporaryDirectory
        .appendingPathComponent("sonara-\(getpid()).sock")
      try? FileManager.default.removeItem(at: invitation)
      try? FileManager.default.removeItem(at: socket)
      let output = FileManager.default.createFile(atPath: log.path, contents: nil)
      guard output, let logHandle = FileHandle(forWritingAtPath: log.path) else {
        throw NSError(domain: "Sonara", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Could not create the host log."])
      }
      defer { logHandle.closeFile() }
      logHandle.truncateFile(atOffset: 0)
      let tap = MacAudioTap(socketPath: socket.path)
      try tap.start(sourcePID: systemAudio ? nil : Int32(pid))
      let process = Process()
      process.executableURL = binary
      process.currentDirectoryURL = binary.deletingLastPathComponent()
      process.arguments = ["host", "--mac-pcm-socket", socket.path,
                           "--listen", "0.0.0.0:49812"]
        + Self.lanAddresses().flatMap { ["--advertise", "\($0):49812"] }
        + ["--duration", "86400", "--invitation-out", invitation.path,
           "--mode", mode, "--profile", profile]
      var environment = ProcessInfo.processInfo.environment
      environment["SONARA_IDENTITY_DIR"] = state.appendingPathComponent("identity").path
      environment["SONARA_HOST_NAME"] = Host.current().localizedName ?? "Sonara Mac"
      process.environment = environment
      process.standardOutput = logHandle
      process.standardError = logHandle
      do { try process.run() }
      catch { tap.stop(); throw error }
      engine = process
      audio = tap
      invitationURL = invitation
      logURL = log
      socketURL = socket
      sourcePID = pid
      sourceLabel = label
      self.mode = mode
      self.profile = profile
      address = selectedAddress
      lastError = nil
      starting = false
      result(status())
    } catch {
      starting = false
      lastError = error.localizedDescription
      result(FlutterError(code: "host", message: error.localizedDescription, details: nil))
    }
  }

  private func status() -> [String: Any] {
    if sourcePID != 0 && engine?.isRunning == true &&
       Darwin.kill(Int32(sourcePID), 0) != 0 && errno == ESRCH {
      lastError = "The selected application closed. Choose another audio source."
      stop(clearError: false)
    }
    let running = engine?.isRunning == true
    if !running && engine != nil {
      if let log = logURL, let content = try? String(contentsOf: log, encoding: .utf8),
         let final = content.split(separator: "\n").last {
        lastError = String(final)
      }
      stop(clearError: false)
    }
    let invitation = running
      ? (invitationURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
      : ""
    return [
      "state": running ? (invitation.isEmpty ? "starting" : "waiting_or_streaming") : "idle",
      "active": running,
      "source_pid": sourcePID,
      "source_label": sourceLabel,
      "source_kind": sourcePID == 0 ? "system" : "application",
      "mode": mode,
      "profile": profile,
      "address": address,
      "invitation": invitation,
      "connected_devices": running ? receiverRoster() : [],
      "capture": audio?.diagnostics ?? [:],
      "error": lastError ?? "",
    ]
  }

  private func receiverRoster() -> [String] {
    guard let logURL, let content = try? String(contentsOf: logURL, encoding: .utf8),
          let line = content.components(separatedBy: .newlines)
            .last(where: { $0.hasPrefix("SONARA_RECEIVERS") }) else { return [] }
    return line.split(separator: "\t").dropFirst().map(String.init)
  }

  func stop(clearError: Bool = true) {
    audio?.stop()
    audio = nil
    if let engine, engine.isRunning {
      let deadline = Date().addingTimeInterval(2)
      while engine.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
      if engine.isRunning { engine.terminate() }
    }
    engine = nil
    if let socketURL { try? FileManager.default.removeItem(at: socketURL) }
    socketURL = nil
    if clearError { lastError = nil }
    sourcePID = 0
    sourceLabel = ""
    mode = ""
    profile = ""
    address = ""
  }

  private static func lanAddresses() -> [String] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }
    var addresses: [String] = []
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let node = current {
      let entry = node.pointee
      if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
         entry.ifa_flags & UInt32(IFF_UP) != 0,
         entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
        var storage = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self)
        var value = ipv4.pointee.sin_addr
        if inet_ntop(AF_INET, &value, &storage, socklen_t(storage.count)) != nil {
          addresses.append(String(cString: storage))
        }
      }
      current = entry.ifa_next
    }
    return Array(Set(addresses)).sorted { lhs, rhs in
      let lhsPrivate = lhs.hasPrefix("10.") || lhs.hasPrefix("192.168.") || lhs.hasPrefix("172.")
      let rhsPrivate = rhs.hasPrefix("10.") || rhs.hasPrefix("192.168.") || rhs.hasPrefix("172.")
      return lhsPrivate == rhsPrivate ? lhs < rhs : lhsPrivate
    }
  }
}
