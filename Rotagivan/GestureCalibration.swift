import Foundation

enum GestureCalibrationMode: String, CaseIterable {
    case doubleTap
    case doubleTapSwipe
    case singleTapSwipe
}

struct GestureCalibrationSample: Equatable {
    let doubleTapInterval: Double
    let swipeWindow: Double?
    var swipeDuration: Double? = nil
}

/// A deterministic, side-effect-free recorder for gesture calibration.
///
/// Reports and timestamps are supplied by the caller so calibration can use the
/// same HID stream as the gesture engine without timers or saved gesture values.
struct GestureCalibrationRecorder {
    private static let requiredSampleCount = 10
    private static let quietDuration = 0.7
    private static let doubleTapTrainingWindow = 1.5
    private static let swipeTrainingWindow = 1.5
    private static let swipeMaxDuration = 0.7
    private static let sensorJumpDistance = 400.0

    private struct ActiveContact {
        let id: UInt8
        let startedAt: TimeInterval
        let originX: Double
        let originY: Double
        var lastX: Double
        var lastY: Double
        var maximumMovement: Double
    }

    private enum Phase {
        case quiet(since: TimeInterval?)
        case ready
        case tapping(number: Int, firstLift: TimeInterval?, contact: ActiveContact)
        case waitingForSecondTap(firstLift: TimeInterval)
        case waitingForSwipe(secondLift: TimeInterval, doubleTapInterval: Double)
        case swiping(secondLift: TimeInterval, doubleTapInterval: Double, contact: ActiveContact)
    }

    let mode: GestureCalibrationMode
    let tapMaxDuration: Double
    let tapMaxMovement: Double
    let swipeDistance: Double

    private(set) var samples: [GestureCalibrationSample] = []
    private(set) var instruction: String
    private var phase: Phase = .quiet(since: nil)

    var isComplete: Bool { samples.count == Self.requiredSampleCount }

    var medianDoubleTapInterval: Double? {
        median(samples.map(\.doubleTapInterval))
    }

    var medianSwipeWindow: Double? {
        median(samples.compactMap(\.swipeWindow))
    }
    var medianSwipeDuration: Double? { median(samples.compactMap(\.swipeDuration)) }
    private var maximumSwipeDuration: Double { mode == .singleTapSwipe ? 0.3 : Self.swipeMaxDuration }
    private var maximumSwipeWindow: Double { mode == .singleTapSwipe ? 0.8 : Self.swipeTrainingWindow }

    init(mode: GestureCalibrationMode, tapMaxDuration: Double, tapMaxMovement: Double, swipeDistance: Double) {
        self.mode = mode
        self.tapMaxDuration = tapMaxDuration
        self.tapMaxMovement = tapMaxMovement
        self.swipeDistance = swipeDistance
        instruction = "Lift all fingers and pause to begin calibration."
    }

