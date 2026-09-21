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
    func process(_ report: TrackpadReport)
    func dismiss()
    func setAlternateHeld(_ held: Bool)
}
extension AppExplorerPresenting {
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
    private let model = ExplorerModel()
    private var sourcePID: pid_t?
    private let shortcutPoster = EventPoster()
    var sendShortcut: ((RecordedShortcut) -> Void)?
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    private var deadline = Date.distantPast
    private var alternateHeld = false
    private var heldKeys = ExplorerScopedHeldKeys()
    private var baseGroupPath: [SwipeDirection] = []
    var performMedia: (ExplorerMediaAction) -> Void = { ExplorerMediaAction.perform($0) }
    private(set) var groupPath: [SwipeDirection] = []
    private var contactIsDown = false
    private var selectionGeneration: UInt64 = 0
    private let cursorCentering = ExplorerCursorCentering()
    var cursorPosition: () -> CGPoint? = { CGEvent(source: nil)?.location }
    var centerApplication: ((pid_t, CGPoint?, @escaping () -> Bool) -> Void)?
    private var tilingTarget: WindowTilingTarget?
    private var controlDirection: SwipeDirection?
    var captureWindow: (pid_t) -> WindowTilingTarget? = { WindowTiling.capture(pid: $0) }
    var configuration: () -> AppExplorerSettings = { AppExplorerSettings() }
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
    var onPresentationChanged: (() -> Void)?
    var contextIsValid: (() -> Bool)?
    weak var editingStore: SettingsStore?
    var onEditingChanged: ((Bool) -> Void)?
    var isVisible: Bool { panel != nil }
    var isEditing: Bool { model.isEditing }
    var displayedEntries: [ExplorerEntry] { model.entries }
    var displayedLevelDirections: [SwipeDirection] { model.groupDirections }

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

    func showWindowManager(waitingForLift: Bool) {
        show(waitingForLift: waitingForLift, windowManager: true)
    }

    private func show(waitingForLift: Bool, windowManager: Bool) {
        guard !isVisible else { return }
        cursorCentering.cancel()
        selectionGeneration &+= 1
        groupPath = []
        heldKeys = ExplorerScopedHeldKeys()
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
        input = AppExplorerSelection(waitingForLift: waitingForLift)
        let panel = ExplorerPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 464),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "App Explorer"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.onEdit = { [weak self] in self?.beginEditing() }
        panel.onKey = { [weak self] in self?.processLayerKey($0) ?? false }
        panel.contentView = NSHostingView(rootView: AppExplorerView(model: model,
            onSelect: { [weak self] in self?.choose($0) }, onCancel: { [weak self] in self?.dismiss() },
            onBack: { [weak self] in self?.goBack() }, onEdit: { [weak self] in self?.beginEditing() }))
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

    private var layerScopePath: [SwipeDirection] {
        if (model.showingWindowManager && !model.directWindowManager) || model.showingMediaControls,
           let controlDirection { return groupPath + [controlDirection] }
        return groupPath
    }

