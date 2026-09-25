import ServiceManagement
import SwiftUI

struct ProfileNameEditor: View {
    @State var name: String
    var onSave: (String) -> Bool
    var onCancel: () -> Void
    @State private var saveFailed = false
    @FocusState private var nameFocused: Bool
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmedName.isEmpty && trimmedName.count <= 80 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename profile").font(.headline)
            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityIdentifier("profile-name-field")
            Text("Names can contain up to 80 characters. Your devices, layers, HUD and other settings stay unchanged.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if trimmedName.count > 80 {
                Text("Use 80 characters or fewer.").font(.caption).foregroundStyle(.red)
            }
            if saveFailed {
                Text("This profile is no longer available. Cancel and select a profile again.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { saveFailed = !onSave(trimmedName) }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 380)
            .onAppear { nameFocused = true }
    }
}

struct ContentView: View {
    private struct PendingLayerDeletion: Identifiable {
        let id: UInt32
        let name: String
    }

    @ObservedObject var store: SettingsStore
    @ObservedObject var hid: NavigatorHIDManager
    @ObservedObject var sync: SettingsSync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = "HUD"
    @State private var actionDevice: GestureDevice = .navigator
    @State private var pointerDevice: GestureDevice = .navigator
    @State private var renamingProfile: ConfigurationProfile?
    @State private var pendingLayerDeletion: PendingLayerDeletion?
    private let initialHUDGroup: ExplorerReservedGroup?
    private let layerColumnWidth: CGFloat = 468

    private let sections = [("Devices", "computermouse"), ("HUD", "safari"),
        ("Calibration", "dial.low"), ("Actions", "bolt.circle"), ("App overrides", "app.badge"),
        ("Pointer & scrolling", "cursorarrow.motionlines"), ("General", "gearshape")]
    private var editingAppleActions: Bool { selection == "HUD" && actionDevice == .apple && !store.settings.resolvedDevices.shareTapActions }

    init(store: SettingsStore, hid: NavigatorHIDManager, sync: SettingsSync,
         initialSection: String = "HUD", initialDevice: GestureDevice = .navigator) {
        self.store = store; self.hid = hid; self.sync = sync
        _selection = State(initialValue: ["Hotkeys", "Keybindings and Macros", "Macros"].contains(initialSection) ? "Actions" :
            ["App Explorer", "Window Manager", "Layers", "Layer actions", "Tap actions"].contains(initialSection) ? "HUD" : initialSection)
        initialHUDGroup = initialSection == "Window Manager" ? .windowManager : nil
        _actionDevice = State(initialValue: initialDevice)
        _pointerDevice = State(initialValue: initialDevice)
    }

