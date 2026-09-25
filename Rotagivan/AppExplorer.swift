import AppKit
import SwiftUI
import OSLog

@MainActor protocol AppExplorerPresenting: AnyObject {
    var isVisible: Bool { get }
    var isEditing: Bool { get }
    var onDismiss: (() -> Void)? { get set }
    var contextIsValid: (() -> Bool)? { get set }
    var onPresentationChanged: (() -> Void)? { get set }
    func show(waitingForLift: Bool)
    func showWindowManager(waitingForLift: Bool)
    func showLayer(_ id: UUID, waitingForLift: Bool)
    func process(_ report: TrackpadReport)
    func dismiss()
    func setAlternateHeld(_ held: Bool)
}
extension AppExplorerPresenting {
    func showLayer(_ id: UUID, waitingForLift: Bool) {}
    var onPresentationChanged: (() -> Void)? { get { nil } set {} }
    var isEditing: Bool { false }
    func setAlternateHeld(_ held: Bool) {}
}

@MainActor final class AppExplorerController: AppExplorerPresenting {
    private let workspace = NSWorkspace.shared
    private let defaults: UserDefaults
    private var recents: AppExplorerRecents
    private var observers: [NSObjectProtocol] = []
    private var panel: ExplorerPanel?
    private var timer: Timer?
    private var escapeMonitor: Any?
    private var input = AppExplorerSelection(waitingForLift: false)
    private var localGestureReports: [TrackpadReport] = []
    private var localGestureStrokeStart = 0
    private var localGestureTapCount = 0
    private var localGestureFingerCount = 0
    private var localGestureSequenceFingers = 0
    private var localGestureMaxTravel = 0.0
    private var localGesturePendingWindow = 0.0
    private var localGestureFollowupDelay = 0.0
    private var localGestureStarted = Date.distantPast
    private var localGestureLastLift = Date.distantPast
    private var orbitDragUnit = CGPoint.zero
    private var localGestureOrigin: CGPoint?
    private var localGestureLast = CGPoint.zero
    private var localGestureFingerOrigins: [UInt8: CGPoint] = [:]
    private var localGestureFingerLast: [UInt8: CGPoint] = [:]
    private var localGestureTimer: Timer?
    private let model = ExplorerModel()
    // Prepared on presentation and reused across rotations; never retain stale
    // configuration or machine-local app icons across separate HUD sessions.
    private var entryCache: [(favorite: AppExplorerFavorite, depth: Int, entry: ExplorerEntry)] = []
    private var entryCacheSettings: AppExplorerSettings?
    private var entryCacheDictionary: [NamedHotkey] = []
    private var sourcePID: pid_t?
    private let shortcutPoster = EventPoster()
    var sendShortcut: ((RecordedShortcut) -> Void)?
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var frontmostBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    private var sourceBundleID: String?
    private var deadline = Date.distantPast
    private var alternateHeld = false
    private var heldKeys = ExplorerScopedHeldKeys()
    private var windowKeys = ExplorerScopedHeldKeys()
    private var windowGroupPath: [ExplorerSlot] = []
    private var baseWindowGroupPath: [ExplorerSlot] = []
    private var windowOwnerPath: [ExplorerSlot]?
    private var windowList: [WindowTiling.AppWindow] = []
    private var windowPage = 0
    var listWindows: (pid_t) -> [WindowTiling.AppWindow] = { WindowTiling.windows(pid: $0) }
    private var baseGroupPath: [ExplorerSlot] = []
    var performMedia: (ExplorerMediaAction) -> Void = { ExplorerMediaAction.perform($0) }
    var performMacCommand: (AppExplorerAction) -> Void = { action in
        guard let shortcut = action.macOSShortcut else { return }
        EventPoster().performTap(.shortcut, shortcut: shortcut)
    }
    private(set) var groupPath: [ExplorerSlot] = []
    private var contactIsDown = false
    private var selectionGeneration: UInt64 = 0
    private let cursorCentering = ExplorerCursorCentering()
    var cursorPosition: () -> CGPoint? = { CGEvent(source: nil)?.location }
    var centerApplication: ((pid_t, CGPoint?, @escaping () -> Bool) -> Void)?
    var focusApplicationWindow: (pid_t) -> Void = { WindowTiling.focusApplicationWindow(pid: $0) }
    private var tilingTarget: WindowTilingTarget?
    private var controlDirection: ExplorerSlot?
    var captureWindow: (pid_t) -> WindowTilingTarget? = { WindowTiling.capture(pid: $0) }
    var configuration: () -> AppExplorerSettings = { AppExplorerSettings() }
    var gestureSettings: () -> ProfileGestures = {
        ProfileGestures(gestures: GestureSettings(), oneFingerTap: .none, twoFingerTap: .none)
    }
    var hotkeyDictionary: () -> [NamedHotkey] = { [] }
    var applicationURL: (String) -> URL? = { ExplorerApplicationCatalog.applicationURL(for: $0) }
    var openWebURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var openApplication: (URL, NSWorkspace.OpenConfiguration, @escaping @MainActor (pid_t?) -> Void) -> Void = { url, configuration, completion in
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error {
                // Launch Services may invoke this callback off the main actor.
                // Keep logging local so it never accesses actor-isolated state.
                let logger = Logger(subsystem: "local.rotagivan", category: "AppExplorer")
                logger.error("Application open failed: \(error.localizedDescription, privacy: .public)")
            }
            let pid = error == nil ? app?.processIdentifier : nil
            Task { @MainActor in completion(pid) }
        }
    }
    var onDismiss: (() -> Void)?
    var onSettings: (() -> Void)?
    var onBindingAction: ((BindingAction) -> Void)?
    var onKeyboardBindingAction: ((BindingAction) -> Void)?
    var onPresentationChanged: (() -> Void)?
    var contextIsValid: (() -> Bool)?
    weak var editingStore: SettingsStore?
    var onEditingChanged: ((Bool) -> Void)?
    var isVisible: Bool { panel != nil }
    var isEditing: Bool { model.isEditing }
    var displayedEntries: [ExplorerEntry] { model.entries }
    var displayedOrbitProgress: Double { model.orbitProgress }
    var displayedHUDMap: [HUDCarouselPreview] { model.carouselPreviews }
    var displayedLayerID: UUID? { heldKeys.activeID }
    var displayedOrbitOffset: HUDMapPoint { model.orbitOffset }
    var displayedLevelDirections: [ExplorerSlot] { model.groupDirections }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = AppExplorerRecents(defaults.stringArray(forKey: "appExplorer.recentBundleIDs") ?? [])
        if let app = workspace.frontmostApplication { record(app) }
        observers.append(workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.record(app)
                if self.isVisible && (self.isEditing
                    ? app.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    : app.processIdentifier != self.sourcePID) { self.dismiss() }
            }
        })
        for notification in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
    }

    deinit {
        for observer in observers { workspace.notificationCenter.removeObserver(observer) }
        timer?.invalidate()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    private func record(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let identifier = app.bundleIdentifier, identifier != "local.rotagivan" else { return }
        recents.record(identifier)
        defaults.set(recents.identifiers, forKey: "appExplorer.recentBundleIDs")
    }

    func show(waitingForLift: Bool) {
        show(waitingForLift: waitingForLift, windowManager: false)
    }

    func showLayer(_ id: UUID, waitingForLift: Bool) {
        guard let layer = configuration().holdLayers?.first(where: { $0.id == id }), layer.isAvailable(in: frontmostBundleID()) else { return }
        if isVisible { dismiss() }
        show(waitingForLift: waitingForLift, windowManager: false, layerID: id)
    }

    func showWindowManager(waitingForLift: Bool) {
        show(waitingForLift: waitingForLift, windowManager: true)
    }

    /// Switch the open panel's scope without changing its source application or
    /// releasing the trackpad that owns its pointer lock.
    func switchLayer(_ id: UUID?) {
        guard isVisible, !isEditing else { return }
        if let id {
            guard let layer = configuration().holdLayers?.first(where: { $0.id == id }),
                  layer.isAvailable(in: sourceBundleID) else { return }
        }
        heldKeys = ExplorerScopedHeldKeys()
        if let id { heldKeys.selectRootLayer(id, settings: configuration()) }
        windowKeys = ExplorerScopedHeldKeys()
        groupPath = []; baseGroupPath = []
        windowGroupPath = []; baseWindowGroupPath = []; windowOwnerPath = nil
        windowList = []; windowPage = 0
        model.showingAppWindows = false
        model.showingMediaControls = false
        model.showingWindowManager = false
        model.directWindowManager = false
        controlDirection = nil
        model.message = nil
        refreshGroup()
    }

    private var mappedBuiltIn: HUDLayerBuiltIn? {
        guard groupPath.isEmpty, windowGroupPath.isEmpty, !model.showingAppWindows else { return nil }
        return configuration().holdLayers?.first { $0.id == heldKeys.activeID }?.builtIn
    }
    private var mapNavigationAvailable: Bool {
        !model.showingAppWindows &&
        (!model.showingWindowManager || mappedBuiltIn == .windowManager) &&
        (!model.showingMediaControls || mappedBuiltIn == .mediaControls)
    }

    /// Move within the fixed map without closing the panel or wrapping at its edges.
    @discardableResult func navigateHUD(_ direction: HUDNavigationAction) -> Bool {
        guard isVisible, !isEditing, mapNavigationAvailable else { return false }
        let map = configuration().hudMap(in: sourceBundleID)
        guard let origin = map.first(where: { $0.layerID == heldKeys.activeID })?.point,
              let target = HUDMapPoint.nearestIndex(in: map.map { $0.point - origin }, toward: direction) else { return false }
        switchLayer(map[target].layerID)
        return true
    }

    @discardableResult func switchContainer(_ tokens: [String]) -> Bool {
        guard isVisible, !isEditing, tokens.count <= 16 else { return false }
        let path = tokens.compactMap(ExplorerTilePathStep.init(token:))
        guard path.count == tokens.count else { return false }
        var keys = ExplorerScopedHeldKeys()
        guard let groups = keys.selectContainer(path, settings: configuration()) else { return false }
        heldKeys = keys
        groupPath = groups; baseGroupPath = groups
        windowKeys = ExplorerScopedHeldKeys()
        windowGroupPath = []; baseWindowGroupPath = []; windowOwnerPath = nil
        windowList = []; windowPage = 0
        model.showingAppWindows = false
        model.showingMediaControls = false
        model.showingWindowManager = false
        model.directWindowManager = false
        controlDirection = nil
        model.message = nil
        refreshGroup()
        return true
    }

    @discardableResult func switchWindowContainer(ownerTokens: [String], targetTokens: [String]) -> Bool {
        guard isVisible, !isEditing, ownerTokens.count <= 16, targetTokens.count <= 16 else { return false }
        let owner = ownerTokens.compactMap(ExplorerTilePathStep.init(token:))
        let target = targetTokens.compactMap(ExplorerTilePathStep.init(token:))
        guard owner.count == ownerTokens.count, target.count == targetTokens.count,
              let window = configuration().windowActionSettings(ownerPath: owner) else { return false }
        var selectedWindow = ExplorerScopedHeldKeys()
        guard let windowGroups = selectedWindow.selectContainer(target, settings: window) else { return false }
        var selectedExplorer = ExplorerScopedHeldKeys()
        var ownerGroups: [ExplorerSlot] = []
        var ownerSlot: ExplorerSlot?
        if !owner.isEmpty {
            guard case .group(let slot) = owner.last!,
                  let groups = selectedExplorer.selectContainer(Array(owner.dropLast()), settings: configuration()) else { return false }
            ownerGroups = groups
            ownerSlot = slot
        }
        heldKeys = selectedExplorer
        groupPath = ownerGroups; baseGroupPath = ownerGroups
        windowKeys = selectedWindow
        windowGroupPath = windowGroups; baseWindowGroupPath = windowGroups
        windowOwnerPath = ownerSlot.map { ownerGroups + [$0] }
        windowList = []; windowPage = 0
        model.showingAppWindows = false
        model.showingMediaControls = false
        model.showingWindowManager = true
        model.directWindowManager = ownerSlot == nil
        controlDirection = ownerSlot
        tilingTarget = sourcePID.flatMap(captureWindow)
        model.message = tilingTarget == nil
            ? "No controllable window. Enable Accessibility and open Explorer over a normal app window." : nil
        refreshGroup()
        return true
    }

    func showBuiltIn(_ command: AppExplorerAction) {
        guard isVisible, !isEditing, contextIsValid?() != false else { return }
        switch command {
        case .mediaControls:
            model.showingMediaControls = true
            model.showingAppWindows = false
            controlDirection = nil
            refreshGroup()
        default: break
        }
    }

    private func show(waitingForLift: Bool, windowManager: Bool, layerID: UUID? = nil) {
        guard !isVisible else { return }
        resetLocalGesture()
        cursorCentering.cancel()
        selectionGeneration &+= 1
        groupPath = []
        heldKeys = ExplorerScopedHeldKeys()
        sourceBundleID = frontmostBundleID()
        if let layerID { heldKeys.selectRootLayer(layerID, settings: configuration()) }
        windowKeys = ExplorerScopedHeldKeys()
        windowGroupPath = []; baseWindowGroupPath = []; windowOwnerPath = nil
        windowList = []; windowPage = 0; model.showingAppWindows = false
        baseGroupPath = []
        model.showingMediaControls = false
        model.showingWindowManager = windowManager
        model.directWindowManager = windowManager
        model.message = nil
        tilingTarget = nil
        controlDirection = nil
        model.canEdit = editingStore != nil
        contactIsDown = waitingForLift
        sourcePID = frontmostPID()
        if windowManager {
            tilingTarget = sourcePID.flatMap(captureWindow)
            model.message = tilingTarget == nil ? "No controllable window. Enable Accessibility and open Explorer over a normal app window." : nil
        }
        loadEntries()
        model.selected = nil
        input = makeSelection(waitingForLift: waitingForLift)
        let panel = ExplorerPanel(contentRect: NSRect(x: 0, y: 0, width: 950, height: 850),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "App Explorer"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !model.theme.isFloating
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.onSettings = { [weak self] in self?.openSettings() }
        panel.onKey = { [weak self] in self?.processLayerKey($0) ?? false }
        panel.contentView = NSHostingView(rootView: AppExplorerView(model: model,
            onSelect: { [weak self] in self?.choose($0) }, onCancel: { [weak self] in self?.dismiss() },
            onDeepSelect: { [weak self] in self?.chooseDeep($0) },
            onBack: { [weak self] in self?.centerTap() },
            onSettings: { [weak self] in self?.openSettings() },
            onWindowCommand: { [weak self] in self?.performWindowCommand($0) },
            onWindowPage: { [weak self] in self?.changeWindowPage($0) }))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        self.panel = panel
        onPresentationChanged?()
        // The owner may decline presentation if pointer capture is unavailable.
        guard self.panel === panel else { return }
        panel.makeKeyAndOrderFront(nil)
        // Selection uses raw HID, not per-event SwiftUI pointer updates.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss() }
        }
        deadline = Date().addingTimeInterval(15)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (!self.isEditing && Date() >= self.deadline) || self.contextIsValid?() == false { self.dismiss() }
                else if self.isVisible && self.model.showingWindowManager && self.model.windowFullScreen != (self.tilingTarget?.isFullScreen() == true) {
                    self.refreshGroup()
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setAlternateHeld(_ held: Bool) {
        guard alternateHeld != held else { return }
        alternateHeld = held
        if isVisible && !isEditing {
            // The HID owner reopens with the actual contact state. Never carry
            // a partial selection across modes or discard a fresh first swipe.
            dismiss()
        }
    }

    private var layerScopePath: [ExplorerSlot] {
        if model.showingWindowManager { return windowOwnerPath ?? [] }
        if model.showingMediaControls,
           let controlDirection { return groupPath + [controlDirection] }
        return groupPath
    }
    var inlineEditorWindowOwnerPath: [ExplorerTilePathStep]? {
        guard model.showingWindowManager else { return nil }
        return (windowOwnerPath ?? []).map { .group($0) }
    }
    private var windowConfiguration: AppExplorerSettings {
        let saved = configuration(), projected = heldKeys.resolved(saved)
        return projected.windowEditor(at: windowOwnerPath ?? [])
    }

    private var visibleActionBindings: [ActionBinding] {
        let original = configuration()
        if model.showingWindowManager {
            let window = windowConfiguration
            let resolved = windowKeys.resolved(window)
            if !windowGroupPath.isEmpty { return resolved.favorite(at: windowGroupPath)?.actionBindings ?? [] }
            if let layer = windowKeys.activeLayer(at: windowGroupPath, in: window) { return layer.actionBindings ?? [] }
            return window.actionBindings ?? []
        }
        let resolved = heldKeys.resolved(original)
        if !groupPath.isEmpty { return resolved.favorite(at: groupPath)?.actionBindings ?? [] }
        if let layer = heldKeys.activeLayer(at: layerScopePath, in: original) {
            return layer.actionBindings ?? []
        }
        return original.actionBindings ?? []
    }

    private func performBoundAction(_ action: BindingAction, fromKeyboard: Bool = false) {
        guard action.isValid, contextIsValid?() != false else { return }
        if action.kind == .hudNavigation, let direction = action.hudNavigation {
            _ = navigateHUD(direction)
            return
        }
        let dispatch = fromKeyboard ? (onKeyboardBindingAction ?? onBindingAction) : onBindingAction
        if action.kind == .hudLayer ||
           (action.kind == .command && action.command == .mediaControls) {
            dispatch?(action)
            return
        }
        let originalPID = sourcePID
        dismiss()
        let generation = selectionGeneration
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.selectionGeneration == generation,
                      self.contextIsValid?() != false, self.frontmostPID() == originalPID else { return }
                if fromKeyboard { (self.onKeyboardBindingAction ?? self.onBindingAction)?(action) }
                else { self.onBindingAction?(action) }
            }
        }
    }

    @discardableResult func processLayerKey(_ event: NSEvent) -> Bool {
        guard isVisible, !isEditing, contextIsValid?() != false else { return false }
        if event.type == .keyDown && event.keyCode == 53 { return false }
        if model.showingAppWindows {
            if event.type == .keyDown && [123, 124].contains(event.keyCode) {
                changeWindowPage(event.keyCode == 123 ? -1 : 1); return true
            }
            return false
        }
        let flags = UInt64(event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
        if event.type == .keyDown, let binding = visibleActionBindings.first(where: {
            $0.trigger.keyboard?.keyCode == event.keyCode && $0.trigger.keyboard?.modifiers == flags
        }) {
            if !event.isARepeat { performBoundAction(binding.action, fromKeyboard: true) }
            return true
        }
        if event.type == .keyDown, let entry = model.entries.first(where: {
            $0.activationShortcut?.keyCode == event.keyCode && $0.activationShortcut?.modifiers == flags
        }) {
            if !event.isARepeat { choose(entry.direction, fromKeyboard: true) }
            return true
        }
        if model.showingWindowManager {
            if event.type == .keyDown && event.isARepeat { return true }
            let fullScreen = tilingTarget?.isFullScreen() == true
            if event.type == .keyDown, let binding = configuration().windowManager?.shortcuts.first(where: {
                $0.shortcut.keyCode == event.keyCode && $0.shortcut.modifiers == flags
            }) {
                if !fullScreen || [.exitFullScreen, .toggleFullScreen].contains(binding.command) {
                    performWindowCommand(fullScreen ? .exitFullScreen : binding.command)
                }
                return true
            }
            guard !fullScreen else { return true }
            let previous = windowKeys.activeID
            let previousSettings = windowKeys.resolved(windowConfiguration)
            var handled = false
            switch event.type {
            case .keyDown: handled = windowKeys.press(key: event.keyCode, modifiers: flags, path: windowGroupPath, settings: windowConfiguration, bundleID: sourceBundleID)
            case .keyUp: windowKeys.release(key: event.keyCode)
            case .flagsChanged: windowKeys.updateModifiers(flags)
            default: return false
            }
            windowKeys.reconcile(windowConfiguration)
            if previous != windowKeys.activeID || previousSettings != windowKeys.resolved(windowConfiguration) {
                if previous == nil { baseWindowGroupPath = windowGroupPath }
                if windowKeys.activeID == nil { windowGroupPath = baseWindowGroupPath }
                else if windowKeys.activeScope?.isEmpty == true { windowGroupPath = [] }
                refreshGroup(); handled = true
            }
            return handled
        }
        let previous = heldKeys.activeID
        let previousSettings = heldKeys.resolved(configuration())
        var handled = false
        switch event.type {
        case .keyDown:
            // A held key must not activate a different tile after navigating back.
            if event.isARepeat { return true }
            handled = heldKeys.press(key: event.keyCode, modifiers: flags, path: layerScopePath, settings: configuration(), bundleID: sourceBundleID)
        case .keyUp: heldKeys.release(key: event.keyCode); handled = previous != heldKeys.activeID
        case .flagsChanged: heldKeys.updateModifiers(flags)
        default: return false
        }
        heldKeys.reconcile(configuration())
        if previous != heldKeys.activeID || previousSettings != heldKeys.resolved(configuration()) {
            if previous == nil { baseGroupPath = groupPath }
            if heldKeys.activeID == nil { groupPath = baseGroupPath }
            else if heldKeys.activeScope?.isEmpty == true && !model.showingWindowManager && !model.showingMediaControls { groupPath = [] }
            model.message = nil
            refreshGroup() // Drain any in-progress swipe before changing its targets.
        }
        return handled
    }

    private func updateCarouselContext(_ settings: AppExplorerSettings) {
        guard mapNavigationAvailable else {
            model.previousLayerName = nil
            model.nextLayerName = nil
            model.carouselPosition = nil
            model.carouselPreviews = []
            return
        }
        let map = settings.hudMap(in: sourceBundleID)
        guard let current = map.firstIndex(where: { $0.layerID == heldKeys.activeID }), map.count > 1 else {
            model.previousLayerName = nil
            model.nextLayerName = nil
            model.carouselPosition = nil
            model.carouselPreviews = []
            return
        }
        model.carouselPreviews = HUDCarouselPreview.makeMap(map, activeLayerID: heldKeys.activeID) { makeEntry($0, depth: 0) }
        model.carouselPreviews = model.carouselPreviews.map { preview in
            guard map.first(where: { $0.id == preview.id })?.builtIn == .recentApps else { return preview }
            return HUDCarouselPreview(id: preview.id, name: preview.name, offset: preview.offset,
                slotCount: preview.slotCount, entries: recentEntries(slotCount: preview.slotCount))
        }
        model.previousLayerName = orbitDestination(.previous)?.name
        model.nextLayerName = orbitDestination(.next)?.name
        model.carouselPosition = "\(current + 1) of \(map.count)"
    }

    private func orbitDestination(_ direction: HUDNavigationAction) -> HUDCarouselPreview? {
        guard let index = HUDMapPoint.nearestIndex(in: model.carouselPreviews.map(\.offset), toward: direction) else { return nil }
        return model.carouselPreviews[index]
    }

    private func loadEntries() {
        let original = configuration()
        if let builtIn = mappedBuiltIn {
            if builtIn == .mediaControls { model.showingMediaControls = true }
            if builtIn == .windowManager {
                model.showingWindowManager = true
                if tilingTarget == nil { tilingTarget = sourcePID.flatMap(captureWindow) }
            }
        }
        let dictionary = hotkeyDictionary()
        if entryCacheSettings != original || entryCacheDictionary != dictionary {
            entryCache.removeAll(keepingCapacity: true)
            entryCacheSettings = original
            entryCacheDictionary = dictionary
        }
        model.actionBindings = visibleActionBindings.map { binding in
            var display = binding
            if display.action.kind == .macro {
                display.action.name = dictionary.title(for: display.action)
            }
            return display
        }
        model.theme = original.resolvedTheme
        model.animationsEnabled = original.resolvedAnimationsEnabled
        updateCarouselContext(original)
        let layer = heldKeys.activeLayer(at: layerScopePath, in: original)
        let settings = heldKeys.resolved(original)
        model.layerName = layer?.name
        model.windowLayout = layer?.windowLayout ?? .halves
        model.layerHint = settings.layers(at: settings.layerScope(at: layerScopePath))
            .filter { $0.isAvailable(in: sourceBundleID) }
            .compactMap { layer in layer.holdShortcut.map { "\(layer.activation == .toggle ? "Press" : "Hold") \($0.displayName) → \(layer.name)" } }.joined(separator: " · ")
        model.mode = layer == nil ? settings.mode(holdingShortcut: alternateHeld) : .favorites
        if model.mode != .favorites || settings.favorites(at: groupPath) == nil { groupPath = [] }
        model.groupNames = groupPath.indices.compactMap { settings.favorite(at: Array(groupPath.prefix($0 + 1)))?.name }
        model.groupDirections = groupPath
        model.groupSlotCounts = groupPath.indices.map { settings.count(at: Array(groupPath.prefix($0))) }
        if model.showingAppWindows || model.showingMediaControls || (model.showingWindowManager && !model.directWindowManager),
           let controlDirection {
            model.groupDirections.append(controlDirection)
            model.groupSlotCounts.append(settings.count(at: groupPath))
        }
        let recentGroup = settings.favorite(at: groupPath)?.isRecentGroup == true || mappedBuiltIn == .recentApps
        model.showingRecents = model.mode == .recent || recentGroup
        model.canEdit = editingStore != nil && !model.showingAppWindows && !model.showingWindowManager && !model.showingMediaControls && layer == nil
        model.slotCount = settings.count(at: groupPath)
        if model.showingAppWindows {
            model.slotCount = 16
            model.groupNames.append("App windows")
            model.layerHint = ""
            model.page = windowPage; model.pageCount = max(1, (windowList.count + 15) / 16)
            model.entries = windowList.dropFirst(windowPage * 16).prefix(16).enumerated().map { offset, window in
                ExplorerEntry(direction: ExplorerSlot.slots(16)[offset], bundleID: nil,
                    name: window.title + (window.minimized ? " (minimized)" : ""), icon: nil, url: nil, windowIndex: windowPage * 16 + offset)
            }
            model.message = windowList.isEmpty ? "No accessible windows. Enable Accessibility and make sure the app is running." : nil
            return
        }
        if model.showingMediaControls {
            model.slotCount = 8
            model.groupNames.append("Media Controls")
            model.entries = ExplorerMediaAction.allCases.map { action in
                ExplorerEntry(direction: ExplorerSlot(action.direction), bundleID: nil, name: action.title, icon: nil, url: nil, mediaAction: action)
            }
            return
        }
        if model.showingWindowManager {
            let windowBase = windowConfiguration
            let window = windowKeys.resolved(windowBase)
            while !windowGroupPath.isEmpty && window.favorites(at: windowGroupPath) == nil { windowGroupPath.removeLast() }
            model.slotCount = window.count(at: windowGroupPath)
            let windowLayer = windowKeys.activeLayer(at: windowGroupPath, in: windowBase)
            model.windowLayout = windowLayer?.windowLayout ?? original.windowManager?.layout ?? .halves
            model.layerName = windowLayer?.name
            let wasFullScreen = model.windowFullScreen
            model.windowFullScreen = tilingTarget?.isFullScreen() == true
            if wasFullScreen && !model.windowFullScreen { model.message = nil }
            model.layerHint = model.windowFullScreen ? "" : window.layers(at: window.layerScope(at: windowGroupPath)).compactMap {
                guard $0.isAvailable(in: sourceBundleID), let key = $0.holdShortcut else { return nil }
                return "\($0.activation == .toggle ? "Press" : "Hold") \(key.displayName) → \($0.name)"
            }.joined(separator: " · ")
            model.groupNames.append("Window Manager")
            model.groupNames += windowGroupPath.indices.compactMap { window.favorite(at: Array(windowGroupPath.prefix($0 + 1)))?.name }
            model.groupDirections += windowGroupPath
            model.groupSlotCounts += windowGroupPath.indices.map { window.count(at: Array(windowGroupPath.prefix($0))) }
            model.canEdit = editingStore != nil && heldKeys.activeID == nil && windowKeys.activeID == nil && !model.windowFullScreen
            if model.windowFullScreen {
                model.entries = [ExplorerEntry(direction: .up, bundleID: nil, name: "Exit full screen", icon: nil, url: nil, command: .exitFullScreen)]
                model.message = "This window is full screen. Exit full screen to enable tiling."
                return
            }
            if window.favorite(at: windowGroupPath)?.isRecentGroup == true { loadRecentEntries(); return }
            model.entries = (window.favorites(at: windowGroupPath) ?? []).map { makeEntry($0, depth: windowGroupPath.count) }
            return
        }
        if model.mode == .favorites && !recentGroup {
            model.entries = (settings.favorites(at: groupPath) ?? []).map { makeEntry($0, depth: groupPath.count) }
            return
        }
        loadRecentEntries()
    }

    private func makeEntry(_ favorite: AppExplorerFavorite, depth: Int) -> ExplorerEntry {
        if let cached = entryCache.first(where: { $0.depth == depth && $0.favorite == favorite }) {
            return cached.entry
        }
        let entry = Self.makeEntry(favorite, depth: depth, dictionary: entryCacheDictionary, applicationURL: applicationURL)
        entryCache.append((favorite, depth, entry))
        return entry
    }

    /// Shared by the live HUD and its inert settings preview.
    static func makeEntry(_ favorite: AppExplorerFavorite, depth: Int, dictionary: [NamedHotkey],
                          applicationURL: (String) -> URL? = { ExplorerApplicationCatalog.applicationURL(for: $0) }) -> ExplorerEntry {
        func activated(_ entry: ExplorerEntry) -> ExplorerEntry {
            var entry = entry
            entry.activationShortcut = favorite.activationShortcut
            entry.hasDeepChoices = favorite.hasDeepChoices
            return entry
        }
        if let placement = favorite.windowPlacement {
            return activated(ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name,
                icon: nil, url: nil, tilingDirection: favorite.isValidDestination ? placement.direction : nil, tilingLayout: placement.layout))
        }
        if let action = favorite.action, action != .windowManager && action != .mediaControls {
            return activated(ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name, icon: nil, url: nil, command: action))
        }
        if favorite.action == .mediaControls {
            return activated(ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name, icon: nil, url: nil, isMediaControls: favorite.isValidDestination))
        }
        if let shortcut = favorite.shortcut {
            let title = dictionary.label(for: shortcut) == nil ? favorite.name : dictionary.title(for: shortcut)
            return activated(ExplorerEntry(direction: favorite.direction, bundleID: nil, name: title,
                icon: nil, url: nil, shortcut: favorite.isValidDestination ? shortcut : nil))
        }
        if favorite.isWindowManager {
            return activated(ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name,
                icon: nil, url: nil, isWindowManager: favorite.isValidDestination))
        }
        if favorite.isPureGroup {
            return activated(ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name,
                icon: nil, url: nil, isGroup: favorite.isValidDestination && depth < AppExplorerSettings.maximumGroupDepth,
                isRecentGroup: favorite.isRecentGroup))
        }
        if favorite.url != nil {
            return activated(ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name,
                icon: nil, url: favorite.isValidDestination ? favorite.resolvedWebURL : nil, isWebURL: true,
                webIconSymbol: favorite.iconSymbol))
        }
        let url = favorite.bundleID.flatMap(applicationURL)
        return activated(ExplorerEntry(direction: favorite.direction, bundleID: favorite.bundleID,
            name: favorite.name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }, url: url, showsWindows: favorite.showsWindows == true))
    }

    private func loadRecentEntries() {
        model.entries = recentEntries(slotCount: model.slotCount)
    }
    private func recentEntries(slotCount: Int) -> [ExplorerEntry] {
        let running = workspace.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.bundleIdentifier != "local.rotagivan"
        }.sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
        let active = running.first { $0.processIdentifier == sourcePID }?.bundleIdentifier
        let ordered = recents.activeFirst(available: running.compactMap(\.bundleIdentifier), active: active, limit: slotCount)
        let slots = ExplorerSlot.slots(slotCount).sorted { a, b in
            (a.angle + 180).truncatingRemainder(dividingBy: 360) < (b.angle + 180).truncatingRemainder(dividingBy: 360)
        }
        return ordered.compactMap { id in
            running.first { $0.bundleIdentifier == id && $0.processIdentifier == sourcePID }
                ?? running.first { $0.bundleIdentifier == id }
        }.enumerated().map {
            var entry = ExplorerEntry(direction: slots[$0.offset], app: $0.element)
            entry.isActiveApp = $0.element.processIdentifier == sourcePID
            return entry
        }
    }

    func process(_ report: TrackpadReport) {
        guard isVisible else { return }
        contactIsDown = report.contacts.contains(where: \.touching) || report.buttonDown
        guard contextIsValid?() != false else { dismiss(); return }
        guard !isEditing else { return }
        if !input.waitingForLift && processLocalGesture(report) { return }
        applySelection(report)
    }

    private func applySelection(_ report: TrackpadReport) {
        switch input.process(report) {
        case .waiting: break
        case .highlight(let direction):
            // Publish only a change of sector, not every hardware report.
            if model.selected != direction { model.selected = direction }
        case .deepen(let direction, let continuation): openDeepFan(direction, continuing: continuation)
        case .select(let direction):
            if model.deepFan == nil { choose(direction) } else { chooseDeep(direction) }
        case .back:
            if model.deepFan == nil { centerTap() } else { closeDeepFan() }
        case .cancel:
            if model.deepFan == nil { dismiss() } else { closeDeepFan() }
        }
    }

    private func makeSelection(waitingForLift: Bool) -> AppExplorerSelection {
        AppExplorerSelection(waitingForLift: waitingForLift, slotCount: model.slotCount,
            deepSlots: Set(model.entries.filter(\.hasDeepChoices).map(\.direction)))
    }

    private func openDeepFan(_ direction: ExplorerSlot, continuing: AppExplorerSelection.Continuation) {
        guard model.deepFan == nil, model.entries.first(where: { $0.direction == direction })?.hasDeepChoices == true else { return }
        let settings = model.showingWindowManager ? windowKeys.resolved(windowConfiguration) : heldKeys.resolved(configuration())
        let path = (model.showingWindowManager ? windowGroupPath : groupPath) + [direction]
        guard let parent = settings.favorite(at: path), let children = parent.children, !children.isEmpty else { return }
        let count = parent.slotCount ?? max(2, min(16, children.count))
        model.deepFan = ExplorerDeepFan(origin: direction, entries: children.map { makeEntry($0, depth: path.count) }, slotCount: count)
        model.selected = nil
        input = AppExplorerSelection(continuing: continuing, slotCount: count, fanOrigin: direction)
        deadline = Date().addingTimeInterval(15)
    }

    private func chooseDeep(_ direction: ExplorerSlot) {
        guard let fan = model.deepFan, fan.entries.contains(where: { $0.direction == direction }) else { closeDeepFan(); return }
        model.deepFan = nil
        if model.showingWindowManager { windowGroupPath.append(fan.origin) }
        else { groupPath.append(fan.origin) }
        loadEntries()
        model.selected = direction
        choose(direction)
    }

    private func closeDeepFan() {
        model.deepFan = nil
        model.selected = nil
        input = makeSelection(waitingForLift: contactIsDown)
    }

    private func resetLocalGesture() {
        model.orbitGeneration += 1
        model.orbitSettling = false
        model.orbitPosition = nil
        model.orbitTrigger = nil
        orbitDragUnit = .zero
        model.orbitOffset = .zero
        model.orbitProgress = 0
        localGestureTimer?.invalidate(); localGestureTimer = nil
        localGestureReports.removeAll()
        localGestureStrokeStart = 0
        localGestureTapCount = 0
        localGestureFingerCount = 0
        localGestureSequenceFingers = 0
        localGestureMaxTravel = 0
        localGesturePendingWindow = 0
        localGestureFollowupDelay = 0
        localGestureOrigin = nil
        localGestureFingerOrigins.removeAll()
        localGestureFingerLast.removeAll()
    }

    private func replayLocalGesture(from index: Int = 0) {
        let reports = Array(localGestureReports.dropFirst(index))
        resetLocalGesture()
        for report in reports where isVisible { applySelection(report) }
    }

    /// Recognize assigned HUD gestures before the HUD's sector-selection gate.
    /// Unassigned strokes are replayed through the original selection path.
    private func processLocalGesture(_ report: TrackpadReport) -> Bool {
        if model.orbitSettling { return true }
        var gestures = visibleActionBindings.filter { $0.trigger.gesture != nil && $0.isValid }
        if mapNavigationAvailable,
           (configuration().holdLayers ?? []).filter({ $0.isAvailable(in: sourceBundleID) }).count > 0 {
            let direction = configuration().resolvedSwipeDirection
            let defaults: [ActionBinding] = [AppGestureTrigger.twoFingerLeft, .twoFingerRight, .twoFingerUp, .twoFingerDown].map { trigger in
                ActionBinding(trigger: BindingTrigger(gesture: trigger),
                    action: .hudNavigation(direction.navigation(for: trigger)!))
            }
            gestures += defaults.filter { fallback in
                !gestures.contains { $0.trigger.identity == fallback.trigger.identity }
            }
        }
        guard !gestures.isEmpty else {
            if !localGestureReports.isEmpty { replayLocalGesture() }
            return false
        }
        let now = Date()
        let profile = gestureSettings()
        let contacts = report.contacts.filter(\.touching)
        guard !report.buttonDown, contacts.count <= 2, contacts.allSatisfy(\.confident) else {
            if model.orbitPosition != nil {
                resetLocalGesture(); input = makeSelection(waitingForLift: true); return true
            }
            replayLocalGesture(); return false
        }
        let needsOneFingerSequence = gestures.contains { binding in
            guard let base = binding.trigger.gesture?.baseTapTrigger else { return false }
            return base == .oneFingerTap || base == .oneFingerDoubleTap || base == .oneFingerTripleTap
        }
        // The built-in HUD carousel uses only two-finger swipes. Do not make
        // ordinary one-finger tile selection wait behind that recognizer.
        if localGestureReports.isEmpty, contacts.count <= 1, !needsOneFingerSequence { return false }
        let oneTapPairSwipe = localGestureSequenceFingers == 1 && localGestureTapCount == 1 &&
            gestures.contains { $0.trigger.gesture?.rawValue.hasPrefix("oneTapTwo.") == true }
        let joiningPair = (localGestureSequenceFingers == 2 || oneTapPairSwipe) && contacts.count == 1 &&
            (localGestureFingerCount == 0 ||
             (localGestureFingerCount == 1 && now.timeIntervalSince(localGestureStarted) <= 0.12))
        if localGestureTapCount > 0, !contacts.isEmpty,
           (now.timeIntervalSince(localGestureLastLift) > localGesturePendingWindow ||
            (contacts.count != localGestureSequenceFingers && !(oneTapPairSwipe && contacts.count == 2) && !joiningPair)) {
            let prior: AppGestureTrigger = localGestureSequenceFingers == 2
                ? (localGestureTapCount == 1 ? .twoFingerTap : .twoFingerDoubleTap)
                : (localGestureTapCount == 1 ? .oneFingerTap : .oneFingerDoubleTap)
            if let binding = gestures.first(where: { $0.trigger.gesture == prior }) {
                resetLocalGesture()
                performBoundAction(binding.action)
                return true
            }
            replayLocalGesture()
            if !isVisible { return true }
        }
        if localGestureReports.count >= 200 {
            if model.orbitPosition != nil { localGestureReports.removeSubrange(1..<100) }
            else { replayLocalGesture(); return false }
        }
        localGestureReports.append(report)
        if !contacts.isEmpty {
            let point = CGPoint(x: contacts.map(\.x).reduce(0, +) / Double(contacts.count),
                                y: contacts.map(\.y).reduce(0, +) / Double(contacts.count))
            if localGestureFingerCount == 0 {
                localGestureTimer?.invalidate(); localGestureTimer = nil
                localGestureStrokeStart = localGestureReports.count - 1
                localGestureFingerCount = contacts.count
                localGestureStarted = now
                localGestureFollowupDelay = localGestureTapCount > 0 ? now.timeIntervalSince(localGestureLastLift) : 0
                localGestureOrigin = point
                localGestureLast = point
                localGestureMaxTravel = 0
                localGestureFingerOrigins = Dictionary(uniqueKeysWithValues: contacts.map {
                    ($0.id, CGPoint(x: $0.x, y: $0.y))
                })
                localGestureFingerLast = localGestureFingerOrigins
            } else if contacts.count >= localGestureFingerCount {
                if localGestureFingerCount == 1 && contacts.count == 2 {
                    localGestureOrigin = point
                    localGestureFingerOrigins = Dictionary(uniqueKeysWithValues: contacts.map {
                        ($0.id, CGPoint(x: $0.x, y: $0.y))
                    })
                }
                localGestureFingerCount = contacts.count
                localGestureLast = point
                localGestureFingerLast = Dictionary(uniqueKeysWithValues: contacts.map {
                    ($0.id, CGPoint(x: $0.x, y: $0.y))
                })
                localGestureMaxTravel = max(localGestureMaxTravel, hypot(point.x - (localGestureOrigin?.x ?? point.x),
                    point.y - (localGestureOrigin?.y ?? point.y)))
            }
            if contacts.count == 2, localGestureTapCount == 0, let origin = localGestureOrigin {
                let dx = localGestureLast.x - origin.x, dy = localGestureLast.y - origin.y
                let trigger: AppGestureTrigger = abs(dx) >= abs(dy)
                    ? (dx < 0 ? .twoFingerLeft : .twoFingerRight)
                    : (dy < 0 ? .twoFingerUp : .twoFingerDown)
                if let binding = gestures.first(where: { $0.trigger.gesture == trigger }),
                   binding.action.kind == .hudNavigation, let assignedNavigation = binding.action.hudNavigation {
                    let explicit = visibleActionBindings.contains { $0.isValid && $0.trigger.gesture == trigger }
                    let navigation = explicit ? assignedNavigation : configuration().resolvedSwipeDirection.navigation(dx: dx, dy: dy)
                    let coherent = localGestureFingerOrigins.count == 2 && localGestureFingerOrigins.allSatisfy { id, start in
                        guard let end = localGestureFingerLast[id] else { return false }
                        return (end.x - start.x) * dx + (end.y - start.y) * dy > 0
                    }
                    if coherent, hypot(dx, dy) > 14, model.orbitPosition == nil {
                        let step = navigation.step
                        let diagonal = step.x != 0 && step.y != 0 && !explicit
                        orbitDragUnit = diagonal
                            ? CGPoint(x: dx < 0 ? -sqrt(0.5) : sqrt(0.5), y: dy < 0 ? -sqrt(0.5) : sqrt(0.5))
                            : (abs(dx) >= abs(dy) ? CGPoint(x: dx < 0 ? -1 : 1, y: 0) : CGPoint(x: 0, y: dy < 0 ? -1 : 1))
                        model.orbitOffset = orbitDestination(navigation)?.offset ?? step
                        model.orbitPosition = navigation
                        model.orbitTrigger = trigger
                    }
                }
                if let position = model.orbitPosition {
                    let distance = max(0, dx * orbitDragUnit.x + dy * orbitDragUnit.y)
                    let available = orbitDestination(position) != nil
                    // Empty cells resist the drag, then spring back on lift.
                    let progress = available ? min(1, distance / 180) : 0.12 * (1 - exp(-distance / 90))
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { model.orbitProgress = progress }
                    deadline = Date().addingTimeInterval(15)
                }
            }
            return true
        }
        if let position = model.orbitPosition {
            let target = orbitDestination(position)
            let commit = target != nil && model.orbitProgress >= 0.45
            let generation = model.orbitGeneration
            model.orbitSettling = true
            let animate = configuration().resolvedAnimationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let remaining = commit ? 1 - model.orbitProgress : model.orbitProgress
            let blocked = target == nil && model.orbitProgress > 0
            let settleDuration = animate ? (blocked ? 0.24 : 0.18 * remaining) : 0
            let settling: Animation? = settleDuration == 0 ? nil : (blocked
                ? .spring(duration: settleDuration, bounce: 0.18)
                : .easeOut(duration: settleDuration))
            withAnimation(settling) {
                model.orbitProgress = commit ? 1 : 0
            }
            let finish: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, self.isVisible, self.model.orbitGeneration == generation else { return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if commit, let target { self.switchLayer(UUID(uuidString: target.id)) }
                    else { self.resetLocalGesture(); self.input = self.makeSelection(waitingForLift: self.contactIsDown) }
                }
            }
            if settleDuration > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + settleDuration, execute: finish) }
            else { finish() }
            return true
        }
        guard localGestureFingerCount > 0, let origin = localGestureOrigin else { return true }
        let fingers = localGestureFingerCount
        if localGestureTapCount > 0 && fingers != localGestureSequenceFingers && !(oneTapPairSwipe && fingers == 2) {
            replayLocalGesture()
            return true
        }
        let dx = localGestureLast.x - origin.x, dy = localGestureLast.y - origin.y
        let duration = now.timeIntervalSince(localGestureStarted)
        let swipeSettings: DoubleTapSwipeSettings? = fingers == 2
            ? (oneTapPairSwipe ? profile.oneFingerTapTwoFingerSwipe :
               localGestureTapCount == 1 ? profile.twoFingerSingleTapSwipe : profile.twoFingerDoubleTapSwipe)
            : (localGestureTapCount == 1 ? profile.singleTapSwipe : profile.doubleTapSwipe)
        let swipeDistance = localGestureTapCount == 0 && fingers == 2 ? 80 : (swipeSettings?.resolvedDistance ?? 60)
        let swipeDuration = localGestureTapCount == 0 ? 0.35 : (swipeSettings?.resolvedFastDuration ?? 0.18)
        localGestureFingerCount = 0
        localGestureOrigin = nil
        localGestureLastLift = now
        let coherentPair = fingers != 2 || (localGestureFingerOrigins.count == 2 &&
            localGestureFingerOrigins.allSatisfy { id, start in
                guard let end = localGestureFingerLast[id] else { return false }
                let fingerDX = end.x - start.x, fingerDY = end.y - start.y
                return hypot(fingerDX, fingerDY) >= min(40, swipeDistance / 2) &&
                    fingerDX * dx + fingerDY * dy > 0
            })
        if duration <= swipeDuration, hypot(dx, dy) >= swipeDistance, coherentPair,
           (localGestureTapCount == 0 || localGestureFollowupDelay <= (swipeSettings?.resolvedWindow ?? 0.2)),
           let direction = SwipeDirection.classify(dx: dx, dy: dy) {
            let trigger: AppGestureTrigger?
            if fingers == 2 && localGestureTapCount == 0 {
                switch direction {
                case .left: trigger = .twoFingerLeft
                case .right: trigger = .twoFingerRight
                case .up: trigger = .twoFingerUp
                case .down: trigger = .twoFingerDown
                default: trigger = nil
                }
            } else if oneTapPairSwipe && fingers == 2 {
                trigger = .combining(tap: .oneFingerTap, direction: direction, swipeFingers: 2)
            } else {
                let base: AppGestureTrigger = fingers == 2
                    ? (localGestureTapCount == 1 ? .twoFingerTap : .twoFingerDoubleTap)
                    : (localGestureTapCount == 1 ? .oneFingerTap : .oneFingerDoubleTap)
                trigger = localGestureTapCount > 0 ? .combining(tap: base, direction: direction) : nil
            }
            if let trigger, let binding = gestures.first(where: { $0.trigger.gesture == trigger }) {
                resetLocalGesture()
                performBoundAction(binding.action)
                return true
            }
            replayLocalGesture(from: localGestureStrokeStart)
            return true
        }
        guard duration <= profile.gestures.tapMaxDuration,
              localGestureMaxTravel <= profile.gestures.tapMaxMovement else {
            replayLocalGesture(from: localGestureStrokeStart)
            return true
        }
        if oneTapPairSwipe && fingers == 2 {
            if let binding = gestures.first(where: { $0.trigger.gesture == .oneFingerTap }) {
                resetLocalGesture()
                performBoundAction(binding.action)
            } else { replayLocalGesture() }
            return true
        }
        localGestureTapCount += 1
        if localGestureTapCount == 1 { localGestureSequenceFingers = fingers }
        let trigger: AppGestureTrigger = fingers == 2
            ? (localGestureTapCount == 1 ? .twoFingerTap : localGestureTapCount == 2 ? .twoFingerDoubleTap : .twoFingerTripleTap)
            : (localGestureTapCount == 1 ? .oneFingerTap : localGestureTapCount == 2 ? .oneFingerDoubleTap : .oneFingerTripleTap)
        let later = gestures.contains { binding in
            guard let candidate = binding.trigger.gesture else { return false }
            return candidate.baseTapTrigger.map { base in
                fingers == 2 ? [.twoFingerTap, .twoFingerDoubleTap, .twoFingerTripleTap].contains(base)
                             : [.oneFingerTap, .oneFingerDoubleTap, .oneFingerTripleTap].contains(base)
            } == true && (candidate.direction != nil ||
                (localGestureTapCount == 1 && [.oneFingerDoubleTap, .oneFingerTripleTap, .twoFingerDoubleTap, .twoFingerTripleTap].contains(candidate)) ||
                (localGestureTapCount == 2 && [.oneFingerTripleTap, .twoFingerTripleTap].contains(candidate)))
        }
        if !later, let binding = gestures.first(where: { $0.trigger.gesture == trigger }) {
            resetLocalGesture()
            performBoundAction(binding.action)
            return true
        }
        let swipeWindow = fingers == 2
            ? (localGestureTapCount == 1 ? profile.twoFingerSingleTapSwipe?.resolvedWindow : profile.twoFingerDoubleTapSwipe?.resolvedWindow)
            : (localGestureTapCount == 1
                ? max(profile.singleTapSwipe?.resolvedWindow ?? 0,
                      profile.oneFingerTapTwoFingerSwipe?.resolvedWindow ?? 0)
                : profile.doubleTapSwipe?.resolvedWindow)
        let hasSwipeFollowup = gestures.contains { $0.trigger.gesture?.baseTapTrigger == trigger && $0.trigger.gesture?.direction != nil }
        let hasTapFollowup = gestures.contains { binding in
            guard let candidate = binding.trigger.gesture else { return false }
            if localGestureTapCount == 1 {
                return fingers == 2 ? [.twoFingerDoubleTap, .twoFingerTripleTap].contains(candidate)
                                    : [.oneFingerDoubleTap, .oneFingerTripleTap].contains(candidate)
            }
            return localGestureTapCount == 2 && (fingers == 2 ? candidate == .twoFingerTripleTap : candidate == .oneFingerTripleTap)
        }
        let tapWindow = localGestureTapCount == 1
            ? (gestures.contains { $0.trigger.gesture == (fingers == 2 ? .twoFingerTripleTap : .oneFingerTripleTap) }
                ? profile.gestures.resolvedTripleTapFirstInterval : profile.gestures.resolvedDoubleTapInterval)
            : profile.gestures.resolvedTripleTapSecondInterval
        localGesturePendingWindow = max(hasSwipeFollowup ? (swipeWindow ?? 0.2) : 0,
                                        hasTapFollowup ? tapWindow : 0)
        if localGesturePendingWindow == 0, let binding = gestures.first(where: { $0.trigger.gesture == trigger }) {
            resetLocalGesture(); performBoundAction(binding.action); return true
        }
        if localGesturePendingWindow == 0 { replayLocalGesture(); return true }
        localGestureTimer?.invalidate()
        let generation = selectionGeneration
        let timer = Timer(timeInterval: localGesturePendingWindow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.selectionGeneration == generation else { return }
                if let binding = self.visibleActionBindings.first(where: { $0.trigger.gesture == trigger && $0.isValid }) {
                    self.resetLocalGesture()
                    self.performBoundAction(binding.action)
                } else { self.replayLocalGesture() }
            }
        }
        localGestureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    private func choose(_ direction: ExplorerSlot, fromKeyboard: Bool = false) {
        guard isVisible, !isEditing else { return }
        guard contextIsValid?() != false else { dismiss(); return }
        let entry = model.entries.first { $0.direction == direction }
        if model.showingWindowManager && model.windowFullScreen && entry?.command != .exitFullScreen {
            input = makeSelection(waitingForLift: contactIsDown)
            model.selected = nil; return
        }
        if let index = entry?.windowIndex, windowList.indices.contains(index) {
            let window = windowList[index]
            let originalPID = sourcePID
            dismiss()
            let generation = selectionGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation, self.contextIsValid?() != false,
                      self.frontmostPID() == originalPID else { return }
                if let error = window.activate() { Self.showWindowError(error) }
            }
            return
        }
        if entry?.showsWindows == true {
            let pid = entry?.bundleID.flatMap { id in workspace.runningApplications.first { $0.bundleIdentifier == id && !$0.isTerminated }?.processIdentifier } ?? (entry?.showsWindows == true ? nil : sourcePID)
            controlDirection = direction
            windowList = pid.map(listWindows) ?? []; windowPage = 0
            model.showingAppWindows = true
            refreshGroup(); return
        }
        if let command = entry?.command, command.macOSShortcut == nil,
           let message = command.shortcutSetupMessage {
            model.message = message
            return
        }
        if let command = entry?.command, command.macOSShortcut != nil {
            let originalPID = sourcePID
            dismiss()
            let generation = selectionGeneration
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.selectionGeneration == generation,
                          self.contextIsValid?() != false, self.frontmostPID() == originalPID else { return }
                    self.performMacCommand(command)
                }
            }
            return
        }
        if let command = entry?.command { performWindowCommand(command); return }
        if let media = entry?.mediaAction {
            performMedia(media)
            model.selected = nil
            input = AppExplorerSelection(waitingForLift: contactIsDown)
            deadline = Date().addingTimeInterval(15)
            return
        }
        if entry?.isMediaControls == true {
            controlDirection = direction
            model.showingMediaControls = true
            refreshGroup()
            return
        }
        if let tile = entry?.tilingDirection {
            if tilingTarget == nil, let sourcePID { tilingTarget = captureWindow(sourcePID) }
            let error = tilingTarget.map { $0.apply(tile, entry?.tilingLayout ?? model.windowLayout) } ?? "No controllable window. Enable Accessibility and open Explorer over a normal app window."
            if let error {
                model.message = error
                model.selected = nil
                input = makeSelection(waitingForLift: contactIsDown)
                deadline = Date().addingTimeInterval(15)
            } else { dismiss() }
            return
        }
        if entry?.isWindowManager == true {
            windowKeys = ExplorerScopedHeldKeys()
            windowGroupPath = []; baseWindowGroupPath = []
            windowOwnerPath = groupPath + [direction]
            controlDirection = direction
            model.showingWindowManager = true
            tilingTarget = sourcePID.flatMap(captureWindow)
            model.message = tilingTarget == nil ? "No controllable window. Enable Accessibility and open Explorer over a normal app window." : nil
            refreshGroup()
            return
        }
        if entry?.isGroup == true {
            if model.showingWindowManager { windowGroupPath.append(direction) }
            else { groupPath.append(direction) }
            refreshGroup()
            return
        }
        if let action = entry?.shortcut?.assignedAction {
            performBoundAction(action, fromKeyboard: fromKeyboard)
            return
        }
        if let shortcut = entry?.shortcut, let id = shortcut.hudLayerID {
            guard shortcut.isValidExplorerShortcut, let layer = configuration().holdLayers?.first(where: { $0.id == id }),
                  layer.isAvailable(in: sourceBundleID) else { refreshGroup(); return }
            heldKeys.selectRootLayer(id, settings: configuration())
            groupPath = []; baseGroupPath = []
            model.showingMediaControls = false; model.showingWindowManager = false; model.showingAppWindows = false
            refreshGroup()
            return
        }
        dismiss()
        guard let entry else { return }
        if let shortcut = entry.shortcut {
            guard shortcut.isValidExplorerShortcut, let targetPID = sourcePID else { return }
            let generation = selectionGeneration
            // Close the HUD before sending keys; cancel if focus or context changes.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                guard let self, self.selectionGeneration == generation,
                      self.contextIsValid?() != false, self.frontmostPID() == targetPID else { return }
                if let sendShortcut = self.sendShortcut { sendShortcut(shortcut) }
                else if let id = shortcut.macroID {
                    if let macro = self.hotkeyDictionary().first(where: { $0.id == id }) { self.shortcutPoster.performMacro(macro) }
                } else { self.shortcutPoster.performTap(.shortcut, shortcut: shortcut) }
                }
            }
            return
        }
        if entry.isWebURL {
            if let url = entry.url, AppExplorerFavorite.webURL(url.absoluteString) != nil { _ = openWebURL(url) }
            return
        }
        guard let identifier = entry.bundleID else { return }
        // Prefer the actual running bundle when multiple installations exist.
        let running = workspace.runningApplications.first { $0.bundleIdentifier == identifier && !$0.isTerminated }
        guard let url = running?.bundleURL ?? entry.url ?? applicationURL(identifier) else { return }
        let generation = selectionGeneration
        let center = configuration().resolvedCenterCursorOnAppSwitch
        let configurationID = editingStore?.activeConfigurationID
        // Dismissal has restored/unhidden the original pointer before capture.
        let cursorOrigin = cursorPosition()
        // A nonactivating panel restores focus as it closes. Submit the user's
        // activation on the next main-loop turn, after that teardown finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectionGeneration == generation, self.contextIsValid?() != false else { return }
            self.openApplication(url, Self.activationConfiguration()) { [weak self] pid in
                guard let self, let pid,
                      self.selectionGeneration == generation, !self.isVisible,
                      self.contextIsValid?() != false,
                      self.editingStore?.settings.enabled != false,
                      self.editingStore?.activeConfigurationID == configurationID else { return }
                // Activating the process alone can leave its window on another
                // Space. Focus/raise its actual window independently of cursor warping.
                self.focusApplicationWindow(pid)
                guard center else { return }
                let isValid: () -> Bool = { [weak self] in
                    guard let self else { return false }
                    return self.selectionGeneration == generation && !self.isVisible &&
                        self.configuration().resolvedCenterCursorOnAppSwitch &&
                        self.editingStore?.settings.enabled != false &&
                        self.editingStore?.activeConfigurationID == configurationID
                }
                guard isValid() else { return }
                if let centerApplication = self.centerApplication { centerApplication(pid, cursorOrigin, isValid) }
                else { self.cursorCentering.start(pid: pid, origin: cursorOrigin, isValid: isValid) }
            }
        }
    }

    private func performWindowCommand(_ command: AppExplorerAction) {
        guard isVisible, !isEditing, contextIsValid?() != false else { return }
        if tilingTarget == nil, let sourcePID { tilingTarget = captureWindow(sourcePID) }
        guard let target = tilingTarget else {
            model.message = "No controllable window. Enable Accessibility and open Explorer over a window."; return
        }
        if target.isFullScreen() && command != .exitFullScreen && command != .toggleFullScreen {
            refreshGroup(); return
        }
        if let error = target.command(command) { model.message = error }
        else { dismiss() }
    }

    static func showWindowError(_ message: String, title: String = "Window unavailable") {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.runModal()
    }

    private func changeWindowPage(_ delta: Int) {
        guard model.showingAppWindows else { return }
        windowPage = max(0, min(max(0, (windowList.count - 1) / 16), windowPage + delta))
        refreshGroup()
    }

    func centerTap() {
        guard isVisible, !isEditing else { return }
        guard contextIsValid?() != false else { dismiss(); return }
        guard model.showingMediaControls else { goBack(); return }
        performMedia(.playPause)
        model.selected = nil
        input = makeSelection(waitingForLift: contactIsDown)
        deadline = Date().addingTimeInterval(15)
    }

    func goBack() {
        guard isVisible, !isEditing else { return }
        if mappedBuiltIn != nil {
            guard contextIsValid?() != false else { dismiss(); return }
            switchLayer(nil)
            return
        }
        if model.showingAppWindows {
            model.showingAppWindows = false; windowList = []; windowPage = 0; controlDirection = model.showingWindowManager ? windowOwnerPath?.last : nil
            model.message = nil; refreshGroup(); return
        }
        if model.showingMediaControls {
            guard contextIsValid?() != false else { dismiss(); return }
            model.showingMediaControls = false
            controlDirection = model.showingWindowManager ? windowOwnerPath?.last : nil
            heldKeys.leave(to: groupPath)
            refreshGroup()
            return
        }
        if model.showingWindowManager {
            guard contextIsValid?() != false else { dismiss(); return }
            if !windowGroupPath.isEmpty {
                windowGroupPath.removeLast(); windowKeys.leave(to: windowGroupPath)
                refreshGroup(); return
            }
            if model.directWindowManager { dismiss(); return }
            model.showingWindowManager = false
            windowKeys = ExplorerScopedHeldKeys()
            windowOwnerPath = nil
            controlDirection = nil
            heldKeys.leave(to: groupPath)
            model.message = nil
            tilingTarget = nil
            refreshGroup()
            return
        }
        guard contextIsValid?() != false, !groupPath.isEmpty else { dismiss(); return }
        groupPath.removeLast()
        heldKeys.leave(to: groupPath)
        refreshGroup()
    }

    private func refreshGroup() {
        resetLocalGesture()
        selectionGeneration &+= 1
        model.deepFan = nil
        loadEntries()
        model.selected = nil
        input = makeSelection(waitingForLift: contactIsDown)
        deadline = Date().addingTimeInterval(15)
    }

    func openSettings() {
        guard isVisible, !isEditing, contextIsValid?() != false else { return }
        dismiss()
        // Restore the pointer and tear down the HUD before activating settings.
        DispatchQueue.main.async { [weak self] in self?.onSettings?() }
    }

    func beginEditing() {
        guard let store = editingStore, let previous = panel, !isEditing, !model.showingAppWindows, !model.showingMediaControls, heldKeys.activeID == nil, windowKeys.activeID == nil, !(model.showingWindowManager && model.windowFullScreen),
              contextIsValid?() != false else { return }
        selectionGeneration &+= 1
        model.isEditing = true
        model.selected = nil
        onPresentationChanged?()
        onEditingChanged?(true)
        // Use an activating panel for text fields and native picker sheets.
        // Recreate it in place; toggling NSPanel's nonactivating style at runtime
        // can leave AppKit's key-focus behavior inconsistent.
        let frame = previous.frame
        let previousScreen = previous.screen
        let visibleFrame = (previousScreen ?? NSScreen.main)?.visibleFrame
        let editorWidth = min(ExplorerInlineEditor.preferredWidth, (visibleFrame?.width ?? 792) - 32)
        let editorHeight = min(980, (visibleFrame?.height ?? 1012) - 32)
        previous.onCancel = nil
        previous.orderOut(nil); previous.close()
        let editor = ExplorerPanel(contentRect: NSRect(x: frame.midX - editorWidth / 2, y: frame.midY - editorHeight / 2,
            width: editorWidth, height: editorHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        editor.title = "Edit App Explorer"
        editor.isOpaque = false; editor.backgroundColor = .clear; editor.hasShadow = true
        editor.level = .floating; editor.hidesOnDeactivate = false
        editor.allowsEditing = true
        editor.onCancel = { [weak self] in self?.dismiss() }
        let editingWindows = model.showingWindowManager
        let owner = windowOwnerPath ?? []
        var expected = store.settings.appExplorer ?? AppExplorerSettings()
        let windowBinding = Binding<AppExplorerSettings>(get: {
            (store.settings.appExplorer ?? AppExplorerSettings()).windowEditor(at: owner)
        }, set: { updated in
            var next = store.settings.appExplorer ?? AppExplorerSettings()
            guard next == expected, next.saveWindowEditor(updated, at: owner) else { return }
            store.settings.appExplorer = next; expected = next
        })
        editor.contentView = NSHostingView(rootView: ExplorerInlineEditor(store: store, groupPath: editingWindows ? windowGroupPath : groupPath,
            onGroupPathChange: { [weak self] path in
                if editingWindows { self?.windowGroupPath = path } else { self?.groupPath = path }
            }, onDone: { [weak self] in self?.finishEditing() },
            configurationOverride: editingWindows ? windowBinding : nil, windowManagerOnly: editingWindows,
            windowOwnerPath: inlineEditorWindowOwnerPath,
            contentWidth: editorWidth, contentHeight: editorHeight))
        if let visible = visibleFrame {
            editor.setFrameOrigin(NSPoint(x: max(visible.minX, min(editor.frame.minX, visible.maxX - editorWidth)),
                                          y: max(visible.minY, min(editor.frame.minY, visible.maxY - editorHeight))))
        }
        panel = editor
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        NSApp.activate()
        editor.makeKeyAndOrderFront(nil)
    }

    func finishEditing() {
        guard isEditing else { return }
        let path = groupPath
        let windowPath = windowGroupPath, owner = windowOwnerPath
        let wasWindow = model.showingWindowManager, direct = model.directWindowManager
        let originalPID = sourcePID, originalTarget = tilingTarget
        let waitingForLift = contactIsDown
        dismiss()
        if wasWindow, let originalPID { _ = NSRunningApplication(processIdentifier: originalPID)?.activate(options: []) }
        show(waitingForLift: waitingForLift)
        if wasWindow {
            sourcePID = originalPID; tilingTarget = originalTarget
            model.showingWindowManager = true; model.directWindowManager = direct
            groupPath = path; windowGroupPath = windowPath; windowOwnerPath = owner
            controlDirection = owner?.last
            refreshGroup(); return
        }
        if model.mode == .favorites, configuration().favorites(at: path) != nil {
            groupPath = path
            refreshGroup()
        }
    }

    static func activationConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        configuration.hidesOthers = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = true
        return configuration
    }

    func dismiss() {
        entryCache.removeAll(keepingCapacity: true)
        entryCacheSettings = nil
        resetLocalGesture()
        guard let panel else { return }
        selectionGeneration &+= 1
        self.panel = nil
        onPresentationChanged?()
        if model.isEditing { model.isEditing = false; onEditingChanged?(false) }
        panel.orderOut(nil)
        panel.close()
        timer?.invalidate(); timer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        model.selected = nil
        groupPath = []
        model.groupNames = []
        model.groupDirections = []
        model.groupSlotCounts = []
        model.showingAppWindows = false
        windowList = []; windowPage = 0; windowKeys = ExplorerScopedHeldKeys()
        windowGroupPath = []; baseWindowGroupPath = []; windowOwnerPath = nil
        model.showingWindowManager = false
        model.directWindowManager = false
        model.showingMediaControls = false
        heldKeys = ExplorerScopedHeldKeys()
        baseGroupPath = []
        model.message = nil
        tilingTarget = nil
        onDismiss?()
    }
}

