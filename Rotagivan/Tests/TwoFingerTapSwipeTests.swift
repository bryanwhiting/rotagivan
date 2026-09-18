import Foundation
import CoreGraphics

private final class PairPoster: GestureEventPosting {
    var dragging = false
    var taps: [(TapAction, RecordedShortcut?)] = []
    var moves = 0
    var scrolls = 0
    var drags = 0
    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) { taps.append((action, shortcut)) }
    func click(button: CGMouseButton, count: Int) {}
    func move(dx: Double, dy: Double) { if dx != 0 || dy != 0 { moves += 1 } }
    func scroll(dx: Double, dy: Double, momentum: Bool) { scrolls += 1 }
    func beginDrag() { dragging = true; drags += 1 }
    func endDrag() { dragging = false }
}

@MainActor private final class PairFixture {
    let suite = "Rotagivan.PairSwipeTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: SettingsStore
    let poster = PairPoster()
    var now = Date(timeIntervalSince1970: 1000)
    var engine: GestureEngine!
    init(single: Bool, double: Bool) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        store = SettingsStore(defaults: defaults)
        store.settings.defaultProfileID = 1
        store.setActiveProfile(1)
        store.foregroundBundleID = "com.apple.finder"
        var taps = store.settings.gestures(for: 1)
        taps.gestures.tapToClick = true
        taps.gestures.tapMaxDuration = 0.25
        taps.gestures.tapMaxMovement = 30
        taps.gestures.doubleTapInterval = 0.3
        taps.gestures.tripleTapFirstInterval = 0.3
        taps.gestures.tripleTapSecondInterval = 0.3
        taps.twoFingerTap = .enter
        taps.twoFingerDoubleTap = .rightClick
        taps.twoFingerTripleTap = TapAction.none
        taps.twoFingerSwipe = nil
        taps.twoFingerSingleTapSwipe = Self.settings(single: true, enabled: single)
        taps.twoFingerDoubleTapSwipe = Self.settings(single: false, enabled: double)
        store.updateGestures(taps, for: 1)
        engine = GestureEngine(store: store, poster: poster, clock: { [unowned self] in now })
    }
    static func settings(single: Bool, enabled: Bool) -> DoubleTapSwipeSettings {
        var result = single ? DoubleTapSwipeSettings.singleTapDefaults : DoubleTapSwipeSettings()
        result.enabled = enabled
        for (i, direction) in SwipeDirection.allCases.enumerated() {
            result[direction] = RecordedShortcut(keyCode: UInt16((single ? 18 : 40) + i), modifiers: 0, keyLabel: direction.title)
        }
        return result
    }
    func send(_ t: Double, dx: Double = 0, dy: Double = 0, count: Int = 2, replacement: Bool = false, confident: Bool = true) {
        now = Date(timeIntervalSince1970: 1000 + t)
        let contacts = (0..<count).map { i in
            FingerContact(id: UInt8(i + (replacement ? 4 : 0)), x: 500 + Double(i) * 200 + dx,
                y: 500 + dy, touching: true, confident: confident)
        }
        engine.process(TrackpadReport(contacts: contacts, buttonDown: false, scanTime: 0), receivedAt: 1000 + t)
    }
    func tap(_ t: Double) { send(t); send(t + 0.03, count: 0) }
    func finish() { engine.reset(); defaults.removePersistentDomain(forName: suite) }
}

