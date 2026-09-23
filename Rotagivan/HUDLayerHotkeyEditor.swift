import SwiftUI

/// Edits the layer's name and its visible hotkey → tile-action pairs.
/// Legacy layer-opening keys remain decodable for migration, but are no longer
/// presented as the way to configure a HUD layer.
struct HUDLayerHotkeyEditor: View {
    @ObservedObject var store: SettingsStore
    @State private var layer: ExplorerHoldLayer
    let settings: AppExplorerSettings
    var onSave: (ExplorerHoldLayer, [HUDTapAssignmentScope: Set<AppGestureTrigger>]) -> Bool
    var onCancel: () -> Void

    init(store: SettingsStore, layer: ExplorerHoldLayer, settings: AppExplorerSettings,
         onSave: @escaping (ExplorerHoldLayer, [HUDTapAssignmentScope: Set<AppGestureTrigger>]) -> Bool,
         onCancel: @escaping () -> Void, supportsDirectLaunch _: Bool = true) {
        self.store = store
        var globalLayer = layer
        globalLayer.appBundleID = nil
        globalLayer.appName = nil
        _layer = State(initialValue: globalLayer)
        self.settings = settings
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var draftExplorer: AppExplorerSettings {
        var result = settings
        var layers = result.holdLayers ?? []
        if let index = layers.firstIndex(where: { $0.id == layer.id }) { layers[index] = layer }
        else { layers.append(layer) }
        result.holdLayers = layers
        return result
    }

    private var valid: Bool {
        !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftExplorer.hasValidFavorites
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("HUD layer", systemImage: "square.3.layers.3d")
                .font(.headline).padding(.bottom, 14)

            TextField("HUD layer name", text: $layer.name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Action hotkeys").font(.headline)
                Text("A hotkey runs the same action as its HUD tile while this layer is open. Assign apps, URLs, macros, macOS commands, media controls, window actions, or another HUD layer to a tile first.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18).padding(.bottom, 10)

            if layer.favorites.isEmpty {
                ContentUnavailableView("No actions in this layer", systemImage: "keyboard.badge.ellipsis",
                    description: Text("Save the layer, then click one of its HUD tiles to choose an action and assign a hotkey."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(layer.favorites.indices, id: \.self) { index in
                            actionRow(index)
                            if index != layer.favorites.indices.last { Divider().padding(.leading, 42) }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                }
            }

            if !valid {
                Label("Use a layer name and unique hotkeys. Escape and bare E/S are reserved for HUD controls.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.top, 10)
            }

            Divider().padding(.vertical, 14)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    var globalLayer = layer
                    globalLayer.appBundleID = nil
                    globalLayer.appName = nil
                    _ = onSave(globalLayer, [:])
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 620, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func actionRow(_ index: Int) -> some View {
        let favorite = layer.favorites[index]
        return HStack(spacing: 10) {
            Image(systemName: favorite.action?.symbol ?? (favorite.shortcut != nil ? "keyboard" :
                (favorite.isGroup ? "square.3.layers.3d" : (favorite.url != nil ? "globe" : "app"))))
                .foregroundStyle(Color.accentColor).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(favorite.name).lineLimit(1)
                Text(favorite.direction.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ShortcutRecorder(title: favorite.activationShortcut?.readableCombination ?? "Assign hotkey…") { shortcut in
                layer.favorites[index].activationShortcut = shortcut
            }
            .frame(width: 190).frame(minHeight: 28)
            if favorite.activationShortcut != nil {
                Button("Clear") { layer.favorites[index].activationShortcut = nil }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 54)
        .accessibilityIdentifier("hud-action-hotkey-\(favorite.direction.rawValue)")
    }
}