final class ExplorerPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onSettings: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var allowsEditing = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); if !allowsEditing { onCancel?() } }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Recorded Command-key chords must reach the applet before menu-bar
        // commands (for example Cmd-M) can act on Rotagivan's own window.
        if !allowsEditing, onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if allowsEditing { super.keyDown(with: event); return }
        if onKey?(event) == true { return }
        if event.keyCode == 1, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onSettings?(); return
        }
        if event.keyCode == 53 { onCancel?() }
        // Do not leak typing into the application behind the HUD.
    }
    override func keyUp(with event: NSEvent) {
        if allowsEditing { super.keyUp(with: event) } else { _ = onKey?(event) }
    }
    override func flagsChanged(with event: NSEvent) {
        if allowsEditing { super.flagsChanged(with: event) } else { _ = onKey?(event) }
    }
}

struct ExplorerEntry: Equatable {
    var isActiveApp = false
    var direction: ExplorerSlot
    var bundleID: String?
    var name: String
    var icon: NSImage?
    var url: URL?
    var isWebURL: Bool
    var webIconSymbol: String?
    var isGroup: Bool
    var hasDeepChoices: Bool
    var isRecentGroup: Bool
    var isWindowManager: Bool
    var tilingDirection: SwipeDirection?
    var tilingLayout: ExplorerWindowLayout?
    var shortcut: RecordedShortcut?
    var activationShortcut: RecordedShortcut?
    var isMediaControls: Bool
    var mediaAction: ExplorerMediaAction?
    var command: AppExplorerAction?
    var showsWindows: Bool
    var windowIndex: Int?
    init(direction: ExplorerSlot, bundleID: String?, name: String, icon: NSImage?, url: URL?, isWebURL: Bool = false, webIconSymbol: String? = nil, isGroup: Bool = false, hasDeepChoices: Bool = false, isRecentGroup: Bool = false, isWindowManager: Bool = false, tilingDirection: SwipeDirection? = nil, shortcut: RecordedShortcut? = nil, activationShortcut: RecordedShortcut? = nil, isMediaControls: Bool = false, mediaAction: ExplorerMediaAction? = nil, command: AppExplorerAction? = nil, showsWindows: Bool = false, windowIndex: Int? = nil, tilingLayout: ExplorerWindowLayout? = nil) {
        self.direction = direction; self.bundleID = bundleID; self.name = name; self.icon = icon; self.url = url
        self.isWebURL = isWebURL
        self.webIconSymbol = webIconSymbol
        self.isGroup = isGroup
        self.hasDeepChoices = hasDeepChoices
        self.isRecentGroup = isRecentGroup
        self.isWindowManager = isWindowManager
        self.tilingDirection = tilingDirection
        self.tilingLayout = tilingLayout
        self.shortcut = shortcut
        self.activationShortcut = activationShortcut
        self.isMediaControls = isMediaControls
        self.mediaAction = mediaAction
        self.command = command; self.showsWindows = showsWindows; self.windowIndex = windowIndex
    }
    init(direction: ExplorerSlot, app: NSRunningApplication) {
        self.init(direction: direction, bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "Application", icon: app.icon, url: app.bundleURL)
    }
}

