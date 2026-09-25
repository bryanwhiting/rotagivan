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
    @Published private(set) var appleTrackpadEnabled: Bool
    @Published private(set) var appleTrackpadStatus = "Disabled on this Mac"
    @Published private(set) var appleTrackpadConnected = false
    private let inputPreferences: UserDefaults
    private let appleInput = AppleTrackpadInput()
    private let appleGestures: GestureEngine
    private let explorerPointer: any ExplorerPointerControlling
    private var inputRouting = TrackpadInputRouting()
    private var explorerSource: TrackpadInputSource?
    var explorerInputSource: TrackpadInputSource? { explorerSource }
    private var calibrationSource: TrackpadInputSource?
    private var navigatorDistanceScale: TrackpadDistanceScale?
    private var appleDistanceScale: TrackpadDistanceScale?
    private var started = false
    private var calibrationTimer: Timer?
    private var calibrationSettings: ProfileGestures?
    private var calibrationDevice: GestureDevice = .navigator
    private var calibrationActiveProfile: UInt32?
    private var calibrationConfigurationID: String?
    private var calibrationCapturing = false
    private var contactsDown = false
    private var suppressUntilLift = false
    private var explorer: (any AppExplorerPresenting)?
    private var explorerHotkeyHeld = false
    private var explorerConfiguration: AppExplorerSettings?
    private var explorerProfileID: UInt32?
    private var explorerSettings: ProfileGestures?
    private var explorerDevices: ProfileDevices?
    private var appObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var pendingAppleHUD: Timer?
    private var appleClickVetoUntil: TimeInterval = 0
    private var appleClickDraining = false
    private let appleHUDDelay: TimeInterval
    private var nextAppleTrustCheck: TimeInterval = 0

    var isCalibrating: Bool { calibrationCapturing }
    var canCalibrate: Bool {
        if appleTrackpadConnected { return store.settings.enabled }
        if case .connected = state { return store.settings.enabled }
        return false
    }
    func canCalibrate(device: GestureDevice) -> Bool {
        guard store.settings.enabled else { return false }
        if device == .apple { return store.settings.resolvedDevices.appleEnabled && appleTrackpadConnected }
        if case .connected = state { return store.settings.resolvedDevices.navigatorEnabled }
        return false
    }
    private let store: SettingsStore
    private let gestures: GestureEngine
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 64)

    init(store: SettingsStore, gestures: GestureEngine? = nil, explorer: (any AppExplorerPresenting)? = nil,
         appleGestures: GestureEngine? = nil, inputPreferences: UserDefaults = .standard,
         explorerPointer: (any ExplorerPointerControlling)? = nil,
         appleHUDDelay: TimeInterval = 0.08) {
        self.store = store
        self.gestures = gestures ?? GestureEngine(store: store)
        self.appleGestures = appleGestures ?? GestureEngine(store: store, inputMode: .nativeActions)
        self.inputPreferences = inputPreferences
        self.explorerPointer = explorerPointer ?? ExplorerPointerLock()
        self.appleHUDDelay = appleHUDDelay
        appleTrackpadEnabled = inputPreferences.bool(forKey: "input.appleTrackpadActions")
        self.explorerPointer.onInterruption = { [weak self] in
            self?.explorer?.dismiss()
        }
        appleInput.onStatus = { [weak self] status in self?.appleStatusChanged(status) }
        appleInput.onReport = { [weak self] identity, report, scale, time in
            guard let self, self.started, self.appleTrackpadEnabled, self.store.settings.enabled,
                  self.store.settings.resolvedDevices.appleEnabled else { return }
            // Accessibility is process-wide, not per touch. Avoid a trust query
            // on every high-frequency Apple frame sharing Navigator's run loop.
            if time >= self.nextAppleTrustCheck {
                self.nextAppleTrustCheck = time + 1
                guard AXIsProcessTrusted() else {
                    self.stopClickObservation()
                    self.appleInput.stop()
                    self.resetAppleSession()
                    self.appleTrackpadStatus = "Grant Accessibility permission, then Reconnect."
                    return
                }
            }
            self.appleDistanceScale = scale
            // Observation only. A held mouse button conservatively vetoes tap
            // actions; this global snapshot is not a device-specific click API.
            let buttonDown = [CGMouseButton.left, .right, .center].contains {
                CGEventSource.buttonState(.combinedSessionState, button: $0)
            }
            let observed = TrackpadReport(contacts: report.contacts,
                buttonDown: report.buttonDown || (buttonDown && report.contacts.contains(where: \.touching)),
                scanTime: report.scanTime)
            self.receive(observed, from: .apple(identity.deviceID), at: time)
        }
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
            explorer.onPresentationChanged = { [weak self] in self?.updateExplorerPointer() }
            (explorer as? AppExplorerController)?.configuration = { [weak store] in store?.settings.appExplorer ?? AppExplorerSettings() }
            (explorer as? AppExplorerController)?.gestureSettings = { [weak self] in
                self?.explorerGestureSettings ?? ProfileGestures(gestures: GestureSettings(), oneFingerTap: .none, twoFingerTap: .none)
            }
            (explorer as? AppExplorerController)?.hotkeyDictionary = { [weak store] in store?.settings.resolvedHotkeyDictionary ?? [] }
            (explorer as? AppExplorerController)?.editingStore = store
            (explorer as? AppExplorerController)?.onSettings = {
                HUDSettingsNavigation.pending = true
                NotificationCenter.default.post(name: .openHUDSettingsRequested, object: nil)
            }
            (explorer as? AppExplorerController)?.onEditingChanged = { [weak self] editing in
                guard let self else { return }
                self.gestures.isEditingInterface = editing
                self.appleGestures.isEditingInterface = editing
                self.suppressUntilLift = self.contactsDown
                if !editing {
                    self.explorerProfileID = self.store.activeProfileID
                    self.explorerSettings = self.explorerGestureSettings
                    self.explorerDevices = self.store.settings.resolvedDevices
                    self.explorerConfiguration = self.store.settings.appExplorer
                }
            }
            self.gestures.onAppExplorer = { [weak self] in self?.openAppExplorer() }
            self.gestures.onWindowManager = { [weak self] in self?.openAppExplorer(windowManager: true) }
            self.appleGestures.onAppExplorer = { [weak self] in self?.scheduleAppleHUD() }
            self.appleGestures.onWindowManager = { [weak self] in self?.scheduleAppleHUD(windowManager: true) }
            self.gestures.onHUDLayer = { [weak self] id in self?.openHUDLayer(id) }
            self.appleGestures.onHUDLayer = { [weak self] id in self?.scheduleAppleHUD(layerID: id) }
            self.gestures.onBindingAction = { [weak self] action in self?.executeBindingAction(action) }
            self.appleGestures.onBindingAction = { [weak self] action in self?.executeBindingAction(action) }
            (explorer as? AppExplorerController)?.onBindingAction = { [weak self] action in self?.executeBindingAction(action) }
            (explorer as? AppExplorerController)?.onKeyboardBindingAction = { [weak self] action in
                self?.executeBindingAction(action, fromKeyboard: true)
            }
            explorer.onDismiss = { [weak self] in
                guard let self else { return }
                self.gestures.reset()
                self.appleGestures.reset()
                self.explorerSource = nil
                self.explorerPointer.setLocked(false)
                self.suppressUntilLift = self.contactsDown
            }
            explorer.contextIsValid = { [weak self] in
                guard let self else { return false }
                if self.explorer?.isEditing == true { return self.store.settings.enabled && !self.calibrationCapturing }
                return self.store.settings.enabled && self.store.activeProfileID == self.explorerProfileID &&
                    self.explorerGestureSettings == self.explorerSettings && !self.calibrationCapturing &&
                    self.store.settings.resolvedDevices == self.explorerDevices &&
                    self.store.settings.appExplorer == self.explorerConfiguration
            }
        }
    }

    deinit {
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        pendingAppleHUD?.invalidate()
    }

    func foregroundAppChanged(_ bundleID: String?) {
        guard store.foregroundBundleID != bundleID else { return }
        if explorer?.isEditing == true, bundleID == "local.rotagivan" {
            store.foregroundBundleID = bundleID
            return
        }
        explorer?.dismiss()
        cancelAppleHUD()
        gestures.reset()
        appleGestures.reset()
        suppressUntilLift = contactsDown
        store.foregroundBundleID = bundleID
    }

    func openHUDLayer(_ id: UUID, fromKeyboard: Bool = false) {
        guard let layer = store.settings.appExplorer?.holdLayers?.first(where: { $0.id == id }),
              layer.isAvailable(in: store.foregroundBundleID) else { return }
        if explorer?.isVisible == true, let controller = explorer as? AppExplorerController {
            controller.switchLayer(id)
            return
        }
        openAppExplorer(layerID: id)
        if fromKeyboard, explorer?.isVisible == true {
            // A keyboard launch is not owned by whichever device last moved.
            // Let the next touching trackpad acquire the HUD and its pointer lock.
            explorerSource = nil
            explorerSettings = explorerGestureSettings
            updateExplorerPointer()
        }
    }

    /// Shared executor for keyboard and trackpad bindings, including actions
    /// assigned inside the HUD. A single path keeps action references from
    /// accidentally being posted as physical keystrokes.
    func executeBindingAction(_ action: BindingAction, fromKeyboard: Bool = false) {
        guard store.settings.enabled, action.isValid, !calibrationCapturing else { return }
        switch action.kind {
        case .keystroke:
            guard let shortcut = action.shortcut else { return }
            EventPoster().performTap(.shortcut, shortcut: shortcut)
        case .macro:
            guard let id = action.macroID,
                  let macro = store.settings.resolvedHotkeyDictionary.first(where: { $0.id == id }) else { return }
            EventPoster().performMacro(macro)
        case .hudLayer:
            if let ownerTokens = action.windowOwnerPath, let targetTokens = action.hudPath {
                let owner = ownerTokens.compactMap(ExplorerTilePathStep.init(token:))
                let targetPath = targetTokens.compactMap(ExplorerTilePathStep.init(token:))
                guard owner.count == ownerTokens.count, targetPath.count == targetTokens.count,
                      let window = store.settings.appExplorer?.windowActionSettings(ownerPath: owner) else { return }
                var target = ExplorerScopedHeldKeys()
                guard target.selectContainer(targetPath, settings: window) != nil else { return }
                let wasVisible = explorer?.isVisible == true
                if !wasVisible { openAppExplorer() }
                _ = (explorer as? AppExplorerController)?.switchWindowContainer(
                    ownerTokens: ownerTokens, targetTokens: targetTokens)
                if fromKeyboard && !wasVisible { releaseKeyboardHUDOwnership() }
            } else if let tokens = action.hudPath {
                let path = tokens.compactMap(ExplorerTilePathStep.init(token:))
                guard path.count == tokens.count else { return }
                var target = ExplorerScopedHeldKeys()
                guard target.selectContainer(path, settings: store.settings.appExplorer ?? AppExplorerSettings()) != nil else { return }
                let wasVisible = explorer?.isVisible == true
                if !wasVisible { openAppExplorer() }
                _ = (explorer as? AppExplorerController)?.switchContainer(tokens)
                if fromKeyboard && !wasVisible { releaseKeyboardHUDOwnership() }
            } else if let id = action.hudLayerID { openHUDLayer(id, fromKeyboard: fromKeyboard) }
            else {
                if explorer?.isVisible == true, let controller = explorer as? AppExplorerController {
                    controller.switchLayer(nil)
                } else {
                    openAppExplorer()
                    if fromKeyboard { releaseKeyboardHUDOwnership() }
                }
            }
        case .hudNavigation:
            guard let direction = action.hudNavigation else { return }
            let wasVisible = explorer?.isVisible == true
            if !wasVisible { openAppExplorer() }
            (explorer as? AppExplorerController)?.navigateHUD(direction)
            if fromKeyboard && !wasVisible { releaseKeyboardHUDOwnership() }
        case .openApp:
            guard let id = action.bundleID,
                  let url = ExplorerApplicationCatalog.applicationURL(for: id) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Logger(subsystem: "local.rotagivan", category: "Bindings").error("Application open failed: \(error.localizedDescription, privacy: .public)") }
            }
        case .openURL:
            guard let string = action.url, let url = AppExplorerFavorite.webURL(string) else { return }
            _ = NSWorkspace.shared.open(url)
        case .command:
            guard let command = action.command else { return }
            switch command {
            case .windowManager:
                if explorer?.isVisible == true { explorer?.dismiss() }
                openAppExplorer(windowManager: true)
                if fromKeyboard { releaseKeyboardHUDOwnership() }
            case .appWindows, .mediaControls:
                let wasVisible = explorer?.isVisible == true
                if !wasVisible { openAppExplorer() }
                (explorer as? AppExplorerController)?.showBuiltIn(command)
                if fromKeyboard && !wasVisible { releaseKeyboardHUDOwnership() }
            default:
                if let shortcut = command.macOSShortcut { EventPoster().performTap(.shortcut, shortcut: shortcut) }
                else if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                        let target = WindowTiling.capture(pid: pid) { if let error = target.command(command) { AppExplorerController.showWindowError(error) } }
            }
        case .media:
            if let media = action.media { ExplorerMediaAction.perform(media) }
        case .windowPlacement:
            guard let placement = action.windowPlacement,
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let target = WindowTiling.capture(pid: pid) else { return }
            _ = target.apply(placement.direction, placement.layout)
        case .tap:
            guard let tap = action.tap else { return }
            switch tap {
            case .appExplorer:
                let wasVisible = explorer?.isVisible == true
                openAppExplorer()
                if fromKeyboard && !wasVisible { releaseKeyboardHUDOwnership() }
            case .windowManager:
                let wasVisible = explorer?.isVisible == true
                openAppExplorer(windowManager: true)
                if fromKeyboard && !wasVisible { releaseKeyboardHUDOwnership() }
            default: EventPoster().performTap(tap)
            }
        }
    }

    /// Carbon receives registered global keys before the nonactivating HUD panel.
    /// Route those physical events through the visible HUD's local scope first.
    func processVisibleHUDHotkey(keyCode: UInt16, modifiers: UInt64, down: Bool) -> Bool {
        guard store.settings.enabled, let controller = explorer as? AppExplorerController,
              controller.isVisible, !controller.isEditing,
              let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                  modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifiers)),
                  timestamp: 0, windowNumber: 0, context: nil, characters: "",
                  charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) else { return false }
        return controller.processLayerKey(event)
    }

    private func releaseKeyboardHUDOwnership() {
        guard explorer?.isVisible == true else { return }
        // A keyboard launch has no current contact owner. The next touching
        // trackpad chooses its own calibration and pointer-lock source.
        explorerSource = nil
        explorerSettings = explorerGestureSettings
        updateExplorerPointer()
    }

    private func openAppExplorer(windowManager: Bool = false, layerID: UUID? = nil) {
        guard explorer?.isEditing != true else { return }
        guard store.settings.enabled, !calibrationCapturing else { return }
        if layerID != nil, explorer?.isVisible == true { explorer?.dismiss() }
        cancelAppleHUD()
        gestures.reset()
        appleGestures.reset()
        explorerProfileID = store.activeProfileID
        explorerConfiguration = store.settings.appExplorer
        explorerSource = inputRouting.source
        explorerSettings = explorerGestureSettings
        explorerDevices = store.settings.resolvedDevices
        if let layerID { explorer?.showLayer(layerID, waitingForLift: contactsDown) }
        else if windowManager { explorer?.showWindowManager(waitingForLift: contactsDown) }
        else { explorer?.show(waitingForLift: contactsDown) }
        updateExplorerPointer()
    }

    private var explorerGestureSettings: ProfileGestures {
        store.activeGestures(for: explorerSource?.isApple == true ? .apple : .navigator)
    }

    private func cancelAppleHUD() {
        pendingAppleHUD?.invalidate()
        pendingAppleHUD = nil
    }

    // Native click events can arrive after the raw touch-lift callback. Give
    // macOS a short arbitration window before presenting a touch-triggered HUD.
    private func scheduleAppleHUD(windowManager: Bool = false, layerID: UUID? = nil) {
        guard let source = inputRouting.source, source.isApple,
              ProcessInfo.processInfo.systemUptime >= appleClickVetoUntil else { return }
        cancelAppleHUD()
        let profile = store.activeProfileID
        let configuration = store.activeGestures(for: .apple)
        let open = { [weak self] in
            guard let self else { return }
            self.pendingAppleHUD = nil
            guard self.inputRouting.source == source, self.store.activeProfileID == profile,
                  self.store.activeGestures(for: .apple) == configuration,
                  ProcessInfo.processInfo.systemUptime >= self.appleClickVetoUntil else { return }
            self.openAppExplorer(windowManager: windowManager, layerID: layerID)
        }
        if appleHUDDelay == 0 { open(); return } // Deterministic input-fixture seam.
        let timer = Timer(timeInterval: appleHUDDelay, repeats: false) { _ in
            MainActor.assumeIsolated { open() }
        }
        pendingAppleHUD = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // Passive mouse-down observation covers clicks between raw touch frames,
    // including native secondary tap-to-click. Never consumes the mouse event.
    func nativeClickObserved() {
        guard appleTrackpadEnabled else { return }
        appleClickVetoUntil = ProcessInfo.processInfo.systemUptime + 0.12
        appleClickDraining = inputRouting.source?.isApple == true && contactsDown
        cancelAppleHUD()
        appleGestures.reset()
    }

    private func startClickObservation() {
        guard globalClickMonitor == nil, localClickMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.nativeClickObserved() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.nativeClickObserved() }
            return event
        }
    }

    private func stopClickObservation() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
        cancelAppleHUD()
    }

    private func updateExplorerPointer() {
        let lock = ExplorerPointerLock.shouldLock(enabled: store.settings.enabled,
            appleEnabled: appleTrackpadEnabled, visible: explorer?.isVisible == true,
            editing: explorer?.isEditing == true, owner: explorerSource,
            appleConnected: appleTrackpadConnected)
        guard explorerPointer.setLocked(lock) else {
            appleTrackpadStatus = "Could not hold the pointer still. Check Accessibility permission and Reconnect."
            explorer?.dismiss()
            return
        }
    }

    func explorerHold(_ down: Bool) {
        guard down != explorerHotkeyHeld else { return }
        explorerHotkeyHeld = down
        if down {
            guard store.settings.enabled, !calibrationCapturing else { explorerHotkeyHeld = false; return }
            explorer?.setAlternateHeld(true)
            gestures.reset()
            appleGestures.reset()
            openAppExplorer()
            // A keyboard-opened HUD may be controlled by either trackpad.
            explorerSource = nil
            explorerSettings = explorerGestureSettings
            updateExplorerPointer()
        } else {
            if explorer?.isEditing != true { explorer?.dismiss() }
            explorer?.setAlternateHeld(false)
        }
    }

    func beginCalibration(profileID: UInt32, mode: GestureCalibrationMode, device: GestureDevice = .navigator) {
        guard canCalibrate(device: device), calibrationSession == nil,
              store.profiles.contains(where: { $0.id == profileID }) else { return }
        startCalibrationSession(GestureCalibrationSession(profileID: profileID,
            profileName: store.activeConfigurationName, mode: mode,
            gestures: store.gestures(for: profileID, device: device), device: device), device: device)
    }

    // Separate from connection setup so the input gate can be tested without a physical device.
    func startCalibrationSession(_ session: GestureCalibrationSession, at time: TimeInterval = ProcessInfo.processInfo.systemUptime, device: GestureDevice = .navigator) {
        cancelAppleHUD()
        explorer?.dismiss()
        endCalibration()
        gestures.reset()
        appleGestures.reset()
        calibrationSource = nil
        calibrationDevice = device
        if let source = inputRouting.source, source.isApple != (device == .apple) {
            // A resting finger on the other trackpad must not block capture.
            inputRouting.reset(draining: contactsDown ? source : nil)
            contactsDown = false
        }
        calibrationSettings = calibrationGestures(session.profileID)
        calibrationActiveProfile = store.activeProfileID
        calibrationConfigurationID = store.activeConfigurationID
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
            store.activeConfigurationID != calibrationConfigurationID ||
            !store.profiles.contains(where: { $0.id == session.profileID }) ||
            calibrationGestures(session.profileID) != calibrationSettings {
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
        appleGestures.reset()
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
        calibrationConfigurationID = nil
        calibrationSource = nil
    }

    func applyCalibration() {
        advanceCalibration(at: ProcessInfo.processInfo.systemUptime)
        guard let session = calibrationSession, session.isComplete, session.cancellationReason == nil,
              let median = session.medianDoubleTapInterval else { return }
        var timings = store.tapCalibration(for: calibrationDevice)
        if session.mode == .tripleTap, let second = session.medianSecondTapInterval {
            timings.tripleTapFirstInterval = min(600, max(50, (median * 1_000).rounded())) / 1_000
            timings.tripleTapSecondInterval = min(600, max(50, (second * 1_000).rounded())) / 1_000
        } else if session.mode != .singleTapSwipe {
            timings.doubleTapInterval = min(600, max(50, (median * 1_000).rounded())) / 1_000
        }
        if session.mode == .singleTapSwipe, let window = session.medianSwipeWindow, let duration = session.medianSwipeDuration {
            timings.singleSwipeWindow = min(800, max(100, (window * 1_000).rounded())) / 1_000
            timings.singleSwipeDuration = min(300, max(60, (duration * 1_000).rounded())) / 1_000
        }
        if session.mode == .doubleTapSwipe, let window = session.medianSwipeWindow {
            timings.doubleSwipeWindow = min(800, max(100, (window * 1_000).rounded())) / 1_000
        }
        let device = calibrationDevice
        endCalibration()
        store.updateTapCalibration(timings, for: device)
    }

    private func calibrationGestures(_ id: UInt32) -> ProfileGestures {
        store.gestures(for: id, device: calibrationDevice)
    }

    func start() {
        started = true
        startAppleInput()
        guard store.settings.resolvedDevices.navigatorEnabled else { state = .stopped; return }
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
        stopClickObservation()
        explorerPointer.setLocked(false)
        let wasTouching = contactsDown
        started = false
        appleInput.stop()
        appleGestures.reset()
        inputRouting.reset()
        contactsDown = false
        suppressUntilLift = false
        explorerSource = nil
        calibrationSource = nil
        explorer?.dismiss()
        suppressUntilLift = wasTouching
        updateDistanceScale(nil)
        navigatorDistanceScale = nil
        appleDistanceScale = nil
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
        navigatorDistanceScale = Self.readDistanceScale(from: device)
        if inputRouting.source?.isApple != true { updateDistanceScale(navigatorDistanceScale) }
        UserDefaults.standard.set(Date(), forKey: "debug.lastConnected")
        state = .connected(product)
    }

    private func didRemove(_ device: IOHIDDevice) {
        guard self.device === device else { return }
        self.device = nil
        navigatorDisconnected()
    }

    // Separate lifecycle seam for testing a Navigator unplug while Apple owns
    // an active contact. An unrelated device must not restart that contact.
    func navigatorDisconnected() {
        navigatorDistanceScale = nil
        state = .looking
        gestures.reset()
        if inputRouting.source?.isApple == true {
            updateDistanceScale(appleDistanceScale)
            return
        }
        explorer?.dismiss()
        updateDistanceScale(appleTrackpadConnected ? appleDistanceScale : nil)
        cancelCalibration(reason: "The trackpad disconnected. Reconnect and start again.")
        inputRouting.reset()
        contactsDown = false
        suppressUntilLift = false
    }

    /// Display metadata is not a frame stream. @Published emits even for equal
    /// values, which otherwise redraws every settings column at report rate.
    func updateDistanceScale(_ scale: TrackpadDistanceScale?) {
        guard distanceScale != scale else { return }
        distanceScale = scale
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
        guard manager != nil, device != nil,
              let parsed = TrackpadReport.parse(report, length: length) else { return }
        receive(parsed, at: receivedAt)
    }

    func receive(_ report: TrackpadReport, at receivedAt: TimeInterval) {
        receive(report, from: .navigator, at: receivedAt)
    }

    func receive(_ report: TrackpadReport, from source: TrackpadInputSource, at receivedAt: TimeInterval) {
        guard source.isApple ? store.settings.resolvedDevices.appleEnabled : store.settings.resolvedDevices.navigatorEnabled else { return }
        let touching = report.buttonDown || report.contacts.contains(where: { $0.touching })
        // Ignore other-device samples, but observe its lift to clear any drain.
        if calibrationCapturing && source.isApple != (calibrationDevice == .apple) {
            if !touching { _ = inputRouting.accept(source, touching: false, lockedTo: calibrationSource) }
            return
        }
        let previousSource = inputRouting.source
        let lock = explorer?.isVisible == true ? explorerSource : (calibrationCapturing ? calibrationSource : nil)
        // Empty frames before the first touch are useful to initialize calibration.
        if previousSource == nil && !touching {
            _ = inputRouting.accept(source, touching: false, lockedTo: lock)
            if calibrationCapturing { calibrationSession?.process(report, at: receivedAt) }
            return
        }
        guard inputRouting.accept(source, touching: touching, lockedTo: lock) else { return }
        if previousSource != inputRouting.source {
            // The two engines have separate contact state. An Apple touch must
            // not cancel Navigator cursor falloff or scroll momentum. Discrete
            // pending taps still cancel rather than firing under a new owner.
            cancelAppleHUD()
            gestures.cancelPendingActionsForSourceChange()
            appleGestures.reset()
        }
        contactsDown = inputRouting.contactsDown
        updateDistanceScale(source.isApple ? appleDistanceScale : navigatorDistanceScale)
        if explorer?.isVisible == true {
            if explorerSource == nil {
                explorerSource = source
                explorerSettings = explorerGestureSettings
            }
            updateExplorerPointer()
            guard explorer?.isVisible == true else { return }
            explorer?.process(report)
            if explorer?.isEditing != true { return }
        }
        if calibrationCapturing, let session = calibrationSession {
            if calibrationSource == nil { calibrationSource = source }
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
        if source.isApple {
            if report.buttonDown || ProcessInfo.processInfo.systemUptime < appleClickVetoUntil {
                cancelAppleHUD()
                appleGestures.reset()
                appleClickDraining = touching
                return
            }
            if appleClickDraining {
                appleClickDraining = touching
                return
            }
        }
        if source.isApple { appleGestures.process(report, receivedAt: receivedAt) }
        else { gestures.process(report, receivedAt: receivedAt) }
    }

    func setAppleTrackpadEnabled(_ enabled: Bool) {
        guard appleTrackpadEnabled != enabled else { return }
        appleTrackpadEnabled = enabled
        updateExplorerPointer()
        inputPreferences.set(enabled, forKey: "input.appleTrackpadActions")
        if enabled, store.settings.enabled {
            started = true
            startAppleInput()
        } else {
            stopClickObservation()
            appleInput.stop()
            appleTrackpadStatus = enabled ? "Rotagivan is disabled" : "Disabled on this Mac"
            resetAppleSession()
        }
    }

    private func startAppleInput() {
        guard appleTrackpadEnabled, store.settings.enabled else { return }
        guard store.settings.resolvedDevices.appleEnabled else {
            appleTrackpadStatus = "Apple actions are off in this profile"
            return
        }
        guard AXIsProcessTrusted() else {
            appleTrackpadStatus = "Grant Accessibility permission, then Reconnect."
            return
        }
        startClickObservation()
        appleInput.start()
    }

    private func resetAppleSession() {
        cancelAppleHUD()
        appleClickDraining = false
        appleGestures.reset()
        if inputRouting.source?.isApple == true {
            let interruptedSource = contactsDown ? inputRouting.source : nil
            explorer?.dismiss()
            cancelCalibration(reason: "The Apple trackpad was disconnected or disabled. Start again after reconnecting.")
            inputRouting.reset(draining: interruptedSource)
            contactsDown = false
            suppressUntilLift = false
            updateDistanceScale(navigatorDistanceScale)
        }
    }

    private func appleStatusChanged(_ status: AppleTrackpadInput.Status) {
        appleTrackpadConnected = false
        switch status {
        case .stopped: appleTrackpadStatus = appleTrackpadEnabled ? "Stopped" : "Disabled on this Mac"
        case .looking: appleTrackpadStatus = "Looking for an Apple trackpad…"
        case .unavailable(let message): appleTrackpadStatus = message
        case .connected(let devices):
            appleTrackpadConnected = !devices.isEmpty
            appleTrackpadStatus = "Monitoring \(devices.count) Apple trackpad\(devices.count == 1 ? "" : "s") · native motion"
            if case .apple(let id) = inputRouting.source, !devices.contains(where: { $0.deviceID == id }) {
                resetAppleSession()
            }
        }
        if !appleTrackpadConnected { resetAppleSession() }
        // A keyboard-opened HUD can be waiting for its first touch with no owner.
        // Release its preemptive pointer capture if the Apple device disappears.
        updateExplorerPointer()
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
