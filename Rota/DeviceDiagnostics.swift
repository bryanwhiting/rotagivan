import Foundation
import AppKit
import ApplicationServices
import SwiftUI
@preconcurrency import IOKit.hid

/// Reads the Navigator directly from IOKit on its own thread for a few
/// seconds. Arrival times here are true arrival times, unlike the app path,
/// whose callback runs on the main run loop and waits behind UI work.
final class NavigatorReportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [ReportSample] = []
    private var lengths: [Int: Int] = [:]
    private var reportIDs: [UInt8: Int] = [:]
    private var unparsed = 0

    func measure(_ device: IOHIDDevice, seconds: TimeInterval) async -> DeviceDiagnosticsReport.Measurement {
        await withCheckedContinuation { continuation in
            let thread = Thread { [self] in
                var buffer = [UInt8](repeating: 0, count: 64)
                let context = Unmanaged.passUnretained(self).toOpaque()
                buffer.withUnsafeMutableBufferPointer { bytes in
                    guard let base = bytes.baseAddress else { return }
                    IOHIDDeviceRegisterInputReportCallback(device, base, bytes.count, Self.inputReport, context)
                    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
                    let deadline = Date().addingTimeInterval(seconds)
                    while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
                    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
                }
                continuation.resume(returning: self.result(duration: seconds))
            }
            thread.name = "Rota.NavigatorReportProbe"
            thread.start()
        }
    }

    private func result(duration: TimeInterval) -> DeviceDiagnosticsReport.Measurement {
        lock.lock(); defer { lock.unlock() }
        return DeviceDiagnosticsReport.Measurement(duration: duration, lengths: lengths, reportIDs: reportIDs,
            unparsed: unparsed, statistics: ReportIntervalStatistics.compute(samples))
    }

    private func record(_ report: UnsafeMutablePointer<UInt8>, length: Int, at uptime: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        lengths[length, default: 0] += 1
        if length > 0 { reportIDs[report[0], default: 0] += 1 }
        guard let parsed = TrackpadReport.parse(report, length: length) else { unparsed += 1; return }
        let down = parsed.contacts.first(where: \.touching)
        samples.append(ReportSample(uptime: uptime, scanTime: parsed.scanTime, contactID: down?.id, x: down?.x, y: down?.y))
    }

    nonisolated private static let inputReport: IOHIDReportCallback = { context, result, _, _, _, report, length in
        guard result == kIOReturnSuccess, let context else { return }
        Unmanaged<NavigatorReportProbe>.fromOpaque(context).takeUnretainedValue()
            .record(report, length: length, at: ProcessInfo.processInfo.systemUptime)
    }
}

/// Builds the device diagnostics report and writes it to the Desktop.
@MainActor
enum DeviceDiagnosticsCollector {
    nonisolated static let vendorID = 0x3297
    nonisolated static let probeDuration: TimeInterval = 3

