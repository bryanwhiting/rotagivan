import SwiftUI

struct HUDLayerHotkeyEditor: View {
    @ObservedObject var store: SettingsStore
    @State private var layer: ExplorerHoldLayer
    let settings: AppExplorerSettings
    var onSave: (ExplorerHoldLayer, [HUDTapAssignmentScope: Set<AppGestureTrigger>]) -> Bool
    var onCancel: () -> Void
    var supportsDirectLaunch = true

    @State private var profileID: UInt32
    @State private var device: GestureDevice = .navigator
    @State private var tapDrafts: [HUDTapAssignmentScope: Set<AppGestureTrigger>] = [:]
    @State private var pendingReplacement: AppGestureTrigger?

    init(store: SettingsStore, layer: ExplorerHoldLayer, settings: AppExplorerSettings,
         onSave: @escaping (ExplorerHoldLayer, [HUDTapAssignmentScope: Set<AppGestureTrigger>]) -> Bool,
         onCancel: @escaping () -> Void, supportsDirectLaunch: Bool = true) {
        self.store = store
        var globalLayer = layer
        globalLayer.appBundleID = nil
        globalLayer.appName = nil
        _layer = State(initialValue: globalLayer)
        self.settings = settings
        self.onSave = onSave
        self.onCancel = onCancel
        self.supportsDirectLaunch = supportsDirectLaunch
        _profileID = State(initialValue: store.activeProfileID)
    }

    private var scope: HUDTapAssignmentScope {
        let canonicalDevice: GestureDevice =
            device == .apple && store.settings.resolvedDevices.shareTapActions ? .navigator : device
        return HUDTapAssignmentScope(profileID: profileID, device: canonicalDevice)
    }

    private var scopeGestures: ProfileGestures {
        if scope.device == .apple && !store.settings.resolvedDevices.shareTapActions {
            return store.settings.devices?.appleLayerGestures?[scope.profileID]
                ?? store.settings.effectiveGestures(for: scope.profileID)
        }
        return store.settings.effectiveGestures(for: scope.profileID)
    }

    private var desiredTapHotkeys: Set<AppGestureTrigger> {
        tapDrafts[scope] ?? Set(scopeGestures.tapTriggers(targetingHUDLayer: layer.id))
    }

    private var draftExplorer: AppExplorerSettings {
        var result = settings
        var layers = result.holdLayers ?? []
        if let index = layers.firstIndex(where: { $0.id == layer.id }) { layers[index] = layer }
        else { layers.append(layer) }
        result.holdLayers = layers
        return result
    }

    private var auditSettings: StoredSettings {
        var result = store.settings
        result.appExplorer = draftExplorer
        return result
    }

    private var keyboardConflicts: [HotkeyAudit.Assignment] {
        guard let shortcut = layer.launchShortcut, shortcut.isPhysicalShortcut else { return [] }
        let source = ShortcutSettings.shared
        let shortcuts = store.captureShortcuts?() ?? ShortcutConfiguration(
            normal: source.normal, precision: source.precision, actions: source.actions,
            additional: source.additional, profileActions: source.profileActions,
            dragShortcut: source.dragShortcut,
            holdToActivate: UserDefaults.standard.object(forKey: "shortcut.hold") as? Bool ?? true
        )
        return HotkeyAudit(settings: auditSettings, shortcuts: shortcuts, layerID: profileID, device: device)
            .assignments
            .filter {
                $0.enabled && $0.inputScope == "" && $0.shortcut?.identity == shortcut.identity &&
                    $0.id != "hud.launch.\(layer.id)"
            }
    }