struct HUDCarouselPreview: Identifiable {
    let id: String
    let name: String
    let offset: HUDMapPoint
    let slotCount: Int
    let entries: [ExplorerEntry]

    static func makeMap(_ map: [HUDMapNode], activeLayerID: UUID?,
                        makeEntry: (AppExplorerFavorite) -> ExplorerEntry) -> [Self] {
        guard let origin = map.first(where: { $0.layerID == activeLayerID })?.point else { return [] }
        return map.filter { $0.layerID != activeLayerID }.map { node in
            Self(id: node.id, name: node.name, offset: node.point - origin,
                slotCount: node.slotCount, entries: node.builtIn == .mediaControls
                    ? ExplorerMediaAction.allCases.map {
                        ExplorerEntry(direction: ExplorerSlot($0.direction), bundleID: nil, name: $0.title,
                            icon: nil, url: nil, mediaAction: $0)
                    } : node.favorites.map(makeEntry))
        }
    }
}

struct ExplorerDeepFan {
    let origin: ExplorerSlot
    let entries: [ExplorerEntry]
    let slotCount: Int
}

private struct ExplorerDeepFanSector: Shape {
    let angle: Double
    let innerRadius: Double
    let outerRadius: Double
    let halfAngle: Double
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.degrees(angle - halfAngle), end = Angle.degrees(angle + halfAngle)
        func point(_ value: Angle, radius: Double) -> CGPoint {
            CGPoint(x: center.x + cos(value.radians) * radius, y: center.y + sin(value.radians) * radius)
        }
        var path = Path()
        path.move(to: point(start, radius: innerRadius))
        path.addLine(to: point(start, radius: outerRadius))
        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addLine(to: point(end, radius: innerRadius))
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Both faces use the same HUD renderer; only their position on the orbit differs.
private struct HUDOrbitSatellite: View, Equatable {
    let preview: HUDCarouselPreview
    let theme: ExplorerTheme
    @StateObject private var model: ExplorerModel

