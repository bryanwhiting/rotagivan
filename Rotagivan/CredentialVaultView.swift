import SwiftUI

struct CredentialVaultView: View {
    @ObservedObject var vault: CredentialVault
    var onUnlocked: (() -> Void)? = nil
    @State private var apiKey = ""
    @State private var openAIKey = ""
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
                    Label("API keys", systemImage: "key").font(.headline)
                    Spacer()
                    if vault.busy || vault.restoringLocal { ProgressView().controlSize(.small).accessibilityLabel("Restoring or updating encrypted keys") }
                }
                HStack {
                    Text("OpenRouter")
                    Spacer()
                    Text(providerStatus(ready: vault.hasKey))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("OpenAI · GPT Live")
                    Spacer()
                    Text(providerStatus(ready: vault.hasOpenAIKey)).font(.caption).foregroundStyle(.secondary)
                }
                Text("OpenAI powers GPT Live. OpenRouter powers Jev action matching. Add a key once and it’s available on your trusted Macs.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if vault.localReady || vault.restoringLocal {
                Label(vault.localReady && !vault.hasKey && !vault.hasOpenAIKey && !vault.hasRemote && vault.account != nil
                      ? "Checking for saved keys…" : vault.unlocked ? "Encrypted · ready on this Mac" : vault.status,
                      systemImage: vault.unlocked ? "lock.shield.fill" : "lock")
                    .font(.caption).foregroundStyle(vault.unlocked ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let date = vault.savedAt {
                    Text("Last encrypted save: " + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if vault.account != nil && !vault.localReady && !vault.restoringLocal {
                    Button("Unlock this Mac") { vault.retryLocalRestore() }
                        .accessibilityIdentifier("vault-restore-retry")
                    Text("This button may ask for your login Keychain password. Once unlocked, voice reuses the keys in memory; it does not request access on each command.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if vault.localReady && vault.account != nil && (vault.unlocked || !vault.hasRemote) {
                SecureField(vault.hasKey ? "Replace OpenRouter API key" : "Paste OpenRouter API key", text: $apiKey).textContentType(.password)
                    .disabled(unavailable)
                    .accessibilityIdentifier("vault-openrouter-key")
                SecureField(vault.hasOpenAIKey ? "Replace OpenAI API key" : "Paste OpenAI API key", text: $openAIKey).textContentType(.password)
                    .disabled(unavailable)
                    .accessibilityIdentifier("vault-openai-key")
                Text("Leave a field blank to keep its saved key. Saving one provider never removes the other.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save keys") {
                        let router = apiKey, openAI = openAIKey
                        Task {
                            let saved = await vault.save(apiKey: router.isEmpty ? nil : router.trimmingCharacters(in: .whitespacesAndNewlines), openAIKey: openAI.isEmpty ? nil : openAI.trimmingCharacters(in: .whitespacesAndNewlines))
                            if saved {
                                if apiKey == router { apiKey = "" }
                                if openAIKey == openAI { openAIKey = "" }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(apiKey.isEmpty && openAIKey.isEmpty)
                    Text("Saved keys download automatically.").font(.caption).foregroundStyle(.secondary)
                }.disabled(unavailable)
                }
                if !vault.unlocked && vault.account != nil && !vault.localReady {
                    HStack {
                        Button("Use recovery code…") { recoveryOpen = true }
                            .disabled(recoveryUnavailable)
                    }
                }
                if vault.localReady && vault.hasRemote && !vault.unlocked {
                    Text("Unlock once to download your settings and saved keys.").font(.subheadline)
                    HStack {
                        Button("Use recovery code…") { recoveryOpen = true }.disabled(recoveryUnavailable)
                        Button("Approve from another Mac…") { Task { await vault.requestAccess() } }.disabled(unavailable)
                    }
                }
                if let code = vault.ownCode {
                    Text("This Mac’s verification code").font(.caption)
                    Text(code).monospaced().textSelection(.enabled)
                    Text("On your trusted Mac, open Account & Sync and approve this Mac using the code above. Sync starts automatically after approval.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if vault.account != nil && vault.localReady {
                  DisclosureGroup("Recovery & advanced") {
                    VStack(alignment: .leading, spacing: 10) {
                    if !vault.unlocked {
                        HStack {
                            Button("Request access on this Mac") { Task { await vault.requestAccess() } }.disabled(unavailable)
                            Button("Use recovery code…") { recoveryOpen = true }.disabled(recoveryUnavailable)
                        }
                    }
                    Button("Import OpenRouter from ~/.env") { Task { await vault.save(importEnvironment: true) } }
                        .disabled(unavailable)
                    Button("Import OpenAI from ~/.env") { Task { await vault.save(importOpenAIEnvironment: true) } }
                        .disabled(unavailable)
                    if vault.unlocked {
                      Button("Show recovery code…") { vault.showRecoveryCode(); showRecovery = vault.recoveryCode != nil }
                        .disabled(unavailable)
                    }
                    }.padding(.top, 8)
                  }.font(.caption)
                }
                if vault.unlocked {
                    ForEach(vault.pending) { device in
                        HStack {
                            Label(device.name, systemImage: "laptopcomputer")
                            Spacer()
                            Button("Approve…") { approvalCode = ""; approval = device }
                        }.disabled(unavailable)
                    }
                }
                Text("Keys are end-to-end encrypted. Saved values are never displayed here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = vault.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { apiKey = ""; openAIKey = ""; recoveryInput = ""; approvalCode = ""; vault.recoveryCode = nil }
        .onChange(of: vault.unlocked) { ready in if ready { onUnlocked?() } }
        .onChange(of: vault.localReady) { ready in if ready { onUnlocked?() } }
        .onChange(of: vault.account) { _ in
            apiKey = ""; openAIKey = ""; recoveryInput = ""; approvalCode = ""
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
    private func providerStatus(ready: Bool) -> String {
        if vault.account == nil { return "Sign in first" }
        if vault.restoringLocal { return "Restoring…" }
        if !vault.localReady { return "Locked on this Mac" }
        if vault.unlocked { return ready ? "Saved · unlocked locally" : "Not saved" }
        return vault.hasRemote ? "Load or unlock to check" : "Not saved"
    }
}
