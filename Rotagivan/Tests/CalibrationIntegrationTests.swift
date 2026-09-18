import Foundation
import CoreGraphics

@MainActor private final class ExplorerStub: AppExplorerPresenting {
    var isVisible = false
    var onDismiss: (() -> Void)?
    var contextIsValid: (() -> Bool)?
    var input = AppExplorerSelection(waitingForLift: false)
    var selections: [SwipeDirection] = []
    var alternateHeld = false
    func setAlternateHeld(_ held: Bool) { alternateHeld = held }
    func show(waitingForLift: Bool) {
        isVisible = true
        input = AppExplorerSelection(waitingForLift: waitingForLift)
    }
    func process(_ report: TrackpadReport) {
        if contextIsValid?() == false { dismiss(); return }
        switch input.process(report) {
        case .select(let direction): selections.append(direction); dismiss()
        case .back, .cancel: dismiss()
        default: break
        }
    }
    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        onDismiss?()
    }
}

private final class CalibrationPoster: GestureEventPosting {
    var dragging = false
    var actions = 0
    var moves = 0
    var scrolls = 0
    var dragStarts = 0
    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) { actions += 1 }
    func click(button: CGMouseButton, count: Int) { actions += 1 }
    func move(dx: Double, dy: Double) { moves += 1 }
    func scroll(dx: Double, dy: Double, momentum: Bool) { scrolls += 1 }
    func beginDrag() { dragging = true; dragStarts += 1 }
    func endDrag() { dragging = false }
}

@MainActor private final class CalibrationFixture {
    let suite = "Rotagivan.CalibrationTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let store: SettingsStore
    let poster = CalibrationPoster()
    let explorer = ExplorerStub()
    let start = ProcessInfo.processInfo.systemUptime
    var now = Date()
    var engine: GestureEngine!
    var hid: NavigatorHIDManager!

    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "migration.rotagivan.v1")
        store = SettingsStore(defaults: preferences)
        store.settings.defaultProfileID = 1
        store.setActiveProfile(1)
        var taps = store.settings.gestures(for: 1)
        taps.gestures.tapToClick = true
        taps.gestures.tapMaxDuration = 0.25
        taps.gestures.tapMaxMovement = 30
        taps.gestures.doubleTapInterval = 0.3
        taps.oneFingerTap = .leftClick
        taps.oneFingerDoubleTap = TapAction.none
        taps.doubleTapSwipe = DoubleTapSwipeSettings(enabled: false, swipeWindow: 0.35,
            left: RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17"))
        store.updateGestures(taps, for: 1)
        engine = GestureEngine(store: store, poster: poster, clock: { [unowned self] in self.now })
        hid = NavigatorHIDManager(store: store, gestures: engine, explorer: explorer)
    }

    func begin(_ mode: GestureCalibrationMode = .doubleTap) -> GestureCalibrationSession {
        let session = GestureCalibrationSession(profileID: 1, profileName: "Test", mode: mode,
            gestures: store.settings.gestures(for: 1))
        hid.startCalibrationSession(session, at: start)
        return session
    }

    func send(_ time: Double, x: Double? = nil, y: Double = 500, button: Bool = false) {
        now = Date(timeIntervalSince1970: start + time)
        let contacts = x.map { [FingerContact(id: 0, x: $0, y: y, touching: true, confident: true)] } ?? []
        hid.receive(TrackpadReport(contacts: contacts, buttonDown: button, scanTime: 0), at: start + time)
    }

    func trials(_ mode: GestureCalibrationMode, intervals: [Double] = (0..<10).map { 0.10 + Double($0) * 0.01 }) {
        for (index, interval) in intervals.enumerated() {
            let t = 1.0 + Double(index) * 3
            send(t, x: 500); send(t + 0.03)
            send(t + interval, x: 500); send(t + interval + 0.03)
            if mode == .doubleTapSwipe {
                let third = t + interval + 0.03 + 0.15 + Double(index) * 0.01
                send(third, x: 500); send(third + 0.04, x: 600); send(third + 0.08)
            }
        }
    }

    func finish() {
        hid.endCalibration()
        engine.reset()
        preferences.removePersistentDomain(forName: suite)
    }
}

@main struct CalibrationIntegrationTests {
    @MainActor private static func check(_ body: (CalibrationFixture) -> Void) {
        let f = CalibrationFixture()
        defer { f.finish() }
        body(f)
    }

