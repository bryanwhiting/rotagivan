import Foundation

@main struct EncryptedPreferencesTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("rota-private-preferences-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 27, count: 32)
        let url = root.appendingPathComponent("settings.sqlite")
        let db = try EncryptedSettingsDatabase(url: url, master: key, scope: "fixture-device")
        let prefs = try EncryptedPreferences(database: db)
        let bookmark = "https://secret-project.example.test/bookmark"
        try await prefs.importLegacy(["settings.v1": Data(bookmark.utf8), "shortcut.hold": true,
            "profiles": ["Work": "Sensitive profile"], "counter": 14])
        prefs.set("fixture-openai-key", forKey: "secrets.openai")
        prefs.set(0.75, forKey: "motion")
        prefs.set(false, forKey: "shortcut.hold")
        for i in 0..<100 { prefs.set(i, forKey: "slider") }
        try await prefs.flush()
        precondition(prefs.data(forKey: "settings.v1") == Data(bookmark.utf8))
        precondition(!prefs.bool(forKey: "shortcut.hold"))
        precondition(prefs.integer(forKey: "slider") == 99)
        precondition(prefs.double(forKey: "motion") == 0.75)
        let reopened = try EncryptedPreferences(database:
            EncryptedSettingsDatabase(url: url, master: key, scope: "fixture-device"))
        precondition(reopened.string(forKey: "secrets.openai") == "fixture-openai-key")
        precondition(reopened.data(forKey: "settings.v1") == Data(bookmark.utf8))
        precondition(reopened.integer(forKey: "slider") == 99)
        do {
            try await prefs.importLegacy(["must-not-import": "partial", "invalid": NSObject()])
            preconditionFailure("Invalid migration must fail before partial updates")
        } catch {}
        precondition(prefs.object(forKey: "must-not-import") == nil)
        prefs.removeObject(forKey: "secrets.openai")
        try await prefs.flush()
        let raw = try Data(contentsOf: url)
        for text in [bookmark, "fixture-openai-key", "Sensitive profile"] {
            precondition(raw.range(of: Data(text.utf8)) == nil)
        }
        precondition(UserDefaults(suiteName: "local.rotagivan.encrypted-adapter")?.data(forKey: "settings.v1") == nil,
            "Adapter must not create a plaintext defaults shadow")
        print("Encrypted preference adapter passed: literal migration, typed values, coalesced edits, flush/reopen, key removal, no plaintext shadow. Dummy fixtures only.")
    }
}
