import Foundation

enum AppGestureTrigger: String, Codable, CaseIterable, Identifiable {
    case oneFingerTap, twoFingerTap, oneFingerDoubleTap, twoFingerDoubleTap, oneFingerTripleTap, twoFingerTripleTap
    case singleLeft = "single.left", singleRight = "single.right", singleUp = "single.up", singleDown = "single.down"
    case singleTopLeft = "single.topLeft", singleTopRight = "single.topRight", singleBottomLeft = "single.bottomLeft", singleBottomRight = "single.bottomRight"
    case doubleLeft = "double.left", doubleRight = "double.right", doubleUp = "double.up", doubleDown = "double.down"
    case doubleTopLeft = "double.topLeft", doubleTopRight = "double.topRight", doubleBottomLeft = "double.bottomLeft", doubleBottomRight = "double.bottomRight"
    case twoFingerLeft = "twoFinger.left", twoFingerRight = "twoFinger.right"
    case twoSingleLeft = "twoSingle.left", twoSingleRight = "twoSingle.right", twoSingleUp = "twoSingle.up", twoSingleDown = "twoSingle.down"
    case twoSingleTopLeft = "twoSingle.topLeft", twoSingleTopRight = "twoSingle.topRight", twoSingleBottomLeft = "twoSingle.bottomLeft", twoSingleBottomRight = "twoSingle.bottomRight"
    case twoDoubleLeft = "twoDouble.left", twoDoubleRight = "twoDouble.right", twoDoubleUp = "twoDouble.up", twoDoubleDown = "twoDouble.down"
    case twoDoubleTopLeft = "twoDouble.topLeft", twoDoubleTopRight = "twoDouble.topRight", twoDoubleBottomLeft = "twoDouble.bottomLeft", twoDoubleBottomRight = "twoDouble.bottomRight"
    var id: String { rawValue }
    var direction: SwipeDirection? { SwipeDirection(rawValue: String(rawValue.split(separator: ".").last!)) }
    static let baseTapTriggers: [Self] = [
        .oneFingerTap, .oneFingerDoubleTap, .oneFingerTripleTap,
        .twoFingerTap, .twoFingerDoubleTap, .twoFingerTripleTap
    ]
    static let swipeCapableTapTriggers: [Self] = [
        .oneFingerTap, .oneFingerDoubleTap, .twoFingerTap, .twoFingerDoubleTap
    ]
    static let layerActionTriggers: [Self] = baseTapTriggers + swipeCapableTapTriggers.flatMap { tap in
        SwipeDirection.allCases.compactMap { combining(tap: tap, direction: $0) }
    }
    static func combining(tap: Self, direction: SwipeDirection) -> Self? {
        let prefix: String
        switch tap {
        case .oneFingerTap: prefix = "single"
        case .oneFingerDoubleTap: prefix = "double"
        case .twoFingerTap: prefix = "twoSingle"
        case .twoFingerDoubleTap: prefix = "twoDouble"
        default: return nil
        }
        return Self(rawValue: "\(prefix).\(direction.rawValue)")
    }
    var baseTapTrigger: Self? {
        guard direction != nil else { return Self.baseTapTriggers.contains(self) ? self : nil }
        switch rawValue.split(separator: ".").first {
        case "single": return .oneFingerTap
        case "double": return .oneFingerDoubleTap
        case "twoSingle": return .twoFingerTap
        case "twoDouble": return .twoFingerDoubleTap
        default: return nil
        }
    }
    var title: String {
        switch self {
        case .oneFingerTap: return "One-finger tap"
        case .twoFingerTap: return "Two-finger tap"
        case .oneFingerDoubleTap: return "One-finger double tap"
        case .twoFingerDoubleTap: return "Two-finger double tap"
        case .oneFingerTripleTap: return "One-finger triple tap"
        case .twoFingerTripleTap: return "Two-finger triple tap"
        default:
            let prefix: String
            switch rawValue.split(separator: ".").first {
            case "single": prefix = "Tap + swipe"
            case "double": prefix = "Double-tap + swipe"
            case "twoSingle": prefix = "Two-finger tap + swipe"
            case "twoDouble": prefix = "Two-finger double-tap + swipe"
            default: prefix = "Two-finger swipe"
            }
            return "\(prefix) \(direction!.title.lowercased())"
        }
    }
}

