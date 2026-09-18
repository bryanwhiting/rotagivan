import SwiftUI

/// An audio-style transfer-curve editor. All paths are sampled from the exact
/// functions used by GestureEngine; the graph is never a decorative preview.
struct MotionCurveEditor: View {
    @Binding var curve: CursorResponse
    let telemetry: CursorTelemetry
    let profileID: UInt32
    var isActive: Bool
    @State private var showLivePreview = true
    @State private var showRelease = false
    @State private var fastRelease = false
    @State private var releaseDrag: Int?
    @State private var beforePreset: CursorResponse?
    private let inset: CGFloat = 12
    private let plotHeight: CGFloat = 170
    private var c: CursorResponse { curve.sanitized }

    init(curve: Binding<CursorResponse>, telemetry: CursorTelemetry, profileID: UInt32, isActive: Bool, releaseExpanded: Bool = false) {
        _curve = curve
        self.telemetry = telemetry
        self.profileID = profileID
        self.isActive = isActive
        _showRelease = State(initialValue: releaseExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Smooth response").font(.system(size: 12, weight: .semibold))
                Spacer()
                Menu {
                    Button("Constant speed (no acceleration)") {
                        var value = c
                        value.fineGain = MotionProfile.normal.cursorSpeed
                        value.fastGain = value.fineGain
                        applyPreset(value)
                    }
                    Button("Balanced") { applyPreset(.balanced) }
                    Button("Precision") {
                        var value = CursorResponse.balanced
                        value.fineGain = 0.10
                        value.fastGain = 0.95
                        value.transitionCenter = 2_200
                        value.transitionWidth = 0.9
                        applyPreset(value)
                    }
                    Button("Wide sweep") {
                        var value = CursorResponse.balanced
                        value.fineGain = 0.18
                        value.fastGain = 1.8
                        value.transitionCenter = 1_100
                        applyPreset(value)
                    }
                    if let previous = beforePreset {
                        Divider()
                        Button("Undo preset") { curve = previous; beforePreset = nil }
                    }
                } label: { Text("Presets") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack {
                Text("Sensitivity ↑ · √ scale").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Toggle("Live", isOn: $showLivePreview).toggleStyle(.switch).controlSize(.mini)
                    .font(.caption).help("Show a lightweight live marker. Turn off to pause the preview; cursor response stays the same.")
            }
            responseGraph
            HStack {
                Text("Fine · slow").foregroundStyle(.teal)
                Spacer()
                Text("Finger speed →").foregroundStyle(.secondary)
                Spacer()
                Text("Fast").foregroundStyle(.orange)
            }.font(.system(size: 10, weight: .medium))
            Text(!showLivePreview ? "Live preview paused" : isActive ? "Move your finger to see the live response" : "Activate this profile to see live motion")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 14)
            Text("LOG-NORMAL · CONTINUOUS BLEND")
                .font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(.secondary)
            parameter("Fine speed", value: endpoint(fast: false), fractionDigits: 1)
                .help("Sensitivity for very slow movement. The curved 0–100 scale gives finer adjustment at low speeds. Fine cannot exceed Fast.")
            parameter("Fast speed", value: endpoint(fast: true), fractionDigits: 1)
                .help("Sensitivity approached at high speed. Uses the same low-speed precision scale as Fine. Fast cannot fall below Fine.")
            Text("Precision scale · finer steps at low speeds")
                .font(.caption2).foregroundStyle(.secondary)
            if c.fineGain == 0 {
                Label(c.fastGain == 0 ? "Cursor movement is disabled: both speeds are zero."
                    : "Fine speed is zero. Slow movements may barely move the cursor. Raise Fine speed or lower the transition center.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            parameter("Transition center", value: center)
                .help("Where sensitivity is halfway between Fine and Fast. Higher retains fine control at higher finger speeds.")
            Text("Halfway at \(Int(c.transitionCenter.rounded())) finger units/sec")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            parameter("Transition width", value: setting(\.transitionWidth,
                minimum: CursorResponse.minimumWidth, maximum: CursorResponse.maximumWidth))
                .help("Higher spreads the transition over a wider range of finger speeds, reducing a sudden middle-speed surge.")
            Text("Center: earlier ↔ later. Width: focused ↔ gradual. The shaded band marks the middle 80% of the transition.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            parameter("Smoothing", value: setting(\.smoothing))
            Text("Smoothing reduces moment-to-moment sensitivity changes. Higher feels softer but responds more slowly.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            DisclosureGroup("Falloff after lift", isExpanded: $showRelease) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Falloff motion", selection: $fastRelease) {
                        Text("Fine").tag(false)
                        Text("Fast").tag(true)
                    }.pickerStyle(.segmented)
                    releaseGraph
                    HStack {
                        Text("Lift · 0 ms")
                        Spacer()
                        Text("Stop · 450 ms")
                    }.font(.caption2).foregroundStyle(.secondary)
                    parameter("\(fastRelease ? "Fast" : "Fine") tail", value: setting(fastRelease ? \.fastRelease : \.fineRelease, maximum: CursorResponse.maximumRelease))
                    parameter("Stop shape", value: setting(\.releaseShape))
                    Text("Drag the end to set stop time; drag the middle to bend the decay. Tail 0 stops immediately. Higher shape brakes sooner. Dragging always stops on lift.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }.font(.caption)
        }
        .frame(width: 290)

    }

    private var responseGraph: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035))
                let low = c.transitionCenter * exp(-1.2815515655 * c.transitionWidth)
                let high = c.transitionCenter * exp(1.2815515655 * c.transitionWidth)
                let left = inset + min(1, low / c.inputRange) * (size.width - 2*inset)
                let right = inset + min(1, high / c.inputRange) * (size.width - 2*inset)
                Rectangle().fill(Color.teal.opacity(0.07))
                    .frame(width: max(0, right-left), height: size.height - 2*inset)
                    .position(x: (left+right)/2, y: size.height/2)
                grid(size: size)
                Path { path in
                    let x = inset + c.transitionCenter / c.inputRange * (size.width - 2*inset)
                    path.move(to: CGPoint(x: x, y: inset))
                    path.addLine(to: CGPoint(x: x, y: size.height-inset))
                }.stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                Path { path in
                    for i in 0...160 {
                        let x = Double(i) / 160
                        let point = position(x: x, gain: c.gain(at: x * c.inputRange), size: size)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(LinearGradient(colors: [.teal, .orange], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                if isActive && showLivePreview {
                    LiveCursorOverlay(telemetry: telemetry, profileID: profileID, inputRange: c.inputRange, size: size, inset: inset)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Log-normal cursor response. Adjust fine speed, fast speed, transition center and width below.")
        }.frame(height: plotHeight)
    }

    private func position(x: Double, gain: Double, size: CGSize) -> CGPoint {
        CGPoint(x: inset + x * (size.width - 2*inset),
                y: inset + (1 - sqrt(min(1, max(0, gain / CursorResponse.maximumGain)))) * (size.height - 2*inset))
    }

    private func grid(size: CGSize) -> some View {
        Path { path in
            for i in 0...4 {
                let x = inset + Double(i) / 4 * (size.width - 2*inset)
                path.move(to: CGPoint(x: x, y: inset))
                path.addLine(to: CGPoint(x: x, y: size.height-inset))
            }
            for gain in [0.0, 0.1, 0.25, 0.5, 1.0] {
                let y = position(x: 0, gain: gain * CursorResponse.maximumGain, size: size).y
                path.move(to: CGPoint(x: inset, y: y))
                path.addLine(to: CGPoint(x: size.width-inset, y: y))
            }
        }.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
    }

    private var releaseGraph: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let duration = fastRelease ? c.fastRelease : c.fineRelease
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035))
                ForEach(0..<2) { index in
                    let time = index == 0 ? c.fineRelease : c.fastRelease
                    Path { path in
                        path.move(to: CGPoint(x: inset, y: inset))
                        for i in 0...120 {
                            let elapsed = Double(i) / 120 * CursorResponse.maximumRelease
                            path.addLine(to: releasePosition(elapsed: elapsed, level: c.releaseLevel(elapsed: elapsed, duration: time), size: size))
                        }
                    }.stroke(index == 0 ? Color.teal : Color.orange,
                             style: StrokeStyle(lineWidth: (index == 1) == fastRelease ? 2.5 : 1, dash: (index == 1) == fastRelease ? [] : [3, 3]))
                }
                ForEach(0..<2) { index in
                    let elapsed = index == 0 ? duration / 2 : duration
                    Circle().fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().stroke(fastRelease ? Color.orange : Color.teal, lineWidth: 2))
                        .frame(width: 10, height: 10)
                        .position(releasePosition(elapsed: elapsed, level: c.releaseLevel(elapsed: elapsed, duration: duration), size: size))
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    if releaseDrag == nil {
                        let middle = releasePosition(elapsed: duration / 2, level: c.releaseLevel(elapsed: duration / 2, duration: duration), size: size)
                        let end = releasePosition(elapsed: duration, level: 0, size: size)
                        releaseDrag = hypot(event.startLocation.x-middle.x, event.startLocation.y-middle.y) < hypot(event.startLocation.x-end.x, event.startLocation.y-end.y) ? 0 : 1
                    }
                    var value = c
                    if releaseDrag == 1 {
                        let seconds = min(1, max(0, (event.location.x-inset) / (size.width-2*inset))) * CursorResponse.maximumRelease
                        if fastRelease { value.fastRelease = seconds } else { value.fineRelease = seconds }
                    } else {
                        let level = min(0.5, max(1.0/32, 1 - (event.location.y-inset)/(size.height-2*inset)))
                        value.releaseShape = (log(level) / log(0.5) - 1) * 25
                    }
                    curve = value.sanitized
                }.onEnded { _ in releaseDrag = nil })
                .accessibilityLabel("Falloff envelope. Edit using the tail and stop shape controls below.")
        }.frame(height: 100)
    }

    private func releasePosition(elapsed: Double, level: Double, size: CGSize) -> CGPoint {
        CGPoint(x: inset + elapsed / CursorResponse.maximumRelease * (size.width-2*inset),
                y: inset + (1-level) * (size.height-2*inset))
    }

    private func parameter(_ title: String, value: Binding<Double>, fractionDigits: Int = 0) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).frame(width: 105, alignment: .leading)
            Slider(value: value, in: 0...100).tint(.teal).accessibilityLabel(title)
            TextField(title, value: value, format: .number.precision(.fractionLength(fractionDigits)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .monospacedDigit().frame(width: 52).accessibilityLabel(title + " value")
        }
    }

    private func endpoint(fast: Bool) -> Binding<Double> {
        Binding(get: { SettingsScale.cursorGain.percentage(for: fast ? c.fastGain : c.fineGain) }, set: { percent in
            guard percent.isFinite else { return }
            var value = c
            value.setEndpoint(fast: fast, gain: SettingsScale.cursorGain.value(for: percent))
            curve = value
        })
    }

    private var center: Binding<Double> {
        Binding(get: { c.centerPercent }, set: { percent in
            var value = c
            value.centerPercent = percent
            curve = value
        })
    }

    private func setting(_ key: WritableKeyPath<CursorResponse, Double>, minimum: Double = 0, maximum: Double = 100) -> Binding<Double> {
        Binding(get: { (c[keyPath: key] - minimum) / (maximum - minimum) * 100 }, set: { percent in
            var value = c
            value[keyPath: key] = minimum + min(100, max(0, percent)) / 100 * (maximum-minimum)
            curve = value.sanitized
        })
    }

    private func applyPreset(_ value: CursorResponse) {
        beforePreset = c
        curve = value
    }
}

