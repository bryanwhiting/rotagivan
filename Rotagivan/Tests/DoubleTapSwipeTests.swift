import Foundation
import CoreGraphics

private final class FakePoster: GestureEventPosting {
    var dragging = false
    var taps: [(TapAction, RecordedShortcut?)] = []
    var moves = 0
    var deltas: [(Double, Double)] = []
    var scrolls = 0
    var dragStarts = 0
    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) { taps.append((action, shortcut)) }
    func click(button: CGMouseButton, count: Int) {}
    func move(dx: Double, dy: Double) { if dx != 0 || dy != 0 { moves += 1; deltas.append((dx, dy)) } }
    func scroll(dx: Double, dy: Double, momentum: Bool) { scrolls += 1 }
    func beginDrag() { dragging = true; dragStarts += 1 }
    func endDrag() { dragging = false }
}

@MainActor private final class Fixture {
    let suite = "Rotagivan.SwipeTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let store: SettingsStore
    let poster = FakePoster()
    var now = Date(timeIntervalSince1970: 1_000)
    var engine: GestureEngine!
    let chord = RecordedShortcut(keyCode: 64, modifiers: 1572864, keyLabel: "F17")
    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "migration.rotagivan.v1")
        store = SettingsStore(defaults: preferences)
        store.settings.defaultProfileID = 1
        store.setActiveProfile(1)
        var taps = store.settings.gestures(for: 1)
        taps.gestures.doubleTapInterval = 0.3
        taps.oneFingerTap = .leftClick
        taps.oneFingerDoubleTap = .rightClick
        var swipe = DoubleTapSwipeSettings(enabled: true, left: chord, right: chord, up: chord, down: chord)
        for direction in SwipeDirection.allCases { swipe[direction] = chord }
        taps.doubleTapSwipe = swipe
        store.updateGestures(taps, for: 1)
        engine = GestureEngine(store: store, poster: poster, clock: { [unowned self] in self.now })
    }
    func send(_ time: Double, _ points: [(Double, Double)] = [], button: Bool = false) {
        now = Date(timeIntervalSince1970: 1_000 + time)
        let contacts = points.enumerated().map {
            FingerContact(id: UInt8($0.offset), x: $0.element.0, y: $0.element.1, touching: true, confident: true)
        }
        engine.process(TrackpadReport(contacts: contacts, buttonDown: button, scanTime: UInt16(Int(time*10_000) % 65_536)), receivedAt: 1_000 + time)
    }
    func doubleTap() {
        send(0, [(500,500)]); send(0.03)
        send(0.10, [(500,500)]); send(0.13)
    }
    func enableSingleSwipe() {
        var taps = store.settings.gestures(for: 1)
        taps.gestures.tapToClick = true
        taps.gestures.touchAndHoldDrag = true
        taps.gestures.tapMaxDuration = 0.25
        taps.gestures.tapMaxMovement = 30
        taps.singleTapSwipe = .singleTapDefaults
        taps.singleTapSwipe!.enabled = true
        for (index, direction) in SwipeDirection.allCases.enumerated() {
            taps.singleTapSwipe![direction] = RecordedShortcut(keyCode: UInt16(18 + index), modifiers: 0, keyLabel: direction.title)
        }
        store.updateGestures(taps, for: 1)
    }
    func finish() {
        engine.reset()
        preferences.removePersistentDomain(forName: suite)
    }
}

@main struct DoubleTapSwipeTests {
    @MainActor private static func check(_ body: (Fixture) throws -> Void) rethrows {
        let f = Fixture()
        defer { f.finish() }
        try body(f)
    }