extension ProfileGestures {
    /// Writes the same persisted fields used by the legacy tap and swipe editors.
    /// Keeping this translation in one place lets the assignment-list UI remain
    /// a pure view over existing configurations and migrations.
    @discardableResult mutating func setLayerAction(_ action: TapAction, shortcut: RecordedShortcut?,
                                                     for trigger: AppGestureTrigger) -> Bool {
        gestures.tapToClick = true
        let storedShortcut = action == .shortcut ? shortcut : nil
        switch trigger {
        case .oneFingerTap:
            oneFingerTap = action; oneFingerShortcut = storedShortcut
        case .oneFingerDoubleTap:
            oneFingerDoubleTap = action; oneFingerDoubleShortcut = storedShortcut
        case .oneFingerTripleTap:
            oneFingerTripleTap = action; oneFingerTripleShortcut = storedShortcut
        case .twoFingerTap:
            twoFingerTap = action; twoFingerShortcut = storedShortcut
        case .twoFingerDoubleTap:
            twoFingerDoubleTap = action; twoFingerDoubleShortcut = storedShortcut
        case .twoFingerTripleTap:
            twoFingerTripleTap = action; twoFingerTripleShortcut = storedShortcut
        default:
            guard let direction = trigger.direction else { return false }
            let key: WritableKeyPath<ProfileGestures, DoubleTapSwipeSettings?>
            let singleTap: Bool
            switch trigger.rawValue.split(separator: ".").first {
            case "single": key = \.singleTapSwipe; singleTap = true
            case "double": key = \.doubleTapSwipe; singleTap = false
            case "twoSingle": key = \.twoFingerSingleTapSwipe; singleTap = true
            case "twoDouble": key = \.twoFingerDoubleTapSwipe; singleTap = false
            default: return false
            }
            guard action == .none || action == .shortcut || action == .appExplorer else { return false }
            var swipe = self[keyPath: key] ?? (singleTap ? .singleTapDefaults : DoubleTapSwipeSettings())
            swipe.setAction(action, for: direction)
            if action == .shortcut { swipe[direction] = shortcut }
            swipe.enabled = SwipeDirection.allCases.contains { swipe.action(for: $0) != .none }
            self[keyPath: key] = swipe
        }
        return true
    }
}

extension AppGestureTrigger {
    func assignment(in taps: ProfileGestures) -> (binding: AppGestureBinding, enabled: Bool) {
        var action: TapAction = .none
        var shortcut: RecordedShortcut?
        var enabled = taps.gestures.tapToClick
        switch self {
        case .oneFingerTap: action = taps.oneFingerTap; shortcut = taps.oneFingerShortcut
        case .twoFingerTap: action = taps.twoFingerTap; shortcut = taps.twoFingerShortcut
        case .oneFingerDoubleTap: action = taps.oneFingerDoubleTap ?? .none; shortcut = taps.oneFingerDoubleShortcut
        case .twoFingerDoubleTap: action = taps.twoFingerDoubleTap ?? .none; shortcut = taps.twoFingerDoubleShortcut
        case .oneFingerTripleTap: action = taps.oneFingerTripleTap ?? .none; shortcut = taps.oneFingerTripleShortcut
        case .twoFingerTripleTap: action = taps.twoFingerTripleTap ?? .none; shortcut = taps.twoFingerTripleShortcut
        default:
            let swipe: DoubleTapSwipeSettings?
            switch rawValue.split(separator: ".").first {
            case "single": swipe = taps.singleTapSwipe
            case "double": swipe = taps.doubleTapSwipe
            case "twoSingle": swipe = taps.twoFingerSingleTapSwipe
            case "twoDouble": swipe = taps.twoFingerDoubleTapSwipe
            default: swipe = taps.twoFingerSwipe; enabled = true // Navigation does not require tap-to-click.
            }
            if let swipe, let direction {
                action = swipe.action(for: direction); shortcut = swipe[direction]
                enabled = enabled && swipe.enabled
            } else { enabled = false }
        }
        return (AppGestureBinding(trigger: self, action: action, shortcut: shortcut), enabled && action != .none)
    }
}

struct HUDTapAssignmentScope: Hashable {
    var profileID: UInt32
    var device: GestureDevice
}

