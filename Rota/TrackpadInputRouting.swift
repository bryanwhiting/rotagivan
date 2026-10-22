import Foundation

enum TrackpadInputSource: Equatable, Hashable {
    case navigator
    case apple(UInt64)

    var isApple: Bool {
        if case .apple = self { return true }
        return false
    }
}

/// A gesture belongs to one physical trackpad. Never splice two devices into a
/// double tap, a swipe, or an Explorer selection, even if their finger IDs match.
struct TrackpadInputRouting {
    private(set) var source: TrackpadInputSource?
    private(set) var contactsDown = false
    private var drain: Set<TrackpadInputSource> = []

    mutating func accept(_ candidate: TrackpadInputSource, touching: Bool,
                         lockedTo: TrackpadInputSource? = nil) -> Bool {
        if drain.contains(candidate) {
            if !touching { drain.remove(candidate) }
            return false
        }
        if let lockedTo, lockedTo != candidate {
            if touching { drain.insert(candidate) }
            return false
        }
        if source != candidate {
            // Outside a HUD/calibration, a resting Apple finger must never
            // starve Navigator's cursor/scroll reports. Discard that Apple
            // contact until lift instead of splicing it into a later gesture.
            let navigatorPriority = candidate == .navigator && lockedTo == nil && touching
            guard touching, !contactsDown || navigatorPriority else {
                if touching { drain.insert(candidate) }
                return false
            }
            if contactsDown, let source { drain.insert(source) }
            source = candidate
        }
        contactsDown = touching
        return true
    }

    mutating func reset(draining source: TrackpadInputSource? = nil) {
        self = Self()
        if let source { drain.insert(source) }
    }
}
