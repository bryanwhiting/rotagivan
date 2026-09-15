import CoreGraphics
import Foundation

@MainActor
final class GestureEngine {
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
        momentumTimer = nil
        pendingDragEnd = nil
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
        } else if store.settings.gestures.touchAndHoldDrag,
                  now.timeIntervalSince(lastTap) <= store.settings.gestures.tapMaxDuration {
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
        guard maximumMovement > store.settings.gestures.tapMaxMovement else { return }
        let profile = store.activeProfile
        let dx = rawDX * profile.scrollMultiplier * (profile.invertScrollX ? -1 : 1)
        let dy = rawDY * profile.scrollMultiplier * (profile.invertScrollY ? -1 : 1)
        poster.scroll(dx: dx, dy: dy)
        let dt = max(0.001, now.timeIntervalSince(lastReportTime))
        scrollVelocity = CGVector(dx: dx / dt, dy: dy / dt)
        scrolling = true
    }

    private func finishTouch(at now: Date) {
        let gestures = store.settings.gestures
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
        let action = hadTwoFingers ? (store.settings.twoFingerTap ?? .enter) : (store.settings.oneFingerTap ?? .optionF19)
        poster.performTap(action)
        // A keyboard tap must not arm mouse dragging on the next touch.
        if !hadTwoFingers && action == .leftClick { lastTap = now }
        else { lastTap = .distantPast }
    }

    private func handlePhysicalButton(_ down: Bool) {
        guard down != physicalButtonDown else { return }
        physicalButtonDown = down
        if down { poster.beginDrag() } else { poster.endDrag() }
    }

    private func startMomentum() {
        momentumTimer?.invalidate()
        var velocity = scrollVelocity
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let decay = self.store.activeProfile.kineticDecay
                velocity.dx *= decay
                velocity.dy *= decay
                if hypot(velocity.dx, velocity.dy) < 30 {
                    timer.invalidate()
                    self.momentumTimer = nil
                    return
                }
                self.poster.scroll(dx: velocity.dx / 60.0, dy: velocity.dy / 60.0, momentum: true)
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
