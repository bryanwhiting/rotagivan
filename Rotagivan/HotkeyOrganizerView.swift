import SwiftUI

struct HotkeyOrganizerView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var keys = ShortcutSettings.shared
    @State private var tab = "Dictionary"
    @State private var search = ""
    @State private var layer: UInt32 = 0
    @State private var device: GestureDevice = .navigator
    @State private var showInactive = false
    @State private var editing: NamedHotkey?
    @State private var deleting: NamedHotkey?

    private var selectedLayer: UInt32 { store.profiles.contains { $0.id == layer } ? layer : store.defaultProfileID }
    private var audit: HotkeyAudit {
        HotkeyAudit(settings: store.settings, shortcuts: ShortcutConfiguration(keys), layerID: selectedLayer, device: device)
    }
    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name reusable shortcuts and understand what wins. This organizer covers bindings configured in Rotagivan—not shortcuts privately configured in other apps or macOS.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("View", selection: $tab) {
                Text("Dictionary").tag("Dictionary")
                Text("Conflicts & overrides").tag("Conflicts")
                Text("All assignments").tag("Assignments")
            }.pickerStyle(.segmented)
            TextField("Search names, keys, apps or actions", text: $search).textFieldStyle(.roundedBorder)
            if tab == "Dictionary" { dictionary }
            else {
                HStack {
                    Picker("Layer", selection: Binding(get: { selectedLayer }, set: { layer = $0 })) {
                        ForEach(store.profiles, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("Device", selection: $device) {
                        ForEach(GestureDevice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Text("Auditing this layer and device, all of its app rules, and every HUD group. Activation keys from other layers are included because they register globally. Select another layer to inspect its tap actions.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = keys.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if tab == "Conflicts" { findings(audit) }
                else { assignments(audit) }
            }
        }
        .font(.system(size: 12))
        .sheet(item: $editing) { value in
            NamedHotkeyEditor(entry: value, existing: store.settings.resolvedHotkeyDictionary, onSave: { entry in
                var next = store.settings.resolvedHotkeyDictionary.filter { $0.id != entry.id }
                next.append(entry)
                guard next.isValidDictionary else { return }
                store.settings.hotkeyDictionary = next
                editing = nil
            }, onCancel: { editing = nil })
        }
        .alert("Remove shortcut name?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove", role: .destructive) {
                store.settings.hotkeyDictionary = store.settings.resolvedHotkeyDictionary.filter { $0.id != deleting?.id }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Assigned actions keep their key combinations. Only the dictionary name is removed.") }
        .onReceive(store.$activeConfigurationID.dropFirst()) { _ in editing = nil; deleting = nil; layer = 0 }
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(store.settings.resolvedHotkeyDictionary.count) named shortcuts").foregroundStyle(.secondary)
                Spacer()
                Button { editing = NamedHotkey(name: "", shortcut: RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17")) } label: {
                    Label("Add hotkey", systemImage: "plus")
                }.disabled(store.settings.resolvedHotkeyDictionary.count >= 500)
            }
            Text("Names are shared across this profile’s layers, app rules and HUD tiles, and travel with YAML/sync. Adding a name does not register a new hotkey. Choose saved names from any shortcut editor’s ••• menu.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.settings.resolvedHotkeyDictionary.isEmpty {
                Label("Your dictionary is empty. Add a shortcut and give it a meaningful name.", systemImage: "book.closed")
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(store.settings.resolvedHotkeyDictionary.filter { matches($0.name + " " + $0.shortcut.readableCombination) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { entry in
                HStack(spacing: 12) {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    Text(entry.name).fontWeight(.medium)
                    Spacer()
                    Text(entry.shortcut.readableCombination).monospaced().foregroundStyle(.secondary)
                    Button("Edit") { editing = entry }
                    Button { deleting = entry } label: { Image(systemName: "trash") }.help("Remove dictionary name")
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func findings(_ audit: HotkeyAudit) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if audit.findings.isEmpty { Label("No conflicts or app overrides in this context.", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            ForEach(HotkeyAudit.Kind.allCases, id: \.self) { kind in
                let rows = audit.findings.filter { $0.kind == kind && matches($0.title + " " + $0.detail) }
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
            Toggle("Show inactive or unassigned actions", isOn: $showInactive)
            ForEach(audit.assignments.filter { (showInactive || $0.enabled || $0.precedence.hasPrefix("Replaces")) && matches($0.searchText) }) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(row.trigger).fontWeight(.medium); Spacer(); Text(row.enabled ? row.scope : row.scope + " · inactive").foregroundStyle(.secondary) }
                    Text(row.action).textSelection(.enabled)
                    if !row.precedence.isEmpty { Text(row.precedence).font(.caption).foregroundStyle(.secondary) }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct NamedHotkeyEditor: View {
    @State var entry: NamedHotkey
    var existing: [NamedHotkey]
    var onSave: (NamedHotkey) -> Void
    var onCancel: () -> Void
    @State private var action: TapAction = .shortcut
    private var duplicate: NamedHotkey? { existing.first { $0.id != entry.id && $0.shortcut.identity == entry.shortcut.identity } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Named hotkey", systemImage: "book.closed").font(.headline)
            TextField("Shortcut name", text: $entry.name).textFieldStyle(.roundedBorder)
            TapActionEditor(title: "Key combination", action: $action, shortcut: Binding(get: { entry.shortcut }, set: { if let value = $0 { entry.shortcut = value } }), keyboardOnly: true)
            Text("Names update matching HUD tiles automatically. Changing this combination only changes the dictionary entry—it does not rebind existing actions.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let duplicate { Text("This combination is already named “\(duplicate.name)”. Edit that entry instead.").foregroundStyle(.orange).font(.caption) }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines); onSave(entry) }
                    .keyboardShortcut(.defaultAction).disabled(!entry.isValid || duplicate != nil)
            }
        }.padding(24).frame(width: 440)
    }
}
