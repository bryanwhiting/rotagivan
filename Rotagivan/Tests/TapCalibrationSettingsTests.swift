import Foundation

@main struct TapCalibrationSettingsTests {
    @MainActor static func main() throws {
        let suite = "Rotagivan.SharedCalibration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        store.settings = StoredSettings()
        store.settings.customTapProfiles = [2]
        var custom = store.settings.gestures(for: 2)
        custom.oneFingerTap = .rightClick
        custom.gestures.doubleTapInterval = 0.5
        custom.singleTapSwipe = .singleTapDefaults
        custom.singleTapSwipe?.enabled = true
        custom.singleTapSwipe?.swipeDistance = 120
        custom.singleTapSwipe?.left = RecordedShortcut(keyCode: 8, modifiers: 0, keyLabel: "C")
        store.updateGestures(custom, for: 2)
        precondition(store.gestures(for: 2, device: .navigator) == custom, "Old uncalibrated layer tuning is unchanged")
        let learned = TapCalibrationSettings(doubleTapInterval: 0.18,
            tripleTapFirstInterval: 0.19, tripleTapSecondInterval: 0.21,
            singleSwipeWindow: 0.25, singleSwipeDuration: 0.12, doubleSwipeWindow: 0.3)
        store.updateTapCalibration(learned, for: .navigator)
        for id: UInt32 in [1, 2] {
            store.setActiveProfile(id)
            let taps = store.activeGestures
            precondition(taps.gestures.doubleTapInterval == 0.18)
            precondition(taps.gestures.tripleTapFirstInterval == 0.19 && taps.gestures.tripleTapSecondInterval == 0.21)
            precondition(taps.singleTapSwipe?.swipeWindow == 0.25 && taps.singleTapSwipe?.fastSwipeDuration == 0.12)
            precondition(taps.doubleTapSwipe?.swipeWindow == 0.3)
        }
        let resolved = store.gestures(for: 2, device: .navigator)
        precondition(resolved.oneFingerTap == .rightClick && resolved.singleTapSwipe?.left == custom.singleTapSwipe?.left)
        precondition(resolved.singleTapSwipe?.enabled == true && resolved.singleTapSwipe?.swipeDistance == 120)
        precondition(store.settings.gestures(for: 2) == custom, "Calibration never rewrites action-layer data")
        store.settings.additionalProfiles = [AdditionalProfile(id: 100, name: "New", motion: .normal)]
        store.settings.customTapProfiles?.insert(100)
        precondition(store.gestures(for: 100, device: .navigator).gestures.doubleTapInterval == 0.18)
        store.makeDefault(2)
        precondition(store.gestures(for: 1, device: .navigator).gestures.doubleTapInterval == 0.18)
        store.updateTapCalibration(TapCalibrationSettings(doubleTapInterval: 0.24), for: .apple)
        for shared in [true, false] {
            store.settings.devices = ProfileDevices(shareTapActions: shared, appleLayerGestures: [2: custom])
            for id: UInt32 in [1, 2, 100] {
                precondition(store.gestures(for: id, device: .apple).gestures.doubleTapInterval == 0.24)
                precondition(store.gestures(for: id, device: .navigator).gestures.doubleTapInterval == 0.18)
            }
        }
        let originalID = store.activeConfigurationID
        store.addConfiguration()
        store.updateTapCalibration(TapCalibrationSettings(doubleTapInterval: 0.4), for: .navigator)
        store.selectConfiguration(originalID)
        precondition(store.tapCalibration(for: .navigator) == learned, "Separate top-level profiles keep their own calibration")
        let reloaded = SettingsStore(defaults: defaults)
        precondition(reloaded.tapCalibration(for: .navigator) == learned, "Calibration persists across relaunch")
        let restored = try JSONDecoder().decode(StoredSettings.self, from: JSONEncoder().encode(store.settings))
        precondition(restored.navigatorTapCalibration == learned)
        print("Shared calibration passed: custom/future layers, actions preserved, device isolation, defaults, profile switching and persistence")
    }
}
