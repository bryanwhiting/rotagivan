import SwiftUI
import UniformTypeIdentifiers

struct AppOverridesView: View {
    @ObservedObject var store: SettingsStore
    @State private var selected = "com.google.Chrome"
    @State private var error: String?
    private var apps: [AppGestureOverride] { store.settings.resolvedAppOverrides }
    private var app: AppGestureOverride? { apps.first { $0.bundleID == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("App overrides").font(.title3.weight(.semibold))
                    Text("Only the actions listed here change. Everything else inherits from your active layer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add app…", action: addApp)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !apps.isEmpty {
                Picker("Application", selection: $selected) {
                    ForEach(apps) { Text($0.name).tag($0.bundleID) }
                }
            }
            if let app {
                HStack {
                    Toggle("Enable overrides", isOn: Binding(get: { app.enabled }, set: { value in update { $0.enabled = value } }))
                    Spacer()
                    Text(app.bundleID == store.foregroundBundleID ? "Active now" : "When this app is in front")
                        .font(.caption).foregroundStyle(app.bundleID == store.foregroundBundleID ? Color.teal : Color.secondary)
                    Button("Remove app") {
                        store.settings.appOverrides = apps.filter { $0.bundleID != selected }
                        selected = store.settings.resolvedAppOverrides.first?.bundleID ?? ""
                    }.buttonStyle(.link)
                }
                Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.tertiary)
                VStack(spacing: 14) {
                    ForEach(app.bindings) { binding in
                        HStack(alignment: .bottom, spacing: 16) {
                            TapActionEditor(title: binding.trigger.title,
                                action: value(binding.trigger, \.action, fallback: .none),
                                shortcut: value(binding.trigger, \.shortcut, fallback: nil),
                                shortcutsOnly: binding.trigger.direction != nil)
                            Button {
                                update { $0.bindings.removeAll { $0.trigger == binding.trigger } }
                            } label: { Image(systemName: "arrow.uturn.backward") }
                                .help("Remove override and inherit from the active layer")
                                .accessibilityLabel("Inherit \(binding.trigger.title) from layer")
                                .padding(.bottom, 3)
                        }
                        if binding.id != app.bindings.last?.id { Divider() }
                    }
                    if app.bindings.isEmpty {
                        Text("All tap and swipe actions inherit from the active layer.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Menu {
                        ForEach(AppGestureTrigger.allCases.filter { trigger in !app.bindings.contains { $0.trigger == trigger } }) { trigger in
                            Button(trigger.title) { update { $0.bindings.append(AppGestureBinding(trigger: trigger)) } }
                        }
                    } label: { Label("Override an action", systemImage: "plus") }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .disabled(!app.enabled)
            } else {
                Text("No app overrides. Your layers apply everywhere.").foregroundStyle(.secondary)
            }
            Text("Quick two-finger horizontal swipes use the assigned action on lift. Vertical and slow movements scroll normally; a brief horizontal gesture-detection delay is expected. Tap and tap-then-swipe rules respect Enable tap actions in the active layer. Motion and timing settings are not overridden.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !apps.contains(where: { $0.bundleID == "com.google.Chrome" }) {
                Button("Add Chrome Back / Forward preset") {
                    store.settings.appOverrides = apps + [.chrome]
                    selected = "com.google.Chrome"
                }
            }
        }
        .onAppear { if app == nil { selected = apps.first?.bundleID ?? "" } }
        .onChange(of: apps.map(\.bundleID)) { _, _ in if app == nil { selected = apps.first?.bundleID ?? "" } }
    }

    private func update(_ edit: (inout AppGestureOverride) -> Void) {
        var updated = apps
        guard let index = updated.firstIndex(where: { $0.bundleID == selected }) else { return }
        edit(&updated[index])
        store.settings.appOverrides = updated
    }

    private func value<T>(_ trigger: AppGestureTrigger, _ key: WritableKeyPath<AppGestureBinding, T>, fallback: T) -> Binding<T> {
        Binding(get: { app?.bindings.first { $0.trigger == trigger }?[keyPath: key] ?? fallback }, set: { newValue in
            update { rule in
                guard let index = rule.bindings.firstIndex(where: { $0.trigger == trigger }) else { return }
                rule.bindings[index][keyPath: key] = newValue
            }
        })
    }

    private func addApp() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.prompt = "Add app"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else {
            error = "Choose a macOS application with a bundle identifier."; return
        }
        if !apps.contains(where: { $0.bundleID == id }) {
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
            store.settings.appOverrides = apps + [AppGestureOverride(bundleID: id, name: name)]
        }
        selected = id
        error = nil
    }
}
