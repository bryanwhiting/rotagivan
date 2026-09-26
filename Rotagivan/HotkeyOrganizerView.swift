import SwiftUI
import UniformTypeIdentifiers

private struct ActionApplicationIcon: View {
    let bundleID: String
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().scaledToFit() }
            else { Image(systemName: "app") }
        }.frame(width: 20, height: 20).accessibilityHidden(true)
            .task(id: bundleID) {
                icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            }
    }
}

struct ActionVocabularyEditor: View {
    let row: ActionTableRow
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    init(row: ActionTableRow, onSave: @escaping (String) -> Void) {
        self.row = row; self.onSave = onSave
        _text = State(initialValue: row.keywords)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voice dictionary · \(row.name)").font(.title2.weight(.semibold))
            Label("Reserved description", systemImage: "lock").font(.headline)
            Text(row.detail).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Keyword sets").font(.headline)
            Text("One set per line; separate related phrases with commas. For example: team chat, open Slack. Up to 20 sets, 12 phrases per set, 120 characters per phrase. These hints improve matching; they do not retrain the model.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .accessibilityLabel("Voice keyword sets")
            Text("Keyword sets are saved with your settings and sent with action descriptions for voice matching.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Clear") { text = "" }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
    }
}

struct HotkeyOrganizerView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var keys = ShortcutSettings.shared
    @ObservedObject private var voiceApps = VoiceApplicationIndex.shared
    @State private var tab = "Dictionary"
    @AppStorage("actions.showIDs") private var showActionIDs = false
    @State private var actionGroupFilter = "All groups"
    @State private var actionSubgroupFilter = "All subgroups"
    @State private var vocabularyRow: ActionTableRow?
    @State private var overrideRow: ActionTableRow?
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
            Text("Browse actions and their keybindings. Search or filter by group, then use a row’s menu to assign or edit.")
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
        .sheet(item: $vocabularyRow) { row in
            ActionVocabularyEditor(row: row) { text in
                var entries = store.settings.actionVocabulary ?? []
                entries.removeAll { $0.actionID == row.id }
                let sets = ActionVocabulary.parse(text)
                if !sets.isEmpty { entries.append(ActionVocabulary(actionID: row.id, keywordSets: sets)) }
                store.settings.actionVocabulary = entries.isEmpty ? nil : entries
            }
        }
        .sheet(item: $overrideRow) { row in
            VStack(alignment: .leading) {
                AppOverridesView(store: store, initialBundleID: row.appBundleID ?? "com.google.Chrome")
                HStack { Spacer(); Button("Done") { overrideRow = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 720, height: 580)
        }
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

    private var dictionary: some View {
        let rows = ActionTableRow.make(settings: store.settings, applications: voiceApps.applications, audit: audit)
        let visible = rows.filter { row in
            (actionGroupFilter == "All groups" || row.group == actionGroupFilter) &&
                (actionSubgroupFilter == "All subgroups" || row.subgroup == actionSubgroupFilter) &&
                textMatches([row.id, row.group, row.subgroup, row.name, row.detail, row.keybindings, row.keywords].joined(separator: " "))
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Group", selection: $actionGroupFilter) {
                    Text("All groups").tag("All groups")
                    ForEach(Array(Set(rows.map(\.group))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 220)
                .onChange(of: actionGroupFilter) { _ in actionSubgroupFilter = "All subgroups" }
                Picker("Subgroup", selection: $actionSubgroupFilter) {
                    Text("All subgroups").tag("All subgroups")
                    ForEach(Array(Set(rows.filter { actionGroupFilter == "All groups" || $0.group == actionGroupFilter }.map(\.subgroup))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 230)
                Toggle("Show action IDs", isOn: $showActionIDs).toggleStyle(.checkbox)
                Spacer()
                Text("\(visible.count) actions").foregroundStyle(.secondary)
                Menu {
                    Button("Add keyboard action or macro") { beginNewAction() }
                        .disabled(store.settings.resolvedHotkeyDictionary.count >= 500)
                    Button("Add application hotkey…") { chooseApplicationHotkey() }
                    Button("Add assignment…") { assign(.hudLayer(nil)) }
                } label: { Label("Add action", systemImage: "plus") }
            }
            Table(visible) {
                if showActionIDs {
                    TableColumn("Action ID") { row in
                        Text(row.id).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).help(row.id)
                    }.width(min: 160, ideal: 190)
                }
                TableColumn("Action group", value: \.group).width(min: 85, ideal: 110, max: 150)
                TableColumn("Subgroup") { row in
                    HStack(spacing: 6) {
                        if let bundleID = row.appBundleID { ActionApplicationIcon(bundleID: bundleID) }
                        Text(row.subgroup.isEmpty ? "—" : row.subgroup).lineLimit(1).help(row.subgroup)
                    }
                }.width(min: 110, ideal: 140)
                TableColumn("Action name", value: \.name).width(min: 125, ideal: 170)
                TableColumn("Reserved description") { row in
                    Text(row.detail).lineLimit(2).help(row.detail)
                }.width(min: 160, ideal: 290)
                TableColumn("Keyword sets") { row in
                    Button { vocabularyRow = row } label: {
                        Text(row.keywords.isEmpty ? "Add keywords…" : row.keywords)
                            .lineLimit(2).help(row.keywords.isEmpty ? "Teach voice alternative phrases for this action" : row.keywords)
                    }.buttonStyle(.link)
                }.width(min: 115, ideal: 170)
                TableColumn("Keybindings") { row in
                    HStack(spacing: 6) {
                        Text(row.keybindings.isEmpty ? "—" : row.keybindings)
                            .foregroundStyle(row.keybindings.isEmpty ? .tertiary : .secondary)
                            .lineLimit(2).help(row.keybindings)
                        Spacer(minLength: 0)
                        Menu {
                            Button("Edit voice keywords…") { vocabularyRow = row }
                            if let bundleID = row.appBundleID {
                                Button("Application overrides…") {
                                    var apps = store.settings.resolvedAppOverrides
                                    if !apps.contains(where: { $0.bundleID == bundleID }) {
                                        apps.append(AppGestureOverride(bundleID: bundleID, name: row.subgroup))
                                        store.settings.appOverrides = apps
                                    }
                                    overrideRow = row
                                }
                            }
                            Button("Add keybinding or gesture…") { assign(row.action) }.disabled(row.isAppScoped)
                            ForEach((store.settings.actionBindings ?? []).filter { $0.action.identity == row.action.identity }) { binding in
                                Button("Edit \(binding.trigger.title)…") { editingBinding = binding }
                                Button("Remove \(binding.trigger.title)", role: .destructive) {
                                    store.settings.actionBindings?.removeAll { $0.id == binding.id }
                                }
                            }
                            if let macro = store.settings.resolvedHotkeyDictionary.first(where: { $0.id == row.action.macroID }) {
                                Divider()
                                Button("Edit action…") { editing = macro }
                                Button("Remove action…", role: .destructive) { deleting = macro }
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Manage \(row.name)")
                    }
                }.width(min: 135, ideal: 200)
            }
            .frame(height: 520)
            .accessibilityIdentifier("actions-table")
            if visible.isEmpty { Text("No actions match this search.").foregroundStyle(.secondary) }
            Text("App defaults are keys sent inside that app, not global registrations. App overrides and voice shortcuts apply only in their app. Reserved descriptions are read-only; add keyword sets to teach voice your phrases.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await voiceApps.load() }
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
