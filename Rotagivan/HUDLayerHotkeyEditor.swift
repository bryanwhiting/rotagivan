import SwiftUI

/// Edits actions that run while this HUD layer is visible, independently of tiles.
struct HUDLayerHotkeyEditor: View {
    @ObservedObject var store: SettingsStore
    @State private var layer: ExplorerHoldLayer
    let settings: AppExplorerSettings
    let isDefaultLayer: Bool
    let editingGroupPath: [ExplorerSlot]
    let layerTitle: String?
    @State private var editingBinding: ActionBinding?
    var onSave: (ExplorerHoldLayer, [HUDTapAssignmentScope: Set<AppGestureTrigger>]) -> Bool
    var onCancel: () -> Void

    init(store: SettingsStore, layer: ExplorerHoldLayer, settings: AppExplorerSettings,
         onSave: @escaping (ExplorerHoldLayer, [HUDTapAssignmentScope: Set<AppGestureTrigger>]) -> Bool,
         onCancel: @escaping () -> Void, isDefaultLayer: Bool = false,
         editingGroupPath: [ExplorerSlot] = [], layerTitle: String? = nil) {
        self.store = store
        var globalLayer = layer
        globalLayer.appBundleID = nil
        globalLayer.appName = nil
        _layer = State(initialValue: globalLayer)
        self.settings = settings
        self.isDefaultLayer = isDefaultLayer
        self.editingGroupPath = editingGroupPath
        self.layerTitle = layerTitle
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var draftExplorer: AppExplorerSettings {
        var result = settings
        if isDefaultLayer {
            if let direction = editingGroupPath.last,
               var group = result.favorite(at: editingGroupPath) {
                group.children = layer.favorites
                group.actionBindings = layer.actionBindings
                _ = result.setFavorite(group, at: direction, in: Array(editingGroupPath.dropLast()))
            } else {
                result.favorites = layer.favorites
                result.actionBindings = layer.actionBindings
            }
            return result
        }
        var layers = result.holdLayers ?? []
        if let index = layers.firstIndex(where: { $0.id == layer.id }) { layers[index] = layer }
        else { layers.append(layer) }
        result.holdLayers = layers
        return result
    }

    private var valid: Bool {
        !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftExplorer.hasValidFavorites
    }

    private var reservedKeys: [RecordedShortcut] {
        layer.favorites.compactMap(\.activationShortcut) +
            settings.layers(at: settings.layerScope(at: editingGroupPath)).compactMap(\.holdShortcut)
    }

    private var editorHeight: CGFloat {
        min(560, max(340, 285 + CGFloat(layer.actionBindings?.count ?? 0) * 35))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(layerTitle ?? (isDefaultLayer ? "Default HUD layer" : "HUD layer"), systemImage: "square.3.layers.3d")
                .font(.headline).padding(.bottom, 14)

            if isDefaultLayer {
                Text(editingGroupPath.isEmpty
                     ? "This layer opens first. Assign keyboard or trackpad triggers to actions here."
                     : "Assign keyboard or trackpad triggers to this HUD layer, with or without tiles.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("HUD layer name", text: $layer.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Layer actions").font(.headline)
                    Spacer()
                    Button {
                        editingBinding = ActionBinding(trigger: BindingTrigger(),
                            action: .keystroke(RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return")))
                    } label: { Label("Add action", systemImage: "plus") }
                }
                Text("A keyboard shortcut or trackpad gesture runs any action while this layer is open.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18).padding(.bottom, 10)

            if (layer.actionBindings ?? []).isEmpty {
                Text("No layer actions yet. Add one without creating a tile.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView {
                  LazyVStack(spacing: 0) {
                    ForEach(layer.actionBindings ?? []) { binding in
                        HStack(spacing: 9) {
                            Text(binding.trigger.title).fontWeight(.medium).lineLimit(1)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            Text(store.settings.resolvedHotkeyDictionary.title(for: binding.action)).lineLimit(1)
                            Spacer()
                            Button("Edit") { editingBinding = binding }
                            Button {
                                layer.actionBindings?.removeAll { $0.id == binding.id }
                            } label: { Image(systemName: "trash") }
                                .help("Remove assignment")
                        }
                        .font(.system(size: 12)).padding(.horizontal, 11).frame(minHeight: 34)
                        if binding.id != layer.actionBindings?.last?.id { Divider() }
                    }
                  }
                }
                .frame(height: min(190, CGFloat((layer.actionBindings ?? []).count) * 35))
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }

            if !valid {
                Label(isDefaultLayer
                      ? "Use unique hotkeys. Escape and bare E/S are reserved for HUD controls."
                      : "Use a layer name and unique hotkeys. Escape and bare E/S are reserved for HUD controls.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.top, 10)
            }

            Divider().padding(.vertical, 14)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { _ = saveDraft() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 620, height: editorHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingBinding) { candidate in
            BindingEditor(binding: candidate, existing: layer.actionBindings ?? [],
                reservedKeys: reservedKeys,
                title: "HUD layer action", onSave: { updated in
                    var bindings = layer.actionBindings ?? []
                    if let index = bindings.firstIndex(where: { $0.id == updated.id }) { bindings[index] = updated }
                    else { bindings.append(updated) }
                    layer.actionBindings = bindings
                    editingBinding = nil
                }, onCancel: { editingBinding = nil })
        }
    }

    /// The button and native smoke test use the same save path.
    @discardableResult func saveDraft() -> Bool {
        var globalLayer = layer
        globalLayer.appBundleID = nil
        globalLayer.appName = nil
        return onSave(globalLayer, [:])
    }

}
