import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One trigger control for keyboard and trackpad assignments. The surrounding
/// screen decides where the binding lives; this control only edits its input.
struct BindingTriggerPicker: View {
    @Binding var trigger: BindingTrigger
    var allowsGestures = true
    var title = "Trigger"
    var assignments: [ActionBinding] = []
    var occupiedGestures: [AppGestureTrigger: String] = [:]

    private func gestureLabel(_ gesture: AppGestureTrigger) -> String {
        let owner = assignments.first { $0.trigger.gesture == gesture }
        return owner.map { "\(gesture.title) · \($0.action.title)" } ??
            occupiedGestures[gesture].map { "\(gesture.title) · \($0)" } ?? gesture.title
    }

    var body: some View {
        HStack(spacing: 8) {
            ShortcutRecorder(title: trigger.keyboard?.readableCombination ?? "Record shortcut…") { shortcut in
                trigger = BindingTrigger(keyboard: shortcut)
            }
            .frame(minWidth: 145, minHeight: 27)
            if allowsGestures {
                Menu {
                    Button("Keyboard shortcut") { trigger = BindingTrigger() }
                    Divider()
                    ForEach(AppGestureTrigger.baseTapTriggers) { gesture in
                        Button(gestureLabel(gesture)) { trigger = BindingTrigger(gesture: gesture) }
                    }
                    Menu("Tap and swipe") {
                        ForEach(AppGestureTrigger.layerActionTriggers.filter { $0.direction != nil }) { gesture in
                            Button(gestureLabel(gesture)) { trigger = BindingTrigger(gesture: gesture) }
                        }
                    }
                } label: {
                    Label(trigger.gesture?.title ?? "Tap or swipe", systemImage: "hand.tap")
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .accessibilityLabel("\(title): \(trigger.title)")
    }
}

/// The same action catalog is used by layer bindings, HUD tiles, and the
/// existing tap controls. The caller owns persistence and scope validation.
struct BindingActionPicker: View {
    @Environment(\.hotkeyDictionary) private var dictionary
    @Environment(\.hudActionLayers) private var hudLayers
    @Environment(\.hudActionDestinations) private var hudDestinations
    @Binding var action: BindingAction
    var title = "Action"
    var allowPointerActions = true
    @State private var recording = false
    @State private var enteringURL = false
    @State private var urlDraft = "https://"

    var body: some View {
        Menu {
            Section("Keybindings") {
                Button("Record keystroke…", systemImage: "keyboard") { recording = true }
                ForEach(dictionary.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { entry in
                    Button("\(entry.name) · \(entry.summary)") { action = .macro(entry) }
                }
            }
            Section("HUD layers") {
                Button("Default", systemImage: "square.stack.3d.up") { action = .hudLayer(nil) }
                ForEach(hudLayers) { layer in
                    Button(layer.name, systemImage: "square.stack.3d.up") { action = .hudLayer(layer) }
                }
                ForEach(hudDestinations.filter { container in
                    !container.id.isEmpty && !(container.id.count == 1 && container.id.first.map {
                        if case .layer = $0 { return true }; return false
                    } == true)
                }) { container in
                    Button(container.title, systemImage: "square.stack.3d.up") {
                        action = .hudContainer(container)
                    }
                }
            }
            Section("Apps and websites") {
                Button("Choose application…", systemImage: "app") { chooseApp() }
                Button("Open URL…", systemImage: "globe") { enteringURL = true }
            }
            Section("Mac and window commands") {
                ForEach(AppExplorerAction.macOSCommands + AppExplorerAction.windowCommands, id: \.self) { command in
                    Button(command.title, systemImage: command.symbol) { action = .command(command) }
                }
                ForEach(ExplorerWindowLayout.allCases, id: \.self) { layout in
                    Menu("Place window · \(layout.title)") {
                        ForEach(SwipeDirection.allCases, id: \.self) { direction in
                            let placement = ExplorerWindowPlacement(direction: direction, layout: layout)
                            Button(placement.title) { action = .windowPlacement(placement) }
                        }
                    }
                }
            }
            Section("Media") {
                ForEach(ExplorerMediaAction.allCases, id: \.self) { media in
                    Button(media.title, systemImage: media.symbol) { action = .media(media) }
                }
            }
            if allowPointerActions {
                Section("Pointer and HUD") {
                    ForEach([TapAction.leftClick, .doubleLeftClick, .tripleLeftClick, .rightClick,
                             .appExplorer, .windowManager, .enter, .optionF19], id: \.self) { tap in
                        Button(tap.title) { action = .tap(tap) }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 16)
                Text(action.isValid ? action.title : "Choose action…").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.11)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .accessibilityLabel("\(title): \(action.title)")
        .popover(isPresented: $recording) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Keystroke").font(.headline)
                Text("Press the combination this action should send.")
                    .font(.caption).foregroundStyle(.secondary)
                ShortcutRecorder(title: "Record keystroke…") { shortcut in
                    action = .keystroke(shortcut)
                    recording = false
                }.frame(width: 260, height: 28)
            }.padding(16)
        }
        .popover(isPresented: $enteringURL) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Open URL").font(.headline)
                TextField("https://example.com", text: $urlDraft).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { enteringURL = false }
                    Spacer()
                    Button("Use URL") {
                        action = .openURL(urlDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        enteringURL = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(URL(string: urlDraft).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil } == nil)
                }
            }.padding(16).frame(width: 330)
        }
    }

    private var symbol: String {
        switch action.kind {
        case .keystroke, .macro: return "keyboard"
        case .hudLayer: return "square.stack.3d.up"
        case .openApp: return "app"
        case .openURL: return "globe"
        case .command: return action.command?.symbol ?? "macwindow"
        case .media: return action.media?.symbol ?? "speaker.wave.2"
        case .windowPlacement: return "rectangle.split.2x2"
        case .tap: return "hand.tap"
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let app = ExplorerApplicationCatalog.application(at: url) else { return }
        action = .openApp(bundleID: app.bundleID, name: app.name)
    }
}

struct BindingEditor: View {
    @State var binding: ActionBinding
    let existing: [ActionBinding]
    var allowsGestures = true
    var global = false
    var reservedKeys: [RecordedShortcut] = []
    var occupiedGestures: [AppGestureTrigger: String] = [:]
    var title = "Assignment"
    let onSave: (ActionBinding) -> Void
    let onCancel: () -> Void

    private var collision: Bool {
        existing.contains { $0.id != binding.id && $0.trigger.identity == binding.trigger.identity } ||
            binding.trigger.keyboard.map { key in reservedKeys.contains { $0.identity == key.identity } } == true
    }
    private var validKey: Bool {
        guard let key = binding.trigger.keyboard else { return true }
        return global ? key.isValidGlobalHotkey : key.isValidHUDActionHotkey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            Text("Choose what starts the action, then what it runs.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("When").frame(width: 46, alignment: .leading)
                BindingTriggerPicker(trigger: $binding.trigger, allowsGestures: allowsGestures,
                    assignments: existing.filter { $0.id != binding.id }, occupiedGestures: occupiedGestures)
            }
            HStack(spacing: 12) {
                Text("Run").frame(width: 46, alignment: .leading)
                BindingActionPicker(action: $binding.action).frame(maxWidth: .infinity)
            }
            if collision {
                Label("This trigger already has an action in this layer.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if !validKey {
                Label(global ? "Use a modifier with letter and number keys. Escape is reserved." :
                    "Escape and bare E/S are reserved while the HUD is open.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if let gesture = binding.trigger.gesture,
                      let current = occupiedGestures[gesture] {
                Text("Currently: \(current). Saving will replace this gesture’s action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { saveDraft() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!binding.trigger.isValid || !binding.action.isValid || collision || !validKey)
            }
        }
        .padding(22).frame(width: 570)
    }

    func saveDraft() { onSave(binding) }
}