@main struct TwoFingerTapSwipeTests {
    @MainActor private static func check(single: Bool = true, double: Bool = true, _ body: (PairFixture) throws -> Void) rethrows {
        let f = PairFixture(single: single, double: double)
        defer { f.finish() }
        try body(f)
    }
    @MainActor static func main() throws {
        let vectors: [(SwipeDirection, Double, Double)] = [
            (.up, 0, -100), (.down, 0, 100), (.left, -100, 0), (.right, 100, 0),
            (.topLeft, -100, -100), (.topRight, 100, -100), (.bottomLeft, -100, 100), (.bottomRight, 100, 100)
        ]
        for single in [false, true] {
            for (direction, dx, dy) in vectors {
                check { f in
                    f.tap(0)
                    if !single { f.tap(0.10) }
                    f.send(0.20, count: 1) // Fingers land on adjacent reports.
                    f.send(0.21)
                    f.send(0.25, dx: dx, dy: dy)
                    f.send(0.27, dx: dx, dy: dy, count: 1)
                    precondition(f.poster.taps.isEmpty, "Wait for both fingers to lift")
                    f.send(0.29, count: 0)
                    let settings = single ? f.store.activeGestures.twoFingerSingleTapSwipe! : f.store.activeGestures.twoFingerDoubleTapSwipe!
                    precondition(f.poster.taps.count == 1 && f.poster.taps[0].1 == settings[direction], "Correct two-finger direction and tap count")
                    f.send(1, count: 0)
                    precondition(f.poster.taps.count == 1 && f.poster.scrolls == 0 && f.poster.moves == 0 && f.poster.drags == 0)
                }
            }
        }
        // Each gesture also works when the other variant is disabled.
        for single in [false, true] {
            check(single: single, double: !single) { f in
                f.tap(0); if !single { f.tap(0.1) }
                f.send(0.2); f.send(0.24, dx: 100); f.send(0.27, count: 0)
                precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut)
            }
        }
        check { f in
            f.tap(0); f.send(1, count: 0)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .enter, "Lone tap fallback")
        }
        check { f in
            f.tap(0); f.tap(0.1); f.send(1, count: 0)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .rightClick, "Double tap fallback")
        }
        check(single: true, double: false) { f in
            f.tap(0); f.tap(0.1)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .rightClick)
        }
        check(single: true, double: false) { f in
            f.tap(0); f.send(0.1); f.send(0.3, count: 0)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .rightClick, "Stationary second tap uses tap duration, not quick-swipe duration")
        }
        check { f in
            f.store.foregroundBundleID = "com.google.Chrome"
            f.tap(0); f.send(0.1); f.send(0.14, dx: 100); f.send(0.17, count: 0)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].1 == f.store.activeGestures.twoFingerSingleTapSwipe!.right,
                "Tap/swipe takes precedence over plain Chrome navigation")
        }
        check { f in
            f.send(0, count: 1); f.send(0.01); f.send(0.025, count: 1); f.send(0.03, count: 0)
            f.send(0.1); f.send(0.14, dy: 100); f.send(0.17, count: 0)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .shortcut, "Staggered initial tap")
        }
        check { f in
            f.tap(0)
            f.now = Date(timeIntervalSince1970: 1001)
            RunLoop.main.run(until: Date().addingTimeInterval(0.85))
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .enter, "Idle timer releases the tap without a HID report")
        }
        check { f in
            var taps = f.store.activeGestures; taps.twoFingerTripleTap = .tripleLeftClick
            f.store.updateGestures(taps, for: 1)
            f.tap(0); f.tap(0.1); f.tap(0.2)
            precondition(f.poster.taps.count == 1 && f.poster.taps[0].0 == .tripleLeftClick, "Triple tap is not swallowed")
        }
        for scenario in 0..<7 {
            check { f in
                f.tap(0); f.send(0.10)
                switch scenario {
                case 0: f.send(0.4, dy: 100) // Too slow for quick swipe.
                case 1: f.send(0.12, dx: 100, count: 3)
                case 2: f.send(0.12, dx: 100, replacement: true)
                case 3: f.send(0.12, dx: 100, confident: false)
                case 4: f.engine.reset()
                case 5: f.store.settings.enabled = false
                default:
                    var taps = f.store.settings.gestures(for: 1)
                    taps.twoFingerSingleTapSwipe!.swipeDistance = 150
                    f.store.updateGestures(taps, for: 1)
                }
                f.send(0.45, count: 0); f.send(1, count: 0)
                precondition(f.poster.taps.isEmpty && f.poster.scrolls == 0 && f.poster.drags == 0, "Invalid sequence must cancel, not leak a tap or scroll")
            }
        }
        check { f in
            f.send(0); f.send(0.04, dy: 50); f.send(0.08, dy: 100); f.send(0.1, count: 0)
            precondition(f.poster.scrolls > 0 && f.poster.taps.isEmpty, "Ordinary two-finger scrolling remains available")
        }
        check { f in
            var opens = 0
            f.engine.onAppExplorer = { opens += 1 }
            var taps = f.store.activeGestures
            taps.twoFingerSingleTapSwipe!.setAction(.appExplorer, for: .down)
            f.store.updateGestures(taps, for: 1)
            f.tap(0); f.send(0.1); f.send(0.14, dy: 100); f.send(0.17, count: 0); f.send(1, count: 0)
            precondition(opens == 1 && f.poster.taps.isEmpty)
        }
        try check { f in
            let original = f.store.settings.gestures(for: 1)
            let inherited = f.store.settings.effectiveGestures(for: 2)
            precondition(inherited.twoFingerSingleTapSwipe == original.twoFingerSingleTapSwipe)
            precondition(inherited.twoFingerDoubleTapSwipe == original.twoFingerDoubleTapSwipe)
            let restored = try JSONDecoder().decode(ProfileGestures.self, from: JSONEncoder().encode(original))
            precondition(restored == original)
            let rule = AppGestureOverride(bundleID: "test", name: "Test", bindings: [
                AppGestureBinding(trigger: .twoSingleDown, action: .appExplorer),
                AppGestureBinding(trigger: .twoDoubleTopLeft, action: .shortcut, shortcut: original.twoFingerDoubleTapSwipe!.left)
            ])
            let overridden = rule.applying(to: original)
            precondition(overridden.twoFingerSingleTapSwipe!.action(for: .down) == .appExplorer)
            precondition(overridden.twoFingerDoubleTapSwipe!.topLeft == original.twoFingerDoubleTapSwipe!.left)
        }
        print("Two-finger tap/swipe passed: all eight directions, both tap counts, staggered contacts, tap fallbacks, cancellation, ordinary scrolling, App Explorer, overrides, inheritance and persistence.")
    }
}
