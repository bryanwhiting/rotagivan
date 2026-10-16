import AppKit
import Foundation

@main struct SettingsSyncActionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.SyncAction." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = true
        let hid = NavigatorHIDManager(store: store)
        let configuration = try AppConfiguration.parse(String(contentsOfFile: "Rotagivan/DefaultConfiguration.yaml", encoding: .utf8))
        let files = SyncFiles(directory: root)
        var calls: [String] = []
        var uploaded: String?
        var revision = 1
        let account = SyncAccount(token: "fixture-token", userID: "fixture", email: "fixture@example.test", expiresAt: 2_000_000_000)
        let vault = CredentialVault(server: "https://sync.test", transport: { _ in fatalError("The sync action must not transfer keys") },
            read: { _, _ in nil }, write: { _, _, _ in })
        let sync = SettingsSync(store: store, hid: hid, files: files, defaults: defaults, server: "https://sync.test",
            credentials: SyncCredentials(read: { _ in account }, save: { _, _ in }, remove: { _ in }), vault: vault,
            transport: { request in
                precondition(request.url?.host == "sync.test")
                calls.append(request.httpMethod! + " " + request.url!.lastPathComponent)
                if request.httpMethod == "PUT" {
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    precondition(body["baseRevision"] as? Int == revision)
                    uploaded = body["yaml"] as? String; revision += 1
                }
                return (try JSONEncoder().encode(CloudSettings(yaml: nil, revision: revision, updatedAt: 1_700_000_000)),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, snapshot: { configuration }, apply: { _ in fatalError("Sync action must never restore remote settings") })
        let action = BindingAction.command(.syncSettings)
        precondition(action.isValid && action.favorite(at: .up)?.action == .syncSettings)
        let decoded = try JSONDecoder().decode(BindingAction.self, from: JSONEncoder().encode(action))
        precondition(decoded == action)
        precondition(calls.isEmpty)
        // Exercise the real input executor without opening Settings or starting HID.
        hid.executeBindingAction(action, fromKeyboard: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while sync.lastSave == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(sync.lastSave != nil && sync.error == nil && !sync.busy)
        precondition(calls == ["GET settings", "PUT settings"])
        let expectedFingerprint = try configuration.syncFingerprint()
        let uploadedFingerprint = try AppConfiguration.parse(uploaded!).syncFingerprint()
        precondition(uploadedFingerprint == expectedFingerprint)
        let persisted = try await files.read()!
        let persistedFingerprint = try persisted.0.syncFingerprint()
        precondition(persistedFingerprint == expectedFingerprint)
        var invocations = 0
        hid.onSyncSettings = { invocations += 1 }
        hid.executeBindingAction(action, fromKeyboard: false)
        precondition(invocations == 1, "Gestures and keyboard must dispatch through the same executor")
        store.settings.enabled = false
        hid.executeBindingAction(action, fromKeyboard: true)
        precondition(invocations == 1, "Disabled bindings must not start a save")
        await sync.prepareToQuit()
        print("Sync settings action PASS: startup/login restore, real keyboard/gesture executor, one cloud upload, persisted local readback, no restore/vault transfer, disabled gate, JSON/HUD roundtrip.")
    }
}
