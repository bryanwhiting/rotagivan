import CoreGraphics
import Foundation

@MainActor
final class GestureEngine {
    enum InputMode {
        case navigator
        case nativeActions
    }

    var onAppExplorer: (() -> Void)?
    var onWindowManager: (() -> Void)?
    var isEditingInterface = false {
        didSet { if oldValue != isEditingInterface { reset() } }
    }
    // Temporary UI interaction, never persisted to profiles: normal pointer and
    // scroll response, immediate click taps, and no app/keyboard swipe actions.
    private var activeGestures: ProfileGestures {
        guard isEditingInterface else { return store.activeGestures }
        var settings = store.activeGestures.gestures
        settings.tapToClick = true
        settings.tapMaxDuration = max(0.25, settings.tapMaxDuration)
        settings.tapMaxMovement = max(30, settings.tapMaxMovement)
        settings.keepCursorStillForTaps = true
        settings.touchAndHoldDrag = false
        return ProfileGestures(gestures: settings, oneFingerTap: .leftClick, twoFingerTap: .rightClick)
    }
    private static let tapDragHoldDelay = 0.12
    private static let tapDragMovementThreshold = 4.0
    // Repositioning for a drag takes longer than a quick double tap. This
    // minimum pickup window is independent of tap duration/calibration.
    private static let tapDragPickupWindow = 0.4

    private struct PendingTap {
        var profileID: UInt32
        var fingerCount: Int
        var action: TapAction
        var shortcut: RecordedShortcut?
        var date: Date
        var tapCount = 1
        var precedingSingles: [PendingTap] = []
        var configuration: ProfileGestures?
    }

    private let store: SettingsStore
    private let poster: any GestureEventPosting
    private let clock: () -> Date
    private let inputMode: InputMode
    private var synthesizesPointerEvents: Bool { inputMode == .navigator }
    private var syntheticDragActive: Bool { synthesizesPointerEvents && poster.dragging }
    private struct DeferredDoubleTap {
        var profileID: UInt32
        var settings: DoubleTapSwipeSettings
        var fallback: [PendingTap]
        var tripleAction: TapAction
        var tripleShortcut: RecordedShortcut?
        var configuration: ProfileGestures
        var isSingleTapSwipe = false
    }
    private var deferredDoubleTap: DeferredDoubleTap?
    private var swipeRecognizer = DoubleTapSwipeRecognizer()
    private var twoFingerNavigation = TwoFingerNavigationRecognizer()
    private var swipeTimer: Timer?
    private var singleSwipe: DoubleTapSwipeSettings?
    private var singleSwipeConfiguration: ProfileGestures?
    private var singleSwipeTimer: Timer?
    private var singleSwipeLast = CGPoint.zero
    private var singleSwipeBlocked = false
    private var previousContacts: [UInt8: FingerContact] = [:]
    private var touchStart = Date.distantPast
    private var touchOrigin: CGPoint = .zero
    private var maximumMovement = 0.0
    private var holdingTapMotion = false
    private var touchProfileID: UInt32?
    private var lastTap = Date.distantPast
    private var lastTapProfileID: UInt32?
    private var hadTwoFingers = false
    private var scrolling = false
    private var scrollVelocity = CGVector.zero
    private var scrollSpeedFilter = CursorVelocityFilter()
    private var scrollResponseSnapshot: ScrollResponse?
    private var scrollProfileID: UInt32 = 0
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
    private var touchHadPhysicalButton = false
    private var nativeContactBlocked = false
    private var keyboardDrag = false
    // A tap-and-hold drag ends with its finger lift. Re-grip only applies to
    // a physical-button drag; otherwise the synthetic left button can linger.
    private var tapDragActive = false
    private var tapDragCandidate = false
    private var tapDragProfileID: UInt32?
    private var tapDragStartTimer: Timer?