    static var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").appendingPathComponent(DeviceDiagnosticsReport.fileName)
    }

    static func collect(store: SettingsStore, hid: NavigatorHIDManager, probe seconds: TimeInterval = probeDuration) async -> DeviceDiagnosticsReport {
        var report = DeviceDiagnosticsReport()
        report.appVersion = AppVersion.display
        report.macOS = ProcessInfo.processInfo.operatingSystemVersionString
        report.model = sysctlString("hw.model")
        report.chip = sysctlString("machdep.cpu.brand_string")
        #if arch(arm64)
        report.architecture = "arm64"
        #else
        report.architecture = sysctlInt("sysctl.proc_translated") == 1 ? "x86_64 under Rosetta" : "x86_64"
        #endif
        report.hostUptime = ProcessInfo.processInfo.systemUptime
        report.primaryDesktopHeight = Double(NSScreen.screens.first?.frame.maxY ?? 0)
        report.displays = NSScreen.screens.map { screen in
            DeviceDiagnosticsReport.Display(name: screen.localizedName, frame: rect(screen.frame),
                visibleFrame: rect(screen.visibleFrame), scale: Double(screen.backingScaleFactor),
                refreshRate: screen.maximumFramesPerSecond, isMain: screen == NSScreen.main)
        }
        report.accessibilityTrusted = AXIsProcessTrusted()
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        report.inputMonitoring = access == kIOHIDAccessTypeGranted ? "granted"
            : access == kIOHIDAccessTypeDenied ? "denied" : "not determined"
        report.competingApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, id.lowercased().contains("zsa") else { return nil }
            return (name: app.localizedName ?? id, bundleID: id)
        }
        report.driverState = driverState(hid)
        report.pointerSettings = pointerSettings(store, hid: hid)
        let probeStart = ProcessInfo.processInfo.systemUptime
        report.devices = await devices(probe: seconds)
        report.probeWindow = probeStart...ProcessInfo.processInfo.systemUptime
        report.events = InputEventRecorder.shared.recent
        return report
    }

    static func write(_ report: DeviceDiagnosticsReport) throws -> URL {
        let url = destination
        try report.render().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func rect(_ frame: CGRect) -> String {
        "(\(Int(frame.minX)), \(Int(frame.minY)), \(Int(frame.width))×\(Int(frame.height)))"
    }

    private static func driverState(_ hid: NavigatorHIDManager) -> [(String, String)] {
        let defaults = UserDefaults.standard
        func date(_ key: String) -> String {
            (defaults.object(forKey: key) as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        }
        func code(_ key: String) -> String {
            defaults.object(forKey: key) == nil ? "none" : "0x\(String(defaults.integer(forKey: key), radix: 16))"
        }
        let state: String
        switch hid.state {
        case .stopped: state = "stopped"
        case .looking: state = "looking"
        case .connected(let name): state = "connected (\(name))"
        case .error(let message): state = "error: \(message)"
        }
        return [
            ("navigator", state),
            ("last driver start", date("debug.lastHIDStart")),
            ("last device match", date("debug.lastDeviceMatch")),
            ("last device open result", code("debug.lastDeviceOpenResult")),
            ("last precision-mode (PTP) result", code("debug.lastPTPResult")),
            ("last connected", date("debug.lastConnected")),
            ("distance scale", hid.distanceScale.map { String(describing: $0) } ?? "none"),
            ("apple trackpad", "\(hid.appleTrackpadStatus) (connected: \(hid.appleTrackpadConnected), allowed on this Mac: \(hid.appleTrackpadEnabled))"),
        ]
    }

    private static func pointerSettings(_ store: SettingsStore, hid: NavigatorHIDManager) -> [(String, String)] {
        let motion = store.activeProfile
        let cursor = motion.resolvedCursorResponse
        let gestures = store.activeGestures(for: .navigator)
        let dragging = store.navigatorDragging
        let devices = store.settings.resolvedDevices
        func number(_ value: Double) -> String { String(format: "%.4g", value) }
        var lines: [(String, String)] = [
            ("enabled", "\(store.settings.enabled)"),
            ("profile", "\(store.activeConfigurationName) (layer \(store.activeProfileID))"),
            ("devices", "navigator \(devices.navigatorEnabled), apple \(devices.appleEnabled), shared tap actions \(devices.shareTapActions)"),
            ("cursor fine/fast gain", "\(number(cursor.fineGain)) / \(number(cursor.fastGain))"),
            ("cursor transition center/width", "\(number(cursor.transitionCenter)) units/s / \(number(cursor.transitionWidth))"),
            ("cursor smoothing", number(cursor.smoothing)),
            ("cursor release fine/fast/shape", "\(number(cursor.fineRelease)) / \(number(cursor.fastRelease)) / \(number(cursor.releaseShape))"),
            ("legacy cursor speed/acceleration", "\(number(motion.cursorSpeed)) / \(number(motion.cursorAcceleration))"),
        ]
        if let scroll = motion.scrollResponse {
            lines.append(("scroll response slow/fast/transition", "\(number(scroll.slowMultiplier)) / \(number(scroll.fastMultiplier)) / \(number(scroll.transitionSpeed))"))
        } else {
            lines.append(("scroll multiplier/acceleration", "\(number(motion.scrollMultiplier)) / \(number(motion.resolvedScrollAcceleration))"))
        }
        lines += [
            ("scroll invert x/y", "\(motion.invertScrollX) / \(motion.invertScrollY)"),
            ("kinetic scroll/decay", "\(motion.kineticScroll) / \(number(motion.kineticDecay))"),
            ("tap to click", "\(gestures.gestures.tapToClick), max duration \(number(gestures.gestures.tapMaxDuration)) s, max movement \(number(gestures.gestures.tapMaxMovement)) units, keep cursor still \(gestures.gestures.resolvedKeepCursorStillForTaps)"),
            ("one-finger tap", "\(gestures.oneFingerTap)"),
            ("dragging", "touch-and-hold \(dragging.touchAndHoldDrag), re-grip \(dragging.dragRegrip) (\(number(dragging.dragRegripWindow)) s)"),
        ]
        return lines
    }

    private static func devices(probe seconds: TimeInterval) async -> [DeviceDiagnosticsReport.Device] {
        guard let matching = IOServiceMatching("IOHIDDevice") else { return [] }
        (matching as NSMutableDictionary)[kIOHIDVendorIDKey] = vendorID
        var iterator: io_iterator_t = 0
        // Port 0 is kIOMasterPortDefault / kIOMainPortDefault on every macOS.
        guard IOServiceGetMatchingServices(0, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [DeviceDiagnosticsReport.Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            result.append(await describe(device, service: service, probe: seconds))
        }
        return result
    }

    private static func describe(_ device: IOHIDDevice, service: io_service_t, probe seconds: TimeInterval) async -> DeviceDiagnosticsReport.Device {
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
        func string(_ key: String) -> String { IOHIDDeviceGetProperty(device, key as CFString) as? String ?? "unknown" }
        let pairs = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []).compactMap { pair -> (page: Int, usage: Int)? in
            guard let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue,
                  let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue else { return nil }
            return (page, usage)
        }
        let descriptor = (IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data)?.count ?? 0
        let interval = IOHIDDeviceGetProperty(device, kIOHIDReportIntervalKey as CFString) as? NSNumber
        let isPTP = pairs.contains { $0.page == 0x0D && $0.usage == 0x05 } || (int(kIOHIDPrimaryUsagePageKey) == 0x0D && int(kIOHIDPrimaryUsageKey) == 0x05)
        var description = DeviceDiagnosticsReport.Device(product: string(kIOHIDProductKey),
            vendorID: int(kIOHIDVendorIDKey), productID: int(kIOHIDProductIDKey), version: int(kIOHIDVersionNumberKey),
            transport: string(kIOHIDTransportKey), locationID: int(kIOHIDLocationIDKey),
            primaryUsagePage: int(kIOHIDPrimaryUsagePageKey), primaryUsage: int(kIOHIDPrimaryUsageKey),
            usagePairs: pairs, reportDescriptorLength: descriptor,
            maxInputReportSize: int(kIOHIDMaxInputReportSizeKey), maxOutputReportSize: int(kIOHIDMaxOutputReportSizeKey),
            maxFeatureReportSize: int(kIOHIDMaxFeatureReportSizeKey), reportIntervalMicroseconds: interval?.intValue,
            registryClass: className(service), parentClass: parentClassName(service), clientClasses: clientClassNames(service),
            isPrecisionTouchpad: isPTP, openResult: "not attempted", inputMode: "not read", measurement: nil)
        guard isPTP else { return description }
        let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        description.openResult = open == kIOReturnSuccess ? "ok" : "failed 0x\(String(UInt32(bitPattern: open), radix: 16))"
        guard open == kIOReturnSuccess else { return description }
        var feature = [UInt8](repeating: 0, count: max(2, description.maxFeatureReportSize))
        var length = CFIndex(feature.count)
        let read = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 4, &feature, &length)
        if read == kIOReturnSuccess, length >= 2 {
            let mode = feature[1]
            description.inputMode = "\(mode) (\(mode == 3 ? "precision touchpad" : mode == 0 ? "mouse: PTP mode was lost" : "unexpected"))"
        } else {
            description.inputMode = "read failed 0x\(String(UInt32(bitPattern: read), radix: 16))"
        }
        description.measurement = await NavigatorReportProbe().measure(device, seconds: seconds)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        return description
    }

    private static func className(_ entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &name) == KERN_SUCCESS else { return "unknown" }
        return String(cString: name)
    }

    private static func parentClassName(_ service: io_service_t) -> String {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return "unknown" }
        defer { IOObjectRelease(parent) }
        return className(parent)
    }

    private static func clientClassNames(_ service: io_service_t) -> [String] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            names.append(className(child))
            IOObjectRelease(child)
        }
        return names
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return -1 }
        return Int(value)
    }
}

/// The Devices page entry point. One button; the report explains itself.
struct DeviceDiagnosticsButton: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var hid: NavigatorHIDManager
    @State private var running = false
    @State private var status: String?
    @State private var saved: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Device diagnostics") { run() }
                    .disabled(running)
                    .accessibilityIdentifier("device-diagnostics")
                if let saved {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        .buttonStyle(.rotaLink)
                }
            }
            Text(status ?? "Writes \(DeviceDiagnosticsReport.fileName) to the Desktop: this Mac, displays, Navigator interfaces, a 3-second report-rate probe, pointer settings and the last 200 input frames. Keep one finger moving on the Navigator while it measures. Nothing secret is included.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run() {
        running = true
        saved = nil
        status = "Measuring for \(Int(DeviceDiagnosticsCollector.probeDuration)) seconds. Move one finger on the Navigator…"
        Task { @MainActor in
            let report = await DeviceDiagnosticsCollector.collect(store: store, hid: hid)
            do {
                let url = try DeviceDiagnosticsCollector.write(report)
                saved = url
                status = "Saved to \(url.path). Copy it to the Mac that works and compare, or share it."
            } catch {
                status = "Could not write the report: \(error.localizedDescription)"
            }
            running = false
        }
    }
}
