import AppKit
import Combine
import Foundation

private final class SyncRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a session token to a redirect destination.
    }
}
struct CloudSettings: Codable {
    var yaml: String?
    var revision: Int
    var updatedAt: Double?
    // Optional YAML comment keeps provenance compatible with older servers/apps.
    private static let computerPrefix = "# rotagivan-saved-by-v1: "
    static func uploadYAML(_ yaml: String, computer: String) -> String {
        let name = String(computer.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined().prefix(256))
        return computerPrefix + Data(name.utf8).base64EncodedString() + "\n" + yaml
    }
    var savedByComputer: String? {
        guard let yaml else { return nil }
        let header = String(yaml.prefix(1500).prefix { $0 != "\n" })
        guard header.hasPrefix(Self.computerPrefix),
              let data = Data(base64Encoded: String(header.dropFirst(Self.computerPrefix.count))),
              let name = String(data: data, encoding: .utf8), !name.isEmpty, name.count <= 256,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}

struct CloudLoadPreview {
    let accountID: String
    let revision: Int
    let savedAt: Date?
    let computer: String?
    var confirmationMessage: String {
        let timestamp = savedAt?.formatted(date: .complete, time: .standard) ?? "Unknown save time"
        return "Saved: \(timestamp)\nComputer: \(computer ?? "Unknown computer (older save)")\n\nThis replaces this Mac’s current settings. A backup will be kept."
    }
}

private struct SyncAPIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// Injectable credentials/transport keep sync tests away from real accounts.
struct SyncCredentials {
    var read: (String) async throws -> SyncAccount?
    var save: (SyncAccount, String) async throws -> Void
    var remove: (String) async throws -> Void
    var unlock: ((String) async throws -> SyncAccount?)? = nil
    static var keychain: Self {
        Self(read: { server in try await CredentialWorker.shared.run { try SyncKeychain.read(server: server) } },
             save: { account, server in try await CredentialWorker.shared.run { try SyncKeychain.save(account, server: server) } },
             remove: { server in try await CredentialWorker.shared.run { try SyncKeychain.remove(server: server) } },
             unlock: { server in try await CredentialWorker.shared.run { try SyncKeychain.read(server: server, allowInteraction: true) } })
    }
}

@MainActor final class SettingsSync: ObservableObject {
    @Published private(set) var account: SyncAccount? {
        didSet { vault.setAccount(account.map { VaultAccount(token: $0.token, userID: $0.userID) }) }
    }
    private let suppliedVault: CredentialVault?
    lazy var vault = suppliedVault ?? CredentialVault(server: server)
    @Published private(set) var restoringLogin = false
    @Published private(set) var credentialsReady = false
    @Published private(set) var lastSave: Date?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    var localURL: URL { files.file }
    private let store: SettingsStore
    private let hid: NavigatorHIDManager
    private let files: SyncFiles
    private let defaults: UserDefaults
    private let credentials: SyncCredentials
    private let server: String
    private let session: URLSession
    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private let snapshot: () -> AppConfiguration
    private let computerName: () -> String
    private let applyOverride: ((AppConfiguration) -> Void)?
    private var started = false
    private var shuttingDown = false
    private var generation = UUID()
    private var restoreTask: Task<Void, Never>?

    init(store: SettingsStore, hid: NavigatorHIDManager, files: SyncFiles = SyncFiles(),
         defaults: UserDefaults = .standard, server: String? = nil,
         credentials: SyncCredentials = .keychain,
         vault: CredentialVault? = nil,
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         snapshot: (() -> AppConfiguration)? = nil, apply: ((AppConfiguration) -> Void)? = nil,
         computerName: @escaping () -> String = { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }) {
        self.store = store; self.hid = hid; self.files = files
        self.defaults = defaults; self.credentials = credentials
        suppliedVault = vault
        self.server = server ?? Bundle.main.object(forInfoDictionaryKey: "RotagivanSyncURL") as? String ?? ""
        let session = URLSession(configuration: .ephemeral, delegate: SyncRedirectBlocker(), delegateQueue: nil)
        self.session = session
        self.transport = transport ?? { try await session.data(for: $0) }
        self.snapshot = snapshot ?? { AppConfiguration(store: store) }
        applyOverride = apply
        self.computerName = computerName
    }

    /// Startup restores only the login and cached timestamp. No settings file
    /// imports, exports, observers, timers, polling, or network checks.
    func start() {
        guard !started, !shuttingDown else { return }; started = true
        restoreLogin()
    }
    func retryLoginRestore() {
        guard started, !shuttingDown, !restoringLogin, !credentialsReady else { return }
        restoreLogin(interactive: true)
    }
    func awaitLoginRestore() async {
        await restoreTask?.value
    }
    private func restoreLogin(interactive: Bool = false) {
        generation = UUID()
        let token = generation
        restoringLogin = true; credentialsReady = false; error = nil
        let read = interactive ? (credentials.unlock ?? credentials.read) : credentials.read, server = server
        restoreTask = Task { [weak self] in
            do {
                let restored = try await read(server)
                guard let self, self.isCurrent(token) else { return }
                self.account = restored; self.restoreLastSave()
                self.credentialsReady = true; self.restoringLogin = false
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.restoringLogin = false; self.error = error.localizedDescription
            }
        }
    }
    private func isCurrent(_ token: UUID) -> Bool {
        !shuttingDown && generation == token && !Task.isCancelled
    }
    private func beginOperation() -> UUID? {
        guard credentialsReady, !busy, !shuttingDown, !Task.isCancelled else { return nil }
        generation = UUID(); busy = true; error = nil
        return generation
    }
    private func finishOperation(_ token: UUID) {
        if !shuttingDown && generation == token { busy = false }
    }

