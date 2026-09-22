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
            Label("Explorer layer", systemImage: "square.3.layers.3d").font(.headline)
            TextField("Layer name", text: $layer.name).textFieldStyle(.roundedBorder)
            TapActionEditor(title: "Key while this group / applet is open", action: $action, shortcut: $layer.holdShortcut, keyboardOnly: true, physicalKeysOnly: true)
            Picker("Activation", selection: Binding(get: { layer.activation ?? .hold }, set: { layer.activation = $0 })) {
                Text("Hold").tag(ExplorerLayerActivation.hold)
                Text("Tap to toggle").tag(ExplorerLayerActivation.toggle)
            }.pickerStyle(.segmented)
            if layer.holdShortcut != nil { Button("Clear hold key") { layer.holdShortcut = nil }.font(.caption) }
            if supportsDirectLaunch {
                Divider()
                TapActionEditor(title: "Open this HUD layer from anywhere", action: $action, shortcut: $layer.launchShortcut, keyboardOnly: true, physicalKeysOnly: true)
                if layer.launchShortcut != nil { Button("Clear open-layer key") { layer.launchShortcut = nil }.font(.caption) }
                Text("Keyboard shortcuts are optional. In Layers or App overrides, use the HUD layer menu beside a tap, double-tap, or swipe action to open this layer with that gesture. Use a modifier with letter-based launch keys.").font(.caption).foregroundStyle(.secondary)
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
            Text("New layers start empty. This key selects the layer’s tiles within its owning group. Hold temporarily or tap to toggle. Cursor and tap layers are unchanged. Click a HUD tile after saving to edit it; each window-position tile has its own size and placement.")
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
