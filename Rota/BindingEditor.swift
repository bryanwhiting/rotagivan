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
                RotaMenuButton(trigger.gesture?.title ?? "Trackpad tap or swipe", systemImage: "hand.tap", kind: .field) {
                    Button("Keyboard shortcut") { trigger = BindingTrigger() }
                    Divider()
                    ForEach(AppGestureTrigger.baseTapTriggers) { gesture in
                        Button(gestureLabel(gesture)) { trigger = BindingTrigger(gesture: gesture) }
                    }
                    Menu("Two-finger swipe") {
                        ForEach([AppGestureTrigger.twoFingerLeft, .twoFingerRight, .twoFingerUp, .twoFingerDown]) { gesture in
                            Button(gestureLabel(gesture)) { trigger = BindingTrigger(gesture: gesture) }
                        }
                    }
                    Menu("Tap and swipe") {
                        ForEach(AppGestureTrigger.layerActionTriggers.filter { $0.direction != nil }) { gesture in
                            Button(gestureLabel(gesture)) { trigger = BindingTrigger(gesture: gesture) }
                        }
                    }
                }
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
    @State private var presenting = false

    var body: some View {
        Button { presenting = true } label: {
            HStack(spacing: 10) {
                ActionPickerItemIcon(item: ActionPickerItem(action: action,
                    category: action.kind == .openApp ? .apps : .all,
                    title: dictionary.title(for: action), detail: action.description), size: 28)
                    .foregroundStyle(Color.accentColor)
                Text(action.isValid ? dictionary.title(for: action) : "Choose action…")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }.padding(.horizontal, 8).padding(.vertical, 6)
                .background(RotaControlChrome())
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("Search and choose an action")
            .accessibilityLabel("\(title): \(dictionary.title(for: action)). Choose action")
            .accessibilityIdentifier("binding-action-picker")
            .sheet(isPresented: $presenting) {
                ActionPickerModal(current: action, dictionary: dictionary, layers: hudLayers,
                    destinations: hudDestinations, allowPointerActions: allowPointerActions,
                    onSelect: { action = $0; presenting = false }, onCancel: { presenting = false })
            }
    }
}

/// A HUD tile's one way to assign: the current assignment is itself the button
/// that opens the picker, which also offers the generated built-in HUDs.
struct TileActionPicker<Icon: View>: View {
    @Environment(\.hotkeyDictionary) private var dictionary
    @Environment(\.hudActionLayers) private var hudLayers
    @Environment(\.hudActionDestinations) private var hudDestinations
    let current: BindingAction?
    let name: String?
    @ViewBuilder let icon: () -> Icon
    let onSelect: (BindingAction) -> Void
    let onSelectBuiltIn: (ExplorerReservedGroup) -> Void
    @State private var presenting = false

    var body: some View {
        Button { presenting = true } label: {
            HStack(spacing: 10) {
                icon().frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name ?? "Choose action…").fontWeight(.medium).lineLimit(1)
                    Text(name == nil ? "Apps, websites, shortcuts, macros or built-in HUDs" : "Current assignment · click to change")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search and choose what this tile does")
        .accessibilityLabel("Action: \(name ?? "none"). Choose action")
        .accessibilityIdentifier("binding-action-picker")
        .sheet(isPresented: $presenting) {
            ActionPickerModal(current: current ?? .tap(.none), dictionary: dictionary, layers: hudLayers,
                destinations: hudDestinations, allowPointerActions: true,
                onSelect: { onSelect($0); presenting = false },
                onSelectBuiltIn: { onSelectBuiltIn($0); presenting = false },
                onCancel: { presenting = false })
        }
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
            Text(allowsGestures
                ? "Choose a keyboard shortcut or trackpad gesture, then what it runs."
                : "Choose a keyboard shortcut, then what it runs.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("When").frame(width: 46, alignment: .leading)
                BindingTriggerPicker(trigger: $binding.trigger, allowsGestures: allowsGestures,
                    assignments: existing.filter { $0.id != binding.id }, occupiedGestures: occupiedGestures)
            }
            HStack(spacing: 12) {
                Text("Run").frame(width: 46, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    BindingActionPicker(action: $binding.action).frame(maxWidth: .infinity)
                    Text(binding.action.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
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
                    .keyboardShortcut(.defaultAction).buttonStyle(.rotaPrimary)
                    .disabled(!binding.trigger.isValid || !binding.action.isValid || collision || !validKey)
            }
        }
        .padding(22).frame(width: 570)
    }

    func saveDraft() { onSave(binding) }
}
