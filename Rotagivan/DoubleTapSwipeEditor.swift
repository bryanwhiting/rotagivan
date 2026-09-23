import SwiftUI

struct DoubleTapSwipeEditor: View {
    @Binding var settings: DoubleTapSwipeSettings
    var singleTap = false
    var twoFingers = false
    var onCalibrate: (() -> Void)? = nil
    var canCalibrate = false
    var showTimingControls = true
    var distanceScale: TrackpadDistanceScale? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(twoFingers ? (singleTap ? "Two-finger tap, then quick swipe" : "Two-finger double-tap, then swipe") : (singleTap ? "Single tap, then quick swipe" : "Double-tap, then swipe"), isOn: $settings.enabled)
            if settings.enabled {
                if twoFingers {
                    Text(singleTap ? "With both fingers: tap → lift → quick swipe → lift. Move both fingers together. A short second tap still counts as a double tap." : "With both fingers: tap → lift → tap → lift → swipe → lift. Move both fingers together; the action fires after both lift.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                Text(singleTap ? "One finger: tap → lift → quick swipe → lift. Finish the swipe within the quick-swipe duration. Holding longer hands control to tap-and-hold dragging; no shortcut fires." : "One finger: tap → lift → tap → lift → swipe → lift. The shortcut fires when the swipe ends; the cursor stays still during the swipe.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                directionEditors("Horizontal & vertical", directions: [.left, .right, .up, .down])
                directionEditors("Diagonal directions", directions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
                if showTimingControls {
                Stepper(value: Binding(get: { settings.resolvedWindow * 1_000 }, set: {
                    settings.swipeWindow = $0 / 1_000
                }), in: 100...800, step: 25) {
                    Text("Swipe window: \(Int(settings.resolvedWindow * 1_000)) ms").monospacedDigit()
                }
                }
                TrackpadDistanceControl(title: "Swipe distance", units: $settings.swipeDistance,
                    scale: distanceScale, range: 20...240,
                    explanation: "Minimum straight-line distance from the swipe's starting point to its ending point, independent of cursor speed.")
                if singleTap && showTimingControls {
                    Stepper(value: Binding(get: { settings.resolvedFastDuration * 1_000 }, set: {
                        settings.fastSwipeDuration = $0 / 1_000
                    }), in: 60...300, step: 10) {
                        Text("Quick-swipe duration: \(Int((settings.resolvedFastDuration * 1_000).rounded())) ms").monospacedDigit()
                    }
                }
                if let onCalibrate {
                    Button(action: onCalibrate) {
                        Label(singleTap ? "Calibrate tap + swipe…" : "Calibrate double-tap + swipe…", systemImage: "stopwatch")
                    }
                    .disabled(!canCalibrate)
                    .help(canCalibrate ? "Time 10 complete gestures and apply their median timing." : "Enable and connect your trackpad to calibrate.")
                }
                Text(settings.isConfigured
                     ? (twoFingers ? "Taps wait briefly for the next touch. A qualifying swipe suppresses scrolling and the earlier tap action. Lift both fingers before starting normal scrolling again. A long hold cancels the gesture; it never starts a drag." : (singleTap ? "The first tap waits briefly for a swipe. During a qualifying second touch, the cursor stays still. A quick second tap still counts as a double tap. Holding waits for the quick-swipe duration before dragging." : "Single taps wait for double-tap recognition. Double taps then wait for this swipe window. No swipe? The usual tap action runs. Tap-and-hold on the second touch still drags as before."))
                     : "Assign a shortcut or HUD to at least one direction to activate this gesture. Your existing taps are unchanged until then.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func directionEditors(_ title: String, directions: [SwipeDirection]) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        ForEach(directions, id: \.self) { direction in
            let shortcut = Binding<RecordedShortcut?>(
                get: { settings[direction] },
                set: { settings[direction] = $0 }
            )
            TapActionEditor(title: "Swipe \(direction.title)",
                action: Binding(get: { settings.action(for: direction) }, set: {
                    settings.setAction($0, for: direction)
                }), shortcut: shortcut, shortcutsOnly: true)
        }
    }
}
