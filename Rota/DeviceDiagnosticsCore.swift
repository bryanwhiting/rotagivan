import Foundation

/// One input frame as the HID path saw it. Deliberately small: the last 200
/// are kept in memory and summarised in the device diagnostics report.
struct InputEventRecord: Equatable {
    var uptime: TimeInterval
    var source: TrackpadInputSource
    var scanTime: UInt16
    var touching: Int
    var confident: Int
    var buttonDown: Bool
    var contactID: UInt8?
    var x: Double?
    var y: Double?

    init(_ report: TrackpadReport, from source: TrackpadInputSource, at uptime: TimeInterval) {
        self.uptime = uptime
        self.source = source
        scanTime = report.scanTime
        let down = report.contacts.filter(\.touching)
        touching = down.count
        confident = down.filter(\.confident).count
        buttonDown = report.buttonDown
        contactID = down.first?.id
        x = down.first?.x
        y = down.first?.y
    }

    var sample: ReportSample {
        ReportSample(uptime: uptime, scanTime: scanTime, contactID: contactID, x: x, y: y)
    }
}

/// Ring buffer of the most recent input frames. The HID path appends; only the
/// diagnostics report reads it. Not observable, so recording never redraws UI.
@MainActor
final class InputEventRecorder {
    static let shared = InputEventRecorder()
    static let capacity = 200
    private var ring: [InputEventRecord] = []
    private var next = 0

    func record(_ report: TrackpadReport, from source: TrackpadInputSource, at uptime: TimeInterval) {
        let record = InputEventRecord(report, from: source, at: uptime)
        if ring.count < Self.capacity {
            ring.append(record)
        } else {
            ring[next] = record
            next = (next + 1) % Self.capacity
        }
    }

    /// Oldest first.
    var recent: [InputEventRecord] {
        guard ring.count == Self.capacity else { return ring }
        return Array(ring[next...] + ring[..<next])
    }

    func reset() {
        ring.removeAll()
        next = 0
    }
}

/// The timing-relevant part of one report, shared by the live recorder and the
/// three-second probe that reads the device directly.
struct ReportSample: Equatable {
    var uptime: TimeInterval
    var scanTime: UInt16
    var contactID: UInt8?
    var x: Double?
    var y: Double?
}

struct IntervalSummary: Equatable {
    var count = 0
    var mean = 0.0
    var median = 0.0
    var minimum = 0.0
    var maximum = 0.0

    init(_ values: [Double]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        count = sorted.count
        mean = sorted.reduce(0, +) / Double(sorted.count)
        median = sorted[sorted.count / 2]
        minimum = sorted[0]
        maximum = sorted[sorted.count - 1]
    }

    var text: String {
        guard count > 0 else { return "no intervals" }
        func ms(_ value: Double) -> String { String(format: "%.2f ms", value * 1_000) }
        return "n=\(count) mean \(ms(mean)) median \(ms(median)) min \(ms(minimum)) max \(ms(maximum))"
    }
}

/// Report-rate health computed from scan times (device clock, 100 µs units)
/// and arrival times (host clock). The two disagree exactly when the host was
/// late, which is the signal that separates device problems from Mac problems.
struct ReportIntervalStatistics: Equatable {
    /// Scan-time gaps longer than this are a finger pause, not a lost report.
    static let pauseThreshold = 0.1
    /// Arriving this much later than the device spacing implies means the
    /// receiving thread was busy; a burst follows.
    static let lateThreshold = 0.05
    /// Finger travel in one frame that the gesture engine would have rejected
    /// before the jump guard became rate-aware.
    static let legacyJumpGuard = 400.0

    var reports = 0
    var span = 0.0
    var arrival = IntervalSummary([])
    var scan = IntervalSummary([])
    var dropped = 0
    var duplicates = 0
    var pauses = 0
    var lateDeliveries = 0
    var coalesced = 0
    var largestJump = 0.0
    var fastestJump = 0.0
    var jumpsOverLegacyGuard = 0

