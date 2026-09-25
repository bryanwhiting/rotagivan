import Foundation

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@main struct VaultLiveSmoke {
    static func main() async throws {
        let base = URL(string: "https://rotagivan-sync.bryan-b4b.workers.dev/v1/")!
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func call(_ path: String, method: String = "GET", body: [String: Any]? = nil, token: String? = nil, expected: Int = 200) async throws -> Data {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method; request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == expected else { throw VaultFailure.message("Live request failed: " + path + ", HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
            return data
        }
        struct Account: Decodable { let token: String; let userID: String; let email: String }
        let email = "vault-smoke-" + UUID().uuidString.lowercased() + "@example.test"
        let account = try JSONDecoder().decode(Account.self, from: await call("register", method: "POST",
            body: ["email": email, "password": UUID().uuidString + UUID().uuidString]))
        // Non-secret exact cleanup target only; never persist the token or keys.
        let cleanup = try JSONSerialization.data(withJSONObject: ["userID": account.userID, "email": account.email])
        try cleanup.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: [.atomic])
        let master = VaultCrypto.randomMaster(), vaultID = UUID().uuidString.lowercased()
        let fixture = VaultPayload(openRouterAPIKey: "fixture-api-key-not-a-real-secret")
        let record = try VaultCrypto.seal(fixture, master: master, userID: account.userID, vaultID: vaultID, revision: 1)
        let saved = try JSONDecoder().decode(VaultRecord.self, from: await call("vault", method: "PUT", body: [
            "vaultID": vaultID, "publicKey": record.publicKey, "ciphertext": record.ciphertext, "signature": record.signature,
            "baseRevision": 0], token: account.token))
        let home = VaultLocal.fresh()
        let device = try JSONDecoder().decode(VaultDevice.self, from: await call("vault/devices", method: "POST",
            body: ["publicKey": try home.devicePublicKey.base64EncodedString(), "name": "Synthetic Home"], token: account.token))
        let grant = try VaultCrypto.grant(master: master, userID: account.userID, vaultID: vaultID, device: device)
        let approval: [String: Any] = ["deviceID": device.id, "ephemeralKey": grant.ephemeralKey, "ciphertext": grant.ciphertext, "signature": grant.signature]
        _ = try await call("vault/approve", method: "POST", body: approval, token: account.token)
        let downloaded = try JSONDecoder().decode(VaultRemote.self, from: await call("vault", token: account.token))
        guard let remote = downloaded.vault, let homeDevice = downloaded.devices.first, let encoded = homeDevice.grant else { throw VaultFailure.message("Approval missing") }
        let delivered = try JSONDecoder().decode(VaultGrant.self, from: Data(encoded.utf8))
        let homeMaster = try VaultCrypto.ungrant(delivered, record: remote, userID: account.userID, local: home, device: homeDevice)
        guard try VaultCrypto.open(remote, master: homeMaster, userID: account.userID) == fixture else { throw VaultFailure.message("Round-trip failed") }
        let recovered = try VaultCrypto.recover(VaultCrypto.recoveryCode(master))
        guard try VaultCrypto.open(saved, master: recovered, userID: account.userID) == fixture else { throw VaultFailure.message("Recovery failed") }
        _ = try await call("vault", method: "PUT", body: ["vaultID": vaultID, "publicKey": record.publicKey,
            "ciphertext": record.ciphertext, "signature": record.signature, "baseRevision": 0], token: account.token, expected: 409)
        _ = try await call("logout", method: "POST", body: [:], token: account.token)
        _ = try await call("vault", token: account.token, expected: 401)
        print("Live vault PASS: CryptoKit ↔ deployed Worker signatures, encrypted upload/download, asynchronous Home approval, local recovery, CAS, revoked session")
    }
}

