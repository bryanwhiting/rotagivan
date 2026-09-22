import AppKit
import SwiftUI

@main struct PointerDeviceUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.PointerDeviceUISmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        store.renameConfiguration("Everyday")
        let hid = NavigatorHIDManager(store: store)
        let sync = SettingsSync(store: store, hid: hid)
        for (section, device, name) in [
            ("Pointer & scrolling", GestureDevice.navigator, "pointer-navigator"),
            ("Pointer & scrolling", GestureDevice.apple, "pointer-apple"),
            ("Layers", GestureDevice.navigator, "layers-without-dragging")
        ] {
            let host = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync,
                initialSection: section, initialDevice: device))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 740),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host; panel.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                CommandLine.arguments[1] + "/" + name + ".png"))
            if device == .navigator && section == "Pointer & scrolling" {
                func scrollViews(_ view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                if let scroll = scrollViews(host).max(by: {
                    ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
                }), let document = scroll.documentView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                        CommandLine.arguments[1] + "/pointer-navigator-dragging.png"))
                }
            }
            panel.orderOut(nil); panel.close()
        }
        print("Per-device pointer panes and layer layout rendered using isolated preferences; no input or sync started.")
    }
}
