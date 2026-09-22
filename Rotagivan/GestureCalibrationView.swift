import SwiftUI

struct TapCalibrationSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var hid: NavigatorHIDManager
    @Binding var device: GestureDevice

    private var reference: ProfileGestures { store.gestures(for: store.defaultProfileID, device: device) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("Practice with one finger. Double- and triple-tap rhythm applies to one- and two-finger taps across every layer in \(store.activeConfigurationName). Swipe practice tunes one-finger families; tune two-finger swipe families below.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    calibrate("Double tap…", mode: .doubleTap)
                    calibrate("Triple tap…", mode: .tripleTap)
                    calibrate("Tap + swipe…", mode: .singleTapSwipe)
                    calibrate("Double tap + swipe…", mode: .doubleTapSwipe)
                }
                Text(hid.canCalibrate(device: device)
                     ? "Complete 10 tries, then Apply to save the median across current and future layers."
                     : "Enable and connect the selected trackpad to capture 10 tries. You can still adjust timing below.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Timing adjustments (milliseconds)") {
                    VStack(spacing: 10) {
                        timing("Double-tap delay", key: \.doubleTapInterval, fallback: reference.gestures.resolvedDoubleTapInterval, range: 50...600)
                        timing("Triple tap · first gap", key: \.tripleTapFirstInterval, fallback: reference.gestures.resolvedTripleTapFirstInterval, range: 50...600)
                        timing("Triple tap · second gap", key: \.tripleTapSecondInterval, fallback: reference.gestures.resolvedTripleTapSecondInterval, range: 50...600)
                        Divider()
                        timing("Tap + swipe · window", key: \.singleSwipeWindow, fallback: (reference.singleTapSwipe ?? .singleTapDefaults).resolvedWindow, range: 100...800)
                        timing("Tap + swipe · duration", key: \.singleSwipeDuration, fallback: (reference.singleTapSwipe ?? .singleTapDefaults).resolvedFastDuration, range: 60...300)
                        timing("Double tap + swipe · window", key: \.doubleSwipeWindow, fallback: (reference.doubleTapSwipe ?? DoubleTapSwipeSettings()).resolvedWindow, range: 100...800)
                        Text("These learned timings cover double taps, triple taps, tap + swipe, and double tap + swipe. Two-finger swipe-family distance and timing remain independently adjustable below.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 10)
                }
            }.padding(10)
        } label: { Label("Shared timing practice", systemImage: "stopwatch") }
    }

    private func calibrate(_ title: String, mode: GestureCalibrationMode) -> some View {
        Button(title) { hid.beginCalibration(profileID: store.defaultProfileID, mode: mode, device: device) }
            .disabled(!hid.canCalibrate(device: device))
    }

    private func timing(_ title: String, key: WritableKeyPath<TapCalibrationSettings, Double?>,
                        fallback: Double, range: ClosedRange<Double>) -> some View {
        let milliseconds = Binding<Double>(get: {
            (store.tapCalibration(for: device)[keyPath: key] ?? fallback) * 1_000
        }, set: { value in
            guard value.isFinite else { return }
            var timings = store.tapCalibration(for: device)
            timings[keyPath: key] = min(range.upperBound, max(range.lowerBound, value.rounded())) / 1_000
            store.updateTapCalibration(timings, for: device)
        })
        return HStack {
            Text(title).frame(width: 205, alignment: .leading)
            Slider(value: milliseconds, in: range, step: 1).accessibilityLabel(title)
            TextField("ms", value: milliseconds, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 60).accessibilityLabel("\(title) in milliseconds")
            Text("ms").foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class GestureCalibrationSession: ObservableObject, Identifiable {
    let id = UUID()
    let profileID: UInt32
    let profileName: String
    let mode: GestureCalibrationMode
    let device: GestureDevice

    @Published private(set) var sampleCount: Int
    @Published private(set) var instruction: String
    @Published private(set) var isComplete: Bool
    @Published private(set) var cancellationReason: String?

    var samples: [GestureCalibrationSample] { recorder.samples }
    var medianDoubleTapInterval: Double? { recorder.medianDoubleTapInterval }
    var medianSwipeWindow: Double? { recorder.medianSwipeWindow }
    var medianSwipeDuration: Double? { recorder.medianSwipeDuration }
    var medianSecondTapInterval: Double? { recorder.medianSecondTapInterval }
    var combinedTripleInterval: Double? { recorder.combinedTripleInterval }

    private var recorder: GestureCalibrationRecorder

    init(profileID: UInt32, profileName: String, mode: GestureCalibrationMode, gestures: ProfileGestures, device: GestureDevice = .navigator) {
        self.profileID = profileID
        self.profileName = profileName
        self.mode = mode
        self.device = device

        let recorder = GestureCalibrationRecorder(
            mode: mode,
            tapMaxDuration: gestures.gestures.tapMaxDuration,
            tapMaxMovement: gestures.gestures.tapMaxMovement,
            swipeDistance: (mode == .singleTapSwipe ? (gestures.singleTapSwipe ?? .singleTapDefaults) : (gestures.doubleTapSwipe ?? DoubleTapSwipeSettings())).resolvedDistance
        )
        self.recorder = recorder
        sampleCount = recorder.samples.count
        instruction = recorder.instruction
        isComplete = recorder.isComplete
    }

    func process(_ report: TrackpadReport, at time: TimeInterval) {
        guard cancellationReason == nil, !isComplete else { return }
        recorder.process(report, at: time)
        publishRecorderChanges()
    }

    func tick(at time: TimeInterval) {
        guard cancellationReason == nil, !isComplete else { return }
        recorder.tick(at: time)
        publishRecorderChanges()
    }

    func cancel(reason: String) {
        guard cancellationReason != reason else { return }
        cancellationReason = reason
    }

    private func publishRecorderChanges() {
        let nextSampleCount = recorder.samples.count
        if sampleCount != nextSampleCount { sampleCount = nextSampleCount }
        if instruction != recorder.instruction { instruction = recorder.instruction }
        if isComplete != recorder.isComplete { isComplete = recorder.isComplete }
    }
}

struct GestureCalibrationView: View {
    @ObservedObject var session: GestureCalibrationSession
    let onApply: () -> Void
    let onCancel: () -> Void

    private let requiredSampleCount = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            if !session.isComplete || session.cancellationReason != nil {
                instructionCard
            }
            progress
            timings
            result
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 520, height: session.mode == .tripleTap ? 650 : session.mode != .doubleTap ? 590 : 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: [.doubleTap, .tripleTap].contains(session.mode) ? "hand.tap" : "hand.draw")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.teal)
                .frame(width: 34, height: 34)
                .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(session.device.title) · All layers in \(session.profileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusLabel
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if session.cancellationReason != nil {
            Label("Stopped", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        } else if session.isComplete {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Capturing", systemImage: "record.circle")
                .foregroundStyle(.teal)
        }
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.instruction)
                .font(.system(size: 15, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(gestureDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Use one finger on the \(session.device.title). Invalid or incomplete attempts are ignored and do not count.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.isComplete ? "Capture complete" : "Valid attempts")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(min(session.sampleCount, requiredSampleCount)) / \(requiredSampleCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(session.sampleCount, requiredSampleCount)), total: Double(requiredSampleCount))
                .tint(session.isComplete ? .green : .teal)
                .accessibilityLabel("Calibration progress")
                .accessibilityValue("\(min(session.sampleCount, requiredSampleCount)) of \(requiredSampleCount) valid attempts")
        }
    }

    private var timings: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Attempt").frame(width: 58, alignment: .leading)
                Text(session.mode == .singleTapSwipe ? "Swipe duration" : session.mode == .tripleTap ? "Tap 1 → 2" : "Tap interval").frame(maxWidth: .infinity, alignment: .trailing)
                if session.mode != .doubleTap {
                    Text(session.mode == .tripleTap ? "Tap 2 → 3" : "Swipe window").frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(session.samples.enumerated()), id: \.offset) { index, sample in
                        HStack {
                            Text("\(index + 1)").frame(width: 58, alignment: .leading)
                            Text(milliseconds(session.mode == .singleTapSwipe ? (sample.swipeDuration ?? 0) : sample.doubleTapInterval))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            if session.mode != .doubleTap {
                                Text((session.mode == .tripleTap ? sample.secondTapInterval : sample.swipeWindow).map(milliseconds) ?? "—")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 5)
                        if index < session.samples.count - 1 { Divider() }
                    }
                }
            }
            .frame(height: session.mode != .doubleTap ? 152 : 130)
            .padding(.horizontal, 10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        }
    }

    @ViewBuilder
    private var result: some View {
        if let reason = session.cancellationReason {
            VStack(alignment: .leading, spacing: 5) {
                Label(reason, systemImage: "exclamationmark.circle")
                Text("Pointer control has been restored. Cancel to close this calibration.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if session.isComplete, let tapMedian = session.medianDoubleTapInterval {
            VStack(alignment: .leading, spacing: 5) {
                Text("Median result").font(.system(size: 12, weight: .semibold))
                if session.mode == .tripleTap, let second = session.medianSecondTapInterval {
                    resultLine(label: "Tap 1 → 2", rawSeconds: tapMedian, range: 0.05...0.6)
                    resultLine(label: "Tap 2 → 3", rawSeconds: second, range: 0.05...0.6)
                    Text("Combined rhythm: \(milliseconds(session.combinedTripleInterval ?? 0)). Intervals are measured lift-to-lift, including the next tap's contact time.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if session.mode == .singleTapSwipe, let duration = session.medianSwipeDuration {
                    resultLine(label: "Quick-swipe duration", rawSeconds: duration, range: 0.06...0.3)
                } else {
                    resultLine(label: "Double-tap interval", rawSeconds: tapMedian, range: 0.05...0.6)
                }
                if let swipeMedian = session.medianSwipeWindow {
                    resultLine(label: "Swipe window", rawSeconds: swipeMedian, range: 0.1...0.8)
                }
                Text("Pointer control has been restored. Apply saves these timings across all layers in this profile for this device. Assigned actions stay unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The median is shown exactly. If slower attempts were missed, choose a larger delay after applying.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(footerGuidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Apply", action: onApply)
                .keyboardShortcut(.defaultAction)
                .disabled(!session.isComplete || session.cancellationReason != nil)
        }
    }

    private var title: String {
        switch session.mode {
        case .doubleTap: return "Calibrate double tap"
        case .tripleTap: return "Calibrate triple tap"
        case .doubleTapSwipe: return "Calibrate double tap + swipe"
        case .singleTapSwipe: return "Calibrate tap + quick swipe"
        }
    }

    private var gestureDescription: String {
        switch session.mode {
        case .doubleTap:
            return "Lift your finger, then make two distinct taps at your natural pace. Lift again before the next attempt."
        case .tripleTap:
            return "Tap three times naturally, then pause. Repeat 10 times. We learn each tap-to-tap interval separately and combine them into your triple-tap rhythm."
        case .doubleTapSwipe:
            return "Lift your finger, make two distinct taps, then place a third contact and swipe horizontally, vertically, or diagonally before lifting."
        case .singleTapSwipe:
            return "Tap once and lift. Immediately touch again, swipe in any of eight directions, and lift within 300 ms. Do not pause or hold. Repeat 10 times, pausing between attempts."
        }
    }

    @ViewBuilder
    private func resultLine(label: String, rawSeconds: Double, range: ClosedRange<Double>) -> some View {
        let rawMilliseconds = rawSeconds * 1_000
        let appliedMilliseconds = min(range.upperBound * 1_000, max(range.lowerBound * 1_000, rawMilliseconds.rounded()))
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text("\(rawMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms median")
                .monospacedDigit()
            if abs(appliedMilliseconds - rawMilliseconds) >= 0.05 {
                Text("→ \(Int(appliedMilliseconds)) ms applied")
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 12))
    }

    private func milliseconds(_ seconds: Double) -> String {
        "\(Int((seconds * 1_000).rounded())) ms"
    }

    private var footerGuidance: String {
        if session.cancellationReason != nil {
            return "Press Tab to move focus or Escape to cancel."
        }
        if session.isComplete {
            return "Press Tab to move focus, Return to apply, or Escape to cancel."
        }
        return "Pointer and gesture output are suppressed while capturing. Press Escape to cancel."
    }
}
