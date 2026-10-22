import AppKit
import ApplicationServices
import SwiftUI

@main
struct RotaApp: App {
    @NSApplicationDelegateAdaptor(CloneDelegate.self) private var delegate
    @StateObject private var store: SettingsStore
    @StateObject private var hid: NavigatorHIDManager
    @StateObject private var sync: SettingsSync
    private let hotKeys = HotKeyManager()
    private let hotkeyPoster = EventPoster()

    init() {
        AppleTrackpadInput.preserveLegacySettings()
        SettingsPersistence.bootstrap()
        let factory = try? AppConfiguration.factory()
        try? factory?.seedIfNeeded(SettingsPersistence.defaults)
        ShortcutSettings.shared = ShortcutSettings(defaults: SettingsPersistence.defaults)
        let store = SettingsStore(defaults: SettingsPersistence.defaults, factorySettings: factory?.settings)
        store.captureShortcuts = { ShortcutConfiguration(.shared) }
        store.restoreShortcuts = { keys in
            ShortcutSettings.shared.replaceConfiguration(normal: keys.normal, precision: keys.precision,
                actions: keys.actions, additional: keys.additional, profileActions: keys.profileActions,
                holdToActivate: keys.holdToActivate, dragShortcut: keys.dragShortcut,
                defaultID: store.defaultProfileID)
        }
        _store = StateObject(wrappedValue: store)
        let hid = NavigatorHIDManager(store: store)
        _hid = StateObject(wrappedValue: hid)
        let sync = SettingsSync(store: store, hid: hid, defaults: SettingsPersistence.defaults, automatic: true)
        _sync = StateObject(wrappedValue: sync)
        // Defer until SwiftUI has installed and retained its state objects, but
        // do not depend on either the settings window or menu being presented.
        DispatchQueue.main.async {
            VoiceApplicationIndex.shared.start()
            MCPBridgeServer.shared.attach(store: store, applications: { VoiceApplicationIndex.shared.applications })
            LocalUsageTracker.shared.actionCatalogue = {
                VoiceActionRegistry.make(settings: store.settings, applications: VoiceApplicationIndex.shared.applications,
                    includeInactiveApplications: true).map {
                    UsageActionTotal(id: VoiceRegisteredAction.id(for: $0.action), name: LocalUsageTracker.actionName($0.action), count: 0, lastUsed: nil)
                }
            }
            LocalUsageTracker.shared.start()
            sync.start()
            UpdateChecker.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup("Rota", id: "settings") {
            ContentView(store: store, hid: hid, sync: sync)
                .onAppear { start() }
                .onReceive(store.$settings) { settings in
                    hotKeys.configureProfiles(defaultID: settings.resolvedDefaultProfileID, customTaps: settings.customTapProfiles ?? [], availableIDs: Set(settings.availableLayerIDs))
                    hotKeys.configureExplorer(nil)
                    hotKeys.configureHUDLayers(settings.enabled ? settings.appExplorer?.holdLayers ?? [] : [])
                    hotKeys.configureNamedHotkeys(settings.enabled ? settings.resolvedHotkeyDictionary : [])
                    hotKeys.configureActionBindings(settings.enabled ? settings.actionBindings ?? [] : [])
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 940, height: 740)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Rota") { showRotaAboutPanel() }
                Button("Check for Updates…") { UpdateChecker.shared.checkNow() }
            }
        }

        WindowGroup("Activity", id: "activity") {
            LocalUsageView().buttonStyle(.rotaSecondary).toggleStyle(.rotaCheckbox)
        }
        .defaultSize(width: 740, height: 700)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            NavigatorPanel(store: store, hid: hid)
        } label: {
            RotaMenuBarLabel(store: store)
                // The menu-bar label exists for the lifetime of the app, even
                // when Settings is never opened. Restore the saved sync login
                // here without transferring settings; the window call is an idempotent fallback.
                .onAppear { sync.start() }
        }
        .menuBarExtraStyle(.window)
    }

    private func start() {
        delegate.onQuit = { MCPBridgeServer.shared.stop(); hid.stop(); ChromeTabRecency.shared.stop(); SlackChannelRecents.shared.stop() }
        delegate.beforeQuit = {
            await LocalUsageTracker.shared.prepareToQuit()
            await sync.prepareToQuit()
        }
        sync.start()
        ChromeTabRecency.shared.start()
        SlackChannelRecents.shared.start()
        hotKeys.onProfileChanged = { id in store.setActiveProfile(id) }
        hotKeys.profileName = { id in store.profiles.first { $0.id == id }?.name }
        hotKeys.onAction = { id, down in hid.keyboardAction(id, down: down) }
        hotKeys.onExplorerHold = { down in hid.explorerHold(down) }
        hotKeys.configureExplorer(nil)
        hotKeys.onHUDLayer = { id in hid.openHUDLayer(id, fromKeyboard: true) }
        hotKeys.onBindingAction = { hid.executeBindingAction($0, fromKeyboard: true) }
        hotKeys.onHUDKey = { keyCode, modifiers, down in
            hid.processVisibleHUDHotkey(keyCode: keyCode, modifiers: modifiers, down: down)
        }
        hotKeys.onNamedHotkey = { id in
            guard let action = store.settings.resolvedHotkeyDictionary.first(where: { $0.id == id }) else { return }
            hotkeyPoster.performMacro(action)
        }
        hotKeys.configureHUDLayers(store.settings.enabled ? store.settings.appExplorer?.holdLayers ?? [] : [])
        hotKeys.configureNamedHotkeys(store.settings.enabled ? store.settings.resolvedHotkeyDictionary : [])
        hotKeys.configureActionBindings(store.settings.enabled ? store.settings.actionBindings ?? [] : [])
        hotKeys.configureProfiles(defaultID: store.defaultProfileID, customTaps: store.settings.customTapProfiles ?? [], availableIDs: Set(store.settings.availableLayerIDs))
        hotKeys.install()
        MacroPackImport.registerPickerTools()
        if store.settings.enabled { hid.start() }
        // First launch: the welcome tour (which covers permissions and the
        // device choice). Later launches fall back to the Accessibility setup
        // whenever permission or the input review is still missing.
        OnboardingController.shared.attach(store: store, hid: hid, sync: sync, defaults: SettingsPersistence.defaults)
        if OnboardingController.shared.shouldPresentAtLaunch { OnboardingController.shared.present() }
        else if hid.needsOnboarding { hid.presentOnboarding() }
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "Rota" })?.makeKeyAndOrderFront(nil)
    }
}

