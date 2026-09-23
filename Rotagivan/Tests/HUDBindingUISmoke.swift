import AppKit
import SwiftUI

/// Native regression for assignments that have no tile to carry them.
@main struct HUDBindingUISmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.HUDBindingUISmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false

        let openURL = BindingAction.openURL("https://example.com")
        let first = ActionBinding(trigger: BindingTrigger(keyboard: RecordedShortcut(
            keyCode: 40, modifiers: 1 << 20, keyLabel: "K")), action: openURL)
        var empty = ExplorerHoldLayer.empty(name: "Empty layer")
        empty.favorites = []
        empty.actionBindings = [first]
        var saved: ExplorerHoldLayer?
        let editor = HUDLayerHotkeyEditor(store: store, layer: empty,
            settings: AppExplorerSettings(favorites: [], holdLayers: [empty]),
            onSave: { layer, _ in saved = layer; return true }, onCancel: {})
        let host = NSHostingView(rootView: editor)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        if CommandLine.arguments.count > 1,
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("hud-independent-bindings.png"))
        }
        precondition(host.fittingSize.height <= 600, "The HUD assignment editor should fit its sheet")
        precondition(editor.saveDraft())
        precondition(saved?.actionBindings == [first], "Saving an empty layer must preserve its independent action")
        precondition(saved?.favorites.isEmpty == true)
        panel.orderOut(nil); panel.close()

        var defaultSaved: ExplorerHoldLayer?
        var defaultLayer = ExplorerHoldLayer.empty(name: "Default")
        defaultLayer.favorites = []
        defaultLayer.actionBindings = [first]
        let defaultEditor = HUDLayerHotkeyEditor(store: store,
            layer: defaultLayer, settings: AppExplorerSettings(actionBindings: [first], favorites: []),
            onSave: { layer, _ in defaultSaved = layer; return true }, onCancel: {}, isDefaultLayer: true)
        let defaultHost = NSHostingView(rootView: defaultEditor)
        let defaultPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        defaultPanel.isReleasedWhenClosed = false
        defaultPanel.contentView = defaultHost
        defaultPanel.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(defaultEditor.saveDraft(), "Default HUD layer must save")
        precondition(defaultSaved?.actionBindings == [first], "Default layer save must include independent bindings")
        precondition(defaultSaved?.favorites.isEmpty == true, "Default layer binding must not create a tile")
        defaultPanel.orderOut(nil); defaultPanel.close()

        for recent in [false, true] {
            let group = AppExplorerFavorite(direction: .left, name: recent ? "Recent Apps" : "Nested",
                children: [], groupMode: recent ? .recent : .favorites)
            store.settings.appExplorer = AppExplorerSettings(favorites: [group])
            let groupEditor = AppExplorerSettingsView(store: store, groupPath: [.left])
            var draft = ExplorerHoldLayer.empty(name: group.name)
            draft.favorites = []
            draft.actionBindings = [first]
            precondition(groupEditor.saveGroupHotkeyDraft(draft, at: [.left], ownerID: nil, snapshot: group),
                "An empty nested or Recent Apps HUD layer must save its own binding")
            let savedGroup = store.settings.appExplorer?.favorite(at: [.left])
            precondition(savedGroup?.actionBindings == [first] && savedGroup?.children?.isEmpty == true,
                "Group binding must stay on the group without creating a tile")
        }

        let many = (0..<110).map { index in
            ActionBinding(trigger: BindingTrigger(keyboard: RecordedShortcut(
                keyCode: UInt16(index), modifiers: 1 << 20, keyLabel: "Key \(index)")), action: openURL)
        }
        var large = ExplorerHoldLayer.empty(name: "Many actions")
        large.favorites = []
        large.actionBindings = many
        let largeHost = NSHostingView(rootView: HUDLayerHotkeyEditor(store: store, layer: large,
            settings: AppExplorerSettings(favorites: [], holdLayers: [large]),
            onSave: { _, _ in true }, onCancel: {}))
        let largePanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        largePanel.isReleasedWhenClosed = false
        largePanel.contentView = largeHost
        largePanel.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        largeHost.layoutSubtreeIfNeeded()
        precondition(largeHost.fittingSize.height <= 600, "Many independent bindings must scroll in the fixed sheet")
        precondition(scrollViews(in: largeHost).count >= 1, "Many bindings need a native scroll view")
        largePanel.orderOut(nil); largePanel.close()

        var selected: ActionBinding?
        let bindingEditor = BindingEditor(binding: first, existing: [],
            title: "Test assignment", onSave: { selected = $0 }, onCancel: {})
        let bindingHost = NSHostingView(rootView: bindingEditor)
        let bindingPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 570, height: 230),
            styleMask: [.titled], backing: .buffered, defer: false)
        bindingPanel.isReleasedWhenClosed = false
        bindingPanel.contentView = bindingHost
        bindingPanel.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        bindingEditor.saveDraft()
        precondition(selected == first, "The shared editor should pass the independent trigger and action to its save callback")
        bindingPanel.orderOut(nil); bindingPanel.close()
        print("HUD binding UI passed: default, nested, Recent, and custom tile-free saves, 110-row scrolling, shared editor callback")
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}
