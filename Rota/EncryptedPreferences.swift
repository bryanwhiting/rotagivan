import Foundation

/// Adapter for existing native preference consumers. Values live in memory and
/// the encrypted SQLite row; nothing is forwarded into a plaintext defaults domain.
/// The caller must successfully unlock/open the database before constructing it.
final class EncryptedPreferences: UserDefaults, @unchecked Sendable {
    private struct Archive: Codable { var values: [String: Data] }
    private let database: EncryptedSettingsDatabase
    private let stateLock = NSLock()
    private let writer = DispatchQueue(label: "local.rota.encrypted-settings-writer", qos: .utility)
    private var values: [String: Data]
    private var registered: [String: Any] = [:]
    private var revision: Int64?
    private var pending: [String: Data]?
    private var admitted = false
    private var failure: Error?
    private var transactionDepth = 0

    init(database: EncryptedSettingsDatabase) throws {
        self.database = database
        let row = try database.read()
        revision = row?.revision
        values = try row.map { try JSONDecoder().decode(Archive.self, from: $0.data).values } ?? [:]
        for data in values.values { _ = try Self.decode(data) }
        super.init(suiteName: "local.rota.encrypted-adapter")!
    }
    private static func encode(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private static func decode(_ data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
    override func object(forKey key: String) -> Any? {
        stateLock.lock(); let data = values[key], fallback = registered[key]; stateLock.unlock()
        return data.flatMap { try? Self.decode($0) } ?? fallback
    }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    override func url(forKey key: String) -> URL? { string(forKey: key).flatMap(URL.init(string:)) }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: URL?, forKey key: String) { set(value?.absoluteString as Any?, forKey: key) }
    override func set(_ value: Any?, forKey key: String) {
        do {
            let encoded = try value.map(Self.encode)
            stateLock.lock()
            values[key] = encoded
            pending = values
            let start = !admitted && transactionDepth == 0
            if start {
                admitted = true
                writer.async { [self] in drain() }
            }
            stateLock.unlock()
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
        } catch {
            stateLock.lock(); failure = error; stateLock.unlock()
        }
    }
    override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }
    func transaction(_ operation: () -> Void) {
        stateLock.withLock { transactionDepth += 1 }
        operation()
        stateLock.lock()
        transactionDepth -= 1
        if transactionDepth == 0, pending != nil, !admitted {
            admitted = true
            writer.async { [self] in drain() }
        }
        stateLock.unlock()
    }
    override func register(defaults: [String: Any]) {
        stateLock.lock(); registered.merge(defaults) { _, new in new }; stateLock.unlock()
    }
    override func dictionaryRepresentation() -> [String: Any] {
        stateLock.lock(); let snapshot = values, fallback = registered; stateLock.unlock()
        return snapshot.reduce(into: fallback) { output, entry in output[entry.key] = try? Self.decode(entry.value) }
    }
    private func drain() {
        while true {
            stateLock.lock()
            guard transactionDepth == 0, let next = pending else { admitted = false; stateLock.unlock(); return }
            pending = nil
            let expected = revision
            stateLock.unlock()
            do {
                let encoded = try JSONEncoder().encode(Archive(values: next))
                let written = try database.save(encoded, expectedRevision: expected)
                stateLock.lock(); revision = written; failure = nil; stateLock.unlock()
            } catch {
                stateLock.lock()
                // Preserve the newest unsaved state. Never replace it with stale disk data.
                if pending == nil { pending = next }
                failure = error; admitted = false
                stateLock.unlock()
                return
            }
        }
    }
    /// An upload/shutdown barrier: never upload state that failed local persistence.
    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateLock.lock()
            writer.async { [self] in
                stateLock.lock(); let needsDrain = !admitted && pending != nil; stateLock.unlock()
                if needsDrain { drain() }
                stateLock.lock(); let error = failure; stateLock.unlock()
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
            stateLock.unlock()
        }
    }
    /// Transactional migration preparation. Caller removes the old plaintext
    /// copies only after this completes and verifies a reopen/read of this store.
    func importLegacy(_ source: [String: Any]) async throws {
        // Validate the entire import before making any memory/disk changes.
        let encoded = try source.mapValues(Self.encode)
        stateLock.withLock {
            values.merge(encoded) { _, new in new }
            pending = values
            if !admitted {
                admitted = true
                writer.async { [self] in drain() }
            }
        }
        try await flush()
    }
    func importLegacySynchronously(_ source: [String: Any]) throws {
        let encoded = try source.mapValues(Self.encode)
        values.merge(encoded) { _, new in new }
        revision = try database.save(JSONEncoder().encode(Archive(values: values)), expectedRevision: revision)
    }
}
