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

@MainActor final class SettingsSync: ObservableObject {
    @Published private(set) var account: SyncAccount?
    @Published private(set) var status = "Starting local settings…"
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var hasConflict = false
    @Published private(set) var localConflict = false
    var hasCloudCopy: Bool { conflictRemote?.yaml != nil }
    let localURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rotagivan/settings.yaml")
    private let store: SettingsStore
    private let hid: NavigatorHIDManager
    private let files = SyncFiles()
    private let server: String
    private let session = URLSession(configuration: .ephemeral, delegate: SyncRedirectBlocker(), delegateQueue: nil)
    private var subscriptions = Set<AnyCancellable>()
    private var saveTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var started = false
    private var applying = false
    private var localDigest: String?
    private var localFingerprint: String?
    private var conflictRemote: CloudSettings?
    private var lastCloudCheck = Date.distantPast
    private var generation = UUID()
    private var needsSave = false
    private var shuttingDown = false

    init(store: SettingsStore, hid: NavigatorHIDManager) {
        self.store = store; self.hid = hid
        server = Bundle.main.object(forInfoDictionaryKey: "RotagivanSyncURL") as? String ?? ""
    }
    func start() {
        guard !started else { return }; started = true
        store.$settings.dropFirst().sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
        store.$configurationProfiles.dropFirst().sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
        ShortcutSettings.shared.objectWillChange.sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
        pollingTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Existing YAML is authoritative on startup. Import is validated and backed up.
                if let (config, digest) = try await files.read() {
                    localDigest = digest
                    if UserDefaults.standard.bool(forKey: "sync.localPending") {
                        guard digest == UserDefaults.standard.string(forKey: "sync.localDigest") else {
                            localConflict = true
                            try await files.backupConflict(AppConfiguration(store: store))
                            throw ConfigurationError("Unsaved app changes and a modified YAML file were found. Choose which local copy to keep.")
                        }
                        try await saveLocal()
                    } else {
                        try await adopt(config)
                        UserDefaults.standard.set(digest, forKey: "sync.localDigest")
                    }
                } else { try await saveLocal() }
                account = try SyncKeychain.read(server: server)
                status = account == nil ? "Saved locally • Sign in to sync across Macs" : "Checking cloud…"
                if account != nil { await sync() }
            } catch { self.error = error.localizedDescription }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                await checkLocalFile()
                if account != nil && Date().timeIntervalSince(lastCloudCheck) >= 30 && !hasConflict && !localConflict {
                    await sync()
                }
            }
        }
    }
    private func changed() {
        guard started, !applying, !shuttingDown else { return }
        UserDefaults.standard.set(true, forKey: "sync.localPending")
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            guard !busy else { needsSave = true; return }
            do {
                try await saveLocal()
                if account != nil { await sync() }
            } catch { self.error = error.localizedDescription }
        }
    }
    @discardableResult private func saveLocal(force: Bool = false) async throws -> AppConfiguration {
        let config = AppConfiguration(store: store)
        do {
            localDigest = try await files.save(config, expectedDigest: localDigest, force: force)
            localFingerprint = try config.syncFingerprint()
            UserDefaults.standard.set(localDigest, forKey: "sync.localDigest")
            if try AppConfiguration(store: store).syncFingerprint() == localFingerprint {
                UserDefaults.standard.set(false, forKey: "sync.localPending")
            }
            localConflict = false
            if account == nil { status = "Saved locally • Sign in to sync across Macs" }
            return config
        } catch { localConflict = true; throw error }
    }
    private func checkLocalFile() async {
        guard !busy, !applying, !localConflict else { return }
        do {
            guard let digest = try await files.rawDigest(), digest != localDigest else { return }
            guard try AppConfiguration(store: store).syncFingerprint() == localFingerprint else {
                localConflict = true
                try await files.backupConflict(AppConfiguration(store: store))
                throw ConfigurationError("Both the app and settings.yaml changed. Choose Reload YAML or Save app settings.")
            }
            guard let (config, readDigest) = try await files.read() else { return }
            try await adopt(config)
            localDigest = readDigest
            error = nil
            if account != nil { await sync() }
        } catch { localConflict = true; self.error = error.localizedDescription }
    }
    private func adopt(_ config: AppConfiguration) async throws {
        try config.validate()
        let previous = AppConfiguration(store: store)
        if try previous.syncFingerprint() != config.syncFingerprint() { try await files.backup(previous) }
        guard try previous.syncFingerprint() == AppConfiguration(store: store).syncFingerprint() else {
            throw ConfigurationError("Settings changed while importing. Your newer local changes were kept; retry sync.")
        }
        applying = true
        defer { applying = false }
        var portable = config.settings
        portable.enabled = store.settings.enabled
        portable.launchAtLogin = store.settings.launchAtLogin
        NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)
        hid.stop()
        store.replaceSettings(portable)
        let keys = config.shortcuts
        ShortcutSettings.shared.replaceConfiguration(normal: keys.normal, precision: keys.precision,
            actions: keys.actions, additional: keys.additional, profileActions: keys.profileActions,
            holdToActivate: keys.holdToActivate)
        store.replaceLibrary(config.profiles, activeID: config.activeConfigurationID, shortcuts: keys)
        AppConfiguration.markCurrent(.standard)
        NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
        if store.settings.enabled { hid.start() }
        localFingerprint = try config.syncFingerprint()
    }
    func reloadLocal() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            guard let (config, digest) = try await files.read() else { throw ConfigurationError("settings.yaml was not found.") }
            try await adopt(config)
            localDigest = digest; localConflict = false; error = nil
            UserDefaults.standard.set(digest, forKey: "sync.localDigest")
            UserDefaults.standard.set(false, forKey: "sync.localPending")
        } catch { self.error = error.localizedDescription }
    }
    func overwriteLocal() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await saveLocal(force: true); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func authenticate(email: String, password: String, create: Bool) async {
        guard !busy else { return }; busy = true
        do {
            try await saveLocal()
            let credentials = ["email": email, "password": password]
            let signed: SyncAccount = try await request(create ? "register" : "login", method: "POST", payload: credentials, token: nil)
            try SyncKeychain.save(signed, server: server)
            generation = UUID(); account = signed; hasConflict = false; conflictRemote = nil; error = nil
            busy = false
            await sync(firstLogin: true, allowInitialUpload: create)
        } catch { self.error = error.localizedDescription; busy = false }
    }
    func signOut() async {
        guard !busy, let signed = account else { return }; busy = true
        defer { busy = false }
        var revoked = true
        do { let _: [String: Bool] = try await request("logout", method: "POST", payload: [:], token: signed.token) }
        catch { revoked = false }
        do {
            try SyncKeychain.remove(server: server)
            generation = UUID(); account = nil; hasConflict = false; conflictRemote = nil
            status = "Signed out • Settings remain on this Mac"
            error = revoked ? nil : "The login was removed from this Mac. The server could not confirm revocation; that session expires within 30 days."
        } catch { self.error = error.localizedDescription }
    }
    func changePassword(current: String, new: String) async {
        guard !busy, let signed = account else { return }; busy = true; defer { busy = false }
        do {
            let replacement: SyncAccount = try await request("password", method: "POST",
                payload: ["currentPassword": current, "newPassword": new], token: signed.token)
            try SyncKeychain.save(replacement, server: server); account = replacement
            error = nil; status = "Password changed • Other Macs must sign in again"
        } catch { self.error = error.localizedDescription }
    }
    func sync(firstLogin: Bool = false, resolution: SyncDecision? = nil, allowInitialUpload: Bool = false) async {
        guard !shuttingDown, !busy, !localConflict, let signed = account, (!hasConflict || resolution != nil) else { return }
        busy = true; lastCloudCheck = Date()
        let operation = generation
        defer { busy = false; if needsSave { needsSave = false; changed() } }
        do {
            // Upload exactly the snapshot that has reached disk, never a newer
            // UI edit that arrived while the actor was writing the file.
            let captured = try await saveLocal()
            let fingerprint = try captured.syncFingerprint()
            let remote: CloudSettings
            if resolution != nil, let conflictRemote { remote = conflictRemote }
            else { remote = try await request("settings", method: "GET", token: signed.token) }
            guard operation == generation, account?.userID == signed.userID else { return }
            // Don't overwrite changes made while a request was in flight.
            guard try AppConfiguration(store: store).syncFingerprint() == fingerprint else {
                needsSave = true; status = "New local changes queued"; return
            }
            let remoteConfig = try remote.yaml.map(AppConfiguration.parse)
            let remoteFingerprint = try remoteConfig?.syncFingerprint()
            let baseline = try await files.baseline(for: server + "/" + signed.userID)
            let previousOwner = UserDefaults.standard.string(forKey: "sync.localOwner")
            let owner = server + "/" + signed.userID
            let decision = resolution ?? SyncDecision.forAccount(local: fingerprint, remote: remoteFingerprint,
                baseline: baseline?.fingerprint, ownerMatches: previousOwner == owner,
                hasPreviousOwner: previousOwner != nil, firstLogin: firstLogin, allowInitialUpload: allowInitialUpload)
            switch decision {
            case .equal:
                try await remember(remote.revision, fingerprint: fingerprint, account: signed)
            case .conflict:
                try await files.backupConflict(captured)
                conflictRemote = remote; hasConflict = true
                status = remoteConfig == nil
                    ? "This account has no cloud settings. Confirm before uploading the configuration left by another account."
                    : "Settings differ on this Mac and in the cloud. Choose which to keep."
                return
            case .upload:
                if resolution == .upload, let remoteConfig { try await files.backup(remoteConfig) }
                let result: CloudSettings = try await request("settings", method: "PUT",
                    payload: ["yaml": try captured.yaml(), "baseRevision": remote.revision], token: signed.token)
                try await remember(result.revision, fingerprint: fingerprint, account: signed)
            case .download:
                guard let remoteConfig, let remoteFingerprint else { throw ConfigurationError("No cloud configuration is available.") }
                guard try AppConfiguration(store: store).syncFingerprint() == fingerprint else { needsSave = true; return }
                // Persist locally before applying; keep a recoverable copy of the current config.
                try await files.backup(captured)
                guard try AppConfiguration(store: store).syncFingerprint() == fingerprint else { needsSave = true; return }
                localDigest = try await files.save(remoteConfig, expectedDigest: localDigest)
                guard try AppConfiguration(store: store).syncFingerprint() == fingerprint else { needsSave = true; return }
                try await adopt(remoteConfig)
                try await remember(remote.revision, fingerprint: remoteFingerprint, account: signed)
                UserDefaults.standard.set(localDigest, forKey: "sync.localDigest")
                UserDefaults.standard.set(false, forKey: "sync.localPending")
            }
            hasConflict = false; conflictRemote = nil; error = nil
            status = "Synced • \(Date().formatted(date: .omitted, time: .shortened))"
        } catch let api as SyncAPIError where api.status == 409 {
            hasConflict = false; conflictRemote = nil
            status = "Another Mac saved first. Checking again…"
            lastCloudCheck = .distantPast
        } catch let api as SyncAPIError where api.status == 401 {
            try? SyncKeychain.remove(server: server)
            account = nil; generation = UUID(); error = api.localizedDescription
            status = "Saved locally • Sign in again"
        } catch {
            self.error = error.localizedDescription
            status = "Saved locally • Cloud sync will retry"
        }
    }
    private func remember(_ revision: Int, fingerprint: String, account: SyncAccount) async throws {
        try await files.setBaseline(SyncBaseline(revision: revision, fingerprint: fingerprint), for: server + "/" + account.userID)
        UserDefaults.standard.set(server + "/" + account.userID, forKey: "sync.localOwner")
    }
    func prepareToQuit() async {
        shuttingDown = true; generation = UUID()
        saveTask?.cancel(); pollingTask?.cancel(); session.invalidateAndCancel()
        do { try await saveLocal() }
        catch { UserDefaults.standard.set(true, forKey: "sync.localPending") }
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
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 2_097_152 else { throw ConfigurationError("Invalid sync response.") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Sync request failed (\(response.statusCode))."
            throw SyncAPIError(status: response.statusCode, message: detail)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
