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
    @Published private(set) var distanceScale: TrackpadDistanceScale?
    @Published private(set) var calibrationSession: GestureCalibrationSession?
    private var calibrationTimer: Timer?
    private var calibrationSettings: ProfileGestures?
    private var calibrationActiveProfile: UInt32?
    private var calibrationCapturing = false
    private var contactsDown = false
    private var suppressUntilLift = false
    private var explorer: (any AppExplorerPresenting)?
    private var explorerHotkeyHeld = false
    private var explorerConfiguration: AppExplorerSettings?
    private var explorerProfileID: UInt32?
    private var explorerSettings: ProfileGestures?
    private var appObserver: NSObjectProtocol?

    var isCalibrating: Bool { calibrationCapturing }
    var canCalibrate: Bool {
        if case .connected = state { return store.settings.enabled }
        return false
    }
    private let store: SettingsStore
    private let gestures: GestureEngine
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 64)

    init(store: SettingsStore, gestures: GestureEngine? = nil, explorer: (any AppExplorerPresenting)? = nil) {
        self.store = store
        self.gestures = gestures ?? GestureEngine(store: store)
        if gestures == nil {
            foregroundAppChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.foregroundAppChanged((notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier)
                }
            }
        }
        if gestures == nil || explorer != nil {
            let explorer: any AppExplorerPresenting = explorer ?? AppExplorerController()
            self.explorer = explorer
            (explorer as? AppExplorerController)?.configuration = { [weak store] in store?.settings.appExplorer ?? AppExplorerSettings() }
            (explorer as? AppExplorerController)?.editingStore = store
            (explorer as? AppExplorerController)?.onEditingChanged = { [weak self] editing in
                guard let self else { return }
                self.gestures.isEditingInterface = editing
                self.suppressUntilLift = self.contactsDown
                if !editing {
                    self.explorerProfileID = self.store.activeProfileID
                    self.explorerSettings = self.store.activeGestures
                    self.explorerConfiguration = self.store.settings.appExplorer
                }
            }
            self.gestures.onAppExplorer = { [weak self] in self?.openAppExplorer() }
            explorer.onDismiss = { [weak self] in
                guard let self else { return }
                self.gestures.reset()
                self.suppressUntilLift = self.contactsDown
            }
            explorer.contextIsValid = { [weak self] in
                guard let self else { return false }
                if self.explorer?.isEditing == true { return self.store.settings.enabled && !self.calibrationCapturing }
                return self.store.settings.enabled && self.store.activeProfileID == self.explorerProfileID &&
                    self.store.activeGestures == self.explorerSettings && !self.calibrationCapturing &&
                    self.store.settings.appExplorer == self.explorerConfiguration
            }
        }
    }

    deinit {
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
    }

    func foregroundAppChanged(_ bundleID: String?) {
        guard store.foregroundBundleID != bundleID else { return }
        if explorer?.isEditing == true, bundleID == "local.rotagivan" {
            store.foregroundBundleID = bundleID
            return
        }
        explorer?.dismiss()
        gestures.reset()
        suppressUntilLift = contactsDown
        store.foregroundBundleID = bundleID
    }

    private func openAppExplorer() {
        guard explorer?.isEditing != true else { return }
        guard store.settings.enabled, !calibrationCapturing else { return }
        explorerProfileID = store.activeProfileID
        explorerSettings = store.activeGestures
        explorerConfiguration = store.settings.appExplorer
        explorer?.show(waitingForLift: contactsDown)
    }

    func explorerHold(_ down: Bool) {
        guard down != explorerHotkeyHeld else { return }
        explorerHotkeyHeld = down
        if down {
            guard store.settings.enabled, !calibrationCapturing else { explorerHotkeyHeld = false; return }
            explorer?.setAlternateHeld(true)
            gestures.reset()
            openAppExplorer()
        } else {
            if explorer?.isEditing != true { explorer?.dismiss() }
            explorer?.setAlternateHeld(false)
        }
    }

    func beginCalibration(profileID: UInt32, mode: GestureCalibrationMode) {
        guard canCalibrate, calibrationSession == nil,
              let profile = store.profiles.first(where: { $0.id == profileID }) else { return }
        startCalibrationSession(GestureCalibrationSession(profileID: profileID,
            profileName: profile.name, mode: mode, gestures: store.settings.gestures(for: profileID)))
    }

    // Separate from connection setup so the input gate can be tested without a physical device.
    func startCalibrationSession(_ session: GestureCalibrationSession, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        explorer?.dismiss()
        endCalibration()
        gestures.reset()
        calibrationSettings = store.settings.gestures(for: session.profileID)
        calibrationActiveProfile = store.activeProfileID
        calibrationSession = session
        calibrationCapturing = true
        if !contactsDown {
            session.process(TrackpadReport(contacts: [], buttonDown: false, scanTime: 0), at: time)
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceCalibration(at: ProcessInfo.processInfo.systemUptime)
            }
        }
        calibrationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func advanceCalibration(at time: TimeInterval) {
        guard let session = calibrationSession else { return }
        if !store.settings.enabled || store.activeProfileID != calibrationActiveProfile ||
            !store.profiles.contains(where: { $0.id == session.profileID }) ||
            store.settings.gestures(for: session.profileID) != calibrationSettings ||
            (session.profileID != store.defaultProfileID && !(store.settings.customTapProfiles ?? []).contains(session.profileID)) {
            session.cancel(reason: "The layer or its tap settings changed. Start a new calibration.")
        }
        if session.cancellationReason == nil && !session.isComplete { session.tick(at: time) }
        if session.isComplete || session.cancellationReason != nil { finishCalibrationCapture() }
    }

    private func finishCalibrationCapture() {
        guard calibrationCapturing else { return }
        calibrationCapturing = false
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        suppressUntilLift = contactsDown
        gestures.reset()
    }

    private func cancelCalibration(reason: String) {
        calibrationSession?.cancel(reason: reason)
        finishCalibrationCapture()
    }

    func endCalibration() {
        finishCalibrationCapture()
        calibrationSession = nil
        calibrationSettings = nil
        calibrationActiveProfile = nil
    }

    func applyCalibration() {
        advanceCalibration(at: ProcessInfo.processInfo.systemUptime)
        guard let session = calibrationSession, session.isComplete, session.cancellationReason == nil,
              let median = session.medianDoubleTapInterval else { return }
        var taps = store.settings.gestures(for: session.profileID)
        if session.mode == .tripleTap, let second = session.medianSecondTapInterval {
            taps.gestures.tripleTapFirstInterval = min(600, max(50, (median * 1_000).rounded())) / 1_000
            taps.gestures.tripleTapSecondInterval = min(600, max(50, (second * 1_000).rounded())) / 1_000
        } else if session.mode != .singleTapSwipe {
            taps.gestures.doubleTapInterval = min(600, max(50, (median * 1_000).rounded())) / 1_000
        }
        if session.mode == .singleTapSwipe, let window = session.medianSwipeWindow, let duration = session.medianSwipeDuration {
            var swipe = taps.singleTapSwipe ?? .singleTapDefaults
            swipe.swipeWindow = min(800, max(100, (window * 1_000).rounded())) / 1_000
            swipe.fastSwipeDuration = min(300, max(60, (duration * 1_000).rounded())) / 1_000
            taps.singleTapSwipe = swipe
        }
        if session.mode == .doubleTapSwipe, let window = session.medianSwipeWindow {
            var swipe = taps.doubleTapSwipe ?? DoubleTapSwipeSettings()
            swipe.swipeWindow = min(800, max(100, (window * 1_000).rounded())) / 1_000
            taps.doubleTapSwipe = swipe
        }
        let profileID = session.profileID
        endCalibration()
        store.updateGestures(taps, for: profileID)
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
        if explorer?.isVisible == true { return }
        guard !calibrationCapturing, !suppressUntilLift else { return }
        if !down { gestures.keyboardAction(id, down: false); return }
        guard store.settings.enabled, AXIsProcessTrusted() else { return }
        gestures.keyboardAction(id, down: true)
    }

    func stop() {
        explorer?.dismiss()
        distanceScale = nil
        cancelCalibration(reason: "The trackpad was disconnected or disabled. Reconnect and start again.")
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
        distanceScale = Self.readDistanceScale(from: device)
        UserDefaults.standard.set(Date(), forKey: "debug.lastConnected")
        state = .connected(product)
    }

    private func didRemove(_ device: IOHIDDevice) {
        guard self.device === device else { return }
        explorer?.dismiss()
        distanceScale = nil
        cancelCalibration(reason: "The trackpad disconnected. Reconnect and start again.")
        self.device = nil
        gestures.reset()
        state = .looking
    }

    static func readDistanceScale(from device: IOHIDDevice) -> TrackpadDistanceScale? {
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        let axes = elements.filter {
            IOHIDElementGetReportID($0) == 1 && IOHIDElementGetUsagePage($0) == 1 &&
                !IOHIDElementIsRelative($0) && [UInt32(0x30), 0x31].contains(IOHIDElementGetUsage($0))
        }.map { element in
            TrackpadDistanceScale.Axis(usage: IOHIDElementGetUsage(element),
                logicalMin: Double(IOHIDElementGetLogicalMin(element)), logicalMax: Double(IOHIDElementGetLogicalMax(element)),
                physicalMin: Double(IOHIDElementGetPhysicalMin(element)), physicalMax: Double(IOHIDElementGetPhysicalMax(element)),
                unit: IOHIDElementGetUnit(element), unitExponent: IOHIDElementGetUnitExponent(element))
        }
        if let scale = TrackpadDistanceScale(axes: axes) { return scale }
        // Do not substitute a registry scale for conflicting live elements.
        guard axes.isEmpty else { return nil }
        let service = IOHIDDeviceGetService(device)
        // Elements are dynamically serialized with the whole property table;
        // fetching the single "Elements" key may return nil on DriverKit HID.
        var properties: Unmanaged<CFMutableDictionary>?
        guard service != 0,
              IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let elements = dictionary["Elements"] as? [[String: Any]] else { return nil }
        return TrackpadDistanceScale(hidElements: elements)
    }

    private func received(_ report: UnsafeMutablePointer<UInt8>, length: Int, receivedAt: TimeInterval) {
        guard let parsed = TrackpadReport.parse(report, length: length) else { return }
        receive(parsed, at: receivedAt)
    }

    func receive(_ report: TrackpadReport, at receivedAt: TimeInterval) {
        contactsDown = report.buttonDown || report.contacts.contains(where: { $0.touching })
        if explorer?.isVisible == true {
            explorer?.process(report)
            if explorer?.isEditing != true { return }
        }
        if calibrationCapturing, let session = calibrationSession {
            advanceCalibration(at: receivedAt)
            if calibrationCapturing {
                session.process(report, at: receivedAt)
                if session.isComplete || session.cancellationReason != nil { finishCalibrationCapture() }
            }
            return
        }
        if suppressUntilLift {
            if !contactsDown { suppressUntilLift = false }
            return
        }
        gestures.process(report, receivedAt: receivedAt)
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