    @discardableResult func processLayerKey(_ event: NSEvent) -> Bool {
        guard isVisible, !isEditing, contextIsValid?() != false else { return false }
        let previous = heldKeys.activeID
        let previousSettings = heldKeys.resolved(configuration())
        let flags = UInt64(event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
        var handled = false
        switch event.type {
        case .keyDown:
            // A held key must not activate a different tile after navigating back.
            if event.isARepeat { return true }
            handled = heldKeys.press(key: event.keyCode, modifiers: flags, path: layerScopePath, settings: configuration())
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

    private func loadEntries() {
        let original = configuration()
        model.theme = original.resolvedTheme
        model.animationsEnabled = original.resolvedAnimationsEnabled
        let layer = heldKeys.activeLayer(at: layerScopePath, in: original)
        let settings = heldKeys.resolved(original)
        model.layerName = layer?.name
        model.windowLayout = layer?.windowLayout ?? .halves
        model.layerHint = settings.layers(at: settings.layerScope(at: layerScopePath))
            .compactMap { layer in layer.holdShortcut.map { "\($0.displayName): \(layer.name)" } }.joined(separator: " · ")
        model.mode = layer == nil ? settings.mode(holdingShortcut: alternateHeld) : .favorites
        if model.mode != .favorites || settings.favorites(at: groupPath) == nil { groupPath = [] }
        model.groupNames = groupPath.indices.compactMap { settings.favorite(at: Array(groupPath.prefix($0 + 1)))?.name }
        model.groupDirections = groupPath
        if model.showingMediaControls || (model.showingWindowManager && !model.directWindowManager),
           let controlDirection { model.groupDirections.append(controlDirection) }
        let recentGroup = settings.favorite(at: groupPath)?.isRecentGroup == true
        model.showingRecents = model.mode == .recent || recentGroup
        model.canEdit = editingStore != nil && !model.showingWindowManager && !model.showingMediaControls && layer == nil
        if model.showingMediaControls {
            model.groupNames.append("Media Controls")
            model.entries = ExplorerMediaAction.allCases.map { action in
                ExplorerEntry(direction: action.direction, bundleID: nil, name: action.title, icon: nil, url: nil, mediaAction: action)
            }
            return
        }
        if model.showingWindowManager {
            model.groupNames.append("Window Manager")
            model.entries = SwipeDirection.allCases.map { direction in
                ExplorerEntry(direction: direction, bundleID: nil, name: WindowTile.title(direction, layout: model.windowLayout),
                    icon: nil, url: nil, tilingDirection: direction)
            }
            return
        }
        if model.mode == .favorites && !recentGroup {
            model.entries = (settings.favorites(at: groupPath) ?? []).map { favorite in
                if favorite.action == .mediaControls {
                    return ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name, icon: nil, url: nil, isMediaControls: favorite.isValidDestination)
                }
                if let shortcut = favorite.shortcut {
                    return ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name,
                        icon: nil, url: nil, shortcut: favorite.isValidDestination ? shortcut : nil)
                }
                if favorite.isWindowManager {
                    return ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name,
                        icon: nil, url: nil, isWindowManager: favorite.isValidDestination)
                }
                if favorite.isGroup {
                    return ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name,
                        icon: nil, url: nil, isGroup: favorite.isValidDestination && groupPath.count < AppExplorerSettings.maximumGroupDepth,
                        isRecentGroup: favorite.isRecentGroup)
                }
                if favorite.url != nil {
                    return ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name,
                        icon: nil, url: favorite.isValidDestination ? favorite.resolvedWebURL : nil, isWebURL: true)
                }
                let url = favorite.bundleID.flatMap(applicationURL)
                return ExplorerEntry(direction: favorite.direction, bundleID: favorite.bundleID,
                    name: favorite.name, icon: url.map { workspace.icon(forFile: $0.path) }, url: url)
            }
            return
        }
        let running = workspace.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.processIdentifier != sourcePID &&
            $0.bundleIdentifier != "local.rotagivan"
        }.sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
        let ordered = recents.ordered(available: running.compactMap(\.bundleIdentifier), excluding: [])
        model.entries = ordered.compactMap { id in running.first { $0.bundleIdentifier == id } }.enumerated().map {
            ExplorerEntry(direction: ExplorerModel.directions[$0.offset], app: $0.element)
        }
    }

    func process(_ report: TrackpadReport) {
        guard isVisible else { return }
        contactIsDown = report.contacts.contains(where: \.touching) || report.buttonDown
        guard contextIsValid?() != false else { dismiss(); return }
        guard !isEditing else { return }
        switch input.process(report) {
        case .waiting: break
        case .highlight(let direction):
            // Publish only a change of sector, not every hardware report.
            if model.selected != direction { model.selected = direction }
        case .select(let direction): choose(direction)
        case .back: goBack()
        case .cancel: dismiss()
        }
    }

    private func choose(_ direction: SwipeDirection) {
        guard isVisible, !isEditing else { return }
        guard contextIsValid?() != false else { dismiss(); return }
        let entry = model.entries.first { $0.direction == direction }
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
            let error = tilingTarget.map { $0.apply(tile, model.windowLayout) } ?? "No controllable window. Enable Accessibility and open Explorer over a normal app window."
            if let error {
                model.message = error
                model.selected = nil
                input = AppExplorerSelection(waitingForLift: contactIsDown)
                deadline = Date().addingTimeInterval(15)
            } else { dismiss() }
            return
        }
        if entry?.isWindowManager == true {
            controlDirection = direction
            model.showingWindowManager = true
            tilingTarget = sourcePID.flatMap(captureWindow)
            model.message = tilingTarget == nil ? "No controllable window. Enable Accessibility and open Explorer over a normal app window." : nil
            refreshGroup()
            return
        }
        if entry?.isGroup == true {
            groupPath.append(direction)
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
                else { self.shortcutPoster.performTap(.shortcut, shortcut: shortcut) }
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
                guard let self, let pid, center else { return }
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

    func goBack() {
        guard isVisible, !isEditing else { return }
        if model.showingMediaControls {
            guard contextIsValid?() != false else { dismiss(); return }
            model.showingMediaControls = false
            controlDirection = nil
            heldKeys.leave(to: groupPath)
            refreshGroup()
            return
        }
        if model.showingWindowManager {
            guard contextIsValid?() != false else { dismiss(); return }
            if model.directWindowManager { dismiss(); return }
            model.showingWindowManager = false
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
        selectionGeneration &+= 1
        loadEntries()
        model.selected = nil
        input = AppExplorerSelection(waitingForLift: contactIsDown)
        deadline = Date().addingTimeInterval(15)
    }

    func beginEditing() {
        guard let store = editingStore, let previous = panel, !isEditing, !model.showingWindowManager, !model.showingMediaControls, heldKeys.activeID == nil,
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
        previous.onCancel = nil
        previous.orderOut(nil); previous.close()
        let editor = ExplorerPanel(contentRect: NSRect(x: frame.midX - 340, y: frame.midY - 250, width: 680, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        editor.title = "Edit App Explorer"
        editor.isOpaque = false; editor.backgroundColor = .clear; editor.hasShadow = true
        editor.level = .floating; editor.hidesOnDeactivate = false
        editor.allowsEditing = true
        editor.onCancel = { [weak self] in self?.dismiss() }
        editor.contentView = NSHostingView(rootView: ExplorerInlineEditor(store: store, groupPath: groupPath,
            onGroupPathChange: { [weak self] in self?.groupPath = $0 }, onDone: { [weak self] in self?.finishEditing() }))
        if let screen = previousScreen ?? NSScreen.main {
            let visible = screen.visibleFrame
            editor.setFrameOrigin(NSPoint(x: max(visible.minX, min(editor.frame.minX, visible.maxX - 680)),
                                          y: max(visible.minY, min(editor.frame.minY, visible.maxY - 500))))
        }
        panel = editor
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        NSApp.activate()
        editor.makeKeyAndOrderFront(nil)
    }

    func finishEditing() {
        guard isEditing else { return }
        let path = groupPath
        let waitingForLift = contactIsDown
        dismiss()
        show(waitingForLift: waitingForLift)
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

private final class ExplorerPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onEdit: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var allowsEditing = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); if !allowsEditing { onCancel?() } }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if allowsEditing { super.keyDown(with: event); return }
        if onKey?(event) == true { return }
        if event.keyCode == 14, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onEdit?(); return
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

struct ExplorerEntry {
    var direction: SwipeDirection
    var bundleID: String?
    var name: String
    var icon: NSImage?
    var url: URL?
    var isWebURL: Bool
    var isGroup: Bool
    var isRecentGroup: Bool
    var isWindowManager: Bool
    var tilingDirection: SwipeDirection?
    var shortcut: RecordedShortcut?
    var isMediaControls: Bool
    var mediaAction: ExplorerMediaAction?
    init(direction: SwipeDirection, bundleID: String?, name: String, icon: NSImage?, url: URL?, isWebURL: Bool = false, isGroup: Bool = false, isRecentGroup: Bool = false, isWindowManager: Bool = false, tilingDirection: SwipeDirection? = nil, shortcut: RecordedShortcut? = nil, isMediaControls: Bool = false, mediaAction: ExplorerMediaAction? = nil) {
        self.direction = direction; self.bundleID = bundleID; self.name = name; self.icon = icon; self.url = url
        self.isWebURL = isWebURL
        self.isGroup = isGroup
        self.isRecentGroup = isRecentGroup
        self.isWindowManager = isWindowManager
        self.tilingDirection = tilingDirection
        self.shortcut = shortcut
        self.isMediaControls = isMediaControls
        self.mediaAction = mediaAction
    }
    init(direction: SwipeDirection, app: NSRunningApplication) {
        self.init(direction: direction, bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "Application", icon: app.icon, url: app.bundleURL)
    }
}

@MainActor final class ExplorerModel: ObservableObject {
    // MRU starts at the left and proceeds clockwise. Positions freeze on open.
    static let directions = AppExplorerSettings.recentDirections
    @Published var entries: [ExplorerEntry] = []
    @Published var selected: SwipeDirection?
    @Published var mode: AppExplorerMode = .favorites
    @Published var groupNames: [String] = []
    @Published var groupDirections: [SwipeDirection] = []
    @Published var canEdit = false
    @Published var isEditing = false
    @Published var showingRecents = false
    @Published var showingWindowManager = false
    @Published var directWindowManager = false
    @Published var message: String?
    @Published var showingMediaControls = false
    @Published var layerName: String?
    @Published var layerHint = ""
    @Published var windowLayout: ExplorerWindowLayout = .halves
    @Published var theme: ExplorerTheme = .vector
    @Published var animationsEnabled = true
}

struct AppExplorerView: View {
    @ObservedObject var model: ExplorerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var reticleRotation = -135.0
    var onSelect: (SwipeDirection) -> Void
    var onCancel: () -> Void
    var onBack: () -> Void = {}
    var onEdit: () -> Void = {}
    // Previews/tests may enforce reduced motion; they cannot override macOS's
    // accessibility preference in the opposite direction.
    var forceReduceMotion = false
    private let grid: [[SwipeDirection?]] = [[.topLeft, .up, .topRight], [.left, nil, .right], [.bottomLeft, .down, .bottomRight]]
    private var canGoBack: Bool { !model.directWindowManager && !model.groupNames.isEmpty }
    private var animates: Bool {
        ExplorerHUDMotion.enabled(theme: model.theme, preference: model.animationsEnabled,
            reduceMotion: reduceMotion || forceReduceMotion)
    }
    private var feedback: Animation? { animates ? .easeOut(duration: 0.12) : nil }
    private var accent: Color { model.theme.accent }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.groupNames.last ?? "App Explorer")
                        .font(.system(size: 19, weight: .semibold, design: model.theme.isHUD ? .monospaced : .rounded)).lineLimit(1)
                    Text(model.layerName.map { "\($0) · \(model.showingWindowManager ? model.windowLayout.title : "Held layer")" } ?? (model.directWindowManager ? "WINDOW CONTROLS" : ([model.mode.title] + model.groupNames.dropLast()).joined(separator: " › ").uppercased()))
                        .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(model.theme.isHUD ? accent : .secondary).lineLimit(1)
                }
                Spacer()
                if model.canEdit {
                    Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(.borderless).help("Customize favorites and groups here (E)")
                }
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Close App Explorer")
            }
            if model.theme == .starburst {
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
                                            ExplorerLayoutPreview(direction: model.selected, layout: model.windowLayout, accent: accent)
                                        } else {
                                            ZStack {
                                                if model.theme.isHUD {
                                                    Circle().stroke(accent.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [2, 5])).frame(width: 57, height: 57)
                                                    Circle().trim(from: 0.04, to: 0.26).stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                                        .frame(width: 57, height: 57)
                                                        .rotationEffect(.degrees(reticleRotation))
                                                }
                                                Image(systemName: canGoBack ? "arrow.uturn.backward" : (model.directWindowManager ? "xmark.circle" : "safari"))
                                                    .font(.system(size: 30, weight: .light)).foregroundStyle(accent)
                                            }.frame(height: model.theme.isHUD ? 57 : 30)
                                        }
                                        Text(canGoBack ? "Tap to go back" : "Tap to close")
                                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                    }.frame(width: 130, height: 98).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(canGoBack ? "Back to parent group" : "Close \(model.directWindowManager ? "Window Manager" : "App Explorer")")
                            }
                        }
                    }
                }
            }
            }
            Text(model.message ?? (model.showingMediaControls ? "Swipe to control · repeat to adjust · center tap to go back" : (model.showingWindowManager ? "Swipe to tile · lift to apply · center tap to \(model.directWindowManager ? "close" : "go back")" : (model.entries.isEmpty ? (model.showingRecents ? "Open another app · E to edit" : "Click Edit or press E to add favorites.") : (model.groupNames.isEmpty ? "Swipe to choose · lift to open · E to edit" : "Swipe to choose · tap to go back · E to edit")))))
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
            if !model.layerHint.isEmpty { Text("Hold \(model.layerHint)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
        }
        .padding(26)
        .frame(width: 470, height: 464)
        .background(ExplorerHUDBackdrop(theme: model.theme))
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
    }

    private var starburst: some View {
        let names = model.directWindowManager ? [] : model.groupNames
        let depth = min(5, names.count)
        let center = CGPoint(x: 209, y: 155)
        return ZStack {
            // Each completed level leaves a concentric breadcrumb. The lit
            // sector records the direction taken at that level, not a guess
            // based on a group's name (duplicate names are allowed).
            ForEach(0..<depth, id: \.self) { level in
                let radius = ExplorerStarburstLayout.ringRadius(level)
                let direction = model.groupDirections.indices.contains(level) ? model.groupDirections[level] : nil
                ForEach(SwipeDirection.allCases, id: \.self) { sector in
                    ExplorerStarburstSector(direction: sector, innerRadius: radius, outerRadius: radius + 6)
                        .fill(direction == sector ? accent.opacity(0.95 - Double(level) * 0.1) : accent.opacity(0.12))
                        .frame(width: 418, height: 310)
                        .accessibilityHidden(true)
                }
                .transition(.opacity)
            }
            ForEach(SwipeDirection.allCases, id: \.self) { direction in
                starburstChoice(direction, depth: depth, center: center)
            }
            Button(action: onBack) {
                VStack(spacing: 3) {
                    Image(systemName: canGoBack ? "arrow.uturn.backward" : "xmark")
                        .font(.system(size: 13, weight: .medium))
                    Text(String(format: "%02d", depth + 1))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(accent)
                .frame(width: 54, height: 54)
                .background(Circle().fill(model.theme.surface))
                .overlay(Circle().strokeBorder(accent.opacity(0.45)))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .position(center)
            .help(canGoBack ? "Level \(depth + 1) · Tap to go back" : "Level 1 · Tap to close")
            .accessibilityLabel("\(canGoBack ? "Back to parent group" : "Close App Explorer"). Level \(depth + 1). \(([model.mode.title] + names).joined(separator: ", "))")
        }
        .frame(width: 418, height: 310)
        .animation(feedback, value: names)
    }

    private func starburstChoice(_ direction: SwipeDirection, depth: Int, center: CGPoint) -> some View {
        let entry = model.entries.first { $0.direction == direction }
        let available = isAvailable(entry)
        let selected = model.selected == direction && available
        let shape = ExplorerStarburstSector(direction: direction,
            innerRadius: ExplorerStarburstLayout.innerRadius(depth: depth), outerRadius: 143, tip: 11)
        let point = ExplorerStarburstLayout.point(direction, radius: 116, center: center)
        return Button { onSelect(direction) } label: {
            ZStack {
                shape.fill(LinearGradient(colors: [accent.opacity(selected ? 0.38 : 0.08),
                    accent.opacity(selected ? 0.18 : 0.025)], startPoint: .top, endPoint: .bottom))
                shape.stroke(accent.opacity(selected ? 0.95 : available ? 0.35 : 0.12), lineWidth: selected ? 1.5 : 0.75)
                VStack(spacing: 3) {
                    if let entry {
                        entrySymbol(entry).scaleEffect(0.55).frame(width: 24, height: 24)
                        Text(entry.name).font(.system(size: 9, weight: .medium))
                            .lineLimit(2).multilineTextAlignment(.center)
                    } else {
                        Image(systemName: "plus").font(.system(size: 13, weight: .ultraLight)).foregroundStyle(.tertiary)
                        Text(direction.title).font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 78, height: 50)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.85))
                .position(point)
            }
            .frame(width: 418, height: 310)
            .contentShape(shape)
        }
        .buttonStyle(.plain).disabled(!available)
        .help(entry?.isWebURL == true ? (entry?.url?.absoluteString ?? "Invalid URL") : (entry?.name ?? "Empty slot"))
        .accessibilityLabel("\(direction.title): \(entry?.name ?? "Empty slot")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(feedback, value: selected)
    }

    private func isAvailable(_ entry: ExplorerEntry?) -> Bool {
        guard let entry else { return false }
        return entry.url != nil || entry.isGroup || entry.isWindowManager || entry.tilingDirection != nil ||
            entry.shortcut != nil || entry.isMediaControls || entry.mediaAction != nil
    }

    @ViewBuilder private func entrySymbol(_ entry: ExplorerEntry) -> some View {
        if entry.isMediaControls || entry.mediaAction != nil {
            Image(systemName: entry.mediaAction?.symbol ?? "speaker.wave.2.fill").font(.system(size: 30, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if entry.shortcut != nil {
            Image(systemName: "keyboard").font(.system(size: 30, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if let direction = entry.tilingDirection {
            WindowTileIcon(direction: direction, layout: model.windowLayout, accent: accent)
        } else if entry.isWindowManager {
            Image(systemName: "rectangle.split.2x2").font(.system(size: 34, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if entry.isGroup {
            Image(systemName: entry.isRecentGroup ? "clock.arrow.circlepath" : "folder.fill").font(.system(size: 34, weight: .light)).foregroundStyle(accent).frame(width: 42, height: 42)
        } else if entry.isWebURL {
            WebsiteFavicon(url: entry.url, size: 42)
        } else {
            Image(nsImage: entry.icon ?? NSImage(named: NSImage.applicationIconName)!).resizable().scaledToFit().frame(width: 42, height: 42)
        }
    }

    private func reticleAngle(_ direction: SwipeDirection?) -> Double {
        switch direction {
        case .up: return -135
        case .topRight: return -90
        case .right: return -45
        case .bottomRight: return 0
        case .down: return 45
        case .bottomLeft: return 90
        case .left: return 135
        case .topLeft: return 180
        case nil: return -135
        }
    }

    private func tile(_ direction: SwipeDirection) -> some View {
        let entry = model.entries.first { $0.direction == direction }
        let available = isAvailable(entry)
        let selected = model.selected == direction && available
        return Button { onSelect(direction) } label: {
            VStack(spacing: 5) {
                if let entry {
                    entrySymbol(entry)
                    Text(entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if let shortcut = entry.shortcut { Text(shortcut.displayName).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
                    else if entry.isGroup { Text(entry.isRecentGroup ? "Recent apps" : "Explorer group").font(.system(size: 9)).foregroundStyle(.secondary) }
                    else if entry.isWindowManager { Text("Swipe to tile").font(.system(size: 9)).foregroundStyle(.secondary) }
                    else if entry.url == nil && entry.tilingDirection == nil && !entry.isMediaControls && entry.mediaAction == nil { Text(entry.isWebURL ? "Invalid URL" : "Not installed").font(.system(size: 9)).foregroundStyle(.secondary) }
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
            .scaleEffect(selected && model.theme.isHUD ? 1.025 : 1)
            .animation(feedback, value: selected)
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain).disabled(!available)
        .help(entry?.isWebURL == true ? (entry?.url?.absoluteString ?? "Invalid URL") : (entry?.name ?? "Empty slot"))
        .accessibilityLabel("\(direction.title): \(entry?.name ?? "No app")")
    }
}
