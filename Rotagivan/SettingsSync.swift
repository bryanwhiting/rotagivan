import AppKit
import Combine
import Foundation
import Network

/// Why a cycle runs. Local-change cycles cost nothing when no portable setting
/// changed since the last reconciliation.
enum SyncTrigger: Sendable { case launch, localChange, poll, wake, network, manual, activity, fileChange }
private struct SyncNotModified: Error {}

private final class SyncRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a session token to a redirect destination.
    }
}
private struct CloudSettings: Codable {
    var yaml: String?
    var revision: Int
    var updatedAt: Double?
}
struct SyncAPIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// Injectable credentials keep tests away from the login Keychain.
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
    static var none: Self { Self(read: { _ in nil }, save: { _, _ in }, remove: { _ in }) }
}

/// One coordinator for both sync homes. The user chooses exactly one:
///
/// - **Cloud:** the whole configuration plus the account's API keys, sealed with
///   a key derived from the account password, uploaded after each edit and
///   polled hourly (sooner on wake, network return and HUD use). Whoever edited
///   last wins as a whole document.
/// - **Local file:** `settings.yaml` in a folder (optionally a git repository),
///   written after each edit and reloaded when the file changes; API keys are
///   read from `~/.env` and never written to the file.
@MainActor final class SettingsSync: ObservableObject {
    static let modeKey = SyncSecrets.modeKey
    static let folderKey = "sync.localFolder"
    static let gitCommitKey = "sync.git.autoCommit"
    static let gitPullKey = "sync.git.autoPull"
    static let pollInterval: UInt64 = 3600
    static let retryInterval: UInt64 = 30
    static let activityCheckInterval: TimeInterval = 60
    static let defaultLocalFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rotagivan", isDirectory: true)

    @Published private(set) var mode: SyncMode?
    @Published private(set) var account: SyncAccount?
    @Published private(set) var restoringLogin = false
    @Published private(set) var credentialsReady = false
    @Published private(set) var busy = false
    @Published private(set) var manualSyncing = false
    @Published private(set) var error: String?
    @Published private(set) var syncStatus = "Choose where your settings live."
    @Published private(set) var conflictNotice: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastSave: Date?
    /// Names of API keys saved in the cloud document (values are never published).
    @Published private(set) var savedSecretNames: Set<String> = []
    // Local mode
    @Published private(set) var localFolder: URL
    @Published private(set) var isGitRepository = false
    @Published private(set) var gitRemote: String?
    @Published private(set) var gitOutput: String?
    @Published var gitAutoCommit: Bool { didSet { defaults.set(gitAutoCommit, forKey: Self.gitCommitKey) } }
    @Published var gitAutoPull: Bool { didSet { defaults.set(gitAutoPull, forKey: Self.gitPullKey) } }

    /// Whether the signed-in account can decrypt (has the password-derived key).
    var unlocked: Bool { account?.master != nil }
    var localFile: URL { localFolder.appendingPathComponent("settings.yaml") }
    private(set) var networkRequests = 0
    private(set) var notModifiedResponses = 0
    let automatic: Bool

    private let store: SettingsStore
    private let hid: NavigatorHIDManager
    private let defaults: UserDefaults
    private let credentials: SyncCredentials
    private let server: String
    private let session: URLSession
    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private let snapshot: () -> AppConfiguration
    private let applyOverride: ((AppConfiguration) -> Void)?
    private let deviceName: String
    private let git: GitRunner
    private var local: LocalFileSync?
    private var watcher: SettingsFileWatcher?
    private var observers = Set<AnyCancellable>()
    private var pollLoop: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var networkSatisfied = true
    private var consecutiveFailures = 0
    private var lastActivityCheck: Date?
    private var running = false
    private var started = false
    private var shuttingDown = false
    private var restoreTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastLocalEditAt: Double = 0