    @MainActor static func main() throws {
        try check { f in
            var taps = f.store.settings.gestures(for: 1)
            taps.oneFingerTap = .appExplorer
            taps.gestures.tapToClick = false
            f.store.updateGestures(taps, for: 1)
            let before = try JSONEncoder().encode(f.store.settings)
            var openings = 0
            f.engine.onAppExplorer = { openings += 1 }
            f.engine.isEditingInterface = true
            f.send(0, [(500,500)]); f.send(0.03)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .leftClick && openings == 0,
                "UI editing gets an immediate click even with disabled/custom profile taps")
            f.store.foregroundBundleID = "com.google.Chrome"
            f.send(0.1, [(500,500),(700,500)]); f.send(0.14, [(600,500),(800,500)]); f.send(0.18)
            precondition(f.poster.scrolls > 0 && f.poster.taps.count == 1, "Editing must not fire navigation shortcuts")
            f.engine.isEditingInterface = false
            f.send(1, [(500,500)]); f.send(1.03)
            precondition(f.poster.taps.count == 1, "Restore disabled profile tapping on exit")
            let decoded = try JSONDecoder().decode(StoredSettings.self, from: before)
            precondition(decoded.gestures(for: 1) == f.store.settings.gestures(for: 1), "Temporary editing behavior is not persisted")
        }
        check { f in
            f.doubleTap() // Queue a swipe action before entering the editor.
            f.engine.isEditingInterface = true
            f.send(0.2, [(500,500)]); f.send(0.24, [(600,500)]); f.send(0.28)
            precondition(f.poster.taps.isEmpty && f.poster.moves > 0, "Entering editing cancels queued shortcuts but allows pointer movement")
            f.engine.isEditingInterface = false
            f.send(1, [(500,500)]); f.send(1.03)
            f.send(1.1, [(500,500)]); f.send(1.13)
            f.send(1.2, [(500,500)]); f.send(1.24, [(600,500)]); f.send(1.28)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut, "Gesture actions resume after editing")
        }
        for chrome in [false,true] {
            check { f in
                f.store.foregroundBundleID = chrome ? "com.google.Chrome" : "com.apple.finder"
                f.send(0,[(500,500),(700,500)])
                f.send(0.08,[(600,500),(800,500)])
                f.send(0.12)
                if chrome {
                    precondition(f.poster.taps.count == 1 && f.poster.taps[0].1?.keyCode == 33)
                    precondition(f.poster.scrolls == 0 && f.poster.moves == 0 && f.poster.dragStarts == 0)
                } else { precondition(f.poster.taps.isEmpty && f.poster.scrolls > 0) }
            }
        }
        check { f in
            f.store.foregroundBundleID = "com.google.Chrome"
            f.send(0,[(500,500),(700,500)]); f.send(0.05,[(500,580),(700,580)]); f.send(0.10)
            precondition(f.poster.scrolls > 0 && f.poster.taps.isEmpty)
        }
        for trigger in 0..<3 {
            check { f in
                var openings = 0
                f.engine.onAppExplorer = { openings += 1 }
                var taps = f.store.activeGestures
                if trigger == 0 {
                    taps.doubleTapSwipe = DoubleTapSwipeSettings(enabled:true)
                    taps.doubleTapSwipe!.setAction(.appExplorer, for:.down)
                } else if trigger == 1 {
                    taps.singleTapSwipe = .singleTapDefaults
                    taps.singleTapSwipe!.enabled = true
                    taps.singleTapSwipe!.setAction(.appExplorer, for:.down)
                } else {
                    taps.doubleTapSwipe = nil
                    taps.oneFingerDoubleTap = .appExplorer
                }
                f.store.updateGestures(taps, for:1)
                f.send(0,[(500,500)]); f.send(0.03)
                if trigger != 1 { f.send(0.10,[(500,500)]); f.send(0.13) }
                if trigger != 2 {
                    f.send(0.20,[(500,500)]); f.send(0.24,[(500,600)]); f.send(0.28)
                }
                precondition(openings == 1 && f.poster.taps.isEmpty && f.poster.moves == 0 && f.poster.dragStarts == 0)
                f.send(0.8)
                precondition(openings == 1, "No delayed tap after opening App Explorer")
            }
        }
        let directionPoints: [(SwipeDirection, (Double, Double))] = [
            (.left, (400, 500)),
            (.right, (600, 500)),
            (.up, (500, 400)),
            (.down, (500, 600)),
            (.topLeft, (400, 400)),
            (.topRight, (600, 400)),
            (.bottomLeft, (400, 600)),
            (.bottomRight, (600, 600)),
        ]
        for (direction, point) in directionPoints {
            check { f in
                f.enableSingleSwipe()
                f.send(0, [(900,900)]); f.send(0.03)
                f.send(0.10, [(500,500)]); f.send(0.14, [point])
                precondition(f.poster.taps.isEmpty && f.poster.dragStarts == 0 && f.poster.moves == 0)
                f.send(0.20)
                precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut)
                precondition(f.poster.taps[0].1 == f.store.activeGestures.singleTapSwipe![direction])
                precondition(f.poster.moves == 0 && f.poster.dragStarts == 0)
            }
        }
        check { f in
            f.enableSingleSwipe()
            f.doubleTap() // No swipe: still arms the existing double-tap + swipe.
            f.send(0.20, [(500,500)]); f.send(0.24, [(600,500)]); f.send(0.28)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].1 == f.chord)
        }
        check { f in
            f.enableSingleSwipe()
            var taps = f.store.activeGestures
            taps.doubleTapSwipe = nil
            f.store.updateGestures(taps, for: 1)
            f.doubleTap()
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .rightClick)
        }
        check { f in
            f.enableSingleSwipe()
            f.send(0, [(500,500)]); f.send(0.03)
            f.send(0.10, [(500,500)]); f.send(0.15, [(600,500)])
            f.send(0.30, [(610,500)]) // Too slow: held drag, not swipe.
            precondition(f.poster.dragStarts == 1 && f.poster.dragging && f.poster.taps.isEmpty)
            f.send(0.35)
            precondition(!f.poster.dragging && f.poster.taps.isEmpty)
        }
        check { f in
            f.enableSingleSwipe()
            f.send(0, [(500,500)]); f.send(0.03)
            f.send(0.10, [(500,500)]); f.send(0.30, [(500,500)])
            precondition(f.poster.dragging, "Stationary hold still starts drag after the quick-swipe deadline")
            f.send(0.35)
            precondition(!f.poster.dragging)
        }
        for invalidation in 0..<5 {
            check { f in
                f.enableSingleSwipe()
                f.send(0, [(500,500)]); f.send(0.03); f.send(0.10, [(500,500)])
                switch invalidation {
                case 0: f.send(0.12, [(1100,500)]) // Sensor jump.
                case 1: f.store.setActiveProfile(2)
                case 2:
                    var taps = f.store.activeGestures
                    taps.singleTapSwipe!.enabled = false
                    f.store.updateGestures(taps, for: 1)
                case 3: f.send(0.12, [(550,500),(700,500)])
                default: f.engine.reset()
                }
                f.send(0.15, [(600,500)]); f.send(0.20)
                precondition(!f.poster.taps.contains { $0.0 == .shortcut } && f.poster.dragStarts == 0)
            }
        }
        check { f in
            f.enableSingleSwipe()
            var taps = f.store.activeGestures
            taps.singleTapSwipe!.right = nil
            f.store.updateGestures(taps, for: 1)
            f.send(0, [(500,500)]); f.send(0.03)
            f.send(0.10, [(500,500)]); f.send(0.14, [(600,500)]); f.send(0.20)
            precondition(f.poster.taps.isEmpty && f.poster.dragStarts == 0, "Unbound direction never leaks a click")
        }
        print("Passed fast single-tap swipe directions, double-tap coexistence, hold-to-drag, and cancellation checks.")
        check { f in
            f.enableSingleSwipe()
            f.send(0, [(500,500)]); f.send(0.03)
            RunLoop.main.run(until: Date().addingTimeInterval(0.34))
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .leftClick, "No second touch: deliver single tap")
        }
        check { f in
            f.enableSingleSwipe()
            f.send(0, [(500,500)]); f.send(0.03); f.send(0.10, [(500,500)])
            RunLoop.main.run(until: Date().addingTimeInterval(0.22))
            precondition(f.poster.dragging && f.poster.taps.isEmpty, "Hold deadline fires without new HID reports")
            f.send(0.35)
            precondition(!f.poster.dragging)
        }
        check { f in
            f.enableSingleSwipe()
            var taps = f.store.activeGestures
            taps.gestures.touchAndHoldDrag = false
            taps.oneFingerDoubleTap = TapAction.none
            taps.doubleTapSwipe = nil
            f.store.updateGestures(taps, for: 1)
            f.doubleTap()
            precondition(f.poster.taps.count == 2 && f.poster.taps.allSatisfy { $0.0 == .leftClick }, "No double action: keep both taps")
        }
        try check { f in
            f.enableSingleSwipe()
            let parent = f.store.activeGestures.singleTapSwipe
            precondition(f.store.settings.effectiveGestures(for: 2).singleTapSwipe == parent)
            var copied = f.store.settings
            copied.makeDefault(2)
            precondition(copied.gestures(for: 2).singleTapSwipe == parent)
            f.store.settings.customTapProfiles = [2]
            precondition(f.store.settings.effectiveGestures(for: 2).singleTapSwipe == nil)
            let decoded = try JSONDecoder().decode(StoredSettings.self, from: JSONEncoder().encode(f.store.settings))
            precondition(decoded.gestures(for: 1).singleTapSwipe == parent)
        }
        for (direction, point) in directionPoints {
            check { f in
                // Give each direction a distinct key to catch mapping errors.
                var taps = f.store.settings.gestures(for: 1)
                for (i, dir) in SwipeDirection.allCases.enumerated() {
                    taps.doubleTapSwipe![dir] = RecordedShortcut(keyCode: UInt16(18+i), modifiers: 0, keyLabel: dir.title)
                }
                f.store.updateGestures(taps, for: 1)
                f.doubleTap()
                precondition(f.poster.taps.isEmpty && !f.poster.dragging)
                f.send(0.20, [(500,500)])
                f.send(0.24, [point])
                precondition(f.poster.taps.isEmpty) // Fire only on lift.
                f.send(0.27)
                f.send(0.28)
                precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut)
                precondition(f.poster.taps[0].1 == taps.doubleTapSwipe![direction])
                precondition(f.poster.moves == 0 && f.poster.scrolls == 0 && f.poster.dragStarts == 0)
            }
        }
        print("Passed eight directional shortcuts, one dispatch on lift, no cursor/scroll/click leakage.")

        for swipe in [false, true] {
            check { f in
                var taps = f.store.settings.gestures(for: 1)
                taps.oneFingerTripleTap = .tripleLeftClick
                f.store.updateGestures(taps, for: 1)
                f.doubleTap()
                f.send(0.20, [(500, 500)])
                f.send(0.22, [(swipe ? 600 : 502, 500)])
                f.send(0.24)
                precondition(f.poster.taps.map { $0.0 } == [swipe ? .shortcut : .tripleLeftClick])
                precondition(f.poster.moves == 0 && f.poster.scrolls == 0 && f.poster.dragStarts == 0)
            }
        }
        check { f in
            var taps = f.store.settings.gestures(for: 1)
            taps.oneFingerTripleTap = .tripleLeftClick
            taps.gestures.doubleTapInterval = 0.15
            f.store.updateGestures(taps, for: 1)
            f.doubleTap()
            f.send(0.29, [(500, 500)]); f.send(0.31)
            precondition(f.poster.taps.map { $0.0 } == [.rightClick], "A late third tap is not a triple tap")
        }
        check { f in
            var taps = f.store.settings.gestures(for: 1)
            taps.oneFingerTripleTap = .tripleLeftClick
            taps.gestures.tapMaxDuration = 0.08
            f.store.updateGestures(taps, for: 1)
            f.doubleTap()
            f.send(0.20, [(500, 500)]); f.send(0.32)
            precondition(f.poster.taps.map { $0.0 } == [.rightClick], "A held third touch is not a triple tap")
        }
        print("Triple tap and double-tap swipe coexistence, stationary cursor, late-tap and held-touch rejection passed.")

        check { f in
            f.doubleTap()
            f.send(0.60)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .rightClick)
            f.send(0.61)
            precondition(f.poster.taps.count == 1)
        }
        check { f in
            var taps = f.store.settings.gestures(for: 1)
            taps.doubleTapSwipe!.swipeWindow = 0.1
            f.store.updateGestures(taps, for: 1)
            f.doubleTap()
            f.now = Date(timeIntervalSince1970: 1_000.3)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .rightClick)
        }
        check { f in
            f.doubleTap()
            f.send(0.20, [(500,500)]); f.send(0.25, [(510,500)]); f.send(0.28)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .rightClick)
        }
        check { f in
            var taps = f.store.settings.gestures(for: 1)
            taps.oneFingerDoubleTap = TapAction.none
            f.store.updateGestures(taps, for: 1)
            f.doubleTap(); f.send(0.60)
            precondition(f.poster.taps.count == 2 && f.poster.taps.allSatisfy { $0.0 == .leftClick })
        }
        print("Passed ordinary-double fallback, real timer expiry without reports, short-third-touch fallback, and two singles fallback.")

        check { f in
            f.doubleTap()
            f.send(0.20, [(500,500)])
            f.send(0.25, [(592.387953,538.268343)]) // 22.5-degree sector boundary.
            f.send(0.28)
            precondition(f.poster.taps.isEmpty && f.poster.moves == 0)
        }
        check { f in
            f.doubleTap()
            f.send(0.20, [(500,500)]); f.send(0.25, [(1000,500)]); f.send(0.28)
            precondition(f.poster.taps.isEmpty)
        }
        check { f in
            f.doubleTap()
            f.send(0.20, [(500,500)]); f.send(1.00, [(600,500)]); f.send(1.02)
            precondition(f.poster.taps.isEmpty)
        }
        check { f in
            f.doubleTap()
            f.send(0.20, [(500,500)]); f.send(0.24, [(550,500),(570,550)]); f.send(0.30)
            precondition(f.poster.taps.isEmpty && f.poster.scrolls == 0)
        }
        check { f in
            var taps = f.store.settings.gestures(for: 1); taps.doubleTapSwipe!.down = nil
            f.store.updateGestures(taps, for: 1)
            f.doubleTap()
            f.send(0.20, [(500,500)]); f.send(0.24, [(500,600)]); f.send(0.28)
            precondition(f.poster.taps.isEmpty)
        }
        check { f in
            var taps = f.store.settings.gestures(for: 1); taps.doubleTapSwipe!.topLeft = nil
            f.store.updateGestures(taps, for: 1)
            f.doubleTap()
            f.send(0.20, [(500,500)]); f.send(0.24, [(400,400)]); f.send(0.28)
            precondition(f.poster.taps.isEmpty, "An unbound diagonal must not fall back to a cardinal shortcut or double tap")
        }
        print("Passed boundary, sensor jump, long hold, added finger, and unbound cardinal/diagonal cancellation.")

        check { f in
            f.doubleTap(); f.send(0.20, [(500,500)])
            f.store.setActiveProfile(2)
            f.send(0.25, [(600,500)]); f.send(0.28)
            precondition(f.poster.taps.isEmpty && f.poster.moves == 0)
        }
        check { f in
            f.send(0, [(500,500)]); f.send(0.03)
            f.store.setActiveProfile(2)
            f.send(0.10, [(500,500)]); f.send(0.13); f.send(0.2, [(500,500)]); f.send(0.25, [(600,500)]); f.send(0.28)
            precondition(!f.poster.taps.contains { $0.0 == .shortcut })
        }
        check { f in
            f.doubleTap()
            f.store.settings.enabled = false
            f.send(0.6)
            precondition(f.poster.taps.isEmpty)
        }
        for keyboard in [false, true] {
            check { f in
                f.doubleTap()
                if keyboard { f.engine.keyboardAction(5, down: true) }
                f.send(0.20, [(500,500)], button: !keyboard)
                f.send(0.25, [(600,500)], button: !keyboard)
                f.send(0.28, button: !keyboard)
                if keyboard { f.engine.keyboardAction(5, down: false) }
                f.send(0.30)
                precondition(f.poster.taps.isEmpty && f.poster.dragStarts == 1 && !f.poster.dragging)
            }
        }
        check { f in
            f.send(0, [(500,500)]); f.send(0.03)
            f.send(0.10, [(500,500)]); f.send(0.12, [(540,500)]); f.send(0.15)
            precondition(f.poster.dragStarts == 1 && !f.poster.dragging && f.poster.taps.isEmpty)
        }
        check { f in
            var taps = f.store.settings.gestures(for: 1)
            taps.doubleTapSwipe = nil
            f.store.updateGestures(taps, for: 1)
            f.doubleTap()
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .rightClick)
        }
        print("Passed cross-profile cancellation, disable/reset, physical and keyboard drags, original tap-hold drag and legacy behavior.")

        for deferred in [false, true] {
            check { f in
                var taps = f.store.settings.gestures(for: 1)
                taps.gestures.tapMaxDuration = 0.08
                taps.gestures.tapMaxMovement = 3
                taps.gestures.doubleTapInterval = 0.10
                taps.doubleTapSwipe = nil
                taps.oneFingerDoubleTap = deferred ? .rightClick : TapAction.none
                f.store.updateGestures(taps, for: 1)
                f.send(0, [(500,500)]); f.send(0.03)
                // Far outside tap radius and sensor-jump limit, but a NEW
                // contact must neither jump the cursor nor prevent pickup.
                f.send(0.35, [(1500,1500)])
                precondition(f.poster.moves == 0 && !f.poster.dragging)
                // Each report is below 4 units; displacement still arms drag.
                f.send(0.36, [(1502,1500)]); f.send(0.37, [(1504,1500)])
                precondition(f.poster.dragging && f.poster.dragStarts == 1)
                precondition(f.poster.deltas.allSatisfy { hypot($0.0, $0.1) < 50 })
                f.send(0.4)
                precondition(!f.poster.dragging, "Repositioned tap-drag releases on lift")
            }
        }
        check { f in
            f.send(0, [(500,500)]); f.send(0.03)
            f.send(0.35, [(1500,1500)])
            RunLoop.main.run(until: Date().addingTimeInterval(0.16))
            precondition(f.poster.dragging && f.poster.dragStarts == 1 && f.poster.moves == 0)
            f.send(0.55)
            precondition(!f.poster.dragging)
        }
        check { f in
            f.send(0, [(500,500)]); f.send(0.03)
            f.send(0.1, [(1500,1500)]); f.send(0.13)
            precondition(f.poster.dragStarts == 0, "Distant quick second tap stays a double tap")
            f.send(0.6)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .rightClick)
        }
        check { f in
            f.send(0, [(500,500)]); f.send(0.03)
            f.send(0.5, [(1500,1500)]); f.send(0.52, [(1510,1500)]); f.send(0.55)
            precondition(f.poster.dragStarts == 0, "Expired pickup must not start a drag")
        }
        for cancellation in 0..<4 {
            check { f in
                f.send(0, [(500,500)]); f.send(0.03)
                f.send(0.1, [(1500,1500)])
                switch cancellation {
                case 0: f.send(0.11, [(1500,1500), (1600,1500)])
                case 1: f.send(0.11, [(2000,1500)]) // Same-contact sensor jump.
                case 2: f.store.setActiveProfile(2)
                default:
                    var taps = f.store.settings.gestures(for: 1)
                    taps.gestures.touchAndHoldDrag = false
                    f.store.updateGestures(taps, for: 1)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.16))
                precondition(f.poster.dragStarts == 0)
                f.send(0.3)
            }
        }
        print("Passed distant second-touch pickup, gentle cumulative movement, stationary hold, no landing jump, quick double tap, expiry, and safe cancellation.")

        try check { f in
            let parent = f.store.settings.gestures(for: 1).doubleTapSwipe
            precondition(f.store.settings.effectiveGestures(for: 2).doubleTapSwipe == parent)
            var copiedSettings = f.store.settings
            copiedSettings.makeDefault(2)
            precondition(copiedSettings.gestures(for: 2).doubleTapSwipe == parent)
            f.store.settings.customTapProfiles = [2]
            precondition(f.store.settings.effectiveGestures(for: 2).doubleTapSwipe == nil)
            let encoded = try JSONEncoder().encode(f.store.settings)
            let decoded = try JSONDecoder().decode(StoredSettings.self, from: encoded)
            precondition(decoded.gestures(for: 1).doubleTapSwipe == parent)
            for direction in [.topLeft, .topRight, .bottomLeft, .bottomRight] as [SwipeDirection] {
                precondition(decoded.gestures(for: 1).doubleTapSwipe?[direction] == f.chord)
            }

            let legacy = Data(#"{"enabled":true,"swipeWindow":0.35,"swipeDistance":60}"#.utf8)
            let legacySwipe = try JSONDecoder().decode(DoubleTapSwipeSettings.self, from: legacy)
            precondition(legacySwipe.topLeft == nil && legacySwipe.topRight == nil)
            precondition(legacySwipe.bottomLeft == nil && legacySwipe.bottomRight == nil)
        }
        print("Passed legacy decode, inheritance, default-profile copy, custom override, and diagonal persistence. No real input events posted.")
    }
}
