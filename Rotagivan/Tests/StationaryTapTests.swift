import Foundation
import CoreGraphics

private final class StationaryPoster: GestureEventPosting {
    var dragging = false
    var moves: [(Double, Double)] = []
    var taps: [TapAction] = []
    var dragStarts = 0
    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) { taps.append(action) }
    func move(dx: Double, dy: Double) { if dx != 0 || dy != 0 { moves.append((dx, dy)) } }
    func click(button: CGMouseButton, count: Int) {}
    func scroll(dx: Double, dy: Double, momentum: Bool) {}
    func beginDrag() { dragging = true; dragStarts += 1 }
    func endDrag() { dragging = false }
}

@MainActor private final class StationaryFixture {
    let suite = "Rotagivan.StationaryTapTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let store: SettingsStore
    let poster = StationaryPoster()
    var now = Date(timeIntervalSince1970: 1000)
    var engine: GestureEngine!
    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "migration.rotagivan.v1")
        store = SettingsStore(defaults: preferences)
        store.settings.defaultProfileID = 1
        store.setActiveProfile(1)
        change { taps in
            taps.oneFingerTap = .leftClick
            taps.oneFingerDoubleTap = TapAction.none
            taps.doubleTapSwipe = nil
            taps.gestures.tapMaxDuration = 0.25
            taps.gestures.tapMaxMovement = 30
            taps.gestures.tapToClick = true
        }
        var motion = store.motion(for: 1)
        var curve = CursorResponse.balanced
        curve.fineGain = 1; curve.fastGain = 1; curve.smoothing = 0
        curve.fineRelease = 0.1; curve.fastRelease = 0.1
        motion.cursorResponse = curve
        store.updateMotion(motion, for: 1)
        engine = GestureEngine(store: store, poster: poster, clock: { [unowned self] in self.now })
    }
    func change(_ body: (inout ProfileGestures) -> Void) {
        var taps = store.settings.gestures(for: 1)
        body(&taps)
        store.updateGestures(taps, for: 1)
    }
    func send(_ t: Double, _ x: Double? = nil, button: Bool = false) {
        now = Date(timeIntervalSince1970: 1000 + t)
        let contacts = x.map { [FingerContact(id: 0, x: $0, y: 500, touching: true, confident: true)] } ?? []
        engine.process(TrackpadReport(contacts: contacts, buttonDown: button,
            scanTime: UInt16(Int(t * 10000) % 65536)), receivedAt: 1000 + t)
    }
    func finish() { engine.reset(); preferences.removePersistentDomain(forName: suite) }
}

@main struct StationaryTapTests {
    @MainActor private static func check(_ body: (StationaryFixture) -> Void) {
        let f = StationaryFixture(); defer { f.finish() }; body(f)
    }
    @MainActor static func main() throws {
        for action in [TapAction.leftClick, .rightClick, .doubleLeftClick, .shortcut] {
            check { f in
                f.change { $0.oneFingerTap = action }
                f.send(0, 500); f.send(0.02, 510); f.send(0.04, 495); f.send(0.06)
                precondition(f.poster.taps == [action], "Tap still dispatches at lift with no added wait")
                precondition(f.poster.moves.isEmpty && f.poster.dragStarts == 0)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                precondition(f.poster.moves.isEmpty, "No cursor glide after a protected tap")
            }
        }
        check { f in
            f.send(0, 500); f.send(0.02, 525)
            precondition(f.poster.moves.isEmpty)
            f.send(0.04, 532)
            precondition(f.poster.moves.count == 1 && abs(f.poster.moves[0].0 - 7) < 1e-9, "Do not replay withheld 25-unit wobble")
            f.send(0.06, 534)
            precondition(f.poster.moves.count == 2 && abs(f.poster.moves[1].0 - 2) < 1e-9, "After committing, small motion is unrestricted")
            f.send(0.08)
            precondition(f.poster.taps.isEmpty)
        }
        check { f in
            f.send(0, 500); f.send(0.02, 502); f.send(0.30, 504)
            precondition(f.poster.moves.count == 1 && abs(f.poster.moves[0].0 - 2) < 1e-9)
            f.send(0.32)
            precondition(f.poster.taps.isEmpty, "Holding past tap duration permits fine motion, not a tap")
        }
        for mode in 0..<3 {
            check { f in
                f.change {
                    if mode == 0 { $0.gestures.keepCursorStillForTaps = false }
                    if mode == 1 { $0.gestures.tapToClick = false }
                    if mode == 2 { $0.oneFingerTap = TapAction.none }
                }
                f.send(0, 500); f.send(0.02, 502)
                precondition(f.poster.moves.count == 1, "Opt-out, disabled taps, and no-action profiles retain immediate motion")
            }
        }
        check { f in
            f.change { $0.gestures.keepCursorStillForTaps = false }
            f.send(0, 500); f.send(0.02, 502); f.send(0.04)
            let count = f.poster.moves.count
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(f.poster.moves.count == count, "Even opt-out clicks must not coast after release")
        }
        check { f in
            f.change { $0.oneFingerDoubleTap = .doubleLeftClick }
            f.send(0, 500); f.send(0.01, 505); f.send(0.03)
            f.send(0.08, 900); f.send(0.09, 920); f.send(0.11)
            precondition(f.poster.taps == [.doubleLeftClick] && f.poster.moves.isEmpty && f.poster.dragStarts == 0,
                "A wobbly second tap must not become an accidental drag")
        }
        for held in [false, true] {
            check { f in
                f.send(0, 500); f.send(0.02, 505); f.send(0.04)
                f.send(0.1, 900); f.send(0.11, 905)
                if held {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    f.send(0.27, 907)
                } else { f.send(0.13, 940) }
                precondition(f.poster.dragStarts == 1 && f.poster.dragging && !f.poster.moves.isEmpty)
                f.send(0.3)
                precondition(!f.poster.dragging, "Drag still ends on finger lift")
            }
        }
        for physical in [false, true] {
            check { f in
                if !physical { f.engine.keyboardAction(5, down: true) }
                f.send(0, 500, button: physical); f.send(0.02, 502, button: physical)
                precondition(f.poster.moves.count == 1 && f.poster.dragging, "Explicit drag bypasses tap protection")
            }
        }
        check { f in
            f.send(0, 500); f.send(0.01, 505); f.engine.reset()
            f.change { $0.gestures.tapToClick = false }
            f.send(1, 500); f.send(1.02, 502)
            precondition(f.poster.moves.count == 1)
        }
        var settings = StoredSettings()
        precondition(settings.gestures.resolvedKeepCursorStillForTaps)
        let decoded = try JSONDecoder().decode(GestureSettings.self, from: JSONEncoder().encode(GestureSettings()))
        precondition(decoded.keepCursorStillForTaps == nil && decoded.resolvedKeepCursorStillForTaps)
        var primary = settings.gestures(for: settings.resolvedDefaultProfileID)
        primary.gestures.keepCursorStillForTaps = false
        settings.profileGestures = [settings.resolvedDefaultProfileID: primary]
        let secondary: UInt32 = settings.resolvedDefaultProfileID == 1 ? 2 : 1
        precondition(!settings.effectiveGestures(for: secondary).gestures.resolvedKeepCursorStillForTaps)
        settings.customTapProfiles = [secondary]
        precondition(settings.effectiveGestures(for: secondary).gestures.resolvedKeepCursorStillForTaps)
        print("Passed stationary tap jitter, no release glide, no buffered jump, deliberate/fine movement, double taps, drag bypass/release, opt-out, reset, and inheritance.")
    }
}