struct NavigatorPanel: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var hid: NavigatorHIDManager
    @Environment(\.openWindow) private var openWindow
    @State private var editingProfileID: UInt32 = 1
    @State private var trusted = AXIsProcessTrusted()

    private var connected: Bool {
        if hid.appleTrackpadConnected { return true }
        if case .connected = hid.state { return true }
        return false
    }

    private var status: String {
        if hid.appleTrackpadConnected {
            if case .connected = hid.state { return "Both connected" }
            return "Apple trackpad"
        }
        switch hid.state {
        case .connected: return "Connected"
        case .looking: return "Searching"
        case .stopped: return "Disabled"
        case .error: return "Disconnected"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "safari").font(.system(size: 23, weight: .light)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rota").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(AppVersion.display).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .help(AppVersion.buildDetails)
                        .accessibilityIdentifier("rota-version")
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(connected ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }.padding(7).background(.quaternary.opacity(0.4), in: Capsule())
            }
            Divider()
            LocalUsageMenuSection()
            Divider()
            if !trusted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Accessibility permission").font(.caption)
                    Spacer(minLength: 0)
                    Button("Grant") {
                        hid.presentOnboarding { trusted = true }
                    }.buttonStyle(.rotaPrimary).controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            } else if case .error(let message) = hid.state, !hid.appleTrackpadConnected {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if hid.appleTrackpadEnabled {
                Text(hid.appleTrackpadStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Apple: actions only · speed and scrolling below apply to Navigator.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Enable", isOn: Binding(get: { store.settings.enabled }, set: {
                store.settings.enabled = $0
                $0 ? hid.start() : hid.stop()
            }))
            .toggleStyle(.rotaSwitch).controlSize(.small)

            RotaSelect("Profile", selection: Binding(get: { store.activeConfigurationID }, set: { id in
                NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)
                hid.stop()
                store.selectConfiguration(id)
                editingProfileID = store.defaultProfileID
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
                    if store.settings.enabled { hid.start() }
                }
            }), options: store.configurationProfiles.map { RotaOption($0.name, value: $0.id) }, fill: true)
            Text("Pointer & scrolling · all layers").font(.caption).foregroundStyle(.secondary)
            speedSlider("Fine Speed", value: curveEndpoint(fast: false), scale: .cursorGain, fractionDigits: 1)
            speedSlider("Fast Speed", value: curveEndpoint(fast: true), scale: .cursorGain, fractionDigits: 1)
            RotaDisclosureSection("Scrolling") {
                ScrollCurveEditor(profile:Binding(get:{store.activeProfile},set:{store.updatePointerMotion($0)}),showGraph:false)
                    .padding(.top,8)
            }
            Text("\(store.activeProfileName) layer active")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            RotaSelect("Edit action layer", selection: $editingProfileID,
                options: store.profiles.map { RotaOption($0.name, value: $0.id) }, fill: true)
            ShortcutEditor(profile: store.profiles.first { $0.id == editingProfileID }?.name ?? "Normal", profileID: editingProfileID, isDefaultProfile: editingProfileID == store.defaultProfileID)
                .controlSize(.small)
            RotaDisclosureSection("Click & drag shortcuts") {
                VStack(alignment: .leading, spacing: 10) {
                    if editingProfileID == store.defaultProfileID || (store.settings.customTapProfiles ?? []).contains(editingProfileID) {
                        ShortcutEditor(showBehavior: false, actionIndex: 0, profileID: editingProfileID)
                        ShortcutEditor(showBehavior: false, actionIndex: 1, profileID: editingProfileID)
                    } else {
                        Text("Tap shortcuts inherit from \(store.profiles[0].name). Enable custom tap settings in All Settings to override.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ShortcutEditor(showBehavior: false, editProfileDragShortcut: true)
                }.controlSize(.small).padding(.top, 8)
            }
            Divider()
            HStack {
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }.buttonStyle(.rotaLink)
                Button("About…") { showRotaAboutPanel() }.buttonStyle(.rotaLink)
                Button("Updates…") { UpdateChecker.shared.checkNow() }.buttonStyle(.rotaLink)
                    .help("Check for Updates")
                Spacer()
                if store.settings.enabled {
                    Button("Reconnect") { trusted = AXIsProcessTrusted(); hid.stop(); hid.start() }
                        .buttonStyle(.rotaLink)
                }
                Button("Quit") { hid.stop(); NSApp.terminate(nil) }.buttonStyle(.rotaLink)
            }.font(.caption)
        }
        .padding(16)
        .frame(width: 340)
        .tint(.primary)
        .toggleStyle(.rotaCheckbox)
        .buttonStyle(.rotaSecondary)
        .onAppear { trusted = AXIsProcessTrusted(); editingProfileID = store.activeProfileID }
        .onChange(of: store.profiles.count) { _, _ in
            if !store.profiles.contains(where: { $0.id == editingProfileID }) { editingProfileID = store.defaultProfileID }
        }
    }

    private func curveEndpoint(fast: Bool) -> Binding<Double> {
        Binding(get: {
            let curve = store.activeProfile.resolvedCursorResponse
            return fast ? curve.fastGain : curve.fineGain
        }, set: { gain in
            var motion = store.activeProfile
            var curve = motion.resolvedCursorResponse
            curve.setEndpoint(fast: fast, gain: gain)
            motion.cursorResponse = curve
            store.updatePointerMotion(motion)
        })
    }

    private func speedSlider(_ title: String, value: Binding<Double>, scale: SettingsScale, fractionDigits: Int = 0) -> some View {
        let precision = pow(10.0, Double(fractionDigits))
        let percentage = Binding(get: { scale.percentage(for: value.wrappedValue) }, set: {
            guard $0.isFinite else { return }
            value.wrappedValue = scale.value(for: ($0 * precision).rounded() / precision)
        })
        return VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(percentage.wrappedValue, format: .number.precision(.fractionLength(fractionDigits))).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            Slider(value: percentage, in: 0...100).controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

/// The menu-bar label stays mounted even when every settings window is closed.
struct RotaMenuBarLabel: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var timer = FocusTimer.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.activeProfileID != store.defaultProfileID ? "safari.fill" : "safari")
                .accessibilityLabel("Rota — \(store.activeProfileName) layer")
            if let endsAt = timer.endsAt {
                // A running timer replaces the version with its countdown.
                Text(endsAt, style: .timer).monospacedDigit()
                    .help("Timer: \(timer.minutes) min, ends at " + endsAt.formatted(date: .omitted, time: .shortened))
                    .accessibilityIdentifier("rota-menu-timer")
            } else {
                Text(AppVersion.versionLabel)
                    .help(AppVersion.buildDetails)
                    .accessibilityIdentifier("rota-menu-version")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHUDSettingsRequested)) { _ in
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApp.windows.first(where: { $0.title == "Rota" })?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

struct SettingsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

final class CloneDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?
    var beforeQuit: (() async -> Void)?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let beforeQuit else { return .terminateNow }
        // A stalled save or sync must never leave the app half-quit, where it
        // also ignores every later Quit. Give cleanup a few seconds, then exit.
        var replied = false
        let reply = { if !replied { replied = true; sender.reply(toApplicationShouldTerminate: true) } }
        Task { @MainActor in await beforeQuit(); reply() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { reply() }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        VoiceApplicationIndex.shared.stop()
        onQuit?()
    }
}

@MainActor
func showRotaAboutPanel() {
    NSApp.orderFrontStandardAboutPanel(options: [
        .applicationVersion: AppVersion.versionLabel,
        .version: AppVersion.build,
        .credits: NSAttributedString(string: AppVersion.buildDetails)
    ])
    NSApp.activate(ignoringOtherApps: true)
}
