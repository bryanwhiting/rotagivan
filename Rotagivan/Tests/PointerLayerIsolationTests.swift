import Foundation
import CoreGraphics

private final class PointerIsolationPoster: GestureEventPosting {
    var dragging = false
    var movements: [Double] = []
    var scrolling: [Double] = []
    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) {}
    func click(button: CGMouseButton, count: Int) {}
    func move(dx: Double, dy: Double) { movements.append(dx); movements.append(dy) }
    func scroll(dx: Double, dy: Double, momentum: Bool) { scrolling.append(dx); scrolling.append(dy) }
    func beginDrag() { dragging = true }
    func endDrag() { dragging = false }
}

@main struct PointerLayerIsolationTests {
    @MainActor static func trace(scroll: Bool, switchLayers: Bool) -> [Double] {
        let suite = "Rotagivan.PointerIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var motion = MotionProfile.normal
        var curve = CursorResponse(legacy: motion)
        curve.fineGain = 0.15; curve.fastGain = 2; curve.transitionCenter = 800; curve.smoothing = 75
        motion.cursorResponse = curve
        motion.scrollResponse = ScrollResponse(slowMultiplier: 0.1, fastMultiplier: 2, transitionSpeed: 800)
        motion.kineticScroll = false
        store.updatePointerMotion(motion)
        // Deliberately different archived values must have no effect.
        store.settings.precision.cursorSpeed = 0
        store.settings.precision.scrollMultiplier = 0
        var taps = store.activeGestures
        taps.gestures.tapToClick = false
        taps.gestures.tapMaxMovement = 0
        taps.twoFingerSwipe = nil
        store.updateGestures(taps, for: store.defaultProfileID)
        let poster = PointerIsolationPoster()
        var now = Date(timeIntervalSince1970: 1_000)
        let engine = GestureEngine(store: store, poster: poster, clock: { now })
        defer { engine.reset() }
        var position = 500.0
        for index in 0..<80 {
            if switchLayers, index == 20 || index == 45 { store.setActiveProfile(index == 20 ? 2 : 1) }
            position += index < 20 ? 2 : index < 45 ? 18 : 5
            now = Date(timeIntervalSince1970: 1_000 + Double(index) * 0.01)
            let contacts = (0..<(scroll ? 2 : 1)).map { id in
                FingerContact(id: UInt8(id), x: 500 + Double(id) * 200 + (scroll ? 0 : position),
                              y: scroll ? position : 500, touching: true, confident: true)
            }
            engine.process(TrackpadReport(contacts: contacts, buttonDown: false, scanTime: UInt16(index * 100)),
                           receivedAt: 1_000 + Double(index) * 0.01)
        }
        return scroll ? poster.scrolling : poster.movements
    }

    @MainActor static func main() {
        for scroll in [false, true] {
            let steady = trace(scroll: scroll, switchLayers: false)
            let switching = trace(scroll: scroll, switchLayers: true)
            precondition(steady.contains { abs($0) > 0 })
            precondition(steady == switching, "Action-layer changes must not change gains or reset smoothing mid-motion")
        }
        print("Pointer isolation passed: cursor and scroll output exactly match with and without mid-touch action-layer switches; no real input posted")
    }
}