    private func sectionTitle(_ section: String) -> String {
        switch section {
        case "Actions": return "Actions"
        default: return section
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                page
            }
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toggleStyle(.checkbox)
        .tint(.primary)
        .environment(\.hotkeyDictionary, store.settings.resolvedHotkeyDictionary)
        .environment(\.hudActionLayers, store.settings.appExplorer?.holdLayers ?? [])
        .environment(\.hudActionDestinations, store.settings.appExplorer?.hudActionDestinations() ?? [])
        .frame(width: 940, height: 740)
        .sheet(item: $renamingProfile) { profile in
            ProfileNameEditor(name: profile.name, onSave: { name in
                guard store.renameConfiguration(name, for: profile.id) else { return false }
                renamingProfile = nil
                return true
            }, onCancel: { renamingProfile = nil })
        }
        .confirmationDialog(
            "Delete \(pendingLayerDeletion?.name ?? "layer")?",
            isPresented: Binding(get: { pendingLayerDeletion != nil }, set: { if !$0 { pendingLayerDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Layer", role: .destructive) {
                if let id = pendingLayerDeletion?.id { deleteLayer(id) }
                pendingLayerDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingLayerDeletion = nil }
        } message: {
            Text("This removes the pointer layer and its activation shortcut.")
        }
        .sheet(item: Binding(get: { hid.calibrationSession }, set: { value in
            if value == nil { hid.endCalibration() }
        })) { session in
            GestureCalibrationView(session: session,
                onApply: { hid.applyCalibration() }, onCancel: { hid.endCalibration() })
                .onDisappear { hid.endCalibration() }
        }
        .onDisappear { hid.endCalibration() }
        .onReceive(NotificationCenter.default.publisher(for: .openHUDSettingsRequested)) { _ in
            selection = "HUD"
            HUDSettingsNavigation.pending = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hid.endCalibration()
        }
        .onAppear {
            if HUDSettingsNavigation.pending {
                selection = "HUD"
                HUDSettingsNavigation.pending = false
            }
            DispatchQueue.main.async {
                store.recenterSliderBaselines(revision: 6)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "safari").font(.system(size: 24, weight: .light)).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("ROTAGIVAN").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                Text(store.activeConfigurationName)
                    .font(.system(size: 19, weight: .semibold)).lineLimit(1)
                    .accessibilityLabel("Profile name")
            }
            Spacer()
            Picker("Profile", selection: Binding(get: { store.activeConfigurationID }, set: { switchProfile($0) })) {
                ForEach(store.configurationProfiles) { profile in Text(profile.name).tag(profile.id) }
            }.frame(width: 215)
            Button("Rename…", systemImage: "pencil") {
                renamingProfile = store.configurationProfiles.first { $0.id == store.activeConfigurationID }
            }.help("Rename the selected profile without changing its settings")
                .accessibilityIdentifier("rename-profile")
            Button { switchProfile(nil) } label: { Label("Add Profile", systemImage: "plus") }
                .disabled(store.configurationProfiles.count >= 20)
                .help("Copy this profile, including every action layer and HUD layer")
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("THIS PROFILE").font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.4).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 9)
            ForEach(sections, id: \.0) { title, icon in
                Button { selection = title } label: {
                    Label(sectionTitle(title), systemImage: icon)
                        .font(.system(size: 12, weight: selection == title ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                        .background(selection == title ? Color.teal.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == title ? .isSelected : [])
            }
            Spacer()
            Text("\(store.profiles.count) layers\n\(store.settings.resolvedDevices.shareTapActions ? "Shared actions" : "Device overrides")")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(4).padding(10)
        }.padding(12).padding(.top, 10).frame(width: 180)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if selection != "HUD" && selection != "Calibration" && selection != "Pointer & scrolling" {
                    Text(sectionTitle(selection)).font(.system(size: 24, weight: .semibold))
                    Text(selection == "General" ? "Account, permissions and startup belong to this Mac. Configurations include every profile." : "Settings for \(store.activeConfigurationName)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                pageContent
            }
            .frame(width: 708, alignment: .leading).padding(22)
            .id(store.activeConfigurationID)
        }
        .background {
            if selection == "HUD" {
                ExplorerSettingsBackdrop(theme: store.settings.appExplorer?.resolvedTheme ?? .starburstAir)
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch selection {
        case "General": general
        case "Devices": devices
        case "HUD": hudAndTapSettings
        case "Actions": HotkeyOrganizerView(store: store)
        case "Calibration": CalibrationSettingsView(store: store, hid: hid, initialDevice: actionDevice)
        case "App overrides": AppOverridesView(store: store)
        case "Pointer & scrolling": pointerSettings
        default: profiles
        }
    }

    private var hudAndTapSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("HUD and tap actions").font(.system(size: 24, weight: .semibold))
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Default").font(.headline)
                            Text("Used whenever no HUD layer is active. This base layer has no on-screen HUD.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label("Tap layer", systemImage: "hand.tap")
                            .font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    }
                    Divider()
                    Toggle("Share tap and swipe actions across devices", isOn: deviceBinding(\.shareTapActions))
                    if !store.settings.resolvedDevices.shareTapActions {
                        Picker("Edit actions for", selection: $actionDevice) {
                            ForEach(GestureDevice.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 340)
                    } else {
                        Label("One set of actions for Navigator and Apple trackpads", systemImage: "link")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    gestures(store.defaultProfileID)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            HUDSettingsView(store: store, initialGroup: initialHUDGroup)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(store.activeConfigurationName)  /  \(store.activeProfileName)")
            Spacer()
            Text(AppVersion.display)
            Text("Changes save automatically")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Pointer layers").font(.system(size: 24, weight: .semibold))
                    Text("Choose a pointer profile and its activation and cursor-click shortcuts. Tap actions live in HUD.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let id = store.addProfile()
                    ShortcutSettings.shared.additional[id] = ProfileShortcut()
                    ShortcutSettings.shared.profileActions[id] = ShortcutSettings.shared.actions(for: store.defaultProfileID)
                } label: {
                    Label("Add layer", systemImage: "plus")
                }
            }
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach([0, 3], id: \.self) { section in
                    GridRow(alignment: .top) {
                        ForEach(store.profiles, id: \.id) { profile in
                            profileCell(profile.name, id: profile.id, section: section)
                                .frame(width: layerColumnWidth, alignment: .topLeading)
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
                            .frame(width: layerColumnWidth)
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
            Text("New pointer layers copy \(store.profiles[0].name). Hold temporarily overrides the selected pointer profile; tap again to return to the previous one.")
                .font(.caption).foregroundStyle(.secondary)
            ShortcutEditor(errorsOnly: true)
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func profileCell(_ title: String, id: UInt32, section: Int) -> some View {
        switch section {
        case 0:
            profileHeader(title, id: id)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(store.activeProfileID == id ? Color.teal.opacity(0.09) : Color.primary.opacity(0.035))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
                .id(id)
        default:
            columnSection("Pointer shortcuts", icon: "cursorarrow.click") {
                ShortcutEditor(showBehavior: false, actionIndex: 0, showError: false, profileID: id)
                ShortcutEditor(showBehavior: false, actionIndex: 1, showError: false, profileID: id)
                Text("Click at cursor and double-click at cursor are keyboard shortcuts for this pointer layer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

    private func centeredScale(_ id: UInt32, minimum: Double, maximum: Double, keyPath: KeyPath<ProfileSliderBaseline, Double>) -> SettingsScale {
        .centered(minimum: minimum, maximum: maximum, baseline: store.settings.sliderBaseline(for: id)[keyPath: keyPath])
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
            Text(id == store.defaultProfileID ? (store.activeProfileID == id ? "Default · Active layer" : "Default layer") : (store.activeProfileID == id ? "Active layer" : " "))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if id != store.defaultProfileID {
                Button("Make default") { makeDefault(id) }.buttonStyle(.link).font(.caption)
            }
            if store.canRemoveProfile(id) {
                Button {
                    pendingLayerDeletion = PendingLayerDeletion(id: id, name: title)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete \(title)")
                .accessibilityLabel("Delete \(title)")
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func deleteLayer(_ id: UInt32) {
        if id == store.defaultProfileID,
           let replacement = store.profiles.first(where: { $0.id != id }) {
            makeDefault(replacement.id)
        }
        guard store.removeProfile(id) else { return }
        let shortcuts = ShortcutSettings.shared
        shortcuts.disableActivation(for: id)
        shortcuts.additional.removeValue(forKey: id)
        shortcuts.profileActions.removeValue(forKey: id)
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

    private var pointerBinding: Binding<MotionProfile> {
        Binding(get: { store.activeProfile }, set: { store.updatePointerMotion($0) })
    }

    private var pointerSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pointer & scrolling").font(.system(size: 24, weight: .semibold))
            Text("Device controls for \(store.activeConfigurationName). Navigator tuning applies across its action layers.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Device", selection: $pointerDevice) {
                Label("ZSA Navigator", systemImage: "computermouse").tag(GestureDevice.navigator)
                Label("macOS Trackpad", systemImage: "rectangle.and.hand.point.up.left").tag(GestureDevice.apple)
            }.pickerStyle(.segmented).frame(width: 390)
                .accessibilityIdentifier("pointer-device-picker")
            if pointerDevice == .navigator {
                navigatorPointerSettings.accessibilityIdentifier("pointer-pane-navigator")
            } else {
                macOSPointerSettings.accessibilityIdentifier("pointer-pane-macos")
            }
            Divider()
            profiles
        }.font(.system(size: 12))
    }

    private var navigatorPointerSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                pointerCard("Pointer", icon: "cursorarrow.motionlines") {
                    MotionCurveEditor(curve: Binding(get: { store.activeProfile.resolvedCursorResponse }, set: { curve in
                        var motion = store.activeProfile
                        motion.cursorResponse = curve.sanitized
                        store.updatePointerMotion(motion)
                    }), telemetry: store.cursorTelemetry, profileID: store.activeProfileID, isActive: true)
                }
                pointerCard("Scrolling", icon: "arrow.up.and.down") {
                    ScrollCurveEditor(profile: pointerBinding)
                    Divider()
                    Toggle("Invert horizontal", isOn: pointerBinding.invertScrollX)
                    Toggle("Invert vertical", isOn: pointerBinding.invertScrollY)
                    Toggle("After-scroll coasting", isOn: pointerBinding.kineticScroll)
                    columnSlider("Coast coefficient", value: pointerBinding.kineticDecay,
                        scale: .centered(minimum: 0, maximum: ProfileMaximum.coastCoefficient,
                                         baseline: store.settings.resolvedPointerCoastBaseline))
                        .disabled(!store.activeProfile.kineticScroll)
                    Text("After lift-off, speed decays exponentially. 0 stops immediately; 100 keeps gliding until you touch again or turn it off.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            pointerWideCard("Dragging", icon: "hand.draw") { navigatorDragging }
        }
    }

    private var macOSPointerSettings: some View {
        pointerWideCard("macOS Trackpad", icon: "rectangle.and.hand.point.up.left") {
            Text("macOS owns pointer motion, scrolling and dragging for built-in and Magic Trackpads. These machine-wide settings are not stored in Rotagivan profiles.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Trackpad Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
                }
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess")!)
                }
            }
            Text("For native dragging: Accessibility → Pointer Control → Trackpad Options. Tap and swipe actions are configured in HUD.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pointerWideCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.headline)
            Divider()
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func pointerCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.headline)
            Divider()
            content()
        }.padding(16).frame(width: 338, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func gestures(_ id: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if editingAppleActions {
                Toggle("Customize Apple actions", isOn: Binding(get: {
                    store.settings.devices?.appleLayerGestures?[id] != nil
                }, set: { enabled in
                    store.updateAppleGestures(enabled ? store.settings.effectiveGestures(for: id) : nil, for: id)
                }))
                if store.settings.devices?.appleLayerGestures?[id] == nil {
                    Text("Uses this layer’s shared actions. Enable customization to override them on Apple trackpads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !editingAppleActions || store.settings.devices?.appleLayerGestures?[id] != nil {
                Toggle("Enable tap actions", isOn: gesture(id, \.tapToClick))
                LayerActionAssignmentsEditor(gestures: gestureBinding(id),
                    globalBindings: Binding(get: { store.settings.actionBindings ?? [] }, set: { updated in
                        guard updated.isValidBindings(global: true) else { return }
                        store.settings.actionBindings = updated
                    }), resolveGestures: { store.settings.applyingActionBindings(to: $0) })
                Text("Double and triple taps replace shorter tap actions. Triple taps use the double-tap delay between taps; enabling them delays double-tap actions while waiting for a third tap.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Tune tap timing, movement thresholds, and all tap + swipe families in Calibration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }



    private var navigatorDragging: some View {
        let dragging = Binding(get: { store.navigatorDragging }, set: { store.updateNavigatorDragging($0) })
        return VStack(alignment: .leading, spacing: 12) {
            ShortcutEditor(showBehavior: false, showError: false, editProfileDragShortcut: true)
            Text("Hold the shortcut and move the cursor to drag. Release the key to drop. You can lift and reposition your finger while holding the shortcut.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Tap, then touch and hold to drag", isOn: dragging.touchAndHoldDrag)
            Text("The second touch can land anywhere on the trackpad. You have at least 400 ms to touch again, then hold or move to drag. Lift to drop. This works in layers whose one-finger tap is Left click.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Allow re-grip while dragging", isOn: dragging.dragRegrip)
            columnSlider("Re-grip window", value: dragging.dragRegripWindow,
                scale: .centered(minimum: 0, maximum: ProfileMaximum.regripWindow,
                                 baseline: store.settings.resolvedNavigatorRegripBaseline))
                .disabled(!store.navigatorDragging.dragRegrip)
        }
        .font(.system(size: 12))
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            Section("Status") {
                LabeledContent("Navigator") { Text(statusText) }
                Button("Reconnect") { hid.stop(); if store.settings.enabled { hid.start() } }
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Button("Open Input Monitoring Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                Toggle("Enable Rotagivan", isOn: enabledBinding)
            }
            Divider()
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }
            Divider()
            ConfigurationSettingsView(store: store, hid: hid)
            Divider()
            SyncSettingsView(sync: sync)
            Divider()
            Section {
                Text("Rotagivan is an independent, editable implementation. Quit ZSA Navigator before using Rotagivan’s Navigator driver. Apple trackpad actions are independent of that driver.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }

    private func gestureBinding(_ id: UInt32) -> Binding<ProfileGestures> {
        Binding(get: { editableGestures(id) }, set: { updateEditableGestures($0, for: id) })
    }

    private func editableGestures(_ id: UInt32) -> ProfileGestures {
        editingAppleActions ? store.gestures(for: id, device: .apple) : store.settings.gestures(for: id)
    }

    private func updateEditableGestures(_ value: ProfileGestures, for id: UInt32) {
        if editingAppleActions { store.updateAppleGestures(value, for: id) }
        else { store.updateGestures(value, for: id) }
    }

    private func switchProfile(_ id: String?) {
        NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)
        hid.stop()
        if let id { store.selectConfiguration(id) } else { store.addConfiguration() }
        actionDevice = .navigator
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
            if store.settings.enabled { hid.start() }
        }
    }

    private func deviceBinding(_ key: WritableKeyPath<ProfileDevices, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings.resolvedDevices[keyPath: key] }, set: { enabled in
            hid.stop()
            var devices = store.settings.resolvedDevices
            devices[keyPath: key] = enabled
            store.settings.devices = devices
            if store.settings.enabled { hid.start() }
        })
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use ZSA Navigator", isOn: deviceBinding(\.navigatorEnabled))
                    Text("Cursor, scrolling, tap actions, layers and Explorer. When off, Rotagivan releases the Navigator driver.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use Apple trackpad actions", isOn: deviceBinding(\.appleEnabled))
                    Text("Built-in and Magic Trackpads. Tap actions require two nearby fingers landing together and lifting quickly without sliding. Typing briefly blocks activation. Native pointer and scrolling remain controlled by macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow Apple input on this Mac", isOn: Binding(get: { hid.appleTrackpadEnabled }, set: { hid.setAppleTrackpadEnabled($0) }))
                    Text(hid.appleTrackpadStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Experimental private macOS touch interface. Clicks take priority over touch actions. The pointer pauses only while an Apple-controlled HUD is active.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Share tap and swipe actions across devices", isOn: deviceBinding(\.shareTapActions))
            Text("The Default tap layer drives the same gestures across pointer profiles. Turn sharing off to customize Apple actions in HUD. Existing overrides are preserved when sharing is turned back on.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func gesture<Value>(_ id: UInt32, _ keyPath: WritableKeyPath<GestureSettings, Value>) -> Binding<Value> {
        gestureBinding(id).gestures[dynamicMember: keyPath]
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
    var editProfileDragShortcut = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editProfileDragShortcut {
                shortcutRow("Keyboard drag", value: $shortcuts.dragShortcut)
            } else if let index = actionIndex {
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
                        shortcutRow(profile ?? "Layer", value: Binding(get: { shortcuts.additional[id] ?? ProfileShortcut() }, set: { shortcuts.additional[id] = $0 }))
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
                TextField("Layer name", text: editableName)
                    .textFieldStyle(.roundedBorder).fontWeight(.semibold)
                    .accessibilityLabel("Layer name")
            } else { Text(profile ?? "Default").fontWeight(.semibold) }
            Text("Used automatically when no other layer is active.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }

    private func shortcutRow(_ title: String, value: Binding<ProfileShortcut>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let editableName {
                    TextField("Layer name", text: editableName)
                        .textFieldStyle(.roundedBorder)
                        .fontWeight(.semibold)
                        .accessibilityLabel("Layer name")
                        .help("Rename this layer")
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
