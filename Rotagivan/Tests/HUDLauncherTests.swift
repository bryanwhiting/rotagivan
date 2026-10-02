import Foundation

@main struct HUDLauncherTests {
    @MainActor static func main() throws {
        let launcher = ActionBinding.defaultHUDLauncher
        precondition(launcher.isValid && launcher.trigger.keyboard!.isValidGlobalHotkey)
        precondition(launcher.trigger.keyboard!.keyCode == 49 && launcher.trigger.keyboard!.modifiers == 1 << 19)
        var fresh = StoredSettings()
        precondition(fresh.installDefaultHUDLauncher())
        precondition(!fresh.installDefaultHUDLauncher(), "Do not duplicate the launch binding")
        let restored = try JSONDecoder().decode(StoredSettings.self, from: JSONEncoder().encode(fresh))
        precondition(restored.actionBindings == fresh.actionBindings, "Launcher must survive settings sync")
        var occupied = StoredSettings()
        occupied.actionBindings = [ActionBinding(trigger: launcher.trigger, action: .media(.mute))]
        precondition(!occupied.installDefaultHUDLauncher(), "Never take over another action's key")
        var repurposed = StoredSettings()
        var edited = launcher
        edited.trigger.keyboard?.keyCode = 8
        edited.trigger.keyboard?.keyLabel = "C"
        edited.action = .media(.mute)
        repurposed.actionBindings = [edited]
        precondition(!repurposed.installDefaultHUDLauncher(), "Preserve an edited default without duplicate IDs")
        var custom = StoredSettings()
        custom.actionBindings = [ActionBinding(trigger: BindingTrigger(keyboard:
            RecordedShortcut(keyCode: 49, modifiers: 1 << 20, keyLabel: "Space")), action: .tap(.appExplorer))]
        precondition(!custom.installDefaultHUDLauncher(), "Preserve a custom HUD launch key")
        var reserved = StoredSettings()
        precondition(!reserved.installDefaultHUDLauncher(reservedKeys: [launcher.trigger.keyboard!.identity]))
        let suite = "Rotagivan.HUDLauncher.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defaults.set(try JSONEncoder().encode(StoredSettings()), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        precondition(store.settings.actionBindings?.contains(launcher) == true)
        store.settings.actionBindings = []
        let reopened = SettingsStore(defaults: defaults)
        precondition(reopened.settings.actionBindings == [], "Removing the default must survive restart")
        print("HUD launcher PASS: default, sync round-trip, conflicts, custom keys, and removal persistence")
    }
}
