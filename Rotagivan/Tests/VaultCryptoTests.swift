import CryptoKit
import Foundation

@main struct VaultCryptoTests {
    static func check(_ value: Bool, _ message: String = "") { precondition(value, message) }
    static func main() throws {
        let user = "test-user", id = UUID().uuidString.lowercased()
        let master = VaultCrypto.randomMaster()
        let payload = VaultPayload(openRouterAPIKey: "fixture-api-key-not-real")
        let sealed = try VaultCrypto.seal(payload, master: master, userID: user, vaultID: id, revision: 1)
        check(try VaultCrypto.open(sealed, master: master, userID: user) == payload)
        check(!String(data: try JSONEncoder().encode(sealed), encoding: .utf8)!.contains(payload.openRouterAPIKey))
        let another = try VaultCrypto.seal(payload, master: master, userID: user, vaultID: id, revision: 1)
        check(sealed.ciphertext != another.ciphertext, "Fresh nonce on every encryption")
        let home = VaultLocal.fresh()
        let homeDevice = VaultDevice(id: try home.deviceID, publicKey: try home.devicePublicKey.base64EncodedString(), name: "Home", createdAt: 0, grant: nil)
        let grant = try VaultCrypto.grant(master: master, userID: user, vaultID: id, device: homeDevice)
        check(try VaultCrypto.ungrant(grant, record: sealed, userID: user, local: home, device: homeDevice) == master)
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Accepted invalid cryptographic data") } catch {}
        }
        rejects { _ = try VaultCrypto.open(sealed, master: VaultCrypto.randomMaster(), userID: user) }
        rejects { _ = try VaultCrypto.open(sealed, master: master, userID: "other-account") }
        var changed = sealed; changed.revision = 2
        rejects { _ = try VaultCrypto.open(changed, master: master, userID: user) }
        changed = sealed; changed.vaultID = UUID().uuidString.lowercased()
        rejects { _ = try VaultCrypto.open(changed, master: master, userID: user) }
        changed = sealed; changed.ciphertext = another.ciphertext
        rejects { _ = try VaultCrypto.open(changed, master: master, userID: user) }
        let stranger = VaultLocal.fresh()
        rejects { _ = try VaultCrypto.ungrant(grant, record: sealed, userID: user, local: stranger, device: homeDevice) }
        var tampered = grant; tampered.ephemeralKey = try stranger.devicePublicKey.base64EncodedString()
        rejects { _ = try VaultCrypto.ungrant(tampered, record: sealed, userID: user, local: home, device: homeDevice) }
        var fakeDevice = homeDevice; fakeDevice.id = String(repeating: "0", count: 64)
        rejects { _ = try VaultCrypto.grant(master: master, userID: user, vaultID: id, device: fakeDevice) }
        let code = VaultCrypto.recoveryCode(master)
        check(try VaultCrypto.recover(code) == master)
        rejects { _ = try VaultCrypto.recover("RV1-wrong") }
        check(homeDevice.verificationCode.count == 29)
        print("Vault cryptography PASS: authenticated encryption, fresh nonces, account/revision/recipient binding, recovery, tamper rejection")
    }
}

