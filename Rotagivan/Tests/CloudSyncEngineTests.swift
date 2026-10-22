import Foundation

/// An in-memory stand-in for the settings endpoint: one record, CAS writes.
final class FakeCloud: @unchecked Sendable {
    private let lock = NSLock()
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    var ciphertext: String?
    var revision: Int64 = 0
    var fetches = 0, writes = 0, conditionalHits = 0
    /// Runs once right before the next CAS; lets a test interleave a competing write.
    var beforeWrite: (() -> Void)?
    var transport: CloudSyncTransport {
        CloudSyncTransport(fetch: { known in
            self.locked {
                self.fetches += 1
                if let known, known == self.revision { self.conditionalHits += 1; return CloudSettingsRecord(ciphertext: nil, revision: known, unchanged: true) }
                return CloudSettingsRecord(ciphertext: self.ciphertext, revision: self.revision)
            }
        }, compareAndSwap: { wire, base in
            let hook: (() -> Void)? = self.locked { let hook = self.beforeWrite; self.beforeWrite = nil; return hook }
            hook?()
            return try self.locked {
                self.writes += 1
                guard base == self.revision else { throw CloudSyncFailure.raced }
                self.ciphertext = wire; self.revision += 1
                return CloudSettingsRecord(ciphertext: wire, revision: self.revision)
            }
        })
    }
    func store(_ document: SyncDocument, master: Data, email: String) throws {
        lock.lock(); defer { lock.unlock() }
        revision += 1
        ciphertext = try SyncCrypto.seal(try SyncDocument.encode(document), master: master, email: email, revision: revision)
    }
}

extension AppConfiguration { var speed: Double { (settings.normal.cursorSpeed * 1000).rounded() / 10 } }

