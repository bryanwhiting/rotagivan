import SwiftUI

struct TrackpadDistanceControl: View {
    let title: String
    @Binding var units: Double
    let scale: TrackpadDistanceScale?
    let range: ClosedRange<Double>
    let explanation: String

    private var unitLabel: String { scale == nil ? "units" : "mm" }
    private var displayRange: ClosedRange<Double> {
        display(range.lowerBound)...display(range.upperBound)
    }
    private func display(_ units: Double) -> Double { scale?.millimeters(from: units) ?? units }
    private var value: Binding<Double> {
        Binding(get: { display(units) }, set: { displayed in
            guard displayed.isFinite else { return }
            let raw = scale?.units(fromMillimeters: displayed) ?? displayed
            guard raw.isFinite else { return }
            units = min(range.upperBound, max(range.lowerBound, raw))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(value: value, in: displayRange)
                    .accessibilityLabel("\(title) in \(unitLabel)")
                TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 55)
                    .accessibilityLabel("\(title) in \(unitLabel)")
                Text(unitLabel).foregroundStyle(.secondary).font(.caption)
            }
        }
        .help(explanation + (scale == nil
            ? " Physical scale unavailable. Connect a trackpad that reports physical dimensions to show millimeters."
            : " Millimeters on the trackpad surface, calculated from its reported physical dimensions; not screen distance."))
    }
}
