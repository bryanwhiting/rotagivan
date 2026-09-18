import Foundation

@main struct TrackpadDistanceTests {
    static func axis(_ usage: UInt32 = 0x30, logicalMin: Double = 0, logicalMax: Double = 2048,
                     physicalMin: Double = 0, physicalMax: Double = 550,
                     unit: UInt32 = 0x11, exponent: UInt32 = 0xE) -> TrackpadDistanceScale.Axis {
        .init(usage: usage, logicalMin: logicalMin, logicalMax: logicalMax,
              physicalMin: physicalMin, physicalMax: physicalMax, unit: unit, unitExponent: exponent)
    }
    static func near(_ actual: Double?, _ expected: Double) {
        precondition(actual != nil && abs(actual! - expected) < 0.000000001)
    }
    static func main() {
        // Actual Navigator report 1: both contacts have 0...2048 logical units,
        // 0...550 physical units, SI centimeters with exponent -2: 55 mm.
        let scale = TrackpadDistanceScale(axes: [axis(), axis(0x31), axis(), axis(0x31)])!
        near(scale.millimeters(from: 2048), 55)
        near(scale.millimeters(from: 60), 1.611328125)
        near(scale.millimeters(from: 30), 0.8056640625)
        near(scale.millimeters(from: 0), 0)
        near(scale.units(fromMillimeters: 1), 2048 / 55)
        for units in [0.0, 4, 20, 30, 60, 97.123456, 160, 240] {
            near(scale.units(fromMillimeters: scale.millimeters(from: units)), units)
        }
        near(axis(exponent: UInt32(bitPattern: -2)).millimetersPerUnit, 55 / 2048)
        near(axis(logicalMin: 100, logicalMax: 2148, physicalMin: 10, physicalMax: 560).millimetersPerUnit, 55 / 2048)
        near(axis(logicalMax: 1000, physicalMax: 100, unit: 0x13).millimetersPerUnit, 25.4 / 1000)
        near(axis(logicalMax: 100, physicalMax: 100, exponent: 0).millimetersPerUnit, 10)
        precondition(TrackpadDistanceScale(axes: []) == nil)
        precondition(TrackpadDistanceScale(axes: [axis()]) == nil)
        precondition(TrackpadDistanceScale(axes: [axis(), axis(0x31, physicalMax: 600)]) == nil)
        precondition(TrackpadDistanceScale(axes: [axis(), axis(0x31), axis(0x31, physicalMax: 600)]) == nil)
        let x: [String: Any] = ["ReportID": 1, "UsagePage": 1, "Usage": 48, "IsRelative": false,
            "Min": 0, "Max": 2048, "ScaledMin": 0, "ScaledMax": 550, "Unit": 17, "UnitExponent": 14]
        var y = x; y["Usage"] = 49
        var mouse = x; mouse["ReportID"] = 6; mouse["Unit"] = 0; mouse["IsRelative"] = true
        precondition(TrackpadDistanceScale(hidElements: [["Elements": [x, y]], ["Elements": [x, y]], mouse]) == scale)
        var missing = y; missing.removeValue(forKey: "Unit")
        precondition(TrackpadDistanceScale(hidElements: [x, missing]) == nil)
        var relative = y; relative["IsRelative"] = true
        precondition(TrackpadDistanceScale(hidElements: [x, relative]) == nil)
        for bad in [axis(unit: 0), axis(unit: 0x14), axis(logicalMax: 0), axis(logicalMax: -1),
                    axis(physicalMax: 0), axis(physicalMax: -.infinity), axis(physicalMax: .nan),
                    axis(logicalMin: -.infinity)] {
            precondition(bad.millimetersPerUnit == nil)
            precondition(TrackpadDistanceScale(axes: [bad, axis(0x31)]) == nil)
        }
        print("Passed physical distance conversion, Navigator metadata, cm/inch units, signed exponents, exact round trips, and unknown/asymmetric metadata fallback.")
    }
}
