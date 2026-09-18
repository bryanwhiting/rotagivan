import AppKit
import SwiftUI
import OSLog

@MainActor protocol AppExplorerPresenting: AnyObject {
    var isVisible: Bool { get }
    var isEditing: Bool { get }
    var onDismiss: (() -> Void)? { get set }
    var contextIsValid: (() -> Bool)? { get set }
    func show(waitingForLift: Bool)
    func process(_ report: TrackpadReport)
    func dismiss()
    func setAlternateHeld(_ held: Bool)
}
extension AppExplorerPresenting {
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
    private var deadline = Date.distantPast
    private var alternateHeld = false
    private(set) var groupPath: [SwipeDirection] = []
    private var contactIsDown = false
    private var selectionGeneration: UInt64 = 0
    var configuration: () -> AppExplorerSettings = { AppExplorerSettings() }
    var applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    var openWebURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var openApplication: (URL, NSWorkspace.OpenConfiguration) -> Void = { url, configuration in
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                // Launch Services may invoke this callback off the main actor.
                // Keep logging local so it never accesses actor-isolated state.
                let logger = Logger(subsystem: "local.rotagivan", category: "AppExplorer")
                logger.error("Application open failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    var onDismiss: (() -> Void)?
    var contextIsValid: (() -> Bool)?
    weak var editingStore: SettingsStore?
    var onEditingChanged: ((Bool) -> Void)?
    var isVisible: Bool { panel != nil }
    var isEditing: Bool { model.isEditing }

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
        guard !isVisible else { return }
        selectionGeneration &+= 1
        groupPath = []
        model.canEdit = editingStore != nil
        contactIsDown = waitingForLift
        sourcePID = workspace.frontmostApplication?.processIdentifier
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
        panel.contentView = NSHostingView(rootView: AppExplorerView(model: model,
            onSelect: { [weak self] in self?.choose($0) }, onCancel: { [weak self] in self?.dismiss() },
            onBack: { [weak self] in self?.goBack() }, onEdit: { [weak self] in self?.beginEditing() }))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        self.panel = panel
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

    private func loadEntries() {
        let settings = configuration()
        model.mode = settings.mode(holdingShortcut: alternateHeld)
        if model.mode != .favorites || settings.favorites(at: groupPath) == nil { groupPath = [] }
        model.groupNames = groupPath.indices.compactMap { settings.favorite(at: Array(groupPath.prefix($0 + 1)))?.name }
        if model.mode == .favorites {
            model.entries = (settings.favorites(at: groupPath) ?? []).map { favorite in
                if favorite.isGroup {
                    return ExplorerEntry(direction: favorite.direction, bundleID: nil, name: favorite.name,
                        icon: nil, url: nil, isGroup: favorite.isValidDestination && groupPath.count < AppExplorerSettings.maximumGroupDepth)
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
        if entry?.isGroup == true {
            groupPath.append(direction)
            refreshGroup()
            return
        }
        dismiss()
        guard let entry else { return }
        if entry.isWebURL {
            if let url = entry.url, AppExplorerFavorite.webURL(url.absoluteString) != nil { _ = openWebURL(url) }
            return
        }
        guard let identifier = entry.bundleID else { return }
        // Prefer the actual running bundle when multiple installations exist.
        let running = workspace.runningApplications.first { $0.bundleIdentifier == identifier && !$0.isTerminated }
        guard let url = running?.bundleURL ?? entry.url ?? applicationURL(identifier) else { return }
        let generation = selectionGeneration
        // A nonactivating panel restores focus as it closes. Submit the user's
        // activation on the next main-loop turn, after that teardown finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectionGeneration == generation, self.contextIsValid?() != false else { return }
            self.openApplication(url, Self.activationConfiguration())
        }
    }

    func goBack() {
        guard isVisible, !isEditing else { return }
        guard contextIsValid?() != false, !groupPath.isEmpty else { dismiss(); return }
        groupPath.removeLast()
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
        guard let store = editingStore, let previous = panel, !isEditing,
              contextIsValid?() != false else { return }
        selectionGeneration &+= 1
        model.isEditing = true
        model.selected = nil
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
        if model.isEditing { model.isEditing = false; onEditingChanged?(false) }
        panel.orderOut(nil)
        panel.close()
        timer?.invalidate(); timer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        model.selected = nil
        groupPath = []
        model.groupNames = []
        onDismiss?()
    }
}

private final class ExplorerPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onEdit: (() -> Void)?
    var allowsEditing = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); if !allowsEditing { onCancel?() } }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if allowsEditing { super.keyDown(with: event); return }
        if event.keyCode == 14, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onEdit?(); return
        }
        if event.keyCode == 53 { onCancel?() }
        // Do not leak typing into the application behind the HUD.
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
    init(direction: SwipeDirection, bundleID: String?, name: String, icon: NSImage?, url: URL?, isWebURL: Bool = false, isGroup: Bool = false) {
        self.direction = direction; self.bundleID = bundleID; self.name = name; self.icon = icon; self.url = url
        self.isWebURL = isWebURL
        self.isGroup = isGroup
    }
    init(direction: SwipeDirection, app: NSRunningApplication) {
        self.init(direction: direction, bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "Application", icon: app.icon, url: app.bundleURL)
    }
}

