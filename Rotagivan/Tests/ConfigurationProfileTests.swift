import Foundation

@main struct ConfigurationProfileTests {
    @MainActor static func main() throws {
        let suite = "Rotagivan.ProfileHierarchyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        precondition(store.configurationProfiles.count == 1 && store.activeConfigurationName == "Default")
        var keys = ShortcutConfiguration()
        keys.normal.keyCode = 100
        store.captureShortcuts = { keys }
        store.restoreShortcuts = { keys = $0 }
        store.settings.normal.cursorSpeed = 0.37
        store.settings.normal.kineticDecay = 0.91
        store.settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: "Docs", url: "https://example.com")])
        let oldMotion = store.settings.normal
        let oldExplorer = store.settings.appExplorer
        let oldLayers = store.profiles.map(\.id)
        let id = store.addConfiguration()
        precondition(store.activeConfigurationID == id && store.configurationProfiles.count == 2)
        precondition(store.settings.normal == oldMotion && store.settings.appExplorer == oldExplorer && store.profiles.map(\.id) == oldLayers)
        store.renameConfiguration("Travel")
        keys.normal.keyCode = 101
        store.settings.normal.cursorSpeed = 0.22
        store.settings.appExplorer = AppExplorerSettings(favorites: [])
        var devices = ProfileDevices()
        devices.navigatorEnabled = false
        devices.shareTapActions = false
        store.settings.devices = devices
        var shared = store.settings.gestures(for: store.defaultProfileID)
        shared.oneFingerTap = .enter
        store.updateGestures(shared, for: store.defaultProfileID)
        var apple = shared
        apple.oneFingerTap = .appExplorer
        store.updateAppleGestures(apple, for: store.defaultProfileID)
        precondition(store.activeGestures.oneFingerTap == .enter)
        precondition(store.activeGestures(for: .apple).oneFingerTap == .appExplorer)
        devices = store.settings.resolvedDevices
        devices.shareTapActions = true
        store.settings.devices = devices
        precondition(store.activeGestures(for: .apple).oneFingerTap == .enter)
        let snapshots = store.profileSnapshot()
        let settingsBeforeRename = store.settings
        precondition(store.renameConfiguration("  Home office  ", for: "default"))
        precondition(store.activeConfigurationID == id && store.activeConfigurationName == "Travel",
                     "A rename dialog must keep targeting its original profile even if selection changes")
        precondition(store.configurationProfiles.first { $0.id == "default" }?.name == "Home office")
        func sameEncoding<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
        }
        precondition(sameEncoding(store.settings, settingsBeforeRename))
        for (before, after) in zip(snapshots, store.profileSnapshot()) {
            precondition(before.id == after.id && sameEncoding(before.settings, after.settings) && sameEncoding(before.shortcuts, after.shortcuts),
                         "Renaming must not alter profile identities, pointer settings, actions or shortcuts")
        }
        precondition(!store.renameConfiguration(" \n\t "))
        precondition(!store.renameConfiguration(String(repeating: "a", count: 81)))
        precondition(!store.renameConfiguration("Missing", for: "missing"))
        precondition(store.activeConfigurationName == "Travel")
        let renamed = SettingsStore(defaults: defaults)
        precondition(renamed.configurationProfiles.first { $0.id == "default" }?.name == "Home office",
                     "Names must persist after reopening")
        precondition(renamed.renameConfiguration(String(repeating: "a", count: 80)))
        precondition(renamed.activeConfigurationName.count == 80)
        print("Profile naming passed: default/custom rename, whitespace, empty/long rejection, ID targeting, persistence and unchanged settings.")
        devices.shareTapActions = false
        store.settings.devices = devices
        precondition(store.activeGestures(for: .apple).oneFingerTap == .appExplorer, "Sharing must preserve disabled overrides")
        store.selectConfiguration("default")
        precondition(keys.normal.keyCode == 100)
        precondition(store.settings.normal == oldMotion && store.settings.appExplorer == oldExplorer)
        precondition(store.settings.resolvedDevices.navigatorEnabled)
        store.selectConfiguration(id)
        precondition(keys.normal.keyCode == 101 && store.activeConfigurationName == "Travel")
        precondition(store.settings.normal.cursorSpeed == 0.22 && !store.settings.resolvedDevices.navigatorEnabled)
        let reopened = SettingsStore(defaults: defaults)
        precondition(reopened.activeConfigurationID == id && reopened.activeConfigurationName == "Travel")
        precondition(reopened.settings.normal.cursorSpeed == 0.22 && reopened.activeGestures(for: .apple).oneFingerTap == .appExplorer)
        reopened.selectConfiguration("default")
        precondition(reopened.settings.normal == oldMotion && reopened.settings.appExplorer == oldExplorer)
        let before = store.activeConfigurationID
        store.selectConfiguration("missing")
        precondition(store.activeConfigurationID == before)
        store.updateAppleGestures(nil, for: store.defaultProfileID)
        precondition(store.activeGestures(for: .apple).oneFingerTap == .enter)
        print("Profile hierarchy passed: legacy migration, full-copy creation, isolated settings/Explorer/shortcuts, device sharing/overrides, reload, invalid selection and override reset.")
    }
}
