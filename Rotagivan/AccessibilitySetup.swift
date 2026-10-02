import AppKit
import ApplicationServices
import SwiftUI

struct OnboardingInputStatus: Equatable {
    var allowedOnMac = false
    var enabledInProfile = false
    var appEnabled = true
    var status = "Disabled on this Mac"
    var actionsEnabled: Bool { allowedOnMac && enabledInProfile }
}

/// Only observes permission. macOS remains responsible for authorizing access.
@MainActor
final class AccessibilitySetupState: ObservableObject {
    @Published private(set) var trusted: Bool
    enum Step { case accessibility, trackpad }
    @Published var step: Step = .accessibility
    @Published private(set) var input = OnboardingInputStatus()
    @Published var settingsOpenFailed = false
    private var readInput: () -> OnboardingInputStatus = { OnboardingInputStatus() }
    private var writeInput: (Bool) -> Void = { _ in }
    private var inputReviewed: () -> Void = {}
    private let probe: () -> Bool
    var onGranted: (() -> Void)?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    var isMonitoring: Bool { timer != nil }

    init(probe: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.probe = probe
        trusted = probe()
    }

    func refresh() {
        let current = probe()
        let newlyGranted = current && !trusted
        trusted = current
        if current { settingsOpenFailed = false }
        if newlyGranted {
            onGranted?()
            step = .trackpad
        }
        if !current { step = .accessibility }
        input = readInput()
    }

    func configureInput(read: @escaping () -> OnboardingInputStatus,
                        write: @escaping (Bool) -> Void, reviewed: @escaping () -> Void) {
        readInput = read
        writeInput = write
        inputReviewed = reviewed
        input = readInput()
    }

    func setAppleInput(_ enabled: Bool) {
        guard trusted else { return }
        writeInput(enabled)
        input = readInput()
    }

    func finishInputSetup() -> Bool {
        refresh()
        guard trusted, step == .trackpad else { return false }
        inputReviewed()
        return true
    }

    static func shouldPresent(trusted: Bool, inputReviewed: Bool, appleInputAllowed: Bool) -> Bool {
        !trusted || (!inputReviewed && !appleInputAllowed)
    }

    func startMonitoring() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let observer = activationObserver { NotificationCenter.default.removeObserver(observer) }
        activationObserver = nil
    }
}

/// A file URL, not an image or a copied application. Never offer move/delete.
enum AccessibilityAppFile {
    static func validatedURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.pathExtension == "app",
              Bundle(url: url)?.bundleIdentifier == "local.rotagivan" else { return nil }
        return url.standardizedFileURL
    }

    static func pasteboardWriter(for url: URL) -> NSPasteboardWriting? {
        validatedURL(url).map { $0 as NSURL }
    }
}

@MainActor
final class AccessibilitySetupController: NSObject, NSWindowDelegate {
    static let shared = AccessibilitySetupController()
    let state: AccessibilitySetupState
    private(set) var panel: NSPanel?
    private let appURL: URL?
    private let openSettings: () -> Bool
    private let revealApp: (URL) -> Void

    init(state: AccessibilitySetupState? = nil,
         appURL: URL = Bundle.main.bundleURL,
         openSettings: @escaping () -> Bool = {
             NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
         },
         revealApp: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.state = state ?? AccessibilitySetupState()
        self.appURL = AccessibilityAppFile.validatedURL(appURL)
        self.openSettings = openSettings
        self.revealApp = revealApp
        super.init()
    }

    func show(readInput: @escaping () -> OnboardingInputStatus = { OnboardingInputStatus() },
              setAppleInput: @escaping (Bool) -> Void = { _ in },
              inputReviewed: @escaping () -> Void = {},
              onGranted: @escaping () -> Void) {
        state.configureInput(read: readInput, write: setAppleInput, reviewed: inputReviewed)
        state.step = state.trusted ? .trackpad : .accessibility
        state.onGranted = onGranted
        state.settingsOpenFailed = false
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 620),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Set up Rotagivan"
            panel.identifier = NSUserInterfaceItemIdentifier("accessibility-setup")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: AccessibilitySetupView(
                state: state, appURL: appURL,
                openSettings: { [weak self] in
                    guard let self else { return }
                    self.state.settingsOpenFailed = !self.openSettings()
                },
                revealApp: { [weak self] in
                    guard let self, let url = self.appURL else { return }
                    self.revealApp(url)
                },
                close: { [weak self] in self?.panel?.close() }))
            panel.center()
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: max(visible.minX, visible.maxX - panel.frame.width - 20),
                                              y: max(visible.minY, visible.midY - panel.frame.height / 2)))
            }
            self.panel = panel
        }
        state.startMonitoring()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        state.stopMonitoring()
        state.onGranted = nil
    }
}

struct AccessibilitySetupView: View {
    @ObservedObject var state: AccessibilitySetupState
    let appURL: URL?
    let openSettings: () -> Void
    let revealApp: () -> Void
    let close: () -> Void

