import Foundation

enum AppVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    static var display: String { "v\(version) (\(build))" }
}

/// User-facing settings are always 0...100. MotionProfile keeps the values
/// used by the gesture engine so existing saved profiles retain their feel.
enum SettingsScale {
    case linear(minimum: Double, maximum: Double)
    case momentum(maximum: Double)

    func percentage(for value: Double) -> Double {
        switch self {
        case let .linear(minimum, maximum):
            guard maximum > minimum else { return 0 }
            return min(100, max(0, (value - minimum) / (maximum - minimum) * 100))
        case let .momentum(maximum):
            guard value > 0 else { return 0 }
            guard maximum > 0 else { return 0 }
            let normalized = min(1, max(0, (value / maximum - 0.70) / 0.30))
            return min(100, max(0, (1 - sqrt(1 - normalized)) * 100))
        }
    }

    func value(for percentage: Double) -> Double {
        let p = min(100, max(0, percentage)) / 100
        switch self {
        case let .linear(minimum, maximum): return minimum + (maximum - minimum) * p
        case let .momentum(maximum): return p == 0 ? 0 : maximum * (0.70 + 0.30 * (1 - pow(1 - p, 2)))
        }
    }
}

/// Global 0...100 ceilings. A profile's own 0...100 value is a fraction of
/// the relevant ceiling, letting profiles remain comparable as limits change.
struct GlobalLimits: Codable, Equatable {
    var cursorSpeedCeiling = 50.0
    var cursorAccelerationCeiling = 50.0
    var scrollSpeedCeiling = 50.0
    var momentumCeiling = 100.0
    var tapDurationCeiling = 60.0
    var tapMovementCeiling = 50.0
    var regripWindowCeiling = 40.0

    var cursorSpeedMaximum: Double { 6 * cursorSpeedCeiling / 100 }
    var cursorAccelerationMaximum: Double { 1 + 2.8 * cursorAccelerationCeiling / 100 }
    var scrollSpeedMaximum: Double { 12 * scrollSpeedCeiling / 100 }
    var momentumMaximum: Double { 0.995 * momentumCeiling / 100 }
    var tapDurationMaximum: Double { tapDurationCeiling / 100 }
    var tapMovementMaximum: Double { 160 * tapMovementCeiling / 100 }
    var regripWindowMaximum: Double { 2 * regripWindowCeiling / 100 }
}

enum TapAction: String, Codable, CaseIterable {
    case optionF19, enter, leftClick, rightClick, none, shortcut
    var title: String {
        switch self {
        case .optionF19: return "Option + F19"
        case .enter: return "Enter"
        case .leftClick: return "Left click"
        case .rightClick: return "Right click"
        case .none: return "Nothing"
        case .shortcut: return "Keyboard shortcut"
        }
    }

    /// A tap-and-hold drag starts with a real left mouse down, so it can only
    /// follow a one-finger tap that also acts as a left click.
    var supportsTapAndHoldDrag: Bool { self == .leftClick }
}

struct RecordedShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var keyLabel: String
}

struct MotionProfile: Codable, Equatable {
    var cursorSpeed: Double
    var cursorAcceleration: Double
    var scrollMultiplier: Double
    var invertScrollX: Bool
    var invertScrollY: Bool
    var kineticScroll: Bool
    var kineticDecay: Double

    static let normal = MotionProfile(
        cursorSpeed: 0.5,
        cursorAcceleration: 1.5,
        scrollMultiplier: 1.4,
        invertScrollX: false,
        invertScrollY: false,
        kineticScroll: true,
        kineticDecay: 0.98
    )

    static let precision = MotionProfile(
        cursorSpeed: 0.22,
        cursorAcceleration: 1.15,
        scrollMultiplier: 0.65,
        invertScrollX: false,
        invertScrollY: false,
        kineticScroll: true,
        kineticDecay: 0.96
    )
}

struct GestureSettings: Codable, Equatable {
    var tapToClick = true
    var tapMaxDuration = 0.25
    var tapMaxMovement = 30.0
    var touchAndHoldDrag = true
    var dragRegrip = true
    var dragRegripWindow = 0.25
    var secondFingerGracePeriod = 0.05
}

struct ProfileGestures: Codable {
    var gestures: GestureSettings
    var oneFingerTap: TapAction
    var twoFingerTap: TapAction
    var oneFingerShortcut: RecordedShortcut?
    var twoFingerShortcut: RecordedShortcut?
    // Optional so profiles saved before double-tap support keep working.
    var oneFingerDoubleTap: TapAction?
    var twoFingerDoubleTap: TapAction?
    var oneFingerDoubleShortcut: RecordedShortcut?
    var twoFingerDoubleShortcut: RecordedShortcut?
}

