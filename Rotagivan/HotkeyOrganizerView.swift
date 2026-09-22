import SwiftUI
import UniformTypeIdentifiers

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
            Text("Build reusable macros: open apps and send key combinations in order. Review conflicts and app overrides for bindings configured in Rotagivan.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("View", selection: $tab) {
                Text("Macros").tag("Dictionary")
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
        .alert("Remove macro?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove", role: .destructive) {
                store.settings.hotkeyDictionary = store.settings.resolvedHotkeyDictionary.filter { $0.id != deleting?.id }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Actions referencing this macro will stop working until reassigned. Legacy key-combination assignments keep their original keystroke.") }
        .onReceive(store.$activeConfigurationID.dropFirst()) { _ in editing = nil; deleting = nil; layer = 0 }
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(store.settings.resolvedHotkeyDictionary.count) macros").foregroundStyle(.secondary)
                Spacer()
                Button { editing = NamedHotkey(name: "", shortcut: RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17")) } label: {
                    Label("Add macro", systemImage: "plus")
                }.disabled(store.settings.resolvedHotkeyDictionary.count >= 500)
            }
            Text("Assign a macro from an action’s ••• menu in layers, app overrides, or HUD tiles. Editing its sequence updates every macro assignment. Macros travel with YAML/sync; creating one does not register a global hotkey.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.settings.resolvedHotkeyDictionary.isEmpty {
                Label("No macros yet. Add a named sequence of app and keystroke steps.", systemImage: "book.closed")
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(store.settings.resolvedHotkeyDictionary.filter { matches($0.name + " " + $0.summary) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { entry in
                HStack(spacing: 12) {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    Text(entry.name).fontWeight(.medium)
                    Spacer()
                    Text(entry.summary).monospaced().foregroundStyle(.secondary).lineLimit(2)
                    Button("Edit") { editing = entry }
                    Button { deleting = entry } label: { Image(systemName: "trash") }.help("Remove macro")
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
            Label("Macro", systemImage: "keyboard").font(.headline)
            TextField("Macro name", text: $entry.name).textFieldStyle(.roundedBorder)
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
            }.frame(height: min(320, CGFloat(entry.resolvedSequence.count) * 66))
            HStack {
                Button("Add keystroke") { updateSteps(entry.resolvedSequence + [.key(RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return"))]) }
                Button("Add open app…") { chooseApp() }
            }.disabled(entry.resolvedSequence.count >= 32)
            Stepper("Delay between steps: \(entry.resolvedDelay) ms", value: Binding(get: { entry.resolvedDelay }, set: { entry.stepDelayMilliseconds = $0 }), in: 0...2000, step: 25)
            Text("Up to 32 steps. Open app launches or activates it before the next keystroke. The delay also gives the app time to prepare. If opening fails or focus changes unexpectedly, playback stops. Move steps with ↑ to set their order.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines); updateSteps(entry.resolvedSequence); onSave(entry) }
                    .keyboardShortcut(.defaultAction).disabled(!entry.isValid)
            }
        }.padding(24).frame(width: 560)
    }
}
