import AppKit
import SwiftUI

@main struct HUDSettingsUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
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
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            precondition(panel.attachedSheet == nil, "Built-in defaults edit inline: \(group.title)")
            func ids(_ object: AnyObject) -> [String] {
                let element = object as AnyObject
                let text = [element.accessibilityIdentifier?(), element.accessibilityLabel?()]
                return text.compactMap { $0 } + (element.accessibilityChildren?() ?? []).flatMap { ids($0 as AnyObject) }
            }
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/hud-\(group.rawValue).png"))
            precondition(views(host).flatMap { ids($0) }.contains { $0 == "hud-builtin-default-pane" || $0.hasPrefix("Built-in default · \(group.summary)") },
                "Reserved group must open its inline default editor: \(group.title)")
            precondition(store.settings.appExplorer == snapshot, "Browsing reserved groups must not mutate saved tiles")
            panel.orderOut(nil); panel.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        print("HUD settings passed: inline built-in default editors, preview rendering, and no saved-setting changes")
    }
}
