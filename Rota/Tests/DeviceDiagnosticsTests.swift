import Foundation

@main
struct DeviceDiagnosticsTests {
    static func close(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 1e-9) {
        precondition(abs(a - b) < tolerance, "\(message): \(a) != \(b)")
    }

    static func frame(id: UInt8 = 0, x: Double, y: Double = 500, scan: UInt16, touching: Bool = true) -> TrackpadReport {
        TrackpadReport(contacts: [FingerContact(id: id, x: x, y: y, touching: touching, confident: true)],
            buttonDown: false, scanTime: scan)
    }

    @MainActor static func main() {
        // Ring buffer keeps exactly the newest 200 frames, oldest first.
        let recorder = InputEventRecorder()
        for i in 0..<250 {
            recorder.record(frame(x: Double(i), scan: UInt16(i * 80)), from: .navigator, at: Double(i) * 0.008)
        }
        let recent = recorder.recent
        precondition(recent.count == InputEventRecorder.capacity)
        precondition(recent.first?.x == 50 && recent.last?.x == 249, "Oldest surviving frame is #50")
        precondition(zip(recent, recent.dropFirst()).allSatisfy { $0.uptime < $1.uptime }, "Ring reads in time order")
        recorder.record(frame(x: 0, scan: 0, touching: false), from: .apple(7), at: 3)
        precondition(recorder.recent.last?.source == .apple(7) && recorder.recent.last?.touching == 0)
        recorder.reset()
        precondition(recorder.recent.isEmpty)

        // Steady 125 Hz: no drops, no duplicates, scan and arrival agree.
        var steady: [ReportSample] = []
        for i in 0..<100 {
            steady.append(ReportSample(uptime: 10 + Double(i) * 0.008, scanTime: UInt16(truncatingIfNeeded: 65_000 + i * 80), contactID: 0, x: Double(i * 4), y: 100))
        }
        let healthy = ReportIntervalStatistics.compute(steady)
        precondition(healthy.reports == 100 && healthy.dropped == 0 && healthy.duplicates == 0 && healthy.pauses == 0)
        precondition(healthy.lateDeliveries == 0 && healthy.coalesced == 0)
        close(healthy.scan.median, 0.008, "Scan median survives the 16-bit rollover", tolerance: 1e-6)
        close(healthy.arrival.mean, 0.008, "Arrival mean", tolerance: 1e-6)
        close(healthy.largestJump, 4, "Largest jump")
        close(healthy.fastestJump, 500, "Finger speed uses the device clock", tolerance: 1e-6)
        precondition(healthy.jumpsOverLegacyGuard == 0)

        // One lost frame, one duplicate, one finger pause, one late burst, one ID-reuse jump.
        var trouble = steady
        trouble.append(ReportSample(uptime: trouble.last!.uptime + 0.024, scanTime: trouble.last!.scanTime &+ 240, contactID: 0, x: 400, y: 100))
        trouble.append(ReportSample(uptime: trouble.last!.uptime + 0.008, scanTime: trouble.last!.scanTime, contactID: 0, x: 400, y: 100))
        trouble.append(ReportSample(uptime: trouble.last!.uptime + 0.2, scanTime: trouble.last!.scanTime &+ 2_000, contactID: 0, x: 400, y: 100))
        // The host stalls 300 ms, then delivers the queued frames at once.
        trouble.append(ReportSample(uptime: trouble.last!.uptime + 0.3, scanTime: trouble.last!.scanTime &+ 80, contactID: 0, x: 404, y: 100))
        trouble.append(ReportSample(uptime: trouble.last!.uptime, scanTime: trouble.last!.scanTime &+ 80, contactID: 0, x: 408, y: 100))
        trouble.append(ReportSample(uptime: trouble.last!.uptime, scanTime: trouble.last!.scanTime &+ 80, contactID: 0, x: 412, y: 100))
        trouble.append(ReportSample(uptime: trouble.last!.uptime + 0.008, scanTime: trouble.last!.scanTime &+ 80, contactID: 0, x: 912, y: 100))
        let unhealthy = ReportIntervalStatistics.compute(trouble)
        precondition(unhealthy.dropped == 2, "A 24 ms scan gap at 8 ms spacing is two lost frames: \(unhealthy.dropped)")
        precondition(unhealthy.duplicates == 1, "Duplicates: \(unhealthy.duplicates)")
        precondition(unhealthy.pauses == 1, "Pauses: \(unhealthy.pauses)")
        precondition(unhealthy.lateDeliveries == 1, "Late deliveries: \(unhealthy.lateDeliveries)")
        precondition(unhealthy.coalesced == 2, "Coalesced: \(unhealthy.coalesced)")
        close(unhealthy.largestJump, 500, "ID-reuse jump")
        precondition(unhealthy.jumpsOverLegacyGuard == 1)
        close(unhealthy.scan.median, 0.008, "Median ignores the pause and the duplicate", tolerance: 1e-6)
        precondition(ReportIntervalStatistics.compute([]).reports == 0)
        precondition(ReportIntervalStatistics.compute([steady[0]]).lines.count == 1)

        // Rendering: every section is present, the event table is bounded, nothing identifying.
        var report = DeviceDiagnosticsReport()
        report.appVersion = "v1.2.3-abcd (45)"
        report.macOS = "Version 15.3 (Build 24D60)"
        report.model = "Mac14,2"
        report.chip = "Apple M2"
        report.architecture = "arm64"
        report.displays = [DeviceDiagnosticsReport.Display(name: "Built-in", frame: "(0, 0, 1470×956)", visibleFrame: "(0, 0, 1470×900)", scale: 2, refreshRate: 60, isMain: true)]
        report.competingApps = [(name: "Keymapp", bundleID: "io.zsa.keymapp")]
        report.driverState = [("navigator", "connected (ZSA Navigator)")]
        report.pointerSettings = [("cursor fine/fast gain", "0.18 / 1.15")]
        report.devices = [DeviceDiagnosticsReport.Device(product: "ZSA Navigator", vendorID: 0x3297, productID: 0x1977, version: 0x100,
            transport: "USB", locationID: 0x14200000, primaryUsagePage: 0x0D, primaryUsage: 0x05, usagePairs: [(0x0D, 0x05), (0x01, 0x02)],
            reportDescriptorLength: 321, maxInputReportSize: 16, maxOutputReportSize: 0, maxFeatureReportSize: 2,
            reportIntervalMicroseconds: 8_000, registryClass: "IOHIDDevice", parentClass: "AppleUserUSBHostHIDDevice",
            clientClasses: ["IOHIDInterface", "AppleUserHIDEventDriver"], isPrecisionTouchpad: true, openResult: "ok",
            inputMode: "3 (precision touchpad)",
            measurement: DeviceDiagnosticsReport.Measurement(duration: 3, lengths: [16: 300], reportIDs: [1: 300], unparsed: 0, statistics: healthy))]
        report.events = recent
        report.probeWindow = 0.39...1.004 // frames #50 through #125
        let text = report.render()
        for heading in ["== Mac ==", "== Displays (1) ==", "== Other ZSA software running ==", "== Navigator driver state ==",
                        "== HID interfaces for vendor 0x3297 (1) ==", "== Active pointer settings ==", "== Last 200 input events"] {
            precondition(text.contains(heading), "Missing \(heading)")
        }
        precondition(text.contains("8000 µs (125.0 Hz)") && text.contains("precision touchpad interface") && text.contains("io.zsa.keymapp"))
        precondition(text.contains("dropped (scan gap") && text.contains("navigator frames seen by the app during the probe window: 76"))
        precondition(text.split(separator: "\n").filter { $0.contains(" nav ") }.count == 200, "One table row per event")
        precondition(!text.lowercased().contains("serial"), "No serial numbers in the report")
        precondition(text.contains("Share this file as-is"))
        print("Passed recorder ring buffer, report-rate statistics (drops, duplicates, pauses, late bursts, jumps) and report rendering.")
    }
}
