import AppKit
import Foundation

/// The sync backend's API, in memory: accounts, sessions, one settings record.
final class FakeSyncServer: @unchecked Sendable {
    struct User { var password: String; var id: String }
    private let lock = NSLock()
    var users: [String: User] = [:]
    var sessions: [String: String] = [:] // token → userID
    var ciphertext: String?
    var revision = 0
    var requests: [String] = []
    var passwordsSeen: [String] = []

    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        requests.append(request.httpMethod! + " " + path)
        func json(_ object: Any, _ status: Int = 200, headers: [String: String] = [:]) throws -> (Data, URLResponse) {
            (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        func fail(_ status: Int, _ message: String) throws -> (Data, URLResponse) { try json(["error": message], status) }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func session() -> String? {
            guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") else { return nil }
            return sessions[String(header.dropFirst(7))]
        }
        func issue(_ email: String, _ user: User) throws -> (Data, URLResponse) {
            let token = UUID().uuidString
            sessions[token] = user.id
            return try json(["token": token, "userID": user.id, "email": email, "expiresAt": 2_000_000_000])
        }
        switch path {
        case "/v1/register":
            let email = body["email"] as! String, password = body["password"] as! String
            passwordsSeen.append(password)
            guard users[email] == nil else { return try fail(409, "exists") }
            users[email] = User(password: password, id: UUID().uuidString)
            return try issue(email, users[email]!)
        case "/v1/login":
            let email = body["email"] as! String, password = body["password"] as! String
            passwordsSeen.append(password)
            guard let user = users[email], user.password == password else { return try fail(401, "Email or password is incorrect.") }
            return try issue(email, user)
        case "/v1/password":
            guard let userID = session(), let email = users.first(where: { $0.value.id == userID })?.key else { return try fail(401, "sign in") }
            passwordsSeen.append(body["newPassword"] as! String)
            guard users[email]!.password == body["currentPassword"] as! String else { return try fail(401, "wrong") }
            users[email]!.password = body["newPassword"] as! String
            return try issue(email, users[email]!)
        case "/v1/logout":
            return try json(["ok": true])
        case "/v1/settings":
            guard session() != nil else { return try fail(401, "sign in") }
            if request.httpMethod == "GET" {
                if let match = request.value(forHTTPHeaderField: "If-None-Match"), match == "\"\(revision)\"" {
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!)
                }
                return try json(["yaml": ciphertext as Any, "revision": revision, "updatedAt": 1])
            }
            let base = body["baseRevision"] as! Int
            guard base == revision else { return try fail(409, "stale") }
            ciphertext = (body["yaml"] as! String); revision += 1
            return try json(["revision": revision, "updatedAt": 1])
        default: return try fail(404, "nope")
        }
    }
}

extension AppConfiguration { var speed: Double { (settings.normal.cursorSpeed * 1000).rounded() / 10 } }

