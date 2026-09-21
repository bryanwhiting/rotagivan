import Foundation
import ConfigurationYAML

extension ShortcutConfiguration {
    @MainActor init(_ source: ShortcutSettings) {
        normal = source.normal; precision = source.precision
        actions = source.actions; additional = source.additional
        profileActions = source.profileActions
        holdToActivate = UserDefaults.standard.object(forKey: "shortcut.hold") as? Bool ?? true
    }

    func preferences() throws -> [String: Any] {
        let encoder = JSONEncoder()
        var result: [String: Any] = [
            "shortcut.normal": try encoder.encode(normal),
            "shortcut.precision": try encoder.encode(precision),
            "shortcut.additional": try encoder.encode(additional),
            "shortcut.profileActions": try encoder.encode(profileActions),
            "shortcut.hold": holdToActivate
        ]
        for (index, action) in actions.enumerated() {
            result["shortcut.action.\(index + 3)"] = try encoder.encode(action)
        }
        return result
    }
}

struct AppConfiguration: Codable {
    var formatVersion = 1
    var settings: StoredSettings
    var shortcuts: ShortcutConfiguration
    var profiles: [ConfigurationProfile]? = nil
    var activeConfigurationID: String? = nil

    @MainActor init(store: SettingsStore) {
        settings = store.settings
        shortcuts = ShortcutConfiguration(.shared)
        profiles = store.profileSnapshot(shortcuts: shortcuts)
        activeConfigurationID = store.activeConfigurationID
    }

    init(settings: StoredSettings, shortcuts: ShortcutConfiguration) {
        self.settings = settings
        self.shortcuts = shortcuts
    }

    static func parse(_ yaml: String) throws -> Self {
        // Inspect numeric values BEFORE model decoding, which may sanitize
        // old cursor curves. Invalid imports must not silently change values.
        let raw = try ConfigurationYAML.decode(ConfigurationValue.self, from: yaml)
        try raw.validate()
        let result = try ConfigurationYAML.decode(Self.self, from: yaml)
        try result.validate()
        return result
    }

    func yaml() throws -> String {
        try validate()
        return "# Rotagivan complete configuration\n# Engine units, not slider percentages. Permissions and signing are excluded.\n"
            + (try ConfigurationYAML.encode(self))
    }

