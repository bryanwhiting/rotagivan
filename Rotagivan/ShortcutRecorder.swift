import AppKit
import SwiftUI

private struct HotkeyDictionaryKey: EnvironmentKey { static let defaultValue: [NamedHotkey] = [] }
private struct HUDActionLayersKey: EnvironmentKey { static let defaultValue: [ExplorerHoldLayer] = [] }
extension EnvironmentValues {
    var hudActionLayers: [ExplorerHoldLayer] {
        get { self[HUDActionLayersKey.self] }
        set { self[HUDActionLayersKey.self] = newValue }
    }
    var hotkeyDictionary: [NamedHotkey] {
        get { self[HotkeyDictionaryKey.self] }
        set { self[HotkeyDictionaryKey.self] = newValue }
    }
}

extension ProfileShortcut {
    mutating func assign(_ recorded: RecordedShortcut) {
        keyCode = UInt32(recorded.keyCode)
        keyLabel = recorded.keyLabel
        let flags = NSEvent.ModifierFlags(rawValue: UInt(recorded.modifiers))
        modifiers = (flags.contains(.control) ? 4096 : 0) |
            (flags.contains(.option) ? 2048 : 0) |
            (flags.contains(.shift) ? 512 : 0) |
            (flags.contains(.command) ? 256 : 0)
        enabled = true
    }

    @MainActor var displayName: String {
        let label = keyLabel ?? ShortcutSettings.keys.first { $0.1 == keyCode }?.0 ?? "Key \(keyCode)"
        return (modifiers & 4096 != 0 ? "⌃" : "") +
            (modifiers & 2048 != 0 ? "⌥" : "") +
            (modifiers & 512 != 0 ? "⇧" : "") +
            (modifiers & 256 != 0 ? "⌘" : "") + label
    }
}

extension RecordedShortcut {
    var displayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        return (flags.contains(.control) ? "⌃" : "") +
            (flags.contains(.option) ? "⌥" : "") +
            (flags.contains(.shift) ? "⇧" : "") +
            (flags.contains(.command) ? "⌘" : "") + keyLabel
    }

    static func capture(_ event: NSEvent) -> RecordedShortcut {
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 76: "Enter", 117: "Forward Delete", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down"]
        let functionKeys: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        let functionName = functionKeys.firstIndex(of: event.keyCode).map { "F\($0 + 1)" }
        let label = special[event.keyCode] ?? functionName ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "Key \(event.keyCode)"
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return RecordedShortcut(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue), keyLabel: label)
    }
}

struct TapActionEditor: View {
    @Environment(\.hotkeyDictionary) private var dictionary
    @Environment(\.hudActionLayers) private var hudLayers
    var title: String
    @Binding var action: TapAction
    @Binding var shortcut: RecordedShortcut?
    var shortcutsOnly = false
    var keyboardOnly = false
    var physicalKeysOnly = false
    @State private var showManual = false
    @State private var draft = RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17")

