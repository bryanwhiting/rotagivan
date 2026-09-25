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
}
private struct SyncAPIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// Injectable credentials/transport keep sync tests away from real accounts.
struct SyncCredentials {
    var read: (String) throws -> SyncAccount?
    var save: (SyncAccount, String) throws -> Void
    var remove: (String) throws -> Void
    static var keychain: Self {
        Self(read: { try SyncKeychain.read(server: $0) },
             save: { try SyncKeychain.save($0, server: $1) },
             remove: { try SyncKeychain.remove(server: $0) })
    }
}

@MainActor final class SettingsSync: ObservableObject {
    @Published private(set) var account: SyncAccount?
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
    private let applyOverride: ((AppConfiguration) -> Void)?
    private var started = false
    private var shuttingDown = false

    init(store: SettingsStore, hid: NavigatorHIDManager, files: SyncFiles = SyncFiles(),
         defaults: UserDefaults = .standard, server: String? = nil,
         credentials: SyncCredentials = .keychain,
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         snapshot: (() -> AppConfiguration)? = nil, apply: ((AppConfiguration) -> Void)? = nil) {
        self.store = store; self.hid = hid; self.files = files
        self.defaults = defaults; self.credentials = credentials
        self.server = server ?? Bundle.main.object(forInfoDictionaryKey: "RotagivanSyncURL") as? String ?? ""
        let session = URLSession(configuration: .ephemeral, delegate: SyncRedirectBlocker(), delegateQueue: nil)
        self.session = session
        self.transport = transport ?? { try await session.data(for: $0) }
        self.snapshot = snapshot ?? { AppConfiguration(store: store) }
        applyOverride = apply
    }

    /// Startup restores only the login and cached timestamp. No settings file
    /// imports, exports, observers, timers, polling, or network checks.
    func start() {
        guard !started else { return }; started = true
        do { account = try credentials.read(server); restoreLastSave() }
        catch { self.error = error.localizedDescription }
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
        guard !busy, !shuttingDown else { return }
        busy = true; error = nil
        defer { busy = false }
        var savedLocally = false
        let signed = account
        do {
            let captured = snapshot()
            _ = try await files.save(captured, expectedDigest: nil, force: true)
            savedLocally = true
            rememberSave(Date(), for: nil)
            guard !shuttingDown else { return }
            if let signed {
                let remote: CloudSettings = try await request("settings", method: "GET", token: signed.token)
                guard !shuttingDown else { return }
                // Save deliberately replaces the remote version, but keeps a
                // recoverable copy and uses CAS to reject a concurrent writer.
                if let yaml = remote.yaml { try await files.backup(AppConfiguration.parse(yaml)) }
                guard !shuttingDown else { return }
                let result: CloudSettings = try await request("settings", method: "PUT",
                    payload: ["yaml": try captured.yaml(), "baseRevision": remote.revision], token: signed.token)
                guard !shuttingDown else { return }
                rememberSave(result.updatedAt.map { Date(timeIntervalSince1970: $0) } ?? Date(), for: signed)
            }
        } catch {
            handle(error, localSaveOnly: savedLocally && signed != nil)
        }
    }

    /// Load never uploads, and never silently replaces edits made while the
    /// read/request or backup was in flight. The previous app state is backed up.
    func load() async {
        guard !busy, !shuttingDown else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let before = snapshot()
            let fingerprint = try before.syncFingerprint()
            let config: AppConfiguration
            let savedAt: Date?
            if let signed = account {
                let remote: CloudSettings = try await request("settings", method: "GET", token: signed.token)
                guard let yaml = remote.yaml else { throw ConfigurationError("No saved cloud settings. Press Save on the Mac you want to copy first.") }
                config = try AppConfiguration.parse(yaml)
                savedAt = remote.updatedAt.map { Date(timeIntervalSince1970: $0) }
            } else {
                guard let (local, _) = try await files.read() else { throw ConfigurationError("No settings.yaml found. Press Save to create it.") }
                config = local
                savedAt = try await files.modificationDate()
            }
            guard !shuttingDown else { return }
            try config.validate()
            try ensureUnchanged(fingerprint)
            if try fingerprint != config.syncFingerprint() { try await files.backup(before) }
            guard !shuttingDown else { return }
            try ensureUnchanged(fingerprint)
            apply(config)
            rememberSave(savedAt, for: account)
        } catch { handle(error) }
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
        guard !busy, !shuttingDown else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let signed: SyncAccount = try await request(create ? "register" : "login", method: "POST",
                payload: ["email": email, "password": password], token: nil)
            guard !shuttingDown else { return }
            try credentials.save(signed, server)
            account = signed
            restoreLastSave()
            // Signing in is not permission to transfer any settings.
        } catch { handle(error) }
    }
    func signOut() async {
        guard !busy, !shuttingDown, let signed = account else { return }
        busy = true; defer { busy = false }
        var revoked = true
        do { let _: [String: Bool] = try await request("logout", method: "POST", payload: [:], token: signed.token) }
        catch { revoked = false }
        do {
            try credentials.remove(server)
            account = nil; restoreLastSave()
            error = revoked ? nil : "Signed out locally. The server could not confirm revocation; that session expires within 30 days."
        } catch { self.error = error.localizedDescription }
    }
    func changePassword(current: String, new: String) async {
        guard !busy, !shuttingDown, let signed = account else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let replacement: SyncAccount = try await request("password", method: "POST",
                payload: ["currentPassword": current, "newPassword": new], token: signed.token)
            guard !shuttingDown else { return }
            try credentials.save(replacement, server); account = replacement; restoreLastSave()
        } catch { handle(error) }
    }
    private func handle(_ failure: Error, localSaveOnly: Bool = false) {
        var message = failure.localizedDescription
        if let api = failure as? SyncAPIError {
            if api.status == 409 { message = "Another Mac saved during this request. Nothing was overwritten in the cloud. Press Save again to retry, or Load to use its copy." }
            if api.status == 401 {
                try? credentials.remove(server)
                account = nil; restoreLastSave()
                message = "Your session expired. Sign in again, then press Save or Load."
            }
        }
        error = (localSaveOnly ? "Saved to settings.yaml, but not to the cloud. " : "") + message
    }

    func prepareToQuit() async {
        shuttingDown = true
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