    static func factory(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "DefaultConfiguration", withExtension: "yaml") else {
            throw ConfigurationError("The bundled default configuration is missing.")
        }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    func validate() throws {
        if let profiles {
            guard !profiles.isEmpty, profiles.count <= 20, Set(profiles.map(\.id)).count == profiles.count,
                  profiles.contains(where: { $0.id == activeConfigurationID }),
                  profiles.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 }) else {
                throw ConfigurationError("Profiles need unique IDs, names, and a valid active profile (maximum 20).")
            }
            for profile in profiles { try AppConfiguration(settings: profile.settings, shortcuts: profile.shortcuts).validate() }
        } else if activeConfigurationID != nil { throw ConfigurationError("The active profile has no profile library.") }
        if let explorer = settings.appExplorer {
            guard explorer.hasValidFavorites else {
                throw ConfigurationError("App Explorer needs named apps, web URLs, or groups with unique directions: at most eight slots per group, four group levels, and 256 entries total. URLs must be HTTP(S) without embedded credentials.")
            }
        }
        let apps = settings.appOverrides ?? []
        guard apps.count <= 100, Set(apps.map(\.bundleID)).count == apps.count,
              apps.allSatisfy({ !$0.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.isEmpty &&
                  Set($0.bindings.map(\.trigger)).count == $0.bindings.count &&
                  $0.bindings.allSatisfy { ($0.action != .shortcut || $0.shortcut != nil) &&
                      ($0.trigger.direction == nil || [.none, .shortcut, .appExplorer].contains($0.action)) } }) else {
            throw ConfigurationError("App overrides need unique bundle IDs and gestures, and keyboard actions need a recorded shortcut.")
        }
        guard formatVersion == 1 else { throw ConfigurationError("Unsupported formatVersion \(formatVersion). This app supports 1.") }
        let extra = settings.additionalProfiles ?? []
        let ids = [UInt32(1), 2] + extra.map(\.id)
        let valid = Set(ids)
        guard extra.count <= 98, valid.count == ids.count,
              extra.allSatisfy({ $0.id >= 100 && $0.id < UInt32.max - 100 && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ConfigurationError("Layers need unique IDs (additional IDs start at 100); at most 100 layers are supported.")
        }
        guard valid.contains(settings.defaultProfileID ?? 1) else { throw ConfigurationError("The default layer does not exist.") }
        let references = Array((settings.profileNames ?? [:]).keys)
            + Array((settings.profileGestures ?? [:]).keys)
            + Array((settings.sliderBaselines ?? [:]).keys)
            + Array(settings.customTapProfiles ?? [])
            + Array(shortcuts.profileActions.keys)
        guard references.allSatisfy(valid.contains), shortcuts.additional.keys.allSatisfy({ valid.contains($0) && $0 >= 100 }) else {
            throw ConfigurationError("A setting or shortcut refers to a layer that does not exist.")
        }
        if let overrides = settings.devices?.appleLayerGestures {
            guard overrides.keys.allSatisfy(valid.contains) else { throw ConfigurationError("Apple actions refer to a missing layer.") }
            for (id, gestures) in overrides {
                var copy = settings
                copy.devices = nil
                copy.profileGestures = (copy.profileGestures ?? [:]).merging([id: gestures]) { _, new in new }
                try AppConfiguration(settings: copy, shortcuts: shortcuts).validate()
            }
        }
        guard shortcuts.actions.count == 3, shortcuts.profileActions.values.allSatisfy({ $0.count == 3 }) else {
            throw ConfigurationError("Each click/drag shortcut list must contain exactly three entries.")
        }
        for id in ids {
            let taps = settings.gestures(for: id)
            let pairs: [(TapAction?, RecordedShortcut?)] = [
                (taps.oneFingerTap, taps.oneFingerShortcut), (taps.twoFingerTap, taps.twoFingerShortcut),
                (taps.oneFingerDoubleTap, taps.oneFingerDoubleShortcut), (taps.twoFingerDoubleTap, taps.twoFingerDoubleShortcut),
                (taps.oneFingerTripleTap, taps.oneFingerTripleShortcut), (taps.twoFingerTripleTap, taps.twoFingerTripleShortcut)
            ]
            guard pairs.allSatisfy({ $0.0 != .shortcut || $0.1 != nil }) else {
                throw ConfigurationError("Layer \(id) has a keyboard tap action without a recorded shortcut.")
            }
        }
        // Also validate programmatically captured configurations before export.
        let data = try JSONEncoder().encode(self)
        try JSONDecoder().decode(ConfigurationValue.self, from: data).validate()
    }

    @MainActor func seedIfNeeded(_ defaults: UserDefaults = .standard, considerLegacySettings: Bool = true) throws {
        guard defaults.data(forKey: "settings.v1") == nil else { return }
        // Leave existing legacy installs to their original migration path.
        if considerLegacySettings, defaults.persistentDomain(forName: "local.navigator.clone")?["settings.v1"] != nil { return }
        try validate()
        defaults.set(try JSONEncoder().encode(settings), forKey: "settings.v1")
        for (key, value) in try shortcuts.preferences() { defaults.set(value, forKey: key) }
        if let profiles, let activeConfigurationID {
            defaults.set(try JSONEncoder().encode(ConfigurationLibrary(activeID: activeConfigurationID, profiles: profiles)), forKey: "configurationProfiles.v1")
        }
        Self.markCurrent(defaults)
    }

    static func markCurrent(_ defaults: UserDefaults) {
        for key in ["migration.rotagivan.v1", "migration.rotagivan.independentFineMotion.v1", "migration.rotagivan.cursorTransitionRange.v1"] {
            defaults.set(true, forKey: key)
        }
    }
}