    private var keys: [(String, UInt32)] {
        var keys = ShortcutSettings.keys + [("Return", 36), ("Space", 49), ("Tab", 48), ("Escape", 53), ("Delete", 51), ("Left arrow", 123), ("Right arrow", 124), ("Down arrow", 125), ("Up arrow", 126)]
        if !keys.contains(where: { $0.1 == UInt32(draft.keyCode) }) { keys.append((draft.keyLabel, UInt32(draft.keyCode))) }
        return keys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            HStack(spacing: 6) {
                ShortcutRecorder(title: action == .shortcut ? (shortcut.map { dictionary.title(for: $0) } ?? "Record shortcut…") : action.title) { recorded in
                    shortcut = recorded
                    action = .shortcut
                }.frame(maxWidth: .infinity).frame(height: 26)
                Menu {
                    if !physicalKeysOnly && !dictionary.isEmpty {
                        Menu("Keybindings and Macros") {
                            ForEach(dictionary.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { entry in
                                Button("\(entry.name) (\(entry.summary))") { shortcut = .macro(entry); action = .shortcut }
                            }
                        }
                        Divider()
                    }
                    if !physicalKeysOnly && (!keyboardOnly || !hudLayers.isEmpty) {
                        Menu("HUD layer") {
                            if !keyboardOnly {
                                Button("Favorites") { action = .appExplorer; shortcut = nil }
                            }
                            ForEach(hudLayers) { layer in
                                Button(layer.name) { shortcut = .hudLayer(layer); action = .shortcut }
                            }
                        }
                    }
                    Button("Set shortcut manually…") {
                        if action == .shortcut, let shortcut, shortcut.isPhysicalShortcut { draft = shortcut }
                        else if action == .optionF19 { draft = RecordedShortcut(keyCode: 80, modifiers: UInt64(NSEvent.ModifierFlags.option.rawValue), keyLabel: "F19") }
                        else if action == .enter { draft = RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return") }
                        showManual = true
                    }
                    Divider()
                    if !shortcutsOnly && !keyboardOnly {
                        Button("Left click") { action = .leftClick }
                        Button("Double left click") { action = .doubleLeftClick }
                        Button("Triple left click") { action = .tripleLeftClick }
                        Button("Right click") { action = .rightClick }
                    }
                    if !keyboardOnly {
                    Button("App Explorer") { action = .appExplorer; shortcut = nil }
                    if !shortcutsOnly {
                        Button("Window Manager") { action = .windowManager; shortcut = nil }
                    }
                    Button("Nothing") { action = .none; if shortcutsOnly { shortcut = nil } }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .controlSize(.regular).frame(width: 32, height: 26)
                    .accessibilityLabel("\(title) action options")
                    .accessibilityIdentifier("gesture-action-menu")
                    .help("Choose a HUD layer, keybinding, macro, or tap action")
            }
        }
        .popover(isPresented: $showManual) {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(title) shortcut").font(.headline)
                Text("Choose a combination without pressing it. Useful when another app already owns the shortcut.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Key", selection: $draft.keyCode) {
                    ForEach(keys, id: \.1) { name, code in Text(name).tag(UInt16(code)) }
                }
                HStack {
                    modifier("⌃", flag: .control, name: "Control")
                    modifier("⌥", flag: .option, name: "Option")
                    modifier("⇧", flag: .shift, name: "Shift")
                    modifier("⌘", flag: .command, name: "Command")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showManual = false }
                    Button("Save") {
                        draft.keyLabel = keys.first { $0.1 == UInt32(draft.keyCode) }?.0 ?? draft.keyLabel
                        shortcut = draft
                        action = .shortcut
                        showManual = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(18).frame(width: 300)
        }
    }

    private func modifier(_ title: String, flag: NSEvent.ModifierFlags, name: String) -> some View {
        Toggle(title, isOn: Binding(get: { draft.modifiers & UInt64(flag.rawValue) != 0 }, set: { enabled in
            if enabled { draft.modifiers |= UInt64(flag.rawValue) }
            else { draft.modifiers &= ~UInt64(flag.rawValue) }
        })).toggleStyle(.button).help(name).accessibilityLabel(name)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var title: String
    var onRecord: (RecordedShortcut) -> Void

    func makeNSView(context: Context) -> RecordingButton {
        let button = RecordingButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(RecordingButton.beginRecording)
        button.setAccessibilityLabel("Record keyboard shortcut")
        button.toolTip = "Click, then press a key combination. Escape cancels."
        return button
    }

    func updateNSView(_ button: RecordingButton, context: Context) {
        button.idleTitle = title
        button.onRecord = onRecord
        if !button.recording && button.title != title { button.title = title }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecordingButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: 26)
    }

    static func dismantleNSView(_ button: RecordingButton, coordinator: ()) {
        button.stopRecording()
    }
}

final class RecordingButton: NSButton {
    var idleTitle = "Record shortcut…"
    var onRecord: ((RecordedShortcut) -> Void)?
    private(set) var recording = false
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        if recording { stopRecording(); return }
        guard window?.makeFirstResponder(self) == true else { return }
        recording = true
        title = "Press shortcut… (Esc cancels)"
        NotificationCenter.default.post(name: .shortcutRecordingStarted, object: self)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type != .keyDown {
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.stopRecording() }
                return event
            }
            guard self.window?.isKeyWindow == true else { return event }
            self.keyDown(with: event)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    func stopRecording() {
        guard recording else { return }
        recording = false
        title = idleTitle
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NotificationCenter.default.post(name: .shortcutRecordingStopped, object: self)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { stopRecording(); return }
        let shortcut = RecordedShortcut.capture(event)
        stopRecording()
        onRecord?(shortcut)
    }
}
