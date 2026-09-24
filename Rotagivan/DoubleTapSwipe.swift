import Foundation

/// Quick horizontal two-finger gestures reserve their axis before emitting
/// any scroll. Vertical movement or a slow start commits to ordinary scrolling.
struct TwoFingerNavigationRecognizer {
    struct Result {
        var consumed = false
        var direction: SwipeDirection?
    }
    private enum Phase { case idle, candidate, horizontal, scrolling, ending, drain }
    private var phase = Phase.idle
    private var origins: [UInt8: CGPoint] = [:]
    private var last: [UInt8: CGPoint] = [:]
    private var start = Date.distantPast
    private var firstLift = Date.distantPast
    private var endingDirection: SwipeDirection?
    private var captured: DoubleTapSwipeSettings?
    private var profile: UInt32 = 0
    private(set) var travel = 0.0

    mutating func update(_ report: TrackpadReport, settings: DoubleTapSwipeSettings?, profileID: UInt32, at now: Date) -> Result {
        let touching = report.contacts.filter(\.touching)
        if phase == .scrolling {
            if touching.isEmpty { phase = .idle }
            return Result()
        }
        if phase == .drain {
            if touching.isEmpty { phase = .idle }
            return Result(consumed: true)
        }
        if phase == .idle {
            guard touching.count == 2, let settings, settings.enabled,
                  settings.action(for: .left) != .none || settings.action(for: .right) != .none else { return Result() }
            guard Set(touching.map(\.id)).count == 2 else { phase = .drain; return Result(consumed:true) }
            captured = settings; profile = profileID
            origins = Dictionary(uniqueKeysWithValues: touching.map { ($0.id, CGPoint(x:$0.x,y:$0.y)) })
            last = origins; start = now; travel = 0; phase = .candidate
        }
        guard settings == captured, profileID == profile, !report.buttonDown,
              touching.count <= 2, touching.allSatisfy(\.confident),
              touching.allSatisfy({ origins[$0.id] != nil }),
              Set(touching.map(\.id)).count == touching.count else {
            phase = touching.isEmpty ? .idle : .drain
            return Result(consumed: true)
        }
        if phase == .ending {
            guard now.timeIntervalSince(firstLift) <= 0.12, touching.count < 2,
                  touching.allSatisfy({ origins[$0.id] != nil }) else {
                phase = touching.isEmpty ? .idle : .drain
                return Result(consumed: true)
            }
            if touching.isEmpty {
                phase = .idle
                return Result(consumed: true, direction: endingDirection)
            }
            return Result(consumed: true)
        }
        if touching.count < 2 {
            if phase == .candidate {
                phase = touching.isEmpty ? .idle : .scrolling
                return Result() // Small contact remains a two-finger tap.
            }
            let dx = last.reduce(0.0) { $0 + $1.value.x - (origins[$1.key]?.x ?? $1.value.x) } / 2
            let dy = last.reduce(0.0) { $0 + $1.value.y - (origins[$1.key]?.y ?? $1.value.y) } / 2
            let direction: SwipeDirection = dx < 0 ? .left : .right
            let coherent = last.allSatisfy { id, point in
                let fingerDX = point.x - origins[id]!.x
                return abs(fingerDX) >= 40 && fingerDX * dx > 0
            }
            endingDirection = coherent && abs(dx) >= 80 && abs(dx) > abs(dy) * 1.8 && now.timeIntervalSince(start) <= 0.35 ? direction : nil
            if touching.isEmpty { phase = .idle; return Result(consumed: true, direction: endingDirection) }
            firstLift = now; phase = .ending
            return Result(consumed: true)
        }
        guard touching.allSatisfy({ finger in
            guard let old = last[finger.id] else { return false }
            return hypot(finger.x - old.x, finger.y - old.y) < 400
        }) else { phase = .drain; return Result(consumed: true) }
        last = Dictionary(uniqueKeysWithValues: touching.map { ($0.id, CGPoint(x:$0.x,y:$0.y)) })
        let dx = touching.reduce(0.0) { $0 + $1.x - origins[$1.id]!.x } / 2
        let dy = touching.reduce(0.0) { $0 + $1.y - origins[$1.id]!.y } / 2
        travel = max(travel, hypot(dx,dy))
        let elapsed = now.timeIntervalSince(start)
        if abs(dy) >= 12 && abs(dy) * 1.8 >= abs(dx) || elapsed > (phase == .candidate ? 0.18 : 0.35) {
            phase = .scrolling
            return Result()
        }
        if phase == .candidate && abs(dx) >= 12 && abs(dx) > abs(dy) * 1.8 {
            let direction: SwipeDirection = dx < 0 ? .left : .right
            guard captured?.action(for: direction) != TapAction.none else { phase = .scrolling; return Result() }
            phase = .horizontal
        }
        return Result(consumed: true)
    }
}

