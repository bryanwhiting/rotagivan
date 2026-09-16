import CoreGraphics
import Foundation

@MainActor
final class GestureEngine {
    private static let tapDragHoldDelay = 0.12
    private static let tapDragMovementThreshold = 4.0

    private struct PendingTap {
        var fingerCount: Int
        var action: TapAction
        var shortcut: RecordedShortcut?
        var date: Date
    }

    private let store: SettingsStore
    private let poster = EventPoster()
    private var previousContacts: [UInt8: FingerContact] = [:]
    private var touchStart = Date.distantPast
    private var touchOrigin: CGPoint = .zero
    private var maximumMovement = 0.0
    private var lastTap = Date.distantPast
    private var hadTwoFingers = false
    private var scrolling = false
    private var scrollVelocity = CGVector.zero
    private var cursorVelocity = CGVector.zero
    private var cursorTiming = CursorTiming()
    private var cursorFilter = CursorVelocityFilter()
    private var cursorGainFilter = CursorGainFilter()
    private var cursorInterval = 1.0 / 125
    private var lastCursorProfileID: UInt32 = 0
    private var lastReportTime = Date.distantPast
    private var momentumTimer: Timer?
    private var cursorDecelerationTimer: Timer?
    private var pendingDragEnd: Timer?
    private var pendingDragEndAt: Date?
    private var pendingTapTimer: Timer?
    private var pendingTap: PendingTap?
    private var physicalButtonDown = false
    private var keyboardDrag = false
    // A tap-and-hold drag ends with its finger lift. Re-grip only applies to
    // a physical-button drag; otherwise the synthetic left button can linger.
    private var tapDragActive = false
    private var tapDragCandidate = false
    private var tapDragStartTimer: Timer?

    func keyboardAction(_ id: UInt32, down: Bool) {
        if id == 5 {
            if down {
                pendingDragEnd?.invalidate()
                momentumTimer?.invalidate()
                cursorDecelerationTimer?.invalidate()
                cursorDecelerationTimer = nil
                keyboardDrag = true
                poster.beginDrag()
            } else if keyboardDrag {
                keyboardDrag = false
                poster.endDrag()
            }
        } else if down && !poster.dragging {
            poster.click(count: id == 4 ? 2 : 1)
        }
    }

    init(store: SettingsStore) {
        self.store = store
    }

    func reset() {
        keyboardDrag = false
        tapDragActive = false
        tapDragCandidate = false
        momentumTimer?.invalidate()
        cursorDecelerationTimer?.invalidate()
        pendingDragEnd?.invalidate()
        pendingTapTimer?.invalidate()
        tapDragStartTimer?.invalidate()
        momentumTimer = nil
        cursorDecelerationTimer = nil
        pendingDragEnd = nil
        pendingDragEndAt = nil
        pendingTapTimer = nil
        tapDragStartTimer = nil
        pendingTap = nil
        previousContacts.removeAll()
        poster.endDrag()
        scrolling = false
        physicalButtonDown = false
        lastTap = .distantPast
        scrollVelocity = .zero
        cursorVelocity = .zero
        cursorFilter = CursorVelocityFilter()
        cursorTiming = CursorTiming()
        cursorGainFilter = CursorGainFilter()
        store.cursorTelemetry.reset()
    }

    func process(_ report: TrackpadReport, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard store.settings.enabled else { reset(); return }
        cursorInterval = cursorTiming.interval(scanTime: report.scanTime, receivedAt: receivedAt)
        let now = Date()
        let current = report.contacts.filter { $0.touching && $0.confident }
        let previousCount = previousContacts.values.filter(\.touching).count

        handlePhysicalButton(report.buttonDown)

        if current.isEmpty {
            store.cursorTelemetry.endTouch()
            if let deadline = pendingDragEndAt, now >= deadline {
                pendingDragEnd?.invalidate()
                pendingDragEnd = nil
                pendingDragEndAt = nil
                poster.endDrag()
            }
            if previousCount > 0 { finishTouch(at: now) }
            previousContacts.removeAll()
            lastReportTime = now
            return
        }

        if previousCount == 0 {
            beginTouch(current, at: now)
        }

        hadTwoFingers = hadTwoFingers || current.count >= 2
        if current.count >= 2 {
            store.cursorTelemetry.endTouch()
            handleScroll(current, at: now)
        } else if let finger = current.first {
            handleCursor(finger, at: now)
        }

        previousContacts = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        lastReportTime = now
    }

