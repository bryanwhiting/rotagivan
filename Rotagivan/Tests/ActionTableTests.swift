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
        let slackActivity = VoiceActionRegistry.slackDefaults.first { $0.title == "Activity" }!
        settings.actionVocabulary = [ActionVocabulary(actionID: slackActivity.id, keywordSets: [["mentions", "what did I miss"], ["my notifications"]])]
        settings.appOverrides = [AppGestureOverride(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", bindings: [
            AppGestureBinding(trigger: .twoFingerTap, action: .shortcut, shortcut: slackActivity.action.shortcut)
        ])]
        let all = VoiceActionRegistry.make(settings: settings, includeInactiveApplications: true)
        let inactive = VoiceActionRegistry.make(settings: settings, activeBundleID: "com.apple.finder")
        let active = VoiceActionRegistry.make(settings: settings, activeBundleID: "com.tinyspeck.slackmacgap")
        precondition(!inactive.contains { $0.appBundleID != nil }, "Application actions must not leak into other apps")
        precondition(active.contains { $0.id == slackActivity.id && $0.matchingDescription.contains("what did I miss") })
        precondition(!inactive.contains { $0.action == .from(shortcut: slackActivity.action.shortcut!) }, "Override outputs must not leak through recursive scanning")
        precondition(Set(all.map(\.id)).count == all.count)
        let roundtrip = try JSONDecoder().decode(StoredSettings.self, from: JSONEncoder().encode(settings))
        precondition(roundtrip.actionVocabulary == settings.actionVocabulary)
        settings.appExplorer?.voiceAutoStart = true
        let document = AppConfiguration(settings: settings, shortcuts: ShortcutConfiguration())
        let reloaded = try AppConfiguration.parse(document.yaml())
        precondition(reloaded.settings.actionVocabulary == settings.actionVocabulary, "Cloud/YAML round trip preserves every keyword set")
        precondition(reloaded.settings.appExplorer?.resolvedVoiceAutoStart == true, "Cloud/YAML round trip preserves voice auto-start")
        precondition(ActionVocabulary.parse("chat, open Slack\n\nmessages") == [["chat", "open Slack"], ["messages"]])
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
        let appRow = rows.first { $0.id == slackActivity.id }!
        precondition(appRow.group == "Applications" && appRow.subgroup == "Slack" && appRow.keywords.contains("mentions"))
        precondition(rows.contains { $0.subgroup == "Slack" && $0.keybindings == "Two-finger tap" })
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
        precondition(table.tableColumns.count == 6, "IDs must be hidden by default")
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name + ".png"))
        }
        try capture("actions-table")
        defaults.set(true, forKey: "actions.showIDs")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(table.tableColumns.count == 7, "Show IDs must reveal the seventh column")
        try capture("actions-table-ids")
        let after = try encoder.encode(store.settings)
        precondition(after == before, "Browsing the table must not change actions or assignments")
        panel.orderOut(nil); panel.close()
        print("Action table passed: scoped app defaults and overrides, vocabulary matching, JSON/YAML persistence, six/seven columns, non-mutating browsing")
    }
}
