import AppKit
import SwiftUI

@main struct BuiltInHUDUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let name = "Rotagivan.BuiltInHUD.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        store.settings.appExplorer = AppExplorerSettings()
        for group in [ExplorerReservedGroup.actions, .chromeTabs, .recentApps, .mediaControls] {
            let host = NSHostingView(rootView: BuiltInHUDDefaultEditor(store: store, group: group)
                .padding(24).frame(width: 720, height: 620).background(Color(nsColor: .windowBackgroundColor)))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host; panel.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            if let destination = CommandLine.arguments.dropFirst().first,
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to:
                    URL(fileURLWithPath: destination).appendingPathComponent("builtin-\(group.rawValue).png"))
            }
            panel.orderOut(nil); panel.close()
        }
        let controller = AppExplorerController(defaults: defaults)
        controller.contextIsValid = { true }
        controller.chromeTabsProvider = { (1...20).map { ChromeRecentTab(windowIndex: 1, tabIndex: $0, title: "Fixture tab \($0)", url: "https://example.test/\($0)") } }
        var configuration = AppExplorerSettings()
        let layer = configuration.assignBuiltIn(.chromeTabs, at: .right)!
        controller.configuration = { configuration }
        controller.show(waitingForLift: false)
        precondition(controller.navigateHUD(.next))
        let deadline = Date().addingTimeInterval(4)
        while controller.displayedEntries.first?.chromeTab == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        precondition(controller.displayedLayerID == layer)
        precondition(controller.displayedEntries.count == 8)
        precondition(controller.displayedEntries.first?.chromeTab?.tabIndex == 1)
        precondition(controller.displayedEntries.last?.chromeTab?.tabIndex == 8)
        controller.changeWindowPage(1)
        precondition(controller.displayedEntries.first?.chromeTab?.tabIndex == 9)
        controller.changeWindowPage(1)
        precondition(controller.displayedEntries.count == 4)
        precondition(controller.displayedEntries.last?.chromeTab?.tabIndex == 20)
        controller.changeWindowPage(1)
        precondition(controller.displayedEntries.count == 4, "Paging clamps at the last tab")
        controller.changeWindowPage(-1)
        precondition(controller.displayedEntries.first?.chromeTab?.tabIndex == 9)
        controller.dismiss()
        print("Built-in HUD preview and Chrome runtime passed; synthetic tabs only, no tab activated")
    }
}
