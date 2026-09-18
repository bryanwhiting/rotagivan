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
    @State private var overwriteFile = false
    @State private var useCloud = false
    @State private var useLocal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Account & Sync", systemImage: "icloud").font(.headline)
                Spacer()
                if sync.busy { ProgressView().controlSize(.small) }
            }
            Text("Settings save on this Mac first. Sign in on another Mac to sync your profiles and shortcuts.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("~/.config/rotagivan/settings.yaml").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([sync.localURL]) }
            }
            if let account = sync.account {
                LabeledContent("Signed in as", value: account.email)
                HStack {
                    Button("Sync now") { Task { await sync.sync() } }.disabled(sync.hasConflict || sync.localConflict)
                    Button("Change password…") { changingPassword = true }
                    Button("Sign out") { Task { await sync.signOut() } }
                }.disabled(sync.busy)
            } else {
                TextField("Email", text: $email).textContentType(.username)
                SecureField("Password (12+ characters)", text: $password)
                    .textContentType(creating ? .newPassword : .password)
                if creating { SecureField("Confirm password", text: $confirmPassword).textContentType(.newPassword) }
                HStack {
                    Button(creating ? "Create account & sync" : "Sign in") {
                        let submitted = password
                        password = ""; confirmPassword = ""
                        Task { await sync.authenticate(email: email, password: submitted, create: creating) }
                    }.disabled(sync.busy || email.isEmpty || password.count < 12 || (creating && password != confirmPassword))
                    Button(creating ? "Already have an account?" : "Create an account") {
                        creating.toggle(); password = ""; confirmPassword = ""
                    }.disabled(sync.busy)
                }
                Text("Email is your login name. Verification and password-reset emails aren't available yet; save your password in a password manager. First sign-in on a new Mac loads your cloud settings and backs up this Mac's settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(sync.status).font(.caption).foregroundStyle(.secondary)
            if let error = sync.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if sync.hasConflict {
                HStack {
                    Button("Use this Mac's settings…") { useLocal = true }
                    if sync.hasCloudCopy { Button("Use cloud settings…") { useCloud = true } }
                }.disabled(sync.busy)
            }
            HStack {
                Button("Reload YAML") { Task { await sync.reloadLocal() } }
                if sync.localConflict { Button("Save app settings…") { overwriteFile = true } }
            }.disabled(sync.busy)
            Text("Passwords and login tokens never go in YAML. Cloud sync doesn't change Accessibility, Input Monitoring, launch-at-login, or this Mac's enable switch.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
        .confirmationDialog("Replace settings.yaml with this app's settings? The existing file will be backed up.", isPresented: $overwriteFile) {
            Button("Back up file and save app settings") { Task { await sync.overwriteLocal() } }
        }
        .confirmationDialog("Replace this Mac's settings with the cloud copy? Your local configuration will be backed up.", isPresented: $useCloud) {
            Button("Use cloud settings") { Task { await sync.sync(resolution: .download) } }
        }
        .confirmationDialog("Replace the cloud copy with this Mac's settings? Other signed-in Macs will receive this version.", isPresented: $useLocal) {
            Button("Use this Mac's settings") { Task { await sync.sync(resolution: .upload) } }
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
