import AppKit

let mainApp = Bundle.main.bundleURL
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = ["--background"]
configuration.activates = false
NSWorkspace.shared.openApplication(at: mainApp, configuration: configuration) { _, error in
  exit(error == nil ? 0 : 1)
}
RunLoop.main.run()
