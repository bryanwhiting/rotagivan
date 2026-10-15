import CryptoKit
import Foundation
import Security

@main struct VaultCryptoTests {
    static func check(_ value: Bool, _ message: String = "") { precondition(value, message) }
    static func main() throws {
        var policies: [Bool] = []
        let status: OSStatus = try CredentialKeychainRead.withoutUI(
            get: { (errSecSuccess, true) }, set: { policies.append($0); return errSecSuccess },
            operation: { errSecInteractionNotAllowed })
        check(status == errSecInteractionNotAllowed && policies == [false, true], "Silent reads restore UI policy even on denied access")
        var accessed = false
        do {
            _ = try CredentialKeychainRead.withoutUI(get: { (errSecSuccess, true) },
                set: { _ in errSecAuthFailed }, operation: { accessed = true })
            fatalError("Unsafe read was allowed")
        } catch { check(!accessed, "Fail closed if UI cannot be disabled") }
        let user = "test-user", id = UUID().uuidString.lowercased()
        let master = VaultCrypto.randomMaster()
        let payload = VaultPayload(openRouterAPIKey: "fixture-api-key-not-real")
        let sealed = try VaultCrypto.seal(payload, master: master, userID: user, vaultID: id, revision: 1)
        check(try VaultCrypto.open(sealed, master: master, userID: user) == payload)
        check(!String(data: try JSONEncoder().encode(sealed), encoding: .utf8)!.contains(payload.openRouterAPIKey))
        let another = try VaultCrypto.seal(payload, master: master, userID: user, vaultID: id, revision: 1)
        check(sealed.ciphertext != another.ciphertext, "Fresh nonce on every encryption")
        let legacy = try JSONDecoder().decode(VaultPayload.self, from: Data("{\"openRouterAPIKey\":\"fixture-legacy-router\"}".utf8))
        check(legacy.openRouterAPIKey == "fixture-legacy-router" && legacy.openAIAPIKey == nil, "Existing one-provider vaults remain readable")
        let both = payload.updating(openRouter: nil, openAI: "fixture-openai-not-real")
        let bothSealed = try VaultCrypto.seal(both, master: master, userID: user, vaultID: id, revision: 2)
        check(try VaultCrypto.open(bothSealed, master: master, userID: user) == both, "Both provider keys round-trip encrypted")
        let wire = String(data: try JSONEncoder().encode(bothSealed), encoding: .utf8)!
        check(!wire.contains(both.openAIAPIKey!) && !wire.contains(both.openRouterAPIKey), "Neither provider leaks in the transport envelope")
        check(both.updating(openRouter: "", openAI: "") == both, "Blank fields preserve both keys")
        check(both.updating(openRouter: "fixture-replacement", openAI: nil).openAIAPIKey == both.openAIAPIKey)
        let openAIOnly = VaultPayload(openAIAPIKey: "fixture-only-openai")
        check(try VaultCrypto.open(VaultCrypto.seal(openAIOnly, master: master, userID: user, vaultID: id, revision: 3), master: master, userID: user) == openAIOnly, "OpenAI-only setup needs no OpenRouter key")
        check(VaultProvider.openRouter.key(in: openAIOnly) == nil && VaultProvider.openAI.key(in: openAIOnly) == "fixture-only-openai")
        VaultKeychain.setActive(server: "https://fixture.test", userID: user)
        var cachedLocal = VaultLocal.fresh(); cachedLocal.masterKey = master; cachedLocal.cached = bothSealed
        VaultKeychain.cache(cachedLocal, server: "https://fixture.test", userID: user)
        check(try VaultKeychain.currentAPIKey(provider: .openAI) == both.openAIAPIKey, "OpenAI reads only its own unlocked key")
        check(try VaultKeychain.currentAPIKey() == both.openRouterAPIKey, "OpenRouter keeps its own key")
        VaultKeychain.setActive(server: "https://fixture.test", userID: nil)
        check(try VaultKeychain.currentAPIKey(provider: .openAI) == nil, "Sign-out clears cached OpenAI access")
        let home = VaultLocal.fresh()
        let homeDevice = VaultDevice(id: try home.deviceID, publicKey: try home.devicePublicKey.base64EncodedString(), name: "Home", createdAt: 0, grant: nil)
        let grant = try VaultCrypto.grant(master: master, userID: user, vaultID: id, device: homeDevice)
        check(try VaultCrypto.ungrant(grant, record: sealed, userID: user, local: home, device: homeDevice) == master)
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Accepted invalid cryptographic data") } catch {}
        }
        struct OldClientPayload: Decodable { let openRouterAPIKey: String }
        rejects { _ = try JSONDecoder().decode(OldClientPayload.self, from: JSONEncoder().encode(both)) }
        rejects { _ = try JSONDecoder().decode(VaultPayload.self, from: Data("{\"schemaVersion\":3,\"providers\":{}}".utf8)) }
        rejects { _ = try JSONDecoder().decode(VaultPayload.self, from: Data("{\"schemaVersion\":2,\"providers\":{\"futureProvider\":\"fixture\"}}".utf8)) }
        rejects { try VaultCrypto.validate(VaultPayload()) }
        rejects { try VaultCrypto.validate(VaultPayload(openAIAPIKey: "invalid whitespace")) }
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
