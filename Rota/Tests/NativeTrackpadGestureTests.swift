import CoreGraphics
import Foundation

private final class NativeGesturePoster: GestureEventPosting {
    var dragging = false
    var taps: [(TapAction, RecordedShortcut?)] = []
    var clicks = 0
    var moves = 0
    var scrolls = 0
    var dragStarts = 0
    var dragEnds = 0

    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) {
        taps.append((action, shortcut))
    }

    func click(button: CGMouseButton, count: Int) { clicks += 1 }
    func move(dx: Double, dy: Double) { moves += 1 }
    func scroll(dx: Double, dy: Double, momentum: Bool) { scrolls += 1 }
    func beginDrag() { dragging = true; dragStarts += 1 }
    func endDrag() { dragging = false; dragEnds += 1 }

    var pointerOutputCount: Int {
        clicks + moves + scrolls + dragStarts + dragEnds + taps.filter {
            [.leftClick, .doubleLeftClick, .tripleLeftClick, .rightClick].contains($0.0)
        }.count
    }
}

@MainActor
private final class NativeGestureFixture {
    private let suite = "Rota.NativeTrackpadGestureTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    let store: SettingsStore
    let poster = NativeGesturePoster()
    var now = Date(timeIntervalSince1970: 1_000)
    private(set) var engine: GestureEngine!

