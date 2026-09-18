import CoreGraphics
import Foundation

private final class TapActionPoster: GestureEventPosting {
    var dragging = false
    var taps: [(TapAction, RecordedShortcut?)] = []
    var dragStarts = 0

    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) {
        taps.append((action, shortcut))
    }

    func click(button: CGMouseButton, count: Int) {}
    func move(dx: Double, dy: Double) {}
    func scroll(dx: Double, dy: Double, momentum: Bool) {}
    func beginDrag() {
        dragging = true
        dragStarts += 1
    }
    func endDrag() { dragging = false }
}

@MainActor
private final class TapFixture {
    private let suite = "Rotagivan.TapActionTests.\(UUID().uuidString)"
    private let preferences: UserDefaults
    let store: SettingsStore
    let poster = TapActionPoster()
    var now = Date(timeIntervalSince1970: 1_000)
    private(set) var engine: GestureEngine!

    init(oneFinger: TapAction = .doubleLeftClick, twoFinger: TapAction = .doubleLeftClick) {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "migration.rotagivan.v1")
        store = SettingsStore(defaults: preferences)
        store.settings.defaultProfileID = 1
        store.setActiveProfile(1)
        var gestures = store.settings.gestures(for: 1)
        gestures.oneFingerTap = oneFinger
        gestures.twoFingerTap = twoFinger
        gestures.oneFingerDoubleTap = nil
        gestures.twoFingerDoubleTap = nil
        gestures.doubleTapSwipe = nil
        store.updateGestures(gestures, for: 1)
        engine = GestureEngine(store: store, poster: poster, clock: { [unowned self] in self.now })
    }

    func send(_ time: Double, points: [(Double, Double)] = []) {
        now = Date(timeIntervalSince1970: 1_000 + time)
        let contacts = points.enumerated().map {
            FingerContact(id: UInt8($0.offset), x: $0.element.0, y: $0.element.1,
                touching: true, confident: true)
        }
        engine.process(TrackpadReport(contacts: contacts, buttonDown: false,
            scanTime: UInt16(Int(time * 10_000) % 65_536)), receivedAt: 1_000 + time)
    }

    func finish() {
        engine.reset()
        preferences.removePersistentDomain(forName: suite)
    }

    func configureTriple(twoFingers: Bool, doubleAction: TapAction = .doubleLeftClick) {
        var taps = store.settings.gestures(for: 1)
        taps.gestures.doubleTapInterval = 0.05
        taps.gestures.tapMaxDuration = 0.1
        if twoFingers {
            taps.twoFingerTap = .leftClick
            taps.twoFingerDoubleTap = doubleAction
            taps.twoFingerTripleTap = .tripleLeftClick
        } else {
            taps.oneFingerTap = .leftClick
            taps.oneFingerDoubleTap = doubleAction
            taps.oneFingerTripleTap = .tripleLeftClick
        }
        store.updateGestures(taps, for: 1)
    }

    func tap(_ time: Double, twoFingers: Bool = false) {
        send(time, points: twoFingers ? [(500, 500), (520, 500)] : [(500, 500)])
        send(time + 0.01)
    }
}

@main
struct TapActionTests {
    @MainActor
    private static func check(_ body: (TapFixture) throws -> Void) rethrows {
        let fixture = TapFixture()
        defer { fixture.finish() }
        try body(fixture)
    }

