import Foundation
import Combine

@main
struct CursorTelemetryTests {
    @MainActor static func main() throws {
        // Exercise the real SettingsStore in an isolated preferences domain.
        let domain = "local.rotagivan.tests.telemetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defaults.set(try JSONEncoder().encode(StoredSettings()), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settingsBefore = try encoder.encode(store.settings)
        let preferencesBefore = defaults.data(forKey: "settings.v1")
        var notifications = 0
        let observation = store.objectWillChange.sink { notifications += 1 }
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0..<50_000 {
            store.cursorTelemetry.record(CursorSample(profileID: 1, speed: Double(index), gain: 0.5, touching: true))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        precondition(store.cursorTelemetry.latest.speed == 49_999, "Preview must take the newest sample, without a backlog")
        store.cursorTelemetry.endTouch()
        precondition(!store.cursorTelemetry.latest.touching)
        store.cursorTelemetry.reset()
        precondition(store.cursorTelemetry.latest == CursorSample())
        precondition(notifications == 0, "Input must not invalidate the settings views")
        let settingsAfter = try encoder.encode(store.settings)
        precondition(settingsAfter == settingsBefore, "Preview must not change tuning")
        precondition(defaults.data(forKey: "settings.v1") == preferencesBefore, "Input must not write preferences")
        // Prove that the subscription is live and actual settings still notify.
        store.settings.enabled.toggle()
        precondition(notifications > 0)
        observation.cancel()
        print("Passed 50,000 samples: zero settings notifications, zero preference writes, latest-value delivery, release/reset.")
        print("Telemetry recording time: \(String(format: "%.2f", elapsed * 1_000)) ms total (not a UI frame-time measurement).")
    }
}
