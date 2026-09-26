import CryptoKit
import Foundation
import Security

enum VaultFailure: Error, LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct VaultPayload: Codable, Equatable, Sendable { var openRouterAPIKey: String }
struct VaultRecord: Codable, Sendable {
    var vaultID: String
    var publicKey: String
    var ciphertext: String
    var signature: String
    var revision: Int
    var updatedAt: Double
}
struct VaultGrant: Codable, Sendable {
    var ephemeralKey: String
    var ciphertext: String
    var signature: String
}
struct VaultDevice: Codable, Identifiable, Sendable {
    var id: String
    var publicKey: String
    var name: String
    var createdAt: Double
    var grant: String?
    var verificationCode: String { VaultCrypto.code(id) }
}
struct VaultRemote: Codable, Sendable { var vault: VaultRecord?; var devices: [VaultDevice] }
struct VaultLocal: Codable, Sendable {
    var devicePrivateKey: Data
    var masterKey: Data?
    var vaultID: String?
    var vaultPublicKey: String?
    var highestRevision = 0
    var cached: VaultRecord?
    static func fresh() -> Self { Self(devicePrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation) }
    var devicePublicKey: Data { get throws { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: devicePrivateKey).publicKey.rawRepresentation } }
    var deviceID: String { get throws { VaultCrypto.hex(SHA256.hash(data: try devicePublicKey)) } }
}

enum VaultCrypto {
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    static func code(_ id: String) -> String {
        let text = Array(id.prefix(24).uppercased())
        return stride(from: 0, to: text.count, by: 4).map { String(text[$0..<min($0 + 4, text.count)]) }.joined(separator: "-")
    }
    static func randomMaster() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func scope(userID: String, vaultID: String) -> String { "rotagivan-vault-v1\n" + userID + "\n" + vaultID }
    static func derive(_ master: Data, userID: String, vaultID: String, purpose: String) throws -> SymmetricKey {
        guard master.count == 32 else { throw VaultFailure.message("Invalid vault key.") }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master),
            salt: Data(scope(userID: userID, vaultID: vaultID).utf8), info: Data(purpose.utf8), outputByteCount: 32)
    }
    static func signing(_ master: Data, userID: String, vaultID: String) throws -> Curve25519.Signing.PrivateKey {
        let seed = try derive(master, userID: userID, vaultID: vaultID, purpose: "signing").withUnsafeBytes { Data($0) }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
    static func payloadMessage(userID: String, record: VaultRecord) -> Data {
        Data(["rotagivan-vault-v1", "payload", userID, record.vaultID, String(record.revision), record.ciphertext].joined(separator: "\n").utf8)
    }
    static func grantMessage(userID: String, vaultID: String, device: VaultDevice, grant: VaultGrant) -> Data {
        Data(["rotagivan-vault-v1", "grant", userID, vaultID, device.id, device.publicKey, grant.ephemeralKey, grant.ciphertext].joined(separator: "\n").utf8)
    }
    static func bytes(_ text: String, count: Int? = nil) throws -> Data {
        guard let data = Data(base64Encoded: text), data.base64EncodedString() == text, count.map({ data.count == $0 }) ?? true else {
            throw VaultFailure.message("Invalid encrypted vault data.")
        }
        return data
    }
    static func verify(_ record: VaultRecord, userID: String) throws {
        guard UUID(uuidString: record.vaultID) != nil, record.revision > 0, record.revision <= 1_000_000_001,
              record.ciphertext.count <= 22000,
              try Curve25519.Signing.PublicKey(rawRepresentation: bytes(record.publicKey, count: 32))
                .isValidSignature(bytes(record.signature, count: 64), for: payloadMessage(userID: userID, record: record)) else {
            throw VaultFailure.message("Vault signature is invalid. Nothing was loaded.")
        }
    }
    static func seal(_ payload: VaultPayload, master: Data, userID: String, vaultID: String, revision: Int) throws -> VaultRecord {
        try validate(payload)
        let signing = try signing(master, userID: userID, vaultID: vaultID)
        let aad = Data((scope(userID: userID, vaultID: vaultID) + "\npayload\n" + String(revision)).utf8)
        let box = try AES.GCM.seal(JSONEncoder().encode(payload),
            using: derive(master, userID: userID, vaultID: vaultID, purpose: "encryption"), authenticating: aad)
        guard let combined = box.combined else { throw VaultFailure.message("Encryption failed.") }
        var record = VaultRecord(vaultID: vaultID, publicKey: signing.publicKey.rawRepresentation.base64EncodedString(),
            ciphertext: combined.base64EncodedString(), signature: "", revision: revision, updatedAt: 0)
        record.signature = try signing.signature(for: payloadMessage(userID: userID, record: record)).base64EncodedString()
        return record
    }
    static func open(_ record: VaultRecord, master: Data, userID: String) throws -> VaultPayload {
        try verify(record, userID: userID)
        guard try signing(master, userID: userID, vaultID: record.vaultID).publicKey.rawRepresentation == bytes(record.publicKey, count: 32) else {
            throw VaultFailure.message("This Mac does not have the key for this vault.")
        }
        let aad = Data((scope(userID: userID, vaultID: record.vaultID) + "\npayload\n" + String(record.revision)).utf8)
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes(record.ciphertext)),
            using: derive(master, userID: userID, vaultID: record.vaultID, purpose: "encryption"), authenticating: aad)
        let payload = try JSONDecoder().decode(VaultPayload.self, from: data)
        try validate(payload)
        return payload
    }
    static func validate(_ payload: VaultPayload) throws {
        guard !payload.openRouterAPIKey.isEmpty, payload.openRouterAPIKey.count <= 1024,
              !payload.openRouterAPIKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw VaultFailure.message("Invalid OpenRouter API key.")
        }
    }
    static func wrappingContext(userID: String, vaultID: String, device: VaultDevice, ephemeral: String) -> Data {
        Data((scope(userID: userID, vaultID: vaultID) + "\nwrap\n" + device.id + "\n" + device.publicKey + "\n" + ephemeral).utf8)
    }
    static func grant(master: Data, userID: String, vaultID: String, device: VaultDevice) throws -> VaultGrant {
        let recipient = try bytes(device.publicKey, count: 32)
        guard hex(SHA256.hash(data: recipient)) == device.id else { throw VaultFailure.message("Device identity does not match its public key.") }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = ephemeral.publicKey.rawRepresentation.base64EncodedString()
        let context = wrappingContext(userID: userID, vaultID: vaultID, device: device, ephemeral: publicKey)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: Data("device-approval".utf8), outputByteCount: 32)
        guard let sealed = try AES.GCM.seal(master, using: key, authenticating: context).combined else { throw VaultFailure.message("Could not encrypt device approval.") }
        var result = VaultGrant(ephemeralKey: publicKey, ciphertext: sealed.base64EncodedString(), signature: "")
        result.signature = try signing(master, userID: userID, vaultID: vaultID)
            .signature(for: grantMessage(userID: userID, vaultID: vaultID, device: device, grant: result)).base64EncodedString()
        return result
    }
    static func ungrant(_ grant: VaultGrant, record: VaultRecord, userID: String, local: VaultLocal, device: VaultDevice) throws -> Data {
        try verify(record, userID: userID)
        guard try local.deviceID == device.id, try local.devicePublicKey.base64EncodedString() == device.publicKey,
              try Curve25519.Signing.PublicKey(rawRepresentation: bytes(record.publicKey, count: 32))
                .isValidSignature(bytes(grant.signature, count: 64), for: grantMessage(userID: userID, vaultID: record.vaultID, device: device, grant: grant)) else {
            throw VaultFailure.message("Device approval could not be verified.")
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: local.devicePrivateKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes(grant.ephemeralKey, count: 32)))
        let context = wrappingContext(userID: userID, vaultID: record.vaultID, device: device, ephemeral: grant.ephemeralKey)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: Data("device-approval".utf8), outputByteCount: 32)
        let master = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes(grant.ciphertext, count: 60)), using: key, authenticating: context)
        _ = try open(record, master: master, userID: userID)
        return master
    }
    static func recoveryCode(_ master: Data) -> String {
        "RV1-" + hex(master).uppercased().enumerated().map { index, char in (index > 0 && index % 4 == 0 ? "-" : "") + String(char) }.joined()
    }
    static func recover(_ code: String) throws -> Data {
        guard code.uppercased().hasPrefix("RV1-") else { throw VaultFailure.message("Invalid recovery code.") }
        let hex = code.dropFirst(4).filter { !$0.isWhitespace && $0 != "-" }.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw VaultFailure.message("Invalid recovery code.") }
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
    }
}

