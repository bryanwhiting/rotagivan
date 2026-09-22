import SwiftUI
import UniformTypeIdentifiers

struct HotkeyOrganizerView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var keys = ShortcutSettings.shared
    @State private var tab = "Dictionary"
    @State private var search = ""
    @State private var searchShortcut: RecordedShortcut?
    @State private var tapFilter: AppGestureTrigger?
    @State private var selectedKeyCode: UInt16?
    @State private var layer: UInt32 = 0
    @State private var device: GestureDevice = .navigator
    @State private var showInactive = false
    @State private var editing: NamedHotkey?
    @State private var editingRequiresHotkey = false
    @State private var deleting: NamedHotkey?

    private var selectedLayer: UInt32 { store.profiles.contains { $0.id == layer } ? layer : store.defaultProfileID }
    private var audit: HotkeyAudit {
        HotkeyAudit(settings: store.settings, shortcuts: ShortcutConfiguration(keys), layerID: selectedLayer, device: device)
    }
    private func textMatches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
    private func assignmentMatches(_ row: HotkeyAudit.Assignment) -> Bool {
        textMatches(row.searchText) &&
        (searchShortcut == nil || row.shortcut?.identity == searchShortcut?.identity) &&
        (tapFilter == nil || row.trigger == tapFilter?.title)
    }
    private func dictionaryMatches(_ entry: NamedHotkey) -> Bool {
        let assigned = ([entry.activationShortcut] + entry.resolvedSequence.map(\.shortcut)).compactMap { $0 }
        return textMatches(entry.name + " " + entry.summary + " " + assigned.map(\.readableCombination).joined(separator: " ")) &&
            (searchShortcut == nil || assigned.contains { $0.identity == searchShortcut?.identity })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create reusable actions, app launchers and macros. Search every keyboard and trackpad assignment, then review conflicts and overrides in one place.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("View", selection: $tab) {
                Text("Saved actions").tag("Dictionary")
                Text("Conflicts").tag("Conflicts")
                Text("All assignments").tag("Assignments")
                Text("Keyboard").tag("Keyboard")
            }.pickerStyle(.segmented)
            searchControls
            HStack {
                Picker("Layer", selection: Binding(get: { selectedLayer }, set: { layer = $0 })) {
                    ForEach(store.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Device", selection: $device) {
                    ForEach(GestureDevice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Spacer()
                if searchShortcut != nil || tapFilter != nil || !search.isEmpty {
                    Button("Clear search") { clearSearch() }.buttonStyle(.link)
                }
            }
            if let error = keys.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            switch tab {
            case "Dictionary": dictionary
            case "Conflicts": findings(audit)
            case "Keyboard": keyboard(audit)
            default: assignments(audit)
            }
        }
        .font(.system(size: 12))
        .sheet(item: $editing) { value in
            NamedHotkeyEditor(entry: value, existing: store.settings.resolvedHotkeyDictionary,
                requiresGlobalHotkey: editingRequiresHotkey, onSave: { entry in
                    var next = store.settings.resolvedHotkeyDictionary.filter { $0.id != entry.id }
                    next.append(entry)
                    guard next.isValidDictionary else { return }
                    store.settings.hotkeyDictionary = next
                    editing = nil; editingRequiresHotkey = false
                }, onCancel: { editing = nil; editingRequiresHotkey = false })
        }
        .alert("Remove saved action?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove", role: .destructive) {
                store.settings.hotkeyDictionary = store.settings.resolvedHotkeyDictionary.filter { $0.id != deleting?.id }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Its global hotkey will stop working. Tap, swipe and HUD references to this action will also become inactive until reassigned.") }
        .onReceive(store.$activeConfigurationID.dropFirst()) { _ in
            editing = nil; deleting = nil; layer = 0; clearSearch()
        }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            TextField("Search names, apps, keys or actions", text: $search).textFieldStyle(.roundedBorder)
            ShortcutRecorder(title: searchShortcut?.readableCombination ?? "Press hotkey to find…") { shortcut in
                searchShortcut = shortcut; search = ""; tapFilter = nil; selectedKeyCode = shortcut.keyCode; tab = "Assignments"
            }.frame(width: 170, height: 26)
            Menu {
                Button("Any tap or gesture") { tapFilter = nil }
                Divider()
                ForEach(AppGestureTrigger.allCases, id: \.self) { trigger in
                    Button(trigger.title) { tapFilter = trigger; searchShortcut = nil; selectedKeyCode = nil; search = ""; tab = "Assignments" }
                }
            } label: {
                Label(tapFilter?.title ?? "Find tap action", systemImage: "hand.tap")
            }.fixedSize()
        }
    }

    private func clearSearch() {
        search = ""; searchShortcut = nil; tapFilter = nil; selectedKeyCode = nil
    }

    private func beginNewAction() {
        editingRequiresHotkey = false
        editing = NamedHotkey(name: "", shortcut: RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17"))
    }

    private func chooseApplicationHotkey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let app = ExplorerApplicationCatalog.application(at: url) else { return }
        editingRequiresHotkey = true
        editing = NamedHotkey(name: "Open \(app.name)",
            shortcut: RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17"),
            sequence: [.app(bundleID: app.bundleID, name: app.name)])
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved actions: \(store.settings.resolvedHotkeyDictionary.count)").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Add keyboard action or macro") { beginNewAction() }
                    Button("Add application hotkey…") { chooseApplicationHotkey() }
                } label: { Label("Add action", systemImage: "plus") }
                .disabled(store.settings.resolvedHotkeyDictionary.count >= 500)
            }
            Text("A saved action can have its own global hotkey, including an app-only launcher. The same action can also be assigned to any tap, swipe or HUD tile and travels with YAML/sync.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let entries = store.settings.resolvedHotkeyDictionary.filter(dictionaryMatches)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if store.settings.resolvedHotkeyDictionary.isEmpty {
                Label("No saved actions yet. Add an application hotkey, keybinding or macro.", systemImage: "book.closed")
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(entries) { entry in
                HStack(spacing: 12) {
                    Image(systemName: entry.resolvedSequence.contains { $0.kind == .openApp } ? "app.badge" : "keyboard")
                        .foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).fontWeight(.medium)
                        if let shortcut = entry.activationShortcut {
                            Label(shortcut.readableCombination, systemImage: "globe").font(.caption).foregroundStyle(Color.accentColor)
                        } else {
                            Text("No global hotkey").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text(entry.summary).monospaced().foregroundStyle(.secondary).lineLimit(2)
                    Button("Edit") { editingRequiresHotkey = false; editing = entry }
                    Button { deleting = entry } label: { Image(systemName: "trash") }.help("Remove saved action")
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            let taps = audit.assignments.filter { $0.kind == "Tap or gesture" && $0.enabled && assignmentMatches($0) }
            if !taps.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Tap and gesture assignments · \(taps.count)").font(.headline)
                Text("These are first-class assignments for the selected layer and device. Search them by gesture name or by the shortcut they send.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(taps) { assignmentCard($0) }
            }
        }
    }

    private func findings(_ audit: HotkeyAudit) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Auditing the selected layer/device, its app rules, global launch hotkeys, and every HUD layer.")
                .font(.caption).foregroundStyle(.secondary)
            let visible = audit.findings.filter { finding in
                textMatches(finding.title + " " + finding.detail) &&
                (searchShortcut == nil || (finding.title + " " + finding.detail).contains(searchShortcut?.readableCombination ?? ""))
            }
            if visible.isEmpty { Label("No matching conflicts or overrides.", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            ForEach(HotkeyAudit.Kind.allCases, id: \.self) { kind in
                let rows = visible.filter { $0.kind == kind }
                if !rows.isEmpty {
                    Text("\(kind.rawValue) · \(rows.count)").font(.headline)
                    ForEach(rows) { finding in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(finding.title, systemImage: kind == .conflict ? "exclamationmark.triangle.fill" : kind == .override ? "arrow.triangle.branch" : "info.circle")
                                .fontWeight(.medium).foregroundStyle(kind == .conflict ? Color.red : kind == .caution ? .orange : .primary)
                            Text(finding.detail).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func assignments(_ audit: HotkeyAudit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Show inactive or unassigned actions", isOn: $showInactive)
                Spacer()
                Text("\(audit.assignments.filter { (showInactive || $0.enabled || $0.precedence.hasPrefix("Replaces")) && assignmentMatches($0) }.count) matches")
                    .foregroundStyle(.secondary)
            }
            ForEach(audit.assignments.filter { (showInactive || $0.enabled || $0.precedence.hasPrefix("Replaces")) && assignmentMatches($0) }) {
                assignmentCard($0)
            }
        }
    }

    @ViewBuilder private func assignmentCard(_ row: HotkeyAudit.Assignment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(row.trigger, systemImage: row.kind == "Tap or gesture" ? "hand.tap" : row.inputScope != nil ? "keyboard" : "arrow.right.circle")
                    .fontWeight(.medium)
                Spacer()
                Text(row.kind).font(.caption2).textCase(.uppercase).foregroundStyle(.secondary)
                Text(row.enabled ? row.scope : row.scope + " · inactive").foregroundStyle(.secondary)
            }
            HStack {
                Text(row.action).textSelection(.enabled)
                Spacer()
                if let shortcut = row.shortcut, shortcut.isPhysicalShortcut {
                    Text(shortcut.readableCombination).monospaced().foregroundStyle(.secondary)
                }
            }
            if !row.precedence.isEmpty { Text(row.precedence).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func keyboard(_ audit: HotkeyAudit) -> some View {
        let visible = audit.assignments.filter { $0.enabled && assignmentMatches($0) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Assigned keys are highlighted. Select a key to see every modifier combination, tap output, launcher and HUD action that uses it.")
                .font(.caption).foregroundStyle(.secondary)
            AssignmentKeyboardLayout(assignments: visible, selectedKeyCode: $selectedKeyCode)
            if let selectedKeyCode {
                let rows = visible.filter { $0.shortcut?.isPhysicalShortcut == true && $0.shortcut?.keyCode == selectedKeyCode }
                Text("Assignments on \(KeyboardLayoutKey.label(for: selectedKeyCode)) · \(rows.count)").font(.headline)
                if rows.isEmpty { Text("No matching assignment on this key.").foregroundStyle(.secondary) }
                ForEach(rows) { assignmentCard($0) }
            } else {
                Text("Choose a highlighted key, or press a hotkey in the search control above.").foregroundStyle(.secondary)
            }
            if tapFilter != nil {
                let nonKeyboard = visible.filter { $0.kind == "Tap or gesture" && $0.shortcut?.isPhysicalShortcut != true }
                ForEach(nonKeyboard) { assignmentCard($0) }
            }
        }
    }
}

private struct KeyboardLayoutKey: Identifiable {
    var label: String
    var code: UInt16?
    var width: CGFloat = 38
    var id: String { "\(label)-\(code.map(String.init) ?? "none")" }

    static func label(for code: UInt16) -> String {
        all.first { $0.code == code }?.label ?? "Key \(code)"
    }
    static let rows: [[Self]] = {
        func keys(_ labels: [String], _ codes: [UInt16]) -> [Self] {
            zip(labels, codes).map { Self(label: $0.0, code: $0.1) }
        }
        let functionCodes: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        let functions = zip((1...20).map { "F\($0)" }, functionCodes).map { Self(label: $0.0, code: $0.1) }
        let numbers = keys(Array("1234567890").map(String.init), [18,19,20,21,23,22,26,28,25,29])
        let qwerty = keys(Array("QWERTYUIOP").map(String.init), [12,13,14,15,17,16,32,34,31,35])
        let home = keys(Array("ASDFGHJKL").map(String.init), [0,1,2,3,5,4,38,40,37])
        let bottom = keys(Array("ZXCVBNM").map(String.init), [6,7,8,9,11,45,46])
        return [
            [Self(label: "Esc", code: 53, width: 50)] + functions,
            [Self(label: "`", code: 50)] + numbers + [Self(label: "-", code: 27), Self(label: "=", code: 24), Self(label: "Delete", code: 51, width: 62)],
            [Self(label: "Tab", code: 48, width: 58)] + qwerty + [Self(label: "[", code: 33), Self(label: "]", code: 30), Self(label: "\\", code: 42, width: 48)],
            [Self(label: "Caps", code: 57, width: 66)] + home + [Self(label: ";", code: 41), Self(label: "'", code: 39), Self(label: "Return", code: 36, width: 72)],
            [Self(label: "Shift", code: 56, width: 84)] + bottom + [Self(label: ",", code: 43), Self(label: ".", code: 47), Self(label: "/", code: 44), Self(label: "Shift", code: 60, width: 84)],
            [Self(label: "Ctrl", code: 59, width: 50), Self(label: "Opt", code: 58, width: 50), Self(label: "Cmd", code: 55, width: 58), Self(label: "Space", code: 49, width: 260), Self(label: "Cmd", code: 54, width: 58), Self(label: "Opt", code: 61, width: 50), Self(label: "←", code: 123), Self(label: "↓", code: 125), Self(label: "↑", code: 126), Self(label: "→", code: 124)]
        ]
    }()
    static var all: [Self] { rows.flatMap { $0 } }
}

private struct AssignmentKeyboardLayout: View {
    var assignments: [HotkeyAudit.Assignment]
    @Binding var selectedKeyCode: UInt16?

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(KeyboardLayoutKey.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 5) {
                        ForEach(row) { key in
                            let matches = assignments.filter { $0.shortcut?.isPhysicalShortcut == true && $0.shortcut?.keyCode == key.code }
                            Button { selectedKeyCode = key.code } label: {
                                ZStack(alignment: .topTrailing) {
                                    Text(key.label).font(.system(size: 10, weight: matches.isEmpty ? .regular : .semibold, design: .rounded))
                                        .frame(width: key.width, height: 31)
                                    if !matches.isEmpty { Text("\(matches.count)").font(.system(size: 8, weight: .bold)).padding(3) }
                                }
                            }
                            .buttonStyle(.plain)
                            .background(matches.isEmpty ? Color.secondary.opacity(0.09) : Color.accentColor.opacity(selectedKeyCode == key.code ? 0.38 : 0.2), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selectedKeyCode == key.code ? Color.accentColor : Color.secondary.opacity(0.18)))
                            .help(matches.isEmpty ? key.label : matches.map { "\($0.shortcut?.readableCombination ?? key.label): \($0.trigger)" }.joined(separator: "\n"))
                        }
                    }
                }
            }.padding(2)
        }
    }
}

