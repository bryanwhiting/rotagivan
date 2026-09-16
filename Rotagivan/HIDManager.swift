import Foundation
@preconcurrency import IOKit.hid
import OSLog
import AppKit
import ApplicationServices

@MainActor
final class NavigatorHIDManager: ObservableObject {
    private let logger = Logger(subsystem: "local.rotagivan", category: "HID")
    enum State: Equatable {
        case stopped
        case looking
        case connected(String)
        case error(String)
    }

    @Published private(set) var state: State = .stopped
    private let store: SettingsStore
    private let gestures: GestureEngine
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 64)

    init(store: SettingsStore) {
        self.store = store
        gestures = GestureEngine(store: store)
    }

    func start() {
        guard manager == nil else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "io.zsa.navigator").isEmpty else {
            state = .error("Quit ZSA Navigator, then press Reconnect.")
            return
        }
        guard AXIsProcessTrusted() else {
            state = .error("Grant Accessibility permission, then press Reconnect.")
            return
        }
        UserDefaults.standard.set(Date(), forKey: "debug.lastHIDStart")
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x3297,
            kIOHIDProductIDKey as String: 0x1977,
            kIOHIDPrimaryUsagePageKey as String: 0x0D,
            kIOHIDPrimaryUsageKey as String: 0x05
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        state = result == kIOReturnSuccess ? .looking : .error("Could not open HID manager (\(result))")
        logger.info("HID manager open result: \(result)")
    }

    func keyboardAction(_ id: UInt32, down: Bool) {
        if !down { gestures.keyboardAction(id, down: false); return }
        guard store.settings.enabled, AXIsProcessTrusted() else { return }
        gestures.keyboardAction(id, down: true)
    }

    func stop() {
        gestures.reset()
        if let manager {
            if let device {
                var fallback: [UInt8] = [4, 0]
                _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 4, &fallback, fallback.count)
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        device = nil
        state = .stopped
    }

    private func didMatch(_ device: IOHIDDevice) {
        guard manager != nil, self.device == nil, store.settings.enabled else { return }
        UserDefaults.standard.set(Date(), forKey: "debug.lastDeviceMatch")
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        UserDefaults.standard.set(Int(openResult), forKey: "debug.lastDeviceOpenResult")
        guard openResult == kIOReturnSuccess else {
            state = .error("Could not open trackpad (\(openResult)). Check Input Monitoring permission, then Reconnect.")
            return
        }
        self.device = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        reportBuffer.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            IOHIDDeviceRegisterInputReportCallback(device, base, bytes.count, Self.inputReport, context)
        }

        var ptpMode: [UInt8] = [4, 3]
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 4, &ptpMode, ptpMode.count)
        UserDefaults.standard.set(Int(result), forKey: "debug.lastPTPResult")
        logger.info("Navigator matched; PTP mode result: \(result)")
        if result != kIOReturnSuccess {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
            state = .error("Connected, but could not enable precision reports (\(result))")
            return
        }
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "ZSA Navigator"
        UserDefaults.standard.set(Date(), forKey: "debug.lastConnected")
        state = .connected(product)
    }

    private func didRemove(_ device: IOHIDDevice) {
        guard self.device === device else { return }
        self.device = nil
        gestures.reset()
        state = .looking
    }

    private func received(_ report: UnsafeMutablePointer<UInt8>, length: Int, receivedAt: TimeInterval) {
        guard let parsed = TrackpadReport.parse(report, length: length) else { return }
        gestures.process(parsed, receivedAt: receivedAt)
    }

    nonisolated private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let owner = Unmanaged<NavigatorHIDManager>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { owner.didMatch(device) }
    }

    nonisolated private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let owner = Unmanaged<NavigatorHIDManager>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { owner.didRemove(device) }
    }

    nonisolated private static let inputReport: IOHIDReportCallback = { context, result, _, _, _, report, length in
        guard result == kIOReturnSuccess, let context else { return }
        let owner = Unmanaged<NavigatorHIDManager>.fromOpaque(context).takeUnretainedValue()
        let copy = Data(bytes: report, count: length)
        let receivedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            copy.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                owner.received(UnsafeMutablePointer(mutating: base), length: length, receivedAt: receivedAt)
            }
        }
    }
}
