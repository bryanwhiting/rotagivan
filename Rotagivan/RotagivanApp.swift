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
        let store = SettingsStore()
        _store = StateObject(wrappedValue: store)
        _hid = StateObject(wrappedValue: NavigatorHIDManager(store: store))
    }

    var body: some Scene {
        WindowGroup("Rotagivan", id: "settings") {
            ContentView(store: store, hid: hid)
                .onAppear { start() }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            NavigatorPanel(store: store, hid: hid)
        } label: {
            Image(systemName: store.precisionActive ? "safari.fill" : "safari")
                .accessibilityLabel("Rotagivan — \(store.precisionActive ? "Precision" : "Normal") profile")
        }
        .menuBarExtraStyle(.window)
    }

    private func start() {
        delegate.onQuit = { hid.stop() }
        hotKeys.onPrecisionChanged = { active in store.setPrecisionActive(active) }
        hotKeys.onAction = { id, down in hid.keyboardAction(id, down: down) }
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
    @State private var editingPrecision = false
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
                    Text("TRACKPAD").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
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

            Picker("Edit profile", selection: $editingPrecision) {
                Text("Normal").tag(false)
                Text("Precision").tag(true)
            }.pickerStyle(.segmented).labelsHidden()

            ShortcutEditor(profile: editingPrecision ? "Precision" : "Normal", showBehavior: false)
                .controlSize(.small)

            speedSlider("Cursor Speed", value: profileValue(\.cursorSpeed), range: 0.05...2)
            speedSlider("Scroll Speed", value: profileValue(\.scrollMultiplier), range: 0.05...4)
            Text(store.precisionActive ? "Precision profile active" : "Normal profile active")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ShortcutEditor(behaviorOnly: true).controlSize(.small)
            DisclosureGroup("Click & drag shortcuts") {
                VStack(alignment: .leading, spacing: 10) {
                    ShortcutEditor(showBehavior: false, actionIndex: 0)
                    ShortcutEditor(showBehavior: false, actionIndex: 1)
                    ShortcutEditor(showBehavior: false, actionIndex: 2)
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
        .onAppear { trusted = AXIsProcessTrusted(); editingPrecision = store.precisionActive }
    }

    private func profileValue(_ key: WritableKeyPath<MotionProfile, Double>) -> Binding<Double> {
        Binding(get: {
            (editingPrecision ? store.settings.precision : store.settings.normal)[keyPath: key]
        }, set: {
            if editingPrecision { store.settings.precision[keyPath: key] = $0 }
            else { store.settings.normal[keyPath: key] = $0 }
        })
    }

    private func speedSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range, step: 0.01).controlSize(.small)
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
