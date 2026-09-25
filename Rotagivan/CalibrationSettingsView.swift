import SwiftUI

struct CalibrationSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var hid: NavigatorHIDManager

    @State private var device: GestureDevice
    private var layerID: UInt32 { store.defaultProfileID }

    init(store: SettingsStore, hid: NavigatorHIDManager, initialDevice: GestureDevice = .navigator) {
        self.store = store
        self.hid = hid
        _device = State(initialValue: initialDevice)
    }

    private var separatesAppleActions: Bool {
        device == .apple && !store.settings.resolvedDevices.shareTapActions
    }

    private var needsCustomization: Bool {
        separatesAppleActions && store.settings.devices?.appleLayerGestures?[layerID] == nil
    }

    private var selectedLayerName: String {
        "Default tap layer"
    }

    private var editableGestures: ProfileGestures {
        if separatesAppleActions {
            return store.settings.devices?.appleLayerGestures?[layerID]
                ?? store.settings.effectiveGestures(for: layerID)
        }
        return store.settings.gestures(for: layerID)
    }

    private var gestureBinding: Binding<ProfileGestures> {
        Binding(get: { editableGestures }, set: { updateGestures($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Calibration")
                    .font(.system(size: 24, weight: .semibold))
                Text("Teach Rotagivan your tap rhythm, then tune recognition for every tap and tap-and-swipe family.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            scopeBar

            TapCalibrationSettingsView(store: store, hid: hid, device: $device)

            if needsCustomization {
                inheritedCard
            } else {
                tapRecognitionCard
                swipeRecognitionCard
            }
        }
        .font(.system(size: 12))
    }

    private var scopeBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CALIBRATION SCOPE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Picker("Trackpad", selection: $device) {
                    ForEach(GestureDevice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)

                Label("Default tap layer", systemImage: "hand.tap")
                    .font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
            }
            if device == .apple && store.settings.resolvedDevices.shareTapActions {
                Label("Timing is calibrated for Apple trackpads. Apple tap actions also require a close, stationary two-finger tap.",
                      systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.teal.opacity(0.18)))
    }

    private var inheritedCard: some View {
        calibrationCard("Recognition inherited", icon: "arrow.triangle.branch") {
            Text(separatesAppleActions
                 ? "\(selectedLayerName) currently uses the shared tap and swipe recognition settings on Apple trackpads."
                 : "Apple trackpads currently use the shared tap and swipe recognition settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Customize Apple tap settings") {
                enableCustomization()
            }
            Text("This uses the currently inherited values as the starting point. Action assignments remain unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tapRecognitionCard: some View {
        calibrationCard("Tap recognition", icon: "hand.tap") {
            Text("These thresholds cover single, double, and triple taps with either one or two fingers in \(selectedLayerName).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                coveragePill("1 finger · tap / double / triple", icon: "hand.point.up.left")
                coveragePill("2 fingers · tap / double / triple", icon: "hand.raised")
            }

            Divider()
            tapImpactSpeed
            Toggle("Keep cursor still while tapping", isOn: Binding(get: {
                editableGestures.gestures.resolvedKeepCursorStillForTaps
            }, set: { enabled in
                var value = editableGestures
                value.gestures.keepCursorStillForTaps = enabled
                updateGestures(value)
            }))
            TrackpadDistanceControl(
                title: "Tap movement radius",
                units: gesture(\.tapMaxMovement),
                scale: hid.distanceScale,
                range: 0...ProfileMaximum.tapMovement,
                explanation: "Maximum movement that still counts as a tap. Two-finger taps use accumulated movement."
            )
            if editableGestures.gestures.resolvedKeepCursorStillForTaps {
                Text("Movement inside this radius is treated as tap wobble and does not move the cursor. Holding past Tap impact speed starts normal tracking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var swipeRecognitionCard: some View {
        calibrationCard("Tap + swipe recognition", icon: "hand.draw") {
            Text("Tune all four gesture families here. Direction assignments stay in HUD.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LayerSwipeRecognitionEditor(gestures: gestureBinding, distanceScale: hid.distanceScale)
        }
    }

    private var tapImpactSpeed: some View {
        let milliseconds = Binding<Double>(get: {
            editableGestures.gestures.tapMaxDuration * 1_000
        }, set: { value in
            guard value.isFinite else { return }
            var profile = editableGestures
            profile.gestures.tapMaxDuration = min(1_000, max(0, value.rounded())) / 1_000
            updateGestures(profile)
        })
        return VStack(alignment: .leading, spacing: 4) {
            Text("Tap impact speed").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Slider(
                    value: milliseconds,
                    in: 0...min(1_000, max(10, store.settings.sliderBaseline(for: layerID).tapImpactSpeed * 2_000)),
                    step: 10
                )
                .accessibilityLabel("Tap impact speed in milliseconds")
                TextField("Milliseconds", value: milliseconds, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 58)
                    .accessibilityLabel("Tap impact speed in milliseconds")
                Text("ms").foregroundStyle(.secondary)
            }
            Text("Maximum finger-down time for a tap. Lower values require a quicker lift.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func calibrationCard<Content: View>(_ title: String, icon: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon)
                .font(.headline)
            Divider()
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func coveragePill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func gesture(_ key: WritableKeyPath<GestureSettings, Double>) -> Binding<Double> {
        Binding(get: { editableGestures.gestures[keyPath: key] }, set: { value in
            var profile = editableGestures
            profile.gestures[keyPath: key] = value
            updateGestures(profile)
        })
    }

    private func updateGestures(_ value: ProfileGestures) {
        if separatesAppleActions {
            store.updateAppleGestures(value, for: layerID)
        } else {
            store.updateGestures(value, for: layerID)
        }
    }

    private func enableCustomization() {
        let inherited = store.settings.effectiveGestures(for: layerID)
        store.updateAppleGestures(inherited, for: layerID)
    }
}
