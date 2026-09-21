import SwiftUI

struct ExplorerHoldLayerEditor: View {
    @State var layer: ExplorerHoldLayer
    let settings: AppExplorerSettings
    var onSave: (ExplorerHoldLayer) -> Void
    var onCancel: () -> Void
    @State private var action: TapAction = .shortcut
    private var valid: Bool {
        var candidate = settings
        candidate.holdLayers = (settings.holdLayers ?? []).filter { $0.id != layer.id } + [layer]
        return candidate.hasValidFavorites
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Explorer layer", systemImage: "square.3.layers.3d").font(.headline)
            TextField("Layer name", text: $layer.name).textFieldStyle(.roundedBorder)
            TapActionEditor(title: "Key while this group / applet is open", action: $action, shortcut: $layer.holdShortcut, keyboardOnly: true)
            Picker("Activation", selection: Binding(get: { layer.activation ?? .hold }, set: { layer.activation = $0 })) {
                Text("Hold").tag(ExplorerLayerActivation.hold)
                Text("Tap to toggle").tag(ExplorerLayerActivation.toggle)
            }.pickerStyle(.segmented)
            if layer.holdShortcut != nil { Button("Clear hold key") { layer.holdShortcut = nil }.font(.caption) }
            Text("This key selects the layer’s tiles within its owning group. Hold temporarily or tap to toggle. Cursor and tap layers are unchanged. Edit the slots in the grid after saving; each window-position tile has its own size and placement.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !valid { Text("Use a name and a unique hold key (not Escape or the Explorer mode hotkey). Up to 16 layers and 256 total slots are supported.").font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { if valid { onSave(layer) } }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 450).background(Color(nsColor: .windowBackgroundColor))
    }
}
