import AppKit
import SwiftUI

@main struct HUDSettingsUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.HUDSettingsUISmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        store.settings.appExplorer = AppExplorerSettings(favorites: [ExplorerReservedGroup.actions.tile(at: .up)])
        let snapshot = store.settings.appExplorer
        for group in ExplorerReservedGroup.allCases {
            let host = NSHostingView(rootView: HUDSettingsView(store: store, initialGroup: group).padding())
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let sheet = panel.attachedSheet, let content = sheet.contentView else {
                fatalError("Reserved group must open a native sheet: \(group.title)")
            }
            content.layoutSubtreeIfNeeded()
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/hud-\(group.rawValue).png"))
            precondition(store.settings.appExplorer == snapshot, "Browsing reserved groups must not mutate saved tiles")
            panel.endSheet(sheet)
            panel.orderOut(nil); panel.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        print("HUD settings passed: three native reserved-group sheets, preview rendering, and no saved-setting changes")
    }
}
