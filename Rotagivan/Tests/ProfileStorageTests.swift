import Foundation

@main
struct ProfileStorageTests {
    @MainActor static func main() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var settings = StoredSettings()
        var timing = GestureSettings()
        precondition(timing.resolvedDoubleTapInterval == 0.30)
        timing.doubleTapInterval = 0.12
        precondition(timing.resolvedDoubleTapInterval == 0.12)
        timing.doubleTapInterval = 2
        precondition(timing.resolvedDoubleTapInterval == 0.6)
        print("Double-tap delay tests passed: legacy default, persistence value and safe bounds.")
        precondition(settings.normal == MotionProfile(cursorSpeed: 0.28, cursorAcceleration: 1.37, scrollMultiplier: 1.0, invertScrollX: false, invertScrollY: false, kineticScroll: true, kineticDecay: 0.75))
        precondition(settings.precision == MotionProfile(cursorSpeed: 0.25, cursorAcceleration: 1.0, scrollMultiplier: 0.1656, invertScrollX: false, invertScrollY: false, kineticScroll: true, kineticDecay: 0.9423446))
        precondition(settings.normal.resolvedCursorFalloff == 0)
        settings.normal.cursorDeceleration = 0.85
        precondition(settings.normal.resolvedCursorFalloff == 0.85)
        settings.normal.cursorDeceleration = 1
        precondition(settings.normal.resolvedCursorFalloff == ProfileMaximum.cursorFalloff)
        print("Cursor falloff tests passed: legacy default, persistence and safe maximum.")
        precondition(settings.normal.resolvedScrollAcceleration == 1)
        settings.normal.scrollAcceleration = 1.3
        precondition(settings.normal.resolvedScrollAcceleration == 1.3)
        print("Scroll acceleration tests passed: legacy neutral default and profile persistence.")
        print("Current motion defaults passed: Normal and Precision match the tuned profiles.")
        settings.normal.cursorSpeed = 0.37
        // Legacy data has no additionalProfiles key.
        let legacy = try decoder.decode(StoredSettings.self, from: encoder.encode(settings))
        precondition(legacy.additionalProfiles == nil && legacy.normal.cursorSpeed == 0.37)
        let cursorScale = SettingsScale.linear(minimum: 0, maximum: ProfileMaximum.cursorSpeed)
        precondition(cursorScale.value(for: 0) == 0)
        precondition(cursorScale.value(for: 100) == ProfileMaximum.cursorSpeed)
        precondition(cursorScale.percentage(for: 1.2) == 50)
        let momentumScale = SettingsScale.momentum(maximum: ProfileMaximum.coastCoefficient)
        precondition(momentumScale.value(for: 0) == 0)
        precondition(abs(momentumScale.value(for: 100) - 1) < 0.000_001)
        precondition(momentumScale.value(for: 75) > 0.97)
        precondition(momentumScale.percentage(for: 0.75) < 10)
        print("0–100 scale tests passed: true zero speeds, upper bounds, curved coast-coefficient mapping.")
        precondition(ProfileMaximum.scrollSpeed == 6 && ProfileMaximum.scrollAcceleration == 1.5 && ProfileMaximum.coastCoefficient == 1)
        precondition(ProfileMaximum.cursorSpeed == 2.4 && ProfileMaximum.cursorAcceleration == 1.4 && ProfileMaximum.cursorAccelerationOnset == 6 && ProfileMaximum.cursorFalloff == 0.85)
        print("Fixed profile maximum tests passed: direct 0–100 controls, true zero and built-in upper bounds.")
        settings.additionalProfiles = [AdditionalProfile(id: 100, name: "Profile 3", motion: settings.normal)]
        settings.additionalProfiles?[0].motion.cursorSpeed = 0.75
        let restored = try decoder.decode(StoredSettings.self, from: encoder.encode(settings))
        precondition(restored.additionalProfiles?.first?.id == 100)
        precondition(restored.additionalProfiles?.first?.name == "Profile 3", "User-chosen legacy names must not be renamed")
        precondition(restored.additionalProfiles?.first?.motion.cursorSpeed == 0.75)
        precondition(restored.normal.cursorSpeed == 0.37)
        settings.profileNames = [1: "Everyday", 2: "Fine control", 100: "Design"]
        let renamed = try decoder.decode(StoredSettings.self, from: encoder.encode(settings))
        precondition(renamed.profileName(for: 1, fallback: "Normal") == "Everyday")
        precondition(renamed.profileName(for: 2, fallback: "Precision") == "Fine control")
        precondition(renamed.profileName(for: 100, fallback: "Profile 3") == "Design")
        precondition(renamed.additionalProfiles?.first?.id == 100)
        precondition(legacy.profileName(for: 1, fallback: "Normal") == "Normal")
        settings.profileNames?[1] = "  "
        precondition(settings.profileName(for: 1, fallback: "Normal") == "Normal")
        settings.gestures.tapMaxDuration = 0.31
        settings.oneFingerTap = .leftClick
        precondition(settings.oneFingerTap?.supportsTapAndHoldDrag == true)
        precondition(TapAction.rightClick.supportsTapAndHoldDrag == false)
        precondition(TapAction.shortcut.supportsTapAndHoldDrag == false)
        precondition(settings.gestures(for: 100).gestures.tapMaxDuration == 0.31)
        precondition(settings.gestures(for: 2).oneFingerTap == .leftClick)
        var custom = settings.gestures(for: 100)
        custom.gestures.tapMaxDuration = 0.18
        custom.gestures.dragRegrip = false
        custom.twoFingerTap = .rightClick
        settings.profileGestures = [100: custom]
        settings.profileGestures?[100]?.oneFingerTap = .shortcut
        settings.profileGestures?[100]?.oneFingerShortcut = RecordedShortcut(keyCode: 80, modifiers: 524288, keyLabel: "F19")
        let gestures = try decoder.decode(StoredSettings.self, from: encoder.encode(settings))
        precondition(gestures.gestures(for: 100).gestures.tapMaxDuration == 0.18)
        precondition(!gestures.gestures(for: 100).gestures.dragRegrip)
        precondition(gestures.gestures(for: 100).twoFingerTap == .rightClick)
        precondition(gestures.gestures(for: 100).oneFingerTap == .shortcut)
        precondition(gestures.gestures(for: 100).oneFingerShortcut?.keyCode == 80)
        precondition(gestures.gestures(for: 100).oneFingerShortcut?.modifiers == 524288)
        precondition(gestures.gestures(for: 1).oneFingerShortcut == nil)
        precondition(gestures.gestures(for: 1).gestures.tapMaxDuration == 0.31)
        precondition(gestures.gestures(for: 1).gestures.dragRegrip)
        // Older settings decode without the new optional double-tap fields.
        precondition(gestures.gestures(for: 1).oneFingerDoubleTap == nil)
        precondition(gestures.gestures(for: 1).twoFingerDoubleTap == nil)
        var doubleTap = gestures.gestures(for: 1)
        doubleTap.oneFingerDoubleTap = .shortcut
        doubleTap.oneFingerDoubleShortcut = RecordedShortcut(keyCode: 64, modifiers: 1572864, keyLabel: "F17")
        doubleTap.twoFingerDoubleTap = .enter
        let doubleTapRestored = try decoder.decode(ProfileGestures.self, from: encoder.encode(doubleTap))
        precondition(doubleTapRestored.oneFingerDoubleTap == .shortcut)
        precondition(doubleTapRestored.oneFingerDoubleShortcut?.displayName == "⌥⌘F17")
        precondition(doubleTapRestored.twoFingerDoubleTap == .enter)
        print("Double-tap settings passed: legacy decode, one/two-finger actions, shortcut persistence.")
        var inherited = gestures
        precondition(inherited.effectiveGestures(for: 100).oneFingerTap == .leftClick)
        precondition(inherited.effectiveGestures(for: 100).gestures.tapMaxDuration == 0.31)
        precondition(!inherited.effectiveGestures(for: 100).gestures.dragRegrip) // Dragging remains independent.
        inherited.profileGestures?[1] = ProfileGestures(gestures: GestureSettings(), oneFingerTap: .enter, twoFingerTap: .none)
        precondition(inherited.effectiveGestures(for: 100).oneFingerTap == .enter)
        inherited.customTapProfiles = [100]
        precondition(inherited.effectiveGestures(for: 100).oneFingerTap == .shortcut)
        precondition(inherited.effectiveGestures(for: 100).gestures.tapMaxDuration == 0.18)
        precondition(inherited.effectiveGestures(for: 2).oneFingerTap == .enter)
        let inheritedRestored = try decoder.decode(StoredSettings.self, from: encoder.encode(inherited))
        precondition(inheritedRestored.customTapProfiles == [100])
        inherited.customTapProfiles = []
        precondition(inherited.effectiveGestures(for: 100).oneFingerTap == .enter)
        print("Tap inheritance passed: live default updates, opt-in overrides, opt-out restoration, independent drag settings, persistence.")
        inherited.customTapProfiles = [100]
        inherited.makeDefault(100)
        precondition(inherited.resolvedDefaultProfileID == 100)
        precondition(inherited.effectiveGestures(for: 100).oneFingerTap == .shortcut)
        precondition(inherited.effectiveGestures(for: 2).oneFingerTap == .shortcut)
        precondition(inherited.effectiveGestures(for: 1).oneFingerTap == .enter)
        inherited.makeDefault(2) // Inherited values are materialized when promoted.
        precondition(inherited.effectiveGestures(for: 2).oneFingerTap == .shortcut)
        precondition(inherited.customTapProfiles?.contains(100) == true)
        let promoted = try decoder.decode(StoredSettings.self, from: encoder.encode(inherited))
        precondition(promoted.resolvedDefaultProfileID == 2)
        inherited.makeDefault(999)
        precondition(inherited.resolvedDefaultProfileID == 2)
        precondition(legacy.resolvedDefaultProfileID == 1)
        print("Default promotion passed: inheritance, previous-default preservation, persistence, invalid IDs, legacy migration.")
        print("Profile gestures passed: legacy inheritance, independent tapping/dragging, persistence.")
        print("Profile naming tests passed: built-in and custom names, persistence, legacy and blank-name fallbacks.")
        print("Profile storage tests passed: legacy decoding, additional-profile round trip, independent settings.")
        let suite = "Rotagivan.LayerNamingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.settings = StoredSettings()
        let added = store.addProfile()
        precondition(store.profiles.first { $0.id == added }?.name == "Layer 3")
        let saved = try JSONSerialization.jsonObject(with: encoder.encode(store.settings)) as! [String: Any]
        precondition(saved["additionalProfiles"] != nil && saved["additionalLayers"] == nil, "Keep existing YAML and sync schema")
        let savedModel = try decoder.decode(StoredSettings.self, from: encoder.encode(store.settings))
        precondition(savedModel.additionalProfiles?.first?.name == "Layer 3")
        print("Layer terminology passed: new default names, preserved legacy names and unchanged storage keys.")
    }
}
