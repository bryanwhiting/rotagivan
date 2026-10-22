import Foundation
import CoreGraphics
import Combine

// One-finger tap, then quick swipe on an Apple trackpad through the HID input
// manager: Apple contact frames reach the native-actions engine, the swipe
// fires the layer's binding, and macOS "Tap to click" (which echoes the tap
// as a native left click after lift) does not cancel it.

@MainActor private final class ExplorerStub: AppExplorerPresenting {
    var isVisible = false { didSet { onPresentationChanged?() } }
    var isEditing = false { didSet { onPresentationChanged?() } }
    var onPresentationChanged: (() -> Void)?
    var onDismiss: (() -> Void)?
    var contextIsValid: (() -> Bool)?
    var shows = 0
    func showLayer(_ id: UUID, waitingForLift: Bool) { show(waitingForLift: waitingForLift) }
    func showWindowManager(waitingForLift: Bool) { show(waitingForLift: waitingForLift) }
    func setAlternateHeld(_ held: Bool) {}
    func show(waitingForLift: Bool) { isVisible = true; shows += 1 }
    func process(_ report: TrackpadReport) {}
    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        onDismiss?()
    }
}

@MainActor private final class PointerStub: ExplorerPointerControlling {
    var onInterruption: (() -> Void)?
    var locked = false
    @discardableResult func setLocked(_ value: Bool) -> Bool { locked = value; return true }
}

private final class ActionPoster: GestureEventPosting {
    var dragging = false
    var taps: [(TapAction, RecordedShortcut?)] = []
    var pointerOutputs = 0
    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) { taps.append((action, shortcut)) }
    func click(button: CGMouseButton, count: Int) { pointerOutputs += 1 }
    func move(dx: Double, dy: Double) { pointerOutputs += 1 }
    func scroll(dx: Double, dy: Double, momentum: Bool) { pointerOutputs += 1 }
    func beginDrag() { dragging = true; pointerOutputs += 1 }
    func endDrag() { dragging = false; pointerOutputs += 1 }
}

@MainActor private final class AppleTapSwipeFixture {
    let suite = "Rota.AppleTapSwipeTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let store: SettingsStore
    let navigatorPoster = ActionPoster()
    let applePoster = ActionPoster()
    let explorer = ExplorerStub()
    let pointer = PointerStub()
    let start = ProcessInfo.processInfo.systemUptime
    var now = Date()
    var engine: GestureEngine!
    var appleEngine: GestureEngine!
    var hid: NavigatorHIDManager!
    private var nextContactID: UInt8 = 1

    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "migration.rota.v1")
        preferences.set(true, forKey: "input.appleTrackpadActions")
        store = SettingsStore(defaults: preferences)
        store.settings.defaultProfileID = 1
        store.setActiveProfile(1)
        store.settings.devices = ProfileDevices(navigatorEnabled: true, appleEnabled: true, shareTapActions: true)
        var taps = store.settings.gestures(for: 1)
        taps.gestures.tapToClick = true
        taps.gestures.tapMaxDuration = 0.2
        taps.gestures.tapMaxMovement = 25
        taps.gestures.doubleTapInterval = 0.12
        taps.oneFingerTap = .leftClick
        taps.twoFingerTap = .rightClick
        taps.oneFingerDoubleTap = nil
        taps.oneFingerTripleTap = nil
        taps.doubleTapSwipe = nil
        taps.twoFingerSwipe = nil
        var swipe = DoubleTapSwipeSettings.singleTapDefaults
        swipe.enabled = true
        for (index, direction) in SwipeDirection.allCases.enumerated() {
            swipe[direction] = RecordedShortcut(keyCode: UInt16(18 + index), modifiers: 0, keyLabel: direction.title)
        }
        taps.singleTapSwipe = swipe
        store.updateGestures(taps, for: 1)
        engine = GestureEngine(store: store, poster: navigatorPoster, clock: { [unowned self] in self.now })
        appleEngine = GestureEngine(store: store, poster: applePoster, clock: { [unowned self] in self.now },
                                    inputMode: .nativeActions)
        hid = NavigatorHIDManager(store: store, gestures: engine, explorer: explorer,
            appleGestures: appleEngine, inputPreferences: preferences, explorerPointer: pointer,
            appleHUDDelay: 0)
    }

    /// An Apple frame. Each touch carries its own identifier, as MultitouchSupport does.
    func sendApple(_ time: Double, _ points: [(UInt8, Double, Double)] = []) {
        now = Date(timeIntervalSince1970: start + time)
        let contacts = points.map { FingerContact(id: $0.0, x: $0.1, y: $0.2, touching: true, confident: true) }
        hid.receive(TrackpadReport(contacts: contacts, buttonDown: false, scanTime: 0), from: .apple(42), at: start + time)
    }

    func newContact() -> UInt8 { defer { nextContactID &+= 1 }; return nextContactID }

    /// Tap, lift, optionally let macOS echo the tap as a native left click, then swipe right and lift.
    func tapSwipe(_ t: Double, tapToClickEcho: Bool, to point: (Double, Double) = (640, 500)) {
        let tap = newContact(), swipe = newContact()
        sendApple(t, [(tap, 500, 500)]); sendApple(t + 0.03)
        if tapToClickEcho { hid.nativeClickObserved(leftButton: true) }
        sendApple(t + 0.10, [(swipe, 500, 500)])
        sendApple(t + 0.12, [(swipe, (500 + point.0) / 2, (500 + point.1) / 2)])
        sendApple(t + 0.14, [(swipe, point.0, point.1)])
        sendApple(t + 0.20)
    }

    func finish() {
        engine.reset()
        appleEngine.reset()
        preferences.removePersistentDomain(forName: suite)
    }
}

