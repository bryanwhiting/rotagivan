import AppKit
import ApplicationServices
import SwiftUI

@main
struct RotagivanApp: App {
    @NSApplicationDelegateAdaptor(CloneDelegate.self) private var delegate
    @StateObject private var store: SettingsStore
    @StateObject private var hid: NavigatorHIDManager
    @StateObject private var sync: SettingsSync
    private let hotKeys = HotKeyManager()
    private let hotkeyPoster = EventPoster()

    init() {
        AppleTrackpadInput.preserveLegacySettings()
        let factory = try? AppConfiguration.factory()
        try? factory?.seedIfNeeded()
        let store = SettingsStore(factorySettings: factory?.settings)
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
        _sync = StateObject(wrappedValue: SettingsSync(store: store, hid: hid))
    }

    var body: some Scene {
        WindowGroup("Rotagivan", id: "settings") {
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
        .windowResizability(.contentSize)

        MenuBarExtra {
            NavigatorPanel(store: store, hid: hid)
        } label: {
            RotagivanMenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }

    private func start() {
        delegate.onQuit = { hid.stop() }
        delegate.beforeQuit = { await sync.prepareToQuit() }
        sync.start()
        hotKeys.onProfileChanged = { id in store.setActiveProfile(id) }
        hotKeys.profileName = { id in store.profiles.first { $0.id == id }?.name }
        hotKeys.onAction = { id, down in hid.keyboardAction(id, down: down) }
        hotKeys.onExplorerHold = { down in hid.explorerHold(down) }
        hotKeys.configureExplorer(nil)
        hotKeys.onHUDLayer = { id in hid.openHUDLayer(id, fromKeyboard: true) }
        hotKeys.onBindingAction = { hid.executeBindingAction($0) }
        hotKeys.onNamedHotkey = { id in
            guard let action = store.settings.resolvedHotkeyDictionary.first(where: { $0.id == id }) else { return }
            hotkeyPoster.performMacro(action)
        }
        hotKeys.configureHUDLayers(store.settings.enabled ? store.settings.appExplorer?.holdLayers ?? [] : [])
        hotKeys.configureNamedHotkeys(store.settings.enabled ? store.settings.resolvedHotkeyDictionary : [])
        hotKeys.configureActionBindings(store.settings.enabled ? store.settings.actionBindings ?? [] : [])
        hotKeys.configureProfiles(defaultID: store.defaultProfileID, customTaps: store.settings.customTapProfiles ?? [], availableIDs: Set(store.settings.availableLayerIDs))
        hotKeys.install()
        if store.settings.enabled { hid.start() }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "Rotagivan" })?.makeKeyAndOrderFront(nil)
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
                    Text("Rotagivan").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(AppVersion.display).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(connected ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }.padding(7).background(.quaternary.opacity(0.4), in: Capsule())
            }
            Divider()
            if !trusted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Accessibility permission").font(.caption)
                    Spacer(minLength: 0)
                    Button("Grant") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }.buttonStyle(.borderedProminent).controlSize(.small)
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
            .toggleStyle(.switch).controlSize(.small)

            Picker("Profile", selection: Binding(get: { store.activeConfigurationID }, set: { id in
                NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)
                hid.stop()
                store.selectConfiguration(id)
                editingProfileID = store.defaultProfileID
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
                    if store.settings.enabled { hid.start() }
                }
            })) {
                ForEach(store.configurationProfiles) { Text($0.name).tag($0.id) }
            }.pickerStyle(.menu)
            Text("Pointer & scrolling · all layers").font(.caption).foregroundStyle(.secondary)
            speedSlider("Fine Speed", value: curveEndpoint(fast: false), scale: .cursorGain, fractionDigits: 1)
            speedSlider("Fast Speed", value: curveEndpoint(fast: true), scale: .cursorGain, fractionDigits: 1)
            DisclosureGroup("Scrolling") {
                ScrollCurveEditor(profile:Binding(get:{store.activeProfile},set:{store.updatePointerMotion($0)}),showGraph:false)
                    .padding(.top,8)
            }
            Text("\(store.activeProfileName) layer active")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Edit action layer", selection: $editingProfileID) {
                ForEach(store.profiles, id: \.id) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }.pickerStyle(.menu)
            ShortcutEditor(profile: store.profiles.first { $0.id == editingProfileID }?.name ?? "Normal", profileID: editingProfileID, isDefaultProfile: editingProfileID == store.defaultProfileID)
                .controlSize(.small)
            DisclosureGroup("Click & drag shortcuts") {
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
                Button("All Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }.buttonStyle(.link)
                Spacer()
                if store.settings.enabled {
                    Button("Reconnect") { trusted = AXIsProcessTrusted(); hid.stop(); hid.start() }
                        .buttonStyle(.link)
                }
                Button("Quit") { hid.stop(); NSApp.terminate(nil) }.buttonStyle(.link)
            }.font(.caption)
        }
        .padding(16)
        .frame(width: 340)
        .tint(.primary)
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
struct RotagivanMenuBarLabel: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.activeProfileID != store.defaultProfileID ? "safari.fill" : "safari")
                .accessibilityLabel("Rotagivan — \(store.activeProfileName) layer")
            Text(AppVersion.version)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHUDSettingsRequested)) { _ in
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApp.windows.first(where: { $0.title == "Rotagivan" })?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

struct SettingsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Settings…") {
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
        Task { await beforeQuit(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { onQuit?() }
}