    mutating func process(_ report: TrackpadReport, at now: TimeInterval) {
        guard !isComplete else { return }

        let touching = report.contacts.filter(\.touching)
        let inputIsInvalid = report.buttonDown || touching.contains(where: { !$0.confident }) || touching.count > 1

        switch phase {
        case .quiet(let since):
            guard !report.buttonDown else {
                phase = .quiet(since: nil)
                return
            }
            if touching.isEmpty {
                guard let since else {
                    phase = .quiet(since: now)
                    return
                }
                if now - since >= Self.quietDuration {
                    phase = .ready
                    setReadyInstruction()
                }
                return
            }
            guard let since,
                  now - since >= Self.quietDuration,
                  touching.count == 1,
                  let finger = touching.first,
                  finger.confident else {
                phase = .quiet(since: nil)
                return
            }
            phase = .tapping(number: 1, firstLift: nil, contact: makeContact(finger, at: now))
            setTapInstruction(number: 1)

        case .ready:
            guard !inputIsInvalid else {
                reject(at: now, alreadyLifted: touching.isEmpty)
                return
            }
            guard let finger = touching.first else { return }
            phase = .tapping(number: 1, firstLift: nil, contact: makeContact(finger, at: now))
            setTapInstruction(number: 1)

        case .tapping(let number, let firstLift, var contact):
            guard !inputIsInvalid else {
                reject(at: now, alreadyLifted: touching.isEmpty)
                return
            }
            guard let finger = touching.first else {
                finishTap(number: number, firstLift: firstLift, contact: contact, at: now)
                return
            }
            guard finger.id == contact.id,
                  now - contact.startedAt <= tapMaxDuration,
                  distance(fromX: contact.lastX, y: contact.lastY, toX: finger.x, y: finger.y) < Self.sensorJumpDistance else {
                reject(at: now, alreadyLifted: false)
                return
            }
            contact.lastX = finger.x
            contact.lastY = finger.y
            contact.maximumMovement = max(
                contact.maximumMovement,
                distance(fromX: contact.originX, y: contact.originY, toX: finger.x, y: finger.y)
            )
            guard contact.maximumMovement <= tapMaxMovement else {
                reject(at: now, alreadyLifted: false)
                return
            }
            phase = .tapping(number: number, firstLift: firstLift, contact: contact)

        case .waitingForSecondTap(let firstLift):
            guard !inputIsInvalid, now - firstLift <= Self.doubleTapTrainingWindow else {
                reject(at: now, alreadyLifted: touching.isEmpty)
                return
            }
            guard let finger = touching.first else { return }
            phase = .tapping(number: 2, firstLift: firstLift, contact: makeContact(finger, at: now))
            setTapInstruction(number: 2)

        case let .waitingForSwipe(secondLift, doubleTapInterval):
            guard !inputIsInvalid, now - secondLift <= maximumSwipeWindow else {
                reject(at: now, alreadyLifted: touching.isEmpty)
                return
            }
            guard let finger = touching.first else { return }
            phase = .swiping(
                secondLift: secondLift,
                doubleTapInterval: doubleTapInterval,
                contact: makeContact(finger, at: now)
            )
            setSwipeInstruction()

        case .swiping(let secondLift, let doubleTapInterval, var contact):
            guard !inputIsInvalid else {
                reject(at: now, alreadyLifted: touching.isEmpty)
                return
            }
            guard let finger = touching.first else {
                finishSwipe(secondLift: secondLift, doubleTapInterval: doubleTapInterval, contact: contact, at: now)
                return
            }
            guard finger.id == contact.id,
                  now - contact.startedAt <= maximumSwipeDuration,
                  distance(fromX: contact.lastX, y: contact.lastY, toX: finger.x, y: finger.y) < Self.sensorJumpDistance else {
                reject(at: now, alreadyLifted: false)
                return
            }
            contact.lastX = finger.x
            contact.lastY = finger.y
            phase = .swiping(secondLift: secondLift, doubleTapInterval: doubleTapInterval, contact: contact)
        }
    }

    mutating func tick(at now: TimeInterval) {
        guard !isComplete else { return }

        switch phase {
        case .quiet(let since):
            if let since, now - since >= Self.quietDuration {
                phase = .ready
                setReadyInstruction()
            }
        case .tapping(_, _, let contact):
            if now - contact.startedAt > tapMaxDuration {
                reject(at: now, alreadyLifted: false)
            }
        case .waitingForSecondTap(let firstLift):
            if now - firstLift > Self.doubleTapTrainingWindow {
                reject(at: now, alreadyLifted: true)
            }
        case .waitingForSwipe(let secondLift, _):
            if now - secondLift > maximumSwipeWindow {
                reject(at: now, alreadyLifted: true)
            }
        case .swiping(_, _, let contact):
            if now - contact.startedAt > maximumSwipeDuration {
                reject(at: now, alreadyLifted: false)
            }
        case .ready:
            break
        }
    }