    @MainActor static func main() {
        check { f in
            f.hid.explorerHold(true)
            precondition(f.explorer.isVisible && f.explorer.alternateHeld)
            f.hid.explorerHold(true) // Repeat does not reset selection.
            f.send(1, x: 500); f.send(1.1, x: 600)
            f.hid.explorerHold(false)
            precondition(!f.explorer.isVisible && !f.explorer.alternateHeld)
            f.send(1.2)
            precondition(f.poster.actions == 0 && f.poster.moves == 0 && f.explorer.selections.isEmpty)
            f.hid.explorerHold(true)
            f.send(2, x: 500); f.send(2.1, x: 600); f.send(2.2)
            precondition(f.explorer.selections == [.right])
            f.hid.explorerHold(false)
            precondition(!f.explorer.isVisible)
            f.store.settings.enabled = false
            f.hid.explorerHold(true)
            precondition(!f.explorer.isVisible)
        }
        check { f in
            let before = f.store.settings.gestures(for: 1)
            let session = f.begin(.tripleTap)
            f.hid.explorerHold(true)
            precondition(!f.explorer.isVisible, "Hotkey cannot interrupt calibration")
            for index in 0..<10 {
                let t = 1.0 + Double(index) * 3
                let first = 0.10 + Double(index) * 0.01
                let second = 0.20 + Double(index) * 0.01
                f.send(t, x: 500); f.send(t + 0.03)
                f.send(t + first, x: 800); f.send(t + first + 0.03)
                f.send(t + first + second, x: 200); f.send(t + first + second + 0.03)
            }
            precondition(session.isComplete && !f.hid.isCalibrating)
            precondition(f.poster.actions == 0 && f.poster.moves == 0)
            precondition(f.store.settings.gestures(for: 1) == before, "Calibration must not save before Apply")
            f.hid.applyCalibration()
            let applied = f.store.settings.gestures(for: 1)
            precondition(applied.gestures.tripleTapFirstInterval == 0.145)
            precondition(applied.gestures.tripleTapSecondInterval == 0.245)
            precondition(applied.gestures.doubleTapInterval == before.gestures.doubleTapInterval)
            precondition(f.store.settings.effectiveGestures(for: 2).gestures.tripleTapSecondInterval == 0.245)
        }
        check { f in
            var taps = f.store.activeGestures
            taps.oneFingerDoubleTap = .rightClick
            f.store.updateGestures(taps, for:1)
            f.store.settings.appOverrides = [AppGestureOverride(bundleID:"com.google.Chrome", name:"Chrome", bindings:[
                AppGestureBinding(trigger:.oneFingerTap, action:.shortcut, shortcut:RecordedShortcut(keyCode:64,modifiers:0,keyLabel:"F17"))])]
            f.hid.foregroundAppChanged("com.google.Chrome")
            precondition(f.store.activeGestures.oneFingerTap == .shortcut)
            f.send(1,x:500); f.send(1.03)
            f.hid.foregroundAppChanged("com.apple.finder")
            RunLoop.main.run(until:Date().addingTimeInterval(0.34))
            precondition(f.poster.actions == 0, "Pending Chrome action must not fire in Finder")
            precondition(f.store.activeGestures.oneFingerTap == .leftClick)
            f.send(2,x:500)
            f.hid.foregroundAppChanged("com.google.Chrome")
            f.send(2.03)
            RunLoop.main.run(until:Date().addingTimeInterval(0.34))
            precondition(f.poster.actions == 0, "An in-progress touch is drained on app switch")
            precondition(f.store.settings.gestures(for:1) == taps, "App overrides never rewrite the profile")
        }
        for cancellation in 0..<4 {
            check { f in
                var taps = f.store.activeGestures
                taps.oneFingerTap = .appExplorer
                f.store.updateGestures(taps, for:1)
                f.send(1, x:500); f.send(1.03)
                precondition(f.explorer.isVisible && f.poster.actions == 0)
                f.send(1.1,x:500)
                switch cancellation {
                case 0:
                    f.send(1.15,x:600); f.send(1.2)
                    precondition(f.explorer.selections == [.right])
                case 1: f.explorer.dismiss() // Escape mid-touch must drain the rest.
                case 2: f.store.setActiveProfile(2)
                default: f.hid.stop()
                }
                if cancellation != 0 { f.send(1.15,x:600); f.send(1.2) }
                precondition(!f.explorer.isVisible && f.poster.actions == 0 && f.poster.moves == 0 && f.poster.scrolls == 0 && f.poster.dragStarts == 0)
            }
        }
        print("App Explorer HID gate passed: action routing, exclusive input, profile/stop/Escape cancellation, and lift draining.")
        check { f in
            let before = f.store.settings.gestures(for: 1)
            let session = f.begin(.singleTapSwipe)
            for index in 0..<10 {
                let t = 1.0 + Double(index) * 2
                f.send(t, x: 500); f.send(t + 0.03)
                f.send(t + 0.18, x: 700); f.send(t + 0.22, x: 800); f.send(t + 0.30)
            }
            precondition(session.isComplete && session.sampleCount == 10)
            precondition(f.poster.actions == 0 && f.poster.moves == 0 && f.poster.dragStarts == 0)
            precondition(f.store.settings.gestures(for: 1) == before)
            f.hid.applyCalibration()
            var expected = before
            expected.singleTapSwipe = .singleTapDefaults
            expected.singleTapSwipe!.swipeWindow = 0.15
            expected.singleTapSwipe!.fastSwipeDuration = 0.12
            precondition(f.store.settings.gestures(for: 1) == expected, "Single-swipe calibration changes only its own timings")
        }
        check { f in
            let before = f.store.settings.gestures(for: 1)
            let session = f.begin()
            f.hid.applyCalibration()
            assert(f.hid.calibrationSession != nil && f.store.settings.gestures(for: 1) == before)
            f.trials(.doubleTap)
            assert(session.isComplete && session.sampleCount == 10)
            assert(!f.hid.isCalibrating)
            assert(f.poster.actions == 0 && f.poster.moves == 0 && f.poster.scrolls == 0 && f.poster.dragStarts == 0)
            assert(f.store.settings.gestures(for: 1) == before, "Capture must not save until Apply")
            f.hid.applyCalibration()
            var expected = before
            expected.gestures.doubleTapInterval = 0.145
            assert(f.store.settings.gestures(for: 1) == expected)
            assert(f.hid.calibrationSession == nil)
            f.send(40, x: 500); f.send(40.03)
            assert(f.poster.actions == 1, "Normal taps resume after capture")
        }
        check { f in
            let before = f.store.settings.gestures(for: 1)
            let session = f.begin(.doubleTapSwipe)
            f.trials(.doubleTapSwipe)
            assert(session.isComplete && session.sampleCount == 10)
            assert(f.poster.actions == 0 && f.poster.moves == 0 && f.poster.scrolls == 0 && f.poster.dragStarts == 0)
            f.hid.applyCalibration()
            var expected = before
            expected.gestures.doubleTapInterval = 0.145
            expected.doubleTapSwipe?.swipeWindow = 0.195
            assert(f.store.settings.gestures(for: 1) == expected, "Only timing fields change; bindings/enabled/distance survive")
        }
        check { f in
            let before = f.store.settings.gestures(for: 1)
            _ = f.begin()
            f.send(1, x: 500)
            f.hid.keyboardAction(0, down: true)
            f.hid.keyboardAction(2, down: true)
            f.hid.endCalibration()
            f.send(1.04, x: 600); f.send(1.08)
            assert(f.poster.actions == 0 && f.poster.moves == 0 && f.poster.dragStarts == 0, "Cancel must drain in-flight touch")
            assert(f.store.settings.gestures(for: 1) == before)
            f.send(2, x: 500); f.send(2.03)
            assert(f.poster.actions == 1)
        }
        check { f in
            let session = f.begin()
            f.send(1, x: 500)
            f.hid.stop()
            assert(session.cancellationReason != nil && !f.hid.isCalibrating)
            let before = f.store.settings.gestures(for: 1)
            f.hid.applyCalibration()
            assert(f.store.settings.gestures(for: 1) == before)
        }
        check { f in
            let session = f.begin()
            var changed = f.store.settings.gestures(for: 1)
            changed.gestures.tapMaxDuration = 0.4
            f.store.updateGestures(changed, for: 1)
            f.hid.advanceCalibration(at: f.start + 1)
            assert(session.cancellationReason != nil && !f.hid.isCalibrating)
        }
        check { f in
            let session = f.begin()
            f.store.setActiveProfile(2)
            f.hid.advanceCalibration(at: f.start + 1)
            assert(session.cancellationReason != nil && !f.hid.isCalibrating)
        }
        check { f in
            _ = f.begin(.doubleTapSwipe)
            f.trials(.doubleTapSwipe, intervals: Array(repeating: 0.9, count: 10))
            f.hid.applyCalibration()
            assert(f.store.settings.gestures(for: 1).gestures.doubleTapInterval == 0.6)
        }
        check { f in
            let session = f.begin()
            f.trials(.doubleTap)
            assert(session.isComplete)
            var changed = f.store.settings.gestures(for: 1)
            changed.gestures.doubleTapInterval = 0.5
            f.store.updateGestures(changed, for: 1)
            f.hid.applyCalibration()
            assert(session.cancellationReason != nil)
            assert(f.store.settings.gestures(for: 1) == changed, "Completed stale results must not overwrite newer settings")
        }
        check { f in
            let session = f.begin()
            f.trials(.doubleTap)
            let before = f.store.settings.gestures(for: 1)
            f.store.setActiveProfile(2)
            f.hid.applyCalibration()
            assert(session.cancellationReason != nil)
            assert(f.store.settings.gestures(for: 1) == before)
        }
        print("Calibration integration tests passed")
    }
}
