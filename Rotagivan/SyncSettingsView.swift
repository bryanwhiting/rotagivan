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
    @State private var confirmingResync = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RotaCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Account & Sync", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                        Spacer()
                        if let account = sync.account {
                            RotaMenuButton("Account", systemImage: "person.crop.circle", kind: .field) {
                                Text(account.email)
                                Button("Change password…") { changingPassword = true }
                                Button("Sign out") { Task { await sync.signOut() } }
                            }.disabled(sync.busy)
                        }
                    }
                    if !sync.credentialsReady {
                        Text(sync.restoringLogin ? "Restoring your account…" : "Unlock your saved account to resume sync.")
                        if !sync.restoringLogin {
                            Button("Unlock account") { sync.retryLoginRestore() }
                                .accessibilityIdentifier("sync-restore-retry")
                        }
                    } else if sync.account != nil {
                        Label(sync.syncStatus, systemImage: sync.error == nil ? "checkmark.icloud" : "icloud.slash")
                            .font(.title3.weight(.medium)).accessibilityIdentifier("sync-status")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Your settings and API keys sync automatically across your trusted Macs. Everything is encrypted before it leaves this Mac; edits here reach your other Mac within about a minute.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if let date = sync.lastChecked ?? sync.lastSave {
                                Text("Last checked " + date.formatted(date: .omitted, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Download latest") { NSWorkspace.shared.open(URL(string: "https://rota.silvermine.dev/download/latest")!) }
                                .help("Download the newest Rotagivan release from rota.silvermine.dev")
                                .accessibilityIdentifier("sync-download-latest")
                            Button("Sync now") { Task { await sync.save() } }
                                .accessibilityIdentifier("sync-save").disabled(sync.busy)
                        }
                        if let notice = sync.conflictNotice {
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        let enrollment = VaultEnrollmentView(vault: sync.vault)
                        if enrollment.needsApproval || (sync.vault.unlocked && !sync.vault.pending.isEmpty) {
                            Divider()
                            enrollment.accessibilityIdentifier("sync-enrollment")
                        }
                    } else {
                        Text("Sign in to keep settings and API keys in sync on your Macs.").foregroundStyle(.secondary)
                        TextField("Email", text: $email).textContentType(.username)
                        SecureField("Password", text: $password).textContentType(creating ? .newPassword : .password)
                        if creating { SecureField("Confirm password", text: $confirmation) }
                        HStack {
                            Button(creating ? "Create account" : "Sign in") {
                                let submitted = password; password = ""; confirmation = ""
                                Task {
                                    await sync.authenticate(email: email, password: submitted, create: creating)
                                    await sync.synchronizeAutomatically(trigger: .manual)
                                }
                            }.buttonStyle(.rotaPrimary)
                                .disabled(sync.busy || email.isEmpty || password.count < 12 || (creating && confirmation != password))
                            Button(creating ? "I already have an account" : "Create an account") { creating.toggle() }
                        }
                        Text("Use at least 12 characters. Keep your password in a password manager; email password reset is not available yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = sync.error {
                        Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    RotaDisclosureSection("Privacy & recovery") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Settings are encrypted in local storage and in the cloud. Your account password alone cannot decrypt them; only Macs you approve (or your recovery code) hold the key.")
                            Text("On a new Mac, sign in: it shows a code to approve from a trusted Mac. Keep the recovery code from the API keys card in your password manager.")
                            Text("Usage history, permissions, and device-only options stay on this Mac. Files you explicitly export are readable; keep them private.")
                            if sync.account != nil, sync.credentialsReady, sync.vault.unlocked {
                                Button("Re-sync from cloud…") { confirmingResync = true }
                                    .accessibilityIdentifier("sync-resync")
                                    .disabled(sync.busy)
                                    .confirmationDialog("Replace this Mac’s sync state with the cloud copy?", isPresented: $confirmingResync, titleVisibility: .visible) {
                                        Button("Re-sync from cloud", role: .destructive) { Task { await sync.resyncFromCloud() } }
                                        Button("Cancel", role: .cancel) {}
                                    } message: {
                                        Text("Use this if sync is stuck. Settings that only exist on this Mac are replaced by the cloud copy; an encrypted backup of this Mac’s current settings is kept first.")
                                    }
                            }
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if sync.credentialsReady, sync.account != nil {
                CredentialVaultView(vault: sync.vault, onUnlocked: {
                    Task { await sync.synchronizeAutomatically(trigger: .manual) }
                }).accessibilityIdentifier("sync-separate-vault")
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { Task { await sync.synchronizeAutomatically(trigger: .manual) } }
        .sheet(isPresented: $changingPassword, onDismiss: clearPasswords) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Change password").font(.headline)
                SecureField("Current password", text: $currentPassword)
                SecureField("New password (12+ characters)", text: $newPassword)
                SecureField("Confirm new password", text: $confirmNewPassword)
                Text("Your other Macs will need to sign in again.").font(.caption)
                HStack {
                    Button("Cancel") { changingPassword = false }
                    Spacer()
                    Button("Change password") {
                        let current = currentPassword, next = newPassword
                        clearPasswords(); changingPassword = false
                        Task { await sync.changePassword(current: current, new: next) }
                    }.buttonStyle(.rotaPrimary).disabled(currentPassword.isEmpty || newPassword.count < 12 || newPassword != confirmNewPassword)
                }
            }.padding(24).frame(width: 400)
        }
    }
    private func clearPasswords() { currentPassword = ""; newPassword = ""; confirmNewPassword = "" }
}