    static func compute(_ samples: [ReportSample]) -> ReportIntervalStatistics {
        var result = ReportIntervalStatistics()
        result.reports = samples.count
        guard samples.count >= 2 else { return result }
        result.span = samples.last!.uptime - samples.first!.uptime
        var arrivals: [Double] = []
        var scans: [Double] = []
        var pairs: [(arrival: Double, scan: Double)] = []
        for (previous, current) in zip(samples, samples.dropFirst()) {
            let arrival = max(0, current.uptime - previous.uptime)
            let scan = Double(current.scanTime &- previous.scanTime) * 0.0001
            arrivals.append(arrival)
            if scan == 0 { result.duplicates += 1 }
            else if scan > pauseThreshold { result.pauses += 1 }
            else { scans.append(scan) }
            pairs.append((arrival, scan))
            if let id = previous.contactID, id == current.contactID,
               let px = previous.x, let py = previous.y, let cx = current.x, let cy = current.y {
                let jump = hypot(cx - px, cy - py)
                result.largestJump = max(result.largestJump, jump)
                let interval = scan >= 0.0001 && scan <= pauseThreshold ? scan : max(0.001, arrival)
                result.fastestJump = max(result.fastestJump, jump / interval)
                if jump >= legacyJumpGuard { result.jumpsOverLegacyGuard += 1 }
            }
        }
        result.arrival = IntervalSummary(arrivals)
        result.scan = IntervalSummary(scans)
        let median = result.scan.median
        for pair in pairs where pair.scan > 0 && pair.scan <= pauseThreshold {
            if median > 0, pair.scan > median * 1.5 {
                result.dropped += max(1, Int((pair.scan / median).rounded()) - 1)
            }
            if pair.arrival - pair.scan > lateThreshold { result.lateDeliveries += 1 }
            if median > 0, pair.arrival < 0.0005, pair.scan >= median * 0.5 { result.coalesced += 1 }
        }
        return result
    }

    var lines: [String] {
        guard reports >= 2 else { return ["reports: \(reports) (not enough to measure)"] }
        return [
            "reports: \(reports) over \(String(format: "%.2f", span)) s",
            "arrival interval (host clock): \(arrival.text)",
            "scan interval (device clock): \(scan.text)",
            "dropped (scan gap ≥ 1.5× median, ≤ 100 ms): \(dropped)",
            "duplicates (same scan time): \(duplicates)",
            "finger pauses (scan gap > 100 ms): \(pauses)",
            "late deliveries (arrived > 50 ms after device spacing): \(lateDeliveries)",
            "coalesced (arrived < 0.5 ms apart although device spaced them): \(coalesced)",
            "largest one-frame finger jump: \(String(format: "%.0f", largestJump)) units"
                + " (\(jumpsOverLegacyGuard) at or over the 400-unit legacy guard)",
            "fastest finger: \(String(format: "%.0f", fastestJump)) units/s",
        ]
    }
}

/// Everything the diagnostics report prints. Plain values only, so the report
/// can be rendered and tested without IOKit, AppKit or the settings store.
struct DeviceDiagnosticsReport {
    struct Display: Equatable {
        var name: String
        var frame: String
        var visibleFrame: String
        var scale: Double
        var refreshRate: Int
        var isMain: Bool
    }

    struct Device {
        var product: String
        var vendorID: Int
        var productID: Int
        var version: Int
        var transport: String
        var locationID: Int
        var primaryUsagePage: Int
        var primaryUsage: Int
        var usagePairs: [(page: Int, usage: Int)]
        var reportDescriptorLength: Int
        var maxInputReportSize: Int
        var maxOutputReportSize: Int
        var maxFeatureReportSize: Int
        var reportIntervalMicroseconds: Int?
        var registryClass: String
        var parentClass: String
        var clientClasses: [String]
        var isPrecisionTouchpad: Bool
        var openResult: String
        var inputMode: String
        var measurement: Measurement?
    }

    struct Measurement {
        var duration: TimeInterval
        var lengths: [Int: Int]
        var reportIDs: [UInt8: Int]
        var unparsed: Int
        var statistics: ReportIntervalStatistics
    }

    var generatedAt = Date()
    var appVersion = ""
    var macOS = ""
    var model = ""
    var chip = ""
    var architecture = ""
    var hostUptime = 0.0
    var displays: [Display] = []
    var primaryDesktopHeight = 0.0
    var accessibilityTrusted = false
    var inputMonitoring = ""
    var competingApps: [(name: String, bundleID: String)] = []
    var devices: [Device] = []
    var driverState: [(String, String)] = []
    var pointerSettings: [(String, String)] = []
    var events: [InputEventRecord] = []
    var probeWindow: ClosedRange<TimeInterval>?

    static let fileName = "Rota-device-diagnostics.txt"

