import AppKit
import SwiftUI

@MainActor protocol AppExplorerPresenting: AnyObject {
    var isVisible: Bool { get }
    var onDismiss: (() -> Void)? { get set }
    var contextIsValid: (() -> Bool)? { get set }
    func show(waitingForLift: Bool)
    func process(_ report: TrackpadReport)
    func dismiss()
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
    var onDismiss: (() -> Void)?
    var contextIsValid: (() -> Bool)?
    var isVisible: Bool { panel != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = AppExplorerRecents(defaults.stringArray(forKey: "appExplorer.recentBundleIDs") ?? [])
        if let app = workspace.frontmostApplication { record(app) }
        observers.append(workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.record(app)
                if self.isVisible && app.processIdentifier != self.sourcePID { self.dismiss() }
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
        sourcePID = workspace.frontmostApplication?.processIdentifier
        let running = workspace.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.processIdentifier != sourcePID &&
            $0.bundleIdentifier != "local.rotagivan"
        }.sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
        let ordered = recents.ordered(available: running.compactMap(\.bundleIdentifier), excluding: [])
        model.entries = ordered.compactMap { id in running.first { $0.bundleIdentifier == id } }.enumerated().map {
            ExplorerEntry(direction: ExplorerModel.directions[$0.offset], app: $0.element)
        }
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
        panel.contentView = NSHostingView(rootView: AppExplorerView(model: model,
            onSelect: { [weak self] in self?.choose($0) }, onCancel: { [weak self] in self?.dismiss() }))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        // Global monitor is only an Escape fallback; selection uses raw HID,
        // never a stream of synthetic mouse events or an event-tap UI update.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss() }
        }
        deadline = Date().addingTimeInterval(15)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date() >= self.deadline || self.contextIsValid?() == false { self.dismiss() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func process(_ report: TrackpadReport) {
        guard isVisible else { return }
        guard contextIsValid?() != false else { dismiss(); return }
        switch input.process(report) {
        case .waiting: break
        case .highlight(let direction):
            // Publish only a change of sector, not every hardware report.
            if model.selected != direction { model.selected = direction }
        case .select(let direction): choose(direction)
        case .cancel: dismiss()
        }
    }

    private func choose(_ direction: SwipeDirection) {
        guard contextIsValid?() != false else { dismiss(); return }
        let app = model.entries.first { $0.direction == direction }?.app
        dismiss()
        guard let app, !app.isTerminated else { return }
        app.activate(options: [])
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        panel.close()
        timer?.invalidate(); timer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        model.selected = nil
        onDismiss?()
    }
}

private final class ExplorerPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); onCancel?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        // Do not leak typing into the application behind the HUD.
    }
}

struct ExplorerEntry {
    var direction: SwipeDirection
    var app: NSRunningApplication
}

@MainActor final class ExplorerModel: ObservableObject {
    // MRU starts at the top and proceeds clockwise. Positions freeze on open.
    static let directions: [SwipeDirection] = [.up, .topRight, .right, .bottomRight, .down, .bottomLeft, .left, .topLeft]
    @Published var entries: [ExplorerEntry] = []
    @Published var selected: SwipeDirection?
}

struct AppExplorerView: View {
    @ObservedObject var model: ExplorerModel
    var onSelect: (SwipeDirection) -> Void
    var onCancel: () -> Void
    private let grid: [[SwipeDirection?]] = [[.topLeft, .up, .topRight], [.left, nil, .right], [.bottomLeft, .down, .bottomRight]]

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("App Explorer").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("RECENT APPS").font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Close App Explorer")
            }
            VStack(spacing: 8) {
                ForEach(0..<3) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3) { column in
                            if let direction = grid[row][column] { tile(direction) }
                            else {
                                VStack(spacing: 7) {
                                    Image(systemName: "safari").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.teal)
                                    Text(model.selected?.title ?? "Swipe to explore").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                }.frame(width: 130, height: 98)
                            }
                        }
                    }
                }
            }
            Text(model.entries.isEmpty ? "Open another app to see it here." : "Swipe toward an app · lift to switch · Esc to cancel")
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
                if let app = entry?.app {
                    Image(nsImage: app.icon ?? NSImage()).resizable().scaledToFit().frame(width: 42, height: 42)
                    Text(app.localizedName ?? "Application").font(.system(size: 11, weight: .medium)).lineLimit(1)
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
        .buttonStyle(.plain).disabled(entry == nil)
        .accessibilityLabel("\(direction.title): \(entry?.app.localizedName ?? "No app")")
    }
}
