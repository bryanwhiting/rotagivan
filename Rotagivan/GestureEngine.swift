import CoreGraphics
import Foundation

@MainActor
final class GestureEngine {
    private struct PendingTap {
        var fingerCount: Int
        var action: TapAction
        var shortcut: RecordedShortcut?
        var date: Date
    }

    private static let doubleTapInterval = 0.30
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
    private var lastReportTime = Date.distantPast
    private var momentumTimer: Timer?
    private var pendingDragEnd: Timer?
    private var pendingTapTimer: Timer?
    private var pendingTap: PendingTap?
    private var physicalButtonDown = false
    private var keyboardDrag = false

    func keyboardAction(_ id: UInt32, down: Bool) {
        if id == 5 {
            if down {
                pendingDragEnd?.invalidate()
                momentumTimer?.invalidate()
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
        momentumTimer?.invalidate()
        pendingDragEnd?.invalidate()
        pendingTapTimer?.invalidate()
        momentumTimer = nil
        pendingDragEnd = nil
        pendingTapTimer = nil
        pendingTap = nil
        previousContacts.removeAll()
        poster.endDrag()
        scrolling = false
        physicalButtonDown = false
        lastTap = .distantPast
        scrollVelocity = .zero
    }

    func process(_ report: TrackpadReport) {
        guard store.settings.enabled else { reset(); return }
        let now = Date()
        let current = report.contacts.filter { $0.touching && $0.confident }
        let previousCount = previousContacts.values.filter(\.touching).count

        handlePhysicalButton(report.buttonDown)

        if current.isEmpty {
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
        touchStart = now
        touchOrigin = centroid(contacts)
        maximumMovement = 0
        hadTwoFingers = contacts.count >= 2
        scrolling = false
        scrollVelocity = .zero

        if poster.dragging {
            pendingDragEnd?.invalidate()
            pendingDragEnd = nil
        } else if store.activeGestures.gestures.touchAndHoldDrag,
                  now.timeIntervalSince(lastTap) <= store.activeGestures.gestures.tapMaxDuration {
            poster.beginDrag()
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
        guard magnitude > 0, magnitude < 400 else { return }
        let scaledMagnitude = pow(magnitude, profile.cursorAcceleration) * profile.cursorSpeed
        let scale = scaledMagnitude / magnitude
        poster.move(dx: rawDX * scale, dy: rawDY * scale)
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
        let dx = rawDX * profile.scrollMultiplier * (profile.invertScrollX ? -1 : 1)
        let dy = rawDY * profile.scrollMultiplier * (profile.invertScrollY ? -1 : 1)
        poster.scroll(dx: dx, dy: dy)
        let dt = max(0.001, now.timeIntervalSince(lastReportTime))
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

        if scrolling {
            if store.activeProfile.kineticScroll { startMomentum() }
            scrolling = false
            if !poster.dragging { return }
        }

        if poster.dragging {
            guard !physicalButtonDown && !keyboardDrag else { return }
            if gestures.dragRegrip {
                pendingDragEnd?.invalidate()
                pendingDragEnd = Timer.scheduledTimer(withTimeInterval: gestures.dragRegripWindow, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.poster.endDrag() }
                }
            } else {
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
        let action = fingerCount == 2 ? active.twoFingerTap : active.oneFingerTap
        let shortcut = fingerCount == 2 ? active.twoFingerShortcut : active.oneFingerShortcut
        let doubleAction = fingerCount == 2 ? (active.twoFingerDoubleTap ?? .none) : (active.oneFingerDoubleTap ?? .none)
        let doubleShortcut = fingerCount == 2 ? active.twoFingerDoubleShortcut : active.oneFingerDoubleShortcut

        if let pendingTap {
            if pendingTap.fingerCount == fingerCount, now.timeIntervalSince(pendingTap.date) <= Self.doubleTapInterval {
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
        pendingTapTimer = Timer.scheduledTimer(withTimeInterval: Self.doubleTapInterval, repeats: false) { [weak self] _ in
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

    private func handlePhysicalButton(_ down: Bool) {
        guard down != physicalButtonDown else { return }
        physicalButtonDown = down
        if down { poster.beginDrag() } else { poster.endDrag() }
    }

    private func startMomentum() {
        momentumTimer?.invalidate()
        // The hardware reports short, high-frequency coordinate deltas. A
        // modest boost turns a deliberate flick into visible page coasting.
        var velocity = CGVector(dx: scrollVelocity.dx * 2.2, dy: scrollVelocity.dy * 2.2)
        var ticks = 0
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let decay = self.store.activeProfile.kineticDecay
                let delta = CGVector(dx: velocity.dx / 60.0, dy: velocity.dy / 60.0)
                if hypot(delta.dx, delta.dy) < 0.08 || ticks >= 600 || decay <= 0 {
                    timer.invalidate()
                    self.momentumTimer = nil
                    return
                }
                self.poster.scroll(dx: delta.dx, dy: delta.dy, momentum: true)
                velocity.dx *= decay
                velocity.dy *= decay
                ticks += 1
            }
        }
    }

    private func centroid(_ contacts: [FingerContact]) -> CGPoint {
        guard !contacts.isEmpty else { return .zero }
        return CGPoint(
            x: contacts.map(\.x).reduce(0, +) / Double(contacts.count),
            y: contacts.map(\.y).reduce(0, +) / Double(contacts.count)
        )
    }
}