    private func saveKey(for account: SyncAccount?) -> String {
        "sync.lastSave." + (account.map { server + "/" + $0.userID } ?? "local")
    }
    private func restoreLastSave() {
        lastSave = defaults.object(forKey: saveKey(for: account)) as? Date
    }
    private func rememberSave(_ date: Date?, for savedAccount: SyncAccount?) {
        let key = saveKey(for: savedAccount)
        if let date { defaults.set(date, forKey: key) }
        else { defaults.removeObject(forKey: key) }
        if account?.userID == savedAccount?.userID { lastSave = date }
    }

    /// An explicit Save captures exactly this moment. Later edits stay local
    /// until the next button press; an error never schedules a retry.
    func save() async {
        guard let token = beginOperation() else { return }
        defer { finishOperation(token) }
        var savedLocally = false
        let signed = account
        do {
            let captured = snapshot()
            _ = try await files.save(captured, expectedDigest: nil, force: true)
            guard isCurrent(token) else { return }
            savedLocally = true
            rememberSave(Date(), for: nil)
            guard isCurrent(token) else { return }
            if let signed {
                let remote: CloudSettings = try await request("settings", method: "GET", token: signed.token)
                guard isCurrent(token) else { return }
                // Save deliberately replaces the remote version, but keeps a
                // recoverable copy and uses CAS to reject a concurrent writer.
                if let yaml = remote.yaml { try await files.backup(AppConfiguration.parse(yaml)) }
                guard isCurrent(token) else { return }
                let result: CloudSettings = try await request("settings", method: "PUT",
                    payload: ["yaml": CloudSettings.uploadYAML(try captured.yaml(), computer: computerName()),
                              "baseRevision": remote.revision], token: signed.token)
                guard isCurrent(token) else { return }
                rememberSave(result.updatedAt.map { Date(timeIntervalSince1970: $0) } ?? Date(), for: signed)
            }
        } catch {
            await handle(error, token: token, signed: signed, localSaveOnly: savedLocally && signed != nil)
        }
    }

    /// Fetch only after the user presses Load; preview never applies or saves.
    func prepareCloudLoad() async -> CloudLoadPreview? {
        guard let signed = account, let token = beginOperation() else { return nil }
        defer { finishOperation(token) }
        do {
            let remote: CloudSettings = try await request("settings", method: "GET", token: signed.token)
            guard isCurrent(token) else { return nil }
            guard let yaml = remote.yaml else {
                throw ConfigurationError("No saved cloud settings. Press Save on the Mac you want to copy first.")
            }
            _ = try AppConfiguration.parse(yaml)
            return CloudLoadPreview(accountID: signed.userID, revision: remote.revision,
                savedAt: remote.updatedAt.map { Date(timeIntervalSince1970: $0) },
                computer: remote.savedByComputer)
        } catch { await handle(error, token: token, signed: signed); return nil }
    }

    /// Load never uploads, and never silently replaces edits made while the
    /// read/request or backup was in flight. The previous app state is backed up.
    func load(expectedCloudSave: CloudLoadPreview? = nil) async {
        guard let token = beginOperation() else { return }
        let signed = account
        defer { finishOperation(token) }
        do {
            if let expectedCloudSave, expectedCloudSave.accountID != account?.userID {
                throw ConfigurationError("The sync account changed. Press Load again to review its saved settings.")
            }
            let before = snapshot()

            let fingerprint = try before.syncFingerprint()
            let config: AppConfiguration
            let savedAt: Date?
            if let signed {
                let remote: CloudSettings = try await request("settings", method: "GET", token: signed.token)
                guard isCurrent(token) else { return }
                if let expectedCloudSave, expectedCloudSave.revision != remote.revision {
                    throw ConfigurationError("The cloud save changed after you opened the confirmation. Nothing was loaded. Press Load again to review the new save.")
                }
                guard let yaml = remote.yaml else { throw ConfigurationError("No saved cloud settings. Press Save on the Mac you want to copy first.") }
                config = try AppConfiguration.parse(yaml)
                savedAt = remote.updatedAt.map { Date(timeIntervalSince1970: $0) }
            } else {
                guard let (local, _) = try await files.read() else { throw ConfigurationError("No settings.yaml found. Press Save to create it.") }
                guard isCurrent(token) else { return }
                config = local
                savedAt = try await files.modificationDate()
            }
            guard isCurrent(token) else { return }
            try config.validate()
            try ensureUnchanged(fingerprint)
            if try fingerprint != config.syncFingerprint() { try await files.backup(before) }
            guard isCurrent(token) else { return }
            try ensureUnchanged(fingerprint)
            apply(config)
            rememberSave(savedAt, for: account)
        } catch { await handle(error, token: token, signed: signed) }
    }

