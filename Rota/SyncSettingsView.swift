import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject var sync: SettingsSync
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creating = false
    @State private var changingPassword = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmNewPassword = ""
    @State private var openRouterKey = ""
    @State private var openAIKey = ""
    @State private var keysNotice: String?
    @State private var confirmingLeave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch sync.mode {
            case nil: chooser
            case .cloud: cloudCard
            case .local: localCard
            }
            if sync.mode != nil { apiKeysCard }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { Task { await sync.synchronizeAutomatically(trigger: .manual) } }
        .sheet(isPresented: $changingPassword, onDismiss: clearPasswords) { passwordSheet }
    }

    // MARK: Mode chooser

    private var chooser: some View { SyncModeChooser(sync: sync) }

    // MARK: Cloud

    private var cloudCard: some View {
        RotaCard("Cloud sync", systemImage: "icloud", accessory: { leaveMenu }) {
            VStack(alignment: .leading, spacing: 12) {
                if !sync.credentialsReady {
                    Text(sync.restoringLogin ? "Restoring your account…" : "Unlock your saved account to resume sync.")
                    if !sync.restoringLogin {
                        Button("Unlock account") { sync.retryLoginRestore() }.accessibilityIdentifier("sync-restore-retry")
                    }
                } else if let account = sync.account, sync.unlocked {
                    statusLine
                    Text("Signed in as \(account.email). Settings and API keys are encrypted with a key derived from your password; the server only ever sees ciphertext. Edits upload within a second; other Macs check hourly, on wake, and whenever you use the HUD.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let date = sync.lastChecked ?? sync.lastSave {
                            Text("Last checked " + date.formatted(.dateTime.hour().minute().second())).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download latest") { NSWorkspace.shared.open(URL(string: "https://rota.silvermine.dev/download/latest")!) }
                            .accessibilityIdentifier("sync-download-latest")
                        syncNowButton
                    }
                    conflict
                } else if let account = sync.account {
                    // Signed in by an older build: the password is needed once to derive the key.
                    Text("Enter the password for \(account.email) to unlock sync on this Mac.")
                    SecureField("Password", text: $password).textContentType(.password)
                    HStack {
                        Button("Unlock") {
                            let submitted = password; password = ""
                            Task { await sync.authenticate(email: account.email, password: submitted, create: false) }
                        }.buttonStyle(.rotaPrimary).disabled(sync.busy || password.count < 12)
                        Button("Sign out") { Task { await sync.signOut() } }
                    }
                } else {
                    Text("Sign in to keep settings and API keys in sync on your Macs.").foregroundStyle(.secondary)
                    TextField("Email", text: $email).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(creating ? .newPassword : .password)
                    if creating { SecureField("Confirm password", text: $confirmation) }
                    HStack {
                        Button(creating ? "Create account" : "Sign in") {
                            let submitted = password; password = ""; confirmation = ""
                            Task { await sync.authenticate(email: email, password: submitted, create: creating) }
                        }.buttonStyle(.rotaPrimary)
                            .disabled(sync.busy || email.isEmpty || password.count < 12 || (creating && confirmation != password))
                            .accessibilityIdentifier("sync-sign-in")
                        Button(creating ? "I already have an account" : "Create an account") { creating.toggle() }
                    }
                    Text("At least 12 characters. Your password is the only key to your settings: there is no reset. Keep it in a password manager.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                errorLine
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var leaveMenu: some View {
        RotaMenuButton(sync.account?.email ?? "Options", systemImage: "person.crop.circle", kind: .field) {
            if sync.account != nil, sync.unlocked { Button("Change password…") { changingPassword = true } }
            if sync.account != nil { Button("Sign out") { Task { await sync.signOut() } } }
            Divider()
            Button("Use a local file instead…") { confirmingLeave = true }
        }
        .disabled(sync.busy)
        .accessibilityIdentifier("sync-account-menu")
        .confirmationDialog("Stop cloud sync on this Mac?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Switch to a local file") { sync.choose(.local) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Settings stay on this Mac and are written to settings.yaml from now on. The cloud copy is left as it is.") }
    }

    // MARK: Local

    private var localCard: some View {
        RotaCard("Local file", systemImage: "folder", accessory: {
            RotaMenuButton("Options", systemImage: "ellipsis.circle", kind: .field) {
                Button("Use cloud sync instead") { sync.choose(.cloud) }
            }.accessibilityIdentifier("sync-local-menu")
        }) {
            VStack(alignment: .leading, spacing: 12) {
                statusLine
                HStack(spacing: RotaTokens.Space.m) {
                    Text(shortPath(sync.localFile)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([sync.localFile]) }
                    Button("Change folder…") { chooseFolder() }.accessibilityIdentifier("sync-local-folder")
                    syncNowButton
                }
                Text("Every edit is written to settings.yaml within a second. When the file changes on disk (an editor, git pull, a synced folder), this Mac loads it. If both change at once, the newer edit wins and the other is kept in backup/.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                gitSection
                conflict
                errorLine
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var gitSection: some View {
        VStack(alignment: .leading, spacing: RotaTokens.Space.m) {
            if sync.isGitRepository {
                Label("Git repository" + (sync.gitRemote.map { " · remote \($0)" } ?? " · no remote"), systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                Toggle("Commit and push after each change", isOn: $sync.gitAutoCommit).toggleStyle(.rotaSwitch)
                    .accessibilityIdentifier("sync-git-autocommit")
                Toggle("Pull on launch, on wake and hourly", isOn: $sync.gitAutoPull).toggleStyle(.rotaSwitch)
                    .accessibilityIdentifier("sync-git-autopull")
                HStack {
                    Button("Pull now") { Task { await sync.pullNow() } }.accessibilityIdentifier("sync-git-pull")
                    Button("Commit & push now") { Task { await sync.commitAndPushNow() } }.accessibilityIdentifier("sync-git-push")
                }
                if sync.gitRemote == nil {
                    Text("Add a remote to push: in Terminal, `git -C \(shortPath(sync.localFolder)) remote add origin <url>`.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let output = sync.gitOutput, !output.isEmpty {
                    Text(output).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            } else {
                HStack {
                    Text("Not a git repository.").font(.caption).foregroundStyle(.secondary)
                    Button("Initialize git repository") { Task { await sync.initializeGit() } }.accessibilityIdentifier("sync-git-init")
                }
            }
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = sync.localFolder
        panel.prompt = "Use this folder"
        panel.message = "Rota writes settings.yaml (and a backup/ folder) here."
        if panel.runModal() == .OK, let url = panel.url { sync.chooseLocalFolder(url) }
    }
    private func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    // MARK: API keys

    private var apiKeysCard: some View {
        RotaCard("API keys", systemImage: "key", subtitle: sync.mode == .cloud
            ? "Saved in your encrypted cloud document and used on every Mac you sign in to."
            : "Read from ~/.env on this Mac. They are never written to settings.yaml.") {
            VStack(alignment: .leading, spacing: 12) {
                let environment = sync.environmentSecretNames()
                ForEach(SyncSecrets.names, id: \.self) { name in
                    HStack {
                        Text(displayName(name)).frame(width: 110, alignment: .leading)
                        if sync.mode == .cloud {
                            Image(systemName: sync.savedSecretNames.contains(name) ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(sync.savedSecretNames.contains(name) ? RotaTokens.accent : .secondary)
                            Text(sync.savedSecretNames.contains(name) ? "Saved" : (environment.contains(name) ? "Not saved · found in ~/.env" : "Not saved"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: environment.contains(name) ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(environment.contains(name) ? RotaTokens.accent : .secondary)
                            Text(environment.contains(name) ? "Found in ~/.env" : "Add \(name)=… to ~/.env").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if sync.mode == .cloud, sync.unlocked {
                    SecureField("Paste OpenRouter API key", text: $openRouterKey).accessibilityIdentifier("sync-key-openrouter")
                    SecureField("Paste OpenAI API key", text: $openAIKey).accessibilityIdentifier("sync-key-openai")
                    HStack {
                        Button("Save keys") {
                            if !openRouterKey.isEmpty { sync.setSecret("OPENROUTER_API_KEY", value: openRouterKey) }
                            if !openAIKey.isEmpty { sync.setSecret("OPENAI_ROTA_KEY", value: openAIKey) }
                            openRouterKey = ""; openAIKey = ""
                            keysNotice = "Saved. They upload with your next sync."
                        }.buttonStyle(.rotaPrimary).disabled(openRouterKey.isEmpty && openAIKey.isEmpty)
                            .accessibilityIdentifier("sync-save-keys")
                        Button("Import from ~/.env") {
                            let imported = sync.importSecretsFromEnvironment()
                            keysNotice = imported.isEmpty ? "No keys found in ~/.env." : "Imported " + imported.map(displayName).joined(separator: " and ") + "."
                        }.accessibilityIdentifier("sync-import-env")
                        if !sync.savedSecretNames.isEmpty {
                            Button("Remove saved keys") {
                                SyncSecrets.names.forEach { sync.setSecret($0, value: "") }
                                keysNotice = "Removed from the synced document."
                            }
                        }
                    }
                    if let keysNotice { Text(keysNotice).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func displayName(_ name: String) -> String {
        switch name {
        case "OPENROUTER_API_KEY": return "OpenRouter"
        case "OPENAI_ROTA_KEY": return "OpenAI"
        default: return name
        }
    }

    // MARK: Shared pieces

    private var statusLine: some View {
        Label(sync.syncStatus, systemImage: sync.error == nil ? "checkmark.circle" : "exclamationmark.circle")
            .font(.title3.weight(.medium)).accessibilityIdentifier("sync-status")
            .fixedSize(horizontal: false, vertical: true)
    }
    private var syncNowButton: some View {
        Button { Task { await sync.syncNowPressed() } } label: {
            if sync.manualSyncing { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Syncing…") } }
            else { Text("Sync now") }
        }.accessibilityIdentifier("sync-now").disabled(sync.manualSyncing)
    }
    @ViewBuilder private var conflict: some View {
        if let notice = sync.conflictNotice {
            Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var errorLine: some View {
        if let error = sync.error {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sync-error")
        }
    }
    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change password").font(.headline)
            SecureField("Current password", text: $currentPassword)
            SecureField("New password (12+ characters)", text: $newPassword)
            SecureField("Confirm new password", text: $confirmNewPassword)
            Text("Your settings are re-encrypted with the new password and uploaded. Your other Macs will ask for the new password.").font(.caption)
            HStack {
                Button("Cancel") { changingPassword = false }
                Spacer()
                Button("Change password") {
                    let current = currentPassword, next = newPassword
                    clearPasswords(); changingPassword = false
                    Task { await sync.changePassword(current: current, new: next) }
                }.buttonStyle(.rotaPrimary).disabled(currentPassword.count < 12 || newPassword.count < 12 || newPassword != confirmNewPassword)
            }
        }.padding(24).frame(width: 420)
    }
    private func clearPasswords() { currentPassword = ""; newPassword = ""; confirmNewPassword = "" }
}

/// The one cloud-or-local chooser. The Sync pane shows it until a mode is
/// chosen; the welcome tour embeds the same view so the choice is made once,
/// through one code path (`SettingsSync.choose`).
struct SyncModeChooser: View {
    @ObservedObject var sync: SettingsSync

    var body: some View {
        RotaCard("Where should your settings live?", systemImage: "arrow.triangle.2.circlepath",
                 subtitle: "Pick one. You can switch later; nothing is copied anywhere until you choose.") {
            HStack(alignment: .top, spacing: RotaTokens.Space.l) {
                modeOption(.cloud, symbol: "icloud", title: "Cloud sync",
                    detail: "Encrypted with your password before it leaves this Mac, synced to your other Macs automatically. Your API keys travel with it. The last Mac to edit wins.")
                    .accessibilityIdentifier("sync-choose-cloud")
                modeOption(.local, symbol: "folder", title: "Local file",
                    detail: "A settings.yaml in a folder you control. Commit it to git, edit it by hand, or share the folder yourself. API keys stay in ~/.env and never enter the file.")
                    .accessibilityIdentifier("sync-choose-local")
            }
        }
    }

    private func modeOption(_ mode: SyncMode, symbol: String, title: String, detail: String) -> some View {
        let chosen = sync.mode == mode
        return Button { sync.choose(mode) } label: {
            VStack(alignment: .leading, spacing: RotaTokens.Space.m) {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Label(chosen ? "Chosen" : "Choose " + title, systemImage: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(RotaTokens.accent)
            }
            .padding(RotaTokens.Space.l)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous).fill(RotaTokens.paneFill))
            .overlay(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous)
                .strokeBorder(chosen ? RotaTokens.accent.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: chosen ? 1.5 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