    init(preview: HUDCarouselPreview, theme: ExplorerTheme) {
        self.preview = preview
        self.theme = theme
        _model = StateObject(wrappedValue: Self.prepare(preview: preview, theme: theme))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.theme == rhs.theme && lhs.preview.id == rhs.preview.id &&
        lhs.preview.name == rhs.preview.name && lhs.preview.slotCount == rhs.preview.slotCount &&
        lhs.preview.entries == rhs.preview.entries
    }

    // StateObject evaluates this lazily, once per satellite identity, not once
    // per gesture update. The orbit transform remains outside this cached face.
    private static func prepare(preview: HUDCarouselPreview, theme: ExplorerTheme) -> ExplorerModel {
        let prepared = ExplorerModel()
        prepared.entries = preview.entries
        prepared.theme = theme
        prepared.slotCount = preview.slotCount
        prepared.layerName = preview.name
        prepared.animationsEnabled = false
        return prepared
    }
    var body: some View {
        AnyView(AppExplorerView(model: model, onSelect: { _ in }, onCancel: {},
            forceReduceMotion: true, isPreview: true, showsCarousel: false))
            .frame(width: 470, height: 520)
            .allowsHitTesting(false)
            .onChange(of: theme) { _, _ in refresh() }
            .onChange(of: preview.name) { _, _ in refresh() }
            .onChange(of: preview.slotCount) { _, _ in refresh() }
            .onChange(of: preview.entries) { _, _ in refresh() }
    }
    private func refresh() {
        model.entries = preview.entries
        model.theme = theme
        model.slotCount = preview.slotCount
        model.layerName = preview.name
        model.animationsEnabled = false
    }
}

/// Move the camera across a fixed map. Every face stays front-on; only uniform
/// scale, brightness and position convey distance. Endpoints are identical to
/// the next active HUD's coordinates, so committing cannot re-pack the map.
struct HUDMapProjection {
    let x: Double
    let y: Double
    var scale: Double { 1 / (1 + 0.8 * (x * x + y * y)) }
    var offsetX: Double { tanh(x * log(2)) * 475 }
    var offsetY: Double { -tanh(y * log(2)) * 385 }
    var brightness: Double { -0.18 * (1 - scale) }
    var opacity: Double { 0.76 + 0.24 * scale }
}

private struct HUDOrbitTransform: ViewModifier, Animatable {
    var x: Double
    var y: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(x, y) }
        set { x = newValue.first; y = newValue.second }
    }
    func body(content: Content) -> some View {
        let projection = HUDMapProjection(x: x, y: y)
        content
            .scaleEffect(projection.scale)
            .brightness(projection.brightness)
            .opacity(projection.opacity)
            .offset(x: projection.offsetX, y: projection.offsetY)
    }
}