    init(store: SettingsStore, hid: NavigatorHIDManager, defaults: UserDefaults = .standard, automatic: Bool = false,
         server: String? = nil, credentials: SyncCredentials = .keychain,
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         snapshot: (() -> AppConfiguration)? = nil, apply: ((AppConfiguration) -> Void)? = nil,
         localFolder: URL? = nil, git: GitRunner = GitRunner(),
         deviceName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName) {
        self.store = store; self.hid = hid; self.defaults = defaults; self.automatic = automatic
        self.credentials = credentials
        self.server = server ?? Bundle.main.object(forInfoDictionaryKey: "RotagivanSyncURL") as? String ?? ""
        let session = URLSession(configuration: .ephemeral, delegate: SyncRedirectBlocker(), delegateQueue: nil)
        self.session = session
        self.transport = transport ?? { try await session.data(for: $0) }
        self.snapshot = snapshot ?? { AppConfiguration(store: store) }
        applyOverride = apply
        self.git = git
        self.deviceName = String(deviceName.prefix(64))
        mode = defaults.string(forKey: Self.modeKey).flatMap(SyncMode.init(rawValue:))
        self.localFolder = localFolder ?? defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultLocalFolder
        gitAutoCommit = defaults.object(forKey: Self.gitCommitKey) as? Bool ?? true
        gitAutoPull = defaults.object(forKey: Self.gitPullKey) as? Bool ?? true
        savedSecretNames = Set(SyncSecrets.stored(defaults).filter { !$0.value.isEmpty }.keys)
        hid.onExplorerUsed = { [weak self] in self?.noteUse() }
        hid.onSyncSettings = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.start()
                await self.syncNowPressed()
                if let error = self.error { AppExplorerController.showWindowError(error, title: "Sync settings") }
            }
        }
        updateStatusForMode()
    }

    // MARK: Mode

    func choose(_ newMode: SyncMode) {
        guard newMode != mode else { return }
        mode = newMode
        defaults.set(newMode.rawValue, forKey: Self.modeKey)
        error = nil; conflictNotice = nil; consecutiveFailures = 0
        local = nil; watcher?.stop(); watcher = nil
        updateStatusForMode()
        if started { Task { await synchronizeAutomatically(trigger: .manual) } }
    }
    /// Back to "nothing chosen". A cloud account stays signed in; the next
    /// choice of Cloud resumes without a password.
    func leaveMode() {
        mode = nil
        defaults.removeObject(forKey: Self.modeKey)
        local = nil; watcher?.stop(); watcher = nil
        error = nil; conflictNotice = nil
        updateStatusForMode()
    }
    private func updateStatusForMode() {
        switch mode {
        case nil: syncStatus = "Choose where your settings live."
        case .cloud:
            if account == nil { syncStatus = "Sign in to sync your settings and API keys." }
            else if !unlocked { syncStatus = "Enter your password to unlock sync on this Mac." }
            else { syncStatus = "Syncing…" }
        case .local: syncStatus = "Saving to " + localFolder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started, !shuttingDown else { return }; started = true
        restoreLogin()
        guard automatic else { return }
        let changes = Publishers.Merge(store.objectWillChange, ShortcutSettings.shared.objectWillChange)
        changes.sink { [weak self] _ in self?.noteLocalEdit() }.store(in: &observers)
        changes.debounce(for: .milliseconds(750), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.synchronizeAutomatically(trigger: .localChange) } }
            .store(in: &observers)
        pollLoop = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                await self?.synchronizeAutomatically(trigger: first ? .launch : .poll)
                first = false
                let delay = self?.pollDelay ?? Self.pollInterval
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            }
        }
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
    var pollDelay: UInt64 {
        consecutiveFailures == 0 ? Self.pollInterval : min(300, Self.retryInterval << UInt64(min(consecutiveFailures, 4)))
    }
    func noteUse() {
        guard automatic, started, !shuttingDown,
              lastActivityCheck.map({ Date().timeIntervalSince($0) >= Self.activityCheckInterval }) ?? true else { return }
        lastActivityCheck = Date()
        Task { await synchronizeAutomatically(trigger: .activity) }
    }
    func prepareToQuit() async {
        pollLoop?.cancel(); pollLoop = nil
        pathMonitor?.cancel(); pathMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        watcher?.stop(); watcher = nil
        try? await (defaults as? EncryptedPreferences)?.flush()
        shuttingDown = true
        generation = UUID()
        restoreTask?.cancel(); restoreTask = nil
        restoringLogin = false; credentialsReady = false; busy = false
        session.invalidateAndCancel()
    }

    // MARK: Account

    func retryLoginRestore() {
        guard started, !shuttingDown, !restoringLogin, !credentialsReady else { return }
        restoreLogin(interactive: true)
    }
    func awaitLoginRestore() async { await restoreTask?.value }
    private func restoreLogin(interactive: Bool = false) {
        generation = UUID()
        let token = generation
        restoringLogin = true; credentialsReady = false; error = nil
        let read = interactive ? (credentials.unlock ?? credentials.read) : credentials.read, server = server
        restoreTask = Task { [weak self] in
            do {
                let restored = try await read(server)
                guard let self, self.isCurrent(token) else { return }
                self.account = restored
                self.credentialsReady = true; self.restoringLogin = false
                self.updateStatusForMode()
                if self.automatic { Task { await self.synchronizeAutomatically(trigger: .launch) } }
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.restoringLogin = false; self.error = error.localizedDescription
            }
        }
    }
    private func isCurrent(_ token: UUID) -> Bool { !shuttingDown && generation == token && !Task.isCancelled }

    /// Sign in or create the account. The server receives a key derived from the
    /// password, never the password itself. An account created by an older build
    /// (which sent the real password) is upgraded on its first sign-in here.
    func authenticate(email rawEmail: String, password: String, create: Bool) async {
        guard credentialsReady, !busy, !shuttingDown else { return }
        busy = true; error = nil
        do {
            let email = try SyncCrypto.normalizedEmail(rawEmail)
            let master = try await Task.detached(priority: .userInitiated) { try SyncCrypto.masterKey(email: email, password: password) }.value
            let secret = SyncCrypto.loginSecret(master: master)
            var signed: SyncAccount
            if create {
                signed = try await request("register", method: "POST", payload: ["email": email, "password": secret], token: nil)
            } else {
                do { signed = try await request("login", method: "POST", payload: ["email": email, "password": secret], token: nil) }
                catch let api as SyncAPIError where api.status == 401 {
                    // Legacy account: the server knows the real password. Switch it
                    // to the derived secret so the password never travels again.
                    let legacy: SyncAccount = try await request("login", method: "POST", payload: ["email": email, "password": password], token: nil)
                    signed = try await request("password", method: "POST",
                        payload: ["currentPassword": password, "newPassword": secret], token: legacy.token)
                }
            }
            signed.master = master
            try await credentials.save(signed, server)
            guard !shuttingDown else { return }
            account = signed
            conflictNotice = nil; consecutiveFailures = 0
            updateStatusForMode()
        } catch { self.error = error.localizedDescription }
        busy = false
        if error == nil, mode == .cloud { await synchronizeAutomatically(trigger: .manual) }
    }
    func signOut() async {
        guard let signed = account, !busy else { return }
        busy = true
        defer { busy = false }
        do { let _: [String: Bool] = try await request("logout", method: "POST", payload: [:], token: signed.token) } catch {}
        do {
            try await credentials.remove(server)
            account = nil
            SyncSecrets.store([:], defaults); savedSecretNames = []
            defaults.removeObject(forKey: stateKey(for: signed))
            updateStatusForMode()
        } catch { self.error = error.localizedDescription }
    }
    func changePassword(current: String, new: String) async {
        guard let signed = account, !busy, let email = try? SyncCrypto.normalizedEmail(signed.email) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let oldMaster = try await Task.detached { try SyncCrypto.masterKey(email: email, password: current) }.value
            let newMaster = try await Task.detached { try SyncCrypto.masterKey(email: email, password: new) }.value
            var replacement: SyncAccount = try await request("password", method: "POST",
                payload: ["currentPassword": SyncCrypto.loginSecret(master: oldMaster),
                          "newPassword": SyncCrypto.loginSecret(master: newMaster)], token: signed.token)
            replacement.master = newMaster
            try await credentials.save(replacement, server)
            account = replacement
            // Force a re-upload under the new key.
            var state = loadState(for: replacement)
            state.fingerprint = ""; state.localEditedAt = Date().timeIntervalSince1970
            saveState(state, for: replacement)
            await synchronizeAutomatically(trigger: .manual)
        } catch { self.error = error.localizedDescription }
    }
    private func expireAccount(_ signed: SyncAccount) async {
        try? await credentials.remove(server)
        guard account == signed, !shuttingDown else { return }
        account = nil
        error = "Your session expired. Sign in again to resume sync."
        updateStatusForMode()
    }

    // MARK: API keys (cloud mode)

    func setSecret(_ name: String, value: String) {
        guard SyncSecrets.names.contains(name) else { return }
        var values = SyncSecrets.stored(defaults)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { values.removeValue(forKey: name) } else { values[name] = trimmed }
        SyncSecrets.store(values, defaults)
        savedSecretNames = Set(values.keys)
        noteLocalEdit()
        Task { await synchronizeAutomatically(trigger: .localChange) }
    }
    /// Copies the keys found in `~/.env` into the synced document. The file is
    /// read literally and never modified.
    @discardableResult func importSecretsFromEnvironment() -> [String] {
        var imported: [String] = []
        var values = SyncSecrets.stored(defaults)
        for name in SyncSecrets.names {
            guard let value = SyncSecrets.environmentValue(name) else { continue }
            values[name] = value; imported.append(name)
        }
        guard !imported.isEmpty else { return [] }
        SyncSecrets.store(values, defaults)
        savedSecretNames = Set(values.keys)
        noteLocalEdit()
        Task { await synchronizeAutomatically(trigger: .localChange) }
        return imported
    }
    func environmentSecretNames() -> Set<String> {
        Set(SyncSecrets.names.filter { SyncSecrets.environmentValue($0) != nil })
    }
    /// Called on every store change (before the debounce) so the conflict rule
    /// compares real edit times, not the times the sync cycles happened to run.
    func noteLocalEdit(at date: Date = Date()) { lastLocalEditAt = max(lastLocalEditAt, date.timeIntervalSince1970) }

    // MARK: Local folder

    func chooseLocalFolder(_ url: URL) {
        localFolder = url
        defaults.set(url.path, forKey: Self.folderKey)
        local = nil; watcher?.stop(); watcher = nil
        error = nil
        updateStatusForMode()
        Task { await synchronizeAutomatically(trigger: .manual) }
    }
    func initializeGit() async {
        guard let local = localEngine() else { return }
        do { try await local.initializeRepository(); gitOutput = "Initialized an empty git repository."; await refreshGitState(local) }
        catch { self.error = error.localizedDescription }
    }
    func pullNow() async {
        guard let local = localEngine() else { return }
        do { gitOutput = try await local.pull(); await synchronizeAutomatically(trigger: .fileChange) }
        catch { self.error = error.localizedDescription }
    }
    func commitAndPushNow() async {
        guard let local = localEngine() else { return }
        do {
            try await local.write(snapshot(), force: true)
            gitOutput = try await local.commitAndPush(message: commitMessage())
        } catch { self.error = error.localizedDescription }
    }
    func reloadFromFile() async {
        await synchronizeAutomatically(trigger: .fileChange)
    }
    private func commitMessage() -> String { "Rotagivan settings from \(deviceName)" }
    private func localEngine() -> LocalFileSync? {
        if let local { return local }
        let engine = LocalFileSync(folder: localFolder, git: git)
        local = engine
        if automatic {
            watcher = SettingsFileWatcher(folder: localFolder) { [weak self] in
                Task { @MainActor [weak self] in await self?.synchronizeAutomatically(trigger: .fileChange) }
            }
        }
        return engine
    }
    private func refreshGitState(_ local: LocalFileSync) async {
        isGitRepository = await local.isRepository
        gitRemote = await local.remoteName()
    }

    // MARK: Cycle

    func syncNowPressed() async {
        guard !manualSyncing else { return }
        manualSyncing = true
        defer { manualSyncing = false }
        for _ in 0..<600 where running || busy { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard !shuttingDown else { return }
        await synchronizeAutomatically(trigger: .manual)
        lastChecked = Date()
    }

    /// Serialized; never runs two cycles at once. Each branch is total: it ends
    /// in "up to date", a visible notice, or a visible error with a retry delay.
    func synchronizeAutomatically(trigger: SyncTrigger = .manual) async {
        guard !running, !shuttingDown, credentialsReady, !busy else { return }
        guard let mode else { return }
        running = true
        defer { running = false }
        do {
            switch mode {
            case .cloud: try await cloudCycle(trigger: trigger)
            case .local: try await localCycle(trigger: trigger)
            }
            consecutiveFailures = 0
            error = nil
        } catch {
            guard !shuttingDown else { return }
            if let api = error as? SyncAPIError, api.status == 401, let signed = account { await expireAccount(signed); return }
            consecutiveFailures += 1
            self.error = "Sync paused. Your local settings are safe. " + error.localizedDescription
            let delay = pollDelay
            syncStatus = delay >= 60 ? "Waiting to sync · retrying in \(delay / 60) min" : "Waiting to sync · retrying in \(delay) s"
        }
    }

    private func stateKey(for account: SyncAccount) -> String {
        "sync.cloud.v2." + SyncFiles.digest(Data((server + "/" + account.userID).utf8))
    }
    private func loadState(for account: SyncAccount) -> CloudSyncState {
        guard let data = defaults.data(forKey: stateKey(for: account)),
              let state = try? JSONDecoder().decode(CloudSyncState.self, from: data) else { return CloudSyncState() }
        return state
    }
    private func saveState(_ state: CloudSyncState, for account: SyncAccount) {
        defaults.set(try? JSONEncoder().encode(state), forKey: stateKey(for: account))
    }

    private func cloudCycle(trigger: SyncTrigger) async throws {
        guard let signed = account else { syncStatus = "Sign in to sync your settings and API keys."; return }
        guard let master = signed.master else { syncStatus = "Enter your password to unlock sync on this Mac."; return }
        let email = try SyncCrypto.normalizedEmail(signed.email)
        let engine = CloudSyncEngine(master: master, email: email, device: deviceName,
            transport: CloudSyncTransport(fetch: { [weak self] known in
                guard let self else { throw CloudSyncFailure.rollback }
                return try await self.fetchCloud(signed, since: known)
            }, compareAndSwap: { [weak self] wire, base in
                guard let self else { throw CloudSyncFailure.rollback }
                return try await self.putCloud(wire, baseRevision: base, account: signed)
            }))
        var state = loadState(for: signed)
        let configuration = snapshot()
        let secrets = SyncSecrets.stored(defaults)
        let fingerprint = try await Task.detached(priority: .utility) { try engine.fingerprint(configuration, secrets: secrets) }.value
        guard account == signed, !shuttingDown else { return }
        let changed = fingerprint != state.fingerprint
        // Stamp the newest edit only once this Mac has reconciled before; until
        // then its settings are defaults, and a cloud copy must win over them.
        if changed, !state.fingerprint.isEmpty {
            let editedAt = lastLocalEditAt > 0 ? lastLocalEditAt : Date().timeIntervalSince1970
            if editedAt > state.localEditedAt { state.localEditedAt = editedAt; saveState(state, for: signed) }
        }
        if trigger == .localChange, !changed { return }
        syncStatus = "Syncing…"
        try await (defaults as? EncryptedPreferences)?.flush()
        let (outcome, next) = try await engine.reconcile(local: configuration, secrets: secrets, state: state)
        guard account == signed, !shuttingDown else { return }
        switch outcome {
        case .upToDate:
            syncStatus = "Up to date"
        case .uploaded, .localWonConflict:
            syncStatus = "Up to date"; lastSave = Date()
            if case .localWonConflict = outcome {
                conflictNotice = "Another Mac changed settings too; this Mac's newer edit won."
            }
        case .replacedUnreadable(_, let reason):
            syncStatus = "Up to date"; lastSave = Date()
            conflictNotice = "The cloud held \(reason); this Mac's settings replaced it."
        case .downloaded(let document, _), .remoteWonConflict(let document, _):
            if case .remoteWonConflict = outcome {
                defaults.set(try? JSONEncoder().encode(configuration), forKey: "sync.beforeMerge." + signed.userID)
                conflictNotice = "Another Mac edited settings more recently; its copy replaced this Mac's. The previous state of this Mac is saved as an encrypted backup."
            } else { conflictNotice = nil }
            applyDocument(document)
            syncStatus = "Up to date · from \(document.editedBy)"
        }
        saveState(next, for: signed)
        try await (defaults as? EncryptedPreferences)?.flush()
        lastChecked = Date()
    }

    private func localCycle(trigger: SyncTrigger) async throws {
        guard let local = localEngine() else { return }
        if trigger == .launch || trigger == .manual { await refreshGitState(local) }
        let configuration = snapshot()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = localFolder.path.replacingOccurrences(of: home, with: "~")
        switch trigger {
        case .localChange:
            do {
                try await local.write(configuration)
            } catch LocalFileSync.Failure.diskChanged {
                // The file was changed by something else while this Mac edited.
                // The newer side wins; the other is kept as a backup.
                let fileDate = (try? await local.modificationDate())?.timeIntervalSince1970 ?? 0
                if fileDate > lastLocalEditAt, let (disk, digest) = try await local.readIfChanged() {
                    try await local.backup(configuration)
                    apply(disk); await local.acknowledge(digest)
                    conflictNotice = "settings.yaml changed on disk after this Mac's last edit; the file won. This Mac's previous settings are in \(shown)/backup."
                } else {
                    try await local.write(configuration, force: true)
                    conflictNotice = "settings.yaml changed on disk, but this Mac's edit was newer and replaced it. The disk copy is in \(shown)/backup."
                }
            }
            lastSave = Date()
            if gitAutoCommit, await local.isRepository {
                gitOutput = try await local.commitAndPush(message: commitMessage())
            }
        case .launch, .poll, .wake, .network, .manual, .activity, .fileChange:
            if gitAutoPull, trigger != .fileChange, await local.isRepository, await local.remoteName() != nil {
                do { gitOutput = try await local.pull() }
                catch { gitOutput = (error as? LocalizedError)?.errorDescription ?? "git pull failed." }
            }
            if let (disk, digest) = try await local.readIfChanged() {
                if try disk.syncFingerprint() != configuration.syncFingerprint() {
                    try await local.backup(configuration)
                    apply(disk)
                }
                await local.acknowledge(digest)
                lastChecked = Date()
            } else if try await !local.exists() {
                try await local.write(configuration, force: true)
                lastSave = Date()
            }
        }
        lastLocalEditAt = trigger == .localChange ? Date().timeIntervalSince1970 : lastLocalEditAt
        syncStatus = "Up to date · \(shown)/settings.yaml"
    }

    // MARK: Apply

    private func applyDocument(_ document: SyncDocument) {
        SyncSecrets.store(document.secrets, defaults)
        savedSecretNames = Set(document.secrets.keys)
        apply(document.configuration)
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

    // MARK: Transport

    private func fetchCloud(_ signed: SyncAccount, since: Int64?) async throws -> CloudSettingsRecord {
        guard account == signed, !shuttingDown else { throw CloudSyncFailure.rollback }
        do {
            let remote: CloudSettings = try await request("settings", method: "GET", token: signed.token,
                ifNoneMatch: since.map { "\"\($0)\"" })
            return CloudSettingsRecord(ciphertext: remote.yaml, revision: Int64(remote.revision))
        } catch is SyncNotModified {
            guard let since else { throw CloudSyncFailure.inconsistentServer }
            notModifiedResponses += 1
            return CloudSettingsRecord(ciphertext: nil, revision: since, unchanged: true)
        }
    }
    private func putCloud(_ wire: String, baseRevision: Int64, account signed: SyncAccount) async throws -> CloudSettingsRecord {
        guard account == signed, !shuttingDown else { throw CloudSyncFailure.rollback }
        do {
            let saved: CloudSettings = try await request("settings", method: "PUT",
                payload: ["yaml": wire, "baseRevision": baseRevision], token: signed.token)
            return CloudSettingsRecord(ciphertext: wire, revision: Int64(saved.revision))
        } catch let api as SyncAPIError where api.status == 409 { throw CloudSyncFailure.raced }
    }
    private func request<T: Decodable>(_ path: String, method: String, payload: [String: Any]? = nil,
                                      token: String?, ifNoneMatch: String? = nil) async throws -> T {
        guard let base = URL(string: server), base.scheme == "https", base.host != nil else {
            throw ConfigurationError("This build has no configured HTTPS sync server.")
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/" + path))
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        networkRequests += 1
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse, data.count <= 4_194_304 else { throw ConfigurationError("Invalid sync response.") }
        if response.statusCode == 304, ifNoneMatch != nil { throw SyncNotModified() }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Sync request failed (\(response.statusCode))."
            throw SyncAPIError(status: response.statusCode, message: detail)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
