import Foundation

/// Display-only conversion. Stored settings and gesture recognition stay in
/// logical coordinates, so changing labels never changes the user's tuning.
struct TrackpadDistanceScale: Equatable {
    struct Axis {
        let usage: UInt32
        let logicalMin: Double
        let logicalMax: Double
        let physicalMin: Double
        let physicalMax: Double
        let unit: UInt32
        let unitExponent: UInt32

        var millimetersPerUnit: Double? {
            let values = [logicalMin, logicalMax, physicalMin, physicalMax]
            guard values.allSatisfy(\.isFinite), logicalMax > logicalMin, physicalMax > physicalMin else { return nil }
            let baseMillimeters: Double
            switch unit {
            case 0x11: baseMillimeters = 10 // SI linear centimeters.
            case 0x13: baseMillimeters = 25.4 // English linear inches.
            default: return nil
            }
            // HID encodes a signed exponent in four bits (0xE means -2).
            let nibble = Int(unitExponent & 0xF)
            let exponent = nibble >= 8 ? nibble - 16 : nibble
            let scale = (physicalMax - physicalMin) * baseMillimeters * pow(10, Double(exponent)) / (logicalMax - logicalMin)
            return scale.isFinite && scale > 0 ? scale : nil
        }
    }

    let millimetersPerUnit: Double

    /// The registry descriptor is also available when an IOHIDDevice cannot
    /// vend element objects (for example, a read-only unopened device handle).
    init?(hidElements: [[String: Any]]) {
        var axes: [Axis] = []
        func visit(_ elements: [[String: Any]]) {
            for element in elements {
                if let children = element["Elements"] as? [[String: Any]] { visit(children) }
                guard (element["ReportID"] as? NSNumber)?.uint32Value == 1,
                      (element["UsagePage"] as? NSNumber)?.uint32Value == 1,
                      (element["IsRelative"] as? NSNumber)?.boolValue == false,
                      let usage = (element["Usage"] as? NSNumber)?.uint32Value,
                      usage == 0x30 || usage == 0x31,
                      let logicalMin = element["Min"] as? NSNumber,
                      let logicalMax = element["Max"] as? NSNumber,
                      let physicalMin = element["ScaledMin"] as? NSNumber,
                      let physicalMax = element["ScaledMax"] as? NSNumber,
                      let unit = element["Unit"] as? NSNumber,
                      let exponent = element["UnitExponent"] as? NSNumber else { continue }
                axes.append(Axis(usage: usage, logicalMin: Double(logicalMin.int64Value), logicalMax: Double(logicalMax.int64Value),
                    physicalMin: Double(physicalMin.int64Value), physicalMax: Double(physicalMax.int64Value),
                    unit: unit.uint32Value, unitExponent: exponent.uint32Value))
            }
        }
        visit(hidElements)
        self.init(axes: axes)
    }

    init?(axes: [Axis]) {
        let coordinates = axes.filter { $0.usage == 0x30 || $0.usage == 0x31 }
        guard coordinates.contains(where: { $0.usage == 0x30 }),
              coordinates.contains(where: { $0.usage == 0x31 }),
              let first = coordinates.first?.millimetersPerUnit else { return nil }
        // The engine uses a scalar Euclidean threshold. Anisotropic or
        // inconsistent axes cannot truthfully be labeled with one mm value.
        guard coordinates.allSatisfy({ axis in
            guard let value = axis.millimetersPerUnit else { return false }
            return abs(value - first) <= first * 0.000001
        }) else { return nil }
        millimetersPerUnit = first
    }

    func millimeters(from units: Double) -> Double { units * millimetersPerUnit }
    func units(fromMillimeters millimeters: Double) -> Double { millimeters / millimetersPerUnit }
}
