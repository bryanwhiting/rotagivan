import AppKit
import Combine
import Foundation

struct VaultAccount: Equatable { let token: String; let userID: String }
private final class VaultRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor final class CredentialVault: ObservableObject {
    @Published private(set) var status = "Sign in to use encrypted API keys."
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var restoringLocal = false
    @Published private(set) var localReady = true
    @Published private(set) var hasKey = false
    @Published private(set) var unlocked = false
    @Published private(set) var ownCode: String?
    @Published private(set) var pending: [VaultDevice] = []
    @Published private(set) var hasRemote = false
    @Published private(set) var savedAt: Date?
    @Published var recoveryCode: String?
    @Published private(set) var account: VaultAccount?
    private let server: String
    private var local: VaultLocal?
    private var remote: VaultRecord?
    private var generation = UUID()
    private var restoreTask: Task<Void, Never>?
    private var operationID: UUID?
    private var stopped = false
    private var taskSession: URLSession
    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private let readLocal: (String, String) async throws -> VaultLocal?
    private let writeLocal: (VaultLocal, String, String) async throws -> Void

    init(server: String, transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         read: @escaping (String, String) async throws -> VaultLocal? = { server, userID in
             try await CredentialWorker.shared.run { try VaultKeychain.read(server: server, userID: userID) }
         },
         write: @escaping (VaultLocal, String, String) async throws -> Void = { value, server, userID in
             try await CredentialWorker.shared.run { try VaultKeychain.save(value, server: server, userID: userID) }
         }) {
        self.server = server
        readLocal = read; writeLocal = write
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: VaultRedirectBlocker(), delegateQueue: nil)
        taskSession = session
        self.transport = transport ?? { try await session.data(for: $0) }
    }
    func setAccount(_ account: VaultAccount?) {
        guard !stopped else { return }
        restoreTask?.cancel()
        generation = UUID()
        operationID = nil; busy = false; restoringLocal = false; localReady = account == nil
        self.account = account; local = nil; remote = nil; recoveryCode = nil
        hasKey = false; unlocked = false; hasRemote = false; ownCode = nil; pending = []; savedAt = nil; error = nil
        VaultKeychain.setActive(server: server, userID: account?.userID)
        status = account == nil ? "Sign in to use encrypted API keys." : "Load the vault, or import your key to create it."
        if account != nil { beginLocalRestore() }
    }
    private func beginLocalRestore() {
        guard !stopped, let account else { return }
        let token = generation
        restoringLocal = true; localReady = false; error = nil
        status = "Restoring local encrypted keys…"
        restoreTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.readLocal(self.server, account.userID)
                try self.checked(token, account)
                if let value, let record = value.cached, let master = value.masterKey {
                    _ = try VaultCrypto.open(record, master: master, userID: account.userID)
                    self.remote = record; self.hasRemote = true; self.hasKey = true; self.unlocked = true
                    self.savedAt = Date(timeIntervalSince1970: record.updatedAt)
                    self.status = "Encrypted remotely · Decrypted locally"
                } else {
                    self.status = "Load the vault, or import your key to create it."
                }
                self.local = value; self.localReady = true; self.restoringLocal = false
            } catch {
                guard self.generation == token, !self.stopped, self.account == account else { return }
                self.restoringLocal = false; self.localReady = false
                self.status = "Local encrypted keys are unavailable."
                self.error = (error as? CredentialWorkerError)?.localizedDescription ?? "Local vault could not be restored. Retry before using the vault."
            }
        }
    }
    func retryLocalRestore() {
        guard !stopped, !busy, !restoringLocal, !localReady, account != nil else { return }
        beginLocalRestore()
    }
    func awaitLocalRestore() async { await restoreTask?.value }
    func shutdown() {
        stopped = true; restoreTask?.cancel(); restoreTask = nil
        generation = UUID(); taskSession.invalidateAndCancel()
        operationID = nil; busy = false; restoringLocal = false; localReady = false
        account = nil; hasKey = false; unlocked = false; hasRemote = false; ownCode = nil; pending = []; savedAt = nil; error = nil
        recoveryCode = nil; local = nil; remote = nil
        VaultKeychain.setActive(server: server, userID: nil)
    }
    private func checked(_ token: UUID, _ account: VaultAccount) throws {
        guard !stopped, !Task.isCancelled, generation == token, self.account == account else { throw VaultFailure.message("Account changed. Nothing was loaded.") }
    }
    private func persist(_ value: VaultLocal, account: VaultAccount, token: UUID) async throws {
        try checked(token, account)
        try await writeLocal(value, server, account.userID)
        try checked(token, account)
        local = value
    }
    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                                      account: VaultAccount, token: UUID) async throws -> T {
        try checked(token, account)
        guard let base = URL(string: server), base.scheme == "https", base.host != nil else { throw VaultFailure.message("An HTTPS sync server is required.") }
        var request = URLRequest(url: base.appendingPathComponent("v1/vault" + path))
        request.httpMethod = method
        request.setValue("Bearer " + account.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await transport(request)
        try checked(token, account)
        guard let response = response as? HTTPURLResponse, data.count < 200_000 else { throw VaultFailure.message("Invalid vault response.") }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            switch response.statusCode {
            case 401: message = "Sign in again to use the vault."
            case 403: message = "A trusted Mac or recovery code is required."
            case 409: message = "The vault changed on another Mac. Load it before saving again."
            case 404: message = "Vault or request not found. Refresh and try again."
            default: message = "Vault request failed (HTTP \(response.statusCode)). Nothing was decrypted on the server."
            }
            throw VaultFailure.message(message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func run(allowRecovery: Bool = false, _ operation: (VaultAccount, UUID) async throws -> Void) async {
        guard !stopped, !busy else { return }
        guard !restoringLocal, localReady || allowRecovery else { error = "Restore local encrypted keys before using the vault."; return }
        guard let account else { error = "Sign into your Rotagivan account first."; return }
        busy = true; error = nil
        let token = generation
        let id = UUID(); operationID = id
        defer { if token == generation, operationID == id { busy = false; operationID = nil } }
        do { try await operation(account, token) }
        catch { if token == generation, operationID == id { self.error = (error as? VaultFailure)?.errorDescription ?? (error as? CredentialWorkerError)?.localizedDescription ?? "Could not verify or unlock the encrypted vault. Nothing was loaded." } }
    }
    private func fetch(account: VaultAccount, token: UUID) async throws -> VaultRemote {
        let snapshot: VaultRemote = try await request("", account: account, token: token)
        if let record = snapshot.vault {
            try VaultCrypto.verify(record, userID: account.userID)
            if let local, let pinned = local.vaultID {
                guard pinned == record.vaultID, record.revision >= local.highestRevision, local.vaultPublicKey.map({ $0 == record.publicKey }) ?? true else { throw VaultFailure.message("Vault identity changed or an older copy was returned. Nothing was loaded.") }
                if let master = local.masterKey {
                    guard try VaultCrypto.signing(master, userID: account.userID, vaultID: pinned).publicKey.rawRepresentation.base64EncodedString() == record.publicKey else {
                        throw VaultFailure.message("Vault identity changed. Nothing was loaded.")
                    }
                }
            }
            remote = record; hasRemote = true
            let ownID = try local?.deviceID
            pending = snapshot.devices.filter { $0.grant == nil && $0.id != ownID }
        } else {
            guard local?.cached == nil else { throw VaultFailure.message("Your existing vault is missing remotely. It will not be silently replaced.") }
            remote = nil; hasRemote = false; pending = []
        }
        return snapshot
    }
    private func accept(_ record: VaultRecord, master: Data, account: VaultAccount, token: UUID) async throws {
        try checked(token, account)
        _ = try VaultCrypto.open(record, master: master, userID: account.userID)
        var value = local ?? .fresh()
        value.masterKey = master; value.vaultID = record.vaultID; value.vaultPublicKey = record.publicKey
        value.highestRevision = max(value.highestRevision, record.revision); value.cached = record
        try await persist(value, account: account, token: token)
        remote = record; hasRemote = true; hasKey = true; unlocked = true; ownCode = nil
        savedAt = Date(timeIntervalSince1970: record.updatedAt)
        status = "Encrypted remotely · Decrypted locally"
    }
    func load() async {
        await run { account, token in
            let snapshot = try await self.fetch(account: account, token: token)
            guard let record = snapshot.vault else { self.status = "No encrypted vault yet. Import an API key on your first Mac."; return }
            if let master = self.local?.masterKey { try await self.accept(record, master: master, account: account, token: token); return }
            if let value = self.local, let device = snapshot.devices.first(where: { $0.id == (try? value.deviceID) }),
               let encoded = device.grant {
                let grant = try JSONDecoder().decode(VaultGrant.self, from: Data(encoded.utf8))
                let master = try VaultCrypto.ungrant(grant, record: record, userID: account.userID, local: value, device: device)
                try await self.accept(record, master: master, account: account, token: token)
            } else {
                self.status = "Encrypted remotely · This Mac needs approval"
                if let value = self.local { self.ownCode = VaultCrypto.code(try value.deviceID) }
            }
        }
    }
    func save(apiKey: String? = nil, importEnvironment: Bool = false) async {
        await run { account, token in
            let snapshot = try await self.fetch(account: account, token: token)
            var value = self.local ?? .fresh()
            if snapshot.vault != nil && value.masterKey == nil { throw VaultFailure.message("Approve this Mac or enter a recovery code before saving.") }
            let key: String
            if importEnvironment { key = try OpenRouterCredential.loadEnvironment() }
            else if let apiKey, !apiKey.isEmpty { key = apiKey }
            else if let record = value.cached, let master = value.masterKey { key = try VaultCrypto.open(record, master: master, userID: account.userID).openRouterAPIKey }
            else { throw VaultFailure.message("Enter an OpenRouter API key or import it from ~/.env.") }
            if let existing = snapshot.vault, value.cached != nil, value.highestRevision != existing.revision {
                throw VaultFailure.message("Another Mac saved a newer API key. Load it before overwriting.")
            }
            let vaultID = snapshot.vault?.vaultID ?? value.vaultID ?? UUID().uuidString.lowercased()
            let master = value.masterKey ?? VaultCrypto.randomMaster()
            value.masterKey = master; value.vaultID = vaultID; value.vaultPublicKey = try VaultCrypto.signing(master, userID: account.userID, vaultID: vaultID).publicKey.rawRepresentation.base64EncodedString()
            // Save private material before the first network write. A lost reply
            // can be recovered with Load instead of generating a different key.
            try await self.persist(value, account: account, token: token)
            let baseRevision = snapshot.vault?.revision ?? 0
            let record = try VaultCrypto.seal(VaultPayload(openRouterAPIKey: key), master: master, userID: account.userID, vaultID: vaultID, revision: baseRevision + 1)
            let saved: VaultRecord = try await self.request("", method: "PUT", body: [
                "vaultID": record.vaultID, "publicKey": record.publicKey, "ciphertext": record.ciphertext,
                "signature": record.signature, "baseRevision": baseRevision], account: account, token: token)
            guard saved.vaultID == record.vaultID, saved.ciphertext == record.ciphertext, saved.revision == record.revision else { throw VaultFailure.message("Vault save could not be confirmed. Press Load to check.") }
            try await self.accept(saved, master: master, account: account, token: token)
        }
    }
    func requestAccess() async {
        await run { account, token in
            let snapshot = try await self.fetch(account: account, token: token)
            guard let record = snapshot.vault else { throw VaultFailure.message("Create the vault on your first Mac before requesting access.") }
            var value = self.local ?? .fresh()
            value.vaultID = record.vaultID; value.vaultPublicKey = record.publicKey
            try await self.persist(value, account: account, token: token)
            let publicKey = try value.devicePublicKey.base64EncodedString()
            let device: VaultDevice = try await self.request("/devices", method: "POST",
                body: ["publicKey": publicKey, "name": String((Host.current().localizedName ?? "Mac").prefix(128))],
                account: account, token: token)
            guard device.id == (try value.deviceID), device.publicKey == publicKey else { throw VaultFailure.message("Device request identity mismatch.") }
            self.ownCode = device.verificationCode
            self.status = "Request sent. Compare this code on your trusted Mac, then Load here."
        }
    }
    func approve(_ device: VaultDevice, verificationCode: String) async {
        await run { account, token in
            let entered = verificationCode.uppercased().filter { !$0.isWhitespace && $0 != "-" }
            guard entered == device.verificationCode.replacingOccurrences(of: "-", with: "") else { throw VaultFailure.message("The verification code does not match. Do not approve this device.") }
            let snapshot = try await self.fetch(account: account, token: token)
            guard let record = snapshot.vault, let master = self.local?.masterKey,
                  snapshot.devices.contains(where: { $0.id == device.id && $0.publicKey == device.publicKey && $0.grant == nil }) else {
                throw VaultFailure.message("This request changed or was already approved. Refresh first.")
            }
            let grant = try VaultCrypto.grant(master: master, userID: account.userID, vaultID: record.vaultID, device: device)
            let _: [String: Bool] = try await self.request("/approve", method: "POST", body: [
                "deviceID": device.id, "ephemeralKey": grant.ephemeralKey, "ciphertext": grant.ciphertext, "signature": grant.signature],
                account: account, token: token)
            self.pending.removeAll { $0.id == device.id }
            self.status = "Device approved. Press Load on the other Mac to unlock."
        }
    }
    func recover(_ code: String) async {
        await run(allowRecovery: true) { account, token in
            let snapshot = try await self.fetch(account: account, token: token)
            guard let record = snapshot.vault else { throw VaultFailure.message("No remote vault to recover.") }
            let master = try VaultCrypto.recover(code)
            try await self.accept(record, master: master, account: account, token: token)
            self.localReady = true
        }
    }
    func showRecoveryCode() {
        guard localReady, !restoringLocal, !busy, !stopped else { return }
        guard let master = local?.masterKey else { error = "Unlock this Mac first."; return }
        recoveryCode = VaultCrypto.recoveryCode(master)
    }
}