    init(mode: GestureEngine.InputMode = .nativeActions) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rota.v1")
        store = SettingsStore(defaults: defaults)
        store.settings.defaultProfileID = 1
        store.setActiveProfile(1)
        store.foregroundBundleID = "com.apple.finder"
        var gestures = store.settings.gestures(for: 1)
        gestures.gestures.tapToClick = true
        gestures.gestures.tapMaxDuration = 0.2
        gestures.gestures.tapMaxMovement = 25
        gestures.gestures.doubleTapInterval = 0.12
        gestures.gestures.tripleTapFirstInterval = 0.12
        gestures.gestures.tripleTapSecondInterval = 0.12
        gestures.gestures.touchAndHoldDrag = true
        gestures.oneFingerTap = .leftClick
        gestures.twoFingerTap = .rightClick
        gestures.oneFingerDoubleTap = nil
        gestures.twoFingerDoubleTap = nil
        gestures.oneFingerTripleTap = nil
        gestures.twoFingerTripleTap = nil
        gestures.doubleTapSwipe = nil
        gestures.singleTapSwipe = nil
        gestures.twoFingerSingleTapSwipe = nil
        gestures.twoFingerDoubleTapSwipe = nil
        gestures.twoFingerSwipe = nil
        store.updateGestures(gestures, for: 1)
        engine = GestureEngine(store: store, poster: poster,
            clock: { [unowned self] in self.now }, inputMode: mode)
    }

    func update(_ body: (inout ProfileGestures) -> Void) {
        var gestures = store.activeGestures
        body(&gestures)
        store.updateGestures(gestures, for: store.activeProfileID)
    }

    func send(_ time: Double, points: [(Double, Double)] = [], buttonDown: Bool = false) {
        now = Date(timeIntervalSince1970: 1_000 + time)
        let contacts = points.enumerated().map {
            FingerContact(id: UInt8($0.offset), x: $0.element.0, y: $0.element.1,
                touching: true, confident: true)
        }
        engine.process(TrackpadReport(contacts: contacts, buttonDown: buttonDown,
            scanTime: UInt16(Int(time * 10_000) % 65_536)), receivedAt: 1_000 + time)
    }

    func tap(_ time: Double, twoFingers: Bool = false) {
        send(time, points: twoFingers ? [(500, 500), (700, 500)] : [(500, 500)])
        send(time + 0.02)
    }

    /// Apple's MultitouchSupport frames give every touch its own identifier, so a
    /// tap and the swipe that follows it never share a contact id.
    func sendApple(_ time: Double, contacts: [(UInt8, Double, Double)] = []) {
        now = Date(timeIntervalSince1970: 1_000 + time)
        let fingers = contacts.map { FingerContact(id: $0.0, x: $0.1, y: $0.2, touching: true, confident: true) }
        engine.process(TrackpadReport(contacts: fingers, buttonDown: false,
            scanTime: UInt16(Int(time * 10_000) % 65_536)), receivedAt: 1_000 + time)
    }

    func enableSingleSwipe(window: Double = 0.2, duration: Double = 0.18) {
        update {
            var swipe = DoubleTapSwipeSettings.singleTapDefaults
            swipe.enabled = true
            swipe.swipeWindow = window
            swipe.fastSwipeDuration = duration
            for (index, direction) in SwipeDirection.allCases.enumerated() {
                swipe[direction] = RecordedShortcut(keyCode: UInt16(18 + index), modifiers: 0, keyLabel: direction.title)
            }
            $0.singleTapSwipe = swipe
        }
    }

    /// One finger: tap (id 7), lift, then a quick swipe with a fresh id (8).
    func appleTapSwipe(_ start: Double = 0, to point: (Double, Double) = (640, 500), tapID: UInt8 = 7, swipeID: UInt8 = 8) {
        sendApple(start, contacts: [(tapID, 500, 500)])
        sendApple(start + 0.03)
        sendApple(start + 0.10, contacts: [(swipeID, 500, 500)])
        sendApple(start + 0.12, contacts: [(swipeID, (500 + point.0) / 2, (500 + point.1) / 2)])
        sendApple(start + 0.14, contacts: [(swipeID, point.0, point.1)])
        sendApple(start + 0.20)
    }

    func wait(_ interval: TimeInterval, clockTime: Double? = nil) {
        if let clockTime { now = Date(timeIntervalSince1970: 1_000 + clockTime) }
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    func finish() {
        engine.reset()
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct NativeTrackpadGestureTests {
    private static let shortcut = RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17")

    @MainActor
    private static func check(mode: GestureEngine.InputMode = .nativeActions,
                              _ body: (NativeGestureFixture) throws -> Void) rethrows {
        let fixture = NativeGestureFixture(mode: mode)
        defer { fixture.finish() }
        try body(fixture)
    }

    @MainActor
    static func main() {
        check { f in
            f.update { $0.oneFingerTap = .enter; $0.twoFingerTap = .enter }
            f.send(0, points: [(500, 500)])
            f.send(0.01, points: [(500, 500), (600, 500), (700, 500)])
            f.send(0.02, points: [(500, 500), (600, 500)])
            f.send(0.03, points: [(500, 500)])
            f.send(0.04)
            precondition(f.poster.taps.isEmpty, "Native three-finger gestures must not become two/one-finger actions")
            f.send(0.2, points: [(500, 500)])
            f.engine.process(TrackpadReport(contacts: [FingerContact(id: 0, x: 500, y: 500,
                touching: true, confident: false)], buttonDown: false, scanTime: 0))
            f.send(0.22, points: [(500, 500)]); f.send(0.24)
            precondition(f.poster.taps.isEmpty, "An uncertain/palm contact cancels and drains the whole gesture")
            f.tap(0.5, twoFingers: true)
            precondition(f.poster.taps.count == 1 && f.poster.pointerOutputCount == 0)
        }
        check { f in
            // Taps, pointer motion, scroll, physical clicks, keyboard mouse
            // actions, drag pickup, reset, and delayed fallbacks all remain
            // entirely Apple's responsibility in native-actions mode.
            f.tap(0)
            f.send(0.10, points: [(500, 500)])
            f.send(0.12, points: [(650, 500)])
            f.send(0.14)
            f.send(0.20, points: [(500, 500), (700, 500)])
            f.send(0.22, points: [(500, 620), (700, 620)])
            f.send(0.24)
            f.send(0.30, points: [(500, 500)], buttonDown: true)
            f.send(0.32, buttonDown: true)
            f.send(0.34)
            f.engine.keyboardAction(4, down: true)
            f.engine.keyboardAction(5, down: true)
            f.engine.keyboardAction(5, down: false)
            f.tap(0.40)
            f.send(0.46, points: [(500, 500)])
            f.wait(0.15, clockTime: 0.61)
            f.engine.reset()
            f.wait(0.15, clockTime: 0.80)
            precondition(f.poster.pointerOutputCount == 0)
            precondition(f.poster.taps.isEmpty, "Native mouse bindings must not reach the event poster")
        }

        check { f in
            f.update {
                $0.oneFingerDoubleTap = .rightClick
                $0.gestures.doubleTapInterval = 0.04
            }
            f.tap(0)
            f.wait(0.08, clockTime: 0.10)
            precondition(f.poster.pointerOutputCount == 0 && f.poster.taps.isEmpty,
                         "A delayed click fallback must not escape native-actions mode")

            f.tap(0.20)
            f.engine.reset()
            f.wait(0.08, clockTime: 0.30)
            precondition(f.poster.pointerOutputCount == 0 && f.poster.taps.isEmpty,
                         "Reset must cancel delayed output without synthesizing a mouse-up")
        }

        check { f in
            f.engine.isEditingInterface = true
            f.tap(0)
            precondition(f.poster.pointerOutputCount == 0 && f.poster.taps.isEmpty,
                         "The temporary editing profile must not synthesize its left click in native mode")
        }
        print("Native pointer isolation passed for taps, movement, scrolling, buttons, drag, editing, reset, and delayed callbacks.")

        check { f in
            f.update { $0.oneFingerTap = .appExplorer; $0.twoFingerTap = .shortcut; $0.twoFingerShortcut = shortcut }
            var explorerShows = 0
            f.engine.onAppExplorer = { explorerShows += 1 }
            f.tap(0)
            precondition(explorerShows == 0 && f.poster.taps.isEmpty,
                         "A single native finger cannot open the HUD or dispatch a keyboard action")
            f.tap(0.3, twoFingers: true)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut)
        }
        for action in [TapAction.enter, .optionF19] {
            check { f in
                f.update { $0.twoFingerTap = action }
                f.tap(0, twoFingers: true)
                precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == action)
                precondition(f.poster.pointerOutputCount == 0)
            }
        }
        check { f in
            f.update { $0.twoFingerTap = .shortcut; $0.twoFingerShortcut = shortcut }
            f.send(0, points: [(500, 500)])
            f.send(0.04, points: [(500, 500), (700, 500)])
            f.send(0.06, points: [(500, 500), (700, 500)])
            f.send(0.08)
            precondition(f.poster.taps.count == 1, "A near-simultaneous, close pair qualifies")
        }
        check { f in
            f.update { $0.twoFingerTap = .shortcut; $0.twoFingerShortcut = shortcut }
            f.send(0, points: [(500, 500), (1_700, 500)])
            f.send(0.02)
            precondition(f.poster.taps.isEmpty, "Wide palm contacts cannot qualify as a close pair")
            f.send(0.3, points: [(500, 500)])
            f.send(0.39, points: [(500, 500), (700, 500)])
            f.send(0.41)
            precondition(f.poster.taps.isEmpty, "Late second-finger landing cannot qualify")
            f.send(0.44, points: [(500, 500)])
            f.now = Date(timeIntervalSince1970: 1_000.47)
            f.engine.process(TrackpadReport(contacts: [FingerContact(id: 2, x: 700, y: 500,
                touching: true, confident: true)], buttonDown: false, scanTime: 0))
            f.send(0.49)
            precondition(f.poster.taps.isEmpty, "Sequential replacement fingers cannot masquerade as a pair")
            f.send(0.6, points: [(500, 500), (700, 500)])
            f.send(0.81)
            precondition(f.poster.taps.isEmpty, "Long resting contacts cannot qualify")
            f.update { $0.gestures.tapMaxMovement = 300 }
            f.send(1.0, points: [(500, 500), (700, 500)])
            f.send(1.03, points: [(500, 500), (770, 500)])
            f.send(1.06, points: [(500, 500), (700, 500)])
            f.send(1.08)
            precondition(f.poster.taps.isEmpty, "Scroll movement returning to its start cannot become a tap")
            f.tap(1.3, twoFingers: true)
            precondition(f.poster.taps.count == 1, "A rejected contact must not poison the next close pair")
        }
        check { f in
            f.update { $0.twoFingerTap = .shortcut; $0.twoFingerShortcut = shortcut }
            f.send(0, points: [(500, 500), (700, 500)])
            f.send(0.02, points: [(500, 500)])
            f.send(0.04)
            precondition(f.poster.taps.count == 1, "A staggered lift keeps its qualified pair identity")
            f.engine.reset()
            f.send(0.2, points: [(500, 500)])
            f.send(0.22)
            precondition(f.poster.taps.count == 1, "Reset does not make a single contact a pair")
        }
        print("Native keyboard actions require a short, stationary, close two-finger pair; palms, scrolling, rests, delayed landings, and one finger are rejected.")

        check { f in
            f.update {
                $0.twoFingerTap = .leftClick
                $0.twoFingerDoubleTap = .shortcut
                $0.twoFingerDoubleShortcut = shortcut
            }
            f.tap(0, twoFingers: true)
            f.tap(0.08, twoFingers: true)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut && f.poster.taps[0].1 == shortcut,
                         "Qualified native pairs still support double-tap actions")
            precondition(f.poster.pointerOutputCount == 0)
        }
        check { f in
            f.update {
                $0.twoFingerTap = .leftClick
                $0.twoFingerDoubleTap = .rightClick
                $0.twoFingerTripleTap = .shortcut
                $0.twoFingerTripleShortcut = shortcut
            }
            f.tap(0, twoFingers: true)
            f.tap(0.06, twoFingers: true)
            f.tap(0.12, twoFingers: true)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut && f.poster.taps[0].1 == shortcut)
        }
        print("Qualified native pair double and triple actions passed without synthetic clicks.")

        check { f in
            f.update {
                $0.twoFingerTap = .shortcut
                $0.twoFingerShortcut = shortcut
            }
            f.tap(0, twoFingers: true)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut)
            precondition(f.poster.pointerOutputCount == 0)
        }

        check { f in
            f.update {
                $0.oneFingerTap = .appExplorer
                $0.twoFingerTap = .shortcut
                $0.twoFingerShortcut = shortcut
            }
            var explorerShows = 0
            f.engine.onAppExplorer = { explorerShows += 1 }
            f.send(0, points: [(500, 500), (700, 500)])
            f.send(0.02, points: [(500, 500)])
            f.send(0.04)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut && explorerShows == 0,
                         "A staggered two-finger lift must remain a pair gesture, not become a one-finger action")
            precondition(f.poster.pointerOutputCount == 0)
        }

        check { f in
            f.update {
                $0.twoFingerTap = .shortcut
                $0.twoFingerShortcut = shortcut
                $0.gestures.tapMaxMovement = 20
            }
            f.send(0, points: [(500, 500), (700, 500)])
            f.send(0.03, points: [(500, 580), (700, 580)])
            f.send(0.04, points: [(500, 580)])
            f.send(0.05)
            precondition(f.poster.taps.isEmpty, "Two-finger travel must suppress tap actions even when native scrolling is untouched")
            precondition(f.poster.pointerOutputCount == 0)
        }

        check { f in
            var navigation = DoubleTapSwipeSettings()
            navigation.enabled = true
            navigation.left = shortcut
            f.update { $0.twoFingerSwipe = navigation }
            f.send(0, points: [(500, 500), (700, 500)])
            f.send(0.04, points: [(400, 500), (600, 500)])
            f.send(0.06)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut && f.poster.taps[0].1 == shortcut)
            precondition(f.poster.pointerOutputCount == 0)
        }
        print("Native two-finger taps, movement suppression, and navigation shortcuts passed without synthetic scrolling.")

        check { f in
            f.update { $0.twoFingerTap = .appExplorer }
            var explorerShows = 0
            f.engine.onAppExplorer = { explorerShows += 1 }
            f.tap(0, twoFingers: true)
            precondition(explorerShows == 1 && f.poster.pointerOutputCount == 0 && f.poster.taps.isEmpty)
        }

        check { f in
            f.update { $0.twoFingerTap = .windowManager }
            var managerShows = 0
            f.engine.onWindowManager = { managerShows += 1 }
            f.tap(0, twoFingers: true)
            precondition(managerShows == 1 && f.poster.pointerOutputCount == 0 && f.poster.taps.isEmpty)
        }
        print("Native App Explorer and Window Manager actions stayed local and reset without mouse-up leakage.")

        // One-finger tap, then quick swipe on an Apple trackpad: the same layer
        // binding as on Navigator, using the layer's tap calibration.
        let singleSwipeDirections: [(SwipeDirection, (Double, Double))] = [
            (.left, (360, 500)), (.right, (640, 500)), (.up, (500, 360)), (.down, (500, 640)),
            (.topLeft, (400, 400)), (.topRight, (600, 400)), (.bottomLeft, (400, 600)), (.bottomRight, (600, 600)),
        ]
        for (direction, point) in singleSwipeDirections {
            check { f in
                f.enableSingleSwipe()
                f.appleTapSwipe(to: point)
                precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut,
                             "Apple one-finger tap + swipe \(direction) must dispatch its shortcut")
                precondition(f.poster.taps[0].1 == f.store.activeGestures(for: .apple).singleTapSwipe![direction])
                precondition(f.poster.pointerOutputCount == 0, "No synthetic pointer output for Apple touches")
            }
        }
        check { f in
            f.enableSingleSwipe()
            f.update { $0.singleTapSwipe!.setAction(.appExplorer, for: .down) }
            var explorerShows = 0
            f.engine.onAppExplorer = { explorerShows += 1 }
            f.sendApple(0, contacts: [(3, 500, 500)]); f.sendApple(0.03)
            f.sendApple(0.10, contacts: [(4, 500, 500)]); f.sendApple(0.14, contacts: [(4, 500, 640)])
            precondition(explorerShows == 0, "The HUD opens on lift, not mid-swipe")
            f.sendApple(0.20)
            precondition(explorerShows == 1 && f.poster.taps.isEmpty && f.poster.pointerOutputCount == 0)
            f.wait(0.3, clockTime: 0.8)
            precondition(explorerShows == 1, "No delayed tap after opening App Explorer")
        }
        check { f in
            f.enableSingleSwipe()
            f.update { $0.oneFingerTap = .appExplorer; $0.oneFingerDoubleTap = .enter; $0.oneFingerTripleTap = .optionF19 }
            var explorerShows = 0
            f.engine.onAppExplorer = { explorerShows += 1 }
            f.sendApple(0, contacts: [(1, 500, 500)]); f.sendApple(0.03)
            f.wait(0.3, clockTime: 0.6)
            precondition(explorerShows == 0 && f.poster.taps.isEmpty,
                         "A lone one-finger tap is a native click: it never fires its own tap action")
            f.sendApple(1.0, contacts: [(2, 500, 500)]); f.sendApple(1.03)
            f.sendApple(1.10, contacts: [(3, 500, 500)]); f.sendApple(1.13)
            f.sendApple(1.20, contacts: [(4, 500, 500)]); f.sendApple(1.23)
            f.wait(0.3, clockTime: 1.8)
            precondition(explorerShows == 0 && f.poster.taps.isEmpty,
                         "One-finger double/triple taps remain native clicks on an Apple trackpad")
        }
        check { f in
            f.enableSingleSwipe()
            f.sendApple(0, contacts: [(1, 500, 500)]); f.sendApple(0.02, contacts: [(1, 640, 500)]); f.sendApple(0.04)
            precondition(f.poster.taps.isEmpty, "A plain one-finger swipe without a tap stays pointer movement")
            f.sendApple(0.5, contacts: [(2, 500, 500)]); f.sendApple(0.53)
            f.wait(0.3, clockTime: 0.9)
            f.sendApple(0.9, contacts: [(3, 500, 500)]); f.sendApple(0.94, contacts: [(3, 640, 500)]); f.sendApple(1.0)
            precondition(f.poster.taps.isEmpty, "A swipe after the tap window is pointer movement")
            f.sendApple(1.5, contacts: [(4, 500, 500)]); f.sendApple(1.53)
            f.sendApple(1.60, contacts: [(5, 500, 500)]); f.sendApple(1.70, contacts: [(5, 540, 500)])
            f.sendApple(1.85, contacts: [(5, 640, 500)]); f.sendApple(1.95)
            precondition(f.poster.taps.isEmpty, "A slow drag after a tap is not a quick swipe")
            f.sendApple(2.5, contacts: [(6, 500, 500)]); f.sendApple(2.53)
            f.sendApple(2.60, contacts: [(7, 500, 500)]); f.sendApple(2.64, contacts: [(7, 520, 500)]); f.sendApple(2.70)
            precondition(f.poster.taps.isEmpty, "Travel under the swipe distance does nothing")
            f.appleTapSwipe(3.0)
            precondition(f.poster.taps.count == 1, "Rejected attempts must not poison the next tap + swipe")
            precondition(f.poster.pointerOutputCount == 0)
        }
        check { f in
            f.enableSingleSwipe()
            f.update { $0.gestures.tapMaxMovement = 25; $0.gestures.tapMaxDuration = 0.2 }
            f.sendApple(0, contacts: [(1, 500, 500)]); f.sendApple(0.02, contacts: [(1, 540, 500)]); f.sendApple(0.04)
            f.sendApple(0.10, contacts: [(2, 500, 500)]); f.sendApple(0.14, contacts: [(2, 640, 500)]); f.sendApple(0.20)
            precondition(f.poster.taps.isEmpty, "A first contact beyond the calibrated tap radius is not a tap")
            f.sendApple(1.0, contacts: [(3, 500, 500)]); f.sendApple(1.15, contacts: [(3, 500, 500)]); f.sendApple(1.30)
            f.sendApple(1.36, contacts: [(4, 500, 500)]); f.sendApple(1.40, contacts: [(4, 640, 500)]); f.sendApple(1.46)
            precondition(f.poster.taps.isEmpty, "A first contact beyond the calibrated tap duration is not a tap")
            f.update { $0.gestures.tapMaxMovement = 60; $0.gestures.tapMaxDuration = 0.35 }
            f.sendApple(2.0, contacts: [(5, 500, 500)]); f.sendApple(2.02, contacts: [(5, 540, 500)]); f.sendApple(2.25)
            f.sendApple(2.32, contacts: [(6, 500, 500)]); f.sendApple(2.36, contacts: [(6, 640, 500)]); f.sendApple(2.42)
            precondition(f.poster.taps.count == 1, "Looser Apple tap calibration accepts the same first contact")
        }
        check { f in
            f.enableSingleSwipe()
            f.update { $0.twoFingerTap = .shortcut; $0.twoFingerShortcut = shortcut }
            f.sendApple(0, contacts: [(1, 500, 500), (2, 700, 500)]); f.sendApple(0.02)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].1 == shortcut, "Two-finger taps still work")
            f.sendApple(0.5, contacts: [(3, 500, 500), (4, 700, 500)]); f.sendApple(0.52, contacts: [(3, 500, 500)]); f.sendApple(0.54)
            f.sendApple(0.60, contacts: [(5, 500, 500)]); f.sendApple(0.64, contacts: [(5, 640, 500)]); f.sendApple(0.70)
            precondition(f.poster.taps.count == 2 && f.poster.taps[1].1 == shortcut,
                         "A staggered pair lift is a pair tap, never the first half of a one-finger tap + swipe")
            f.sendApple(1.0, contacts: [(6, 500, 500)]); f.sendApple(1.03)
            f.sendApple(1.10, contacts: [(7, 500, 500), (8, 700, 500)])
            f.sendApple(1.14, contacts: [(7, 500, 620), (8, 700, 620)]); f.sendApple(1.20)
            precondition(f.poster.taps.count == 2, "Tap, then two-finger movement is native scrolling unless that gesture is bound")
            f.sendApple(2.0, contacts: [(9, 500, 500)]); f.sendApple(2.03)
            f.sendApple(2.05, contacts: [(10, 500, 500), (11, 600, 500), (12, 700, 500)]); f.sendApple(2.08)
            f.sendApple(2.12, contacts: [(13, 500, 500)]); f.sendApple(2.16, contacts: [(13, 640, 500)]); f.sendApple(2.22)
            precondition(f.poster.taps.count == 2, "A native three-finger gesture cancels the pending tap")
            precondition(f.poster.pointerOutputCount == 0)
        }
        check { f in
            // MultitouchSupport often lands a pair's fingers in different frames.
            // After a one-finger tap, such a staggered pair tap is still the
            // pair tap: the second finger ends the armed swipe without draining
            // the touch.
            f.enableSingleSwipe()
            f.update { $0.twoFingerTap = .shortcut; $0.twoFingerShortcut = shortcut }
            f.sendApple(0, contacts: [(1, 500, 500)]); f.sendApple(0.03)
            f.sendApple(0.10, contacts: [(2, 500, 500)])
            f.sendApple(0.12, contacts: [(2, 500, 500), (3, 700, 500)]); f.sendApple(0.14)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].1 == shortcut,
                         "A staggered two-finger tap after a one-finger tap is still the pair tap")
            f.sendApple(0.5, contacts: [(4, 500, 500)]); f.sendApple(0.53)
            f.sendApple(0.60, contacts: [(5, 500, 500)])
            f.sendApple(0.62, contacts: [(6, 700, 500), (5, 500, 500)]); f.sendApple(0.64)
            precondition(f.poster.taps.count == 2, "Contact order within the frame does not matter")
            f.sendApple(1.0, contacts: [(7, 500, 500)]); f.sendApple(1.03)
            f.sendApple(1.10, contacts: [(8, 500, 500)])
            f.sendApple(1.12, contacts: [(8, 500, 500), (9, 700, 500)])
            f.sendApple(1.16, contacts: [(8, 500, 620), (9, 700, 620)]); f.sendApple(1.22)
            precondition(f.poster.taps.count == 2, "Tap, then a staggered two-finger scroll is native scrolling")
            f.appleTapSwipe(1.6)
            precondition(f.poster.taps.count == 3 && f.poster.taps[2].0 == .shortcut,
                         "The next tap + swipe still dispatches")
            precondition(f.poster.pointerOutputCount == 0)
        }
        check { f in
            // A swipe that is drained until lift (here its finger is replaced
            // by a new id in one frame) must not leave a stale landing verdict
            // that rejects the next pair tap or tap + swipe.
            f.enableSingleSwipe()
            f.update { $0.twoFingerTap = .shortcut; $0.twoFingerShortcut = shortcut }
            f.sendApple(0, contacts: [(1, 500, 500)]); f.sendApple(0.03)
            f.sendApple(0.10, contacts: [(2, 500, 500)])
            f.sendApple(0.12, contacts: [(3, 560, 500)])
            f.sendApple(0.14, contacts: [(3, 640, 500)]); f.sendApple(0.20)
            precondition(f.poster.taps.isEmpty, "A replaced finger cancels the swipe")
            f.sendApple(0.55, contacts: [(4, 500, 500), (5, 700, 500)]); f.sendApple(0.57)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].1 == shortcut,
                         "A drained swipe must not poison the next pair tap")
            f.appleTapSwipe(1.0)
            precondition(f.poster.taps.count == 2 && f.poster.taps[1].0 == .shortcut,
                         "A drained swipe must not poison the next tap + swipe")
            f.sendApple(1.5, contacts: [(11, 500, 500)]); f.sendApple(1.53)
            f.sendApple(1.60, contacts: [(12, 500, 500)])
            f.store.setActiveProfile(2)
            f.sendApple(1.62, contacts: [(12, 560, 500)]); f.sendApple(1.66)
            f.store.setActiveProfile(1)
            precondition(f.poster.taps.count == 2, "A layer change drains the swipe")
            f.sendApple(2.0, contacts: [(13, 500, 500), (14, 700, 500)]); f.sendApple(2.02)
            precondition(f.poster.taps.count == 3, "A drained swipe after a layer change does not poison the next pair tap")
            precondition(f.poster.pointerOutputCount == 0)
        }
        check { f in
            var pair = DoubleTapSwipeSettings.singleTapDefaults
            pair.enabled = true
            pair.left = shortcut
            f.update { $0.oneFingerTapTwoFingerSwipe = pair }
            f.sendApple(0, contacts: [(1, 500, 500)]); f.sendApple(0.03)
            f.sendApple(0.10, contacts: [(2, 500, 500), (3, 700, 500)])
            f.sendApple(0.14, contacts: [(2, 400, 500), (3, 600, 500)]); f.sendApple(0.20)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].1 == shortcut,
                         "Apple one-finger tap, then two-finger swipe dispatches its binding")
            precondition(f.poster.pointerOutputCount == 0)
        }
        print("Apple one-finger tap + quick swipe passed: all directions, HUD, calibration, pointer movement, and two-finger isolation.")

        check(mode: .navigator) { f in
            f.tap(0)
            f.send(0.10, points: [(500, 500)])
            f.send(0.12, points: [(650, 500)])
            f.send(0.14)
            f.send(0.20, points: [(500, 500), (700, 500)])
            f.send(0.22, points: [(500, 620), (700, 620)])
            f.send(0.24)
            precondition(f.poster.taps.contains(where: { $0.0 == .leftClick }))
            precondition(f.poster.moves > 0 && f.poster.scrolls > 0,
                         "The default Navigator mode must retain click, cursor, and scroll output")
        }
        print("Navigator default-mode click, cursor, and scroll regression passed.")
    }
}
