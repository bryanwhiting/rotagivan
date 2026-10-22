import ServiceManagement
import SwiftUI

struct VoiceModeSettingsView: View {
    @ObservedObject var store: SettingsStore
    @AppStorage(LauncherVoiceProvider.preferenceKey) private var localProvider = LauncherVoiceProvider.openRouter.rawValue
    @ObservedObject var intentionStore: TemporaryIntentionStore = .shared
    @ObservedObject private var index = VoiceApplicationIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
        RotaCard("Action matching", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 12) {
                RotaSelect("Voice provider", selection: $localProvider,
                    options: LauncherVoiceProvider.allCases.map { RotaOption($0.label, value: $0.rawValue) })
                    .accessibilityIdentifier("voice-provider")
                Text("OpenAI streams speech to text using gpt-live-transcribe; words search local apps and menus. Press Return once to confirm and run the selected action. Auto-select applies only to OpenRouter/Jev, which sends audio to OpenRouter / xAI and text plus action names to Jev; Rotagivan does not save audio or transcripts.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Start listening when HUD opens", isOn: Binding(
                    get: { store.settings.appExplorer?.resolvedVoiceAutoStart ?? false },
                    set: { enabled in
                        var settings = store.settings.appExplorer ?? AppExplorerSettings()
                        settings.voiceAutoStart = enabled
                        store.settings.appExplorer = settings
                    }))
                    .accessibilityIdentifier("voice-auto-start")
                Text("Off by default. When enabled, opening the main HUD requests microphone access and starts listening automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Auto-select", isOn: Binding(
                    get: { store.settings.appExplorer?.resolvedVoiceAutoSelect ?? true },
                    set: { enabled in
                        var settings = store.settings.appExplorer ?? AppExplorerSettings()
                        settings.voiceAutoSelect = enabled
                        store.settings.appExplorer = settings
                    }))
                    .accessibilityIdentifier("voice-auto-select")
                Text("On by default: the HUD shows what it heard and the top matches, then runs the best match after a moment. Swipe left or press Escape to cancel, or swipe to another match to pick it instead. Turn off to always choose from the top three yourself: swipe to a match and lift to run, or swipe left to cancel. No-match results never run.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Assign Activate voice mode and edit voice keywords in Actions.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        RotaCard("Application index", systemImage: "square.grid.2x2") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Applications refresh automatically on this Mac at startup and after app changes. Voice, Actions, and app pickers share this local index.")
                    .foregroundStyle(.secondary)
                HStack {
                    if index.isRefreshing {
                        ProgressView().controlSize(.small)
                        Text("Indexing applications…")
                    } else {
                        Text("\(index.applications.count) applications")
                    }
                    Spacer()
                    Button("Reindex now") { Task { await index.refresh(force: true) } }
                        .disabled(index.isRefreshing)
                }
                if let date = index.lastRefreshedAt {
                    Text("Last indexed \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = index.refreshError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = index.observationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        RotaCard("Temporary intention", systemImage: "scope") {
            TemporaryIntentionControl(store: intentionStore)
        }
        }
        .font(.system(size: 12))
        .accessibilityIdentifier("voice-mode-settings")
        .task { await index.load() }
    }
}

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
                    .buttonStyle(.rotaPrimary)
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
    @ObservedObject var intentionStore: TemporaryIntentionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = "HUD"
    @State private var actionDevice: GestureDevice = .apple
    @State private var pointerDevice: GestureDevice = .navigator
    @State private var renamingProfile: ConfigurationProfile?
    @State private var deletingProfile: ConfigurationProfile?
    /// Persisted, user-controlled sidebar state (toggle button or ⌃⌘S).
    @AppStorage("settings.sidebarCollapsed") private var sidebarCollapsed = false
    @State private var pendingLayerDeletion: PendingLayerDeletion?
    private let initialHUDGroup: ExplorerReservedGroup?
    private let initialHUDFocus: HUDWorkspaceFocus?
    private let layerColumnWidth: CGFloat = 468

    private let sections = [("Devices", "computermouse"), ("HUD", "safari"),
        ("Actions", "bolt.circle"), ("Voice mode", "waveform"),
        ("Pointer & scrolling", "cursorarrow.motionlines"), ("General", "gearshape"), ("Sync & backup", "arrow.triangle.2.circlepath")]
    private var editingAppleActions: Bool { selection == "HUD" && actionDevice == .apple && !store.settings.resolvedDevices.shareTapActions }

    init(store: SettingsStore, hid: NavigatorHIDManager, sync: SettingsSync,
         initialSection: String = "HUD", initialDevice: GestureDevice = .apple,
         intentionStore: TemporaryIntentionStore = .shared) {
        self.store = store; self.hid = hid; self.sync = sync
        self.intentionStore = intentionStore
        let resolvedSection: String
        switch initialSection {
        case "Hotkeys", "Keybindings and Macros", "Macros", "App overrides": resolvedSection = "Actions"
        case "Calibration": resolvedSection = "HUD"
        case "Profiles", "Pointer layers": resolvedSection = "Pointer & scrolling"
        case "Devices", "HUD", "Actions", "Voice mode", "Pointer & scrolling", "General", "Sync & backup": resolvedSection = initialSection
        default: resolvedSection = "HUD"
        }
        _selection = State(initialValue: resolvedSection)
        initialHUDGroup = initialSection == "Window Manager" ? .windowManager : nil
        initialHUDFocus = initialSection == "Calibration" ? .calibration : nil
        _actionDevice = State(initialValue: initialDevice)
        _pointerDevice = State(initialValue: .navigator)   // Pointer motion controls are Navigator-specific.
    }

    private func sectionTitle(_ section: String) -> String {
        switch section {
        case "Actions": return "Actions"
        default: return section
        }
    }

    private var settingsLayout: some View {
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
        .toggleStyle(.rotaCheckbox)
        .buttonStyle(.rotaSecondary)
        .tint(.primary)
        .environment(\.hotkeyDictionary, store.settings.resolvedHotkeyDictionary)
        .environment(\.actionPickerMacroTools, ActionPickerMacroTools.live(store: store))
        .environment(\.hudActionLayers, store.settings.appExplorer?.holdLayers ?? [])
        .environment(\.hudActionDestinations, store.settings.appExplorer?.hudActionDestinations() ?? [])
        // The HUD workspace needs room for its list, canvas and inspector.
        .frame(minWidth: selection == "HUD" ? 1100 : 860, idealWidth: selection == "HUD" ? 1220 : 940, maxWidth: .infinity,
               minHeight: 680, idealHeight: 740, maxHeight: .infinity)
    }

    private var profileEditingContent: some View {
        settingsLayout
        .sheet(item: $renamingProfile) { profile in
            ProfileNameEditor(name: profile.name, onSave: { name in
                guard store.renameConfiguration(name, for: profile.id) else { return false }
                renamingProfile = nil
                return true
            }, onCancel: { renamingProfile = nil })
        }
        .confirmationDialog("Delete profile “\(deletingProfile?.name ?? "")”?",
            isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                if let id = deletingProfile?.id { deleteProfile(id) }
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) { deletingProfile = nil }
        } message: {
            Text("Its devices, layers, HUD and shortcuts are removed. Other profiles are unchanged.")
        }
    }

    var body: some View {
        profileEditingContent
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
        HStack(spacing: RotaTokens.Space.l) {
            Button {
                if reduceMotion { sidebarCollapsed.toggle() }
                else { withAnimation(.snappy(duration: 0.22)) { sidebarCollapsed.toggle() } }
            } label: {
                Label(sidebarCollapsed ? "Show sidebar" : "Hide sidebar", systemImage: "sidebar.left")
            }
            .buttonStyle(.rotaIcon)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(sidebarCollapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)")
            .accessibilityIdentifier("toggle-sidebar")
            VStack(alignment: .leading, spacing: 2) {
                Text("ROTAGIVAN").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                Text(sectionTitle(selection))
                    .font(.system(size: 19, weight: .semibold)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settings-header-title")
            }
            Spacer()
            RotaProfileSwitcher(profiles: store.configurationProfiles, activeID: store.activeConfigurationID,
                onSelect: { switchProfile($0) },
                onAdd: { switchProfile(nil, fresh: true) },
                onRename: { renamingProfile = store.configurationProfiles.first { $0.id == store.activeConfigurationID } },
                onDuplicate: { switchProfile(nil) },
                onDelete: { deletingProfile = store.configurationProfiles.first { $0.id == store.activeConfigurationID } })
        }
        .padding(.horizontal, RotaTokens.Space.l + 2).padding(.vertical, RotaTokens.Space.xl)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.xxs + 1) {
            ForEach(Array(sections.enumerated()), id: \.element.0) { index, section in
                sidebarRow(section.0, icon: section.1, index: index)
            }
            Spacer()
        }
        .padding(sidebarCollapsed ? RotaTokens.Space.m : RotaTokens.Space.l).padding(.top, RotaTokens.Space.xs)
        .frame(width: sidebarCollapsed ? 56 : 196)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    private func sidebarRow(_ title: String, icon: String, index: Int) -> some View {
        let selected = selection == title
        return Button { selection = title } label: {
            HStack(spacing: RotaTokens.Space.m + 1) {
                Image(systemName: icon)
                    .font(.system(size: sidebarCollapsed ? 14 : 12.5, weight: .medium))
                    .foregroundStyle(selected ? RotaTokens.accent : Color.secondary)
                    .frame(width: 18)
                if !sidebarCollapsed {
                    Text(sectionTitle(title)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            .frame(maxWidth: .infinity, alignment: sidebarCollapsed ? .center : .leading)
            .padding(.horizontal, sidebarCollapsed ? 0 : RotaTokens.Space.m + 2).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.m + 1, style: .continuous)
                .fill(selected ? RotaTokens.accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(sectionTitle(title)) (⌘\(index + 1))")
        .accessibilityLabel(sectionTitle(title))
        .accessibilityIdentifier("settings-section-\(title)")
    }

    private var page: some View {
        Group {
            if selection == "HUD" {
                hudAndTapSettings
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(store.activeConfigurationID)
            } else {
                GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(pageSubtitle)
                            .font(.callout).foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-page-heading")
                        pageContent
                    }
                    .frame(width: selection == "Actions" ? max(708, viewport.size.width - 44) : 708,
                        alignment: .leading).padding(22)
                    .environment(\.actionsTableHeight, max(520, viewport.size.height - 240))
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                    .id(store.activeConfigurationID)
                }
                }
            }
        }
        .background {
            if selection == "HUD" {
                ExplorerSettingsBackdrop(theme: store.settings.appExplorer?.resolvedTheme ?? .starburstAir)
            }
        }
    }

    private var pageSubtitle: String {
        switch selection {
        case "Sync & backup": return "Keep settings and API keys in the cloud (encrypted) or in a local settings.yaml you can put in git."
        case "General": return "Permissions and startup belong to this Mac."
        case "Pointer & scrolling": return "Device controls for \(store.activeConfigurationName). Navigator tuning applies across its action layers."
        default: return "Settings for \(store.activeConfigurationName)"
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch selection {
        case "General": general
        case "Sync & backup":
            SyncSettingsView(sync: sync)
            ConfigurationSettingsView(store: store, hid: hid)
        case "Devices": devices
        case "HUD": hudAndTapSettings
        case "Actions":
            HotkeyOrganizerView(store: store)
        case "Voice mode": VoiceModeSettingsView(store: store, intentionStore: intentionStore)
        case "Pointer & scrolling": pointerSettings
        default: hudAndTapSettings
        }
    }

    private var hudAndTapSettings: some View {
        HUDSettingsView(store: store, initialGroup: initialHUDGroup, initialFocus: initialHUDFocus,
                        defaultTaps: { AnyView(defaultTapSettings.accessibilityIdentifier("default-tap-settings")) },
                        calibration: { AnyView(CalibrationSettingsView(store: store, hid: hid, initialDevice: actionDevice)) })
    }

    private var defaultTapSettings: some View {
            RotaCard {
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
                        HStack(spacing: 8) {
                            Text("Edit actions for")
                            RotaSegmented("Edit actions for", selection: $actionDevice, values: GestureDevice.allCases) { $0.title }
                        }
                    } else {
                        Label("One set of actions for Navigator and Apple trackpads", systemImage: "link")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    gestures(store.defaultProfileID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    private var footer: some View {
        HStack {
            Text("\(store.activeConfigurationName)  /  \(store.activeProfileName)")
            Spacer()
            Text(AppVersion.display)
                .help(AppVersion.buildDetails)
                .accessibilityIdentifier("rota-settings-version")
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
                Button("Make default") { makeDefault(id) }.buttonStyle(.rotaLink).font(.caption)
            }
            if store.canRemoveProfile(id) {
                Button {
                    pendingLayerDeletion = PendingLayerDeletion(id: id, name: title)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.rotaIcon)
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
            RotaSegmented("Device", selection: $pointerDevice, options: [
                RotaOption("ZSA Navigator", value: GestureDevice.navigator, systemImage: "computermouse"),
                RotaOption("macOS Trackpad", value: GestureDevice.apple, systemImage: "rectangle.and.hand.point.up.left")])
                .accessibilityIdentifier("pointer-device-picker")
            if pointerDevice == .navigator {
                navigatorPointerSettings.accessibilityIdentifier("pointer-pane-navigator")
            } else {
                macOSPointerSettings.accessibilityIdentifier("pointer-pane-macos")
            }
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

    private func pointerWideCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        RotaCard(title, systemImage: icon) {
            VStack(alignment: .leading, spacing: 14) { content() }
        }
    }

    private func pointerCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        RotaCard(title, systemImage: icon) {
            VStack(alignment: .leading, spacing: 14) { content() }
        }.frame(width: 338, alignment: .topLeading)
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
                Text("Tune tap timing, movement thresholds, and all tap + swipe families in Actions → Tap calibration.")
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
        VStack(alignment: .leading, spacing: 16) {
            RotaCard("Status", systemImage: "dot.radiowaves.left.and.right") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Navigator") { Text(statusText).foregroundStyle(.secondary) }
                    Toggle("Enable Rotagivan", isOn: enabledBinding).toggleStyle(.rotaSwitch)
                    HStack(spacing: 8) {
                        Button("Reconnect") { hid.stop(); if store.settings.enabled { hid.start() } }
                        Button("Set up this Mac…") { hid.presentOnboarding() }
                            .accessibilityIdentifier("open-accessibility-setup")
                        Button("Open Input Monitoring Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                        }
                    }
                }
            }
            RotaCard("Startup", systemImage: "power") {
                Toggle("Launch at login", isOn: launchAtLoginBinding).toggleStyle(.rotaSwitch)
            }
            MCPSettingsCard()
            Text("Rotagivan is an independent, editable implementation. Quit ZSA Navigator before using Rotagivan’s Navigator driver. Apple trackpad actions are independent of that driver.")
                .font(.callout)
                .foregroundStyle(.secondary)
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

    private func deleteProfile(_ id: String) {
        NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)
        hid.stop()
        store.deleteConfiguration(id)
        actionDevice = .navigator
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
            if store.settings.enabled { hid.start() }
        }
    }

    private func switchProfile(_ id: String?, fresh: Bool = false) {
        NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)
        let before = store.settings
        if let id { store.selectConfiguration(id) } else { store.addConfiguration(fresh: fresh) }
        actionDevice = .apple
        // Same devices on both profiles: keep the trackpad open and only reset
        // gesture state. Otherwise reopen the devices for the new settings.
        // The light reload re-reads Apple input settings itself, so the Navigator
        // only needs reopening when its own enablement changes.
        let sameDevices = before.enabled == store.settings.enabled
            && before.resolvedDevices.navigatorEnabled == store.settings.resolvedDevices.navigatorEnabled
        if sameDevices && store.settings.enabled {
            hid.reloadProfile()
            DispatchQueue.main.async { NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil) }
        } else {
            hid.stop()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
                if store.settings.enabled { hid.start() }
            }
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
            RotaCard("ZSA Navigator", systemImage: "computermouse") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use ZSA Navigator", isOn: deviceBinding(\.navigatorEnabled)).toggleStyle(.rotaSwitch)
                    Text("Cursor, scrolling, tap actions, layers and Explorer. When off, Rotagivan releases the Navigator driver.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            RotaCard("Apple trackpads", systemImage: "rectangle.and.hand.point.up.left") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use Apple trackpad actions", isOn: deviceBinding(\.appleEnabled)).toggleStyle(.rotaSwitch)
                    Text("Built-in and Magic Trackpads. Tap actions require two nearby fingers landing together and lifting quickly without sliding. Typing briefly blocks activation. Native pointer and scrolling remain controlled by macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow Apple input on this Mac", isOn: Binding(get: { hid.appleTrackpadEnabled }, set: { hid.setAppleTrackpadEnabled($0) }))
                    Text(hid.appleTrackpadStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Experimental private macOS touch interface. Clicks take priority over touch actions. The pointer pauses only while an Apple-controlled HUD is active.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
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
                Toggle("Hotkey", isOn: value.enabled).toggleStyle(.rotaSwitch).controlSize(.small)
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
                RotaSelect("Key", selection: value.keyCode,
                    options: ShortcutSettings.keys.map { RotaOption($0.0, value: $0.1) }, fill: true)
                    .frame(width: 120)
                ForEach([( "⌃", UInt32(4096)), ("⌥", UInt32(2048)), ("⇧", UInt32(512)), ("⌘", UInt32(256))], id: \.1) { label, flag in
                    Toggle(label, isOn: Binding(get: { value.wrappedValue.modifiers & flag != 0 }, set: { on in
                        if on { value.wrappedValue.modifiers |= flag }
                        else { value.wrappedValue.modifiers &= ~flag }
                    }))
                    .toggleStyle(.rotaChip)
                    .help(flag == 4096 ? "Control" : flag == 2048 ? "Option" : flag == 512 ? "Shift" : "Command")
                }
            }.disabled(!value.wrappedValue.enabled)
            }
            if showBehavior && actionIndex == nil {
                RotaSegmented("\(title) activation", selection: Binding(get: { value.wrappedValue.holdToActivate ?? true }, set: { value.wrappedValue.holdToActivate = $0 }),
                    options: [RotaOption("Hold to activate", value: true), RotaOption("Tap to toggle", value: false)])
                .disabled(!value.wrappedValue.enabled)
            }
        }.padding(.vertical, 4)
    }
}