    private var valid: Bool {
        draftExplorer.hasValidFavorites && keyboardConflicts.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("HUD layer", systemImage: "square.3.layers.3d")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("HUD layer name", text: $layer.name)
                        .textFieldStyle(.roundedBorder)

                    insideHUDSection

                    if supportsDirectLaunch {
                        Divider()
                        globalHotkeysSection
                    }

                    Text("New HUD layers start empty. The in-HUD key switches from the current layer to this one. Cursor and tap profiles are unchanged; each window-position tile keeps its own size and placement.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().padding(.vertical, 14)

            if !valid {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    var globalLayer = layer
                    globalLayer.appBundleID = nil
                    globalLayer.appName = nil
                    _ = onSave(globalLayer, tapDrafts)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 520, height: supportsDirectLaunch ? 680 : 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            pendingReplacement.map { "Replace \($0.title)?" } ?? "Replace tap hotkey?",
            isPresented: Binding(get: { pendingReplacement != nil }, set: { if !$0 { pendingReplacement = nil } }),
            titleVisibility: .visible
        ) {
            if let trigger = pendingReplacement {
                Button("Replace current assignment", role: .destructive) {
                    setTap(trigger, assigned: true)
                    pendingReplacement = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingReplacement = nil }
        } message: {
            if let trigger = pendingReplacement {
                Text("\(trigger.title) currently runs \(tapStatus(trigger).detail). Saving will update the same assignment shown in Layer actions.")
            }
        }
    }

    private var insideHUDSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Inside this HUD", detail: "Optional key for switching to this layer while another HUD is open")
            HStack(spacing: 8) {
                ShortcutRecorder(title: layer.holdShortcut?.displayName ?? "Record in-HUD key…") {
                    layer.holdShortcut = $0
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                if layer.holdShortcut != nil {
                    Button("Clear") { layer.holdShortcut = nil }
                }
            }
            Picker("Activation", selection: Binding(
                get: { layer.activation ?? .hold },
                set: { layer.activation = $0 }
            )) {
                Text("Hold").tag(ExplorerLayerActivation.hold)
                Text("Tap to toggle").tag(ExplorerLayerActivation.toggle)
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private var globalHotkeysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Open this HUD layer from anywhere",
                detail: "Assign a keyboard hotkey, one or more tap hotkeys, or both")

            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard hotkey")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ShortcutRecorder(title: layer.launchShortcut?.displayName ?? "Record hotkey…") {
                        layer.launchShortcut = $0
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    if layer.launchShortcut != nil {
                        Button("Clear") { layer.launchShortcut = nil }
                    }
                }
                keyboardAvailability
            }

            Divider()

            HStack {
                Text("Tap hotkeys")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Action layer", selection: $profileID) {
                    ForEach(store.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 130)
                Picker("Trackpad", selection: $device) {
                    ForEach(GestureDevice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 135)
            }

            if device == .apple && store.settings.resolvedDevices.shareTapActions {
                Text("Apple tap hotkeys are shared with ZSA Navigator, so this selection updates both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(AppGestureTrigger.baseTapTriggers.enumerated()), id: \.element.id) { index, trigger in
                    tapRow(trigger)
                    if index < AppGestureTrigger.baseTapTriggers.count - 1 {
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }

            Text("Tap hotkeys are the same assignments shown in Layer actions. Saving here updates that list; occupied taps are never replaced without confirmation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder
    private var keyboardAvailability: some View {
        if layer.launchShortcut == nil {
            Text("Optional. Use a modifier with letter-based global hotkeys.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if keyboardConflicts.isEmpty {
            Label("Available global hotkey", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("Already used by another Rotagivan hotkey", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(Array(keyboardConflicts.prefix(3))) { conflict in
                    Text("• \(conflict.scope) · \(conflict.trigger)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Clear this key or record another combination before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tapRow(_ trigger: AppGestureTrigger) -> some View {
        let status = tapStatus(trigger)
        let selected = desiredTapHotkeys.contains(trigger)
        return HStack(spacing: 9) {
            Image(systemName: selected ? "checkmark.circle.fill" : "hand.tap")
                .foregroundStyle(selected ? Color.accentColor : (status.available ? Color.green : Color.orange))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(trigger.title)
                Text(selected ? "Assigned to this HUD layer" : status.detail)
                    .font(.caption)
                    .foregroundStyle(selected || status.available ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
            if selected {
                Button("Remove") { setTap(trigger, assigned: false) }
                    .buttonStyle(.link)
            } else {
                Button(status.available ? "Assign" : "Replace…") {
                    if status.available { setTap(trigger, assigned: true) }
                    else { pendingReplacement = trigger }
                }
                .buttonStyle(.link)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 42)
        .accessibilityIdentifier("hud-tap-hotkey-\(trigger.rawValue)")
    }

    private func tapStatus(_ trigger: AppGestureTrigger) -> (available: Bool, detail: String) {
        let binding = trigger.assignment(in: scopeGestures).binding
        if binding.shortcut?.hudLayerID == layer.id, !desiredTapHotkeys.contains(trigger) {
            return (true, "Available after save")
        }
        guard binding.action != .none else { return (true, "Available") }
        if binding.action == .shortcut, let shortcut = binding.shortcut {
            if let id = shortcut.hudLayerID {
                let name = store.settings.appExplorer?.holdLayers?.first { $0.id == id }?.name ?? shortcut.keyLabel
                return (false, "Used by HUD layer \(name)")
            }
            return (false, "Used by \(store.settings.resolvedHotkeyDictionary.title(for: shortcut))")
        }
        return (false, "Used by \(binding.action.title)")
    }

    private func setTap(_ trigger: AppGestureTrigger, assigned: Bool) {
        var next = desiredTapHotkeys
        if assigned { next.insert(trigger) } else { next.remove(trigger) }
        tapDrafts[scope] = next
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var validationMessage: String {
        if !keyboardConflicts.isEmpty { return "Choose a keyboard hotkey that is not already registered by Rotagivan." }
        return "Use a name, a unique in-HUD key (not Escape), and a modifier for letter-based global hotkeys."
    }
}