struct ConfigurationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Lossless data-only preflight; no preferences or runtime state are touched.
private indirect enum ConfigurationValue: Codable {
    case object([String: Self]), array([Self]), number(Double), string(String), bool(Bool), null

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let object = try? box.decode([String: Self].self) { self = .object(object) }
        else if let array = try? box.decode([Self].self) { self = .array(array) }
        else if let bool = try? box.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? box.decode(Double.self) { self = .number(number) }
        else { self = .string(try box.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .object(let v): try box.encode(v)
        case .array(let v): try box.encode(v)
        case .number(let v): try box.encode(v)
        case .string(let v): try box.encode(v)
        case .bool(let v): try box.encode(v)
        case .null: try box.encodeNil()
        }
    }

    func validate(key: String = "", path: String = "config") throws {
        switch self {
        case .object(let values):
            let allowed: String
            switch key {
            case "": allowed = "formatVersion settings shortcuts profiles activeConfigurationID"
            case "profiles": allowed = "id name settings shortcuts"
            case "devices": allowed = "navigatorEnabled appleEnabled shareTapActions appleLayerGestures"
            case "settings": allowed = "enabled launchAtLogin normal precision gestures oneFingerTap twoFingerTap additionalProfiles profileNames profileGestures customTapProfiles defaultProfileID sliderBaselines sliderBaselineRevision appOverrides appExplorer devices"
            case "appExplorer": allowed = "defaultMode favorites holdShortcut holdLayers theme animationsEnabled centerCursorOnAppSwitch slotCount windowManager"
            case "windowManager": allowed = "layout layers shortcuts"
            case "layers", "holdLayers": allowed = "id name holdShortcut favorites windowLayout slotCount activation"
            case "favorites", "children": allowed = "direction bundleID name url children groupMode action shortcut holdLayers slotCount showsWindows"
            case "holdShortcut": allowed = "keyCode modifiers keyLabel"
            case "appOverrides": allowed = "bundleID name enabled bindings"
            case "bindings": allowed = "trigger action shortcut"
            case "shortcut": allowed = "keyCode modifiers keyLabel"
            case "shortcuts": allowed = path.contains("windowManager") ? "command shortcut" : "normal precision actions additional profileActions holdToActivate"
            case "normal", "precision", "motion":
                allowed = path.contains(".shortcuts.") ? "keyCode modifiers enabled holdToActivate keyLabel" : "cursorResponse scrollResponse cursorSpeed cursorAcceleration scrollMultiplier invertScrollX invertScrollY kineticScroll kineticDecay scrollAcceleration cursorDeceleration fineCursorSpeed fineCursorAcceleration fineCursorFalloff cursorSpeedTransition"
            case "scrollResponse":
                allowed = "slowMultiplier fastMultiplier transitionSpeed"
                guard Set(allowed.split(separator:" ").map(String.init)).isSubset(of:Set(values.keys)) else {
                    throw ConfigurationError("\(path) must include Slow speed, Fast speed, and Transition point.")
                }
                if case .number(let slow)? = values["slowMultiplier"], case .number(let fast)? = values["fastMultiplier"], slow > fast {
                    throw ConfigurationError("\(path): Slow speed cannot exceed Fast speed.")
                }
            case "cursorResponse":
                allowed = "fineGain fastGain transitionCenter transitionWidth smoothing fineRelease fastRelease releaseShape"
                guard Set(allowed.split(separator: " ").map(String.init)).isSubset(of: Set(values.keys)) else {
                    throw ConfigurationError("\(path) must include all eight curve parameters. Export a complete configuration first.")
                }
                if case .number(let fine)? = values["fineGain"], case .number(let fast)? = values["fastGain"], fine > fast {
                    throw ConfigurationError("\(path): Fine speed cannot exceed Fast speed.")
                }
            case "gestures": allowed = "tapToClick tapMaxDuration tapMaxMovement keepCursorStillForTaps touchAndHoldDrag dragRegrip dragRegripWindow secondFingerGracePeriod doubleTapInterval tripleTapFirstInterval tripleTapSecondInterval"
            case "profileGestures", "appleLayerGestures": allowed = "gestures oneFingerTap twoFingerTap oneFingerShortcut twoFingerShortcut oneFingerDoubleTap twoFingerDoubleTap oneFingerDoubleShortcut twoFingerDoubleShortcut doubleTapSwipe singleTapSwipe twoFingerSingleTapSwipe twoFingerDoubleTapSwipe twoFingerSwipe oneFingerTripleTap twoFingerTripleTap oneFingerTripleShortcut twoFingerTripleShortcut"
            case "doubleTapSwipe", "singleTapSwipe", "twoFingerSingleTapSwipe", "twoFingerDoubleTapSwipe", "twoFingerSwipe": allowed = "enabled swipeWindow swipeDistance fastSwipeDuration appExplorerDirections left right up down topLeft topRight bottomLeft bottomRight"
            case "oneFingerShortcut", "twoFingerShortcut", "oneFingerDoubleShortcut", "twoFingerDoubleShortcut", "oneFingerTripleShortcut", "twoFingerTripleShortcut", "left", "right", "up", "down", "topLeft", "topRight", "bottomLeft", "bottomRight": allowed = "keyCode modifiers keyLabel"
            case "sliderBaselines": allowed = "cursorSpeed cursorAcceleration cursorFalloff scrollSpeed scrollAcceleration coastCoefficient tapImpactSpeed tapMovementRadius doubleTapDelay regripWindow"
            case "additionalProfiles": allowed = "id name motion"
            case "actions", "additional", "profileActions": allowed = "keyCode modifiers enabled holdToActivate keyLabel"
            default: throw ConfigurationError("Unexpected object at \(path).")
            }
            let known = Set(allowed.split(separator: " ").map(String.init))
            if let unknown = values.keys.sorted().first(where: { !known.contains($0) }) {
                throw ConfigurationError("Unknown setting: \(path).\(unknown)")
            }
            for (name, value) in values { try value.validate(key: name, path: path + "." + name) }
        case .array(let values):
            if path.hasSuffix("." + key), ["profileNames", "profileGestures", "appleLayerGestures", "sliderBaselines", "additional", "profileActions"].contains(key) {
                guard values.count % 2 == 0 else { throw ConfigurationError("\(path) must contain alternating layer IDs and values.") }
                var seen = Set<Double>()
                for i in stride(from: 0, to: values.count, by: 2) {
                    guard case .number(let id) = values[i], id >= 1, id < Double(UInt32.max - 100), id.rounded() == id,
                          seen.insert(id).inserted else { throw ConfigurationError("\(path) has an invalid or duplicate layer ID.") }
                }
            }
            for (i, value) in values.enumerated() { try value.validate(key: key, path: path + "[\(i)]") }
        case .number(let number):
            let ranges: [String: ClosedRange<Double>] = [
                "swipeWindow": 0.1...0.8, "swipeDistance": 20...240,
                "fastSwipeDuration": 0.06...0.3,
                "slowMultiplier": 0...ScrollResponse.maximumMultiplier, "fastMultiplier": 0...ScrollResponse.maximumMultiplier,
                "transitionSpeed": ScrollResponse.minimumTransition...ScrollResponse.maximumTransition,
                "fineGain": 0...CursorResponse.maximumGain, "fastGain": 0...CursorResponse.maximumGain,
                "transitionCenter": CursorResponse.minimumCenter...CursorResponse.maximumCenter,
                "transitionWidth": CursorResponse.minimumWidth...CursorResponse.maximumWidth,
                "smoothing": 0...100, "releaseShape": 0...100,
                "fineRelease": 0...CursorResponse.maximumRelease, "fastRelease": 0...CursorResponse.maximumRelease,
                "cursorSpeed": 0...ProfileMaximum.cursorSpeed, "fineCursorSpeed": 0...ProfileMaximum.cursorSpeed,
                "cursorAcceleration": 1...ProfileMaximum.cursorAcceleration, "fineCursorAcceleration": 1...ProfileMaximum.cursorAcceleration,
                "cursorDeceleration": 0...ProfileMaximum.cursorFalloff, "fineCursorFalloff": 0...ProfileMaximum.cursorFalloff,
                "cursorFalloff": 0...ProfileMaximum.cursorFalloff, "cursorSpeedTransition": 0...ProfileMaximum.cursorSpeedTransition,
                "scrollMultiplier": 0...ProfileMaximum.scrollSpeed, "scrollSpeed": 0...ProfileMaximum.scrollSpeed,
                "scrollAcceleration": 1...ProfileMaximum.scrollAcceleration, "kineticDecay": 0...1, "coastCoefficient": 0...1,
                "tapMaxDuration": 0...1, "tapImpactSpeed": 0...1, "tapMaxMovement": 0...160, "tapMovementRadius": 0...160,
                "dragRegripWindow": 0...2, "regripWindow": 0...2, "secondFingerGracePeriod": 0...2,
                "doubleTapInterval": 0.05...0.6, "doubleTapDelay": 0.05...0.6, "keyCode": 0...127,
                "tripleTapFirstInterval": 0.05...0.6, "tripleTapSecondInterval": 0.05...0.6,
                "modifiers": 0...Double(UInt32.max), "gain": 0...CursorResponse.maximumGain, "x": 0...1, "inputRange": 250...8000
            ]
            guard number.isFinite, number >= 0, ranges[key]?.contains(number) ?? true else {
                throw ConfigurationError("\(path) is outside its supported range.")
            }
            if ["id", "keyCode", "modifiers", "defaultProfileID", "formatVersion", "sliderBaselineRevision"].contains(key),
               number.rounded() != number { throw ConfigurationError("\(path) must be an integer.") }
        case .string(let text):
            guard text.count <= (key == "url" ? 4096 : 512) else { throw ConfigurationError("\(path) is too long.") }
        default: break
        }
    }
}
