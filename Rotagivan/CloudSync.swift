import Foundation

/// What one Mac uploads: the complete portable configuration, the API keys that
/// belong to the account, and when and where it was last edited. Whoever edited
/// last wins as a whole document.
struct SyncDocument: Codable {
    var editedAt: Double
    var editedBy: String
    var configuration: AppConfiguration
    var secrets: [String: String]

    static let decoder = JSONDecoder()
    static func encode(_ document: Self) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }
    static func decode(_ data: Data) throws -> Self {
        let document = try decoder.decode(Self.self, from: data)
        try document.configuration.validate()
        guard document.secrets.count <= 32,
              document.secrets.allSatisfy({ SyncSecrets.isValidName($0.key) && $0.value.count <= 4096 }) else {
            throw SyncCrypto.Failure.unreadable
        }
        return document
    }
}

/// What the server holds: one opaque string per account and a revision that
/// increases by one per accepted write. `nil` ciphertext with revision 0 means
/// the account has never uploaded.
struct CloudSettingsRecord: Equatable, Sendable {
    var ciphertext: String?
    var revision: Int64
    /// A conditional fetch confirmed `revision` is still current; no body came.
    var unchanged = false
}

/// The only two things the engine asks of the network. A compare-and-swap that
/// loses must throw `CloudSyncFailure.raced` so the engine re-reads and merges.
struct CloudSyncTransport: Sendable {
    var fetch: @Sendable (_ knownRevision: Int64?) async throws -> CloudSettingsRecord
    var compareAndSwap: @Sendable (_ wire: String, _ baseRevision: Int64) async throws -> CloudSettingsRecord
}

enum CloudSyncFailure: Error, LocalizedError, Equatable {
    case raced, rollback, inconsistentServer
    var errorDescription: String? {
        switch self {
        case .raced: return "Another Mac is saving at the same moment. Retrying shortly."
        case .rollback: return "The server returned an older copy of your settings than this Mac already synced. Nothing was changed."
        case .inconsistentServer: return "The server acknowledged a save it did not store. Nothing was changed."
        }
    }
}

/// Persisted per account between cycles.
struct CloudSyncState: Codable, Equatable, Sendable {
    /// The cloud revision this Mac last reconciled with (0 = never).
    var revision: Int64 = 0
    /// Fingerprint of the configuration and secrets as of that reconciliation.
    var fingerprint = ""
    /// Wall-clock time of the newest local edit not yet in the cloud.
    var localEditedAt: Double = 0
}

/// Whole-document, last-edit-wins reconciliation. No field journals, no
/// Lamport clocks, no tombstones: a settings document is small, edits are made
/// by one person, and "the Mac I edited on last wins" is the rule the user asked
/// for. Every outcome is total: there is no merged state that can fail to decode.
struct CloudSyncEngine: Sendable {
    enum Outcome {
        case upToDate
        case uploaded(revision: Int64)
        case downloaded(SyncDocument, revision: Int64)
        /// Both sides changed; the remote edit was newer so it replaced this Mac's.
        case remoteWonConflict(SyncDocument, revision: Int64)
        /// Both sides changed; this Mac's edit was newer so it was uploaded.
        case localWonConflict(revision: Int64)
        /// The cloud held something this build cannot read (plaintext from an old
        /// manual save, the former field journal, or a different password); this
        /// Mac's copy replaced it.
        case replacedUnreadable(revision: Int64, reason: String)
    }
    var master: Data
    var email: String
    var device: String
    var transport: CloudSyncTransport
    var now: @Sendable () -> Double = { Date().timeIntervalSince1970 }

    func fingerprint(_ configuration: AppConfiguration, secrets: [String: String]) throws -> String {
        let secretDigest = SyncFiles.digest(try JSONEncoder().encode(secrets.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }))
        return (try configuration.syncFingerprint()) + "/" + secretDigest
    }

    /// One reconciliation. `local` is this Mac's current document; `state` is
    /// where it stood after the previous cycle. Returns the outcome and the new
    /// state to persist. Never applies anything itself.
    func reconcile(local configuration: AppConfiguration, secrets: [String: String],
                   state: CloudSyncState) async throws -> (Outcome, CloudSyncState) {
        let localFingerprint = try fingerprint(configuration, secrets: secrets)
        let localChanged = localFingerprint != state.fingerprint
        // A Mac that has never reconciled holds defaults, not edits: a cloud
        // document always wins there, without being called a conflict.
        let localEdited = localChanged && (state.localEditedAt > 0 || !state.fingerprint.isEmpty)
        var state = state
        for _ in 0..<4 {
            let remote = try await transport.fetch(state.revision > 0 ? state.revision : nil)
            guard remote.revision >= state.revision else { throw CloudSyncFailure.rollback }
            let remoteChanged = !remote.unchanged && remote.revision != state.revision
            if !remoteChanged && !localChanged { state.localEditedAt = 0; return (.upToDate, state) }
            var remoteDocument: SyncDocument?
            var unreadable: String?
            if remoteChanged, let wire = remote.ciphertext {
                do {
                    remoteDocument = try SyncDocument.decode(try SyncCrypto.open(wire, master: master, email: email, revision: remote.revision))
                } catch {
                    unreadable = SyncCrypto.isEncrypted(wire)
                        ? (error as? LocalizedError)?.errorDescription ?? "unreadable encrypted copy"
                        : "a settings copy saved by an older Rotagivan"
                }
            }
            // Decide who wins. A remote document wins when this Mac has nothing
            // new, or when the remote edit is the later one.
            let takeRemote: Bool
            if let remoteDocument {
                takeRemote = !localEdited || remoteDocument.editedAt > state.localEditedAt
            } else { takeRemote = false }
            if let remoteDocument, takeRemote {
                let next = CloudSyncState(revision: remote.revision,
                    fingerprint: try fingerprint(remoteDocument.configuration, secrets: remoteDocument.secrets), localEditedAt: 0)
                return (localEdited ? .remoteWonConflict(remoteDocument, revision: remote.revision)
                                    : .downloaded(remoteDocument, revision: remote.revision), next)
            }
            // Upload this Mac's document on top of whatever the server holds.
            let editedAt = state.localEditedAt > 0 ? state.localEditedAt : now()
            let document = SyncDocument(editedAt: editedAt, editedBy: device, configuration: configuration, secrets: secrets)
            let wire = try SyncCrypto.seal(try SyncDocument.encode(document), master: master, email: email, revision: remote.revision + 1)
            let saved: CloudSettingsRecord
            do { saved = try await transport.compareAndSwap(wire, remote.revision) }
            catch CloudSyncFailure.raced { continue }
            guard saved.revision == remote.revision + 1 else { throw CloudSyncFailure.inconsistentServer }
            let next = CloudSyncState(revision: saved.revision, fingerprint: localFingerprint, localEditedAt: 0)
            if let unreadable { return (.replacedUnreadable(revision: saved.revision, reason: unreadable), next) }
            if remoteDocument != nil { return (.localWonConflict(revision: saved.revision), next) }
            return (.uploaded(revision: saved.revision), next)
        }
        throw CloudSyncFailure.raced
    }
}
