import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject var sync: SettingsSync
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var creating = false
    @State private var changingPassword = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmNewPassword = ""
    @State private var confirmLoad = false
    @State private var cloudLoadPreview: CloudLoadPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Account & Sync", systemImage: "icloud").font(.headline)
                Spacer()
                if sync.busy || sync.restoringLogin { ProgressView().controlSize(.small).accessibilityLabel("Restoring or updating account") }
            }
            Text("Save and load only when you choose. Nothing syncs automatically.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("~/.config/rotagivan/settings.yaml").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([sync.localURL]) }
            }
            if !sync.credentialsReady {
                Text(sync.restoringLogin ? "Restoring your saved account…" : "Your saved account is unavailable. Retry before saving or loading settings.")
                    .fixedSize(horizontal: false, vertical: true)
                if !sync.restoringLogin {
                    Button("Retry account restore") { sync.retryLoginRestore() }
                        .accessibilityIdentifier("sync-restore-retry")
                }
            } else if let account = sync.account {
                LabeledContent("Signed in as", value: account.email)
                HStack {
                    Button("Change password…") { changingPassword = true }
                    Button("Sign out") { Task { await sync.signOut() } }
                }.disabled(sync.busy)
            } else {
                TextField("Email", text: $email).textContentType(.username)
                SecureField("Password (12+ characters)", text: $password)
                    .textContentType(creating ? .newPassword : .password)
                if creating { SecureField("Confirm password", text: $confirmPassword).textContentType(.newPassword) }
                HStack {
                    Button(creating ? "Create account" : "Sign in") {
                        let submitted = password
                        password = ""; confirmPassword = ""
                        Task { await sync.authenticate(email: email, password: submitted, create: creating) }
                    }.disabled(sync.busy || email.isEmpty || password.count < 12 || (creating && password != confirmPassword))
                    Button(creating ? "Already have an account?" : "Create an account") {
                        creating.toggle(); password = ""; confirmPassword = ""
                    }.disabled(sync.busy)
                }
                Text("Email is your login name. Verification and password-reset emails aren't available yet; save your password in a password manager. Signing in does not save or load settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Last save", value: sync.lastSave?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save") { Task { await sync.save(); if sync.error == nil && sync.vault.unlocked { await sync.vault.save() } } }
                    .accessibilityIdentifier("sync-save")
                    .help(sync.account == nil ? "Save current app settings to settings.yaml." : "Save current app settings to the cloud and settings.yaml.")
                Button("Load") {
                    guard sync.credentialsReady else { return }
                    cloudLoadPreview = nil
                    if sync.account == nil { confirmLoad = true }
                    else {
                        Task {
                            if let preview = await sync.prepareCloudLoad() {
                                cloudLoadPreview = preview
                                confirmLoad = true
                            }
                        }
                    }
                }
                    .accessibilityIdentifier("sync-load")
                    .help(sync.account == nil ? "Load settings.yaml into this app." : "Load your saved cloud settings into this app.")
            }.disabled(sync.busy || !sync.credentialsReady || sync.restoringLogin)
            Text(!sync.credentialsReady ? "Save and Load remain unavailable until your saved account is restored."
                : sync.account == nil
                ? "Save and Load use settings.yaml on this Mac. Replaced copies are backed up."
                : "Save writes to your cloud account and settings.yaml. Load uses the cloud copy. Replaced copies are backed up.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sync.credentialsReady {
                CredentialVaultView(vault: sync.vault)
            } else {
                Label("Encrypted API keys will appear after your saved account is restored.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync-vault-awaiting-account")
            }
            if let error = sync.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("Passwords and login tokens never go in YAML. Cloud sync doesn't change Accessibility, Input Monitoring, launch-at-login, or this Mac's enable switch.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: sync.credentialsReady) { ready in
            if !ready { confirmLoad = false; cloudLoadPreview = nil; changingPassword = false; clearPasswords() }
        }
        .confirmationDialog(sync.account == nil ? "Load settings.yaml?" : "Load your saved cloud settings?", isPresented: $confirmLoad) {
            Button("Back up current settings and load") {
                guard sync.credentialsReady else { return }
                let preview = cloudLoadPreview
                Task { await sync.load(expectedCloudSave: preview); if sync.error == nil && sync.account != nil { await sync.vault.load() } }
            }
        } message: {
            Text(cloudLoadPreview?.confirmationMessage ?? "This replaces this Mac's current settings. A backup will be kept.")
        }
        .sheet(isPresented: $changingPassword) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Change password").font(.headline)
                SecureField("Current password", text: $currentPassword).textContentType(.password)
                SecureField("New password (12+ characters)", text: $newPassword).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmNewPassword).textContentType(.newPassword)
                Text("This signs out your other Macs. They can sign in again with the new password.").font(.caption)
                HStack {
                    Button("Cancel") { clearPasswords(); changingPassword = false }
                    Spacer()
                    Button("Change password") {
                        let current = currentPassword, next = newPassword
                        clearPasswords(); changingPassword = false
                        Task { await sync.changePassword(current: current, new: next) }
                    }.disabled(currentPassword.isEmpty || newPassword.count < 12 || newPassword != confirmNewPassword)
                }
            }.padding(24).frame(width: 400)
        }
    }
    private func clearPasswords() { currentPassword = ""; newPassword = ""; confirmNewPassword = "" }
}
