import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var hid: NavigatorHIDManager
    @State private var showingImport = false
    @State private var text = ""
    @State private var candidate: AppConfiguration?
    @State private var error: String?
    @State private var status = ""
    @State private var confirmImport = false
    @State private var confirmDefaults = false
    @State private var hasBackup = UserDefaults.standard.data(forKey: backupKey) != nil
    private static let backupKey = "configuration.previous.v1"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration").font(.headline)
            Text("One YAML file contains all layers, motion, scrolling, taps, dragging, hotkeys, and slider calibration. Permissions stay on this Mac.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy YAML") { perform {
                    let yaml = try AppConfiguration(store: store).yaml()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(yaml, forType: .string)
                    status = "Complete configuration copied."
                } }
                Button("Save YAML…") { saveFile() }
                Button("Import YAML…") {
                    text = ""; candidate = nil; error = nil; showingImport = true
                }
            }
            HStack {
                Button("Restore defaults…") { confirmDefaults = true }
                Button("Undo last import") { perform {
                    guard let data = UserDefaults.standard.data(forKey: Self.backupKey) else { return }
                    let previous = try JSONDecoder().decode(AppConfiguration.self, from: data)
                    try apply(previous)
                    status = "Previous configuration restored."
                } }.disabled(!hasBackup)
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let error, !showingImport {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showingImport) { importer }
        .confirmationDialog("Restore the bundled defaults? This replaces every layer and shortcut. You can undo it.", isPresented: $confirmDefaults) {
            Button("Restore defaults", role: .destructive) { perform {
                try apply(AppConfiguration.factory())
                status = "Bundled defaults restored."
            } }
        }
    }

    private var importer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import configuration").font(.title2.weight(.semibold))
            Text("Paste a complete Rotagivan YAML config or open a file. Validate it before replacing your current settings.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Paste clipboard") {
                    text = NSPasteboard.general.string(forType: .string) ?? ""
                }
                Button("Open YAML file…") { openFile() }
                Spacer()
                Text("\(text.utf8.count.formatted()) bytes").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $text).font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 260)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                .accessibilityLabel("YAML configuration")
            if let candidate {
                Text("Valid • \(2 + (candidate.settings.additionalProfiles?.count ?? 0)) layers • Default: \(candidate.settings.profileName(for: candidate.settings.resolvedDefaultProfileID, fallback: candidate.settings.resolvedDefaultProfileID == 1 ? "Normal" : "Precision"))")
                    .font(.caption).foregroundStyle(.green)
            }
            if let error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 75)
            }
            HStack {
                Button("Cancel") { showingImport = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Validate") {
                    candidate = nil
                    perform { candidate = try AppConfiguration.parse(text) }
                }
                Button("Replace configuration…") { confirmImport = true }
                    .disabled(candidate == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 620, height: 510)
        .onChange(of: text) { _, _ in candidate = nil; error = nil }
        .confirmationDialog("Replace all layers and shortcuts with this YAML? Your current configuration will be saved for Undo.", isPresented: $confirmImport) {
            Button("Replace configuration", role: .destructive) {
                guard let candidate else { return }
                perform {
                    try apply(candidate)
                    showingImport = false
                    status = "Configuration imported. Use Undo last import to restore the previous settings."
                }
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        error = nil
        do { try operation() }
        catch { self.error = error.localizedDescription }
    }

    private func saveFile() {
        perform {
            let yaml = try AppConfiguration(store: store).yaml()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "rotagivan.yaml"
            panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .text]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            status = "Configuration saved."
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw ConfigurationError("Configuration is larger than 1 MB.") }
            text = try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func apply(_ config: AppConfiguration) throws {
        try config.validate()
        let previous = try JSONEncoder().encode(AppConfiguration(store: store))
        // This is the only OS-level setting in the config. If macOS rejects
        // the change, leave profile and shortcut preferences untouched.
        let loginEnabled = SMAppService.mainApp.status == .enabled
        if config.settings.launchAtLogin != loginEnabled {
            if config.settings.launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        }
        UserDefaults.standard.set(previous, forKey: Self.backupKey)
        hasBackup = true
        NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)
        hid.stop() // Release held drags and stop momentum before replacing state.
        store.replaceSettings(config.settings)
        let keys = config.shortcuts
        ShortcutSettings.shared.replaceConfiguration(normal: keys.normal, precision: keys.precision,
            actions: keys.actions, additional: keys.additional, profileActions: keys.profileActions,
            holdToActivate: keys.holdToActivate)
        AppConfiguration.markCurrent(.standard)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
            if store.settings.enabled { hid.start() }
        }
    }
}