/// Recognizes only the third contact after two completed taps. Tap/drag
/// classification stays in GestureEngine. No events are posted here.
struct DoubleTapSwipeRecognizer {
    enum Completion: Equatable {
        case swipe(SwipeDirection), tap, fallback, cancelled
    }
    struct Result {
        var consumed = false
        var completion: Completion?
    }
    private enum Phase {
        case idle
        case waiting(Date)
        case swiping(id: UInt8, origin: CGPoint, last: CGPoint, started: Date)
        case untilLift
    }
    private var phase = Phase.idle
    private var distance = 60.0
    private var tripleDuration: Double?
    private var tripleRadius = 0.0
    private var tripleDeadline = Date.distantPast
    private var swipeDeadline = Date.distantPast
    private var swipeAllowed = true
    private var maximumMovement = 0.0
    private var pairRecognizer = TwoFingerTapSwipeRecognizer()
    private var fingerCount = 1

    mutating func arm(at now: Date, settings: DoubleTapSwipeSettings,
                      tripleTapDuration: Double? = nil, tripleTapRadius: Double = 0,
                      tripleTapInterval: Double = 0.3, fingerCount: Int = 1,
                      maximumDuration: Double = 0.7) {
        self.fingerCount = fingerCount
        if fingerCount == 2 {
            pairRecognizer.arm(at: now, settings: settings, tapDuration: tripleTapDuration,
                tapRadius: tripleTapRadius, tapInterval: tripleTapInterval, maximumDuration: maximumDuration)
            return
        }
        swipeDeadline = now.addingTimeInterval(settings.resolvedWindow)
        tripleDeadline = tripleTapDuration == nil ? .distantPast : now.addingTimeInterval(tripleTapInterval)
        phase = .waiting(max(swipeDeadline, tripleDeadline))
        distance = settings.resolvedDistance
        tripleDuration = tripleTapDuration
        tripleRadius = tripleTapRadius
        maximumMovement = 0
    }

    mutating func cancel() {
        if fingerCount == 2 { pairRecognizer.cancel(); return }
        switch phase {
        case .swiping, .untilLift: phase = .untilLift
        default: phase = .idle
        }
    }

    mutating func update(_ contacts: [FingerContact], at now: Date) -> Result {
        if fingerCount == 2 { return pairRecognizer.update(contacts, at: now) }
        switch phase {
        case .idle:
            return Result()
        case .untilLift:
            if contacts.isEmpty { phase = .idle }
            return Result(consumed: true)
        case .waiting(let deadline):
            if now > deadline {
                phase = .idle
                return Result(completion: .fallback)
            }
            if contacts.isEmpty { return Result() }
            guard contacts.count == 1, let finger = contacts.first else {
                phase = .idle
                return Result(completion: .cancelled)
            }
            let point = CGPoint(x: finger.x, y: finger.y)
            swipeAllowed = now <= swipeDeadline
            phase = .swiping(id: finger.id, origin: point, last: point, started: now)
            return Result(consumed: true)
        case let .swiping(id, origin, last, started):
            // A swipe must finish promptly. A long hold is not a shortcut.
            guard now.timeIntervalSince(started) <= 0.7 else {
                phase = contacts.isEmpty ? .idle : .untilLift
                return Result(consumed: true, completion: .cancelled)
            }
            if contacts.isEmpty {
                phase = .idle
                let dx = last.x - origin.x, dy = last.y - origin.y
                if let tripleDuration, now <= tripleDeadline,
                   now.timeIntervalSince(started) <= tripleDuration,
                   maximumMovement <= tripleRadius, maximumMovement < distance {
                    return Result(consumed: true, completion: .tap)
                }
                guard swipeAllowed, hypot(dx, dy) >= distance else {
                    return Result(consumed: true, completion: .fallback)
                }
                guard let direction = SwipeDirection.classify(dx: dx, dy: dy) else {
                    return Result(consumed: true, completion: .cancelled)
                }
                return Result(consumed: true, completion: .swipe(direction))
            }
            guard contacts.count == 1, let finger = contacts.first, finger.id == id,
                  hypot(finger.x-last.x, finger.y-last.y) < 400 else {
                phase = .untilLift
                return Result(consumed: true, completion: .cancelled)
            }
            maximumMovement = max(maximumMovement, hypot(finger.x - origin.x, finger.y - origin.y))
            phase = .swiping(id: id, origin: origin, last: CGPoint(x: finger.x, y: finger.y), started: started)
            return Result(consumed: true)
        }
    }

    /// Timer expiry must not flush a double tap while its third touch is active.
    mutating func expire(at now: Date) -> Bool {
        if fingerCount == 2 { return pairRecognizer.expire(at: now) }
        guard case .waiting(let deadline) = phase, now >= deadline else { return false }
        phase = .idle
        return true
    }
}

