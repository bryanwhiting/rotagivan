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
        var withSingleSwipe = factory
        withSingleSwipe.settings.appExplorer = AppExplorerSettings(defaultMode: .favorites,
            favorites: [AppExplorerFavorite(direction: .topLeft, bundleID: "com.apple.Safari", name: "Safari")],
            holdShortcut: RecordedShortcut(keyCode: 64, modifiers: 1 << 19, keyLabel: "F17"))
        withSingleSwipe.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .right, name: "Project docs", url: "https://example.com/docs?q=hello%20world#intro"), at: .right)
        withSingleSwipe.settings.precision.scrollResponse = ScrollResponse(slowMultiplier:0.25,fastMultiplier:2.5,transitionSpeed:1300)
        withSingleSwipe.settings.appOverrides = [.chrome]
        var gestures = withSingleSwipe.settings.gestures(for: 1)
        gestures.singleTapSwipe = .singleTapDefaults
        gestures.singleTapSwipe!.enabled = true
        gestures.singleTapSwipe!.fastSwipeDuration = 0.125
        gestures.singleTapSwipe!.topRight = RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17")
        gestures.singleTapSwipe!.setAction(.appExplorer, for: .down)
        gestures.twoFingerSingleTapSwipe = gestures.singleTapSwipe
        gestures.twoFingerDoubleTapSwipe = DoubleTapSwipeSettings(enabled: true)
        gestures.twoFingerDoubleTapSwipe!.bottomLeft = RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17")
        gestures.oneFingerDoubleTap = .appExplorer
        gestures.gestures.tripleTapFirstInterval = 0.14
        gestures.gestures.tripleTapSecondInterval = 0.24
        withSingleSwipe.settings.profileGestures?[1] = gestures
        let singleSwipeYAML = try withSingleSwipe.yaml()
        let singleSwipeRoundtrip = try AppConfiguration.parse(singleSwipeYAML)
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).twoFingerSingleTapSwipe == gestures.twoFingerSingleTapSwipe)
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).twoFingerDoubleTapSwipe == gestures.twoFingerDoubleTapSwipe)
        var invalidPair = withSingleSwipe
        invalidPair.settings.profileGestures?[1]?.twoFingerDoubleTapSwipe?.swipeDistance = 999
        rejected(try ConfigurationYAML.encode(invalidPair), "out-of-range two-finger swipe distance")
        precondition(singleSwipeRoundtrip.settings.appExplorer == withSingleSwipe.settings.appExplorer)
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).gestures.tripleTapSecondInterval == 0.24)
        precondition(singleSwipeRoundtrip.settings.effectiveGestures(for: 2).gestures.tripleTapSecondInterval == withSingleSwipe.settings.effectiveGestures(for: 2).gestures.tripleTapSecondInterval)
        var invalidExplorer = withSingleSwipe
        invalidExplorer.settings.appExplorer!.favorites.append(invalidExplorer.settings.appExplorer!.favorites[0])
        rejected(try ConfigurationYAML.encode(invalidExplorer), "duplicate explorer slot")
        for destination in ["file:///tmp/unsafe", "javascript:alert(1)", "https://user:password@example.com", "https://"] {
            var invalid = withSingleSwipe
            invalid.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .right, name: "Invalid", url: destination), at: .right)
            rejected(try ConfigurationYAML.encode(invalid), "unsafe or invalid favorite URL")
        }
        var ambiguousFavorite = withSingleSwipe
        ambiguousFavorite.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .right, bundleID: "com.apple.Safari", name: "Ambiguous", url: "https://example.com"), at: .right)
        rejected(try ConfigurationYAML.encode(ambiguousFavorite), "favorite with both app and URL")
        var longLink = withSingleSwipe
        longLink.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .right, name: "Long link", url: "https://example.com/?q=" + String(repeating: "a", count: 600)), at: .right)
        let longRestored = try AppConfiguration.parse(longLink.yaml())
        precondition(longRestored.settings.appExplorer == longLink.settings.appExplorer)
        var invalidTriple = withSingleSwipe
        invalidTriple.settings.profileGestures?[1]?.gestures.tripleTapSecondInterval = 0.9
        rejected(try ConfigurationYAML.encode(invalidTriple), "triple-tap timing outside bounds")
        precondition(singleSwipeRoundtrip.settings.precision.scrollResponse == withSingleSwipe.settings.precision.scrollResponse)
        var invalidScroll = withSingleSwipe
        invalidScroll.settings.precision.scrollResponse = ScrollResponse(slowMultiplier:3,fastMultiplier:1)
        rejected(try ConfigurationYAML.encode(invalidScroll), "scroll slow speed above fast speed")
        invalidScroll.settings.precision.scrollResponse = ScrollResponse(slowMultiplier:0,fastMultiplier:7)
        rejected(try ConfigurationYAML.encode(invalidScroll), "scroll curve exceeds maximum")
        invalidScroll.settings.precision.scrollResponse = ScrollResponse(slowMultiplier:0,fastMultiplier:1,transitionSpeed:0)
        rejected(try ConfigurationYAML.encode(invalidScroll), "invalid scroll transition")
        precondition(singleSwipeRoundtrip.settings.appOverrides == [.chrome])
        var invalidApp = withSingleSwipe
        invalidApp.settings.appOverrides = [.chrome, .chrome]
        rejected(try ConfigurationYAML.encode(invalidApp), "duplicate app overrides")
        invalidApp.settings.appOverrides = [AppGestureOverride(bundleID:"test.app",name:"Test",bindings:[AppGestureBinding(trigger:.oneFingerTap,action:.shortcut)])]
        rejected(try ConfigurationYAML.encode(invalidApp), "app keyboard override missing shortcut")
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).singleTapSwipe == gestures.singleTapSwipe)
        rejected(singleSwipeYAML.replacingOccurrences(of: "fastSwipeDuration: 0.125", with: "fastSwipeDuration: 0.5"), "slow single-swipe duration")
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
        var swipes = factory
        var taps = swipes.settings.gestures(for: swipes.settings.resolvedDefaultProfileID)
        taps.doubleTapSwipe = DoubleTapSwipeSettings(enabled: true,
            left: RecordedShortcut(keyCode: 123, modifiers: 1048576, keyLabel: "Left arrow"),
            up: RecordedShortcut(keyCode: 126, modifiers: 0, keyLabel: "Up arrow"))
        let swipeProfileID = swipes.settings.resolvedDefaultProfileID
        swipes.settings.profileGestures?[swipeProfileID] = taps
        let swipeYAML = try swipes.yaml()
        let swipeRoundtrip = try AppConfiguration.parse(swipeYAML)
        precondition(tryEqual(swipes, swipeRoundtrip))
        rejected(swipeYAML.replacingOccurrences(of: "swipeWindow: [^\\n]+", with: "swipeWindow: 99", options: .regularExpression), "out-of-range swipe window")
        print("Passed double-tap swipe settings and shortcut YAML roundtrip.")
        // Old configurations still load without adding any diagonal bindings.
        let legacySwipe = swipeRoundtrip.settings.gestures(for: swipeProfileID).doubleTapSwipe!
        precondition(legacySwipe.topLeft == nil && legacySwipe.topRight == nil && legacySwipe.bottomLeft == nil && legacySwipe.bottomRight == nil)
        for (index, direction) in [SwipeDirection.topLeft, .topRight, .bottomLeft, .bottomRight].enumerated() {
            taps.doubleTapSwipe![direction] = RecordedShortcut(keyCode: UInt16(18 + index), modifiers: 1048576, keyLabel: direction.title)
        }
        taps.oneFingerTap = .doubleLeftClick
        taps.twoFingerDoubleTap = .doubleLeftClick
        swipes.settings.profileGestures?[swipeProfileID] = taps
        let expandedYAML = try swipes.yaml()
        let expandedRoundtrip = try AppConfiguration.parse(expandedYAML)
        precondition(tryEqual(swipes, expandedRoundtrip))
        precondition(expandedRoundtrip.settings.gestures(for: swipeProfileID).oneFingerTap == .doubleLeftClick)
        var invalidDiagonal = swipes
        invalidDiagonal.settings.profileGestures?[swipeProfileID]?.doubleTapSwipe?.topLeft?.keyCode = 999
        rejected(try ConfigurationYAML.encode(invalidDiagonal), "invalid diagonal shortcut key code")
        print("Passed four diagonal bindings, double-left-click actions, legacy defaults, and YAML roundtrip.")
        precondition(swipeRoundtrip.settings.gestures(for: swipeProfileID).gestures.resolvedKeepCursorStillForTaps)
        for enabled in [false, true] {
            swipes.settings.profileGestures?[swipeProfileID]?.gestures.keepCursorStillForTaps = enabled
            let stationaryRoundtrip = try AppConfiguration.parse(swipes.yaml())
            precondition(tryEqual(swipes, stationaryRoundtrip))
            precondition(stationaryRoundtrip.settings.gestures(for: swipeProfileID).gestures.resolvedKeepCursorStillForTaps == enabled)
        }
        print("Passed stationary-tap YAML opt-in, opt-out, and legacy default.")
        precondition(swipeRoundtrip.settings.gestures(for: swipeProfileID).oneFingerTripleTap == nil)
        swipes.settings.profileGestures?[swipeProfileID]?.oneFingerTripleTap = .tripleLeftClick
        swipes.settings.profileGestures?[swipeProfileID]?.twoFingerTripleTap = .shortcut
        swipes.settings.profileGestures?[swipeProfileID]?.twoFingerTripleShortcut = RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return")
        let tripleRoundtrip = try AppConfiguration.parse(swipes.yaml())
        precondition(tryEqual(swipes, tripleRoundtrip))
        swipes.settings.profileGestures?[swipeProfileID]?.twoFingerTripleShortcut = nil
        rejected(try ConfigurationYAML.encode(swipes), "triple tap shortcut missing its key binding")
        print("Triple-tap actions, shortcut YAML roundtrip, legacy defaults and validation passed.")
    }

    static func tryEqual<T: Encodable>(_ a: T, _ b: T) -> Bool { try! equal(a, b) }
}
