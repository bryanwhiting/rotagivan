import ServiceManagement
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var hid: NavigatorHIDManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = "Motion"
    @State private var confirmReset = false

    private let sections = [("Motion", "cursorarrow.motionlines"), ("Scrolling", "arrow.up.and.down"), ("Tapping", "hand.tap"), ("Dragging", "hand.draw"), ("General", "slider.horizontal.3")]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(sections, id: \.0) { title, icon in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { selection = title }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: icon).font(.system(size: 19, weight: .medium))
                            Text(title).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(selection == title ? Color.primary : Color.secondary)
                        .frame(width: 76, height: 50)
                        .background(selection == title ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == title ? .isSelected : [])
                }
            }
            .padding(.top, 8).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            Divider()
            ScrollView {
                Group {
                    switch selection {
                    case "Scrolling": scrolling
                    case "Tapping": gestures
                    case "Dragging": dragging
                    case "General": general
                    default: profiles
                    }
                }
                .frame(width: 510)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text(store.precisionActive ? "Precision profile active" : "Normal profile active")
                Spacer()
                Text("Changes save automatically")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toggleStyle(.checkbox)
        .tint(.primary)
        .frame(width: 800, height: 640)
        .confirmationDialog("Reset both profiles and gesture settings?", isPresented: $confirmReset) {
            Button("Reset settings", role: .destructive) { store.reset() }
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 22) {
            Section {
                Text("Tune each profile and its shortcut together.")
                    .foregroundStyle(.secondary)
                profileEditor("Normal", profile: normalBinding)
                Divider()
                profileEditor("Precision", profile: precisionBinding)
            }
            ShortcutEditor(behaviorOnly: true)
        }
        .font(.system(size: 12))
    }

    private var scrolling: some View {
        VStack(alignment: .leading, spacing: 22) {
            Section("Normal") { scrollEditor(profile: normalBinding) }
            Section("Precision") { scrollEditor(profile: precisionBinding) }
        }
        .font(.system(size: 12))
    }

    private var gestures: some View {
        VStack(alignment: .leading, spacing: 22) {
            Toggle("Enable tap actions", isOn: gesture(\.tapToClick))
            Picker("One-finger tap", selection: Binding(get: { store.settings.oneFingerTap ?? .optionF19 }, set: { store.settings.oneFingerTap = $0 })) {
                ForEach(TapAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Two-finger tap", selection: Binding(get: { store.settings.twoFingerTap ?? .enter }, set: { store.settings.twoFingerTap = $0 })) {
                ForEach(TapAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Maximum tap duration") {
                Slider(value: gesture(\.tapMaxDuration), in: 0.1...0.6, step: 0.01)
                Text(store.settings.gestures.tapMaxDuration, format: .number.precision(.fractionLength(2))).frame(width: 42)
            }
            LabeledContent("Maximum tap movement") {
                Slider(value: gesture(\.tapMaxMovement), in: 5...80, step: 1)
                Text(store.settings.gestures.tapMaxMovement, format: .number.precision(.fractionLength(0))).frame(width: 42)
            }
            Divider()
            ShortcutEditor(showBehavior: false, actionIndex: 0)
            ShortcutEditor(showBehavior: false, actionIndex: 1)
            Text("These keyboard shortcuts click at the cursor. They work even when tap actions are off.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    private var dragging: some View {
        VStack(alignment: .leading, spacing: 22) {
            ShortcutEditor(showBehavior: false, actionIndex: 2)
            Text("Hold the shortcut and move the cursor to drag. Release the key to drop. You can lift and reposition your finger while holding the shortcut.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Tap, then touch and hold to drag", isOn: gesture(\.touchAndHoldDrag))
            Toggle("Allow re-grip while dragging", isOn: gesture(\.dragRegrip))
            LabeledContent("Re-grip window") {
                Slider(value: gesture(\.dragRegripWindow), in: 0.05...0.8, step: 0.01)
                Text(store.settings.gestures.dragRegripWindow, format: .number.precision(.fractionLength(2))).frame(width: 42)
            }
        }
        .font(.system(size: 12))
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            Section("Status") {
                LabeledContent("Trackpad") { Text(statusText) }
                Button("Reconnect") { hid.stop(); if store.settings.enabled { hid.start() } }
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Button("Open Input Monitoring Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                Toggle("Enable Rotagivan", isOn: enabledBinding)
            }
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                Button("Reset all settings…") { confirmReset = true }
            }
            Section {
                Text("Rotagivan is an independent, editable implementation. Do not run it at the same time as ZSA Navigator or both apps will respond to each touch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func profileEditor(_ title: String, profile: Binding<MotionProfile>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ShortcutEditor(profile: title, showBehavior: false)
            valueSlider("Cursor speed", value: profile.cursorSpeed, range: 0.05...2.0, step: 0.01)
            valueSlider("Acceleration", value: profile.cursorAcceleration, range: 1.0...2.2, step: 0.01)
        }
    }

    @ViewBuilder
    private func scrollEditor(profile: Binding<MotionProfile>) -> some View {
        valueSlider("Scroll speed", value: profile.scrollMultiplier, range: 0.05...4.0, step: 0.01)
        Toggle("Invert horizontal scroll", isOn: profile.invertScrollX)
        Toggle("Invert vertical scroll", isOn: profile.invertScrollY)
        Toggle("Kinetic scrolling", isOn: profile.kineticScroll)
        valueSlider("Momentum", value: profile.kineticDecay, range: 0.75...0.99, step: 0.01)
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 24) {
            Text(title).foregroundStyle(.secondary).frame(width: 136, alignment: .trailing)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                .monospacedDigit().font(.system(size: 12, weight: .medium))
                .frame(width: 42).padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var normalBinding: Binding<MotionProfile> {
        Binding(get: { store.settings.normal }, set: { store.settings.normal = $0 })
    }

    private var precisionBinding: Binding<MotionProfile> {
        Binding(get: { store.settings.precision }, set: { store.settings.precision = $0 })
    }

    private func gesture<Value>(_ keyPath: WritableKeyPath<GestureSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings.gestures[keyPath: keyPath] }, set: { store.settings.gestures[keyPath: keyPath] = $0 })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { store.settings.enabled }, set: { enabled in
            store.settings.enabled = enabled
            enabled ? hid.start() : hid.stop()
        })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { store.settings.launchAtLogin }, set: { enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                store.settings.launchAtLogin = enabled
            } catch {
                store.settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        })
    }

    private var statusText: String {
        switch hid.state {
        case .stopped: return "Stopped"
        case .looking: return "Looking for ZSA trackpad…"
        case .connected(let name): return "Connected to \(name)"
        case .error(let message): return message
        }
    }
}

struct ShortcutEditor: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    var profile: String? = nil
    var showBehavior = true
    var behaviorOnly = false
    var actionIndex: Int? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showBehavior {
            Picker("Behavior", selection: $shortcuts.hold) {
                Text("Hold to use").tag(true)
                Text("Press to switch").tag(false)
            }
            }
            if let index = actionIndex {
                shortcutRow(["Single click", "Double click", "Hold to drag"][index], value: $shortcuts.actions[index])
            } else if !behaviorOnly {
                if profile == nil || profile == "Normal" { shortcutRow("Normal", value: $shortcuts.normal) }
                if profile == nil || profile == "Precision" { shortcutRow("Precision", value: $shortcuts.precision) }
            }
            if showBehavior {
            Text(shortcuts.hold ? "The last shortcut held selects the profile. Release all shortcuts to return to Normal." : "Press a shortcut to select its profile until you choose another.")
                .font(.caption).foregroundStyle(.secondary)
            }
            if let error = shortcuts.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func shortcutRow(_ title: String, value: Binding<ProfileShortcut>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                Toggle("Hotkey", isOn: value.enabled).toggleStyle(.switch).controlSize(.small)
            }
            HStack(spacing: 6) {
                Picker("Key", selection: value.keyCode) {
                    ForEach(ShortcutSettings.keys, id: \.1) { name, code in Text(name).tag(code) }
                }.frame(width: 120)
                ForEach([( "⌃", UInt32(4096)), ("⌥", UInt32(2048)), ("⇧", UInt32(512)), ("⌘", UInt32(256))], id: \.1) { label, flag in
                    Toggle(label, isOn: Binding(get: { value.wrappedValue.modifiers & flag != 0 }, set: { on in
                        if on { value.wrappedValue.modifiers |= flag }
                        else { value.wrappedValue.modifiers &= ~flag }
                    }))
                    .toggleStyle(.button)
                    .help(flag == 4096 ? "Control" : flag == 2048 ? "Option" : flag == 512 ? "Shift" : "Command")
                }
            }.disabled(!value.wrappedValue.enabled)
        }.padding(.vertical, 4)
    }
}