struct NamedHotkeyEditor: View {
    @State var entry: NamedHotkey
    var existing: [NamedHotkey]
    var requiresGlobalHotkey = false
    var onSave: (NamedHotkey) -> Void
    var onCancel: () -> Void
    @State private var action: TapAction = .shortcut

    private var activationConflict: Bool {
        guard let trigger = entry.activationShortcut else { return false }
        return existing.contains { $0.id != entry.id && $0.activationShortcut?.identity == trigger.identity }
    }
    private func updateSteps(_ steps: [MacroStep]) {
        entry.sequence = steps; entry.steps = nil
        if let first = steps.compactMap(\.shortcut).first { entry.shortcut = first }
    }
    private func chooseApp(replacing index: Int? = nil) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let app = ExplorerApplicationCatalog.application(at: url) else { return }
        var steps = entry.resolvedSequence
        let step = MacroStep.app(bundleID: app.bundleID, name: app.name)
        if let index, steps.indices.contains(index) { steps[index] = step }
        else if steps.count < 32 { steps.append(step) }
        updateSteps(steps)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Saved action", systemImage: entry.resolvedSequence.contains { $0.kind == .openApp } ? "app.badge" : "keyboard").font(.headline)
            TextField("Name", text: $entry.name).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Run from anywhere").fontWeight(.medium)
                    Spacer()
                    ShortcutRecorder(title: entry.activationShortcut?.readableCombination ?? "Record global hotkey…") {
                        entry.activationShortcut = $0
                    }.frame(width: 220, height: 26)
                    if entry.activationShortcut != nil {
                        Button { entry.activationShortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Remove global hotkey")
                    }
                }
                Text("Optional for reusable actions; required when adding an application hotkey. Letter and number keys need a modifier.")
                    .font(.caption).foregroundStyle(.secondary)
                if activationConflict { Text("That global hotkey is already assigned to another saved action.").font(.caption).foregroundStyle(.red) }
                else if requiresGlobalHotkey && entry.activationShortcut == nil { Text("Record a global hotkey for this application.").font(.caption).foregroundStyle(.orange) }
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(entry.resolvedSequence.indices), id: \.self) { index in
                        HStack {
                            if entry.resolvedSequence[index].kind == .openApp {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Step \(index + 1) · Open app").foregroundStyle(.secondary)
                                    Button(entry.resolvedSequence[index].appName ?? "Choose app…") { chooseApp(replacing: index) }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                TapActionEditor(title: "Step \(index + 1)", action: $action, shortcut: Binding(get: {
                                    entry.resolvedSequence.indices.contains(index) ? entry.resolvedSequence[index].shortcut : nil
                                }, set: { value in
                                    guard let value, value.isPhysicalShortcut, entry.resolvedSequence.indices.contains(index) else { return }
                                    var steps = entry.resolvedSequence; steps[index] = .key(value); updateSteps(steps)
                                }), keyboardOnly: true, physicalKeysOnly: true)
                            }
                            Button { var steps = entry.resolvedSequence; steps.swapAt(index, index - 1); updateSteps(steps) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move step earlier")
                            Button { var steps = entry.resolvedSequence; steps.remove(at: index); updateSteps(steps) } label: { Image(systemName: "minus.circle") }.disabled(entry.resolvedSequence.count == 1).help("Remove step")
                        }
                    }
                }
            }.frame(height: min(300, CGFloat(entry.resolvedSequence.count) * 66))
            HStack {
                Button("Add keystroke") { updateSteps(entry.resolvedSequence + [.key(RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return"))]) }
                Button("Add open app…") { chooseApp() }
            }.disabled(entry.resolvedSequence.count >= 32)
            Stepper("Delay between steps: \(entry.resolvedDelay) ms", value: Binding(get: { entry.resolvedDelay }, set: { entry.stepDelayMilliseconds = $0 }), in: 0...2000, step: 25)
            Text("Open app launches or activates it before the next keystroke. App-only actions are supported. Playback stops if opening fails or focus changes unexpectedly.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines); updateSteps(entry.resolvedSequence); onSave(entry) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!entry.isValid || activationConflict || (requiresGlobalHotkey && entry.activationShortcut == nil))
            }
        }.padding(24).frame(width: 590)
    }
}
