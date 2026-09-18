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

    mutating func arm(at now: Date, settings: DoubleTapSwipeSettings,
                      tripleTapDuration: Double? = nil, tripleTapRadius: Double = 0,
                      tripleTapInterval: Double = 0.3) {
        swipeDeadline = now.addingTimeInterval(settings.resolvedWindow)
        tripleDeadline = tripleTapDuration == nil ? .distantPast : now.addingTimeInterval(tripleTapInterval)
        phase = .waiting(max(swipeDeadline, tripleDeadline))
        distance = settings.resolvedDistance
        tripleDuration = tripleTapDuration
        tripleRadius = tripleTapRadius
        maximumMovement = 0
    }

    mutating func cancel() {
        switch phase {
        case .swiping, .untilLift: phase = .untilLift
        default: phase = .idle
        }
    }

    mutating func update(_ contacts: [FingerContact], at now: Date) -> Result {
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
        guard case .waiting(let deadline) = phase, now >= deadline else { return false }
        phase = .idle
        return true
    }
}