struct AdditionalProfile: Codable, Identifiable {
    var id: UInt32
    var name: String
    var motion: MotionProfile
}

struct StoredSettings: Codable {
    var enabled = true
    var launchAtLogin = false
    var normal = MotionProfile.normal
    var precision = MotionProfile.precision
    var gestures = GestureSettings()
    var oneFingerTap: TapAction?
    var twoFingerTap: TapAction?
    var additionalProfiles: [AdditionalProfile]?
    var profileNames: [UInt32: String]?
    var profileGestures: [UInt32: ProfileGestures]?
    var customTapProfiles: Set<UInt32>?
    var defaultProfileID: UInt32?
    var globalLimits: GlobalLimits?
    var resolvedGlobalLimits: GlobalLimits { globalLimits ?? GlobalLimits() }
    var resolvedDefaultProfileID: UInt32 {
        let id = defaultProfileID ?? 1
        return id == 1 || id == 2 || (additionalProfiles ?? []).contains(where: { $0.id == id }) ? id : 1
    }

    mutating func makeDefault(_ id: UInt32) {
        guard id == 1 || id == 2 || (additionalProfiles ?? []).contains(where: { $0.id == id }) else { return }
        guard id != resolvedDefaultProfileID else { return }
        let currentTaps = effectiveGestures(for: id)
        var stored = profileGestures ?? [:]
        stored[id] = currentTaps
        profileGestures = stored
        var custom = customTapProfiles ?? []
        custom.insert(resolvedDefaultProfileID)
        customTapProfiles = custom
        defaultProfileID = id
    }

    func gestures(for id: UInt32) -> ProfileGestures {
        profileGestures?[id] ?? ProfileGestures(gestures: gestures, oneFingerTap: oneFingerTap ?? .optionF19, twoFingerTap: twoFingerTap ?? .enter)
    }

    func effectiveGestures(for id: UInt32) -> ProfileGestures {
        var result = gestures(for: id)
        if id != resolvedDefaultProfileID && !(customTapProfiles ?? []).contains(id) {
            let primary = gestures(for: resolvedDefaultProfileID)
            result.oneFingerTap = primary.oneFingerTap
            result.twoFingerTap = primary.twoFingerTap
            result.oneFingerShortcut = primary.oneFingerShortcut
            result.twoFingerShortcut = primary.twoFingerShortcut
            result.oneFingerDoubleTap = primary.oneFingerDoubleTap
            result.twoFingerDoubleTap = primary.twoFingerDoubleTap
            result.oneFingerDoubleShortcut = primary.oneFingerDoubleShortcut
            result.twoFingerDoubleShortcut = primary.twoFingerDoubleShortcut
            result.gestures.tapToClick = primary.gestures.tapToClick
            result.gestures.tapMaxDuration = primary.gestures.tapMaxDuration
            result.gestures.tapMaxMovement = primary.gestures.tapMaxMovement
        }
        return result
    }

