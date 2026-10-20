import CryptoKit
import Foundation
import SQLite3

@main struct EncryptedSettingsCoreTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value) }
        let key = Data(repeating: 17, count: 32)
        let secret = Data("bookmark=https://private.example.test/project;OPENAI=dummy-private-key".utf8)
        let sealed = try SettingsCipherEnvelope.seal(secret, master: key, scope: "account-one", purpose: "cloud", revision: 7)
        check(try sealed.open(master: key, scope: "account-one", purpose: "cloud") == secret)
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Must reject invalid encrypted state") } catch {}
        }
        rejects { _ = try sealed.open(master: key, scope: "account-two", purpose: "cloud") }
        rejects { _ = try sealed.open(master: key, scope: "account-one", purpose: "local") }
        rejects { _ = try sealed.open(master: Data(repeating: 18, count: 32), scope: "account-one", purpose: "cloud") }
        rejects { _ = try SettingsCipherEnvelope(version: 1, revision: 8, ciphertext: sealed.ciphertext).open(master: key, scope: "account-one", purpose: "cloud") }
        var altered = sealed.ciphertext; altered[altered.startIndex] ^= 1
        rejects { _ = try SettingsCipherEnvelope(version: 1, revision: 7, ciphertext: altered).open(master: key, scope: "account-one", purpose: "cloud") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rota-encrypted-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.sqlite")
        let db = try EncryptedSettingsDatabase(url: url, master: key, scope: "local-device")
        check(try db.read() == nil)
        check(try db.save(secret, expectedRevision: nil) == 1)
        rejects { _ = try db.save(Data("stale".utf8), expectedRevision: nil) }
        check(try db.read()?.data == secret)
        let raw = try Data(contentsOf: url)
        precondition(raw.range(of: Data("private.example.test".utf8)) == nil)
        precondition(raw.range(of: Data("dummy-private-key".utf8)) == nil)
        rejects { _ = try EncryptedSettingsDatabase(url: url, master: Data(repeating: 18, count: 32), scope: "local-device") }
        let reopened = try EncryptedSettingsDatabase(url: url, master: key, scope: "local-device")
        check(try reopened.read()?.data == secret)
        check(try reopened.save(secret, expectedRevision: 1) == 2)
        rejects { _ = try db.save(secret, expectedRevision: 1) }
        let link = root.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        rejects { _ = try EncryptedSettingsDatabase(url: link, master: key, scope: "local-device") }
        let foreign = root.appendingPathComponent("unrelated.sqlite")
        var handle: OpaquePointer?
        precondition(sqlite3_open(foreign.path, &handle) == SQLITE_OK)
        precondition(sqlite3_exec(handle, "CREATE TABLE keep_me(value TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let originalForeign = try Data(contentsOf: foreign)
        rejects { _ = try EncryptedSettingsDatabase(url: foreign, master: key, scope: "local-device") }
        check(try Data(contentsOf: foreign) == originalForeign)
        var work = EncryptedSettingsJournal(), home = EncryptedSettingsJournal()
        try work.set(Data("work-bookmark".utf8), for: "bookmark", deviceID: "work")
        try home.set(Data("home-hotkey".utf8), for: "hotkey", deviceID: "home")
        var a = work, b = home
        try a.merge(home); try b.merge(work)
        precondition(a == b && a.fields.count == 2)
        try a.set(nil, for: "bookmark", deviceID: "work")
        try b.merge(a); try a.merge(b)
        precondition(a == b && b.fields["bookmark"]?.value == nil)
        var first = EncryptedSettingsJournal(), second = EncryptedSettingsJournal()
        try first.set(Data("one".utf8), for: "same", deviceID: "a")
        try second.set(Data("two".utf8), for: "same", deviceID: "b")
        var one = first, two = second
        try one.merge(second); try two.merge(first)
        precondition(one == two && one.fields["same"]?.value == Data("two".utf8))
        // Whoever edited last wins, even against a higher logical counter and
        // device ID; stamps from older builds carry no time and lose to any edit.
        var late = EncryptedSettingsJournal(), early = EncryptedSettingsJournal()
        try late.set(Data("later".utf8), for: "same", deviceID: "aaa", at: Date(timeIntervalSince1970: 2_000))
        try early.set(Data("x".utf8), for: "other", deviceID: "zzz", at: Date(timeIntervalSince1970: 500))
        try early.set(Data("earlier".utf8), for: "same", deviceID: "zzz", at: Date(timeIntervalSince1970: 1_000))
        var lateMerged = late, earlyMerged = early
        try lateMerged.merge(early); try earlyMerged.merge(late)
        precondition(lateMerged == earlyMerged && lateMerged.fields["same"]?.value == Data("later".utf8))
        precondition(lateMerged.latestEdit == 2_000 && lateMerged.counter == 2)
        let legacyJSON = Data(#"{"fields":{"same":{"stamp":{"counter":9,"deviceID":"zzz"},"value":"b2xk"}},"counter":9}"#.utf8)
        var legacy = try JSONDecoder().decode(EncryptedSettingsJournal.self, from: legacyJSON)
        precondition(legacy.fields["same"]?.stamp.editedAt == 0 && legacy.latestEdit == 0)
        try legacy.merge(late)
        precondition(legacy.fields["same"]?.value == Data("later".utf8) && legacy.counter == 9)
        let reencoded = try JSONDecoder().decode(EncryptedSettingsJournal.self, from: JSONEncoder().encode(legacy))
        precondition(reencoded == legacy, "Timestamps round-trip")
        // An authenticated but inconsistent peer must not partly mutate state.
        var inconsistent = EncryptedSettingsJournal()
        try inconsistent.set(Data("different".utf8), for: "same", deviceID: "a")
        let unchanged = first
        rejects { try first.merge(inconsistent) }
        precondition(first == unchanged)
        print("Encrypted core passed: authenticated scope/purpose/revision, tamper/wrong-key rejection, encrypted SQLite/reopen, stale-write rejection, convergent fields and deletion tombstones. Dummy data only; no Keychain/network/microphone.")
    }
}
