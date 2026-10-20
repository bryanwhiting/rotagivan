import Foundation

enum EncryptedSyncFailure: Error, LocalizedError {
    case inactive, invalidRemote, rollback, legacyMigrationRequired, raced, tooLarge
    var errorDescription: String? {
        switch self {
        case .inactive: return "Sync stopped because the account changed on this Mac."
        case .invalidRemote: return "The cloud copy of your settings could not be read with this Mac’s key. Nothing was changed."
        case .rollback: return "The server returned an older copy of your settings than this Mac already synced. Nothing was changed. If this persists, use “Re-sync from cloud” under Privacy & recovery."
        case .legacyMigrationRequired: return "The cloud copy was saved by an older Rotagivan. Sync once from a Mac running the current version."
        case .raced: return "Another Mac is saving at the same moment. Retrying shortly."
        case .tooLarge: return "Your settings exceed the 1 MB sync limit."
        }
    }
}

struct EncryptedCloudSnapshot: Sendable {
    var ciphertext: String?
    var revision: Int64
    /// A conditional fetch confirmed the known revision is still current; no
    /// body was transferred. `ciphertext` is nil and `revision` is the known one.
    var unchanged = false
}

/// The transport only handles opaque ciphertext and CAS revisions. A 409 must
/// become `raced`; never retry an overwrite without fetching and merging first.
/// `fetch` receives the already-acknowledged encrypted revision, if any, so the
/// transport may ask the server for "changed since" instead of the full body.
struct EncryptedSyncTransport: Sendable {
    var fetch: @Sendable (Int64?) async throws -> EncryptedCloudSnapshot
    var compareAndSwap: @Sendable (String, Int64) async throws -> EncryptedCloudSnapshot
}

struct EncryptedSyncState: Codable, Equatable, Sendable {
    var journal = EncryptedSettingsJournal()
    var highestCloudRevision: Int64 = 0
    var acknowledged = EncryptedSettingsJournal()
    var migrated = false
}

