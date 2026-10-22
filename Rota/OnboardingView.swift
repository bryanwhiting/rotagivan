import AppKit
import ApplicationServices
import IOKit.hid
import SwiftUI

// MARK: - Steps

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 1, permissions, trackpad, tryIt, settingsHome, starterPacks
    var id: Int { rawValue }
    /// The accessibility identifier of the step's content: `onboarding-step-N`.
    var identifier: String { "onboarding-step-\(rawValue)" }
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .trackpad: return "Your trackpad"
        case .tryIt: return "Try it"
        case .settingsHome: return "Where settings live"
        case .starterPacks: return "Starter packs"
        }
    }
    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    static var count: Int { allCases.count }
}

struct OnboardingGestureLine: Identifiable, Equatable {
    let symbol: String
    let gesture: String
    let result: String
    var id: String { gesture }
}

struct OnboardingPackImport: Equatable {
    var imported: [String] = []
    var failed: [String] = []
}

/// Everything the tour observes or changes, as closures, so it renders in
/// tests with injected state: no permission prompts, no live input, no network.
struct OnboardingEnvironment {
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    /// true = granted, false = denied, nil = macOS has not been asked yet.
    var inputMonitoringGranted: () -> Bool? = {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return true
        case kIOHIDAccessTypeDenied: return false
        default: return nil
        }
    }
    var openAccessibilitySettings: () -> Bool = {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    var openInputMonitoringSettings: () -> Bool = {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    var hudVisible: () -> Bool = { false }
    var applyDevice: (GestureDevice) -> Void = { _ in }
    var builtInPacks: [MacroPack.BuiltIn] = []
    var importPacks: ([MacroPack.BuiltIn]) -> OnboardingPackImport = { _ in OnboardingPackImport() }
    var appURL: URL? = nil
    var hudShortcut = ActionBinding.defaultHUDLauncher.trigger.title
    var gestureSummary: [OnboardingGestureLine] = []
    var pollInterval: TimeInterval = 0.5
    /// Packs checked by default. Every built-in pack is listed; these are the
    /// ones most people want on day one.
    static let starterPackNames: Set<String> = ["Slack", "Google Chrome", "Gmail"]

    /// The packs the tour pre-checks: the starter set, or every pack when a
    /// build ships none of them.
    var defaultPackIDs: Set<String> {
        let starters = builtInPacks.filter { Self.starterPackNames.contains($0.name) }
        return Set((starters.isEmpty ? builtInPacks : starters).map(\.id))
    }

    /// The live environment: reads the store, the HID manager and the app bundle.
    @MainActor static func live(store: SettingsStore, hid: NavigatorHIDManager) -> OnboardingEnvironment {
        var environment = OnboardingEnvironment()
        environment.hudVisible = { [weak hid] in hid?.hudVisible == true }
        environment.applyDevice = { [weak store, weak hid] device in
            guard let store, let hid else { return }
            hid.stop()
            var devices = store.settings.resolvedDevices
            if device == .apple { devices.appleEnabled = true } else { devices.navigatorEnabled = true }
            store.settings.devices = devices
            if store.settings.enabled { hid.start() }
            // "Allow Apple input on this Mac" is a per-Mac choice, never synced.
            if device == .apple { hid.setAppleTrackpadEnabled(true) }
            hid.markInputReviewed()
        }
        environment.builtInPacks = MacroPackImport.builtInPacks
        environment.importPacks = { [weak store] packs in
            guard let store else { return OnboardingPackImport() }
            return Self.importPacks(packs, into: store)
        }
        environment.appURL = AccessibilityAppFile.validatedURL(Bundle.main.bundleURL)
        environment.hudShortcut = Self.hudShortcut(store.settings)
        environment.gestureSummary = Self.gestureSummary(store.settings)
        return environment
    }

    /// The same merge-and-store path as the Actions table and the action
    /// picker (`MacroPackImport.apply`), without one alert per pack.
    @MainActor static func importPacks(_ packs: [MacroPack.BuiltIn], into store: SettingsStore) -> OnboardingPackImport {
        var result = OnboardingPackImport()
        for builtIn in packs {
            do {
                let pack = try MacroPack.parse(contentsOf: builtIn.url)
                _ = try MacroPackImport.apply(pack, to: store)
                result.imported.append(pack.name)
            } catch {
                result.failed.append("\(builtIn.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func hudShortcut(_ settings: StoredSettings) -> String {
        let launcher = ActionBinding.defaultHUDLauncher
        return settings.actionBindings?.first { $0.id == launcher.id }?.trigger.title ?? launcher.trigger.title
    }

    static func gestureSummary(_ settings: StoredSettings) -> [OnboardingGestureLine] {
        let gestures = settings.gestures(for: settings.resolvedDefaultProfileID)
        func result(_ action: TapAction, _ shortcut: RecordedShortcut?) -> String {
            action == .shortcut ? (shortcut?.readableCombination ?? action.title) : action.title
        }
        return [
            OnboardingGestureLine(symbol: "hand.point.up.left", gesture: "One-finger tap", result: result(gestures.oneFingerTap, gestures.oneFingerShortcut)),
            OnboardingGestureLine(symbol: "hand.tap", gesture: "Two-finger tap", result: result(gestures.twoFingerTap, gestures.twoFingerShortcut)),
            OnboardingGestureLine(symbol: "arrow.left.and.right", gesture: "Two-finger swipe", result: "Move between HUD tiles"),
        ]
    }
}

// MARK: - Model

/// The tour's state. Completion is persisted under `onboarding.completed.v1`;
/// closing, skipping and finishing all count, so the tour appears once at
/// launch and afterwards only from General → "Show welcome tour…".
@MainActor
final class OnboardingModel: ObservableObject {
    static let completedKey = "onboarding.completed.v1"
    static let deviceKey = "onboarding.device.v1"

    @Published private(set) var step: OnboardingStep = .welcome
    @Published var device: GestureDevice
    @Published var selectedPackIDs: Set<String>
    @Published private(set) var inputMonitoring: Bool?
    @Published private(set) var hudOpened = false
    @Published private(set) var packImport: OnboardingPackImport?
    @Published private(set) var accessibilityOpenFailed = false
    @Published private(set) var inputMonitoringOpenFailed = false
    @Published private(set) var completed: Bool
    let accessibility: AccessibilitySetupState
    let environment: OnboardingEnvironment
    private let defaults: UserDefaults
    private var timer: Timer?
    /// Called when the tour is finished or skipped; the controller closes the window.
    var onDismiss: (() -> Void)?
    var isMonitoring: Bool { timer != nil }

    init(defaults: UserDefaults, environment: OnboardingEnvironment) {
        self.defaults = defaults
        self.environment = environment
        accessibility = AccessibilitySetupState(probe: environment.accessibilityTrusted)
        device = defaults.string(forKey: Self.deviceKey).flatMap(GestureDevice.init(rawValue:)) ?? .apple
        selectedPackIDs = environment.defaultPackIDs
        completed = defaults.bool(forKey: Self.completedKey)
        inputMonitoring = environment.inputMonitoringGranted()
    }

    static func isCompleted(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: completedKey) }
    static func shouldPresent(defaults: UserDefaults) -> Bool { !isCompleted(defaults) }

    var isFirst: Bool { step.previous == nil }
    var isLast: Bool { step.next == nil }
    var progressLabel: String { "Step \(step.rawValue) of \(OnboardingStep.count): \(step.title)" }

    // MARK: Live status

    func refresh() {
        accessibility.refresh()
        inputMonitoring = environment.inputMonitoringGranted()
        if step == .tryIt, environment.hudVisible() { hudOpened = true }
    }

    func startMonitoring() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: environment.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func openAccessibilitySettings() { accessibilityOpenFailed = !environment.openAccessibilitySettings() }
    func openInputMonitoringSettings() { inputMonitoringOpenFailed = !environment.openInputMonitoringSettings() }

    // MARK: Navigation

    func go(to target: OnboardingStep) {
        step = target
        refresh()
    }

    /// Continue. Leaving the trackpad step applies the device choice; the
    /// last step finishes the tour.
    func next() {
        if step == .trackpad { applyDevice() }
        if let next = step.next { go(to: next) } else { finish() }
    }

    func back() {
        if let previous = step.previous { go(to: previous) }
    }

    /// Skip the rest of the tour. Nothing chosen so far is undone.
    func skip() {
        markCompleted()
        onDismiss?()
    }

    func applyDevice() {
        defaults.set(device.rawValue, forKey: Self.deviceKey)
        environment.applyDevice(device)
    }

    func togglePack(_ id: String) {
        if selectedPackIDs.contains(id) { selectedPackIDs.remove(id) } else { selectedPackIDs.insert(id) }
    }

    var selectedPacks: [MacroPack.BuiltIn] { environment.builtInPacks.filter { selectedPackIDs.contains($0.id) } }

    /// Import the chosen packs and close. A failed pack keeps the window open
    /// with the reason; Finish then simply closes.
    func finish() {
        if packImport == nil, !selectedPacks.isEmpty {
            let result = environment.importPacks(selectedPacks)
            packImport = result
            markCompleted()
            if !result.failed.isEmpty { return }
        }
        markCompleted()
        onDismiss?()
    }

    func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
        completed = true
    }
}

// MARK: - Controller

/// One window for the tour. Non-modal and not floating: the menu bar app and
/// its settings stay usable while it is open.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    private(set) var window: NSWindow?
    private(set) var model: OnboardingModel?
    private var sync: SettingsSync?
    private var defaults: UserDefaults = .standard
    private var environment: OnboardingEnvironment?

    /// Wire the live dependencies once at launch. A custom environment is for tests.
    func attach(store: SettingsStore, hid: NavigatorHIDManager, sync: SettingsSync,
                defaults: UserDefaults, environment: OnboardingEnvironment? = nil) {
        self.sync = sync
        self.defaults = defaults
        self.environment = environment ?? .live(store: store, hid: hid)
    }

    var shouldPresentAtLaunch: Bool { OnboardingModel.shouldPresent(defaults: defaults) }

    func present() {
        guard let sync, let environment else { return }
        if window == nil {
            let model = OnboardingModel(defaults: defaults, environment: environment)
            model.onDismiss = { [weak self] in self?.window?.close() }
            self.model = model
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: OnboardingView.height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Welcome to Rota"
            window.identifier = NSUserInterfaceItemIdentifier("onboarding")
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView(model: model, sync: sync))
            window.center()
            self.window = window
        }
        model?.startMonitoring()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stopMonitoring()
        // Closing with the window button is a skip: never ask again at launch.
        model?.markCompleted()
        window?.delegate = nil
        window = nil
        model = nil
    }
}

