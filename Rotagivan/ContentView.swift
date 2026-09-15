import ServiceManagement
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var hid: NavigatorHIDManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = "Profiles"
    @State private var confirmReset = false

    private let sections = [("Profiles", "rectangle.split.2x1"), ("General", "slider.horizontal.3")]

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
                    case "General": general
                    default: profiles
                    }
                }
                .frame(width: selection == "Profiles" ? 720 : 510)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("\(store.activeProfileName) profile active")
                Spacer()
                Text(AppVersion.display)
                Text("Changes save automatically")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toggleStyle(.checkbox)
        .tint(.primary)
        .frame(width: 800, height: 640)
        .confirmationDialog("Reset all profiles and gesture settings? Added profiles will be removed.", isPresented: $confirmReset) {
            Button("Reset settings", role: .destructive) { store.reset(); ShortcutSettings.shared.additional = [:]; ShortcutSettings.shared.profileActions = [:] }
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button {
                    let id = store.addProfile()
                    ShortcutSettings.shared.additional[id] = ProfileShortcut()
                    ShortcutSettings.shared.profileActions[id] = ShortcutSettings.shared.actions(for: store.defaultProfileID)
                } label: {
                    Label("Add profile", systemImage: "plus")
                }
            }
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach(0..<5) { section in
                    GridRow(alignment: .top) {
                        ForEach(store.profiles, id: \.id) { profile in
                            profileCell(profile.name, id: profile.id, section: section)
                                .frame(width: 322, alignment: .topLeading)
                        }
                    }
                }
            }
            .background {
                HStack(spacing: 12) {
                    ForEach(store.profiles, id: \.id) { profile in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(store.activeProfileID == profile.id ? Color.teal.opacity(0.65) : Color.primary.opacity(0.16), lineWidth: 1))
                            .frame(width: 322)
                    }
                }.allowsHitTesting(false)
            }
            .padding(.bottom, 8)
            }
            .onChange(of: store.profiles.count) { _, _ in
                if let id = store.profiles.last?.id { proxy.scrollTo(id, anchor: .trailing) }
            }
            }
            Divider()
            Text("New profiles copy \(store.profiles[0].name). Hold temporarily overrides the selected profile; tap again to return to the previous profile.")
                .font(.caption).foregroundStyle(.secondary)
            ShortcutEditor(errorsOnly: true)
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func profileCell(_ title: String, id: UInt32, section: Int) -> some View {
        let limits = store.settings.resolvedGlobalLimits
        switch section {
        case 0:
            profileHeader(title, id: id)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(store.activeProfileID == id ? Color.teal.opacity(0.09) : Color.primary.opacity(0.035))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
                .id(id)
        case 1:
            columnSection("Motion", icon: "cursorarrow.motionlines") {
                columnSlider("Cursor speed", value: motionBinding(id).cursorSpeed, scale: .linear(minimum: 0, maximum: limits.cursorSpeedMaximum))
                columnSlider("Acceleration", value: motionBinding(id).cursorAcceleration, scale: .linear(minimum: 1, maximum: limits.cursorAccelerationMaximum))
            }
        case 2:
            columnSection("Scrolling", icon: "arrow.up.and.down") {
                columnSlider("Scroll speed", value: motionBinding(id).scrollMultiplier, scale: .linear(minimum: 0, maximum: limits.scrollSpeedMaximum))
                Toggle("Invert horizontal", isOn: motionBinding(id).invertScrollX)
                Toggle("Invert vertical", isOn: motionBinding(id).invertScrollY)
                Toggle("Kinetic scrolling", isOn: motionBinding(id).kineticScroll)
                columnSlider("Momentum", value: motionBinding(id).kineticDecay, scale: .momentum(maximum: limits.momentumMaximum))
                    .disabled(!store.motion(for: id).kineticScroll)
            }
        case 3:
            columnSection("Tapping", icon: "hand.tap") { gestures(id) }
        default:
            columnSection("Dragging", icon: "hand.draw") { dragging(id) }
        }
    }

    private func columnSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 16).padding(.bottom, 18)
    }

    private func columnSlider(_ title: String, value: Binding<Double>, scale: SettingsScale) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            profileSlider(title, name: "", value: value, scale: scale)
        }
    }

    private func profileHeader(_ title: String, id: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ShortcutEditor(profile: title, showError: false, profileID: id, editableName: Binding(get: {
                store.settings.profileNames?[id] ?? title
            }, set: { name in
                var names = store.settings.profileNames ?? [:]
                names[id] = name
                store.settings.profileNames = names
            }), isDefaultProfile: id == store.defaultProfileID)
            HStack {
            Text(id == store.defaultProfileID ? (store.activeProfileID == id ? "Default · Active profile" : "Default profile") : (store.activeProfileID == id ? "Active profile" : " "))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if id != store.defaultProfileID {
                Button("Make default") { makeDefault(id) }.buttonStyle(.link).font(.caption)
            }
            }
        }
        .frame(width: 270, alignment: .leading)
        .frame(minHeight: 120, alignment: .topLeading)
    }

    private func makeDefault(_ id: UInt32) {
        let shortcuts = ShortcutSettings.shared
        let effective = HotKeyManager.resolvedActions(for: id, defaults: shortcuts.actions, saved: shortcuts.profileActions, customTapProfiles: store.settings.customTapProfiles ?? [], defaultID: store.defaultProfileID)
        shortcuts.profileActions[id] = effective
        shortcuts.disableActivation(for: store.defaultProfileID)
        shortcuts.disableActivation(for: id)
        store.makeDefault(id)
    }

    private func profileSlider(_ title: String, name: String, value: Binding<Double>, scale: SettingsScale) -> some View {
        let percentage = Binding(get: { scale.percentage(for: value.wrappedValue) }, set: {
            value.wrappedValue = scale.value(for: $0.rounded())
        })
        return HStack(spacing: 10) {
            Slider(value: percentage, in: 0...100)
                .accessibilityLabel("\(name) \(title)")
            TextField(title, value: percentage, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 52)
                .accessibilityLabel("\(name) \(title) value")
        }.frame(width: 270)
    }

    private func motionBinding(_ id: UInt32) -> Binding<MotionProfile> {
        Binding(get: { store.motion(for: id) }, set: { store.updateMotion($0, for: id) })
    }

    private func gestures(_ id: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if id != store.defaultProfileID {
                Toggle("Set Custom Tap settings", isOn: Binding(get: {
                    (store.settings.customTapProfiles ?? []).contains(id)
                }, set: { enabled in
                    var ids = store.settings.customTapProfiles ?? []
                    if enabled { ids.insert(id) } else { ids.remove(id) }
                    store.settings.customTapProfiles = ids
                }))
            }
            if id == store.defaultProfileID || (store.settings.customTapProfiles ?? []).contains(id) {
            Toggle("Enable tap actions", isOn: gesture(id, \.tapToClick))
            if store.settings.gestures(for: id).gestures.tapToClick {
                tapRecorder("One-finger tap", action: gestureBinding(id).oneFingerTap, shortcut: gestureBinding(id).oneFingerShortcut)
                tapRecorder("One-finger double tap", action: doubleTapActionBinding(id, twoFingers: false), shortcut: doubleTapShortcutBinding(id, twoFingers: false))
                tapRecorder("Two-finger tap", action: gestureBinding(id).twoFingerTap, shortcut: gestureBinding(id).twoFingerShortcut)
                tapRecorder("Two-finger double tap", action: doubleTapActionBinding(id, twoFingers: true), shortcut: doubleTapShortcutBinding(id, twoFingers: true))
                Text("A configured double tap replaces the matching single tap.")
                    .font(.caption).foregroundStyle(.secondary)
                columnSlider("Maximum tap duration", value: gesture(id, \.tapMaxDuration), scale: .linear(minimum: 0, maximum: store.settings.resolvedGlobalLimits.tapDurationMaximum))
                columnSlider("Maximum tap movement", value: gesture(id, \.tapMaxMovement), scale: .linear(minimum: 0, maximum: store.settings.resolvedGlobalLimits.tapMovementMaximum))
            }
            Divider()
            ShortcutEditor(showBehavior: false, actionIndex: 0, showError: false, profileID: id)
            ShortcutEditor(showBehavior: false, actionIndex: 1, showError: false, profileID: id)
            Text("These are separate keyboard shortcuts that click at the cursor; they do not change what a trackpad tap does.")
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Inherit from default")
                    .foregroundStyle(.secondary)
                Text("Uses tapping settings from \(store.profiles[0].name). Enable custom settings to override them while this profile is active.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
    }

    private func tapRecorder(_ title: String, action: Binding<TapAction>, shortcut: Binding<RecordedShortcut?>) -> some View {
        TapActionEditor(title: title, action: action, shortcut: shortcut)
    }

    private func dragging(_ id: UInt32) -> some View {
        let primaryTap = store.settings.effectiveGestures(for: id).oneFingerTap
        let canTapAndHoldDrag = store.settings.effectiveGestures(for: id).gestures.tapToClick && primaryTap.supportsTapAndHoldDrag
        return VStack(alignment: .leading, spacing: 12) {
            ShortcutEditor(showBehavior: false, actionIndex: 2, showError: false, profileID: id)
            Text("Hold the shortcut and move the cursor to drag. Release the key to drop. You can lift and reposition your finger while holding the shortcut.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Tap, then touch and hold to drag", isOn: gesture(id, \.touchAndHoldDrag))
                .disabled(!canTapAndHoldDrag)
            if !canTapAndHoldDrag {
                Text("Tap-and-hold drag needs One-finger tap to be set to Left click. Your current action is \(primaryTap.title).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Allow re-grip while dragging", isOn: gesture(id, \.dragRegrip))
            columnSlider("Re-grip window", value: gesture(id, \.dragRegripWindow), scale: .linear(minimum: 0, maximum: store.settings.resolvedGlobalLimits.regripWindowMaximum))
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
            Section("Global limits") {
                Text("Each profile slider is a 0–100 fraction of these ceilings. Raise a ceiling if a profile at 100 is still too slow.")
                    .font(.caption).foregroundStyle(.secondary)
                globalLimitSlider("Cursor speed ceiling", keyPath: \.cursorSpeedCeiling)
                globalLimitSlider("Acceleration ceiling", keyPath: \.cursorAccelerationCeiling)
                globalLimitSlider("Scroll speed ceiling", keyPath: \.scrollSpeedCeiling)
                globalLimitSlider("Momentum ceiling", keyPath: \.momentumCeiling)
                globalLimitSlider("Tap duration ceiling", keyPath: \.tapDurationCeiling)
                globalLimitSlider("Tap movement ceiling", keyPath: \.tapMovementCeiling)
                globalLimitSlider("Re-grip window ceiling", keyPath: \.regripWindowCeiling)
            }
            Section {
                Text("Rotagivan is an independent, editable implementation. Do not run it at the same time as ZSA Navigator or both apps will respond to each touch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }

    private func gestureBinding(_ id: UInt32) -> Binding<ProfileGestures> {
        Binding(get: { store.settings.gestures(for: id) }, set: { store.updateGestures($0, for: id) })
    }

    private func globalLimitSlider(_ title: String, keyPath: WritableKeyPath<GlobalLimits, Double>) -> some View {
        let value = Binding<Double>(get: { store.settings.resolvedGlobalLimits[keyPath: keyPath] }, set: { newValue in
            var limits = store.settings.resolvedGlobalLimits
            limits[keyPath: keyPath] = min(100, max(0, newValue.rounded()))
            store.updateGlobalLimits(limits)
        })
        return columnSlider(title, value: value, scale: .linear(minimum: 0, maximum: 100))
    }

    private func gesture<Value>(_ id: UInt32, _ keyPath: WritableKeyPath<GestureSettings, Value>) -> Binding<Value> {
        gestureBinding(id).gestures[dynamicMember: keyPath]
    }

    private func doubleTapActionBinding(_ id: UInt32, twoFingers: Bool) -> Binding<TapAction> {
        Binding(get: {
            let gestures = store.settings.gestures(for: id)
            return twoFingers ? (gestures.twoFingerDoubleTap ?? .none) : (gestures.oneFingerDoubleTap ?? .none)
        }, set: { action in
            var gestures = store.settings.gestures(for: id)
            if twoFingers { gestures.twoFingerDoubleTap = action } else { gestures.oneFingerDoubleTap = action }
            store.updateGestures(gestures, for: id)
        })
    }

    private func doubleTapShortcutBinding(_ id: UInt32, twoFingers: Bool) -> Binding<RecordedShortcut?> {
        Binding(get: {
            let gestures = store.settings.gestures(for: id)
            return twoFingers ? gestures.twoFingerDoubleShortcut : gestures.oneFingerDoubleShortcut
        }, set: { shortcut in
            var gestures = store.settings.gestures(for: id)
            if twoFingers { gestures.twoFingerDoubleShortcut = shortcut } else { gestures.oneFingerDoubleShortcut = shortcut }
            store.updateGestures(gestures, for: id)
        })
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
    var errorsOnly = false
    var actionIndex: Int? = nil
    var showError = true
    var profileID: UInt32? = nil
    var editableName: Binding<String>? = nil
    var isDefaultProfile = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let index = actionIndex {
                shortcutRow(["Click at cursor", "Double-click at cursor", "Keyboard drag"][index], value: Binding(get: {
                    shortcuts.actions(for: profileID ?? 1)[index]
                }, set: { value in
                    var actions = shortcuts.actions(for: profileID ?? 1)
                    actions[index] = value
                    shortcuts.profileActions[profileID ?? 1] = actions
                }))
            } else if !errorsOnly {
                if isDefaultProfile { defaultProfileHeader }
                else if let id = profileID {
                    if id == 1 { shortcutRow(profile ?? "Normal", value: $shortcuts.normal) }
                    else if id == 2 { shortcutRow(profile ?? "Precision", value: $shortcuts.precision) }
                    else {
                        shortcutRow(profile ?? "Profile", value: Binding(get: { shortcuts.additional[id] ?? ProfileShortcut() }, set: { shortcuts.additional[id] = $0 }))
                    }
                } else {
                    if profile == nil || profile == "Normal" { shortcutRow("Normal", value: $shortcuts.normal) }
                    if profile == nil || profile == "Precision" { shortcutRow("Precision", value: $shortcuts.precision) }
                }
            }
            if showError, let error = shortcuts.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var defaultProfileHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let editableName {
                TextField("Profile name", text: editableName)
                    .textFieldStyle(.roundedBorder).fontWeight(.semibold)
                    .accessibilityLabel("Profile name")
            } else { Text(profile ?? "Default").fontWeight(.semibold) }
            Text("Used automatically when no other profile is active.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }

    private func shortcutRow(_ title: String, value: Binding<ProfileShortcut>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let editableName {
                    TextField("Profile name", text: editableName)
                        .textFieldStyle(.roundedBorder)
                        .fontWeight(.semibold)
                        .accessibilityLabel("Profile name")
                        .help("Rename this profile")
                } else {
                    Text(title).fontWeight(.semibold)
                }
                Spacer()
                Toggle("Hotkey", isOn: value.enabled).toggleStyle(.switch).controlSize(.small)
            }
            if actionIndex == nil {
                ShortcutRecorder(title: value.wrappedValue.enabled ? value.wrappedValue.displayName : "Record shortcut…") { recorded in
                    var updated = value.wrappedValue
                    updated.assign(recorded)
                    value.wrappedValue = updated
                }
                .frame(maxWidth: .infinity).frame(height: 26)
            } else {
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
            }
            if showBehavior && actionIndex == nil {
                Picker("Activation", selection: Binding(get: { value.wrappedValue.holdToActivate ?? true }, set: { value.wrappedValue.holdToActivate = $0 })) {
                    Text("Hold to activate").tag(true)
                    Text("Tap to toggle").tag(false)
                }
                .accessibilityLabel("\(title) activation")
                .disabled(!value.wrappedValue.enabled)
            }
        }.padding(.vertical, 4)
    }
}
