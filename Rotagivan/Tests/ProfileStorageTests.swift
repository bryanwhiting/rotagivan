import Foundation

@main
struct ProfileStorageTests {
    static func main() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var settings = StoredSettings()
        settings.normal.cursorSpeed = 0.37
        // Legacy data has no additionalProfiles key.
        let legacy = try decoder.decode(StoredSettings.self, from: encoder.encode(settings))
        precondition(legacy.additionalProfiles == nil && legacy.normal.cursorSpeed == 0.37 && legacy.globalLimits == nil)
        let cursorScale = SettingsScale.linear(minimum: 0, maximum: 3)
        precondition(cursorScale.value(for: 0) == 0)
        precondition(cursorScale.value(for: 100) == 3)
        precondition(cursorScale.percentage(for: 1.5) == 50)
        let momentumScale = SettingsScale.momentum(maximum: 0.995)
        precondition(momentumScale.value(for: 0) == 0)
        precondition(abs(momentumScale.value(for: 100) - 0.995) < 0.000_001)
        precondition(momentumScale.value(for: 75) > 0.97)
        precondition(momentumScale.percentage(for: 0.75) < 10)
        print("0–100 scale tests passed: true zero speeds, upper bounds, curved momentum mapping.")
        var limits = GlobalLimits()
        precondition(limits.cursorSpeedMaximum == 3 && limits.scrollSpeedMaximum == 6)
        precondition(abs(limits.momentumMaximum - 0.995) < 0.000_001)
        limits.cursorSpeedCeiling = 0
        limits.scrollSpeedCeiling = 0
        limits.momentumCeiling = 0
        precondition(limits.cursorSpeedMaximum == 0 && limits.scrollSpeedMaximum == 0 && limits.momentumMaximum == 0)
        limits.cursorSpeedCeiling = 100
        limits.scrollSpeedCeiling = 100
        limits.momentumCeiling = 100
        precondition(limits.cursorSpeedMaximum == 6 && limits.scrollSpeedMaximum == 12)
        let persistedLimits = try decoder.decode(GlobalLimits.self, from: encoder.encode(limits))
        precondition(persistedLimits == limits)
        print("Global-limit tests passed: default caps, true zero ceilings, upper ceilings, persistence.")
        settings.additionalProfiles = [AdditionalProfile(id: 100, name: "Profile 3", motion: settings.normal)]
        settings.additionalProfiles?[0].motion.cursorSpeed = 0.75
        let restored = try decoder.decode(StoredSettings.self, from: encoder.encode(settings))
        precondition(restored.additionalProfiles?.first?.id == 100)
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
    }
}
