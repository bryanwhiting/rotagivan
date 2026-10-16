import CryptoKit
import Foundation
import SQLite3

enum EncryptedSettingsError: Error, LocalizedError {
    case invalidEnvelope, staleRevision, unsafePath, databaseFailure, exhaustedClock
    var errorDescription: String? {
        switch self {
        case .invalidEnvelope: return "Encrypted settings could not be verified with this Mac’s key."
        case .staleRevision: return "Encrypted settings changed on disk while saving."
        case .unsafePath: return "The encrypted settings location is not a private regular file."
        case .databaseFailure: return "The encrypted settings database could not be written."
        case .exhaustedClock: return "The sync change counter is exhausted."
        }
    }
}

/// A purpose-separated, authenticated envelope; no setting names or keys are
/// exposed in its metadata. Unlocking material is supplied by Keychain, not disk.
struct SettingsCipherEnvelope: Codable {
    let version: Int
    let revision: Int64
    let ciphertext: Data
    static let maximumBytes = 8_388_608

    private static func context(scope: String, purpose: String, revision: Int64) -> Data {
        Data("rota-settings-v1\n\(purpose)\n\(scope)\n\(revision)".utf8)
    }
    private static func key(_ master: Data, scope: String, purpose: String) throws -> SymmetricKey {
        guard master.count == 32, !scope.isEmpty, !scope.contains("\n") else {
            throw EncryptedSettingsError.invalidEnvelope
        }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master),
            salt: Data(scope.utf8), info: Data("rota-settings-v1/\(purpose)".utf8), outputByteCount: 32)
    }
    static func seal(_ data: Data, master: Data, scope: String, purpose: String, revision: Int64) throws -> Self {
        guard data.count <= maximumBytes, revision > 0 else { throw EncryptedSettingsError.invalidEnvelope }
        let sealed = try AES.GCM.seal(data, using: key(master, scope: scope, purpose: purpose),
            authenticating: context(scope: scope, purpose: purpose, revision: revision))
        guard let bytes = sealed.combined else { throw EncryptedSettingsError.invalidEnvelope }
        return Self(version: 1, revision: revision, ciphertext: bytes)
    }
    func open(master: Data, scope: String, purpose: String) throws -> Data {
        guard version == 1, revision > 0, ciphertext.count >= 28,
              ciphertext.count <= Self.maximumBytes + 28 else { throw EncryptedSettingsError.invalidEnvelope }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
            using: Self.key(master, scope: scope, purpose: purpose),
            authenticating: Self.context(scope: scope, purpose: purpose, revision: revision))
    }
}