@main struct CloudSyncEngineTests {
    static func check(_ value: Bool, _ message: String = "", line: UInt = #line) { precondition(value, "line \(line): " + message) }
    static func main() async throws {
        let email = "pair@example.com"
        let master = try SyncCrypto.masterKey(email: email, password: "a long fixture password", rounds: 1_000)
        let base = try AppConfiguration.parse(try String(contentsOfFile: "Rotagivan/DefaultConfiguration.yaml", encoding: .utf8))
        func variant(_ speed: Double) -> AppConfiguration { var copy = base; copy.settings.normal.cursorSpeed = speed / 100; return copy }
        let cloud = FakeCloud()
        final class Clock: @unchecked Sendable { var value = 1_000.0 }
        let clockBox = Clock()
        var clock: Double { get { clockBox.value } set { clockBox.value = newValue } }
        let macA = CloudSyncEngine(master: master, email: email, device: "Mac A", transport: cloud.transport, now: { clockBox.value })
        let macB = CloudSyncEngine(master: master, email: email, device: "Mac B", transport: cloud.transport, now: { clockBox.value })

        // 1. First Mac uploads into an empty account.
        var stateA = CloudSyncState()
        var (outcome, next) = try await macA.reconcile(local: variant(1.0), secrets: ["OPENROUTER_API_KEY": "sk-fixture-secret-value-one"], state: stateA)
        guard case .uploaded(let revision) = outcome, revision == 1 else { fatalError("expected upload, got \(outcome)") }
        stateA = next
        check(stateA.revision == 1 && !stateA.fingerprint.isEmpty && stateA.localEditedAt == 0)
        check(cloud.ciphertext!.hasPrefix(SyncCrypto.wirePrefix) && !cloud.ciphertext!.contains("sk-fixture-secret-value-one"))

        // 2. Nothing changed anywhere: one conditional fetch, no body, no write.
        let writesBefore = cloud.writes, hitsBefore = cloud.conditionalHits
        (outcome, next) = try await macA.reconcile(local: variant(1.0), secrets: ["OPENROUTER_API_KEY": "sk-fixture-secret-value-one"], state: stateA)
        guard case .upToDate = outcome else { fatalError("expected upToDate") }
        check(cloud.writes == writesBefore && cloud.conditionalHits == hitsBefore + 1)
        stateA = next

        // 3. Second Mac with nothing of its own downloads the document, secrets included.
        var stateB = CloudSyncState()
        (outcome, next) = try await macB.reconcile(local: base, secrets: [:], state: stateB)
        guard case .downloaded(let document, let rev) = outcome, rev == 1 else { fatalError("expected download") }
        check(document.configuration.speed == 1.0 && document.secrets == ["OPENROUTER_API_KEY": "sk-fixture-secret-value-one"] && document.editedBy == "Mac A")
        stateB = next
        check(stateB.revision == 1 && stateB.fingerprint == stateA.fingerprint)

        // 4. Mac B edits; Mac A (unchanged) picks it up.
        clock = 2_000
        (outcome, next) = try await macB.reconcile(local: variant(2.0), secrets: document.secrets, state: stateB)
        guard case .uploaded(2) = outcome else { fatalError("expected upload 2") }
        stateB = next
        (outcome, next) = try await macA.reconcile(local: variant(1.0), secrets: ["OPENROUTER_API_KEY": "sk-fixture-secret-value-one"], state: stateA)
        guard case .downloaded(let fromB, 2) = outcome, fromB.configuration.speed == 2.0 else { fatalError("expected download of B's edit") }
        stateA = next

        // 5. Both edit. B's edit is later than A's unsynced one: B wins on A.
        clock = 3_000
        var pendingA = stateA; pendingA.localEditedAt = 3_000      // A edited at t=3000 while offline
        clock = 3_500
        (outcome, next) = try await macB.reconcile(local: variant(3.5), secrets: fromB.secrets, state: stateB)
        guard case .uploaded(3) = outcome else { fatalError("expected upload 3") }
        stateB = next
        (outcome, next) = try await macA.reconcile(local: variant(3.0), secrets: fromB.secrets, state: pendingA)
        guard case .remoteWonConflict(let winner, 3) = outcome, winner.configuration.speed == 3.5 else { fatalError("expected remote win, got \(outcome)") }
        stateA = next
        check(stateA.localEditedAt == 0 && stateA.revision == 3)

        // 6. Both edit, A's edit is the later one: A wins and uploads over B.
        var lateA = stateA; lateA.localEditedAt = 5_000
        clock = 4_000
        (outcome, next) = try await macB.reconcile(local: variant(4.0), secrets: fromB.secrets, state: stateB)
        guard case .uploaded(4) = outcome else { fatalError("expected upload 4") }
        stateB = next
        clock = 5_000
        (outcome, next) = try await macA.reconcile(local: variant(5.0), secrets: fromB.secrets, state: lateA)
        guard case .localWonConflict(5) = outcome else { fatalError("expected local win, got \(outcome)") }
        stateA = next
        (outcome, next) = try await macB.reconcile(local: variant(4.0), secrets: fromB.secrets, state: stateB)
        guard case .downloaded(let fromA, 5) = outcome, fromA.configuration.speed == 5.0, fromA.editedAt == 5_000 else { fatalError("B must receive A's win") }
        stateB = next

        // 7. A lost CAS race is retried on top of the competing write.
        cloud.beforeWrite = { try! cloud.store(SyncDocument(editedAt: 5_500, editedBy: "Mac C", configuration: variant(5.5), secrets: [:]), master: master, email: email) }
        clock = 6_000
        var editedA = stateA; editedA.localEditedAt = 6_000
        (outcome, next) = try await macA.reconcile(local: variant(6.0), secrets: fromB.secrets, state: editedA)
        guard case .localWonConflict(7) = outcome else { fatalError("expected retry after race, got \(outcome)") }
        stateA = next
        check(cloud.revision == 7)

        // 8. Rollback: a server returning an older revision than this Mac synced is refused.
        var rolledBack = stateA; rolledBack.revision = 99
        do { _ = try await macA.reconcile(local: variant(6.0), secrets: fromB.secrets, state: rolledBack); fatalError("rollback accepted") }
        catch CloudSyncFailure.rollback {}

        // 9. An unreadable cloud copy (plaintext from an older build, or sealed under a
        //    different password) is replaced by this Mac's settings, with a reason.
        let legacy = FakeCloud()
        legacy.ciphertext = "settings:\n  enabled: true\n"; legacy.revision = 3
        let legacyEngine = CloudSyncEngine(master: master, email: email, device: "Mac A", transport: legacy.transport, now: { clockBox.value })
        (outcome, next) = try await legacyEngine.reconcile(local: variant(1.0), secrets: [:], state: CloudSyncState())
        guard case .replacedUnreadable(4, let reason) = outcome, reason.contains("older Rotagivan") else { fatalError("expected legacy replacement, got \(outcome)") }
        check(next.revision == 4)
        let otherKey = try SyncCrypto.masterKey(email: email, password: "a different fixture password", rounds: 1_000)
        let foreign = FakeCloud()
        try foreign.store(SyncDocument(editedAt: 1, editedBy: "Elsewhere", configuration: variant(9), secrets: [:]), master: otherKey, email: email)
        let foreignEngine = CloudSyncEngine(master: master, email: email, device: "Mac A", transport: foreign.transport, now: { clockBox.value })
        (outcome, next) = try await foreignEngine.reconcile(local: variant(1.0), secrets: [:], state: CloudSyncState())
        guard case .replacedUnreadable(2, let why) = outcome, why.contains("password") else { fatalError("expected foreign-key replacement, got \(outcome)") }
        // Documents that decode but fail validation are also unreadable, never applied.
        var invalid = variant(1.0); invalid.formatVersion = 2
        let broken = FakeCloud()
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(SyncDocument(editedAt: 1, editedBy: "x", configuration: invalid, secrets: [:]))
            broken.ciphertext = try SyncCrypto.seal(data, master: master, email: email, revision: 1); broken.revision = 1
        }
        let brokenEngine = CloudSyncEngine(master: master, email: email, device: "Mac A", transport: broken.transport, now: { clockBox.value })
        (outcome, next) = try await brokenEngine.reconcile(local: variant(1.0), secrets: [:], state: CloudSyncState())
        guard case .replacedUnreadable = outcome else { fatalError("invalid document must be replaced, got \(outcome)") }
        print("Cloud sync engine passed: first upload, conditional no-op, download, two-Mac edits, last-edit-wins both ways, CAS retry, rollback refusal, unreadable replacement.")
    }
}