    private mutating func finishTap(
        number: Int,
        firstLift: TimeInterval?,
        contact: ActiveContact,
        at now: TimeInterval
    ) {
        guard now - contact.startedAt <= tapMaxDuration,
              contact.maximumMovement <= tapMaxMovement else {
            reject(at: now, alreadyLifted: true)
            return
        }

        if number == 1 {
            if mode == .singleTapSwipe {
                phase = .waitingForSwipe(secondLift: now, doubleTapInterval: 0)
                instruction = "Trial \(trialNumber) of \(Self.requiredSampleCount): swipe quickly, then lift (under 300 ms)."
                return
            }
            phase = .waitingForSecondTap(firstLift: now)
            instruction = "Trial \(trialNumber) of \(Self.requiredSampleCount): complete the second tap."
            return
        }

        guard let firstLift else {
            reject(at: now, alreadyLifted: true)
            return
        }
        let doubleTapInterval = now - firstLift
        guard doubleTapInterval <= Self.doubleTapTrainingWindow else {
            reject(at: now, alreadyLifted: true)
            return
        }
        if mode == .doubleTap {
            accept(GestureCalibrationSample(doubleTapInterval: doubleTapInterval, swipeWindow: nil), at: now)
        } else {
            phase = .waitingForSwipe(secondLift: now, doubleTapInterval: doubleTapInterval)
            instruction = "Trial \(trialNumber) of \(Self.requiredSampleCount): begin the swipe."
        }
    }

    private mutating func finishSwipe(
        secondLift: TimeInterval,
        doubleTapInterval: Double,
        contact: ActiveContact,
        at now: TimeInterval
    ) {
        guard now - contact.startedAt <= maximumSwipeDuration else {
            reject(at: now, alreadyLifted: true)
            return
        }
        let dx = contact.lastX - contact.originX
        let dy = contact.lastY - contact.originY
        guard hypot(dx, dy) >= swipeDistance,
              SwipeDirection.classify(dx: dx, dy: dy) != nil else {
            reject(at: now, alreadyLifted: true)
            return
        }
        accept(GestureCalibrationSample(
            doubleTapInterval: doubleTapInterval,
            swipeWindow: contact.startedAt - secondLift,
            swipeDuration: now - contact.startedAt
        ), at: now)
    }

    private mutating func accept(_ sample: GestureCalibrationSample, at now: TimeInterval) {
        samples.append(sample)
        if isComplete {
            instruction = "Calibration complete."
        } else {
            phase = .quiet(since: now)
            instruction = "Trial \(trialNumber) of \(Self.requiredSampleCount): lift all fingers and pause."
        }
    }

    private mutating func reject(at now: TimeInterval, alreadyLifted: Bool) {
        phase = .quiet(since: alreadyLifted ? now : nil)
        instruction = "Trial \(trialNumber) of \(Self.requiredSampleCount): attempt not recorded; lift all fingers and pause."
    }

    private mutating func setReadyInstruction() {
        instruction = "Trial \(trialNumber) of \(Self.requiredSampleCount): \(mode == .singleTapSwipe ? "tap once, then swipe quickly and lift." : "tap twice.")"
    }

    private mutating func setTapInstruction(number: Int) {
        instruction = "Trial \(trialNumber) of \(Self.requiredSampleCount): tap \(number) of \(mode == .singleTapSwipe ? 1 : 2)."
    }

    private mutating func setSwipeInstruction() {
        instruction = "Trial \(trialNumber) of \(Self.requiredSampleCount): swipe horizontally, vertically, or diagonally, then lift."
    }

    private var trialNumber: Int { min(samples.count + 1, Self.requiredSampleCount) }

    private func makeContact(_ finger: FingerContact, at now: TimeInterval) -> ActiveContact {
        ActiveContact(
            id: finger.id,
            startedAt: now,
            originX: finger.x,
            originY: finger.y,
            lastX: finger.x,
            lastY: finger.y,
            maximumMovement: 0
        )
    }

    private func distance(fromX x1: Double, y y1: Double, toX x2: Double, y y2: Double) -> Double {
        hypot(x2 - x1, y2 - y1)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