extension StoredSettings {
    /// Applies staged HUD-layer tap hotkeys through the same profile fields used
    /// by Layer actions. Shared Apple actions canonicalize to Navigator so one
    /// edit cannot create two competing copies of the same assignment.
    mutating func updateHUDLayerTapAssignments(
        _ staged: [HUDTapAssignmentScope: Set<AppGestureTrigger>],
        for layer: ExplorerHoldLayer
    ) {
        var normalized: [HUDTapAssignmentScope: Set<AppGestureTrigger>] = [:]
        for (scope, triggers) in staged {
            let device: GestureDevice = scope.device == .apple && resolvedDevices.shareTapActions ? .navigator : scope.device
            normalized[HUDTapAssignmentScope(profileID: scope.profileID, device: device)] = triggers
        }
        for (scope, desired) in normalized {
            let separateApple = scope.device == .apple && !resolvedDevices.shareTapActions
            var profile = separateApple
                ? (devices?.appleLayerGestures?[scope.profileID] ?? effectiveGestures(for: scope.profileID))
                : effectiveGestures(for: scope.profileID)
            for trigger in AppGestureTrigger.baseTapTriggers {
                let current = trigger.assignment(in: profile).binding
                if desired.contains(trigger) {
                    _ = profile.setLayerAction(.shortcut, shortcut: .hudLayer(layer), for: trigger)
                } else if current.shortcut?.hudLayerID == layer.id {
                    _ = profile.setLayerAction(.none, shortcut: nil, for: trigger)
                }
            }
            if separateApple {
                var deviceSettings = resolvedDevices
                var overrides = deviceSettings.appleLayerGestures ?? [:]
                overrides[scope.profileID] = profile
                deviceSettings.appleLayerGestures = overrides
                devices = deviceSettings
            } else {
                var profiles = profileGestures ?? [:]
                profiles[scope.profileID] = profile
                profileGestures = profiles
                if scope.profileID != resolvedDefaultProfileID {
                    var custom = customTapProfiles ?? []
                    custom.insert(scope.profileID)
                    customTapProfiles = custom
                }
            }
        }
    }
}

struct AppGestureBinding: Codable, Equatable, Identifiable {
    var trigger: AppGestureTrigger
    var action: TapAction = .none
    var shortcut: RecordedShortcut?
    var id: AppGestureTrigger { trigger }
}

struct AppGestureOverride: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var enabled = true
    var bindings: [AppGestureBinding] = []
    var id: String { bundleID }

    static let chrome = Self(bundleID: "com.google.Chrome", name: "Google Chrome", bindings: [
            AppGestureBinding(trigger: .twoFingerRight, action: .shortcut,
                shortcut: RecordedShortcut(keyCode: 33, modifiers: 1 << 20, keyLabel: "[")),
            AppGestureBinding(trigger: .twoFingerLeft, action: .shortcut,
                shortcut: RecordedShortcut(keyCode: 30, modifiers: 1 << 20, keyLabel: "]"))
        ])
    static let defaults: [Self] = [.chrome]

    func applying(to base: ProfileGestures) -> ProfileGestures {
        guard enabled else { return base }
        var result = base
        for binding in bindings {
            switch binding.trigger {
            case .oneFingerTap: result.oneFingerTap = binding.action; result.oneFingerShortcut = binding.shortcut
            case .twoFingerTap: result.twoFingerTap = binding.action; result.twoFingerShortcut = binding.shortcut
            case .oneFingerDoubleTap: result.oneFingerDoubleTap = binding.action; result.oneFingerDoubleShortcut = binding.shortcut
            case .twoFingerDoubleTap: result.twoFingerDoubleTap = binding.action; result.twoFingerDoubleShortcut = binding.shortcut
            case .oneFingerTripleTap: result.oneFingerTripleTap = binding.action; result.oneFingerTripleShortcut = binding.shortcut
            case .twoFingerTripleTap: result.twoFingerTripleTap = binding.action; result.twoFingerTripleShortcut = binding.shortcut
            default:
                guard let direction = binding.trigger.direction else { continue }
                let key: WritableKeyPath<ProfileGestures, DoubleTapSwipeSettings?>
                switch binding.trigger.rawValue.split(separator: ".").first {
                case "single": key = \.singleTapSwipe
                case "double": key = \.doubleTapSwipe
                case "twoSingle": key = \.twoFingerSingleTapSwipe
                case "twoDouble": key = \.twoFingerDoubleTapSwipe
                default: key = \.twoFingerSwipe
                }
                let single = key == \.singleTapSwipe || key == \.twoFingerSingleTapSwipe
                var swipe = result[keyPath: key] ?? (single ? .singleTapDefaults : DoubleTapSwipeSettings())
                if !swipe.enabled && binding.action != .none {
                    for direction in SwipeDirection.allCases { swipe.setAction(.none, for: direction) }
                }
                swipe.setAction(binding.action, for: direction)
                if binding.action == .shortcut { swipe[direction] = binding.shortcut }
                if binding.action != .none { swipe.enabled = true }
                result[keyPath: key] = swipe
            }
        }
        return result
    }
}