@main struct AppleTapSwipeTests {
    @MainActor private static func check(_ body: (AppleTapSwipeFixture) -> Void) {
        let f = AppleTapSwipeFixture()
        defer { f.finish() }
        body(f)
    }

    @MainActor static func main() {
        check { f in
            f.tapSwipe(1, tapToClickEcho: false)
            precondition(f.applePoster.taps.count == 1 && f.applePoster.taps[0].0 == .shortcut,
                         "Apple one-finger tap + swipe reaches the native-actions engine through the HID manager")
            precondition(f.applePoster.taps[0].1 == f.store.activeGestures(for: .apple).singleTapSwipe![.right])
            precondition(f.navigatorPoster.taps.isEmpty && f.navigatorPoster.pointerOutputs == 0,
                         "Apple frames never reach the Navigator engine")
            precondition(f.applePoster.pointerOutputs == 0, "No synthetic pointer events for Apple touches")
        }
        check { f in
            f.tapSwipe(1, tapToClickEcho: true)
            precondition(f.applePoster.taps.count == 1 && f.applePoster.taps[0].0 == .shortcut,
                         "macOS Tap to click echoing the tap as a left click must not cancel the swipe")
            f.tapSwipe(2, tapToClickEcho: true, to: (500, 360))
            precondition(f.applePoster.taps.count == 2 &&
                         f.applePoster.taps[1].1 == f.store.activeGestures(for: .apple).singleTapSwipe![.up])
        }
        check { f in
            // The tap's click may reach the event monitor before the lift frame
            // reaches the engine. A prompt lift still completes the gesture.
            let tap = f.newContact(), swipe = f.newContact()
            f.sendApple(1, [(tap, 500, 500)])
            f.hid.nativeClickObserved(leftButton: true) // Tap to click, ahead of the lift frame.
            f.sendApple(1.03)
            f.sendApple(1.10, [(swipe, 500, 500)]); f.sendApple(1.14, [(swipe, 640, 500)]); f.sendApple(1.20)
            precondition(f.applePoster.taps.count == 1 && f.applePoster.taps[0].0 == .shortcut,
                         "A Tap to click echo arriving before the lift frame must not cancel the swipe")
            f.tapSwipe(2, tapToClickEcho: true)
            precondition(f.applePoster.taps.count == 2, "Either click order keeps working")
            precondition(f.applePoster.pointerOutputs == 0)
        }
        check { f in
            // Only a left click around a one-finger tap's lift is treated as the
            // tap's own echo. Everything else keeps the veto.
            let tap = f.newContact(), swipe = f.newContact()
            f.sendApple(1, [(tap, 500, 500)]); f.sendApple(1.03)
            f.hid.nativeClickObserved() // Secondary/other button.
            f.sendApple(1.10, [(swipe, 500, 500)]); f.sendApple(1.14, [(swipe, 640, 500)]); f.sendApple(1.20)
            precondition(f.applePoster.taps.isEmpty, "A non-left native click still cancels the pending Apple gesture")
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))