/// A private database whose only content row is AEAD ciphertext. SQLite's
/// rollback journal also receives ciphertext, never the decoded settings.
final class EncryptedSettingsDatabase {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let master: Data
    private let scope: String
    let url: URL
    init(url: URL, master: Data, scope: String) throws {
        guard url.isFileURL, master.count == 32 else { throw EncryptedSettingsError.unsafePath }
        self.url = url; self.master = master; self.scope = scope
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: url.path)
        let parent = url.deletingLastPathComponent()
        if let type = try? fm.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType {
            guard type == .typeDirectory else { throw EncryptedSettingsError.unsafePath }
        } else {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType {
            guard type == .typeRegular else { throw EncryptedSettingsError.unsafePath }
        }
        // NOFOLLOW closes the gap between the entry check and sqlite's open.
        // Foundation re-abbreviates /private/var to /var on macOS. realpath keeps
        // the actual OS directory path required by SQLite's NOFOLLOW policy.
        guard let resolved = realpath(parent.path, nil) else { throw EncryptedSettingsError.unsafePath }
        let path = String(cString: resolved) + "/" + url.lastPathComponent
        free(resolved)
        let result = sqlite3_open_v2(path, &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK else {
            sqlite3_close(database); database = nil
            throw NSError(domain: "Rotagivan.EncryptedStorage", code: Int(result))
        }
        do {
            // Refuse foreign/legacy databases before changing their schema or
            // permissions. A marker also detects empty/truncated replacements.
            if existed {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "PRAGMA application_id", -1, &statement, nil) == SQLITE_OK else {
                    throw EncryptedSettingsError.databaseFailure
                }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW,
                      sqlite3_column_int(statement, 0) == 0x524F5441 else {
                    throw EncryptedSettingsError.invalidEnvelope
                }
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(database, 2_000)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA secure_delete=ON")
            try execute("CREATE TABLE IF NOT EXISTS settings (slot INTEGER PRIMARY KEY CHECK(slot=1), revision INTEGER NOT NULL, ciphertext BLOB NOT NULL)")
            if !existed { try execute("PRAGMA application_id=1380930625") }
            // Existing unreadable/tampered data must never be treated as empty.
            if let record = try record() { _ = try record.open(master: master, scope: scope, purpose: "local") }
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }
    private func execute(_ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw NSError(domain: "Rotagivan.EncryptedStorage", code: Int(result)) }
    }
    private func record() throws -> SettingsCipherEnvelope? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT revision,ciphertext FROM settings WHERE slot=1", -1, &statement, nil) == SQLITE_OK else {
            throw EncryptedSettingsError.databaseFailure
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 1) else { throw EncryptedSettingsError.databaseFailure }
        let count = Int(sqlite3_column_bytes(statement, 1))
        guard count >= 28, count <= SettingsCipherEnvelope.maximumBytes + 28 else { throw EncryptedSettingsError.invalidEnvelope }
        return SettingsCipherEnvelope(version: 1, revision: sqlite3_column_int64(statement, 0),
            ciphertext: Data(bytes: bytes, count: count))
    }
    func read() throws -> (revision: Int64, data: Data)? {
        lock.lock(); defer { lock.unlock() }
        guard let record = try record() else { return nil }
        return (record.revision, try record.open(master: master, scope: scope, purpose: "local"))
    }
    @discardableResult func save(_ data: Data, expectedRevision: Int64?) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }
        let old = try record()
        if let old { _ = try old.open(master: master, scope: scope, purpose: "local") }
        guard old?.revision == expectedRevision else { throw EncryptedSettingsError.staleRevision }
        guard (old?.revision ?? 0) < Int64.max else { throw EncryptedSettingsError.exhaustedClock }
        let next = (old?.revision ?? 0) + 1
        let envelope = try SettingsCipherEnvelope.seal(data, master: master, scope: scope, purpose: "local", revision: next)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO settings(slot,revision,ciphertext) VALUES(1,?,?)", -1, &statement, nil) == SQLITE_OK else {
            throw EncryptedSettingsError.databaseFailure
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, next) == SQLITE_OK else { throw EncryptedSettingsError.databaseFailure }
        let bound = envelope.ciphertext.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw EncryptedSettingsError.databaseFailure }
        try execute("COMMIT"); committed = true
        return next
    }
}

/// Logical clocks avoid trusting a Mac's wall clock for reconciliation. Different
/// fields merge independently; same-field concurrent writes converge by device ID.
struct SettingsFieldStamp: Codable, Equatable, Comparable, Sendable {
    let counter: UInt64
    let deviceID: String
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.deviceID < rhs.deviceID : lhs.counter < rhs.counter
    }
}
struct SettingsField: Codable, Equatable, Sendable {
    let stamp: SettingsFieldStamp
    let value: Data? // nil is a deletion tombstone, not a missing update
}
struct EncryptedSettingsJournal: Codable, Equatable, Sendable {
    private(set) var fields: [String: SettingsField] = [:]
    private(set) var counter: UInt64 = 0
    func validateStructure() throws {
        guard fields.count <= 50_000,
              fields.allSatisfy({ name, field in
                  !name.isEmpty && name.utf8.count <= 1024 &&
                  !field.stamp.deviceID.isEmpty && field.stamp.deviceID.utf8.count <= 1024 &&
                  field.stamp.counter > 0 && field.stamp.counter <= counter &&
                  (field.value?.count ?? 0) <= SettingsCipherEnvelope.maximumBytes
              }) else { throw EncryptedSettingsError.invalidEnvelope }
    }
    mutating func set(_ value: Data?, for field: String, deviceID: String) throws {
        guard !field.isEmpty, !deviceID.isEmpty, counter < UInt64.max else { throw EncryptedSettingsError.exhaustedClock }
        counter += 1
        fields[field] = SettingsField(stamp: SettingsFieldStamp(counter: counter, deviceID: deviceID), value: value)
    }
    mutating func merge(_ remote: Self) throws {
        try remote.validateStructure()
        var merged = fields
        for (name, incoming) in remote.fields {
            if let old = merged[name] {
                if incoming.stamp == old.stamp, incoming.value != old.value { throw EncryptedSettingsError.invalidEnvelope }
                if old.stamp < incoming.stamp { merged[name] = incoming }
            } else { merged[name] = incoming }
        }
        fields = merged
        counter = max(counter, remote.counter, fields.values.map(\.stamp.counter).max() ?? 0)
    }
}
