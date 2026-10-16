import Foundation

private actor FakeEncryptedCloud {
    var record = EncryptedCloudSnapshot(ciphertext: nil, revision: 0)
    var offline = false
    var races = 0
    var writes = 0
    var bodies = 0
    var unchangedReplies = 0
    var fetchDelay: UInt64 = 0
    var putDelay: UInt64 = 0
    func fetch(since: Int64?) async throws -> EncryptedCloudSnapshot {
        if offline { throw URLError(.notConnectedToInternet) }
        if fetchDelay > 0 { try await Task.sleep(nanoseconds: fetchDelay) }
        // Model the server's If-None-Match: a matching revision carries no body.
        if let since, since == record.revision {
            unchangedReplies += 1
            return EncryptedCloudSnapshot(ciphertext: nil, revision: record.revision, unchanged: true)
        }
        bodies += 1
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
        let transport = EncryptedSyncTransport(fetch: { try await cloud.fetch(since: $0) },
            compareAndSwap: { try await cloud.put($0, expected: $1) })
        let master = Data(repeating: 45, count: 32)
        func device(_ id: String, disk: MemoryPersistence, scope: String = "account:vault",
                    state: EncryptedSyncState? = nil,
                    validate: @escaping @Sendable (EncryptedSettingsJournal) throws -> Void = { _ in }) throws -> EncryptedAutoSync {
            try EncryptedAutoSync(key: master, scope: scope, deviceID: id, state: state ?? disk.read(),
                transport: transport, persist: { try disk.save($0) }, validate: validate)
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
        let encrypted = try await cloud.fetch(since: nil)
        precondition(!encrypted.ciphertext!.contains("private.test"))
        precondition(!encrypted.ciphertext!.contains("dummy-openai-secret"))

        // An idle poll after convergence is a conditional fetch: no body, no write.
        let bodiesBefore = await cloud.bodies, writesBefore = await cloud.writes
        let idle = try await work.syncNow()
        let bodiesAfter = await cloud.bodies, writesAfter = await cloud.writes, unchanged = await cloud.unchangedReplies
        precondition(idle == .synchronized && bodiesAfter == bodiesBefore && writesAfter == writesBefore && unchanged > 0,
                     "Unchanged cloud must be confirmed without transferring ciphertext")
        let settled = await work.hasPendingEdits
        precondition(!settled)

        await cloud.configure(offline: true)
        try await work.edit(["bookmark": nil])
        let pending = await work.hasPendingEdits
        precondition(pending)
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
        let current = try await cloud.fetch(since: nil)
        await cloud.replace(encrypted)
        let restart = try device("work", disk: workDisk)
        await rejected { _ = try await restart.syncNow() }
        await restart.stop(); await cloud.replace(current)

        // A forged "unchanged" reply for a different revision is rejected.
        let forging = EncryptedSyncTransport(fetch: { since in
            EncryptedCloudSnapshot(ciphertext: nil, revision: (since ?? 0) + 5, unchanged: true)
        }, compareAndSwap: { _, _ in preconditionFailure("No write after a rejected fetch") })
        let forged = try EncryptedAutoSync(key: master, scope: "account:vault", deviceID: "work", state: workDisk.read(),
            transport: forging, persist: { _ in }, validate: { _ in })
        await rejected { _ = try await forged.syncNow() }
        await forged.stop()

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

        // A delete on one Mac racing an edit on another can merge into a document
        // that no longer validates. Sync must converge on the cloud copy instead
        // of failing every cycle forever on both Macs.
        let fragmentRule: @Sendable (EncryptedSettingsJournal) throws -> Void = { journal in
            if let name = journal.fields["profile/name"], name.value == nil, journal.fields["profile/speed"]?.value != nil {
                throw EncryptedSettingsError.invalidEnvelope
            }
        }
        let deleterDisk = MemoryPersistence(), editorDisk = MemoryPersistence()
        let deleter = try device("deleter", disk: deleterDisk, validate: fragmentRule)
        let editor = try device("editor", disk: editorDisk, validate: fragmentRule)
        try await deleter.edit(["profile/name": Data("Travel".utf8), "profile/speed": Data("1".utf8)])
        _ = try await deleter.syncNow(); _ = try await editor.syncNow()
        precondition(deleterDisk.read().journal == editorDisk.read().journal)
        try await deleter.edit(["profile/name": nil, "profile/speed": nil])
        for value in ["2", "3", "4"] { try await editor.edit(["profile/speed": Data(value.utf8)]) }
        _ = try await deleter.syncNow()
        let conflicted = try await editor.syncNow()
        precondition(conflicted == .synchronizedDroppingLocalConflict)
        precondition(editorDisk.read().journal == deleterDisk.read().journal, "Both Macs converge on the deletion")
        precondition(editorDisk.read().journal.fields["profile/speed"]?.value == nil)
        let clock = editorDisk.read().journal.counter
        try await editor.edit(["profile/name": Data("Travel again".utf8)])
        precondition(editorDisk.read().journal.fields["profile/name"]!.stamp.counter > clock, "Later edits still outrank everything seen")
        let editorAgain = try await editor.syncNow(), deleterAgain = try await deleter.syncNow()
        precondition(editorAgain == .synchronized && deleterAgain == .synchronized)
        precondition(deleterDisk.read().journal.fields["profile/name"]?.value == Data("Travel again".utf8))
        await deleter.stop(); await editor.stop()

        // Legacy plaintext cloud records require explicit verified migration.
        await cloud.replace(EncryptedCloudSnapshot(ciphertext: "settings: plaintext", revision: 1))
        let legacy = try device("legacy", disk: MemoryPersistence())
        await rejected { _ = try await legacy.syncNow() }
        await legacy.stop(); await work.stop(); await home.stop()
        print("Encrypted auto-sync core passed: concurrent CAS reconciliation, conditional idle polls, offline edits/deletions, ciphertext-only wire, account isolation, persisted rollback floor, forged 304 rejection, edits during GET/PUT, stopped response rejection, failed local write, invalid-merge fallback, legacy migration gate. Mock data only; app integration is not verified.")
    }
}
