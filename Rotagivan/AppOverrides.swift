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