    private func beginTouch(_ contacts: [FingerContact], at now: Date) {
        momentumTimer?.invalidate()
        momentumTimer = nil
        cursorDecelerationTimer?.invalidate()
        cursorDecelerationTimer = nil
        touchStart = now
        touchOrigin = centroid(contacts)
        maximumMovement = 0
        hadTwoFingers = contacts.count >= 2
        scrolling = false
        scrollVelocity = .zero
        cursorVelocity = .zero
        cursorFilter = CursorVelocityFilter()
        cursorGainFilter = CursorGainFilter()

        if poster.dragging {
            pendingDragEnd?.invalidate()
            pendingDragEnd = nil
            pendingDragEndAt = nil
        } else if store.activeGestures.gestures.touchAndHoldDrag {
            let followsCompletedClick = now.timeIntervalSince(lastTap) <= store.activeGestures.gestures.tapMaxDuration
            let followsPendingLeftClick = pendingTap?.fingerCount == 1 &&
                pendingTap?.action == .leftClick &&
                now.timeIntervalSince(pendingTap?.date ?? .distantPast) <= store.activeGestures.gestures.resolvedDoubleTapInterval
            if followsCompletedClick || followsPendingLeftClick {
                // Do not turn a normal tap-tap into a drag. The second touch
                // becomes a drag only when it is held or moved; a quick lift
                // continues through registerTap as the configured double tap.
                tapDragCandidate = true
                tapDragStartTimer?.invalidate()
                tapDragStartTimer = Timer.scheduledTimer(withTimeInterval: Self.tapDragHoldDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startTapDrag() }
                }
            }
        }
    }

    private func handleCursor(_ finger: FingerContact, at now: Date) {
        guard !hadTwoFingers else { return }
        guard let previous = previousContacts[finger.id] else { return }
        let rawDX = finger.x - previous.x
        let rawDY = finger.y - previous.y
        maximumMovement = max(maximumMovement, hypot(finger.x - touchOrigin.x, finger.y - touchOrigin.y))
        let profile = store.activeProfile
        let magnitude = hypot(rawDX, rawDY)
        if tapDragCandidate, magnitude >= Self.tapDragMovementThreshold {
            startTapDrag()
        }
        guard magnitude < 400 else { cursorVelocity = .zero; return }
        if lastCursorProfileID != store.activeProfileID {
            cursorFilter = CursorVelocityFilter()
            cursorGainFilter = CursorGainFilter()
            lastCursorProfileID = store.activeProfileID
        }
        let curve = profile.resolvedCursorResponse
        let dt = cursorInterval
        let fingerSpeed = cursorFilter.update(dx: rawDX, dy: rawDY, dt: dt, smoothing: curve.smoothing)
        let targetGain = curve.gain(at: fingerSpeed)
        let scale = cursorGainFilter.update(target: targetGain, dt: dt, smoothing: curve.smoothing)
        let dx = rawDX * scale
        let dy = rawDY * scale
        poster.move(dx: dx, dy: dy)
        cursorVelocity = CGVector(dx: dx / dt, dy: dy / dt)
        store.cursorTelemetry.record(CursorSample(profileID: store.activeProfileID, speed: fingerSpeed, gain: scale, touching: true))
    }

    private func handleScroll(_ contacts: [FingerContact], at now: Date) {
        let matching = contacts.compactMap { current -> (FingerContact, FingerContact)? in
            guard let previous = previousContacts[current.id] else { return nil }
            return (current, previous)
        }
        guard !matching.isEmpty else { return }
        let rawDX = matching.map { $0.0.x - $0.1.x }.reduce(0, +) / Double(matching.count)
        let rawDY = matching.map { $0.0.y - $0.1.y }.reduce(0, +) / Double(matching.count)
        maximumMovement += hypot(rawDX, rawDY)
        guard maximumMovement > store.activeGestures.gestures.tapMaxMovement else { return }
        let profile = store.activeProfile
        let dt = max(0.001, now.timeIntervalSince(lastReportTime))
        let fingerSpeed = hypot(rawDX, rawDY) / dt
        let acceleration = profile.resolvedScrollAcceleration
        let accelerationGain = pow(max(1, fingerSpeed / ProfileMaximum.scrollAccelerationOnset), acceleration - 1)
        let dx = rawDX * profile.scrollMultiplier * accelerationGain * (profile.invertScrollX ? -1 : 1)
        let dy = rawDY * profile.scrollMultiplier * accelerationGain * (profile.invertScrollY ? -1 : 1)
        poster.scroll(dx: dx, dy: dy)
        let instantaneous = CGVector(dx: dx / dt, dy: dy / dt)
        // A flick often slows just before lift-off. Blend the final samples so
        // the release retains the swipe's real intent instead of only its last
        // tiny movement.
        let sameDirection = scrollVelocity.dx * instantaneous.dx + scrollVelocity.dy * instantaneous.dy >= 0
        scrollVelocity = sameDirection
            ? CGVector(dx: scrollVelocity.dx * 0.35 + instantaneous.dx * 0.65,
                       dy: scrollVelocity.dy * 0.35 + instantaneous.dy * 0.65)
            : instantaneous
        scrolling = true
    }

    private func finishTouch(at now: Date) {
        let gestures = store.activeGestures.gestures
        let duration = now.timeIntervalSince(touchStart)

        // A quick second tap is still a double tap, not a drag.
        tapDragCandidate = false
        tapDragStartTimer?.invalidate()
        tapDragStartTimer = nil

        if scrolling {
            if store.activeProfile.kineticScroll { startMomentum() }
            scrolling = false
            if !poster.dragging { return }
        }

        if !hadTwoFingers && !poster.dragging { startCursorDeceleration() }

        if poster.dragging {
            if tapDragActive {
                tapDragActive = false
                pendingDragEnd?.invalidate()
                pendingDragEnd = nil
                pendingDragEndAt = nil
                poster.endDrag()
                return
            }
            guard !physicalButtonDown && !keyboardDrag else { return }
            if gestures.dragRegrip {
                pendingDragEnd?.invalidate()
                pendingDragEndAt = now.addingTimeInterval(gestures.dragRegripWindow)
                pendingDragEnd = Timer.scheduledTimer(withTimeInterval: gestures.dragRegripWindow, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.pendingDragEnd = nil
                        self?.pendingDragEndAt = nil
                        self?.poster.endDrag()
                    }
                }
            } else {
                pendingDragEndAt = nil
                poster.endDrag()
            }
            return
        }

        guard gestures.tapToClick,
              duration <= gestures.tapMaxDuration,
              maximumMovement <= gestures.tapMaxMovement else { return }
        registerTap(fingerCount: hadTwoFingers ? 2 : 1, at: now)
    }

    private func registerTap(fingerCount: Int, at now: Date) {
        let active = store.activeGestures
        let doubleTapInterval = active.gestures.resolvedDoubleTapInterval
        let action = fingerCount == 2 ? active.twoFingerTap : active.oneFingerTap
        let shortcut = fingerCount == 2 ? active.twoFingerShortcut : active.oneFingerShortcut
        let doubleAction = fingerCount == 2 ? (active.twoFingerDoubleTap ?? .none) : (active.oneFingerDoubleTap ?? .none)
        let doubleShortcut = fingerCount == 2 ? active.twoFingerDoubleShortcut : active.oneFingerDoubleShortcut

        if let pendingTap {
            if pendingTap.fingerCount == fingerCount, now.timeIntervalSince(pendingTap.date) <= doubleTapInterval {
                pendingTapTimer?.invalidate()
                self.pendingTap = nil
                pendingTapTimer = nil
                performTap(doubleAction, shortcut: doubleShortcut, at: now)
                return
            }
            pendingTapTimer?.invalidate()
            performTap(pendingTap.action, shortcut: pendingTap.shortcut, at: pendingTap.date)
            self.pendingTap = nil
            pendingTapTimer = nil
        }

        guard doubleAction != .none else {
            performTap(action, shortcut: shortcut, at: now)
            return
        }
        pendingTap = PendingTap(fingerCount: fingerCount, action: action, shortcut: shortcut, date: now)
        pendingTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let pending = self.pendingTap else { return }
                self.pendingTap = nil
                self.pendingTapTimer = nil
                self.performTap(pending.action, shortcut: pending.shortcut, at: pending.date)
            }
        }
    }

    private func performTap(_ action: TapAction, shortcut: RecordedShortcut?, at date: Date) {
        poster.performTap(action, shortcut: shortcut)
        // Only a real single-finger click may arm tap-hold dragging.
        lastTap = action == .leftClick ? date : .distantPast
    }

    private func startTapDrag() {
        guard tapDragCandidate, !poster.dragging else { return }
        tapDragCandidate = false
        tapDragStartTimer?.invalidate()
        tapDragStartTimer = nil
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        pendingTap = nil
        tapDragActive = true
        poster.beginDrag()
    }

    private func handlePhysicalButton(_ down: Bool) {
        guard down != physicalButtonDown else { return }
        physicalButtonDown = down
        if down {
            cursorDecelerationTimer?.invalidate()
            cursorDecelerationTimer = nil
            poster.beginDrag()
        } else { poster.endDrag() }
    }

    private func startMomentum() {
        momentumTimer?.invalidate()
        // The hardware reports short, high-frequency coordinate deltas. A
        // modest boost turns a deliberate flick into visible page coasting.
        var velocity = CGVector(dx: scrollVelocity.dx * 2.2, dy: scrollVelocity.dy * 2.2)
        let initialSpeed = hypot(velocity.dx, velocity.dy)
        // End the exponential tail after it reaches 1.5% of the release
        // velocity. A literal coefficient of 1 is intentionally unbounded.
        let terminalSpeed = initialSpeed * 0.015
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let decay = self.store.activeProfile.kineticDecay
                let delta = CGVector(dx: velocity.dx / 60.0, dy: velocity.dy / 60.0)
                let glidesContinuously = decay >= 0.999_999
                if (!glidesContinuously && hypot(velocity.dx, velocity.dy) <= terminalSpeed) || decay <= 0 {
                    timer.invalidate()
                    self.momentumTimer = nil
                    return
                }
                self.poster.scroll(dx: delta.dx, dy: delta.dy, momentum: true)
                velocity.dx *= decay
                velocity.dy *= decay
            }
        }
    }

    private func startCursorDeceleration() {
        cursorDecelerationTimer?.invalidate()
        cursorDecelerationTimer = nil
        let curve = store.activeProfile.resolvedCursorResponse
        let duration = curve.releaseDuration(at: cursorFilter.speed)
        let velocity = cursorVelocity
        guard duration > 0, hypot(velocity.dx, velocity.dy) > 0 else { return }
        let started = ProcessInfo.processInfo.systemUptime
        var previousElapsed = 0.0
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let integral = curve.releaseIntegral(from: previousElapsed, to: elapsed, duration: duration)
                self.poster.move(dx: velocity.dx * integral, dy: velocity.dy * integral)
                previousElapsed = elapsed
                if elapsed >= duration {
                    timer.invalidate()
                    self.cursorDecelerationTimer = nil
                }
            }
        }
        cursorDecelerationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func centroid(_ contacts: [FingerContact]) -> CGPoint {
        guard !contacts.isEmpty else { return .zero }
        return CGPoint(
            x: contacts.map(\.x).reduce(0, +) / Double(contacts.count),
            y: contacts.map(\.y).reduce(0, +) / Double(contacts.count)
        )
    }
}
