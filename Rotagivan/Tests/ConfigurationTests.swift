import Foundation
import ConfigurationYAML

@main
struct ConfigurationTests {
    static func canonical(_ value: Any, key: String = "") -> Any {
        if let map = value as? [String: Any] {
            return map.mapValues { $0 }.reduce(into: [String: Any]()) { out, pair in
                out[pair.key] = canonical(pair.value, key: pair.key)
            }
        }
        if let list = value as? [Any] {
            if ["profileNames", "profileGestures", "sliderBaselines", "additional", "profileActions"].contains(key) {
                precondition(list.count % 2 == 0)
                var map: [String: Any] = [:]
                for i in stride(from: 0, to: list.count, by: 2) {
                    map[String(describing: list[i])] = canonical(list[i+1])
                }
                return map
            }
            if key == "customTapProfiles" { return list.map { String(describing: $0) }.sorted() }
            return list.map { canonical($0) }
        }
        return value
    }

    static func equal<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
        let a = canonical(try JSONSerialization.jsonObject(with: JSONEncoder().encode(lhs))) as! [String: Any]
        let b = canonical(try JSONSerialization.jsonObject(with: JSONEncoder().encode(rhs))) as! [String: Any]
        return NSDictionary(dictionary: a).isEqual(to: b)
    }

    static func rejected(_ text: String, _ label: String) {
        do { _ = try AppConfiguration.parse(text); fatalError("Accepted invalid config: \(label)") }
        catch { print("Rejected \(label)") }
    }

    @MainActor static func main() throws {
        let yaml = try String(contentsOfFile: "Rotagivan/DefaultConfiguration.yaml", encoding: .utf8)
        let factory = try AppConfiguration.parse(yaml)
        let exported = try factory.yaml()
        let roundtrip = try AppConfiguration.parse(exported)
        precondition(tryEqual(factory, roundtrip))
        precondition(factory.settings.defaultProfileID == 2)
        precondition(factory.shortcuts.normal.keyCode == 106)
        precondition(factory.shortcuts.normal.enabled)
        precondition(!factory.shortcuts.precision.enabled)
        precondition(factory.settings.precision.cursorResponse != nil)
        print("Passed full YAML roundtrip: profiles, recorded taps, activation/click/drag shortcuts, calibration, and general settings.")

        rejected("", "empty input")
        rejected("bad: [", "malformed YAML")
        rejected("formatVersion: 1", "missing fields")
        rejected(exported.replacingOccurrences(of: "formatVersion: 1", with: "formatVersion: 900"), "unsupported version")
        rejected(exported + "\nformatVersion: 1\n", "duplicate keys")
        rejected(exported + "\n---\nhello: world\n", "multiple documents")
        rejected("formatVersion: &version 1\nsettings: *version", "aliases")
        rejected(String(repeating: "x", count: 1_048_577), "oversized input")
        let nonfinite = exported.replacingOccurrences(of: "smoothing: [^\\n]+", with: "smoothing: .nan", options: .regularExpression)
        precondition(nonfinite != exported)
        rejected(nonfinite, "non-finite smoothing")
        rejected(exported.replacingOccurrences(of: "smoothing:", with: "smothing:"), "unknown setting")
        rejected("a: " + String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000), "excessive nesting")
        var bad = factory
        bad.settings.defaultProfileID = 999
        rejected(try ConfigurationYAML.encode(bad), "missing default profile")
        bad = factory
        bad.settings.normal.scrollMultiplier = -1
        rejected(try ConfigurationYAML.encode(bad), "negative scroll speed")
        bad = factory
        bad.settings.precision.cursorResponse!.transitionCenter = 9_000
        // CursorResponse.encode sanitizes; corrupt the raw text to test preflight.
        let invalidCenter = exported.replacingOccurrences(of: "transitionCenter: [^\\n]+",
                                                          with: "transitionCenter: 9000", options: .regularExpression)
        precondition(invalidCenter != exported)
        rejected(invalidCenter, "out-of-range center before model sanitization")
        bad = factory
        bad.shortcuts.actions.removeLast()
        rejected(try ConfigurationYAML.encode(bad), "incomplete action shortcuts")
        bad = factory
        bad.settings.additionalProfiles = [.init(id: 1, name: "Duplicate", motion: .normal)]
        rejected(try ConfigurationYAML.encode(bad), "duplicate profile IDs")

        let suite = "Rotagivan.ConfigurationTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        // Use an isolated suite; don't consult any real legacy-app domain.
        try factory.seedIfNeeded(preferences, considerLegacySettings: false)
        let store = SettingsStore(defaults: preferences, factorySettings: factory.settings)
        precondition(tryEqual(store.settings, factory.settings))
        precondition(store.activeProfileID == factory.settings.defaultProfileID)
        precondition(preferences.bool(forKey: "migration.rotagivan.cursorTransitionRange.v1"))
        let original = preferences.data(forKey: "settings.v1")
        rejected("not: valid", "invalid import leaves preferences unchanged")
        precondition(preferences.data(forKey: "settings.v1") == original)
        store.settings.normal.scrollMultiplier = 0.123
        try factory.seedIfNeeded(preferences, considerLegacySettings: false)
        let loaded = SettingsStore(defaults: preferences, factorySettings: factory.settings)
        precondition(loaded.settings.normal.scrollMultiplier == 0.123)
        loaded.reset()
        precondition(tryEqual(loaded.settings, factory.settings))
        print("Passed isolated first-launch defaults, no renormalization, existing-preference preservation, reset and invalid-import safety.")

        var multiple = factory
        multiple.settings.additionalProfiles = [.init(id: 100, name: "Quiet: #1 🧭", motion: .precision)]
        multiple.settings.profileNames?[100] = "Quiet: #1 🧭"
        multiple.shortcuts.additional[100] = ProfileShortcut(keyCode: 90, modifiers: 512, enabled: true)
        let extraRoundtrip = try AppConfiguration.parse(multiple.yaml())
        precondition(tryEqual(multiple, extraRoundtrip))
        print("Passed additional profile, Unicode name, comments, and full shortcut roundtrip.")
        for name in ["true", "null", "123", "2026-09-15", "a: b # c"] {
            multiple.settings.profileNames?[100] = name
            let decoded = try AppConfiguration.parse(multiple.yaml())
            precondition(decoded.settings.profileNames?[100] == name)
        }
        var precise = factory
        precise.settings.precision.cursorResponse!.fineGain = 0.32493574766355143
        let preciseRoundtrip = try AppConfiguration.parse(precise.yaml())
        precondition(preciseRoundtrip.settings.precision.cursorResponse!.fineGain == 0.32493574766355143)
        print("Passed ambiguous string names and exact floating-point preservation.")
    }

    static func tryEqual<T: Encodable>(_ a: T, _ b: T) -> Bool { try! equal(a, b) }
}
