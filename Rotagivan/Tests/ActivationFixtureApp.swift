// Disposable app for the manual activation smoke test. No files or user data.
import AppKit

final class ActivationFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) { showWindow() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    private func showWindow() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 120),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Activation test"
            panel.contentView = NSTextField(labelWithString: "Temporary Rotagivan activation test")
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

@main struct ActivationFixtureApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = ActivationFixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
