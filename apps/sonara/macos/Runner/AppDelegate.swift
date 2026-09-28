import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "◉ Sonara"
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Open Sonara", action: #selector(openSonara), keyEquivalent: "o"))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Sonara", action: #selector(quitSonara), keyEquivalent: "q"))
    for entry in menu.items { entry.target = self }
    item.menu = menu
    statusItem = item
    if ProcessInfo.processInfo.arguments.contains("--background") {
      NSApp.windows.forEach { $0.orderOut(nil) }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication,
                                               hasVisibleWindows flag: Bool) -> Bool {
    openSonara()
    return true
  }

  @objc private func openSonara() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first(where: { $0 is MainFlutterWindow })?.makeKeyAndOrderFront(nil)
  }

  @objc private func quitSonara() { NSApp.terminate(nil) }

  override func applicationWillTerminate(_ notification: Notification) {
    NSApp.windows.compactMap { $0 as? MainFlutterWindow }.forEach { $0.stopHost() }
    super.applicationWillTerminate(notification)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