/// Private device/root keys are device-only Keychain items, never iCloud/YAML.
enum VaultKeychain {
    private static let lock = NSLock()
    private static var active: (String, String)?
    private static var activeGeneration: UInt64 = 0
    static func setActive(server: String, userID: String?) {
        lock.lock(); defer { lock.unlock() }
        active = userID.map { (server, $0) }
        activeGeneration &+= 1
    }
    static func item(server: String, userID: String) -> String { server + "/" + userID }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.rotagivan.vault.v1",
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    static func read(server: String, userID: String) throws -> VaultLocal? {
        var query = query(item(server: server, userID: userID))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultFailure.message("Keychain could not unlock the vault (\(status)).") }
        return try JSONDecoder().decode(VaultLocal.self, from: data)
    }
    static func save(_ local: VaultLocal, server: String, userID: String) throws {
        let account = item(server: server, userID: userID)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(local),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw VaultFailure.message("Keychain could not save the vault (\(status)). Nothing was uploaded.") }
    }
    static func currentAPIKey(readLocal: @Sendable (String, String) throws -> VaultLocal? = { try read(server: $0, userID: $1) }) throws -> String? {
        lock.lock(); let scope = active; let generation = activeGeneration; lock.unlock()
        guard let (server, userID) = scope else { return nil }
        let local = try readLocal(server, userID)
        let key: String?
        if let local, let master = local.masterKey, let cached = local.cached {
            key = try VaultCrypto.open(cached, master: master, userID: userID).openRouterAPIKey
        } else { key = nil }
        lock.lock(); defer { lock.unlock() }
        guard activeGeneration == generation, active?.0 == server, active?.1 == userID else {
            throw VaultFailure.message("The active account changed while preparing voice credentials. Please try again.")
        }
        return key
    }
}
