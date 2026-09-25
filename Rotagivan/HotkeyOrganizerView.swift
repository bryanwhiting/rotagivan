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
    @State private var deleting: NamedHotkey?
    @State private var editingBinding: ActionBinding?
    @State private var migratingNamedHotkeyID: String?
    @State private var expandedAssignment: String?

    private var selectedLayer: UInt32 { store.profiles.contains { $0.id == layer } ? layer : store.defaultProfileID }
    private var occupiedGestures: [AppGestureTrigger: String] {
        let gestures = store.gestures(for: selectedLayer, device: device)
        return Dictionary(uniqueKeysWithValues: AppGestureTrigger.allCases.compactMap { trigger in
            let value = trigger.assignment(in: gestures)
            guard value.enabled else { return nil }
            let title = value.binding.shortcut.map { store.settings.resolvedHotkeyDictionary.title(for: $0) } ?? value.binding.action.title
            return (trigger, title)
        })
    }
    private var audit: HotkeyAudit {
        HotkeyAudit(settings: store.settings, shortcuts: ShortcutConfiguration(keys), layerID: selectedLayer, device: device)
    }
    private var reservedGlobalKeys: [RecordedShortcut] {
        audit.assignments.filter {
            $0.enabled && $0.inputScope == "" && !$0.id.hasPrefix("Global bindings.binding.") &&
            $0.id != migratingNamedHotkeyID.map { "dictionary.hotkey." + $0 }
        }.compactMap(\.shortcut).filter(\.isPhysicalShortcut)
    }
    private func textMatches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
    private func assignmentMatches(_ row: HotkeyAudit.Assignment) -> Bool {
        textMatches(row.searchText) &&
        (searchShortcut == nil || row.searchableShortcuts.contains { $0.identity == searchShortcut?.identity }) &&
        (tapFilter == nil || row.gesture == tapFilter || row.trigger == tapFilter?.title)
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
                Text("Actions").tag("Dictionary")
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
        .sheet(item: $editingBinding) { binding in
            BindingEditor(binding: binding, existing: store.settings.actionBindings ?? [], global: true,
                reservedKeys: reservedGlobalKeys,
                occupiedGestures: occupiedGestures,
                title: "Global assignment", onSave: { updated in
                    var bindings = store.settings.actionBindings ?? []
                    if let index = bindings.firstIndex(where: { $0.id == updated.id }) { bindings[index] = updated }
                    else { bindings.append(updated) }
                    guard bindings.isValidBindings(global: true) else { return }
                    var settings = store.settings
                    if let id = migratingNamedHotkeyID,
                       let index = settings.hotkeyDictionary?.firstIndex(where: { $0.id == id }) {
                        settings.hotkeyDictionary?[index].activationShortcut = nil
                    }
                    settings.actionBindings = bindings
                    store.settings = settings
                    migratingNamedHotkeyID = nil
                    editingBinding = nil
                }, onCancel: { editingBinding = nil; migratingNamedHotkeyID = nil })
        }
        .sheet(item: $editing) { value in
            NamedHotkeyEditor(entry: value, existing: store.settings.resolvedHotkeyDictionary,
                onAssignTrigger: { entry in
                    var next = store.settings.resolvedHotkeyDictionary.filter { $0.id != entry.id }
                    next.append(entry)
                    guard next.isValidDictionary else { return }
                    store.settings.hotkeyDictionary = next
                    editing = nil
                    let configurationID = store.activeConfigurationID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard store.activeConfigurationID == configurationID else { return }
                        migratingNamedHotkeyID = entry.activationShortcut == nil ? nil : entry.id
                        editingBinding = ActionBinding(trigger: BindingTrigger(keyboard: entry.activationShortcut), action: .macro(entry))
                    }
                }, onSave: { entry in
                    var next = store.settings.resolvedHotkeyDictionary.filter { $0.id != entry.id }
                    next.append(entry)
                    guard next.isValidDictionary else { return }
                    store.settings.hotkeyDictionary = next
                    editing = nil
                }, onCancel: { editing = nil })
        }
        .alert("Remove saved action?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove", role: .destructive) {
                store.settings.hotkeyDictionary = store.settings.resolvedHotkeyDictionary.filter { $0.id != deleting?.id }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Its global hotkey will stop working. Tap, swipe and HUD references to this action will also become inactive until reassigned.") }
        .onReceive(store.$activeConfigurationID.dropFirst()) { _ in
            editing = nil; editingBinding = nil; migratingNamedHotkeyID = nil; deleting = nil; layer = 0; clearSearch()
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
        editing = NamedHotkey(name: "", shortcut: RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17"))
    }

    private func chooseApplicationHotkey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let app = ExplorerApplicationCatalog.application(at: url) else { return }
        migratingNamedHotkeyID = nil
        editingBinding = ActionBinding(trigger: BindingTrigger(), action: .openApp(bundleID: app.bundleID, name: app.name))
    }

    private func assign(_ action: BindingAction) {
        migratingNamedHotkeyID = nil
        editingBinding = ActionBinding(trigger: BindingTrigger(), action: action)
    }

    private var builtInActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            actionGroup("Common Mac shortcuts", actions: CommonMacShortcut.all.map(\.action))
            actionGroup("Mac controls", actions: AppExplorerAction.macOSCommands.map { BindingAction(kind: .command, command: $0) })
            actionGroup("Windows", actions: AppExplorerAction.windowCommands.map { BindingAction(kind: .command, command: $0) })
            actionGroup("Window layouts", actions: ExplorerWindowLayout.allCases.flatMap { layout in
                SwipeDirection.allCases.map { BindingAction(kind: .windowPlacement, windowPlacement: ExplorerWindowPlacement(direction: $0, layout: layout)) }
            })
            actionGroup("Audio and media", actions: ExplorerMediaAction.allCases.map { BindingAction(kind: .media, media: $0) })
            actionGroup("HUDs", actions: [AppExplorerAction.windowManager, .mediaControls].map { BindingAction(kind: .command, command: $0) }
                + HUDNavigationAction.allCases.map { BindingAction(kind: .hudNavigation, hudNavigation: $0) })
            actionGroup("Pointer and keys", actions: TapAction.allCases.filter { $0 != .none && $0 != .shortcut }.map { BindingAction(kind: .tap, tap: $0) })
        }
    }

    private func actionGroup(_ title: String, actions: [BindingAction]) -> some View {
        let visible = actions.filter { textMatches($0.title + " " + $0.description) }
        return Group {
            if !visible.isEmpty {
                DisclosureGroup(title) {
                    ForEach(visible, id: \.identity) { action in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.title).fontWeight(.medium)
                                Text(action.description).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Assign…") { assign(action) }.help("Assign a keybinding or gesture to this action")
                        }.padding(8)
                    }
                }
            }
        }
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 12) {
            builtInActions
            HStack {
                Text("Macros: \(store.settings.resolvedHotkeyDictionary.count)").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Add keyboard action or macro") { beginNewAction() }
                    Button("Add application hotkey…") { chooseApplicationHotkey() }
                } label: { Label("Add action", systemImage: "plus") }
                .disabled(store.settings.resolvedHotkeyDictionary.count >= 500)
            }
            Text("Macros are reusable actions made of ordered steps. Assign keybindings or gestures to an action, or choose it in a HUD tile.")
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
                    Button("Assign…") { assign(.macro(entry)) }
                    Button("Edit") { editing = entry }
                    Button { deleting = entry } label: { Image(systemName: "trash") }.help("Remove saved action")
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            globalBindings
            let taps = audit.displayAssignments.filter { $0.kind == "Tap or gesture" && $0.enabled && assignmentMatches($0) }
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
                Text("\(audit.displayAssignments.filter { (showInactive || $0.enabled || $0.precedence.hasPrefix("Replaces")) && assignmentMatches($0) }.count) matches")
                    .foregroundStyle(.secondary)
            }
            let rows = audit.displayAssignments.filter { (showInactive || $0.enabled || $0.precedence.hasPrefix("Replaces")) && assignmentMatches($0) }
            ForEach(Array(Set(rows.map(\.scope))).sorted(), id: \.self) { scope in
                Text(scope).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 5)
                VStack(spacing: 1) {
                    ForEach(rows.filter { $0.scope == scope }) { assignmentCard($0) }
                }
            }
        }
    }

    @ViewBuilder private func assignmentCard(_ row: HotkeyAudit.Assignment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label(row.trigger, systemImage: row.kind == "Tap or gesture" ? "hand.tap" : row.inputScope != nil ? "keyboard" : "arrow.right.circle")
                    .fontWeight(.medium).lineLimit(1).frame(width: 205, alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Text(row.action).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if !row.enabled { Text("Inactive").font(.caption).foregroundStyle(.secondary) }
                Button {
                    expandedAssignment = expandedAssignment == row.id ? nil : row.id
                } label: {
                    Image(systemName: expandedAssignment == row.id ? "chevron.up" : "info.circle")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Show scope and precedence")
            }.frame(minHeight: 30)
            if expandedAssignment == row.id {
                Text(row.scope + (row.precedence.isEmpty ? "" : " · " + row.precedence))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(row.action).font(.caption).textSelection(.enabled)
                if !row.outputShortcuts.isEmpty {
                    Text("Sends: " + row.outputShortcuts.map(\.readableCombination).joined(separator: " → "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }.padding(.horizontal, 10).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            .help(row.trigger + " → " + row.action + " · " + row.scope)
    }

    private var globalBindings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Global assignments").font(.headline)
                Spacer()
                Button {
                    editingBinding = ActionBinding(trigger: BindingTrigger(), action: .hudLayer(nil))
                } label: { Label("Add assignment", systemImage: "plus") }
            }
            Text("Keyboard shortcuts, taps, and swipes can run any action. HUD layers have their own assignments while open.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach((store.settings.actionBindings ?? []).filter {
                textMatches($0.trigger.title + " " + store.settings.resolvedHotkeyDictionary.title(for: $0.action)) &&
                    (tapFilter == nil || $0.trigger.gesture == tapFilter) &&
                    (searchShortcut == nil || $0.trigger.keyboard?.identity == searchShortcut?.identity)
            }) { binding in
                HStack(spacing: 10) {
                    Text(binding.trigger.title).fontWeight(.medium).lineLimit(1).frame(width: 205, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(store.settings.resolvedHotkeyDictionary.title(for: binding.action)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit") { editingBinding = binding }
                    Button {
                        store.settings.actionBindings?.removeAll { $0.id == binding.id }
                    } label: { Image(systemName: "trash") }.help("Remove assignment")
                }.padding(8).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            }
            Divider().padding(.vertical, 6)
        }
    }

    private func keyboard(_ audit: HotkeyAudit) -> some View {
        let visible = audit.displayAssignments.filter { $0.enabled && assignmentMatches($0) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Assigned keys are highlighted. Select a key to see every modifier combination, tap output, launcher and HUD action that uses it.")
                .font(.caption).foregroundStyle(.secondary)
            AssignmentKeyboardLayout(assignments: visible, selectedKeyCode: $selectedKeyCode)
            if let selectedKeyCode {
                let rows = visible.filter { $0.searchableShortcuts.contains { $0.isPhysicalShortcut && $0.keyCode == selectedKeyCode } }
                Text("Assignments on \(KeyboardLayoutKey.label(for: selectedKeyCode)) · \(rows.count)").font(.headline)
                if rows.isEmpty { Text("No matching assignment on this key.").foregroundStyle(.secondary) }
                ForEach(rows) { assignmentCard($0) }
            } else {
                Text("Choose a highlighted key, or press a hotkey in the search control above.").foregroundStyle(.secondary)
            }
            if tapFilter != nil {
                let nonKeyboard = visible.filter { $0.kind == "Tap or gesture" && !$0.searchableShortcuts.contains { $0.isPhysicalShortcut } }
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
                            let matches = assignments.filter { $0.searchableShortcuts.contains { $0.isPhysicalShortcut && $0.keyCode == key.code } }
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
    var onAssignTrigger: ((NamedHotkey) -> Void)? = nil
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
                    Text("Triggers").fontWeight(.medium)
                    Spacer()
                    if let key = entry.activationShortcut {
                        Text(key.readableCombination).font(.callout.monospaced())
                        Button { entry.activationShortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Remove global hotkey")
                    }
                }
                Text("This saved action can be reused by any keyboard, tap or swipe trigger. Assign triggers in the shared assignment editor.")
                    .font(.caption).foregroundStyle(.secondary)
                if let onAssignTrigger {
                    Button(entry.activationShortcut == nil ? "Save and assign trigger…" : "Save and edit trigger…") {
                        entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        updateSteps(entry.resolvedSequence)
                        onAssignTrigger(entry)
                    }
                    .disabled(!entry.isValid || activationConflict)
                }
                if activationConflict { Text("That global hotkey is already assigned to another saved action.").font(.caption).foregroundStyle(.red) }
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
                    .disabled(!entry.isValid || activationConflict)
            }
        }.padding(24).frame(width: 590)
    }
}
