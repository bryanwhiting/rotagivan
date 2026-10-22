import Foundation
import CoreGraphics

private final class MovePoster: GestureEventPosting {
    var dragging = false
    var moves: [Double] = []
    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) {}
    func click(button: CGMouseButton, count: Int) {}
    func move(dx: Double, dy: Double) { moves.append(dx) }
    func scroll(dx: Double, dy: Double, momentum: Bool) {}
    func beginDrag() { dragging = true }
    func endDrag() { dragging = false }
}

/// The one-frame finger jump guard rejects ID reuse and palm artefacts. It must
/// be a speed limit, not a per-report distance: a Mac or hub that delivers
/// Navigator frames at 62.5 Hz sees twice the travel per frame for the same
/// flick, and must not freeze the cursor on ordinary fast motion.
@main struct CursorJumpGuardTests {
    @MainActor static func moves(jump: Double, scanDelta: UInt16, frames: Int = 1) -> Int {
        let suite = "Rota.CursorJumpGuardTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "migration.rota.v1")
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: prefs)
        store.settings.defaultProfileID = 1; store.setActiveProfile(1)
        var taps = store.activeGestures
        taps.gestures.tapMaxMovement = 0
        store.updateGestures(taps, for: 1)
        let poster = MovePoster()
        var now = Date(timeIntervalSince1970: 1_000)
        let engine = GestureEngine(store: store, poster: poster, clock: { now })
        defer { engine.reset() }
        func report(_ x: Double, _ scan: UInt16) -> TrackpadReport {
            TrackpadReport(contacts: [FingerContact(id: 0, x: x, y: 500, touching: true, confident: true)], buttonDown: false, scanTime: scan)
        }
        var scan: UInt16 = 0
        var x = 100.0
        var uptime = 1_000.0
        engine.process(report(x, scan), receivedAt: uptime)
        for _ in 0..<frames {
            scan &+= scanDelta
            x += jump
            let seconds = Double(scanDelta) * 0.0001
            uptime += seconds
            now = now.addingTimeInterval(seconds)
            engine.process(report(x, scan), receivedAt: uptime)
        }
        return poster.moves.count
    }

    @MainActor static func main() {
        precondition(abs(GestureEngine.cursorJumpLimit(interval: 0.008) - 400) < 1e-9, "125 Hz keeps the 400-unit guard")
        precondition(abs(GestureEngine.cursorJumpLimit(interval: 0.016) - 800) < 1e-9, "62.5 Hz allows twice the travel")
        precondition(abs(GestureEngine.cursorJumpLimit(interval: 0.001) - 400) < 1e-9, "Faster reporting never tightens below 400")
        precondition(abs(GestureEngine.cursorJumpLimit(interval: 0.1) - 1_200) < 1e-9, "A stalled interval is capped at 1,200 units")
        precondition(abs(GestureEngine.cursorJumpLimit(interval: 10) - 1_200) < 1e-9)
        precondition(abs(GestureEngine.cursorJumpLimit(interval: .nan) - 400) < 1e-9, "Invalid interval keeps the default guard")

        precondition(moves(jump: 300, scanDelta: 80) == 1, "Normal motion at 125 Hz moves the cursor")
        precondition(moves(jump: 500, scanDelta: 80) == 0, "A 500-unit step in 8 ms is still rejected as an ID reuse")
        precondition(moves(jump: 500, scanDelta: 160) == 1, "The same finger speed at 62.5 Hz must move the cursor")
        precondition(moves(jump: 900, scanDelta: 160) == 0, "62.5 Hz still rejects a jump that would be rejected at 125 Hz speed")
        precondition(moves(jump: 500, scanDelta: 160, frames: 5) == 5, "Sustained fast motion at 62.5 Hz is not dropped")
        print("Passed rate-aware cursor jump guard: 400 units at 125 Hz, 800 at 62.5 Hz, capped at 1,200.")
    }
}
