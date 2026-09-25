import AppKit
import SwiftUI

@main struct ActionTableTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.ActionTable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let output = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
        let trigger = RecordedShortcut(keyCode: 40, modifiers: 1 << 20, keyLabel: "K")
        let macro = NamedHotkey(name: "Copy selection", shortcut: output, activationShortcut: trigger)
        var settings = StoredSettings()
        settings.enabled = true
        settings.hotkeyDictionary = [macro]
        settings.actionBindings = [ActionBinding(trigger: BindingTrigger(keyboard: trigger), action: .command(.lockScreen))]
        settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: "Volume", shortcut: .assigned(.media(.volumeUp)), activationShortcut: output)])
        let audit = HotkeyAudit(settings: settings, shortcuts: ShortcutConfiguration(), layerID: 1, device: .navigator)
        let rows = ActionTableRow.make(settings: settings, applications: [], audit: audit)
        precondition(Set(rows.map(\.id)).count == rows.count)
        let macroRow = rows.first { $0.action.macroID == macro.id }!
        precondition(macroRow.name == macro.name && macroRow.group == "Macros")
        precondition(macroRow.id == VoiceRegisteredAction.id(for: .macro(macro)))
        precondition(macroRow.keybindings.contains("Cmd+K") && !macroRow.keybindings.contains("Cmd+C"), "Macro output keys must not be presented as input bindings")
        precondition(rows.first { $0.action.command == .lockScreen }!.keybindings.contains("Global"))
        precondition(rows.first { $0.action.media == .volumeUp }!.keybindings.contains("HUD"))
        precondition(rows.allSatisfy { !$0.detail.isEmpty && !$0.group.isEmpty })
        let store = SettingsStore(defaults: defaults)
        store.settings = settings
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(store.settings)
        let host = NSHostingView(rootView: HotkeyOrganizerView(store: store).padding(20).frame(width: 1000, height: 790, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light).defaultAppStorage(defaults))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 790), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host; panel.center(); panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = descendants(host).compactMap { $0 as? NSTableView }.first!
        precondition(table.tableColumns.count == 4, "IDs must be hidden by default")
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name + ".png"))
        }
        try capture("actions-table")
        defaults.set(true, forKey: "actions.showIDs")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(table.tableColumns.count == 5, "Show IDs must reveal the fifth column")
        try capture("actions-table-ids")
        let after = try encoder.encode(store.settings)
        precondition(after == before, "Browsing the table must not change actions or assignments")
        panel.orderOut(nil); panel.close()
        print("Action table passed: canonical IDs, groups, descriptions, input-only bindings, native four/five column toggle, non-mutating browsing")
    }
}
