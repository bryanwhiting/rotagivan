import SwiftUI

struct CredentialVaultView: View {
    @ObservedObject var vault: CredentialVault
    @State private var apiKey = ""
    @State private var recoveryInput = ""
    @State private var recoveryOpen = false
    @State private var approval: VaultDevice?
    @State private var approvalCode = ""
    @State private var showRecovery = false
    private var unavailable: Bool { vault.busy || !vault.localReady || vault.restoringLocal || vault.account == nil }
    private var recoveryUnavailable: Bool { vault.busy || vault.restoringLocal || vault.account == nil }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Encrypted API keys", systemImage: "lock.shield").font(.headline)
                    Spacer()
                    if vault.busy || vault.restoringLocal { ProgressView().controlSize(.small).accessibilityLabel("Restoring or updating encrypted keys") }
                }
                HStack {
                    Text("OpenRouter")
                    Spacer()
                    Text(!vault.localReady ? "Unavailable" : (vault.hasRemote || vault.hasKey ? "••••••••" : "Not saved")).monospaced()
                }
                Label(vault.status, systemImage: vault.unlocked ? "lock.shield.fill" : "lock")
                    .font(.caption).foregroundStyle(vault.unlocked ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = vault.savedAt {
                    Text("Last encrypted save: " + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                SecureField("New OpenRouter key (optional)", text: $apiKey).textContentType(.password)
                    .disabled(unavailable)
                if vault.account != nil && !vault.localReady && !vault.restoringLocal {
                    Button("Retry local key restore") { vault.retryLocalRestore() }
                        .accessibilityIdentifier("vault-restore-retry")
                }
                HStack {
                    Button("Save encrypted key") {
                        let key = apiKey; apiKey = ""
                        Task { await vault.save(apiKey: key.isEmpty ? nil : key) }
                    }
                    Button("Import ~/.env and save") { Task { await vault.save(importEnvironment: true) } }
                    Button("Load / refresh") { Task { await vault.load() } }
                }.disabled(unavailable)
                if !vault.unlocked {
                    HStack {
                        Button("Request access on this Mac") { Task { await vault.requestAccess() } }.disabled(unavailable)
                        Button("Use recovery code…") { recoveryOpen = true }
                            .disabled(recoveryUnavailable)
                    }
                }
                if let code = vault.ownCode {
                    Text("This Mac’s verification code").font(.caption)
                    Text(code).monospaced().textSelection(.enabled)
                    Text("On a trusted Mac, refresh this section, select this request, and enter the code shown HERE. Then press Load here. Never approve a code supplied only by the server or an unexpected request.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if vault.unlocked {
                    Button("Show recovery code…") { vault.showRecoveryCode(); showRecovery = vault.recoveryCode != nil }
                        .disabled(unavailable)
                    ForEach(vault.pending) { device in
                        HStack {
                            Label(device.name, systemImage: "laptopcomputer")
                            Spacer()
                            Button("Approve…") { approvalCode = ""; approval = device }
                        }.disabled(unavailable)
                    }
                }
                Text("API keys are encrypted before upload and decrypted only on trusted Macs. Private keys stay in this Mac’s Keychain—not iCloud. Settings YAML and backups never contain API keys. Ordinary settings are not end-to-end encrypted.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = vault.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }.padding(6)
        }
        .onDisappear { apiKey = ""; recoveryInput = ""; approvalCode = ""; vault.recoveryCode = nil }
        .onChange(of: vault.account) { _ in
            apiKey = ""; recoveryInput = ""; approvalCode = ""
            approval = nil; recoveryOpen = false; showRecovery = false
        }
        .sheet(item: $approval) { device in
            VStack(alignment: .leading, spacing: 14) {
                Text("Approve \(device.name)?").font(.headline)
                Text("Enter the verification code displayed in Rotagivan on the other Mac. Compare it directly with that screen—not a code sent in an unexpected message. Approval grants access to all API keys in this vault.")
                    .fixedSize(horizontal: false, vertical: true)
                TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $approvalCode).monospaced()
                HStack {
                    Button("Cancel") { approvalCode = ""; approval = nil }
                    Spacer()
                    Button("Approve trusted Mac") {
                        let code = approvalCode; approvalCode = ""; approval = nil
                        Task { await vault.approve(device, verificationCode: code) }
                    }.disabled(unavailable || approvalCode.filter { $0.isHexDigit }.count != 24)
                }
            }.padding(24).frame(width: 440)
        }
        .sheet(isPresented: $recoveryOpen) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Recover this vault").font(.headline)
                SecureField("RV1-…", text: $recoveryInput).monospaced()
                Text("The recovery code is decrypted locally and is never sent to the server.").font(.caption)
                if !vault.localReady {
                    Text("Successful recovery replaces the unavailable local vault keys in this Mac’s Keychain. Saving may still require Keychain access.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { recoveryInput = ""; recoveryOpen = false }
                    Spacer()
                    Button("Unlock this Mac") {
                        let code = recoveryInput; recoveryInput = ""; recoveryOpen = false
                        Task { await vault.recover(code) }
                    }.disabled(recoveryUnavailable || recoveryInput.isEmpty)
                }
            }.padding(24).frame(width: 440)
        }
        .sheet(isPresented: $showRecovery, onDismiss: { vault.recoveryCode = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Keep this recovery code private").font(.headline)
                Text("Save it in your password manager. With your account login, this code unlocks the vault if all trusted Macs are lost. Rotagivan cannot recover it from the server.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(vault.recoveryCode ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .privacySensitive().fixedSize(horizontal: false, vertical: true)
                Text("Changing your login password does not change this code or revoke a Mac that already has the vault key.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done") { vault.recoveryCode = nil; showRecovery = false }
            }.padding(24).frame(width: 470)
        }
    }
}