// MARK: - View

struct OnboardingView: View {
    static let width: CGFloat = 600
    static let height: CGFloat = 660
    @ObservedObject var model: OnboardingModel
    @ObservedObject var sync: SettingsSync
    @ObservedObject private var accessibility: AccessibilitySetupState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: OnboardingModel, sync: SettingsSync) {
        self.model = model
        self.sync = sync
        accessibility = model.accessibility
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .padding(RotaTokens.Space.xxl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .id(model.step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .clipped()
            Divider()
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(.rotaSecondary)
        .toggleStyle(.rotaCheckbox)
        .tint(.primary)
        .onAppear { model.startMonitoring() }
        .onDisappear { model.stopMonitoring() }
    }

    private func animated(_ change: @escaping () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: 0.22)) { change() } }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.m) {
            HStack {
                Text("ROTA").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Text(model.progressLabel).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding-progress-label")
            }
            Text(model.step.title).font(.title2.weight(.semibold))
            progressDots
        }
        .padding(.horizontal, RotaTokens.Space.xxl)
        .padding(.vertical, RotaTokens.Space.xl)
    }

    private var progressDots: some View {
        HStack(spacing: RotaTokens.Space.s) {
            ForEach(OnboardingStep.allCases) { step in
                let current = step == model.step
                let done = step.rawValue < model.step.rawValue
                Capsule()
                    .fill(current ? RotaTokens.accent : (done ? RotaTokens.accent.opacity(0.45) : Color.primary.opacity(0.14)))
                    .frame(width: current ? 22 : 8, height: 8)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(model.progressLabel)
        .accessibilityIdentifier("onboarding-progress")
    }

    private var footer: some View {
        HStack {
            Button("Back") { animated { model.back() } }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.isFirst)
                .accessibilityIdentifier("onboarding-tour-back")
            Spacer()
            if !model.isLast {
                Button("Skip tour") { model.skip() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("onboarding-tour-skip")
            }
            Button(continueTitle) { animated { model.next() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.rotaPrimary)
                .accessibilityIdentifier("onboarding-tour-continue")
        }
        .padding(.horizontal, RotaTokens.Space.xxl)
        .padding(.vertical, RotaTokens.Space.xl)
    }

    private var continueTitle: String {
        guard model.isLast else { return "Continue" }
        if let result = model.packImport, !result.failed.isEmpty { return "Close" }
        return model.selectedPacks.isEmpty ? "Finish" : "Import and finish"
    }

    // MARK: Steps

    @ViewBuilder private var stepContent: some View {
        Group {
            switch model.step {
            case .welcome: welcome
            case .permissions: permissions
            case .trackpad: trackpad
            case .tryIt: tryIt
            case .settingsHome: settingsHome
            case .starterPacks: starterPacks
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.step.identifier)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.xl) {
            Image(systemName: "safari").font(.system(size: 44, weight: .light)).foregroundStyle(RotaTokens.accent)
            Text("Rota turns your trackpad into a launcher for apps, windows and actions.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: RotaTokens.Space.l) {
                bullet("safari", "A HUD, one shortcut away", "Press \(model.environment.hudShortcut) or tap the trackpad to open a radial HUD of your favourite apps, windows and actions, then flick to pick one.")
                bullet("hand.tap", "Gestures that run things", "One-finger and two-finger taps and swipes run shortcuts, macros and window layouts, on an Apple trackpad or a ZSA Navigator.")
                bullet("shippingbox", "Starter packs and voice", "Import macro packs for Slack, Chrome and Gmail, keep settings in sync across Macs, and talk to voice mode when your hands are busy.")
            }
            Text("This tour takes about a minute. You can reopen it any time from General → Show welcome tour.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: RotaTokens.Space.l) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(RotaTokens.accent)
                .frame(width: 26, height: 26)
                .background(RotaTokens.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.xl) {
            Text("macOS grants these; Rota only checks them. Status updates live while this window is open.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RotaCard("Accessibility", systemImage: "hand.raised.fill", subtitle: "Required. Runs your shortcuts, moves the pointer and arranges windows.",
                     accessory: { permissionBadge(accessibility.trusted ? true : false, grantedText: "Enabled", missingText: "Not enabled").accessibilityIdentifier("onboarding-accessibility-status") }) {
                VStack(alignment: .leading, spacing: RotaTokens.Space.l) {
                    if !accessibility.trusted {
                        Text("Open System Settings → Privacy & Security → Accessibility and turn on Rota. If it is not listed, drag the app below into the list or use the + button.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let url = model.environment.appURL { AccessibilityAppDragTile(appURL: url).frame(height: 72) }
                    }
                    HStack {
                        Button("Open System Settings") { model.openAccessibilitySettings() }
                            .buttonStyle(accessibility.trusted ? .rotaSecondary : .rotaPrimary)
                            .accessibilityIdentifier("onboarding-accessibility-open")
                        if model.accessibilityOpenFailed {
                            Text("Open System Settings → Privacy & Security → Accessibility manually.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            RotaCard("Input Monitoring", systemImage: "keyboard", subtitle: "Needed for a ZSA Navigator. Apple trackpads do not need it.",
                     accessory: { permissionBadge(model.inputMonitoring, grantedText: "Enabled", missingText: model.inputMonitoring == nil ? "Not asked yet" : "Not enabled").accessibilityIdentifier("onboarding-input-monitoring-status") }) {
                VStack(alignment: .leading, spacing: RotaTokens.Space.l) {
                    Text(model.inputMonitoring == nil
                         ? "macOS asks the first time a Navigator connects. You can also enable it now."
                         : "System Settings → Privacy & Security → Input Monitoring → Rota.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open System Settings") { model.openInputMonitoringSettings() }
                            .accessibilityIdentifier("onboarding-input-monitoring-open")
                        if model.inputMonitoringOpenFailed {
                            Text("Open System Settings → Privacy & Security → Input Monitoring manually.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            RotaCard("Microphone", systemImage: "mic", subtitle: "Only for voice mode. macOS asks the first time you use it; nothing to do now.",
                     accessory: { permissionBadge(nil, grantedText: "Enabled", missingText: "Later").accessibilityIdentifier("onboarding-microphone-status") }) { EmptyView() }
        }
    }

    private func permissionBadge(_ granted: Bool?, grantedText: String, missingText: String) -> some View {
        HStack(spacing: RotaTokens.Space.xs) {
            Image(systemName: granted == true ? "checkmark.circle.fill" : (granted == false ? "xmark.circle" : "circle.dotted"))
                .foregroundStyle(granted == true ? Color.green : (granted == false ? Color.orange : Color.secondary))
            Text(granted == true ? grantedText : missingText).font(.caption.weight(.medium))
        }
        .padding(.horizontal, RotaTokens.Space.m).padding(.vertical, RotaTokens.Space.xs)
        .background(RotaTokens.subtleFill, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var trackpad: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.xl) {
            Text("Which trackpad will you use most? This sets the device defaults; Devices in Settings has every option, and both can be on at once.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: RotaTokens.Space.l) {
                deviceOption(.apple, symbol: "rectangle.and.hand.point.up.left",
                    detail: "Built-in or Magic Trackpad. Tap actions use two nearby fingers; native pointing and scrolling stay with macOS. Turns on “Allow Apple input on this Mac”.")
                deviceOption(.navigator, symbol: "computermouse",
                    detail: "ZSA Navigator over USB. Rota drives the pointer, scrolling, tap actions and layers. Quit ZSA's own app first and allow Input Monitoring.")
            }
            Text("Applied when you continue. This Mac's input choice is never synced.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func deviceOption(_ device: GestureDevice, symbol: String, detail: String) -> some View {
        let chosen = model.device == device
        return Button { model.device = device } label: {
            VStack(alignment: .leading, spacing: RotaTokens.Space.m) {
                Label(device.title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Label(chosen ? "Chosen" : "Choose", systemImage: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(RotaTokens.accent)
            }
            .padding(RotaTokens.Space.l)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous).fill(RotaTokens.paneFill))
            .overlay(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                .strokeBorder(chosen ? RotaTokens.accent.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: chosen ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("onboarding-device-\(device.rawValue)")
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.xl) {
            Text("Open the HUD now. Press the shortcut below, then release it to pick a tile or press Escape to close it.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: RotaTokens.Space.l) {
                ForEach(model.environment.hudShortcut.split(separator: "+").map(String.init), id: \.self) { key in
                    Text(key)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.horizontal, RotaTokens.Space.l).frame(height: 36)
                        .background(RotaTokens.fieldFill, in: RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous).strokeBorder(RotaTokens.hairline))
                }
                Spacer()
                HStack(spacing: RotaTokens.Space.s) {
                    Image(systemName: model.hudOpened ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(model.hudOpened ? Color.green : Color.secondary)
                    Text(model.hudOpened ? "You opened the HUD" : "Waiting for the HUD…").font(.callout.weight(.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding-hud-status")
            }
            .padding(RotaTokens.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RotaTokens.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: RotaTokens.Radius.l, style: .continuous))
            RotaCard("Trackpad gestures", systemImage: "hand.tap", subtitle: "Defaults for your \(model.device.title). Change them under HUD in Settings.") {
                VStack(alignment: .leading, spacing: RotaTokens.Space.m) {
                    ForEach(model.environment.gestureSummary) { line in
                        HStack(spacing: RotaTokens.Space.l) {
                            Image(systemName: line.symbol).foregroundStyle(RotaTokens.accent).frame(width: 20)
                            Text(line.gesture).font(.callout)
                            Spacer()
                            Text(line.result).font(.callout).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text(model.hudOpened ? "Nice. Continue when you are ready." : "Not opening? Accessibility must be enabled (step 2), and Rota must be enabled in the menu bar. You can continue without it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settingsHome: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.xl) {
            SyncModeChooser(sync: sync)
            Text(sync.mode == nil
                 ? "No choice yet. Settings stay on this Mac until you pick one; Sync & backup asks again later."
                 : "Chosen: \(sync.mode == .cloud ? "Cloud sync" : "Local file"). Sign in or pick the folder under Sync & backup in Settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding-sync-choice")
        }
    }

    private var starterPacks: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.xl) {
            Text("Macro packs add ready-made shortcuts you can assign to any gesture or HUD tile. Each pack brings its app to the front before typing.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.environment.builtInPacks.isEmpty {
                Text("No built-in packs were found in this build. Import packs later from Actions → Add action.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                RotaCard("Built-in packs", systemImage: "shippingbox") {
                    VStack(alignment: .leading, spacing: RotaTokens.Space.l) {
                        ForEach(model.environment.builtInPacks) { pack in
                            Toggle(pack.name, isOn: Binding(
                                get: { model.selectedPackIDs.contains(pack.id) },
                                set: { _ in model.togglePack(pack.id) }))
                                .accessibilityIdentifier("onboarding-pack-\(MacroPack.slug(pack.name))")
                        }
                    }
                }
            }
            if let result = model.packImport {
                VStack(alignment: .leading, spacing: RotaTokens.Space.s) {
                    if !result.imported.isEmpty {
                        Label("Imported " + result.imported.joined(separator: ", ") + ". Find them under Macros in the actions table.", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(result.failed, id: \.self) { failure in
                        Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("onboarding-pack-result")
            }
            Text("Finish imports the checked packs. You can import or export packs later from Actions → Add action.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