    func keyboardAction(_ id: UInt32, down: Bool) {
        guard synthesizesPointerEvents else { return }
        if id == 5 {
            if down {
                cancelTapSwipe(blockUntilLift: false)
                cancelPendingTap()
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

    init(store: SettingsStore, poster: any GestureEventPosting = EventPoster(),
         clock: @escaping () -> Date = Date.init, inputMode: InputMode = .navigator) {
        self.store = store
        self.poster = poster
        self.clock = clock
        self.inputMode = inputMode
    }

    func reset() {
        twoFingerNavigation = TwoFingerNavigationRecognizer()
        clearSingleSwipe()
        singleSwipeBlocked = false
        cancelTapSwipe(blockUntilLift: false)
        keyboardDrag = false
        tapDragActive = false
        tapDragCandidate = false
        tapDragProfileID = nil
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
        holdingTapMotion = false
        touchProfileID = nil
        if synthesizesPointerEvents { poster.endDrag() }
        scrolling = false
        physicalButtonDown = false
        touchHadPhysicalButton = false
        nativeContactBlocked = false
        lastTap = .distantPast
        lastTapProfileID = nil
        scrollVelocity = .zero
        scrollSpeedFilter = CursorVelocityFilter()
        cursorVelocity = .zero
        cursorFilter = CursorVelocityFilter()
        cursorTiming = CursorTiming()
        cursorGainFilter = CursorGainFilter()
        if synthesizesPointerEvents { store.cursorTelemetry.reset() }
    }

    // Switching input devices invalidates discrete gesture sequences, but is
    // not a new Navigator touch: preserve its cursor tail and scroll coasting.
    func cancelPendingActionsForSourceChange() {
        cancelPendingTap()
        cancelTapSwipe(blockUntilLift: false)
        cancelTapDragCandidate()
        lastTap = .distantPast
        lastTapProfileID = nil
    }

    func process(_ report: TrackpadReport, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard store.settings.enabled else { reset(); return }
        if !synthesizesPointerEvents {
            let touching = report.contacts.filter(\.touching)
            // Three/four-finger macOS gestures and uncertain/palm contacts must
            // never degrade into one/two-finger custom actions on partial lift.
            if touching.count > 2 || touching.contains(where: { !$0.confident }) {
                reset()
                nativeContactBlocked = true
                return
            }
            if nativeContactBlocked {
                if touching.isEmpty { nativeContactBlocked = false }
                return
            }
        }
        if synthesizesPointerEvents {
            cursorInterval = cursorTiming.interval(scanTime: report.scanTime, receivedAt: receivedAt)
        }
        let now = clock()
        let current = report.contacts.filter { $0.touching && $0.confident }
        let previousCount = previousContacts.values.filter(\.touching).count

        if tapDragCandidate, tapDragProfileID != store.activeProfileID { cancelTapDragCandidate() }

        handlePhysicalButton(report.buttonDown)

        if singleSwipe != nil && (current.count > 1 ||
            report.contacts.contains(where: { $0.touching && !$0.confident }) ||
            touchProfileID != store.activeProfileID || singleSwipeConfiguration != activeGestures ||
            (!current.isEmpty && current.first.map { previousContacts[$0.id] == nil } == true)) {
            clearSingleSwipe()
            cancelPendingTap()
            cancelTapDragCandidate()
            singleSwipeBlocked = true
        }
        if singleSwipeBlocked {
            previousContacts.removeAll()
            if !report.contacts.contains(where: \.touching) { singleSwipeBlocked = false }
            return
        }
        if let candidate = singleSwipe, now.timeIntervalSince(touchStart) > candidate.resolvedFastDuration {
            expireSingleSwipe()
        }

        if deferredDoubleTap != nil && report.contacts.contains(where: { $0.touching && !$0.confident }) {
            cancelTapSwipe()
        }

        if let pending = pendingTap, pending.profileID != store.activeProfileID ||
            pending.configuration != activeGestures { cancelPendingTap() }
        if let deferred = deferredDoubleTap,
           deferred.profileID != store.activeProfileID || !activeGestures.gestures.tapToClick ||
            deferred.configuration != activeGestures {
            cancelTapSwipe()
        }
        let swipe = swipeRecognizer.update(current, at: now)
        if let completion = swipe.completion {
            switch completion {
            case .fallback: finishDeferredDoubleTap()
            case .tap:
                let deferred = deferredDoubleTap
                cancelTapSwipe()
                if let deferred {
                    if deferred.isSingleTapSwipe {
                        // The follow-up was a second tap, not a swipe. Restore
                        // the first tap so normal double/triple arbitration runs.
                        pendingTap = deferred.fallback.first
                        registerTap(fingerCount: 2, at: now)
                    } else {
                        performTap(deferred.tripleAction, shortcut: deferred.tripleShortcut, at: now)
                    }
                }
            case .cancelled: cancelTapSwipe()
            case .swipe(let direction):
                let settings = deferredDoubleTap?.settings
                cancelTapSwipe()
                if let settings { dispatchTap(settings.action(for: direction), shortcut: settings[direction]) }
            }
        }
        if swipe.consumed {
            previousContacts.removeAll()
            momentumTimer?.invalidate(); momentumTimer = nil
            cursorDecelerationTimer?.invalidate(); cursorDecelerationTimer = nil
            cursorVelocity = .zero
            endCursorTelemetry()
            lastReportTime = now
            return
        }

        if previousCount == 0 && !current.isEmpty { beginTouch(current, at: now) }
        if current.count >= 2 {
            hadTwoFingers = true
            holdingTapMotion = false
            cancelTapDragCandidate()
        }
        if syntheticDragActive { twoFingerNavigation = TwoFingerNavigationRecognizer() }
        else {
            let settings = activeGestures.twoFingerSwipe
            let navigation = twoFingerNavigation.update(report, settings: settings, profileID: store.activeProfileID, at: now)
            if navigation.consumed {
                endCursorTelemetry()
                maximumMovement = max(maximumMovement, twoFingerNavigation.travel)
                previousContacts = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
                lastReportTime = now
                if let direction = navigation.direction, let settings {
                    cancelPendingTap()
                    dispatchTap(settings.action(for: direction), shortcut: settings[direction])
                }
                return
            }
        }

        if current.isEmpty {
            endCursorTelemetry()
            if let deadline = pendingDragEndAt, now >= deadline {
                pendingDragEnd?.invalidate()
                pendingDragEnd = nil
                pendingDragEndAt = nil
                if synthesizesPointerEvents { poster.endDrag() }
            }
            if previousCount > 0 { finishTouch(at: now) }
            previousContacts.removeAll()
            lastReportTime = now
            return
        }

        hadTwoFingers = hadTwoFingers || current.count >= 2
        if current.count >= 2 {
            holdingTapMotion = false
            cancelTapDragCandidate()
            endCursorTelemetry()
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
        touchProfileID = store.activeProfileID
        touchHadPhysicalButton = physicalButtonDown
        let taps = activeGestures
        let hasTapAction = taps.oneFingerTap != .none || (taps.oneFingerDoubleTap ?? .none) != .none ||
            (taps.oneFingerTripleTap ?? .none) != .none ||
            taps.doubleTapSwipe?.isConfigured == true || taps.singleTapSwipe?.isConfigured == true
        holdingTapMotion = synthesizesPointerEvents && contacts.count == 1 && !syntheticDragActive &&
            hasTapAction && taps.gestures.tapToClick && taps.gestures.resolvedKeepCursorStillForTaps
        maximumMovement = 0
        hadTwoFingers = contacts.count >= 2
        scrolling = false
        scrollVelocity = .zero
        scrollSpeedFilter = CursorVelocityFilter()
        cursorVelocity = .zero
        cursorFilter = CursorVelocityFilter()
        cursorGainFilter = CursorGainFilter()

        if contacts.count == 1, !syntheticDragActive, taps.gestures.tapToClick,
           let settings = taps.singleTapSwipe, settings.isConfigured,
           let pending = pendingTap, pending.fingerCount == 1, pending.tapCount == 1,
           pending.profileID == store.activeProfileID,
           now.timeIntervalSince(pending.date) <= settings.resolvedWindow {
            singleSwipe = settings
            singleSwipeConfiguration = taps
            singleSwipeLast = touchOrigin
            // No click may escape while deciding between swipe, double tap, and drag.
            pendingTapTimer?.invalidate()
            pendingTapTimer = nil
            let timer = Timer(timeInterval: settings.resolvedFastDuration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.expireSingleSwipe() }
            }
            singleSwipeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        if syntheticDragActive {
            pendingDragEnd?.invalidate()
            pendingDragEnd = nil
            pendingDragEndAt = nil
        } else if synthesizesPointerEvents, contacts.count == 1, activeGestures.gestures.tapToClick,
                  activeGestures.oneFingerTap == .leftClick,
                  activeGestures.gestures.touchAndHoldDrag {
            let pickupWindow = max(Self.tapDragPickupWindow, activeGestures.gestures.resolvedDoubleTapInterval)
            let followsCompletedClick = lastTapProfileID == store.activeProfileID &&
                now.timeIntervalSince(lastTap) <= pickupWindow
            let followsPendingLeftClick = pendingTap?.fingerCount == 1 &&
                pendingTap?.tapCount == 1 &&
                pendingTap?.profileID == store.activeProfileID &&
                pendingTap?.action == .leftClick &&
                now.timeIntervalSince(pendingTap?.date ?? .distantPast) <= pickupWindow
            if followsCompletedClick || followsPendingLeftClick {
                // Do not turn a normal tap-tap into a drag. The second touch
                // becomes a drag only when it is held or moved; a quick lift
                // continues through registerTap as the configured double tap.
                tapDragCandidate = true
                tapDragProfileID = store.activeProfileID
                tapDragStartTimer?.invalidate()
                let timer = Timer(timeInterval: singleSwipe?.resolvedFastDuration ?? Self.tapDragHoldDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startTapDrag() }
                }
                tapDragStartTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func handleCursor(_ finger: FingerContact, at now: Date) {
        guard !hadTwoFingers else { return }
        guard let previous = previousContacts[finger.id] else { return }
        let rawDX = finger.x - previous.x
        let rawDY = finger.y - previous.y
        let profile = store.activeProfile
        let magnitude = hypot(rawDX, rawDY)
        maximumMovement = max(maximumMovement, hypot(finger.x - touchOrigin.x, finger.y - touchOrigin.y))
        guard magnitude < 400 else {
            cursorVelocity = .zero
            cancelTapDragCandidate()
            if singleSwipe != nil {
                clearSingleSwipe()
                cancelPendingTap()
                singleSwipeBlocked = true
            }
            return
        }
        if singleSwipe != nil {
            singleSwipeLast = CGPoint(x: finger.x, y: finger.y)
            cursorVelocity = .zero
            return
        }
        guard synthesizesPointerEvents else {
            cursorVelocity = .zero
            return
        }
        // The new touch has its own origin: landing elsewhere never moves the
        // cursor. Small report-by-report movements add up to a deliberate drag.
        let tapSettings = activeGestures.gestures
        let dragMovementThreshold = holdingTapMotion
            ? max(Self.tapDragMovementThreshold, tapSettings.tapMaxMovement.nextUp)
            : Self.tapDragMovementThreshold
        if tapDragCandidate, maximumMovement >= dragMovementThreshold {
            startTapDrag()
        }
        if holdingTapMotion {
            let stillPotentialTap = touchProfileID == store.activeProfileID &&
                tapSettings.tapToClick && tapSettings.resolvedKeepCursorStillForTaps &&
                !syntheticDragActive && maximumMovement <= tapSettings.tapMaxMovement &&
                now.timeIntervalSince(touchStart) <= tapSettings.tapMaxDuration
            if stillPotentialTap {
                // Drop tap wobble rather than buffer it: replaying it on lift
                // or on movement recognition would move the click target.
                cursorVelocity = .zero
                return
            }
            holdingTapMotion = false
            cursorFilter = CursorVelocityFilter()
            cursorGainFilter = CursorGainFilter()
        }
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
        guard maximumMovement > activeGestures.gestures.tapMaxMovement else { return }
        guard synthesizesPointerEvents else { return }
        let profile = store.activeProfile
        let dt = profile.scrollResponse == nil ? max(0.001, now.timeIntervalSince(lastReportTime)) : cursorInterval
        if scrollProfileID != store.activeProfileID || scrollResponseSnapshot != profile.scrollResponse {
            scrollSpeedFilter = CursorVelocityFilter()
            scrollProfileID = store.activeProfileID
            scrollResponseSnapshot = profile.scrollResponse
        }
        let fingerSpeed = profile.scrollResponse == nil ? hypot(rawDX,rawDY)/dt :
            scrollSpeedFilter.update(dx:rawDX,dy:rawDY,dt:dt,smoothing:30)
        let gain = profile.scrollGain(at:fingerSpeed)
        let dx = rawDX * gain * (profile.invertScrollX ? -1 : 1)
        let dy = rawDY * gain * (profile.invertScrollY ? -1 : 1)
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
        if let candidate = singleSwipe {
            let dx = singleSwipeLast.x - touchOrigin.x
            let dy = singleSwipeLast.y - touchOrigin.y
            clearSingleSwipe()
            if hypot(dx, dy) >= candidate.resolvedDistance {
                cancelPendingTap()
                cancelTapDragCandidate()
                holdingTapMotion = false
                cursorVelocity = .zero
                lastTap = .distantPast
                lastTapProfileID = nil
                if let direction = SwipeDirection.classify(dx: dx, dy: dy) {
                    dispatchTap(candidate.action(for: direction), shortcut: candidate[direction])
                }
                return
            }
            // A short second contact remains a normal double tap. A failed
            // swipe must not leave an unscheduled first tap in memory.
            if maximumMovement > activeGestures.gestures.tapMaxMovement ||
                now.timeIntervalSince(touchStart) > activeGestures.gestures.tapMaxDuration {
                if let pending = pendingTap { flushPendingTap(pending) }
                cancelPendingTap()
            }
        }
        let gestures = activeGestures.gestures
        let duration = now.timeIntervalSince(touchStart)
        let isTap = gestures.tapToClick && touchProfileID == store.activeProfileID &&
            (synthesizesPointerEvents || !touchHadPhysicalButton) &&
            duration <= gestures.tapMaxDuration && maximumMovement <= gestures.tapMaxMovement
        holdingTapMotion = false

        // A quick second tap is still a double tap, not a drag.
        cancelTapDragCandidate()

        if scrolling {
            if store.activeProfile.kineticScroll { startMomentum() }
            scrolling = false
            if !syntheticDragActive { return }
        }

        if !hadTwoFingers && !syntheticDragActive && synthesizesPointerEvents {
            if isTap { cursorVelocity = .zero }
            else { startCursorDeceleration() }
        }

        if syntheticDragActive {
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

        guard isTap else { return }
        registerTap(fingerCount: hadTwoFingers ? 2 : 1, at: now)
    }

    private func registerTap(fingerCount: Int, at now: Date) {
        let active = activeGestures
        let doubleTapInterval = active.gestures.resolvedDoubleTapInterval
        let action = fingerCount == 2 ? active.twoFingerTap : active.oneFingerTap
        let shortcut = fingerCount == 2 ? active.twoFingerShortcut : active.oneFingerShortcut
        let doubleAction = fingerCount == 2 ? (active.twoFingerDoubleTap ?? .none) : (active.oneFingerDoubleTap ?? .none)
        let doubleShortcut = fingerCount == 2 ? active.twoFingerDoubleShortcut : active.oneFingerDoubleShortcut
        let tripleAction = (fingerCount == 2 ? active.twoFingerTripleTap : active.oneFingerTripleTap) ?? .none
        let tripleShortcut = fingerCount == 2 ? active.twoFingerTripleShortcut : active.oneFingerTripleShortcut
        let firstInterval = tripleAction == .none ? doubleTapInterval : active.gestures.resolvedTripleTapFirstInterval
        let secondInterval = active.gestures.resolvedTripleTapSecondInterval
        let swipeSettings = (fingerCount == 2 ? active.twoFingerDoubleTapSwipe : active.doubleTapSwipe) ?? DoubleTapSwipeSettings()
        let singleSettings = fingerCount == 2 ? active.twoFingerSingleTapSwipe : active.singleTapSwipe
        let canSwipe = swipeSettings.isConfigured
        let canSingleSwipe = singleSettings?.isConfigured == true

        if let pendingTap {
            if pendingTap.fingerCount == fingerCount, now.timeIntervalSince(pendingTap.date) <= (pendingTap.tapCount == 2 ? secondInterval : firstInterval) {
                pendingTapTimer?.invalidate()
                self.pendingTap = nil
                pendingTapTimer = nil
                if pendingTap.tapCount == 2 {
                    performTap(tripleAction, shortcut: tripleShortcut, at: now)
                    return
                }
                var second = PendingTap(profileID: store.activeProfileID, fingerCount: fingerCount,
                    action: doubleAction == .none ? action : doubleAction,
                    shortcut: doubleAction == .none ? shortcut : doubleShortcut, date: now, tapCount: 2)
                if doubleAction == .none { second.precedingSingles = [pendingTap] }
                if canSwipe {
                    deferredDoubleTap = DeferredDoubleTap(profileID: store.activeProfileID, settings: swipeSettings,
                        fallback: [second], tripleAction: tripleAction, tripleShortcut: tripleShortcut,
                        configuration: active)
                    lastTap = .distantPast
                    swipeRecognizer.arm(at: now, settings: swipeSettings,
                        tripleTapDuration: tripleAction == .none ? nil : active.gestures.tapMaxDuration,
                        tripleTapRadius: active.gestures.tapMaxMovement, tripleTapInterval: secondInterval,
                        fingerCount: fingerCount)
                    let wait = tripleAction == .none ? swipeSettings.resolvedWindow : max(swipeSettings.resolvedWindow, secondInterval)
                    let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            if self.swipeRecognizer.expire(at: self.clock()) { self.finishDeferredDoubleTap() }
                        }
                    }
                    swipeTimer = timer
                    RunLoop.main.add(timer, forMode: .common)
                    return
                }
                if tripleAction != .none {
                    lastTap = .distantPast
                    schedulePendingTap(second, interval: secondInterval)
                    return
                }
                flushPendingTap(second)
                return
            }
            pendingTapTimer?.invalidate()
            flushPendingTap(pendingTap)
            self.pendingTap = nil
            pendingTapTimer = nil
        }

        guard doubleAction != .none || tripleAction != .none || canSwipe || canSingleSwipe else {
            performTap(action, shortcut: shortcut, at: now)
            return
        }
        if fingerCount == 2, canSingleSwipe, let singleSettings {
            var first = PendingTap(profileID: store.activeProfileID, fingerCount: 2,
                action: action, shortcut: shortcut, date: now)
            first.configuration = active
            deferredDoubleTap = DeferredDoubleTap(profileID: store.activeProfileID, settings: singleSettings,
                fallback: [first], tripleAction: .none, tripleShortcut: nil, configuration: active,
                isSingleTapSwipe: true)
            lastTap = .distantPast
            swipeRecognizer.arm(at: now, settings: singleSettings,
                tripleTapDuration: active.gestures.tapMaxDuration, tripleTapRadius: active.gestures.tapMaxMovement,
                tripleTapInterval: firstInterval, fingerCount: 2,
                maximumDuration: singleSettings.resolvedFastDuration)
            let timer = Timer(timeInterval: max(singleSettings.resolvedWindow, firstInterval), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.swipeRecognizer.expire(at: self.clock()) { self.finishDeferredDoubleTap() }
                }
            }
            swipeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        let wait = canSingleSwipe ? max(singleSettings!.resolvedWindow,
            doubleAction != .none || tripleAction != .none || canSwipe ? firstInterval : 0) : firstInterval
        schedulePendingTap(PendingTap(profileID: store.activeProfileID, fingerCount: fingerCount,
            action: action, shortcut: shortcut, date: now), interval: wait)
    }

    private func flushPendingTap(_ pending: PendingTap) {
        for tap in pending.precedingSingles + [pending] {
            performTap(tap.action, shortcut: tap.shortcut, at: tap.date)
        }
    }

    private func schedulePendingTap(_ pending: PendingTap, interval: TimeInterval) {
        var captured = pending
        captured.configuration = activeGestures
        pendingTap = captured
        pendingTapTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let pending = self.pendingTap else { return }
                self.pendingTap = nil
                self.pendingTapTimer = nil
                if self.store.settings.enabled, pending.profileID == self.store.activeProfileID,
                   pending.configuration == self.activeGestures, self.activeGestures.gestures.tapToClick {
                    self.flushPendingTap(pending)
                }
            }
        }
    }

    private func performTap(_ action: TapAction, shortcut: RecordedShortcut?, at date: Date) {
        dispatchTap(action, shortcut: shortcut)
        // Only a real single-finger click may arm tap-hold dragging.
        let armsSyntheticDrag = synthesizesPointerEvents && action == .leftClick
        lastTap = armsSyntheticDrag ? date : .distantPast
        lastTapProfileID = armsSyntheticDrag ? store.activeProfileID : nil
    }

    private func dispatchTap(_ action: TapAction, shortcut: RecordedShortcut?) {
        guard action != .none else { return }
        if action == .appExplorer || action == .windowManager {
            reset() // Stop all cursor/scroll momentum and queued taps before the HUD opens.
            if action == .windowManager { onWindowManager?() }
            else { onAppExplorer?() }
        } else if synthesizesPointerEvents || [.shortcut, .optionF19, .enter].contains(action) {
            // Apple's native trackpad owns every pointer event in native-actions
            // mode. Keyboard actions cross the poster boundary; mouse actions
            // stay native.
            poster.performTap(action, shortcut: shortcut)
        }
    }

    private func cancelPendingTap() {
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        pendingTap = nil
    }

    private func cancelTapSwipe(blockUntilLift: Bool = true) {
        clearSingleSwipe()
        swipeTimer?.invalidate()
        swipeTimer = nil
        deferredDoubleTap = nil
        if blockUntilLift { swipeRecognizer.cancel() }
        else { swipeRecognizer = DoubleTapSwipeRecognizer() }
    }

    private func finishDeferredDoubleTap() {
        let deferred = deferredDoubleTap
        cancelTapSwipe()
        guard let deferred, deferred.profileID == store.activeProfileID,
              activeGestures.gestures.tapToClick,
              store.settings.enabled, activeGestures == deferred.configuration else { return }
        for tap in deferred.fallback { flushPendingTap(tap) }
    }

    private func cancelTapDragCandidate() {
        tapDragCandidate = false
        tapDragProfileID = nil
        tapDragStartTimer?.invalidate()
        tapDragStartTimer = nil
    }

    private func startTapDrag() {
        guard synthesizesPointerEvents else {
            cancelTapDragCandidate()
            return
        }
        // The second contact belongs to quick-swipe recognition until its
        // deadline. Never post mouse-down and then reinterpret it as a swipe.
        if singleSwipe != nil { return }
        guard tapDragCandidate, !syntheticDragActive else { return }
        guard tapDragProfileID == store.activeProfileID, !hadTwoFingers,
              store.settings.enabled, activeGestures.gestures.tapToClick,
              activeGestures.gestures.touchAndHoldDrag,
              activeGestures.oneFingerTap == .leftClick else {
            cancelTapDragCandidate()
            return
        }
        cancelTapDragCandidate()
        lastTap = .distantPast
        lastTapProfileID = nil
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        pendingTap = nil
        tapDragActive = true
        holdingTapMotion = false
        poster.beginDrag()
    }

    private func handlePhysicalButton(_ down: Bool) {
        guard down != physicalButtonDown else { return }
        physicalButtonDown = down
        if down {
            touchHadPhysicalButton = true
            cancelTapSwipe(blockUntilLift: false)
            cancelPendingTap()
            cancelTapDragCandidate()
            cursorDecelerationTimer?.invalidate()
            cursorDecelerationTimer = nil
            if synthesizesPointerEvents { poster.beginDrag() }
        } else if synthesizesPointerEvents { poster.endDrag() }
    }

    private func clearSingleSwipe() {
        singleSwipeTimer?.invalidate()
        singleSwipeTimer = nil
        singleSwipe = nil
        singleSwipeConfiguration = nil
    }

    private func expireSingleSwipe() {
        guard singleSwipe != nil else { return }
        let valid = store.settings.enabled && touchProfileID == store.activeProfileID &&
            singleSwipeConfiguration == activeGestures
        clearSingleSwipe()
        if valid {
            startTapDrag()
            if let pending = pendingTap { flushPendingTap(pending); cancelPendingTap() }
        } else {
            cancelPendingTap()
            cancelTapDragCandidate()
            singleSwipeBlocked = true
        }
    }

    private func startMomentum() {
        guard synthesizesPointerEvents else { return }
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
                guard self.synthesizesPointerEvents else {
                    timer.invalidate(); self.momentumTimer = nil; return
                }
                let decay = self.store.activeProfile.kineticDecay
                if self.store.activeProfile.scrollResponse?.sanitized.fastMultiplier == 0 {
                    timer.invalidate(); self.momentumTimer = nil; return
                }
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
        guard synthesizesPointerEvents else { return }
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
                guard self.synthesizesPointerEvents else {
                    timer.invalidate(); self.cursorDecelerationTimer = nil; return
                }
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

    private func endCursorTelemetry() {
        if synthesizesPointerEvents { store.cursorTelemetry.endTouch() }
    }

    private func centroid(_ contacts: [FingerContact]) -> CGPoint {
        guard !contacts.isEmpty else { return .zero }
        return CGPoint(
            x: contacts.map(\.x).reduce(0, +) / Double(contacts.count),
            y: contacts.map(\.y).reduce(0, +) / Double(contacts.count)
        )
    }
}