    @MainActor
    static func main() throws {
        let encoded = try JSONEncoder().encode(TapAction.doubleLeftClick)
        precondition(String(decoding: encoded, as: UTF8.self) == "\"doubleLeftClick\"")
        let decoded = try JSONDecoder().decode(TapAction.self, from: encoded)
        precondition(decoded == .doubleLeftClick)
        precondition(TapAction.doubleLeftClick.title == "Double left click")
        precondition(!TapAction.doubleLeftClick.supportsTapAndHoldDrag)
        print("Double-left-click raw value, Codable round trip, title and drag capability passed.")

        var settings = StoredSettings()
        settings.additionalProfiles = [AdditionalProfile(id: 100, name: "Inherited", motion: settings.normal)]
        settings.defaultProfileID = 1
        var primary = settings.gestures(for: 1)
        primary.oneFingerTap = .doubleLeftClick
        primary.twoFingerTap = .doubleLeftClick
        settings.profileGestures = [1: primary]
        precondition(settings.effectiveGestures(for: 2).oneFingerTap == .doubleLeftClick)
        precondition(settings.effectiveGestures(for: 100).twoFingerTap == .doubleLeftClick)
        let restored = try JSONDecoder().decode(StoredSettings.self, from: JSONEncoder().encode(settings))
        precondition(restored.effectiveGestures(for: 2).oneFingerTap == .doubleLeftClick)
        precondition(restored.effectiveGestures(for: 100).twoFingerTap == .doubleLeftClick)
        print("Double-left-click profile inheritance and settings persistence passed.")

        check { fixture in
            fixture.send(0, points: [(500, 500)])
            fixture.send(0.03)
            precondition(fixture.poster.taps.count == 1)
            precondition(fixture.poster.taps[0].0 == .doubleLeftClick)
            precondition(fixture.poster.taps[0].1 == nil)

            // A configured double click must not make the next touch a
            // tap-and-hold drag candidate; only a single left click may do so.
            fixture.send(0.10, points: [(500, 500)])
            fixture.send(0.11, points: [(510, 500)])
            precondition(fixture.poster.dragStarts == 0 && !fixture.poster.dragging)
        }

        check { fixture in
            fixture.send(0, points: [(500, 500), (520, 500)])
            fixture.send(0.03)
            precondition(fixture.poster.taps.count == 1)
            precondition(fixture.poster.taps[0].0 == .doubleLeftClick)
            precondition(fixture.poster.taps[0].1 == nil)
            precondition(fixture.poster.dragStarts == 0)
        }
        print("One- and two-finger physical taps each request one double-left-click action without arming drag.")
        let ordinary = TapFixture(oneFinger: .leftClick, twoFinger: .rightClick)
        ordinary.tap(0)
        ordinary.tap(0.1)
        ordinary.tap(0.2)
        precondition(ordinary.poster.taps.map { $0.0 } == [.leftClick, .leftClick, .leftClick],
                     "Ordinary quick taps must reach native click counting even with tap-to-drag enabled")
        precondition(ordinary.poster.dragStarts == 0)
        ordinary.finish()
        for twoFingers in [false, true] {
            for swipeEnabled in [false, true] {
                check { f in
                    f.configureTriple(twoFingers: twoFingers)
                    var taps = f.store.activeGestures
                    taps.gestures.tripleTapFirstInterval = 0.15
                    taps.gestures.tripleTapSecondInterval = 0.30
                    if swipeEnabled {
                        taps.doubleTapSwipe = DoubleTapSwipeSettings(enabled: true, left: RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17"))
                    }
                    f.store.updateGestures(taps, for: 1)
                    f.tap(0, twoFingers: twoFingers)
                    f.tap(0.12, twoFingers: twoFingers)
                    f.tap(0.37, twoFingers: twoFingers)
                    precondition(f.poster.taps.map { $0.0 } == [.tripleLeftClick], "Use independently calibrated intervals, including swipe arbitration")
                }
            }
            check { f in
                f.configureTriple(twoFingers: twoFingers)
                f.tap(0, twoFingers: twoFingers); f.tap(0.02, twoFingers: twoFingers)
                precondition(f.poster.taps.isEmpty)
                f.tap(0.04, twoFingers: twoFingers)
                precondition(f.poster.taps.map { $0.0 } == [.tripleLeftClick])
                RunLoop.main.run(until: Date().addingTimeInterval(0.07))
                precondition(f.poster.taps.count == 1 && f.poster.dragStarts == 0)
            }
            for doubleAction in [TapAction.doubleLeftClick, .none] {
                check { f in
                    f.configureTriple(twoFingers: twoFingers, doubleAction: doubleAction)
                    f.tap(0, twoFingers: twoFingers); f.tap(0.02, twoFingers: twoFingers)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.07))
                    precondition(f.poster.taps.map { $0.0 } == (doubleAction == .none ? [.leftClick, .leftClick] : [.doubleLeftClick]))
                }
            }
        }
        check { f in
            f.configureTriple(twoFingers: false)
            f.tap(0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.07))
            precondition(f.poster.taps.map { $0.0 } == [.leftClick])
        }
        check { f in
            f.configureTriple(twoFingers: false)
            f.tap(0); f.tap(0.02); f.tap(0.2)
            precondition(f.poster.taps.map { $0.0 } == [.doubleLeftClick])
            RunLoop.main.run(until: Date().addingTimeInterval(0.07))
            precondition(f.poster.taps.map { $0.0 } == [.doubleLeftClick, .leftClick])
        }
        for cancelMode in 0..<4 {
            check { f in
                f.configureTriple(twoFingers: false)
                f.tap(0); f.tap(0.02)
                switch cancelMode {
                case 0: f.engine.reset()
                case 1: f.store.settings.enabled = false
                case 2: f.store.setActiveProfile(2)
                default:
                    var taps = f.store.settings.gestures(for: 1)
                    taps.oneFingerTripleTap = TapAction.none
                    f.store.updateGestures(taps, for: 1)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.07))
                precondition(f.poster.taps.isEmpty)
            }
        }
        check { f in
            f.configureTriple(twoFingers: false)
            f.tap(0)
            f.send(0.02, points: [(500, 500)])
            f.send(0.03, points: [(600, 500)])
            precondition(f.poster.dragStarts == 1 && f.poster.dragging)
            f.send(0.04)
            precondition(!f.poster.dragging && f.poster.taps.isEmpty)
        }
        check { f in
            var taps = f.store.settings.gestures(for: 1)
            taps.oneFingerTap = .tripleLeftClick
            f.store.updateGestures(taps, for: 1)
            f.tap(0)
            precondition(f.poster.taps.map { $0.0 } == [.tripleLeftClick])
        }
        primary.oneFingerTripleTap = .tripleLeftClick
        primary.twoFingerTripleTap = .shortcut
        primary.twoFingerTripleShortcut = RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return")
        settings.profileGestures = [1: primary]
        let tripleRestored = try JSONDecoder().decode(StoredSettings.self, from: JSONEncoder().encode(settings))
        precondition(tripleRestored.effectiveGestures(for: 2).oneFingerTripleTap == .tripleLeftClick)
        precondition(tripleRestored.effectiveGestures(for: 100).twoFingerTripleShortcut == primary.twoFingerTripleShortcut)
        precondition(!TapAction.tripleLeftClick.supportsTapAndHoldDrag)
        print("Triple taps passed: one/two fingers, single-tap triple click, no extra clicks, single/double fallbacks, timeout, cancellation, drag, persistence and inheritance.")
    }
}