            let press = f.newContact(), after = f.newContact()
            f.sendApple(2, [(press, 500, 500)])
            f.hid.nativeClickObserved(leftButton: true) // Physical press: the finger keeps resting.
            f.sendApple(2.02, [(press, 500, 500)]); f.sendApple(2.03)
            f.sendApple(2.10, [(after, 500, 500)]); f.sendApple(2.14, [(after, 640, 500)]); f.sendApple(2.20)
            precondition(f.applePoster.taps.isEmpty, "A left click followed by a resting finger is a press, not a tap echo")
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))

            let slow = f.newContact(), afterSlow = f.newContact()
            f.sendApple(2.5, [(slow, 500, 500)])
            f.hid.nativeClickObserved(leftButton: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // Lift frame later than the echo grace.
            f.sendApple(2.53)
            f.sendApple(2.60, [(afterSlow, 500, 500)]); f.sendApple(2.64, [(afterSlow, 640, 500)]); f.sendApple(2.70)
            precondition(f.applePoster.taps.isEmpty, "A late lift after a left click is a press, not a tap echo")
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))

            let moved = f.newContact(), afterMoved = f.newContact()
            f.sendApple(2.8, [(moved, 500, 500)]); f.sendApple(2.82, [(moved, 600, 500)])
            f.hid.nativeClickObserved(leftButton: true) // The resting finger already travelled too far for a tap.
            f.sendApple(2.84)
            f.sendApple(2.90, [(afterMoved, 500, 500)]); f.sendApple(2.94, [(afterMoved, 640, 500)]); f.sendApple(3.0)
            precondition(f.applePoster.taps.isEmpty, "A left click during a moving finger keeps the veto")
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))

            f.hid.nativeClickObserved(leftButton: true) // A click with nothing pending.
            let late = f.newContact()
            f.sendApple(3.2, [(late, 500, 500)]); f.sendApple(3.24, [(late, 640, 500)]); f.sendApple(3.30)
            precondition(f.applePoster.taps.isEmpty, "A stray left click plus a plain swipe does nothing")
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))

            f.tapSwipe(4, tapToClickEcho: true)
            precondition(f.applePoster.taps.count == 1, "The veto path recovers for the next tap + swipe")
        }
        check { f in
            var taps = f.store.activeGestures
            taps.singleTapSwipe!.setAction(.appExplorer, for: .down)
            f.store.updateGestures(taps, for: 1)
            f.tapSwipe(1, tapToClickEcho: true, to: (500, 640))
            precondition(f.explorer.isVisible && f.explorer.shows == 1 && f.applePoster.taps.isEmpty,
                         "Tap + swipe down opens App Explorer from the Apple trackpad")
            precondition(f.pointer.locked, "An Apple-opened HUD holds the pointer still")
            f.explorer.dismiss()
            let tap = f.newContact()
            f.sendApple(2, [(tap, 500, 500)]); f.sendApple(2.03)
            f.hid.nativeClickObserved(leftButton: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            precondition(f.explorer.shows == 1 && f.applePoster.taps.isEmpty,
                         "A lone one-finger tap stays a native click and opens nothing")
        }
        check { f in
            var taps = f.store.activeGestures
            taps.twoFingerTap = .enter
            f.store.updateGestures(taps, for: 1)
            let a = f.newContact(), b = f.newContact()
            f.sendApple(1, [(a, 500, 500), (b, 700, 500)]); f.sendApple(1.02)
            precondition(f.applePoster.taps.count == 1 && f.applePoster.taps[0].0 == .enter,
                         "Two-finger taps keep working alongside one-finger tap + swipe")
            f.tapSwipe(2, tapToClickEcho: true)
            precondition(f.applePoster.taps.count == 2 && f.applePoster.taps[1].0 == .shortcut)
        }
        print("Apple one-finger tap + quick swipe passed through the HID manager, with and without macOS Tap to click.")
    }
}