/// Only this subtree refreshes for telemetry. It performs no curve sampling,
/// settings writes, or layout of the profile controls. No stale-sample queue.
private struct LiveCursorOverlay: View {
    let telemetry: CursorTelemetry
    let profileID: UInt32
    let inputRange: Double
    let size: CGSize
    let inset: CGFloat
    @State private var sample = CursorSample()
    private let ticker = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if sample.touching && sample.profileID == profileID {
                let point = CGPoint(
                    x: inset + min(1, max(0, sample.speed / inputRange)) * (size.width - 2*inset),
                    y: inset + (1 - sqrt(min(1, max(0, sample.gain / CursorResponse.maximumGain)))) * (size.height - 2*inset))
                Path { path in
                    path.move(to: CGPoint(x: point.x, y: size.height - inset))
                    path.addLine(to: point)
                }.stroke(Color.teal.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Circle().fill(Color.teal.opacity(0.2)).frame(width: 19, height: 19).position(point)
                Circle().fill(Color.teal).frame(width: 6, height: 6).position(point)
                Text("Input \(Int((sample.speed / inputRange * 100).rounded()))% · Sensitivity \(SettingsScale.cursorGain.percentage(for: sample.gain), format: .number.precision(.fractionLength(1)))")
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .frame(width: size.width, height: size.height)
        .onReceive(ticker) { _ in
            let latest = telemetry.latest
            if sample != latest { sample = latest }
        }
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}
