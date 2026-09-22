import Foundation
import CoreGraphics
import Combine

@MainActor private final class ExplorerStub: AppExplorerPresenting {
    var isVisible = false { didSet { onPresentationChanged?() } }
    var isEditing = false { didSet { onPresentationChanged?() } }
    var onPresentationChanged: (() -> Void)?
    var onDismiss: (() -> Void)?
    var contextIsValid: (() -> Bool)?
    var input = AppExplorerSelection(waitingForLift: false)
    var selections: [ExplorerSlot] = []
    var alternateHeld = false
    var windowManagerShows = 0
    var layerShows: [UUID] = []
    func showLayer(_ id: UUID, waitingForLift: Bool) {
        layerShows.append(id); show(waitingForLift: waitingForLift)
    }
    func showWindowManager(waitingForLift: Bool) {
        windowManagerShows += 1
        show(waitingForLift: waitingForLift)
    }
    func setAlternateHeld(_ held: Bool) { alternateHeld = held }
    func show(waitingForLift: Bool) {
        isVisible = true
        input = AppExplorerSelection(waitingForLift: waitingForLift)
    }
    func process(_ report: TrackpadReport) {
        if contextIsValid?() == false { dismiss(); return }
        if isEditing { return }
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

@MainActor private final class PointerStub: ExplorerPointerControlling {
    var onInterruption: (() -> Void)?
    var locked = false
    var failCapture = false
    @discardableResult func setLocked(_ value: Bool) -> Bool {
        locked = value && !failCapture
        return !value || !failCapture
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
    let applePoster = CalibrationPoster()
    let explorer = ExplorerStub()
    let pointer = PointerStub()
    let start = ProcessInfo.processInfo.systemUptime
    var now = Date()
    var engine: GestureEngine!
    var appleEngine: GestureEngine!
    var hid: NavigatorHIDManager!

    init(appleActionsEnabled: Bool = false, appleHUDDelay: TimeInterval = 0) {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "migration.rotagivan.v1")
        preferences.set(appleActionsEnabled, forKey: "input.appleTrackpadActions")
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
        appleEngine = GestureEngine(store: store, poster: applePoster, clock: { [unowned self] in self.now }, inputMode: .nativeActions)
        hid = NavigatorHIDManager(store: store, gestures: engine, explorer: explorer,
            appleGestures: appleEngine, inputPreferences: preferences, explorerPointer: pointer,
            appleHUDDelay: appleHUDDelay)
    }

    func begin(_ mode: GestureCalibrationMode = .doubleTap, device: GestureDevice = .navigator) -> GestureCalibrationSession {
        let session = GestureCalibrationSession(profileID: 1, profileName: "Test", mode: mode,
            gestures: store.gestures(for: 1, device: device), device: device)
        hid.startCalibrationSession(session, at: start, device: device)
        return session
    }

    func send(_ time: Double, x: Double? = nil, y: Double = 500, button: Bool = false) {
        now = Date(timeIntervalSince1970: start + time)
        let contacts = x.map { [FingerContact(id: 0, x: $0, y: y, touching: true, confident: true)] } ?? []
        hid.receive(TrackpadReport(contacts: contacts, buttonDown: button, scanTime: 0), at: start + time)
    }

    func sendApple(_ time: Double, x: Double? = nil, y: Double = 500, deviceID: UInt64 = 42, twoFingers: Bool = false) {
        now = Date(timeIntervalSince1970: start + time)
        var contacts = x.map { [FingerContact(id: 0, x: $0, y: y, touching: true, confident: true)] } ?? []
        if twoFingers, let x { contacts.append(FingerContact(id: 1, x: x + 100, y: y, touching: true, confident: true)) }
        hid.receive(TrackpadReport(contacts: contacts, buttonDown: false, scanTime: 0),
            from: .apple(deviceID), at: start + time)
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
        appleEngine.reset()
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
            var taps = f.store.activeGestures
            taps.gestures.tapToClick = false
            taps.twoFingerSwipe = nil
            f.store.updateGestures(taps, for: 1)
            let saved = f.preferences.data(forKey: "settings.v1")
            var notifications = 0
            let observation = f.hid.objectWillChange.sink { notifications += 1 }
            defer { observation.cancel() }
            for index in 0..<10_000 {
                f.send(1 + Double(index) * 0.008, x: 500 + Double(index % 200))
            }
            precondition(f.poster.moves > 0 && f.store.cursorTelemetry.latest.touching,
                "Real input must still move and feed the Live buffer")
            f.send(82)
            for index in 0..<10_000 {
                let time = f.start + 83 + Double(index) * 0.008
                f.now = Date(timeIntervalSince1970: time)
                let contacts = [0, 1].map { FingerContact(id: UInt8($0), x: 500 + Double($0) * 100,
                    y: 500 + Double(index % 200), touching: true, confident: true) }
                f.hid.receive(TrackpadReport(contacts: contacts, buttonDown: false,
                    scanTime: UInt16(truncatingIfNeeded: index * 80)), at: time)
            }
            precondition(f.poster.scrolls > 0, "Scroll reports must still be delivered")
            precondition(notifications == 0, "20,000 motion/scroll reports must not republish display metadata")
            precondition(f.preferences.data(forKey: "settings.v1") == saved, "Input must not rewrite tuning")
            let axes = [UInt32(0x30), 0x31].map {
                TrackpadDistanceScale.Axis(usage: $0, logicalMin: 0, logicalMax: 2048,
                    physicalMin: 0, physicalMax: 550, unit: 0x11, unitExponent: 0xE)
            }
            let scale = TrackpadDistanceScale(axes: axes)!
            f.hid.updateDistanceScale(scale)
            precondition(notifications == 1 && f.hid.distanceScale == scale, "Changed scale must notify the UI")
            for _ in 0..<10_000 { f.hid.updateDistanceScale(scale) }
            precondition(notifications == 1, "Equal non-nil metadata must also stay silent")
            f.hid.updateDistanceScale(nil)
            f.hid.updateDistanceScale(nil)
            precondition(notifications == 2 && f.hid.distanceScale == nil, "Disconnect clears scale once")
        }
        print("HID display isolation passed: 20,000 cursor/scroll reports, no view invalidations or tuning writes; real scale changes publish once.")
        check { f in
            var taps = f.store.activeGestures
            taps.oneFingerTap = .enter
            f.store.updateGestures(taps, for: 1)
            f.store.settings.devices = ProfileDevices(navigatorEnabled: false, appleEnabled: true, shareTapActions: false)
            var apple = taps
            apple.oneFingerTap = .appExplorer
            f.store.updateAppleGestures(apple, for: 1)
            f.send(1, x: 500); f.send(1.03)
            precondition(!f.explorer.isVisible && f.poster.actions == 0, "Disabled Navigator must not dispatch actions")
            f.sendApple(2, x: 500); f.sendApple(2.03)
            precondition(f.explorer.isVisible && f.applePoster.actions == 0, "Apple engine must use its layer override, not the shared Enter action")
            f.explorer.dismiss()
            f.store.settings.devices?.appleEnabled = false
            f.sendApple(3, x: 500); f.sendApple(3.03)
            precondition(!f.explorer.isVisible, "Profile-level Apple disable suppresses custom actions")
        }
        check { f in
            f.store.settings.devices = ProfileDevices(shareTapActions: false)
            let original = f.store.gestures(for: 1, device: .navigator)
            f.store.updateAppleGestures(original, for: 1)
            let session = GestureCalibrationSession(profileID: 1, profileName: "Apple", mode: .doubleTap, gestures: original)
            f.hid.startCalibrationSession(session, at: f.start, device: .apple)
            f.trials(.doubleTap)
            precondition(session.samples.isEmpty, "Navigator touches cannot calibrate the selected Apple device")
            for index in 0..<10 {
                let t = 1.0 + Double(index) * 3
                f.sendApple(t, x: 500); f.sendApple(t + 0.03)
                f.sendApple(t + 0.18, x: 500); f.sendApple(t + 0.21)
            }
            precondition(session.isComplete)
            f.hid.applyCalibration()
            precondition(f.store.gestures(for: 1, device: .navigator) == original, "Apple calibration must not modify shared Navigator settings")
            precondition(abs(f.store.gestures(for: 1, device: .apple).gestures.resolvedDoubleTapInterval - 0.18) < 0.0001)
            f.store.settings.customTapProfiles = [2]
            f.store.updateAppleGestures(original, for: 2)
            precondition(f.store.gestures(for: 2, device: .apple).gestures.doubleTapInterval == 0.18)
            f.store.settings.devices?.shareTapActions = true
            precondition(f.store.gestures(for: 2, device: .apple).gestures.doubleTapInterval == 0.18,
                         "Sharing actions must not discard the device's shared calibration")
        }
        print("Device profiles passed: per-device dispatch, disabled drivers, and isolated Apple calibration.")
        for action in [TapAction.appExplorer, .windowManager] {
            for clickAfterLift in [false, true] {
                let f = CalibrationFixture(appleActionsEnabled: true, appleHUDDelay: 0.08)
                var taps = f.store.activeGestures
                taps.twoFingerTap = action
                taps.twoFingerDoubleTap = TapAction.none
                taps.twoFingerTripleTap = TapAction.none
                taps.twoFingerSingleTapSwipe = nil
                taps.twoFingerDoubleTapSwipe = nil
                f.store.updateGestures(taps, for: 1)
                f.sendApple(1, x: 500, twoFingers: true)
                if !clickAfterLift { f.hid.nativeClickObserved() }
                f.sendApple(1.03)
                precondition(!f.explorer.isVisible, "Apple HUD waits for native click arbitration")
                if clickAfterLift { f.hid.nativeClickObserved() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.16))
                precondition(!f.explorer.isVisible && !f.pointer.locked, "Native secondary click wins before or just after touch lift")
                f.sendApple(2, x: 500, twoFingers: true); f.sendApple(2.03)
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                precondition(f.explorer.isVisible, "A fresh intentional gesture still opens the HUD")
                f.explorer.dismiss()
                f.finish()
            }
        }
        check { f in
            var taps = f.store.activeGestures
            taps.gestures.tapToClick = false
            taps.twoFingerSwipe = nil
            f.store.updateGestures(taps, for: 1)
            f.sendApple(1, x: 500) // Finger resting on the built-in trackpad.
            f.send(1.01, x: 500); f.send(1.03, x: 650)
            precondition(f.poster.moves > 0, "Resting Apple finger must not starve Navigator cursor reports")
            f.send(1.04)
            f.sendApple(1.05, x: 500); f.sendApple(1.06)
            f.store.settings.normal.kineticScroll = true
            f.store.settings.normal.kineticDecay = 0.95
            f.store.settings.normal.scrollMultiplier = 1
            @MainActor func scroll(_ t: Double, y: Double?) {
                f.now = Date(timeIntervalSince1970: f.start + t)
                let contacts = y.map { y in [
                    FingerContact(id: 0, x: 500, y: y, touching: true, confident: true),
                    FingerContact(id: 1, x: 650, y: y, touching: true, confident: true)
                ] } ?? []
                f.hid.receive(TrackpadReport(contacts: contacts, buttonDown: false, scanTime: 0), at: f.start + t)
            }
            scroll(2, y: 500); scroll(2.02, y: 530); scroll(2.04, y: 565); scroll(2.06, y: 610); scroll(2.08, y: nil)
            let before = f.poster.scrolls
            precondition(before > 0)
            f.sendApple(2.09, x: 500)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            precondition(f.poster.scrolls > before, "Apple touch must not reset Navigator's scroll momentum")
            f.sendApple(2.2)
        }
        print("Native click arbitration and Navigator priority/momentum regression tests passed.")
        for action in [TapAction.appExplorer, .windowManager] {
            let f = CalibrationFixture(appleActionsEnabled: true)
            var taps = f.store.activeGestures
            taps.oneFingerTap = action
            f.store.updateGestures(taps, for: 1)
            f.sendApple(1, x: 500); f.sendApple(1.03)
            precondition(f.pointer.locked && f.explorer.isVisible, "Apple-opened HUD holds the pointer still")
            f.explorer.isEditing = true
            precondition(!f.pointer.locked, "Editing always restores pointer control")
            f.explorer.isEditing = false
            precondition(f.pointer.locked, "Returning to the gesture HUD recaptures the pointer")
            f.sendApple(1.1, x: 500); f.sendApple(1.14, x: 600); f.sendApple(1.18)
            precondition(f.explorer.selections == [.right] && !f.pointer.locked, "Selection releases capture")
            f.sendApple(2, x: 500); f.sendApple(2.03)
            f.pointer.locked = false; f.pointer.onInterruption?()
            precondition(!f.explorer.isVisible, "System tap disable cancels the HUD without recapturing")
            f.pointer.failCapture = true
            f.sendApple(3, x: 500); f.sendApple(3.03)
            precondition(!f.explorer.isVisible && !f.pointer.locked)
            precondition(f.hid.appleTrackpadStatus.contains("Could not hold"))
            f.pointer.failCapture = false
            f.sendApple(4, x: 500); f.sendApple(4.03)
            precondition(f.pointer.locked)
            f.hid.stop()
            precondition(!f.pointer.locked)
            f.send(5, x: 500); f.send(5.03)
            precondition(f.explorer.isVisible && !f.pointer.locked, "Navigator never freezes the native pointer")
            f.explorer.dismiss()
            f.finish()
        }
        do {
            let f = CalibrationFixture(appleActionsEnabled: true)
            var taps = f.store.activeGestures
            taps.oneFingerTap = .appExplorer
            f.store.updateGestures(taps, for: 1)
            f.sendApple(1, x: 500); f.sendApple(1.03)
            precondition(f.pointer.locked)
            f.hid.setAppleTrackpadEnabled(false)
            precondition(!f.pointer.locked && !f.explorer.isVisible, "Disabling Apple actions releases capture immediately")
            f.finish()
        }
        print("Pointer/HUD integration passed: Apple capture, editor escape, selection/stop/disable/timeout release, denial fallback, Navigator isolation.")
        for action in [TapAction.appExplorer, .windowManager] {
            check { f in
                var taps = f.store.activeGestures
                taps.oneFingerTap = action
                f.store.updateGestures(taps, for: 1)
                f.sendApple(1, x: 500); f.sendApple(1.03)
                precondition(f.explorer.isVisible, "Apple tap must open the shared HUD")
                precondition(f.explorer.windowManagerShows == (action == .windowManager ? 1 : 0))
                f.send(1.1, x: 500); f.send(1.14, x: 600); f.send(1.18)
                f.sendApple(1.2, x: 500, deviceID: 43); f.sendApple(1.24, x: 600, deviceID: 43); f.sendApple(1.28, deviceID: 43)
                precondition(f.explorer.isVisible && f.explorer.selections.isEmpty, "Other devices cannot steer this HUD")
                f.sendApple(1.3, x: 500); f.sendApple(1.34, x: 600); f.sendApple(1.38)
                precondition(f.explorer.selections == [.right])
                precondition(f.applePoster.actions == 0 && f.applePoster.moves == 0 && f.applePoster.scrolls == 0 && f.applePoster.dragStarts == 0)
                precondition(f.poster.actions == 0 && f.poster.moves == 0, "Navigator remains quiet while Apple owns the HUD")
            }
        }
        check { f in
            f.hid.explorerHold(true)
            f.sendApple(1, x: 500); f.sendApple(1.05, x: 600); f.sendApple(1.1)
            precondition(f.explorer.selections == [.right], "Keyboard-opened HUD accepts Apple input")
            f.hid.explorerHold(false)
        }
        check { f in
            f.send(0.1, x: 500) // Resting Navigator finger must not block Apple capture.
            let session = f.begin(device: .apple)
            for index in 0..<10 {
                let t = 1.0 + Double(index) * 3
                f.sendApple(t, x: 500); f.sendApple(t + 0.03)
                // Navigator touches must never count as the second Apple tap.
                f.send(t + 0.05, x: 500); f.send(t + 0.07)
                f.sendApple(t + 0.18, x: 500); f.sendApple(t + 0.21)
            }
            precondition(session.isComplete && session.sampleCount == 10)
            precondition(abs((session.medianDoubleTapInterval ?? 0) - 0.18) < 0.0001)
            precondition(f.applePoster.actions == 0 && f.poster.actions == 0)
        }
        print("Apple HID integration passed: action HUDs, source isolation, hotkey entry, and calibration.")
        check { f in
            let layer = ExplorerHoldLayer(name: "Direct", holdShortcut: nil)
            f.store.settings.appExplorer = AppExplorerSettings(holdLayers: [layer])
            f.send(0.1, x: 500); f.send(0.15)
            f.hid.openHUDLayer(layer.id, fromKeyboard: true)
            precondition(f.explorer.layerShows == [layer.id])
            f.sendApple(1, x: 500); f.sendApple(1.05, x: 600); f.sendApple(1.1)
            precondition(f.explorer.selections == [.right], "Direct keyboard layer launch must hand off from Navigator to Apple")
            f.store.settings.appExplorer?.holdLayers?[0].appBundleID = "restricted.editor"
            f.hid.foregroundAppChanged("other.app")
            f.hid.openHUDLayer(layer.id, fromKeyboard: true)
            precondition(!f.explorer.isVisible && f.explorer.layerShows.count == 1)
        }
        print("Direct HUD-layer HID handoff and app restriction passed")
        check { f in
            var taps = f.store.activeGestures
            taps.oneFingerTap = .appExplorer
            f.store.updateGestures(taps, for: 1)
            f.sendApple(1, x: 500)
            f.sendApple(1.1, x: 650)
            f.hid.navigatorDisconnected()
            f.sendApple(1.11, x: 650); f.sendApple(1.14)
            precondition(!f.explorer.isVisible, "Navigator unplug must not turn a moved Apple contact into a fresh tap")
            f.sendApple(2, x: 500); f.sendApple(2.03)
            precondition(f.explorer.isVisible)
            f.hid.navigatorDisconnected()
            f.sendApple(2.1, x: 500); f.sendApple(2.14, x: 600); f.sendApple(2.18)
            precondition(f.explorer.selections == [.right], "Unrelated Navigator unplug must preserve the Apple HUD")
        }
        check { f in
            f.hid.explorerHold(true)
            f.explorer.isEditing = true
            f.engine.isEditingInterface = true
            f.hid.foregroundAppChanged("local.rotagivan")
            precondition(f.explorer.isVisible, "Focusing the editor must not dismiss it")
            f.hid.explorerHold(false)
            precondition(f.explorer.isVisible && !f.explorer.alternateHeld, "Release the opening hotkey while editing")
            f.send(0.1, x: 500); f.send(0.14)
            precondition(f.poster.actions == 1, "HID passes safe pointer/tap input through while editing")
            var settings = f.store.settings.appExplorer ?? AppExplorerSettings()
            settings.setFavorite(AppExplorerFavorite(direction: .left, name: "Work", children: []), at: .left)
            f.store.settings.appExplorer = settings
            f.send(0.2)
            precondition(f.explorer.isVisible, "Saving favorites must not invalidate the editor")
            f.hid.foregroundAppChanged("com.apple.finder")
            precondition(!f.explorer.isVisible, "Switching to another app closes the editor")
        }
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
            let before = f.store.gestures(for: 1, device: .navigator)
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
            precondition(f.store.gestures(for: 1, device: .navigator) == before, "Calibration must not save before Apply")
            f.hid.applyCalibration()
            let applied = f.store.gestures(for: 1, device: .navigator)
            precondition(applied.gestures.tripleTapFirstInterval == 0.145)
            precondition(applied.gestures.tripleTapSecondInterval == 0.245)
            precondition(applied.gestures.doubleTapInterval == before.gestures.doubleTapInterval)
            precondition(f.store.gestures(for: 2, device: .navigator).gestures.tripleTapSecondInterval == 0.245)
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
        for action in [TapAction.appExplorer, .windowManager] {
        for cancellation in 0..<4 {
            check { f in
                var taps = f.store.activeGestures
                taps.oneFingerTap = action
                f.store.updateGestures(taps, for:1)
                f.send(1, x:500); f.send(1.03)
                precondition(f.explorer.isVisible && f.poster.actions == 0)
                precondition(f.explorer.windowManagerShows == (action == .windowManager ? 1 : 0))
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
        }
        print("App Explorer HID gate passed: action routing, exclusive input, profile/stop/Escape cancellation, and lift draining.")
        check { f in
            let before = f.store.gestures(for: 1, device: .navigator)
            let session = f.begin(.singleTapSwipe)
            for index in 0..<10 {
                let t = 1.0 + Double(index) * 2
                f.send(t, x: 500); f.send(t + 0.03)
                f.send(t + 0.18, x: 700); f.send(t + 0.22, x: 800); f.send(t + 0.30)
            }
            precondition(session.isComplete && session.sampleCount == 10)
            precondition(f.poster.actions == 0 && f.poster.moves == 0 && f.poster.dragStarts == 0)
            precondition(f.store.gestures(for: 1, device: .navigator) == before)
            f.hid.applyCalibration()
            var expected = before
            expected.singleTapSwipe = .singleTapDefaults
            expected.singleTapSwipe!.swipeWindow = 0.15
            expected.singleTapSwipe!.fastSwipeDuration = 0.12
            precondition(f.store.gestures(for: 1, device: .navigator) == expected, "Single-swipe calibration changes only its own timings")
        }
        check { f in
            let before = f.store.gestures(for: 1, device: .navigator)
            let session = f.begin()
            f.hid.applyCalibration()
            assert(f.hid.calibrationSession != nil && f.store.gestures(for: 1, device: .navigator) == before)
            f.trials(.doubleTap)
            assert(session.isComplete && session.sampleCount == 10)
            assert(!f.hid.isCalibrating)
            assert(f.poster.actions == 0 && f.poster.moves == 0 && f.poster.scrolls == 0 && f.poster.dragStarts == 0)
            assert(f.store.gestures(for: 1, device: .navigator) == before, "Capture must not save until Apply")
            f.hid.applyCalibration()
            var expected = before
            expected.gestures.doubleTapInterval = 0.145
            assert(f.store.gestures(for: 1, device: .navigator) == expected)
            assert(f.hid.calibrationSession == nil)
            f.send(40, x: 500); f.send(40.03)
            assert(f.poster.actions == 1, "Normal taps resume after capture")
        }
        check { f in
            let before = f.store.gestures(for: 1, device: .navigator)
            let session = f.begin(.doubleTapSwipe)
            f.trials(.doubleTapSwipe)
            assert(session.isComplete && session.sampleCount == 10)
            assert(f.poster.actions == 0 && f.poster.moves == 0 && f.poster.scrolls == 0 && f.poster.dragStarts == 0)
            f.hid.applyCalibration()
            var expected = before
            expected.gestures.doubleTapInterval = 0.145
            expected.doubleTapSwipe?.swipeWindow = 0.195
            assert(f.store.gestures(for: 1, device: .navigator) == expected, "Only timing fields change; bindings/enabled/distance survive")
        }
        check { f in
            let before = f.store.gestures(for: 1, device: .navigator)
            _ = f.begin()
            f.send(1, x: 500)
            f.hid.keyboardAction(0, down: true)
            f.hid.keyboardAction(2, down: true)
            f.hid.endCalibration()
            f.send(1.04, x: 600); f.send(1.08)
            assert(f.poster.actions == 0 && f.poster.moves == 0 && f.poster.dragStarts == 0, "Cancel must drain in-flight touch")
            assert(f.store.gestures(for: 1, device: .navigator) == before)
            f.send(2, x: 500); f.send(2.03)
            assert(f.poster.actions == 1)
        }
        check { f in
            let session = f.begin()
            f.send(1, x: 500)
            f.hid.stop()
            assert(session.cancellationReason != nil && !f.hid.isCalibrating)
            let before = f.store.gestures(for: 1, device: .navigator)
            f.hid.applyCalibration()
            assert(f.store.gestures(for: 1, device: .navigator) == before)
        }
        check { f in
            let session = f.begin()
            var changed = f.store.gestures(for: 1, device: .navigator)
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
            assert(f.store.gestures(for: 1, device: .navigator).gestures.doubleTapInterval == 0.6)
        }
        check { f in
            let session = f.begin()
            f.trials(.doubleTap)
            assert(session.isComplete)
            var changed = f.store.gestures(for: 1, device: .navigator)
            changed.gestures.doubleTapInterval = 0.5
            f.store.updateGestures(changed, for: 1)
            f.hid.applyCalibration()
            assert(session.cancellationReason != nil)
            assert(f.store.gestures(for: 1, device: .navigator) == changed, "Completed stale results must not overwrite newer settings")
        }
        check { f in
            let session = f.begin()
            f.trials(.doubleTap)
            let before = f.store.gestures(for: 1, device: .navigator)
            f.store.setActiveProfile(2)
            f.hid.applyCalibration()
            assert(session.cancellationReason != nil)
            assert(f.store.gestures(for: 1, device: .navigator) == before)
        }
        print("Calibration integration tests passed")
    }
}