    private func ensureUnchanged(_ fingerprint: String) throws {
        guard try snapshot().syncFingerprint() == fingerprint else {
            throw ConfigurationError("Settings changed while loading. Your newer edits were kept. Press Load again when ready.")
        }
    }
    private func apply(_ config: AppConfiguration) {
        if let applyOverride { applyOverride(config); return }
        var portable = config.settings
        portable.enabled = store.settings.enabled
        portable.launchAtLogin = store.settings.launchAtLogin
        NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)
        hid.stop()
        store.replaceSettings(portable)
        let keys = config.shortcuts
        ShortcutSettings.shared.replaceConfiguration(normal: keys.normal, precision: keys.precision,
            actions: keys.actions, additional: keys.additional, profileActions: keys.profileActions,
            holdToActivate: keys.holdToActivate, dragShortcut: keys.dragShortcut,
            defaultID: store.defaultProfileID)
        store.replaceLibrary(config.profiles, activeID: config.activeConfigurationID, shortcuts: keys)
        AppConfiguration.markCurrent(defaults)
        NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
        if store.settings.enabled { hid.start() }
    }

    func authenticate(email: String, password: String, create: Bool) async {
        guard let token = beginOperation() else { return }
        defer { finishOperation(token) }
        do {
            let signed: SyncAccount = try await request(create ? "register" : "login", method: "POST",
                payload: ["email": email, "password": password], token: nil)
            guard isCurrent(token) else { return }
            try await credentials.save(signed, server)
            guard isCurrent(token) else { return }
            account = signed
            restoreLastSave()
            // Signing in is not permission to transfer any settings.
        } catch { await handle(error, token: token, signed: nil) }
    }
    func signOut() async {
        guard let signed = account, let token = beginOperation() else { return }
        defer { finishOperation(token) }
        var revoked = true
        do { let _: [String: Bool] = try await request("logout", method: "POST", payload: [:], token: signed.token) }
        catch { revoked = false }
        guard isCurrent(token), account == signed else { return }
        do {
            try await credentials.remove(server)
            guard isCurrent(token), account == signed else { return }
            account = nil; restoreLastSave()
            error = revoked ? nil : "Signed out locally. The server could not confirm revocation; that session expires within 30 days."
        } catch { if isCurrent(token) { self.error = error.localizedDescription } }
    }
    func changePassword(current: String, new: String) async {
        guard let signed = account, let token = beginOperation() else { return }
        defer { finishOperation(token) }
        do {
            let replacement: SyncAccount = try await request("password", method: "POST",
                payload: ["currentPassword": current, "newPassword": new], token: signed.token)
            guard isCurrent(token), account == signed else { return }
            try await credentials.save(replacement, server)
            guard isCurrent(token), account == signed else { return }
            account = replacement; restoreLastSave()
        } catch { await handle(error, token: token, signed: signed) }
    }
    private func handle(_ failure: Error, token: UUID, signed: SyncAccount?, localSaveOnly: Bool = false) async {
        guard isCurrent(token) else { return }
        var message = failure.localizedDescription
        if let api = failure as? SyncAPIError {
            if api.status == 409 { message = "Another Mac saved during this request. Nothing was overwritten in the cloud. Press Save again to retry, or Load to use its copy." }
            if api.status == 401 {
                guard let signed, account == signed else {
                    self.error = message
                    return
                }
                var cleanupFailure: String?
                do { try await credentials.remove(server) }
                catch { cleanupFailure = error.localizedDescription }
                guard isCurrent(token), account == signed else { return }
                account = nil; restoreLastSave()
                message = "Your session expired. Sign in again, then press Save or Load."
                if let cleanupFailure { message += " The saved login could not be removed: " + cleanupFailure }
            }
        }
        error = (localSaveOnly ? "Saved to settings.yaml, but not to the cloud. " : "") + message
    }

    func prepareToQuit() async {
        shuttingDown = true
        generation = UUID()
        restoreTask?.cancel(); restoreTask = nil
        restoringLogin = false; credentialsReady = false; busy = false
        vault.shutdown()
        session.invalidateAndCancel()
        // No final save, upload, or import on quit.
    }
    private func request<T: Decodable>(_ path: String, method: String,
                                      payload: [String: Any]? = nil, token: String?) async throws -> T {
        guard let base = URL(string: server), base.scheme == "https", base.host != nil else {
            throw ConfigurationError("This build has no configured HTTPS sync server.")
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/" + path))
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse, data.count <= 2_097_152 else { throw ConfigurationError("Invalid sync response.") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Sync request failed (\(response.statusCode))."
            throw SyncAPIError(status: response.statusCode, message: detail)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