    func profileName(for id: UInt32, fallback: String) -> String {
        let name = profileNames?[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fallback : name
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: StoredSettings { didSet { save() } }
    @Published private(set) var activeProfileID: UInt32 = 1

    private static let storageKey = "settings.v1"

    init() {
        // Keep the legacy domain read-only so existing installations retain their tuning.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "migration.rotagivan.v1") {
            let legacy = defaults.persistentDomain(forName: "local.navigator.clone") ?? [:]
            for (key, value) in legacy where key == Self.storageKey || key.hasPrefix("shortcut.") {
                if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "migration.rotagivan.v1")
        }
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(StoredSettings.self, from: data) {
            settings = decoded
        } else {
            settings = StoredSettings()
            importZSASettingsIfPresent()
        }
        if settings.oneFingerTap == nil && settings.twoFingerTap == nil {
            settings.oneFingerTap = .optionF19
            settings.twoFingerTap = .enter
            settings.gestures.tapToClick = true
        }
        activeProfileID = settings.resolvedDefaultProfileID
    }

    var activeProfile: MotionProfile {
        motion(for: activeProfileID)
    }

    func updateGlobalLimits(_ limits: GlobalLimits) {
        settings.globalLimits = limits
    }

    var activeGestures: ProfileGestures { settings.effectiveGestures(for: activeProfileID) }

    func updateGestures(_ value: ProfileGestures, for id: UInt32) {
        var profiles = settings.profileGestures ?? [:]
        profiles[id] = value
        settings.profileGestures = profiles
    }

    var profiles: [(id: UInt32, name: String)] {
        let defaults: [(id: UInt32, name: String)] = [(1, "Normal"), (2, "Precision")] + (settings.additionalProfiles ?? []).map { ($0.id, $0.name) }
        let named = defaults.map { (id: $0.id, name: settings.profileName(for: $0.id, fallback: $0.name)) }
        return named.filter { $0.id == defaultProfileID } + named.filter { $0.id != defaultProfileID }
    }

    var defaultProfileID: UInt32 { settings.resolvedDefaultProfileID }

    func makeDefault(_ id: UInt32) {
        var updated = settings
        updated.makeDefault(id)
        settings = updated
        activeProfileID = defaultProfileID
    }

    var activeProfileName: String { profiles.first { $0.id == activeProfileID }?.name ?? "Normal" }

    func setActiveProfile(_ id: UInt32) {
        activeProfileID = profiles.contains { $0.id == id } ? id : defaultProfileID
    }

    func motion(for id: UInt32) -> MotionProfile {
        if id == 1 { return settings.normal }
        if id == 2 { return settings.precision }
        return settings.additionalProfiles?.first { $0.id == id }?.motion ?? settings.normal
    }

    func updateMotion(_ motion: MotionProfile, for id: UInt32) {
        if id == 1 { settings.normal = motion }
        else if id == 2 { settings.precision = motion }
        else if let index = settings.additionalProfiles?.firstIndex(where: { $0.id == id }) {
            settings.additionalProfiles?[index].motion = motion
        }
    }

    @discardableResult
    func addProfile() -> UInt32 {
        let id = max(99, settings.additionalProfiles?.map(\.id).max() ?? 99) + 1
        let profile = AdditionalProfile(id: id, name: "Profile \(profiles.count + 1)", motion: motion(for: defaultProfileID))
        settings.additionalProfiles = (settings.additionalProfiles ?? []) + [profile]
        updateGestures(settings.gestures(for: defaultProfileID), for: id)
        return id
    }

    func reset() {
        settings = StoredSettings()
        activeProfileID = 1
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func importZSASettingsIfPresent() {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "io.zsa.navigator") else { return }
        settings.normal.cursorSpeed = (domain["cursor.speed"] as? NSNumber)?.doubleValue ?? settings.normal.cursorSpeed
        settings.normal.cursorAcceleration = (domain["cursor.acceleration"] as? NSNumber)?.doubleValue ?? settings.normal.cursorAcceleration
        settings.normal.scrollMultiplier = (domain["scroll.multiplier"] as? NSNumber)?.doubleValue ?? settings.normal.scrollMultiplier
        settings.normal.invertScrollX = (domain["scroll.invertX"] as? NSNumber)?.boolValue ?? settings.normal.invertScrollX
        settings.normal.invertScrollY = (domain["scroll.invertY"] as? NSNumber)?.boolValue ?? settings.normal.invertScrollY
        settings.normal.kineticScroll = (domain["scroll.kinetic.enabled"] as? NSNumber)?.boolValue ?? settings.normal.kineticScroll
        settings.normal.kineticDecay = (domain["scroll.kinetic.decay"] as? NSNumber)?.doubleValue ?? settings.normal.kineticDecay
        settings.gestures.tapToClick = (domain["gestures.tapToClickEnabled"] as? NSNumber)?.boolValue ?? settings.gestures.tapToClick
        settings.gestures.tapMaxDuration = (domain["gestures.tapMaxDuration"] as? NSNumber)?.doubleValue ?? settings.gestures.tapMaxDuration
        settings.gestures.tapMaxMovement = (domain["gestures.tapMaxMovement"] as? NSNumber)?.doubleValue ?? settings.gestures.tapMaxMovement
        settings.gestures.touchAndHoldDrag = (domain["gestures.touchAndHoldDrag"] as? NSNumber)?.boolValue ?? settings.gestures.touchAndHoldDrag
        settings.gestures.dragRegrip = (domain["gestures.dragRegrip"] as? NSNumber)?.boolValue ?? settings.gestures.dragRegrip
        settings.gestures.dragRegripWindow = (domain["gestures.dragRegripWindow"] as? NSNumber)?.doubleValue ?? settings.gestures.dragRegripWindow
        settings.gestures.secondFingerGracePeriod = (domain["gestures.secondFingerGracePeriod"] as? NSNumber)?.doubleValue ?? settings.gestures.secondFingerGracePeriod
        settings.precision = MotionProfile(
            cursorSpeed: max(0.05, settings.normal.cursorSpeed * 0.45),
            cursorAcceleration: max(1.0, settings.normal.cursorAcceleration * 0.8),
            scrollMultiplier: max(0.05, settings.normal.scrollMultiplier * 0.5),
            invertScrollX: settings.normal.invertScrollX,
            invertScrollY: settings.normal.invertScrollY,
            kineticScroll: settings.normal.kineticScroll,
            kineticDecay: settings.normal.kineticDecay
        )
    }
}
