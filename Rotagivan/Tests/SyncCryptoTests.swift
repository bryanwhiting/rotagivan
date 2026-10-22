import Foundation

@main struct SyncCryptoTests {
    static func check(_ value: Bool, _ message: String = "", line: UInt = #line) { precondition(value, "line \(line): " + message) }
    static func main() throws {
        // Key derivation is deterministic per (email, password) and case-insensitive on email.
        let a = try SyncCrypto.masterKey(email: "Someone@Example.com ", password: "correct horse battery", rounds: 2_000)
        let b = try SyncCrypto.masterKey(email: "someone@example.com", password: "correct horse battery", rounds: 2_000)
        let c = try SyncCrypto.masterKey(email: "someone@example.com", password: "correct horse battery!", rounds: 2_000)
        check(a == b && a != c && a.count == 32)
        do { _ = try SyncCrypto.masterKey(email: "x@y.z", password: "short", rounds: 10); fatalError("weak password accepted") }
        catch SyncCrypto.Failure.weakPassword {}
        do { _ = try SyncCrypto.masterKey(email: "not-an-email", password: "correct horse battery", rounds: 10); fatalError("bad email accepted") }
        catch SyncCrypto.Failure.badEmail {}
        // The login secret the server sees reveals nothing about the settings key and is a valid "password".
        let secret = SyncCrypto.loginSecret(master: a)
        check(secret.count == 64 && secret.allSatisfy { $0.isHexDigit } && secret != a.map({ String(format: "%02x", $0) }).joined())
        check(SyncCrypto.loginSecret(master: a) == secret && SyncCrypto.loginSecret(master: c) != secret)

        // Envelope round trip, bound to email and revision.
        let email = "someone@example.com"
        let plaintext = Data("{\"hello\":\"world\"}".utf8)
        let wire = try SyncCrypto.seal(plaintext, master: a, email: email, revision: 7)
        check(wire.hasPrefix(SyncCrypto.wirePrefix) && SyncCrypto.isEncrypted(wire))
        check(!wire.contains("hello"))
        check(try SyncCrypto.open(wire, master: a, email: email, revision: 7) == plaintext)
        do { _ = try SyncCrypto.open(wire, master: c, email: email, revision: 7); fatalError("wrong key opened") }
        catch SyncCrypto.Failure.wrongKey {}
        do { _ = try SyncCrypto.open(wire, master: a, email: email, revision: 8); fatalError("replayed revision opened") }
        catch SyncCrypto.Failure.unreadable {}
        do { _ = try SyncCrypto.open(wire, master: a, email: "other@example.com", revision: 7); fatalError("other account opened") }
        catch SyncCrypto.Failure.wrongKey {}
        // Tampering with the ciphertext is detected.
        var envelope = try JSONDecoder().decode(SyncCrypto.Envelope.self, from: Data(base64Encoded: String(wire.dropFirst(SyncCrypto.wirePrefix.count)))!)
        envelope.sealed[envelope.sealed.count - 1] ^= 0x01
        let tampered = SyncCrypto.wirePrefix + (try JSONEncoder().encode(envelope)).base64EncodedString()
        do { _ = try SyncCrypto.open(tampered, master: a, email: email, revision: 7); fatalError("tampered opened") }
        catch SyncCrypto.Failure.wrongKey {}
        // Newer formats are reported as such; plaintext and the old journal are unreadable.
        envelope = try JSONDecoder().decode(SyncCrypto.Envelope.self, from: Data(base64Encoded: String(wire.dropFirst(SyncCrypto.wirePrefix.count)))!)
        envelope.version = 9
        let future = SyncCrypto.wirePrefix + (try JSONEncoder().encode(envelope)).base64EncodedString()
        do { _ = try SyncCrypto.open(future, master: a, email: email, revision: 7); fatalError("future opened") }
        catch SyncCrypto.Failure.unsupported(let version) { check(version == 9) }
        do { _ = try SyncCrypto.open("settings:\n  enabled: true\n", master: a, email: email, revision: 1); fatalError("plaintext opened") }
        catch SyncCrypto.Failure.unreadable {}
        do { _ = try SyncCrypto.open(SyncCrypto.wirePrefix + "AAAA", master: a, email: email, revision: 1); fatalError("garbage opened") }
        catch SyncCrypto.Failure.unreadable {}
        do { _ = try SyncCrypto.seal(Data(count: SyncCrypto.maximumBytes + 1), master: a, email: email, revision: 1); fatalError("oversize sealed") }
        catch SyncCrypto.Failure.tooLarge {}

        // Secrets: cloud mode serves the synced copy; otherwise ~/.env only.
        let suite = "Rotagivan.SyncCrypto." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = SyncSecrets.defaults
        SyncSecrets.defaults = { defaults }
        defer { SyncSecrets.defaults = previous }
        check(SyncSecrets.isValidName("OPENROUTER_API_KEY") && !SyncSecrets.isValidName("lowercase") && !SyncSecrets.isValidName(""))
        SyncSecrets.store(["OPENROUTER_API_KEY": "sk-fixture"], defaults)
        check(SyncSecrets.stored(defaults) == ["OPENROUTER_API_KEY": "sk-fixture"])
        let environment = SyncSecrets.environmentValue("OPENROUTER_API_KEY")
        defaults.set(SyncMode.cloud.rawValue, forKey: SyncSecrets.modeKey)
        check(try SyncSecrets.value("OPENROUTER_API_KEY") == "sk-fixture")
        defaults.set(SyncMode.local.rawValue, forKey: SyncSecrets.modeKey)
        do { check(try SyncSecrets.value("OPENROUTER_API_KEY") == environment, "local mode reads ~/.env") }
        catch { check(environment == nil) }
        defaults.removeObject(forKey: SyncSecrets.modeKey)
        do { check(try SyncSecrets.value("OPENROUTER_API_KEY") == environment, "no mode reads ~/.env") }
        catch { check(environment == nil) }
        SyncSecrets.store([:], defaults)
        check(defaults.data(forKey: SyncSecrets.storageKey) == nil)
        print("Sync crypto passed: deterministic KDF, login secret separation, authenticated envelope bound to account and revision, tamper/replay/version rejection, secrets routing by mode.")
    }
}