/// Account-scoped reconciliation core. Persistence must durably encrypt the
/// complete state; validation must enforce domain invariants before any apply.
/// A new instance is required for a different account/key. No factory settings,
/// Keychain prompts, action execution or plaintext export happen in this actor.
actor EncryptedAutoSync {
    enum Result: Equatable {
        case synchronized, queued
        /// Local edits collided with a concurrent change so badly that the merged
        /// document was invalid; the cloud document was adopted instead.
        case synchronizedDroppingLocalConflict
    }
    private static let prefix = "rota-e2ee-settings-v1:"
    private static let maximumWireBytes = 1_048_576
    private let key: Data
    private let scope: String
    private let deviceID: String
    private let transport: EncryptedSyncTransport
    private let persist: @Sendable (EncryptedSyncState) throws -> Void
    private let validate: @Sendable (EncryptedSettingsJournal) throws -> Void
    private let legacy: (@Sendable (String) throws -> EncryptedSettingsJournal)?
    private let schedulesItself: Bool
    private var state: EncryptedSyncState
    private var active = true
    private var running = false
    private var requested = false
    private var loop: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private(set) var lastFailure: Error?

    init(key: Data, scope: String, deviceID: String, state: EncryptedSyncState,
         transport: EncryptedSyncTransport,
         persist: @escaping @Sendable (EncryptedSyncState) throws -> Void,
         validate: @escaping @Sendable (EncryptedSettingsJournal) throws -> Void,
         legacy: (@Sendable (String) throws -> EncryptedSettingsJournal)? = nil,
         schedulesItself: Bool = true) throws {
        guard key.count == 32, !scope.isEmpty, !scope.contains("\n"),
              !deviceID.isEmpty, state.highestCloudRevision >= 0 else {
            throw EncryptedSyncFailure.invalidRemote
        }
        try state.journal.validateStructure()
        try state.acknowledged.validateStructure()
        try validate(state.journal)
        self.key = key; self.scope = scope; self.deviceID = deviceID
        self.state = state; self.transport = transport
        self.persist = persist; self.validate = validate
        self.legacy = legacy
        self.schedulesItself = schedulesItself
    }

    func snapshot() -> EncryptedSyncState { state }

    /// Local edits not yet acknowledged by the cloud.
    var hasPendingEdits: Bool { state.journal != state.acknowledged }

    /// All changes are locally durable before a debounce can send them.
    func edit(_ updates: [String: Data?]) throws {
        guard active else { throw EncryptedSyncFailure.inactive }
        var next = state
        for name in updates.keys.sorted() {
            try next.journal.set(updates[name]!, for: name, deviceID: deviceID)
        }
        try next.journal.validateStructure()
        try validate(next.journal)
        try persist(next)
        state = next
        requested = true
        scheduleDebounce()
    }

    /// Idempotent automatic startup. Wake/reachability may call syncNow too.
    /// Backoff remains bounded; offline failures retain local edits and retry.
    func start() {
        guard active, loop == nil else { return }
        loop = Task { [weak self] in
            var delay: UInt64 = 30
            while !Task.isCancelled {
                guard let self else { return }
                do { _ = try await self.syncNow(); delay = 30 }
                catch { await self.recordFailure(error); delay = min(300, delay * 2) }
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                catch { return }
            }
        }
    }

    private func recordFailure(_ error: Error) { lastFailure = error }
    private func scheduleDebounce() {
        guard schedulesItself else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self else { return }
            do { _ = try await self.syncNow() } catch { await self.recordFailure(error) }
        }
    }

    /// Stop invalidates in-flight responses even if a transport ignores cancel.
    func stop() {
        active = false
        loop?.cancel(); loop = nil
        debounce?.cancel(); debounce = nil
    }

    private func checkActive() throws {
        guard active, !Task.isCancelled else { throw EncryptedSyncFailure.inactive }
    }

    func syncNow() async throws -> Result {
        try checkActive()
        if running { requested = true; return .queued }
        running = true
        defer {
            running = false
            if active, requested { scheduleDebounce() }
        }
        var droppedLocalConflict = false
        // Bound contention work. Another debounce/poll retries after this budget.
        for _ in 0..<4 {
            requested = false
            // Only an acknowledged *encrypted* revision is safe to skip: a legacy
            // plaintext revision must still be re-read and migrated.
            let known: Int64? = state.migrated && state.highestCloudRevision > 0 ? state.highestCloudRevision : nil
            let remote = try await transport.fetch(known)
            try checkActive()
            guard remote.revision >= state.highestCloudRevision else { throw EncryptedSyncFailure.rollback }
            let peer: EncryptedSettingsJournal
            let encryptedRemote: Bool
            if remote.unchanged {
                guard let known, remote.revision == known, remote.ciphertext == nil else { throw EncryptedSyncFailure.invalidRemote }
                peer = state.acknowledged
                encryptedRemote = true
            } else if let wire = remote.ciphertext {
                peer = try decode(wire, revision: remote.revision)
                encryptedRemote = wire.hasPrefix(Self.prefix)
            } else {
                guard remote.revision == 0, state.highestCloudRevision == 0 else {
                    throw EncryptedSyncFailure.rollback
                }
                peer = EncryptedSettingsJournal()
                encryptedRemote = true
            }
            if remote.revision > 0, remote.revision == state.highestCloudRevision,
               peer != state.acknowledged { throw EncryptedSyncFailure.rollback }
            // Use state *after* the fetch: edits during the await are included.
            var merged = state
            try merged.journal.merge(peer)
            do { try validate(merged.journal) } catch {
                // Concurrent edits can combine into a document that no longer
                // validates (for example a field edited here inside a profile
                // deleted on another Mac). Retrying the same merge forever would
                // stall sync for every Mac, so whoever edited last wins as a
                // whole document: this Mac's copy when its newest edit is later
                // than anything in the cloud, otherwise the cloud copy (which
                // validated when its writer uploaded it), reporting the drop.
                var adopted = merged
                if state.journal.latestEdit > peer.latestEdit, (try? validate(state.journal)) != nil {
                    adopted.journal = state.journal
                    adopted.journal.adoptClock(of: peer)
                } else {
                    adopted.journal = peer
                    try validate(adopted.journal)
                    droppedLocalConflict = true
                }
                merged = adopted
            }
            merged.highestCloudRevision = remote.revision
            merged.acknowledged = peer
            merged.migrated = merged.migrated || (encryptedRemote && remote.revision > 0)
            try persist(merged)
            state = merged
            if merged.journal == peer, encryptedRemote {
                lastFailure = nil
                return droppedLocalConflict ? .synchronizedDroppingLocalConflict : .synchronized
            }
            guard remote.revision < Int64.max else { throw EncryptedSyncFailure.invalidRemote }
            let submitted = merged.journal
            let wire = try encode(submitted, revision: remote.revision + 1)
            let response: EncryptedCloudSnapshot
            do { response = try await transport.compareAndSwap(wire, remote.revision) }
            catch EncryptedSyncFailure.raced { requested = true; continue }
            try checkActive()
            guard response.revision == remote.revision + 1,
                  response.ciphertext == wire else { throw EncryptedSyncFailure.invalidRemote }
            // An acknowledgement never replaces edits made while PUT awaited.
            var acknowledged = state
            acknowledged.highestCloudRevision = response.revision
            acknowledged.acknowledged = submitted
            acknowledged.migrated = true
            try persist(acknowledged)
            state = acknowledged
            if acknowledged.journal == submitted {
                lastFailure = nil
                return droppedLocalConflict ? .synchronizedDroppingLocalConflict : .synchronized
            }
            requested = true
        }
        throw EncryptedSyncFailure.raced
    }

    private func encode(_ journal: EncryptedSettingsJournal, revision: Int64) throws -> String {
        let envelope = try SettingsCipherEnvelope.seal(JSONEncoder().encode(journal),
            master: key, scope: scope, purpose: "cloud", revision: revision)
        let wire = Self.prefix + (try JSONEncoder().encode(envelope)).base64EncodedString()
        guard wire.utf8.count <= Self.maximumWireBytes else { throw EncryptedSyncFailure.tooLarge }
        return wire
    }
    private func decode(_ wire: String, revision: Int64) throws -> EncryptedSettingsJournal {
        guard wire.hasPrefix(Self.prefix) else {
            guard !state.migrated, let legacy else { throw EncryptedSyncFailure.legacyMigrationRequired }
            return try legacy(wire)
        }
        guard wire.utf8.count <= Self.maximumWireBytes,
              let bytes = Data(base64Encoded: String(wire.dropFirst(Self.prefix.count))) else {
            throw EncryptedSyncFailure.invalidRemote
        }
        let envelope = try JSONDecoder().decode(SettingsCipherEnvelope.self, from: bytes)
        guard envelope.revision == revision else { throw EncryptedSyncFailure.invalidRemote }
        return try JSONDecoder().decode(EncryptedSettingsJournal.self,
            from: envelope.open(master: key, scope: scope, purpose: "cloud"))
    }
}
