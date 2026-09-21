import Foundation

@main struct PointerProfileTests {
    @MainActor static func main() throws {
        let suite = "Rotagivan.PointerProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var legacy = StoredSettings()
        legacy.normal.cursorSpeed = 0.12
        legacy.precision.cursorSpeed = 0.38
        legacy.precision.kineticDecay = 0.82
        legacy.defaultProfileID = 2
        let extra = AdditionalProfile(id: 100, name: "Actions", motion: .normal)
        legacy.additionalProfiles = [extra]
        store.replaceSettings(legacy)
        let original = legacy.precision
        let baseline = legacy.resolvedPointerCoastBaseline
        for id: UInt32 in [1, 2, 100] {
            store.setActiveProfile(id)
            precondition(store.activeProfile == original, "Action layers always use the top-level profile response")
        }
        store.makeDefault(100)
        precondition(store.defaultProfileID == 100 && store.activeProfile == original)
        precondition(store.settings.resolvedPointerCoastBaseline == baseline)
        precondition(store.settings.normal == legacy.normal && store.settings.precision == legacy.precision,
                     "Legacy tuning is preserved, not destructively flattened")
        var edited = original
        edited.cursorResponse = CursorResponse(legacy: original)
        edited.scrollResponse = ScrollResponse(slowMultiplier: 0.2, fastMultiplier: 1.8, transitionSpeed: 900)
        edited.invertScrollX = true
        store.updatePointerMotion(edited)
        store.setActiveProfile(1)
        precondition(store.activeProfile == edited)
        let id = store.addConfiguration()
        precondition(store.activeProfile == edited, "New full profiles copy shared motion")
        var second = edited
        second.cursorSpeed = 0.15
        second.scrollResponse?.fastMultiplier = 0.7
        store.updatePointerMotion(second)
        store.setActiveProfile(2)
        precondition(store.activeProfile == second)
        store.selectConfiguration("default")
        precondition(store.activeProfile == edited, "Different top-level profiles keep independent mouse tuning")
        store.selectConfiguration(id)
        let reopened = SettingsStore(defaults: defaults)
        precondition(reopened.activeProfile == second && reopened.settings.resolvedPointerCoastBaseline == baseline)
        let json = try JSONEncoder().encode(reopened.settings)
        let roundtrip = try JSONDecoder().decode(StoredSettings.self, from: json)
        precondition(roundtrip.resolvedPointerMotion == second)
        // A legacy default can be an additional layer, not just Normal/Precision.
        var old = legacy
        old.defaultProfileID = 100
        precondition(old.resolvedPointerMotion == extra.motion)
        old.makeDefault(1)
        precondition(old.resolvedPointerMotion == extra.motion)
        print("Pointer profiles passed: default-tuning compatibility, layer independence, stable default changes, full-profile copy/switch, persistence and no legacy data loss")
    }
}
