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
    private let suite = "Rotagivan.NativeTrackpadGestureTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    let store: SettingsStore
    let poster = NativeGesturePoster()
    var now = Date(timeIntervalSince1970: 1_000)
    private(set) var engine: GestureEngine!

    init(mode: GestureEngine.InputMode = .nativeActions) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
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
