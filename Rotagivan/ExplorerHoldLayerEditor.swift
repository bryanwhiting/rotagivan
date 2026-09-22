import SwiftUI
import UniformTypeIdentifiers

struct ExplorerHoldLayerEditor: View {
    @State var layer: ExplorerHoldLayer
    let settings: AppExplorerSettings
    var onSave: (ExplorerHoldLayer) -> Void
    var onCancel: () -> Void
    var supportsDirectLaunch = true
    @State private var action: TapAction = .shortcut
    private var valid: Bool {
        var candidate = settings
        candidate.holdLayers = (settings.holdLayers ?? []).filter { $0.id != layer.id } + [layer]
        return candidate.hasValidFavorites
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("HUD layer", systemImage: "square.3.layers.3d").font(.headline)
            TextField("HUD layer name", text: $layer.name).textFieldStyle(.roundedBorder)
            TapActionEditor(title: "Key while this HUD is open", action: $action, shortcut: $layer.holdShortcut, keyboardOnly: true, physicalKeysOnly: true)
            Picker("Activation", selection: Binding(get: { layer.activation ?? .hold }, set: { layer.activation = $0 })) {
                Text("Hold").tag(ExplorerLayerActivation.hold)
                Text("Tap to toggle").tag(ExplorerLayerActivation.toggle)
            }.pickerStyle(.segmented)
            if layer.holdShortcut != nil { Button("Clear in-HUD key") { layer.holdShortcut = nil }.font(.caption) }
            if supportsDirectLaunch {
                Divider()
                TapActionEditor(title: "Open this HUD layer from anywhere", action: $action, shortcut: $layer.launchShortcut, keyboardOnly: true, physicalKeysOnly: true)
                if layer.launchShortcut != nil { Button("Clear open-layer key") { layer.launchShortcut = nil }.font(.caption) }
                Text("Keyboard shortcuts are optional. You can also assign a tap directly from this layer’s card. Swipe actions and app-specific overrides remain available in Layer actions. Use a modifier with letter-based launch keys.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(layer.appName.map { "Only in \($0)" } ?? "Available in every app")
                Spacer()
                Button("Choose app…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url, let app = ExplorerApplicationCatalog.application(at: url) {
                        layer.appBundleID = app.bundleID; layer.appName = app.name
                    }
                }
                if layer.appBundleID != nil { Button("All apps") { layer.appBundleID = nil; layer.appName = nil } }
            }
            Text("An app restriction applies to this layer’s launch key, gesture targets, and in-HUD activation key. Use App overrides to make a gesture open this layer only in that app.").font(.caption).foregroundStyle(.secondary)
            Text("New HUD layers start empty. The in-HUD key switches from the current layer to this one: hold temporarily or tap to toggle. Cursor and tap profiles are unchanged. Click a HUD tile after saving to edit it; each window-position tile has its own size and placement.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !valid { Text("Use a name, a unique hold key (not Escape), and a modifier for letter-based launch keys. Up to 16 layers and 256 total slots are supported.").font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { if valid { onSave(layer) } }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 450).background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A focused shortcut from a HUD layer to the six discrete trackpad taps. More
/// complex directional gestures remain in Layer actions, where their timing and
/// distance controls are visible together.
struct HUDLayerTapAssignmentEditor: View {
    @ObservedObject var store: SettingsStore
    let layer: ExplorerHoldLayer
    var onDone: () -> Void
    @State private var profileID: UInt32
    @State private var device: GestureDevice = .navigator
    @State private var trigger: AppGestureTrigger = .oneFingerTap
    @State private var savedMessage: String?

    private static let tapTriggers: [AppGestureTrigger] = [
        .oneFingerTap, .oneFingerDoubleTap, .oneFingerTripleTap,
        .twoFingerTap, .twoFingerDoubleTap, .twoFingerTripleTap
    ]

    init(store: SettingsStore, layer: ExplorerHoldLayer, onDone: @escaping () -> Void) {
        self.store = store
        self.layer = layer
        self.onDone = onDone
        _profileID = State(initialValue: store.activeProfileID)
    }

    private var appleUsesSeparateActions: Bool {
        device == .apple && !store.settings.resolvedDevices.shareTapActions
    }

    private func assign() {
        var gestures: ProfileGestures
        if appleUsesSeparateActions {
            gestures = store.settings.devices?.appleLayerGestures?[profileID]
                ?? store.settings.effectiveGestures(for: profileID)
        } else {
            gestures = store.settings.effectiveGestures(for: profileID)
        }
        guard gestures.assignTapShortcut(.hudLayer(layer), to: trigger) else { return }
        if appleUsesSeparateActions {
            store.updateAppleGestures(gestures, for: profileID)
        } else {
            store.updateGestures(gestures, for: profileID)
            if profileID != store.defaultProfileID {
                var custom = store.settings.customTapProfiles ?? []
                custom.insert(profileID)
                store.settings.customTapProfiles = custom
            }
        }
        savedMessage = "\(trigger.title) now opens \(layer.name)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Open \(layer.name) with a tap", systemImage: "hand.tap")
                .font(.title2.weight(.semibold))
            Text("Choose where the tap lives. Assigning it replaces that tap’s current action; the layer card will show the new source immediately.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Action layer", selection: $profileID) {
                ForEach(store.profiles, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Trackpad", selection: $device) {
                ForEach(GestureDevice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Tap action", selection: $trigger) {
                ForEach(Self.tapTriggers, id: \.self) { Text($0.title).tag($0) }
            }
            if device == .apple && !appleUsesSeparateActions {
                Text("Apple trackpad actions are currently shared with ZSA Navigator, so this assignment applies to both devices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                Button("Done", action: onDone).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Assign tap to layer", action: assign).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