@MainActor final class ExplorerModel: ObservableObject {
    // MRU starts at the top and proceeds clockwise. Positions freeze on open.
    static let directions: [SwipeDirection] = [.up, .topRight, .right, .bottomRight, .down, .bottomLeft, .left, .topLeft]
    @Published var entries: [ExplorerEntry] = []
    @Published var selected: SwipeDirection?
    @Published var mode: AppExplorerMode = .favorites
    @Published var groupNames: [String] = []
    @Published var canEdit = false
    @Published var isEditing = false
}

struct AppExplorerView: View {
    @ObservedObject var model: ExplorerModel
    var onSelect: (SwipeDirection) -> Void
    var onCancel: () -> Void
    var onBack: () -> Void = {}
    var onEdit: () -> Void = {}
    private let grid: [[SwipeDirection?]] = [[.topLeft, .up, .topRight], [.left, nil, .right], [.bottomLeft, .down, .bottomRight]]

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.groupNames.last ?? "App Explorer").font(.system(size: 19, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(([model.mode.title] + model.groupNames.dropLast()).joined(separator: " › ").uppercased())
                        .font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.canEdit {
                    Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(.borderless).help("Customize favorites and groups here (E)")
                }
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Close App Explorer")
            }
            VStack(spacing: 8) {
                ForEach(0..<3) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3) { column in
                            if let direction = grid[row][column] { tile(direction) }
                            else {
                                Button(action: onBack) {
                                    VStack(spacing: 7) {
                                        Image(systemName: model.groupNames.isEmpty ? "safari" : "arrow.uturn.backward")
                                            .font(.system(size: 30, weight: .light)).foregroundStyle(.teal)
                                        Text(model.groupNames.isEmpty ? "Tap to close" : "Tap to go back")
                                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                    }.frame(width: 130, height: 98).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(model.groupNames.isEmpty ? "Close App Explorer" : "Back to parent group")
                            }
                        }
                    }
                }
            }
            Text(model.entries.isEmpty ? (model.mode == .favorites ? "Click Edit or press E to add favorites." : "Open another app · E to edit favorites") : (model.groupNames.isEmpty ? "Swipe to choose · lift to open · E to edit" : "Swipe to choose · tap to go back · E to edit"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(26)
        .frame(width: 470, height: 464)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.2)))
    }

    private func tile(_ direction: SwipeDirection) -> some View {
        let entry = model.entries.first { $0.direction == direction }
        let selected = model.selected == direction && entry != nil
        return Button { onSelect(direction) } label: {
            VStack(spacing: 5) {
                if let entry {
                    if entry.isGroup {
                        Image(systemName: "folder.fill").font(.system(size: 34, weight: .light)).foregroundStyle(.teal).frame(width: 42, height: 42)
                    } else if entry.isWebURL {
                        Image(systemName: "globe").font(.system(size: 34, weight: .light)).foregroundStyle(.teal).frame(width: 42, height: 42)
                    } else {
                        Image(nsImage: entry.icon ?? NSImage(named: NSImage.applicationIconName)!).resizable().scaledToFit().frame(width: 42, height: 42)
                    }
                    Text(entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if entry.isGroup { Text("Explorer group").font(.system(size: 9)).foregroundStyle(.secondary) }
                    else if entry.url == nil { Text(entry.isWebURL ? "Invalid URL" : "Not installed").font(.system(size: 9)).foregroundStyle(.secondary) }
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                }
                Text(direction.title).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(width: 130, height: 98)
            .background(selected ? Color.teal.opacity(0.22) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(selected ? Color.teal.opacity(0.8) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain).disabled(entry == nil || (entry?.url == nil && entry?.isGroup != true))
        .help(entry?.isWebURL == true ? (entry?.url?.absoluteString ?? "Invalid URL") : (entry?.name ?? "Empty slot"))
        .accessibilityLabel("\(direction.title): \(entry?.name ?? "No app")")
    }
}
