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
        let hid = NavigatorHIDManager(store: store)
        let sync = SettingsSync(store: store, hid: hid) // Never start input, sync or Keychain access.
        let output = CommandLine.arguments[1]
        for (index, section) in ["Layers", "Devices", "App Explorer", "Pointer & scrolling", "General", "Layers"].enumerated() {
            if index == 5 {
                store.settings.devices = ProfileDevices(shareTapActions: false)
                store.updateAppleGestures(store.settings.effectiveGestures(for: store.defaultProfileID), for: store.defaultProfileID)
            }
            let view = ContentView(store: store, hid: hid, sync: sync, initialSection: section,
                initialDevice: index == 5 ? .apple : .navigator)
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
            panel.orderOut(nil); panel.close()
        }
        print("Profile settings UI rendered: shared actions, device overrides, devices, Explorer, Navigator tuning, General. No live input/sync started.")
    }
}