// MARK: - Profile switcher
// Built from RotaMenuButton (UIComponents.swift).

/// One compact control for the configuration profile library: switch, rename,
/// duplicate and delete live in a single menu instead of scattered buttons.
struct RotaProfileSwitcher: View {
    let profiles: [ConfigurationProfile]
    let activeID: String
    var onSelect: (String) -> Void
    var onAdd: () -> Void = {}
    var onRename: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var maximumProfiles = 20

    private var activeName: String { profiles.first { $0.id == activeID }?.name ?? "Default" }

    var body: some View {
        HStack(spacing: RotaTokens.Space.s) {
            Text(String(activeName.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(RotaTokens.accent.gradient))
                .accessibilityHidden(true)
            RotaMenuButton(activeName, kind: .field) {
                Section("Profiles") {
                    ForEach(profiles) { profile in
                        Button { onSelect(profile.id) } label: {
                            if profile.id == activeID { Label(profile.name, systemImage: "checkmark") }
                            else { Text(profile.name) }
                        }
                    }
                }
                Divider()
                Button("Add profile", systemImage: "plus", action: onAdd)
                    .disabled(profiles.count >= maximumProfiles)
                    .accessibilityIdentifier("add-profile")
                Button("Duplicate", action: onDuplicate)
                    .disabled(profiles.count >= maximumProfiles)
                    .accessibilityIdentifier("duplicate-profile")
                Button("Rename…", action: onRename)
                    .accessibilityIdentifier("rename-profile")
                Button("Delete…", role: .destructive, action: onDelete)
                    .disabled(profiles.count <= 1)
                    .accessibilityIdentifier("delete-profile")
            }
            .accessibilityLabel("Profile")
            .accessibilityValue(activeName)
            .accessibilityIdentifier("profile-switcher")
        }
        .help("Switch, add, duplicate, rename or delete profiles")
    }
}
