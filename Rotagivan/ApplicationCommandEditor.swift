import SwiftUI

/// Shared by the sheet and its native UI fixtures. Vocabulary belongs to the
/// stable command ID, not its changing name or output.
enum ApplicationCommandEdits {
    static func save(_ command: ApplicationCommand, settings: inout StoredSettings) {
        guard command.isValid else { return }
        var commands = settings.resolvedApplicationCommands
        if let index = commands.firstIndex(where: { $0.id == command.id }) { commands[index] = command }
        else {
            guard commands.count < 500 else { return }
            commands.append(command)
        }
        settings.applicationCommands = commands
    }
    static func remove(_ command: ApplicationCommand, settings: inout StoredSettings) {
        settings.applicationCommands = settings.resolvedApplicationCommands.filter { $0.id != command.id }
        settings.actionVocabulary?.removeAll { $0.actionID == command.voiceActionID }
        if settings.actionVocabulary?.isEmpty == true { settings.actionVocabulary = nil }
    }
}

struct ApplicationCommandEditor: View {
    @State private var command: ApplicationCommand
    @State private var output: String
    @State private var shortcut: RecordedShortcut?
    @State private var url: String
    let applications: [ExplorerApplication]
    let existing: [ApplicationCommand]
    var onSave: (ApplicationCommand) -> Void
    var onCancel: () -> Void

    init(command: ApplicationCommand, applications: [ExplorerApplication], existing: [ApplicationCommand],
         onSave: @escaping (ApplicationCommand) -> Void, onCancel: @escaping () -> Void) {
        _command = State(initialValue: command)
        _output = State(initialValue: command.action.kind == .openURL ? "URL" : "Shortcut")
        _shortcut = State(initialValue: command.action.shortcut)
        _url = State(initialValue: command.action.url ?? "")
        self.applications = applications; self.existing = existing
        self.onSave = onSave; self.onCancel = onCancel
    }
    private var appChoices: [ExplorerApplication] {
        var seen = Set<String>()
        return applications.filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var draft: ApplicationCommand {
        var value = command
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.detail = value.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if output == "URL" {
            value.action = .openURL(url.trimmingCharacters(in: .whitespacesAndNewlines))
            value.action.targetBrowserBundleID = value.bundleID
        } else if let shortcut {
            value.action = .keystroke(shortcut)
        } else {
            value.action = BindingAction(kind: .keystroke)
        }
        return value
    }
    private var atCapacity: Bool { existing.count >= 500 && !existing.contains { $0.id == command.id } }
    private var validation: String? {
        if command.bundleID.isEmpty { return "Choose the application this command belongs to." }
        if draft.name.isEmpty { return "Give this command a name." }
        if draft.detail.isEmpty { return "Describe what this command does so voice can find it." }
        if output == "Shortcut", shortcut?.isPhysicalShortcut != true { return "Record a physical keyboard shortcut." }
        if !draft.isValid { return output == "URL" ? "Enter a complete HTTP or HTTPS URL without a username or password." : "Check the command fields and shortcut." }
        if atCapacity { return "You can save up to 500 application commands." }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if !command.bundleID.isEmpty {
                    ActionApplicationIcon(bundleID: command.bundleID).scaleEffect(1.6).frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.badge").font(.system(size: 28, weight: .light)).foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(existing.contains { $0.id == command.id } ? "Edit application command" : "New application command")
                        .font(.title2.weight(.semibold))
                    Text("A named action that runs inside one application.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Application").font(.headline)
                Picker("Application", selection: $command.bundleID) {
                    Text("Choose an application…").tag("")
                    if !command.bundleID.isEmpty && !appChoices.contains(where: { $0.bundleID == command.bundleID }) {
                        Text(command.appName + " (not installed)").tag(command.bundleID)
                    }
                    ForEach(appChoices, id: \.bundleID) { app in Text(app.name).tag(app.bundleID) }
                }.labelsHidden().accessibilityIdentifier("application-command-app")
                    .onChange(of: command.bundleID) { bundleID in
                        command.appName = appChoices.first { $0.bundleID == bundleID }?.name ?? command.appName
                    }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Command").font(.headline)
                TextField("Name, such as Open team workspace", text: $command.name)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Command name")
                    .accessibilityIdentifier("application-command-name")
                TextField("What does this command do?", text: $command.detail, axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder).accessibilityLabel("Command description")
                    .accessibilityIdentifier("application-command-description")
                Text("The description and your separate keyword sets help voice match this command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Output").font(.headline)
                Picker("Output", selection: $output) {
                    Text("Send shortcut").tag("Shortcut")
                    Text("Open URL").tag("URL")
                }.pickerStyle(.segmented).accessibilityIdentifier("application-command-output")
                if output == "Shortcut" {
                    HStack {
                        ShortcutRecorder(title: shortcut?.readableCombination ?? "Record shortcut…") { shortcut = $0 }
                            .frame(width: 205, height: 30).accessibilityIdentifier("application-command-shortcut")
                        if shortcut != nil {
                            Button("Clear") { shortcut = nil }.buttonStyle(.link)
                                .accessibilityIdentifier("application-command-clear-shortcut")
                        }
                    }
                    Text("Sends keys only while \(command.appName.isEmpty ? "the chosen app" : command.appName) is frontmost. This does not register a global hotkey.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("https://example.com/workspace", text: $url)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Command URL")
                        .accessibilityIdentifier("application-command-url")
                    Text("Opens this URL in \(command.appName.isEmpty ? "the chosen application" : command.appName). The application decides which window or browser profile handles it. Voice can choose it only while that app is frontmost.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            Toggle("Enabled for voice matching", isOn: $command.enabled)
                .accessibilityIdentifier("application-command-enabled")
            Text(validation ?? "Ready to save. Nothing runs when you save this command.")
                .font(.caption).foregroundStyle(validation == nil ? Color.secondary : Color.orange)
                .frame(minHeight: 30, alignment: .leading).accessibilityIdentifier("application-command-validation")
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("application-command-cancel")
                Spacer()
                Button("Save command") { guard validation == nil else { return }; onSave(draft) }
                    .keyboardShortcut(.defaultAction).disabled(validation != nil)
                    .accessibilityIdentifier("application-command-save")
            }
        }.padding(24).frame(width: 560)
    }
}

struct ApplicationCommandRemovalConfirmation: View {
    let command: ApplicationCommand
    var onDelete: () -> Void
    var onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Delete application command?", systemImage: "trash").font(.title2.weight(.semibold))
            Text("“\(command.name)” in \(command.appName) and its voice keyword sets will be removed. Other commands and application defaults are kept.")
                .fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("application-command-delete-cancel")
                Spacer()
                Button("Delete command", role: .destructive, action: onDelete)
                    .accessibilityIdentifier("application-command-delete-confirm")
            }
        }.padding(24).frame(width: 500)
    }
}
