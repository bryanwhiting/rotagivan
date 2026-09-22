import AppKit
import SwiftUI

@main struct ProfileSettingsUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.SettingsUISmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        store.settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: "Docs", url: "https://example.com")])
        store.renameConfiguration("Everyday")
        store.settings.appOverrides = [.chrome,
            AppGestureOverride(bundleID: "com.apple.Safari", name: "Safari"),
            AppGestureOverride(bundleID: "com.apple.finder", name: "Finder"),
            AppGestureOverride(bundleID: "com.apple.Terminal", name: "Terminal", enabled: false),
            AppGestureOverride(bundleID: "test.missing.application", name: "An app with a longer name")]
        let hid = NavigatorHIDManager(store: store)
        let sync = SettingsSync(store: store, hid: hid) // Never start input, sync or Keychain access.
        let output = CommandLine.arguments[1]
        for (index, section) in ["Layers", "Devices", "App Explorer", "Pointer & scrolling", "General", "Calibration", "Layers", "App overrides", "Window Manager", "App Explorer"].enumerated() {
            if index == 9 {
                store.settings.appExplorer = AppExplorerSettings(favorites: ExplorerSlot.slots(16).map {
                    AppExplorerFavorite(direction: $0, name: "App", url: "https://example.com")
                }, slotCount: 16)
            }
            if index == 6 {
                store.settings.devices = ProfileDevices(shareTapActions: false)
                store.updateAppleGestures(store.settings.effectiveGestures(for: store.defaultProfileID), for: store.defaultProfileID)
            }
            let view = ContentView(store: store, hid: hid, sync: sync, initialSection: section,
                initialDevice: index == 6 ? .apple : .navigator)
            let host = NSHostingView(rootView: view)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 740),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/settings-\(index).png"))
            if section == "Calibration" {
                func scrollViews(_ view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                if let scroll = scrollViews(host).max(by: {
                    ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
                }), let document = scroll.documentView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    let lower = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: lower)
                    try lower.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/calibration-swipe-families.png"))
                }
            }
            if section == "App overrides" {
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate()
                // Coordinates refer to this fixed 940 × 740 native render fixture.
                // Events go only to the test panel, never to the live app.
                func click(_ x: CGFloat, _ yFromTop: CGFloat) {
                    let point = host.convert(NSPoint(x: x, y: host.isFlipped ? yFromTop : host.bounds.height - yFromTop), to: nil)
                    func event(_ type: NSEvent.EventType) -> NSEvent {
                        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                    }
                    // Native buttons may track synchronously until mouse-up.
                    NSApp.postEvent(event(.leftMouseUp), atStart: true)
                    panel.sendEvent(event(.leftMouseDown))
                    if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                        panel.sendEvent(up)
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                }
                click(450, 250) // Safari
                click(214, 347) // Enable overrides
                precondition(store.settings.resolvedAppOverrides.first { $0.bundleID == "com.apple.Safari" }?.enabled == false)
                precondition(store.settings.resolvedAppOverrides.first { $0.bundleID == "com.google.Chrome" }?.enabled == true,
                             "Editing a selected chip must not affect another app")
                click(285, 300) // Missing app, on the wrapped second row
                click(214, 347)
                precondition(store.settings.resolvedAppOverrides.last?.enabled == false, "Missing apps remain selectable")
                click(800, 250) // Disabled Terminal overrides remain selectable
                click(875, 347) // Remove app
                precondition(!store.settings.resolvedAppOverrides.contains { $0.bundleID == "com.apple.Terminal" })
                store.settings.appOverrides = []
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                print("App override chips passed: native click selection, independent edits, disabled-app selection/removal, missing-app fallback and empty-state rendering.")
            }
            panel.orderOut(nil); panel.close()
        }
        print("Profile settings UI rendered: shared actions, device overrides, Calibration, devices, Explorer, Navigator tuning, General, and app override chips. No live input/sync started.")
    }
}