@main struct SettingsSyncTests {
    static func check(_ value: Bool, _ message: String = "", line: UInt = #line) { precondition(value, "line \(line): " + message) }
    @MainActor static func mac(named name: String, server: FakeSyncServer, defaults: UserDefaults, configuration: @escaping () -> AppConfiguration,
                               apply: @escaping (AppConfiguration) -> Void, localFolder: URL? = nil) -> SettingsSync {
        let store = SettingsStore(defaults: defaults)
        let hid = NavigatorHIDManager(store: store)
        var saved: SyncAccount?
        return SettingsSync(store: store, hid: hid, defaults: defaults, automatic: false, server: "https://sync.test",
            credentials: SyncCredentials(read: { _ in saved }, save: { account, _ in saved = account }, remove: { _ in saved = nil }),
            transport: { request in
                precondition(request.url?.host == "sync.test")
                return try server.handle(request)
            }, snapshot: configuration, apply: apply, localFolder: localFolder, deviceName: name)
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let base = try AppConfiguration.parse(try String(contentsOfFile: "Rota/DefaultConfiguration.yaml", encoding: .utf8))
        func variant(_ speed: Double) -> AppConfiguration { var copy = base; copy.settings.normal.cursorSpeed = speed / 100; return copy }
        let server = FakeSyncServer()
        let suiteA = "Rota.SyncA." + UUID().uuidString, suiteB = "Rota.SyncB." + UUID().uuidString
        let defaultsA = UserDefaults(suiteName: suiteA)!, defaultsB = UserDefaults(suiteName: suiteB)!
        defer { defaultsA.removePersistentDomain(forName: suiteA); defaultsB.removePersistentDomain(forName: suiteB) }
        for defaults in [defaultsA, defaultsB] { defaults.set(true, forKey: "migration.rota.v1") }

        // Nothing happens before a mode is chosen.
        var currentA = variant(1.0)
        var appliedA: [AppConfiguration] = []
        let macA = mac(named: "Mac A", server: server, defaults: defaultsA, configuration: { currentA }, apply: { appliedA.append($0) })
        check(macA.mode == nil)
        macA.start(); await macA.awaitLoginRestore()
        await macA.synchronizeAutomatically(trigger: .launch)
        check(server.requests.isEmpty && macA.syncStatus == "Choose where your settings live.")

        // Cloud: create an account. The server never sees the password.
        macA.choose(.cloud)
        check(defaultsA.string(forKey: SettingsSync.modeKey) == "cloud")
        await macA.authenticate(email: "Pair@Example.com", password: "a long fixture password", create: true)
        check(macA.error == nil, macA.error ?? "")
        check(macA.account?.email == "pair@example.com" && macA.unlocked)
        check(!server.passwordsSeen.contains("a long fixture password") && server.passwordsSeen.allSatisfy { $0.count == 64 })
        // authenticate ran a cycle: the first upload.
        check(server.revision == 1 && server.ciphertext!.hasPrefix(SyncCrypto.wirePrefix), "first upload after sign-in")
        check(macA.syncStatus == "Up to date", macA.syncStatus)
        // No portable change → no network.
        let before = server.requests.count
        await macA.synchronizeAutomatically(trigger: .localChange)
        check(server.requests.count == before, "unchanged settings cost no request")
        await macA.synchronizeAutomatically(trigger: .poll)
        check(server.requests.count == before + 1 && macA.notModifiedResponses == 1, "an idle poll is one conditional GET answered 304")
        // A local edit uploads.
        currentA = variant(2.0); macA.noteLocalEdit()
        await macA.synchronizeAutomatically(trigger: .localChange)
        check(server.revision == 2 && macA.lastSave != nil)
        // API keys travel in the document.
        macA.setSecret("OPENROUTER_API_KEY", value: " sk-fixture ")
        await macA.synchronizeAutomatically(trigger: .localChange)
        check(server.revision == 3 && macA.savedSecretNames == ["OPENROUTER_API_KEY"] && !server.ciphertext!.contains("sk-fixture"))

        // Mac B signs in with the same password and receives settings and keys.
        var currentB = variant(100)
        var appliedB: [AppConfiguration] = []
        let macB = mac(named: "Mac B", server: server, defaults: defaultsB, configuration: { currentB }, apply: { appliedB.append($0); currentB = $0 })
        macB.start(); await macB.awaitLoginRestore()
        macB.choose(.cloud)
        await macB.authenticate(email: "pair@example.com", password: "a long fixture password", create: false)
        check(macB.error == nil, macB.error ?? "")
        check(appliedB.count == 1 && appliedB[0].speed == 2.0, "Mac B adopts the cloud copy")
        check(SyncSecrets.stored(defaultsB)["OPENROUTER_API_KEY"] == "sk-fixture" && macB.savedSecretNames == ["OPENROUTER_API_KEY"])
        check(macB.syncStatus.hasPrefix("Up to date"), macB.syncStatus)
        check(server.revision == 3, "adopting the cloud copy uploads nothing")
        // Wrong password cannot sign in and cannot decrypt.
        let defaultsC = UserDefaults(suiteName: "Rota.SyncC." + UUID().uuidString)!
        defaultsC.set(true, forKey: "migration.rota.v1")
        let macC = mac(named: "Mac C", server: server, defaults: defaultsC, configuration: { base }, apply: { _ in fatalError("wrong password applied settings") })
        macC.start(); await macC.awaitLoginRestore(); macC.choose(.cloud)
        await macC.authenticate(email: "pair@example.com", password: "not the right password", create: false)
        check(macC.account == nil && macC.error?.contains("incorrect") == true, macC.error ?? "")

        // B edits, A picks it up on its hourly poll; then both edit and the later edit wins.
        currentB = variant(3.0); macB.noteLocalEdit()
        await macB.synchronizeAutomatically(trigger: .localChange)
        check(server.revision == 4)
        await macA.synchronizeAutomatically(trigger: .poll)
        check(appliedA.count == 1 && appliedA[0].speed == 3.0, "A applied B's edit")
        currentA = variant(4.0); macA.noteLocalEdit()  // A edits first…
        try await Task.sleep(nanoseconds: 20_000_000)
        currentB = variant(5.0); macB.noteLocalEdit()  // …B edits later and syncs first.
        await macB.synchronizeAutomatically(trigger: .localChange)
        await macA.synchronizeAutomatically(trigger: .localChange)
        check(appliedA.count == 2 && appliedA[1].speed == 5.0, "the later edit (B) wins on A")
        check(macA.conflictNotice?.contains("more recently") == true, macA.conflictNotice ?? "")
        check(defaultsA.data(forKey: "sync.beforeMerge." + macA.account!.userID) != nil, "A's losing state is backed up")

        // An account created by an older build (server knows the real password) is upgraded on sign-in.
        server.users["old@example.com"] = FakeSyncServer.User(password: "legacy real password!", id: "legacy")
        let defaultsD = UserDefaults(suiteName: "Rota.SyncD." + UUID().uuidString)!
        defaultsD.set(true, forKey: "migration.rota.v1")
        let macD = mac(named: "Mac D", server: server, defaults: defaultsD, configuration: { base }, apply: { _ in })
        macD.start(); await macD.awaitLoginRestore(); macD.choose(.cloud)
        await macD.authenticate(email: "old@example.com", password: "legacy real password!", create: false)
        check(macD.error == nil && macD.unlocked, macD.error ?? "")
        check(server.users["old@example.com"]!.password.count == 64, "legacy password replaced by the derived secret")

        // Sign out forgets the keys and the state; the server copy stays.
        await macB.signOut()
        check(macB.account == nil && SyncSecrets.stored(defaultsB).isEmpty && server.revision >= 5)

        // Local file mode on a fresh Mac: the file is written, then reloaded when it changes.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rota-sync-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var currentE = variant(10)
        var appliedE: [AppConfiguration] = []
        let defaultsE = UserDefaults(suiteName: "Rota.SyncE." + UUID().uuidString)!
        defaultsE.set(true, forKey: "migration.rota.v1")
        let macE = mac(named: "Mac E", server: server, defaults: defaultsE, configuration: { currentE }, apply: { appliedE.append($0); currentE = $0 }, localFolder: root)
        macE.start(); await macE.awaitLoginRestore()
        macE.choose(.local)
        await macE.synchronizeAutomatically(trigger: .launch)
        check(FileManager.default.fileExists(atPath: macE.localFile.path), "launch writes settings.yaml")
        check(macE.syncStatus.hasPrefix("Up to date"), macE.syncStatus)
        let requestsBeforeLocal = server.requests.count
        currentE = variant(11)
        await macE.synchronizeAutomatically(trigger: .localChange)
        check(try AppConfiguration.parse(String(contentsOf: macE.localFile, encoding: .utf8)).speed == 11)
        try Data(try variant(12).yaml().utf8).write(to: macE.localFile, options: .atomic)
        await macE.synchronizeAutomatically(trigger: .fileChange)
        check(appliedE.count == 1 && appliedE[0].speed == 12, "an external edit is loaded")
        check(server.requests.count == requestsBeforeLocal, "local mode never talks to the server")
        check(SyncSecrets.names.allSatisfy { !(try! String(contentsOf: macE.localFile, encoding: .utf8)).contains($0) }, "no secrets in the YAML")
        // The HUD's "Sync now" command runs a cycle in the current mode.
        var invoked = false
        let hidE = NavigatorHIDManager(store: SettingsStore(defaults: defaultsE))
        hidE.onSyncSettings = { invoked = true }
        hidE.onSyncSettings?()
        check(invoked)
        for mac in [macA, macB, macC, macD, macE] { await mac.prepareToQuit() }
        print("Settings sync passed: mode gate, password-derived login, first upload, idle 304, edit upload, synced API keys, second Mac download, wrong password refusal, last-edit-wins, legacy account upgrade, sign-out, local-file write/reload, no secrets on disk.")
    }
}