/// Reserves a two-finger follow-up touch after completed taps. Stable contact IDs
/// avoid centroid jumps when fingers land/lift on adjacent reports. Both fingers
/// must move together, so a pinch or one moving finger cannot fire a shortcut.
struct TwoFingerTapSwipeRecognizer {
    typealias Result = DoubleTapSwipeRecognizer.Result
    typealias Completion = DoubleTapSwipeRecognizer.Completion
    private enum Phase { case idle, waiting, joining, moving, ending, drain }
    private var phase = Phase.idle
    private var settings = DoubleTapSwipeSettings()
    private var deadline = Date.distantPast
    private var swipeDeadline = Date.distantPast
    private var tapDeadline = Date.distantPast
    private var started = Date.distantPast
    private var lifted = Date.distantPast
    private var tapDuration: Double?
    private var tapRadius = 0.0
    private var maximumDuration = 0.7
    private var first: FingerContact?
    private var origins: [UInt8: CGPoint] = [:]
    private var last: [UInt8: CGPoint] = [:]
    private var travel = 0.0
    private var completion: Completion?
    private var onlyStartWithPair = false

    mutating func arm(at now: Date, settings: DoubleTapSwipeSettings, tapDuration: Double?,
                      tapRadius: Double, tapInterval: Double, maximumDuration: Double,
                      onlyStartWithPair: Bool = false) {
        self = Self()
        self.settings = settings; self.tapDuration = tapDuration; self.tapRadius = tapRadius
        self.maximumDuration = maximumDuration
        self.onlyStartWithPair = onlyStartWithPair
        swipeDeadline = now.addingTimeInterval(settings.resolvedWindow)
        tapDeadline = tapDuration == nil ? .distantPast : now.addingTimeInterval(tapInterval)
        deadline = max(swipeDeadline, tapDeadline)
        phase = .waiting
    }

    mutating func cancel() {
        phase = (phase == .waiting || phase == .idle) ? .idle : .drain
    }

    mutating func expire(at now: Date) -> Bool {
        guard phase == .waiting, now >= deadline else { return false }
        phase = .idle; return true
    }

    private mutating func reject(_ contacts: [FingerContact]) -> Result {
        phase = contacts.isEmpty ? .idle : .drain
        return Result(consumed: true, completion: .cancelled)
    }

    mutating func update(_ contacts: [FingerContact], at now: Date) -> Result {
        if phase == .idle { return Result() }
        if phase == .drain {
            if contacts.isEmpty { phase = .idle }
            return Result(consumed: true)
        }
        guard contacts.count <= 2, contacts.allSatisfy(\.confident),
              Set(contacts.map(\.id)).count == contacts.count else { return reject(contacts) }
        if phase == .waiting {
            if now > deadline { phase = .idle; return Result(completion: .fallback) }
            if contacts.isEmpty { return Result() }
            if onlyStartWithPair && contacts.count < 2 { return Result() }
            started = now; first = contacts.first; phase = .joining
        }
        if phase == .joining {
            guard now.timeIntervalSince(started) <= 0.06, !contacts.isEmpty,
                  let first, contacts.contains(where: { $0.id == first.id && hypot($0.x - first.x, $0.y - first.y) < 40 }) else {
                return reject(contacts)
            }
            if contacts.count == 1 { return Result(consumed: true) }
            origins = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
            last = origins; phase = .moving
        }
        if phase == .ending {
            guard now.timeIntervalSince(lifted) <= 0.12, contacts.count < 2,
                  contacts.allSatisfy({ last[$0.id] != nil }) else { return reject(contacts) }
            if contacts.isEmpty { phase = .idle; return Result(consumed: true, completion: completion) }
            return Result(consumed: true)
        }
        guard now.timeIntervalSince(started) <= max(maximumDuration, tapDuration ?? 0),
              contacts.allSatisfy({ finger in
                  guard let previous = last[finger.id] else { return false }
                  return hypot(finger.x - previous.x, finger.y - previous.y) < 400
              }) else { return reject(contacts) }
        if contacts.count == 2 {
            last = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
            for (id, point) in last { travel = max(travel, hypot(point.x - origins[id]!.x, point.y - origins[id]!.y)) }
            return Result(consumed: true)
        }
        // Freeze the displacement at the last report containing both fingers.
        // Do not turn staggered lifts into extra movement or a new gesture.
        let dx = last.reduce(0.0) { $0 + $1.value.x - origins[$1.key]!.x } / 2
        let dy = last.reduce(0.0) { $0 + $1.value.y - origins[$1.key]!.y } / 2
        let distance = hypot(dx, dy)
        if let tapDuration, now <= tapDeadline, now.timeIntervalSince(started) <= tapDuration,
           travel <= tapRadius, travel < settings.resolvedDistance {
            completion = .tap
        } else if started <= swipeDeadline, now.timeIntervalSince(started) <= maximumDuration,
                  distance >= settings.resolvedDistance,
                  last.allSatisfy({ id, point in
                      let x = point.x - origins[id]!.x, y = point.y - origins[id]!.y
                      return (x * dx + y * dy) / max(distance, 1) >= settings.resolvedDistance / 3
                  }), let direction = SwipeDirection.classify(dx: dx, dy: dy) {
            completion = .swipe(direction)
        } else { completion = .fallback }
        if contacts.isEmpty { phase = .idle; return Result(consumed: true, completion: completion) }
        lifted = now; phase = .ending
        return Result(consumed: true)
    }
}
