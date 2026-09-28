import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var hostBridge: MacHostBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    hostBridge = MacHostBridge(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  override func close() {
    orderOut(nil)
  }

  func stopHost() { hostBridge?.stop() }
}