    func render() -> String {
        var out: [String] = []
        func section(_ title: String) { out.append(""); out.append("== \(title) =="); }
        let stamp = ISO8601DateFormatter().string(from: generatedAt)
        out.append("Rota device diagnostics \(stamp)")
        out.append("Share this file as-is. It contains no secrets: no device identifiers beyond vendor and product IDs, no keys, no typed text, and no settings beyond pointer tuning.")
        section("Mac")
        out.append("app: \(appVersion)")
        out.append("macOS: \(macOS)")
        out.append("model: \(model)")
        out.append("chip: \(chip) (\(architecture))")
        out.append("host uptime: \(String(format: "%.0f", hostUptime)) s")
        out.append("accessibility trusted: \(accessibilityTrusted)")
        out.append("input monitoring: \(inputMonitoring)")
        section("Displays (\(displays.count))")
        out.append("primary desktop height used for Quartz flip: \(String(format: "%.0f", primaryDesktopHeight))")
        for display in displays {
            out.append("- \(display.name)\(display.isMain ? " [main]" : ""): frame \(display.frame), visible \(display.visibleFrame), scale \(String(format: "%.1f", display.scale))x, \(display.refreshRate) Hz")
        }
        section("Other ZSA software running")
        if competingApps.isEmpty { out.append("none") }
        for app in competingApps { out.append("- \(app.name) (\(app.bundleID))") }
        section("Navigator driver state")
        for (key, value) in driverState { out.append("\(key): \(value)") }
        section("HID interfaces for vendor 0x3297 (\(devices.count))")
        if devices.isEmpty { out.append("none found. Check the cable, the hub and Input Monitoring.") }
        for (index, device) in devices.enumerated() {
            out.append("[\(index + 1)] \(device.product)\(device.isPrecisionTouchpad ? " — precision touchpad interface" : "")")
            out.append("    vendor 0x\(String(device.vendorID, radix: 16)) product 0x\(String(device.productID, radix: 16)) version 0x\(String(device.version, radix: 16))")
            out.append("    transport \(device.transport), location 0x\(String(device.locationID, radix: 16))")
            out.append("    primary usage page 0x\(String(device.primaryUsagePage, radix: 16)) usage 0x\(String(device.primaryUsage, radix: 16))")
            let pairs = device.usagePairs.map { "0x\(String($0.page, radix: 16)):0x\(String($0.usage, radix: 16))" }.joined(separator: " ")
            out.append("    usage pairs: \(pairs.isEmpty ? "none" : pairs)")
            out.append("    report descriptor \(device.reportDescriptorLength) bytes; max input \(device.maxInputReportSize), output \(device.maxOutputReportSize), feature \(device.maxFeatureReportSize)")
            out.append("    advertised report interval: \(device.reportIntervalMicroseconds.map { "\($0) µs (\(String(format: "%.1f", 1_000_000 / Double(max(1, $0)))) Hz)" } ?? "unknown")")
            out.append("    registry: \(device.registryClass) under \(device.parentClass); clients: \(device.clientClasses.isEmpty ? "none" : device.clientClasses.joined(separator: ", "))")
            out.append("    open: \(device.openResult); input mode feature report 4: \(device.inputMode)")
            if let measurement = device.measurement {
                out.append("    probe (\(String(format: "%.1f", measurement.duration)) s, direct from IOKit on a background thread):")
                let lengths = measurement.lengths.keys.sorted().map { "\($0)B×\(measurement.lengths[$0]!)" }.joined(separator: " ")
                let ids = measurement.reportIDs.keys.sorted().map { "id\($0)×\(measurement.reportIDs[$0]!)" }.joined(separator: " ")
                out.append("      lengths: \(lengths.isEmpty ? "none" : lengths); report ids: \(ids.isEmpty ? "none" : ids); unparsed: \(measurement.unparsed)")
                for line in measurement.statistics.lines { out.append("      \(line)") }
            }
        }
        section("Active pointer settings")
        for (key, value) in pointerSettings { out.append("\(key): \(value)") }
        section("Last \(events.count) input events (app path, main thread)")
        let navigator = events.filter { !$0.source.isApple }.map(\.sample)
        out.append("navigator frames: \(navigator.count); apple frames: \(events.count - navigator.count)")
        for line in ReportIntervalStatistics.compute(navigator).lines { out.append(line) }
        if let window = probeWindow {
            let during = navigator.filter { window.contains($0.uptime) }
            out.append("navigator frames seen by the app during the probe window: \(during.count)")
            for line in ReportIntervalStatistics.compute(during).lines { out.append("  \(line)") }
        }
        out.append("uptime        src  scan   dScan(ms) dArr(ms) n  conf btn  id  x     y")
        var previous: InputEventRecord?
        for event in events {
            let dScan = previous.map { String(format: "%8.1f", Double(event.scanTime &- $0.scanTime) * 0.1) } ?? "       -"
            let dArr = previous.map { String(format: "%8.1f", (event.uptime - $0.uptime) * 1_000) } ?? "       -"
            let source = event.source.isApple ? "apl" : "nav"
            let position = event.x.map { String(format: "%5.0f", $0) } ?? "    -"
            let positionY = event.y.map { String(format: "%5.0f", $0) } ?? "    -"
            out.append("\(String(format: "%12.3f", event.uptime)) \(source) \(String(format: "%6d", Int(event.scanTime))) \(dScan) \(dArr) \(event.touching)  \(event.confident)    \(event.buttonDown ? "1" : "0")   \(event.contactID.map { String($0) } ?? "-")  \(position) \(positionY)")
            previous = event
        }
        return out.joined(separator: "\n") + "\n"
    }
}