@MainActor final class ExplorerModel: ObservableObject {
    // MRU starts at the left and proceeds clockwise. Positions freeze on open.
    static let directions = AppExplorerSettings.recentDirections
    @Published var entries: [ExplorerEntry] = []
    @Published var actionBindings: [ActionBinding] = []
    @Published var selected: ExplorerSlot?
    @Published var deepFan: ExplorerDeepFan?
    @Published var mode: AppExplorerMode = .favorites
    @Published var groupNames: [String] = []
    @Published var groupDirections: [ExplorerSlot] = []
    @Published var groupSlotCounts: [Int] = []
    @Published var canEdit = false
    @Published var isEditing = false
    @Published var showingRecents = false
    @Published var showingWindowManager = false
    @Published var directWindowManager = false
    @Published var message: String?
    @Published var showingMediaControls = false
    @Published var layerName: String?
    @Published var previousLayerName: String?
    @Published var nextLayerName: String?
    @Published var carouselPreviews: [HUDCarouselPreview] = []
    @Published var orbitPosition: HUDNavigationAction?
    // Track the physical stroke independently of its chosen navigation action.
    var orbitTrigger: AppGestureTrigger?
    @Published var orbitOffset: HUDMapPoint = .zero
    @Published var orbitProgress = 0.0
    var orbitSettling = false
    var orbitGeneration = 0
    @Published var carouselPosition: String?
    @Published var layerHint = ""
    @Published var windowLayout: ExplorerWindowLayout = .halves
    @Published var theme: ExplorerTheme = .starburstAir
    @Published var animationsEnabled = true
    @Published var slotCount = 8
    @Published var windowFullScreen = false
    @Published var showingAppWindows = false
    @Published var page = 0
    @Published var pageCount = 1
}

