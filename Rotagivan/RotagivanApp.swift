import AppKit
import ApplicationServices
import SwiftUI

@main
struct RotagivanApp: App {
    @NSApplicationDelegateAdaptor(CloneDelegate.self) private var delegate
    @StateObject private var store: SettingsStore
    @StateObject private var hid: NavigatorHIDManager
    private let hotKeys = HotKeyManager()

    init() {
        let factory = try? AppConfiguration.factory()
        try? factory?.seedIfNeeded()
        let store = SettingsStore(factorySettings: factory?.settings)
        _store = StateObject(wrappedValue: store)
        _hid = StateObject(wrappedValue: NavigatorHIDManager(store: store))
    }

    var body: some Scene {
        WindowGroup("Rotagivan", id: "settings") {
            ContentView(store: store, hid: hid)
                .onAppear { start() }
                .onReceive(store.$settings) { settings in
                    hotKeys.configureProfiles(defaultID: settings.resolvedDefaultProfileID, customTaps: settings.customTapProfiles ?? [])
                }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            NavigatorPanel(store: store, hid: hid)
        } label: {
            HStack(spacing: 4) {
            Image(systemName: store.activeProfileID != store.defaultProfileID ? "safari.fill" : "safari")
                .accessibilityLabel("Rotagivan — \(store.activeProfileName) profile")
            Text(AppVersion.version)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func start() {
        delegate.onQuit = { hid.stop() }
        hotKeys.onProfileChanged = { id in store.setActiveProfile(id) }
        hotKeys.profileName = { id in store.profiles.first { $0.id == id }?.name }
        hotKeys.onAction = { id, down in hid.keyboardAction(id, down: down) }
        hotKeys.configureProfiles(defaultID: store.defaultProfileID, customTaps: store.settings.customTapProfiles ?? [])
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
        if case .connected = hid.state { return true }
        return false
    }

    private var status: String {
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
            } else if case .error(let message) = hid.state {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Enable", isOn: Binding(get: { store.settings.enabled }, set: {
                store.settings.enabled = $0
                $0 ? hid.start() : hid.stop()
            }))
            .toggleStyle(.switch).controlSize(.small)

            Picker("Edit profile", selection: $editingProfileID) {
                ForEach(store.profiles, id: \.id) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }.pickerStyle(.menu)

            ShortcutEditor(profile: store.profiles.first { $0.id == editingProfileID }?.name ?? "Normal", profileID: editingProfileID, isDefaultProfile: editingProfileID == store.defaultProfileID)
                .controlSize(.small)

            speedSlider("Fine Speed", value: curveEndpoint(fast: false), scale: .linear(minimum: 0, maximum: CursorResponse.maximumGain))
            speedSlider("Fast Speed", value: curveEndpoint(fast: true), scale: .linear(minimum: 0, maximum: CursorResponse.maximumGain))
            speedSlider("Scroll Speed", value: profileValue(\.scrollMultiplier), scale: .linear(minimum: 0, maximum: ProfileMaximum.scrollSpeed))
            Text("\(store.activeProfileName) profile active")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup("Click & drag shortcuts") {
                VStack(alignment: .leading, spacing: 10) {
                    if editingProfileID == store.defaultProfileID || (store.settings.customTapProfiles ?? []).contains(editingProfileID) {
                        ShortcutEditor(showBehavior: false, actionIndex: 0, profileID: editingProfileID)
                        ShortcutEditor(showBehavior: false, actionIndex: 1, profileID: editingProfileID)
                    } else {
                        Text("Tap shortcuts inherit from \(store.profiles[0].name). Enable custom tap settings in All Settings to override.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ShortcutEditor(showBehavior: false, actionIndex: 2, profileID: editingProfileID)
                }.controlSize(.small).padding(.top, 8)
            }
            Divider()
            HStack {
                Button("All Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }.buttonStyle(.link)
                Spacer()
                if !connected && store.settings.enabled {
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

    private func profileValue(_ key: WritableKeyPath<MotionProfile, Double>) -> Binding<Double> {
        Binding(get: {
            store.motion(for: editingProfileID)[keyPath: key]
        }, set: {
            var motion = store.motion(for: editingProfileID)
            motion[keyPath: key] = $0
            store.updateMotion(motion, for: editingProfileID)
        })
    }

    private func curveEndpoint(fast: Bool) -> Binding<Double> {
        Binding(get: {
            let curve = store.motion(for: editingProfileID).resolvedCursorResponse
            return fast ? curve.fastGain : curve.fineGain
        }, set: { gain in
            var motion = store.motion(for: editingProfileID)
            var curve = motion.resolvedCursorResponse
            curve.setEndpoint(fast: fast, gain: gain)
            motion.cursorResponse = curve
            store.updateMotion(motion, for: editingProfileID)
        })
    }

    private func speedSlider(_ title: String, value: Binding<Double>, scale: SettingsScale) -> some View {
        let percentage = Binding(get: { scale.percentage(for: value.wrappedValue) }, set: { value.wrappedValue = scale.value(for: $0.rounded()) })
        return VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(percentage.wrappedValue, format: .number.precision(.fractionLength(0))).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            Slider(value: percentage, in: 0...100).controlSize(.small)
                .accessibilityLabel(title)
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
    func applicationWillTerminate(_ notification: Notification) { onQuit?() }
}