    var body: some View {
        Group {
            if state.step == .trackpad { trackpadStep }
            else { accessibilityStep }
        }
        .padding(26)
        .frame(width: 410)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: state.trusted ? "checkmark.shield.fill" : "hand.raised.fill")
                    .font(.system(size: 28)).foregroundStyle(state.trusted ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.trusted ? "Your Mac. Connected." : "Connect your Mac.").font(.title2.weight(.semibold))
                    Text("Step 1 of 2 · Accessibility").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Accessibility lets Rotagivan run your shortcuts, control the pointer, and arrange windows when you use an action.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                step("1", title: "Open Accessibility settings", detail: "Keep this guide beside System Settings.")
                Button("Open Accessibility Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("accessibility-open-settings")
                step("2", title: "Drag Rotagivan into the list", detail: "Drag the app below into the Accessibility app list.")
                if let url = appURL {
                    AccessibilityAppDragTile(appURL: url).frame(height: 82)
                    Button("Show in Finder", action: revealApp)
                        .buttonStyle(.link).accessibilityIdentifier("accessibility-show-finder")
                } else {
                    Text("Open your installed Rotagivan app to drag it from this guide. You can also use + in System Settings to select it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                step("3", title: "Turn on Rotagivan", detail: "Enable its switch. macOS may ask you to authenticate. If it’s already listed, just turn it on.")
            }
            if state.settingsOpenFailed {
                Text("Open System Settings → Privacy & Security → Accessibility manually.")
                    .font(.callout).foregroundStyle(.orange)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: state.trusted ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(state.trusted ? Color.green : Color.secondary)
                Text(state.trusted ? "Accessibility is enabled" : "Waiting for permission…")
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("accessibility-permission-status")
            }
            Text(state.trusted ? "Permission is ready. Continue to choose your input." : "We’ll detect access and continue automatically. If dragging isn’t convenient, use + in System Settings to choose Rotagivan.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !state.trusted {
                    Button("Check again") { state.refresh() }
                        .accessibilityIdentifier("accessibility-check-again")
                }
                Spacer()
                if state.trusted {
                    Button("Continue") { state.step = .trackpad }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding-continue")
                } else {
                    Button("Set up later", action: close)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("accessibility-close")
                }
            }
        }
    }

    private var trackpadStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "rectangle.and.hand.point.up.left")
                .font(.system(size: 34)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 5) {
                Text("Make your next move.").font(.title2.weight(.semibold))
                Text("Step 2 of 2 · Your input").font(.callout).foregroundStyle(.secondary)
            }
            Label("Accessibility is enabled", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
            Text("Use a built-in or Magic Trackpad to open your HUD and run gesture actions.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Toggle("Enable Apple trackpad gestures", isOn: Binding(
                get: { state.input.actionsEnabled }, set: { state.setAppleInput($0) }))
                .toggleStyle(.switch)
                .accessibilityIdentifier("onboarding-apple-input")
            Text("Turns on “Allow Apple input on this Mac” and Apple actions in this profile. This Mac’s input choice is not synced.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text(state.input.appEnabled ? state.input.status : "Rotagivan is disabled. Enable it in General to use gestures.")
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("onboarding-input-status")
                Text(state.input.actionsEnabled ? "Try a quick two-finger tap with both fingers close together. Lift without pressing down. The result follows your configured tap action." : "Only using Navigator or keyboard shortcuts? You can skip Apple gestures and enable them later in Devices.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            Text("Apple trackpad support is experimental. Native pointing and scrolling stay under macOS control.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Accessibility") { state.step = .accessibility }
                    .accessibilityIdentifier("onboarding-back")
                Spacer()
                Button(state.input.actionsEnabled ? "Done" : "Skip Apple gestures") {
                    if state.finishInputSetup() { close() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-finish")
            }
        }
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.weight(.semibold)).frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AccessibilityAppDragTile: NSViewRepresentable {
    let appURL: URL
    func makeNSView(context: Context) -> AccessibilityAppDragView { AccessibilityAppDragView(appURL: appURL) }
    func updateNSView(_ nsView: AccessibilityAppDragView, context: Context) { nsView.appURL = appURL }
}

final class AccessibilityAppDragView: NSView, NSDraggingSource {
    var appURL: URL { didSet { needsDisplay = true } }
    private var downPoint: NSPoint?
    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Rotagivan app. Drag into the Accessibility list in System Settings.")
        setAccessibilityHelp("You can also use Show in Finder, then add Rotagivan with the plus button in System Settings.")
        setAccessibilityIdentifier("accessibility-app-drag")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.06).setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 1
        path.setLineDash([5, 4], count: 2, phase: 0); path.stroke()
        NSWorkspace.shared.icon(forFile: appURL.path).draw(in: NSRect(x: 16, y: (bounds.height - 48) / 2, width: 48, height: 48))
        ("Rotagivan.app" as NSString).draw(at: NSPoint(x: 78, y: bounds.midY + 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
        ("Drag to System Settings" as NSString).draw(at: NSPoint(x: 78, y: bounds.midY - 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
    }
    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) { downPoint = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 4,
              let writer = AccessibilityAppFile.pasteboardWriter(for: appURL) else { return }
        downPoint = nil
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48),
                              contents: NSWorkspace.shared.icon(forFile: appURL.path))
        beginDraggingSession(with: [item], event: event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