struct AppExplorerView: View {
    @ObservedObject var model: ExplorerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var reticleRotation = -135.0
    var onSelect: (ExplorerSlot) -> Void
    var onCancel: () -> Void
    var onDeepSelect: (ExplorerSlot) -> Void = { _ in }
    var onBack: () -> Void = {}
    var onSettings: () -> Void = {}
    var onWindowCommand: (AppExplorerAction) -> Void = { _ in }
    var onWindowPage: (Int) -> Void = { _ in }
    // Previews/tests may enforce reduced motion; they cannot override macOS's
    // accessibility preference in the opposite direction.
    var forceReduceMotion = false
    var forceReduceTransparency = false
    var isPreview = false
    var showsCarousel = true
    var onPreviewDrag: (ExplorerSlot, ExplorerSlot?) -> Void = { _, _ in }
    var onPreviewDrop: (ExplorerSlot, ExplorerSlot?) -> Void = { _, _ in }
    private let grid: [[ExplorerSlot?]] = [[.topLeft, .up, .topRight], [.left, nil, .right], [.bottomLeft, .down, .bottomRight]]
    private var canGoBack: Bool { model.directWindowManager ? model.groupNames.count > 1 : !model.groupNames.isEmpty }
    private var animates: Bool {
        ExplorerHUDMotion.enabled(theme: model.theme, preference: model.animationsEnabled,
            reduceMotion: reduceMotion || forceReduceMotion)
    }
    private var feedback: Animation? { animates ? .easeOut(duration: 0.12) : nil }
    private var accent: Color { model.theme.accent }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var opaqueChrome: Bool { reduceTransparency || forceReduceTransparency }
    private var guidance: String {
        if let message = model.message { return message }
        if let slot = model.selected, model.slotCount > 8,
           let entry = model.entries.first(where: { $0.direction == slot }) { return "\(entry.name) · lift to choose" }
        if model.showingAppWindows { return "Swipe to raise a window · ←/→ pages · center tap to go back" }
        if model.showingMediaControls { return "Tap to play / pause · swipe to control · Esc to close" }
        if model.showingWindowManager { return "Swipe to choose · lift to run · center tap to \(canGoBack ? "go back" : "close")" }
        if model.entries.isEmpty { return model.showingRecents ? "Open another app to see it here" : "Add favorites to get started" }
        return model.groupNames.isEmpty ? "Swipe to choose · lift to open" : "\(model.groupNames.last!) · swipe to choose · tap center to go back"
    }

