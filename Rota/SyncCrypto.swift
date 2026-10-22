import CommonCrypto
import CryptoKit
import Foundation

/// Cloud sync encryption, from first principles.
///
/// One secret, the account password, never leaves this Mac. A slow KDF turns it
/// into a 256-bit master key; two independent subkeys are derived from that:
///
/// - the **login secret**, which is what the server receives as the account
///   "password" (and hashes again with scrypt). The server never sees the real
///   password, so it can never derive the encryption key;
/// - the **settings key**, which seals the whole settings document with AES-GCM.
///
/// Any Mac that knows the email and password can decrypt. There is no device
/// enrolment, approval code or recovery code: the password is the recovery code.
enum SyncCrypto {
    static let version = 2
    /// PBKDF2-HMAC-SHA256 rounds. ~0.3 s on an M-series Mac; paid once per sign-in.
    static let rounds: UInt32 = 600_000
    static let wirePrefix = "rota-e2ee-settings-v1:"

    enum Failure: Error, LocalizedError {
        case weakPassword, badEmail, sealFailed, unreadable, wrongKey, tooLarge, unsupported(Int)
        var errorDescription: String? {
            switch self {
            case .weakPassword: return "Use a password of at least 12 characters."
            case .badEmail: return "Enter a valid email address."
            case .sealFailed: return "Settings could not be encrypted."
            case .unreadable: return "The cloud copy of your settings is not in a format this Rota can read."
            case .wrongKey: return "The cloud copy could not be decrypted with this password. Nothing was changed."
            case .tooLarge: return "Your settings exceed the 1 MB sync limit."
            case .unsupported(let version): return "The cloud copy was saved by a newer Rota (format \(version)). Update this Mac."
            }
        }
    }

    static func normalizedEmail(_ email: String) throws -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count <= 254, trimmed.contains("@"), !trimmed.contains(where: \.isWhitespace),
              trimmed.split(separator: "@").count == 2, trimmed.split(separator: "@")[1].contains(".") else {
            throw Failure.badEmail
        }
        return trimmed
    }

    /// Deterministic for one (email, password) pair on every Mac.
    /// The "rotagivan-sync-v2" salt and context strings below are key-derivation
    /// inputs: every existing account's login secret and every stored cloud
    /// document depend on them, so they keep the app's former name on purpose.
    static func masterKey(email: String, password: String, rounds: UInt32 = rounds) throws -> Data {
        guard password.count >= 12 else { throw Failure.weakPassword }
        let salt = Data(("rotagivan-sync-v2:" + (try normalizedEmail(email))).utf8)
        var derived = Data(count: 32)
        let passwordBytes = Array(password.utf8)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                    output.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
            }
        }
        guard status == kCCSuccess else { throw Failure.sealFailed }
        return derived
    }
    private static func subkey(_ master: Data, _ purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master), salt: Data("rotagivan-sync-v2".utf8),
            info: Data(purpose.utf8), outputByteCount: 32)
    }
    /// 64 hex characters: satisfies the server's 12+ character password rule and
    /// reveals nothing about the settings key.
    static func loginSecret(master: Data) -> String {
        subkey(master, "login").withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// The sealed document carries its own version and revision; the revision is
    /// also authenticated so a server cannot replay an old body under a new number.
    struct Envelope: Codable, Equatable {
        var version: Int
        var revision: Int64
        var sealed: Data
    }
    static let maximumBytes = 1_048_576

    static func seal(_ plaintext: Data, master: Data, email: String, revision: Int64) throws -> String {
        guard plaintext.count <= maximumBytes else { throw Failure.tooLarge }
        let box = try AES.GCM.seal(plaintext, using: subkey(master, "settings"),
            authenticating: context(email: try normalizedEmail(email), revision: revision))
        guard let combined = box.combined else { throw Failure.sealFailed }
        let envelope = Envelope(version: version, revision: revision, sealed: combined)
        let wire = wirePrefix + (try JSONEncoder().encode(envelope)).base64EncodedString()
        guard wire.utf8.count <= maximumBytes + 4096 else { throw Failure.tooLarge }
        return wire
    }
    static func open(_ wire: String, master: Data, email: String, revision: Int64) throws -> Data {
        guard wire.hasPrefix(wirePrefix), wire.utf8.count <= maximumBytes * 2,
              let bytes = Data(base64Encoded: String(wire.dropFirst(wirePrefix.count))),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes) else { throw Failure.unreadable }
        guard envelope.version == version else {
            throw envelope.version > version ? Failure.unsupported(envelope.version) : Failure.unreadable
        }
        guard envelope.revision == revision, envelope.sealed.count >= 28 else { throw Failure.unreadable }
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: envelope.sealed), using: subkey(master, "settings"),
                authenticating: context(email: try normalizedEmail(email), revision: revision))
        } catch { throw Failure.wrongKey }
    }
    /// True for any ciphertext this or an earlier encrypted format produced.
    static func isEncrypted(_ wire: String) -> Bool { wire.hasPrefix("rota-e2ee-") }
    private static func context(email: String, revision: Int64) -> Data {
        Data("rotagivan-sync-v2\n\(email)\n\(revision)".utf8)
    }
}

/// The API keys voice providers read. In cloud mode they are part of the
/// encrypted document (and cached in the encrypted local preferences). In local
/// mode they come from `~/.env` only and are never written to the YAML file.
enum SyncSecrets {
    static let names = ["OPENROUTER_API_KEY", "OPENAI_ROTA_KEY"]
    static let storageKey = "sync.secrets.v2"
    static let modeKey = "sync.mode"
    /// Production points this at the encrypted preferences at bootstrap.
    static var defaults: () -> UserDefaults = { .standard }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }
    static func stored(_ defaults: UserDefaults) -> [String: String] {
        guard let data = defaults.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }
    static func store(_ values: [String: String], _ defaults: UserDefaults) {
        if values.isEmpty { defaults.removeObject(forKey: storageKey) }
        else { defaults.set(try? JSONEncoder().encode(values), forKey: storageKey) }
    }
    /// Cloud mode: the synced key, falling back to `~/.env` while none is saved yet.
    /// Any other mode: `~/.env` only.
    static func value(_ name: String) throws -> String {
        let defaults = defaults()
        if defaults.string(forKey: modeKey) == SyncMode.cloud.rawValue,
           let value = stored(defaults)[name], !value.isEmpty { return value }
        return try OpenRouterCredential.loadEnvironment(variable: name)
    }
    /// Reads `~/.env` without executing it; nil when the variable is absent.
    static func environmentValue(_ name: String) -> String? {
        try? OpenRouterCredential.loadEnvironment(variable: name)
    }
}

/// Which of the two sync homes this Mac uses. Exactly one must be chosen before
/// anything is written anywhere; until then settings stay on this Mac.
enum SyncMode: String, CaseIterable, Codable {
    case cloud, local
    var title: String { self == .cloud ? "Cloud sync" : "Local file" }
}
