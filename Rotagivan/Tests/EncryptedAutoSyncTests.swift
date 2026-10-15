import Foundation

private actor FakeEncryptedCloud {
    var record = EncryptedCloudSnapshot(ciphertext: nil, revision: 0)
    var offline = false
    var races = 0
    var writes = 0
    var fetchDelay: UInt64 = 0
    var putDelay: UInt64 = 0
    func fetch() async throws -> EncryptedCloudSnapshot {
        if offline { throw URLError(.notConnectedToInternet) }
        if fetchDelay > 0 { try await Task.sleep(nanoseconds: fetchDelay) }
        return record
    }
    func put(_ wire: String, expected: Int64) async throws -> EncryptedCloudSnapshot {
        if putDelay > 0 { try await Task.sleep(nanoseconds: putDelay) }
        if offline { throw URLError(.notConnectedToInternet) }
        if races > 0 { races -= 1; throw EncryptedSyncFailure.raced }
        guard expected == record.revision else { throw EncryptedSyncFailure.raced }
        record = EncryptedCloudSnapshot(ciphertext: wire, revision: expected + 1)
        writes += 1
        return record
    }
    func configure(offline: Bool = false, races: Int = 0, fetchDelay: UInt64 = 0, putDelay: UInt64 = 0) {
        self.offline = offline; self.races = races
        self.fetchDelay = fetchDelay; self.putDelay = putDelay
    }
    func replace(_ value: EncryptedCloudSnapshot) { record = value }
}

private final class MemoryPersistence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = EncryptedSyncState()
    var rejects = false // test only, no concurrent mutation
    func save(_ next: EncryptedSyncState) throws {
        try lock.withLock {
            if rejects { throw EncryptedSettingsError.databaseFailure }
            value = next
        }
    }
    func read() -> EncryptedSyncState { lock.withLock { value } }
}

@main struct EncryptedAutoSyncTests {
    static func main() async throws {
        let cloud = FakeEncryptedCloud()
        let transport = EncryptedSyncTransport(fetch: { try await cloud.fetch() },
            compareAndSwap: { try await cloud.put($0, expected: $1) })
        let master = Data(repeating: 45, count: 32)
        func device(_ id: String, disk: MemoryPersistence, scope: String = "account:vault",
                    state: EncryptedSyncState? = nil) throws -> EncryptedAutoSync {
            try EncryptedAutoSync(key: master, scope: scope, deviceID: id, state: state ?? disk.read(),
                transport: transport, persist: { try disk.save($0) }, validate: { _ in })
        }
        func rejected(_ operation: () async throws -> Void) async {
            do { try await operation(); preconditionFailure("Expected rejection") } catch {}
        }
        let workDisk = MemoryPersistence(), homeDisk = MemoryPersistence()
        let work = try device("work", disk: workDisk), home = try device("home", disk: homeDisk)
        try await work.edit(["bookmark": Data("https://private.test/bookmark".utf8)])
        try await home.edit(["OpenAI": Data("dummy-openai-secret".utf8)])
        async let workSync = work.syncNow()
        async let homeSync = home.syncNow()
        _ = try await (workSync, homeSync)
        _ = try await work.syncNow(); _ = try await home.syncNow()
        precondition(workDisk.read().journal == homeDisk.read().journal)
        let encrypted = try await cloud.fetch()
        precondition(!encrypted.ciphertext!.contains("private.test"))
        precondition(!encrypted.ciphertext!.contains("dummy-openai-secret"))
        await cloud.configure(offline: true)
        try await work.edit(["bookmark": nil])
        await rejected { _ = try await work.syncNow() }
        precondition(workDisk.read().journal.fields["bookmark"]?.value == nil)
        await cloud.configure(races: 2)
        _ = try await work.syncNow(); _ = try await home.syncNow()
        precondition(workDisk.read().journal == homeDisk.read().journal)

        // Wrong account cannot decrypt or publish into another account's store.
        let other = try device("other", disk: MemoryPersistence(), scope: "different-account:vault")
        await rejected { _ = try await other.syncNow() }
        await other.stop()

        // Restart retains revision floor. A server replay never overwrites it.
        let current = try await cloud.fetch()
        await cloud.replace(encrypted)
        let restart = try device("work", disk: workDisk)
        await rejected { _ = try await restart.syncNow() }
        await restart.stop(); await cloud.replace(current)

        // Edits made while GET/PUT awaits survive the remote acknowledgement.
        await cloud.configure(fetchDelay: 20_000_000, putDelay: 80_000_000)
        try await work.edit(["during": Data("first".utf8)])
        let inFlight = Task { try await work.syncNow() }
        try await Task.sleep(nanoseconds: 40_000_000)
        try await work.edit(["during": Data("second".utf8)])
        _ = try await inFlight.value
        precondition(workDisk.read().journal.fields["during"]?.value == Data("second".utf8))
        await cloud.configure(); _ = try await home.syncNow()
        precondition(homeDisk.read().journal.fields["during"]?.value == Data("second".utf8))

        // Stop invalidates a response already fetched under an old account.
        let stoppedDisk = MemoryPersistence(), stopped = try device("stopped", disk: stoppedDisk)
        await cloud.configure(fetchDelay: 60_000_000)
        let oldAccount = Task { try await stopped.syncNow() }
        try await Task.sleep(nanoseconds: 10_000_000)
        await stopped.stop()
        await rejected { _ = try await oldAccount.value }
        precondition(stoppedDisk.read() == EncryptedSyncState())
        await cloud.configure()

        // Persistence failure rejects an edit without admitting it to memory.
        let failedDisk = MemoryPersistence(), failed = try device("failed", disk: failedDisk)
        failedDisk.rejects = true
        await rejected { try await failed.edit(["private": Data("must-not-upload".utf8)]) }
        let failedState = await failed.snapshot()
        precondition(failedState == EncryptedSyncState())
        await failed.stop()

        // Legacy plaintext cloud records require explicit verified migration.
        await cloud.replace(EncryptedCloudSnapshot(ciphertext: "settings: plaintext", revision: 1))
        let legacy = try device("legacy", disk: MemoryPersistence())
        await rejected { _ = try await legacy.syncNow() }
        await legacy.stop(); await work.stop(); await home.stop()
        print("Encrypted auto-sync core passed: concurrent CAS reconciliation, offline edits/deletions, ciphertext-only wire, account isolation, persisted rollback floor, edits during GET/PUT, stopped response rejection, failed local write, legacy migration gate. Mock data only; app integration is not verified.")
    }
}
