import AppKit
import Combine
import Foundation
import Network

/// Why a sync cycle runs. Local-change cycles skip the network entirely when
/// no portable setting differs from the last reconciled snapshot.
enum SyncTrigger: Sendable { case launch, localChange, poll, wake, network, manual, activity }
private struct SyncNotModified: Error {}

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
        didSet {
            let old = reconciler
            reconciler = nil; reconciliationAccount = nil; observedFields = nil
            Task { await old?.stop() }
            vault.setAccount(account.map { VaultAccount(token: $0.token, userID: $0.userID) })
        }
    }
    private let suppliedVault: CredentialVault?
    lazy var vault = suppliedVault ?? CredentialVault(server: server)
    @Published private(set) var restoringLogin = false
    @Published private(set) var credentialsReady = false
    @Published private(set) var lastSave: Date?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var syncStatus = "Sign in to sync your settings and API keys."
    /// Set when the last cycle had to discard local edits that conflicted
    /// with another Mac; cleared by the next successful local change.
    @Published private(set) var conflictNotice: String?
    @Published private(set) var lastChecked: Date?
    let automatic: Bool
    /// Idle Macs check the cloud once an hour; using the HUD checks sooner.
    static let pollInterval: UInt64 = 3600
    /// While a cycle keeps failing, retries start here and back off to five minutes.
    static let retryInterval: UInt64 = 30
    /// A HUD or launcher use checks for remote changes at most this often.
    static let activityCheckInterval: TimeInterval = 60
    private static let vaultRefreshInterval: TimeInterval = 300
    private var lastActivityCheck: Date?
    private var autoLoop: Task<Void, Never>?
    private var reconciler: EncryptedAutoSync?
    private var reconciliationAccount: String?
    private var observedFields: [String: Data]?
    private var observedStorageKey: String?
    private var autoRunning = false
    /// True while the user's Sync now press is waiting or running, so the
    /// button can show progress instead of appearing to do nothing.
    @Published private(set) var manualSyncing = false
    private var autoObservers = Set<AnyCancellable>()
    private var consecutiveFailures = 0
    private var lastVaultRefresh: Date?
    private var pathMonitor: NWPathMonitor?
    private var networkSatisfied = true
    private var wakeObserver: NSObjectProtocol?
    /// Transport-level counters for tests and diagnostics; never user data.
    private(set) var networkRequests = 0
    private(set) var notModifiedResponses = 0
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
         defaults: UserDefaults = .standard, automatic: Bool = false, server: String? = nil,
         credentials: SyncCredentials = .keychain,
         vault: CredentialVault? = nil,
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         snapshot: (() -> AppConfiguration)? = nil, apply: ((AppConfiguration) -> Void)? = nil,
         computerName: @escaping () -> String = { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }) {
        self.store = store; self.hid = hid; self.files = files
        self.automatic = automatic
        self.defaults = defaults; self.credentials = credentials
        suppliedVault = vault
        self.server = server ?? Bundle.main.object(forInfoDictionaryKey: "RotagivanSyncURL") as? String ?? ""
        let session = URLSession(configuration: .ephemeral, delegate: SyncRedirectBlocker(), delegateQueue: nil)
        self.session = session
        self.transport = transport ?? { try await session.data(for: $0) }
        self.snapshot = snapshot ?? { AppConfiguration(store: store) }
        applyOverride = apply
        self.computerName = computerName
        hid.onExplorerUsed = { [weak self] in self?.noteUse() }
        hid.onSyncSettings = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.start()
                await self.awaitLoginRestore()
                guard self.credentialsReady else {
                    AppExplorerController.showWindowError(self.error ?? "Saved login is unavailable. Open Sync & backup to retry.", title: "Sync settings")
                    return
                }
                guard !self.busy else { return }
                await self.save()
                if let error = self.error { AppExplorerController.showWindowError(error, title: "Sync settings") }
            }
        }
    }

    /// Production starts encrypted automatic reconciliation. The explicit
    /// manual mode remains available to legacy migration/test callers only.
    func start() {
        guard !started, !shuttingDown else { return }; started = true
        restoreLogin()
        if automatic {
            // Push: every edit uploads after a short quiet period, so the last
            // Mac to edit wins. The cycle itself decides whether a portable
            // setting actually changed before touching the network.
            Publishers.Merge(store.objectWillChange, ShortcutSettings.shared.objectWillChange)
                .debounce(for: .milliseconds(750), scheduler: RunLoop.main)
                .sink { [weak self] _ in Task { await self?.synchronizeAutomatically(trigger: .localChange) } }
                .store(in: &autoObservers)
            // Pull: an hourly conditional poll (plus wake, network and HUD use),
            // retrying sooner with bounded backoff while failing.
            autoLoop = Task { [weak self] in
                var first = true
                while !Task.isCancelled {
                    await self?.synchronizeAutomatically(trigger: first ? .launch : .poll)
                    first = false
                    let delay = self?.pollDelay ?? Self.pollInterval
                    do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                }
            }
            observeWakeAndNetwork()
        }
    }
    /// Seconds until the next poll: an hour when healthy; while failing, 60 s doubling to 5 min.
    var pollDelay: UInt64 {
        consecutiveFailures == 0 ? Self.pollInterval : min(300, Self.retryInterval << UInt64(min(consecutiveFailures, 4)))
    }
    /// The user just used the HUD or launcher: a good moment to pick up another
    /// Mac's edits, at most once a minute. Never more than one conditional GET.
    func noteUse() {
        guard automatic, started, !shuttingDown,
              lastActivityCheck.map({ Date().timeIntervalSince($0) >= Self.activityCheckInterval }) ?? true else { return }
        lastActivityCheck = Date()
        Task { await synchronizeAutomatically(trigger: .activity) }
    }
    private func observeWakeAndNetwork() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.synchronizeAutomatically(trigger: .wake) }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let regained = satisfied && !self.networkSatisfied
                self.networkSatisfied = satisfied
                if regained { await self.synchronizeAutomatically(trigger: .network) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "local.rotagivan.sync.network", qos: .utility))
        pathMonitor = monitor
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
                if self.automatic { Task { await self.synchronizeAutomatically() } }
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

    /// The Sync now button. A press during an automatic pass or a key
    /// refresh used to be dropped silently; it now waits its turn (up to 30 s)
    /// and always ends with a status the user can see.
    func syncNowPressed() async {
        guard !manualSyncing else { return }
        manualSyncing = true
        defer { manualSyncing = false }
        syncStatus = "Syncing…"
        for _ in 0..<600 where autoRunning || busy || vault.busy {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !shuttingDown else { return }
        guard credentialsReady else { syncStatus = "Unlock your saved account to resume sync."; return }
        guard !autoRunning, !busy, !vault.busy else {
            syncStatus = "Another sync is still running. Try again in a moment."; return
        }
        await save()
        if syncStatus == "Syncing…" { syncStatus = error == nil ? "Up to date" : "Waiting to sync" }
        lastChecked = Date()
    }

    /// An explicit Save captures exactly this moment. Later edits stay local
    /// until the next button press; an error never schedules a retry.
    func save() async {
        if automatic { await synchronizeAutomatically(trigger: .manual); return }
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
        if let encrypted = defaults as? EncryptedPreferences {
            encrypted.transaction { applyUnbatched(config) }
        } else { applyUnbatched(config) }
    }
    private func applyUnbatched(_ config: AppConfiguration) {
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
        autoLoop?.cancel(); autoLoop = nil
        pathMonitor?.cancel(); pathMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        await reconciler?.stop()
        try? await (defaults as? EncryptedPreferences)?.flush()
        shuttingDown = true
        generation = UUID()
        restoreTask?.cancel(); restoreTask = nil
        restoringLogin = false; credentialsReady = false; busy = false
        vault.shutdown()
        session.invalidateAndCancel()
        // No final save, upload, or import on quit.
    }
    /// A single coordinator serializes settings transfers and key refreshes.
    /// The account vault supplies the shared key; no settings plaintext is sent.
    func synchronizeAutomatically(trigger: SyncTrigger = .manual) async {
        guard automatic, !autoRunning, !shuttingDown, credentialsReady, !busy else { return }
        guard let signed = account else { syncStatus = "Sign in to sync your settings and API keys."; return }
        autoRunning = true
        defer { autoRunning = false }
        let accountID = signed.userID
        do {
            // Edits that do not touch a portable setting (window focus, the
            // enable switch, a remote change just applied) never hit the network.
            // Encoding every field is a few milliseconds; keep it off the main thread.
            let initialConfiguration = snapshot()
            let initial = try await Task.detached(priority: .utility) { try SyncConfigurationCodec.fields(initialConfiguration) }.value
            guard account == signed, !shuttingDown else { return }
            if trigger == .localChange, let observedFields, reconciler != nil,
               SyncConfigurationCodec.changes(from: observedFields, to: initial).isEmpty { return }
            await vault.awaitLocalRestore()
            guard account == signed, !shuttingDown else { return }
            guard vault.localReady else { syncStatus = "Unlock this Mac to resume sync."; return }
            guard !vault.busy else { return }
            // Refresh keys without an extra Load button. New Macs discover the
            // approval requirement before they can create or overwrite anything.
            // Once this Mac holds the key, a periodic refresh is enough to notice
            // new API keys or another Mac asking to be approved.
            let vaultStale = lastVaultRefresh.map { Date().timeIntervalSince($0) >= Self.vaultRefreshInterval } ?? true
            if vault.settingsKey == nil || vaultStale || [.manual, .launch, .wake, .network].contains(trigger) {
                await vault.load()
                guard account == signed, !shuttingDown else { return }
                if vault.authenticationExpired { try await expireAccount(signed); return }
                if let failure = vault.error { throw ConfigurationError(failure) }
                lastVaultRefresh = Date()
            }
            if !vault.hasRemote || (vault.unlocked && !vault.settingsConfigured) {
                await vault.save(enableSettings: true)
                if let failure = vault.error { throw ConfigurationError(failure) }
            }
            guard let key = vault.settingsKey, let vaultID = vault.settingsScope else {
                // Enrollment: register this Mac's public key once so the trusted
                // Mac sees a request and a code without any extra button here.
                if vault.hasRemote, !vault.unlocked, !vault.requestPending, !vault.busy {
                    await vault.requestAccess()
                    guard account == signed, !shuttingDown else { return }
                }
                if let code = vault.ownCode {
                    syncStatus = "Waiting for approval from your other Mac · code " + code
                } else {
                    syncStatus = "Approve this Mac from another Mac, or enter your recovery code, to start syncing."
                }
                lastChecked = Date()
                return
            }
            syncStatus = "Syncing…"
            if reconciler == nil || reconciliationAccount != accountID {
                await reconciler?.stop()
                let stateKey = "encrypted.sync." + SyncFiles.digest(Data((server + "/" + accountID + "/" + vaultID).utf8))
                var localState: EncryptedSyncState
                if let data = defaults.data(forKey: stateKey) { localState = try JSONDecoder().decode(EncryptedSyncState.self, from: data) }
                else { localState = EncryptedSyncState() }
                let deviceKey = "encrypted.deviceID"
                let device = defaults.string(forKey: deviceKey) ?? UUID().uuidString
                defaults.set(device, forKey: deviceKey)
                if localState.journal.fields.isEmpty {
                    let firstCloud = try await fetchEncrypted(signed, since: nil)
                    if let yaml = firstCloud.ciphertext, !yaml.hasPrefix("rota-e2ee-settings-v1:") {
                        let legacyConfig = try Self.parseLegacyCloud(yaml)
                        defaults.set(try JSONEncoder().encode(legacyConfig), forKey: "encrypted.legacyCloud." + accountID)
                        let legacyFields = try SyncConfigurationCodec.fields(legacyConfig)
                        // A manual snapshot predates every live edit, so it carries no time.
                        for (name, value) in legacyFields.sorted(by: { $0.key < $1.key }) {
                            try localState.journal.set(value, for: name, deviceID: "legacy", at: Date(timeIntervalSince1970: 0))
                        }
                        // The first upgraded Mac keeps its live edits while
                        // upgrading the manual cloud snapshot to encryption.
                        for (name, value) in SyncConfigurationCodec.changes(from: legacyFields, to: initial).sorted(by: { $0.key < $1.key }) {
                            try localState.journal.set(value, for: name, deviceID: device)
                        }
                    }
                }
                let preferences = SyncPreferenceWriter(defaults)
                let engine = try EncryptedAutoSync(key: key, scope: accountID + "/" + vaultID,
                    deviceID: device, state: localState,
                    transport: EncryptedSyncTransport(fetch: { [weak self] since in
                        guard let self else { throw EncryptedSyncFailure.inactive }
                        return try await self.fetchEncrypted(signed, since: since)
                    }, compareAndSwap: { [weak self] wire, revision in
                        guard let self else { throw EncryptedSyncFailure.inactive }
                        return try await self.putEncrypted(wire, revision: revision, account: signed)
                    }), persist: { state in
                        preferences.defaults.set(try JSONEncoder().encode(state), forKey: stateKey)
                    }, validate: { journal in _ = try SyncConfigurationCodec.configuration(journal) }, legacy: { yaml in
                        var journal = EncryptedSettingsJournal()
                        for (name, value) in try SyncConfigurationCodec.fields(SettingsSync.parseLegacyCloud(yaml)).sorted(by: { $0.key < $1.key }) {
                            try journal.set(value, for: name, deviceID: "legacy", at: Date(timeIntervalSince1970: 0))
                        }
                        return journal
                    }, schedulesItself: false)
                reconciler = engine; reconciliationAccount = accountID
                observedStorageKey = stateKey + ".observed"
                if let baseline = defaults.data(forKey: stateKey + ".observed") {
                    observedFields = try JSONDecoder().decode([String: Data].self, from: baseline)
                } else {
                    // Keep an encrypted recovery snapshot before first download.
                    defaults.set(try JSONEncoder().encode(snapshot()), forKey: "encrypted.beforeFirstSync." + accountID)
                    observedFields = initial
                }
            }
            guard let reconciler else { return }
            let edits = SyncConfigurationCodec.changes(from: observedFields ?? initial, to: initial)
            if !edits.isEmpty { try await reconciler.edit(edits); conflictNotice = nil }
            observedFields = initial
            if let observedStorageKey { defaults.set(try JSONEncoder().encode(initial), forKey: observedStorageKey) }
            var outcome = try await reconciler.syncNow()
            guard account == signed, !shuttingDown else { return }
            var state = await reconciler.snapshot()
            if state.journal.fields.isEmpty {
                try await reconciler.edit(SyncConfigurationCodec.changes(from: [:], to: initial))
                outcome = try await reconciler.syncNow()
                state = await reconciler.snapshot()
            }
            // Preserve edits made while a request was in flight.
            let currentConfiguration = snapshot()
            let current = try await Task.detached(priority: .utility) { try SyncConfigurationCodec.fields(currentConfiguration) }.value
            guard account == signed, !shuttingDown else { return }
            let duringRequest = SyncConfigurationCodec.changes(from: initial, to: current)
            if !duringRequest.isEmpty {
                try await reconciler.edit(duringRequest)
                state = await reconciler.snapshot()
            }
            if let merged = try SyncConfigurationCodec.configuration(state.journal) {
                if try merged.syncFingerprint() != snapshot().syncFingerprint() {
                    defaults.set(try JSONEncoder().encode(snapshot()), forKey: "encrypted.beforeMerge." + accountID)
                    apply(merged)
                }
                observedFields = try SyncConfigurationCodec.fields(merged)
                if let observedStorageKey { defaults.set(try JSONEncoder().encode(observedFields), forKey: observedStorageKey) }
            }
            try await (defaults as? EncryptedPreferences)?.flush()
            if outcome == .synchronizedDroppingLocalConflict {
                conflictNotice = "Another Mac changed the same settings first, so some edits from this Mac were not kept. The previous state of this Mac is saved as an encrypted backup."
            }
            error = nil; lastSave = Date(); lastChecked = Date(); consecutiveFailures = 0
            syncStatus = duringRequest.isEmpty ? "Up to date" : "Saving changes…"
        } catch {
            guard account == signed, !shuttingDown else { return }
            if let api = error as? SyncAPIError, api.status == 401 {
                try? await expireAccount(signed)
                return
            }
            consecutiveFailures += 1
            self.error = "Sync paused. Your local settings are safe. " + error.localizedDescription
            let delay = pollDelay
            syncStatus = delay >= 60 ? "Waiting to sync · retrying in \(delay / 60) min" : "Waiting to sync · retrying in \(delay) s"
        }
    }
    /// Explicit recovery for a wedged state (for example a server that was
    /// restored from backup, which the rollback guard rightly refuses). Drops this
    /// Mac's reconciliation journal; the next cycle adopts the cloud document and
    /// keeps an encrypted copy of this Mac's current settings beforehand.
    func resyncFromCloud() async {
        guard automatic, let signed = account, let vaultID = vault.settingsScope else { return }
        // Let an in-flight cycle finish rather than racing its persistence.
        for _ in 0..<200 where autoRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard !autoRunning, account == signed, !shuttingDown else { return }
        await reconciler?.stop()
        reconciler = nil; reconciliationAccount = nil; observedFields = nil
        let stateKey = "encrypted.sync." + SyncFiles.digest(Data((server + "/" + signed.userID + "/" + vaultID).utf8))
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: stateKey + ".observed")
        consecutiveFailures = 0; error = nil; conflictNotice = nil
        await synchronizeAutomatically(trigger: .manual)
    }
    /// The cloud copy is neither encrypted sync data nor a plain YAML save.
    nonisolated static func parseLegacyCloud(_ yaml: String) throws -> AppConfiguration {
        do { return try AppConfiguration.parse(yaml) } catch {
            let format = yaml.hasPrefix("rota-e2ee-") ? "was saved by a newer version of Rotagivan"
                : "isn’t in a format this version of Rotagivan can read"
            throw ConfigurationError("The cloud copy of your settings \(format) (\(error.localizedDescription)) Update Rotagivan on your other Macs, then sync again.")
        }
    }
    private func expireAccount(_ signed: SyncAccount) async throws {
        try await credentials.remove(server)
        guard account == signed, !shuttingDown else { return }
        account = nil
        error = "Your session expired. Sign in again to resume automatic sync."
        syncStatus = "Sign in to resume sync"
    }
    /// `since` is the encrypted revision this Mac already holds; the server
    /// answers 304 when nothing changed, so idle polls transfer no ciphertext.
    private func fetchEncrypted(_ signed: SyncAccount, since: Int64?) async throws -> EncryptedCloudSnapshot {
        guard account == signed, !shuttingDown else { throw EncryptedSyncFailure.inactive }
        try await (defaults as? EncryptedPreferences)?.flush()
        do {
            let remote: CloudSettings = try await request("settings", method: "GET", token: signed.token,
                ifNoneMatch: since.map { "\"\($0)\"" })
            guard account == signed, !shuttingDown else { throw EncryptedSyncFailure.inactive }
            return EncryptedCloudSnapshot(ciphertext: remote.yaml, revision: Int64(remote.revision))
        } catch is SyncNotModified {
            guard account == signed, !shuttingDown, let since else { throw EncryptedSyncFailure.inactive }
            notModifiedResponses += 1
            return EncryptedCloudSnapshot(ciphertext: nil, revision: since, unchanged: true)
        }
    }
    private func putEncrypted(_ wire: String, revision: Int64, account signed: SyncAccount) async throws -> EncryptedCloudSnapshot {
        guard account == signed, !shuttingDown else { throw EncryptedSyncFailure.inactive }
        try await (defaults as? EncryptedPreferences)?.flush()
        do {
            let saved: CloudSettings = try await request("settings", method: "PUT",
                payload: ["yaml": wire, "baseRevision": revision], token: signed.token)
            guard account == signed, !shuttingDown else { throw EncryptedSyncFailure.inactive }
            return EncryptedCloudSnapshot(ciphertext: wire, revision: Int64(saved.revision))
        } catch let api as SyncAPIError where api.status == 409 { throw EncryptedSyncFailure.raced }
    }
    private func request<T: Decodable>(_ path: String, method: String,
                                      payload: [String: Any]? = nil, token: String?,
                                      ifNoneMatch: String? = nil) async throws -> T {
        guard let base = URL(string: server), base.scheme == "https", base.host != nil else {
            throw ConfigurationError("This build has no configured HTTPS sync server.")
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/" + path))
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let ifNoneMatch {
            // The server decides freshness; never let a URL cache answer or
            // synthesize a 200 from a stored body.
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        networkRequests += 1
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse, data.count <= 2_097_152 else { throw ConfigurationError("Invalid sync response.") }
        if response.statusCode == 304, ifNoneMatch != nil { throw SyncNotModified() }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Sync request failed (\(response.statusCode))."
            throw SyncAPIError(status: response.statusCode, message: detail)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