    var body: some View {
        VStack(spacing: 18) {
            if model.showingWindowManager && model.windowFullScreen {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 48, weight: .light)).foregroundStyle(accent)
                    Button("Exit full screen") { onWindowCommand(.exitFullScreen) }.buttonStyle(.borderedProminent)
                    Text("Swipe up to exit full screen").font(.caption).foregroundStyle(.secondary)
                }.frame(height: 260)
                    .background { if model.theme.isFloating { Circle().fill(model.theme.surface.opacity(opaqueChrome ? 1 : 0.9)) } }
            } else if model.theme.isRadial || model.slotCount != 8 {
                starburst
            } else {
            VStack(spacing: 8) {
                ForEach(0..<3) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3) { column in
                            if let direction = grid[row][column] { tile(direction) }
                            else {
                                Button(action: onBack) {
                                    VStack(spacing: 7) {
                                        if model.theme.isHUD && model.showingWindowManager {
                                            let selected = model.entries.first { $0.direction == model.selected }
                                            ExplorerLayoutPreview(direction: selected?.tilingDirection, layout: selected?.tilingLayout ?? model.windowLayout, accent: accent)
                                        } else {
                                            ZStack {
                                                if model.theme.isHUD {
                                                    Circle().stroke(accent.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [2, 5])).frame(width: 57, height: 57)
                                                    Circle().trim(from: 0.04, to: 0.26).stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                                        .frame(width: 57, height: 57)
                                                        .rotationEffect(.degrees(reticleRotation))
                                                }
                                                Image(systemName: model.showingMediaControls ? "playpause.fill" : (canGoBack ? "arrow.uturn.backward" : (model.directWindowManager ? "xmark.circle" : "safari")))
                                                    .font(.system(size: 30, weight: .light)).foregroundStyle(accent)
                                            }.frame(height: model.theme.isHUD ? 57 : 30)
                                        }
                                        Text(model.showingMediaControls ? "Tap to play / pause" : (canGoBack ? "Tap to go back" : "Tap to close"))
                                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                    }.frame(width: 130, height: 98).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(model.showingMediaControls ? "Play / pause" : (canGoBack ? "Back to previous HUD layer" : "Close \(model.directWindowManager ? "Window Manager" : "HUD")"))
                            }
                        }
                    }
                }
            }
            }
        }
        .padding(26)
        .frame(width: 470, height: 520)
        .background(ExplorerHUDBackdrop(theme: model.theme, forceReduceTransparency: forceReduceTransparency))
        .tint(accent)
        .environment(\.colorScheme, model.theme.isHUD ? .dark : colorScheme)
        .scaleEffect(animates && !appeared ? 0.985 : 1)
        .opacity(animates && !appeared ? 0.85 : 1)
        .onAppear {
            reticleRotation = reticleAngle(model.selected)
            withAnimation(animates ? .easeOut(duration: 0.16) : nil) { appeared = true }
        }
        .onReceive(model.$selected.removeDuplicates()) { direction in
            withAnimation(feedback) {
                reticleRotation = ExplorerHUDMotion.nearestAngle(from: reticleRotation, to: reticleAngle(direction))
            }
        }
        .transaction { if !animates { $0.animation = nil } }
        .help(guidance)
        .overlay(alignment: .bottom) {
            if !showsCarousel {
                Text(model.layerName ?? "Main HUD")
                    .font(.caption.weight(.medium)).foregroundStyle(accent)
                    .padding(.bottom, 80)
            }
        }
        .modifier(HUDOrbitTransform(x: -cameraX, y: -cameraY))
        .offset(y: showsCarousel ? -38 : 0)
        .frame(width: 950, height: 850)
        .background { if showsCarousel { carouselBackdrop.offset(y: -38) } }
        .overlay(alignment: .bottom) {
            if showsCarousel {
                ScrollView(.vertical, showsIndicators: false) {
                    fixedHUDControls
                }
                .frame(width: 440, height: 72, alignment: .top)
                .padding(.bottom, 6)
                .tint(accent)
                .environment(\.colorScheme, model.theme.isHUD ? .dark : colorScheme)
                .transaction { $0.animation = nil }
            }
        }

    }

    private var fixedHUDControls: some View {
        VStack(spacing: 6) {
            settingsFooter
            if !layerActionHotkeys.isEmpty || !model.actionBindings.isEmpty {
                layerActionHotkeyFooter.frame(height: 30)
            }
            if !isPreview, let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            if model.showingAppWindows {
                HStack {
                    Button("Previous") { onWindowPage(-1) }.disabled(model.page == 0)
                    Text("Page \(model.page + 1) / \(model.pageCount)").font(.caption)
                    Button("Next") { onWindowPage(1) }.disabled(model.page + 1 >= model.pageCount)
                }.background { if model.theme.isFloating { Capsule().fill(model.theme.surface.opacity(opaqueChrome ? 1 : 0.9)).padding(-6) } }
            }
            if !model.layerHint.isEmpty {
                Text(model.layerHint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .background { if model.theme.isFloating { Capsule().fill(model.theme.surface.opacity(opaqueChrome ? 1 : 0.9)).padding(-5) } }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var carouselBackdrop: some View {
        ZStack {
            ForEach(model.carouselPreviews) { preview in
                carouselGhost(preview)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var cameraX: Double { animates ? Double(model.orbitOffset.x) * model.orbitProgress : 0 }
    private var cameraY: Double { animates ? Double(model.orbitOffset.y) * model.orbitProgress : 0 }

    private func carouselGhost(_ preview: HUDCarouselPreview) -> some View {
        HUDOrbitSatellite(preview: preview, theme: model.theme)
            .equatable()
            .modifier(HUDOrbitTransform(x: Double(preview.offset.x) - cameraX,
                y: Double(preview.offset.y) - cameraY))
            .zIndex(-Double(preview.offset.x * preview.offset.x + preview.offset.y * preview.offset.y))
    }

    private var settingsFooter: some View {
        HStack(spacing: 4) {
            Text("HUD: \(model.groupNames.last ?? model.layerName ?? "Main HUD")")
                .lineLimit(1).truncationMode(.middle)
            Text("·")
            Text("Press")
            footerKey("S", help: "Open HUD settings", identifier: "explorer-settings", action: onSettings)
            Text("for settings")
            if let position = model.carouselPosition {
                Text("· \(position)").monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule().fill(model.theme.isHUD ? model.theme.surface.opacity(model.theme.isFloating && !opaqueChrome ? 0.9 : 1) : Color(nsColor: .controlBackgroundColor))
                .overlay(Capsule().strokeBorder(accent.opacity(0.24), lineWidth: 0.7))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Press S for settings")
    }

    private var layerActionHotkeys: [ExplorerEntry] {
        model.entries.filter { $0.activationShortcut != nil }
    }

    private var layerActionHotkeyFooter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(layerActionHotkeys, id: \.direction) { entry in
                    HStack(spacing: 5) {
                        Text(entry.activationShortcut!.displayName)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                        Text(entry.name).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.09)))
                }
                ForEach(model.actionBindings) { binding in
                    HStack(spacing: 5) {
                        Text(binding.trigger.title)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                        Text(binding.action.title).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.09)))
                }
            }
        }
        .frame(maxWidth: 390)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hotkeys for actions in this HUD layer")
    }

    private func footerKey(_ key: String, help: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .frame(minWidth: 18, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent.opacity(0.45), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .disabled(isPreview || (key == "E" && !model.canEdit))
        .help(help)
        .accessibilityIdentifier(identifier)
    }

    private var starburst: some View {
        let names = model.directWindowManager ? Array(model.groupNames.dropFirst()) : model.groupNames
        let depth = min(5, names.count)
        let center = CGPoint(x: 209, y: 155)
        return ZStack {
            if model.theme.isFloating {
                ExplorerAirGlass(opaque: opaqueChrome).frame(width: 304, height: 304).position(center)
            }
            // Each completed level leaves a concentric breadcrumb. The lit
            // sector records the direction taken at that level, not a guess
            // based on a group's name (duplicate names are allowed).
            ForEach(0..<depth, id: \.self) { level in
                let radius = ExplorerStarburstLayout.ringRadius(level)
                let direction = model.groupDirections.indices.contains(level) ? model.groupDirections[level] : nil
                let count = model.groupSlotCounts.indices.contains(level) ? model.groupSlotCounts[level] : 8
                ForEach(ExplorerSlot.slots(count), id: \.self) { sector in
                    ExplorerStarburstSector(direction: sector, innerRadius: radius, outerRadius: radius + 6, halfAngle: 180 / Double(count) - 2)
                        .fill(direction == sector ? (model.theme.isFloating ? Color(red: 1, green: 0.77, blue: 0.40) : accent).opacity(0.95 - Double(level) * 0.1) : accent.opacity(model.theme.isFloating ? 0.3 : 0.12))
                        .frame(width: 418, height: 310)
                        .accessibilityHidden(true)
                }
                .transition(.opacity)
            }
            ForEach(ExplorerSlot.slots(model.slotCount), id: \.self) { direction in
                starburstChoice(direction, depth: depth, center: center)
            }
            if let fan = model.deepFan { deepFan(fan) }
            Button(action: onBack) {
                VStack(spacing: 3) {
                    Image(systemName: model.showingMediaControls ? "playpause.fill" : (canGoBack ? "arrow.uturn.backward" : "xmark"))
                        .font(.system(size: 13, weight: .medium))
                    Text(String(format: "%02d", depth + 1))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(model.theme.isFloating ? Color(red: 1, green: 0.83, blue: 0.54) : accent)
                .frame(width: 54, height: 54)
                .background(Circle().fill(model.theme.surface.opacity(model.theme.isFloating && !opaqueChrome ? 0.88 : 1)))
                .overlay(Circle().strokeBorder(model.theme.isFloating ? Color(red: 1, green: 0.78, blue: 0.43) : accent.opacity(0.45),
                    lineWidth: model.theme.isFloating ? 1.5 : 1))
                .shadow(color: model.theme.isFloating ? Color.orange.opacity(0.28) : .clear, radius: 4)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .position(center)
            .help(model.showingMediaControls ? "Tap to play / pause" : (canGoBack ? "Level \(depth + 1) · Tap to go back" : "Level 1 · Tap to close"))
            .accessibilityLabel("\(model.showingMediaControls ? "Play / pause" : (canGoBack ? "Back to previous HUD layer" : "Close HUD")). Level \(depth + 1). \(([model.mode.title] + names).joined(separator: ", "))")
        }
        .frame(width: 418, height: 310)
        .animation(feedback, value: names)
    }

    private func starburstChoice(_ direction: ExplorerSlot, depth: Int, center: CGPoint) -> some View {
        let entry = model.entries.first { $0.direction == direction }
        let available = isAvailable(entry)
        let selected = model.deepFan == nil && model.selected == direction && available
        let shape = ExplorerStarburstSector(direction: direction,
            innerRadius: ExplorerStarburstLayout.innerRadius(depth: depth), outerRadius: 143, tip: model.theme.isFloating ? 2 : 11,
            halfAngle: 180 / Double(model.slotCount) - 2, roundedRim: model.theme.isFloating)
        let point = ExplorerStarburstLayout.point(direction, radius: model.slotCount > 8 ? 128 : 116, center: center)
        return Button { onSelect(direction) } label: {
            ZStack {
                if model.theme.isFloating {
                    ExplorerAirSectorChrome(shape: shape, selected: selected, available: available, opaque: opaqueChrome)
                    Circle().trim(from: 0, to: (360 / Double(model.slotCount) - 8) / 360)
                        .stroke(accent.opacity(selected ? 1 : available ? 0.5 : 0.15), style: StrokeStyle(lineWidth: selected ? 2 : 0.75, lineCap: .round))
                        .frame(width: 294, height: 294)
                        .rotationEffect(.degrees(direction.angle - 180 / Double(model.slotCount) + 4))
                        .position(center)
                        .allowsHitTesting(false)
                } else {
                    shape.fill(LinearGradient(colors: [accent.opacity(selected ? 0.38 : 0.08),
                        accent.opacity(selected ? 0.18 : 0.025)], startPoint: .top, endPoint: .bottom))
                    shape.stroke(accent.opacity(selected ? 0.95 : available ? 0.35 : 0.12), lineWidth: selected ? 1.5 : 0.75)
                }
                if entry?.isActiveApp == true {
                    shape.stroke(Color.orange, lineWidth: 2)
                        .allowsHitTesting(false)
                }
                VStack(spacing: 3) {
                    if let entry {
                        entrySymbol(entry).scaleEffect(model.slotCount > 8 ? 0.43 : 0.55).frame(width: 24, height: model.slotCount > 8 ? 18 : 24)
                        Text(entry.name).font(.system(size: model.slotCount > 8 ? 8 : 9, weight: model.theme.isFloating ? .semibold : .medium))
                            .lineLimit(entry.shortcut == nil ? 2 : 3).multilineTextAlignment(.center)
                        if entry.isActiveApp {
                            Text("ACTIVE").font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Color.orange)
                        }
                        if entry.hasDeepChoices {
                            Image(systemName: "chevron.forward.2")
                                .font(.system(size: 7, weight: .bold)).foregroundStyle(accent)
                                .rotationEffect(.degrees(direction.angle))
                        }
                    } else {
                        Image(systemName: "plus").font(.system(size: 13, weight: .ultraLight)).foregroundStyle(.tertiary)
                        Text(direction.title).font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: model.slotCount > 8 ? 45 : (model.theme.isFloating ? 68 : 78), height: model.slotCount > 8 ? 40 : 50)
                .foregroundStyle(model.theme.isHUD ? (selected ? Color.white : Color.white.opacity(0.85)) : Color.primary)
                .shadow(color: model.theme.isFloating ? .black.opacity(0.8) : .clear, radius: 1, y: 1)
                .position(point)
            }
            .frame(width: 418, height: 310)
            .contentShape(shape)
        }
        .buttonStyle(.plain).disabled(!available)
        .modifier(ExplorerSectorFocus(theme: model.theme, shape: shape))
        .modifier(previewDrag(direction))
        .anchorPreference(key: ExplorerTileAnchors.self, value: .rect(CGRect(x: point.x - 26, y: point.y - 24, width: 52, height: 48))) {
            isPreview ? [direction: $0] : [:]
        }
        .help(entry?.isWebURL == true ? (entry?.url?.absoluteString ?? "Invalid URL") : (entry?.name ?? "Empty slot"))
        .accessibilityLabel("\(direction.title): \(entry?.name ?? "Empty slot")\(entry?.isActiveApp == true ? ", Active app" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(feedback, value: selected)
    }

    private func deepFan(_ fan: ExplorerDeepFan) -> some View {
        let width = DeepSwipeFan.span(count: fan.slotCount) / Double(fan.slotCount)
        let fanCenter = CGPoint(x: 209, y: 195)
        let originPoint = CGPoint(x: 0.5 + cos(fan.origin.angle * .pi / 180) * 0.34,
                                  y: 0.5 + sin(fan.origin.angle * .pi / 180) * 0.44)
        return ZStack {
            ForEach(ExplorerSlot.slots(fan.slotCount), id: \.self) { slot in
                let angle = DeepSwipeFan.angle(for: slot, count: fan.slotCount, origin: fan.origin)
                let entry = fan.entries.first { $0.direction == slot }
                let selected = model.selected == slot && entry != nil
                let shape = ExplorerDeepFanSector(angle: angle, innerRadius: 147, outerRadius: 205,
                    halfAngle: max(3, width / 2 - 1.2))
                let radians = angle * .pi / 180
                let point = CGPoint(x: fanCenter.x + cos(radians) * 176, y: fanCenter.y + sin(radians) * 176)
                Button { onDeepSelect(slot) } label: {
                    ZStack {
                        shape.fill(accent.opacity(selected ? 0.40 : entry == nil ? 0.035 : 0.15))
                        shape.stroke(accent.opacity(selected ? 1 : entry == nil ? 0.12 : 0.58),
                            lineWidth: selected ? 1.8 : 0.8)
                        VStack(spacing: 2) {
                            if let entry {
                                entrySymbol(entry).scaleEffect(0.38).frame(width: 20, height: 17)
                                Text(entry.name).font(.system(size: 7, weight: .semibold)).lineLimit(2)
                            } else {
                                Image(systemName: "plus").font(.system(size: 9, weight: .light)).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 42, height: 34)
                        .position(point)
                    }
                    .frame(width: 418, height: 390)
                    .contentShape(shape)
                }
                .buttonStyle(.plain).disabled(entry == nil)
                .accessibilityLabel("Deep choice: \(entry?.name ?? "Empty slot")")
            }
        }
        .frame(width: 418, height: 390)
        .transition(animates
            ? .scale(scale: 0.92, anchor: UnitPoint(x: originPoint.x, y: originPoint.y)).combined(with: .opacity)
            : .identity)
        .animation(animates ? .easeOut(duration: 0.18) : nil, value: fan.origin)
        .zIndex(4)
    }

    private func isAvailable(_ entry: ExplorerEntry?) -> Bool {
        if isPreview { return true }
        guard let entry else { return false }
        return entry.url != nil || entry.isGroup || entry.isWindowManager || entry.tilingDirection != nil ||
            entry.shortcut != nil || entry.isMediaControls || entry.mediaAction != nil || entry.command != nil || entry.windowIndex != nil
    }

    @ViewBuilder private func entrySymbol(_ entry: ExplorerEntry) -> some View {
        if let command = entry.command {
            Image(systemName: command.symbol).font(.system(size: 30, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if entry.windowIndex != nil {
            Image(systemName: "macwindow").font(.system(size: 30, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if entry.isMediaControls || entry.mediaAction != nil {
            Image(systemName: entry.mediaAction?.symbol ?? "speaker.wave.2.fill").font(.system(size: 30, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if entry.shortcut != nil {
            Image(systemName: "keyboard").font(.system(size: 30, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if let direction = entry.tilingDirection {
            WindowTileIcon(direction: direction, layout: entry.tilingLayout ?? model.windowLayout, accent: accent)
        } else if entry.isWindowManager {
            Image(systemName: "rectangle.split.2x2").font(.system(size: 34, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if entry.isGroup {
            Image(systemName: entry.isRecentGroup ? "clock.arrow.circlepath" : "folder.fill").font(.system(size: 34, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if entry.isWebURL {
            WebsiteFavicon(url: entry.url, size: 42, symbolName: entry.webIconSymbol)
        } else {
            Image(nsImage: entry.icon ?? NSImage(named: NSImage.applicationIconName)!).resizable().scaledToFit().frame(width: 42, height: 42)
        }
    }

    private func reticleAngle(_ direction: ExplorerSlot?) -> Double {
        (direction?.angle ?? -90) - 45
    }

    private func tile(_ direction: ExplorerSlot) -> some View {
        let entry = model.entries.first { $0.direction == direction }
        let available = isAvailable(entry)
        let selected = model.selected == direction && available
        return Button { onSelect(direction) } label: {
            VStack(spacing: 5) {
                if let entry {
                    entrySymbol(entry)
                    Text(entry.name).font(.system(size: 11, weight: .medium)).lineLimit(entry.shortcut == nil ? 1 : 2)
                    if entry.isActiveApp {
                        Text("ACTIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.orange)
                    }
                    if let shortcut = entry.shortcut {
                        if !entry.name.hasSuffix("(\(shortcut.readableCombination))") { Text(shortcut.displayName).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    else if entry.isGroup { Text(entry.isRecentGroup ? "Recent apps" : "HUD layer").font(.system(size: 9)).foregroundStyle(.secondary) }
                    else if entry.isWindowManager { Text("Swipe to tile").font(.system(size: 9)).foregroundStyle(.secondary) }
                    else if entry.url == nil && entry.tilingDirection == nil && !entry.isMediaControls && entry.mediaAction == nil && entry.command == nil { Text(entry.isWebURL ? "Invalid URL" : "Not installed").font(.system(size: 9)).foregroundStyle(.secondary) }
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                }
                Text(selected && model.theme.isHUD ? "\(direction.title.uppercased()) · READY" : direction.title)
                    .font(.system(size: 9, weight: .medium, design: model.theme.isHUD ? .monospaced : .default))
                    .foregroundStyle(selected ? accent : .secondary)
            }
            .frame(width: 130, height: 98)
            .background(ExplorerTileChrome(theme: model.theme, selected: selected, occupied: entry != nil))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(
                entry?.isActiveApp == true ? Color.orange : .clear, lineWidth: 2))
            .scaleEffect(selected && model.theme.isHUD ? 1.025 : 1)
            .animation(feedback, value: selected)
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain).disabled(!available)
        .modifier(previewDrag(direction))
        .help(entry?.isWebURL == true ? (entry?.url?.absoluteString ?? "Invalid URL") : (entry?.name ?? "Empty slot"))
        .accessibilityLabel("\(direction.title): \(entry?.name ?? "No app")\(entry?.isActiveApp == true ? ", Active app" : "")")
        .anchorPreference(key: ExplorerTileAnchors.self, value: .bounds) { isPreview ? [direction: $0] : [:] }
    }

    private func previewDrag(_ direction: ExplorerSlot) -> ExplorerPreviewDrag {
        ExplorerPreviewDrag(enabled: isPreview && !model.showingRecents && model.entries.contains { $0.direction == direction },
            source: direction, theme: model.theme, count: model.slotCount, depth: model.groupNames.count,
            onChanged: onPreviewDrag, onEnded: onPreviewDrop)
    }
}
