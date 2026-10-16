import AppKit
import Foundation
import SwiftUI

@MainActor private final class EncryptedCloudFixture {
    var settings = CloudSettings(yaml: nil, revision: 0, updatedAt: nil)
    var vault: VaultRecord
    var settingsPuts = 0
    var requests = 0
    var notModified = 0
    var offline = false
    let master = VaultCrypto.randomMaster()
    let account = SyncAccount(token: "fixture-session", userID: "fixture-user", email: "fixture@example.test", expiresAt: 2_000_000_000)
    init() throws {
        var payload = VaultPayload(); payload.settingsEnabled = true
        vault = try VaultCrypto.seal(payload, master: master, userID: "fixture-user", vaultID: UUID().uuidString, revision: 1)
    }
    func local() -> VaultLocal {
        var local = VaultLocal.fresh()
        local.masterKey = master; local.vaultID = vault.vaultID; local.vaultPublicKey = vault.publicKey
        local.highestRevision = vault.revision; local.cached = vault
        return local
    }
    func call(_ request: URLRequest) throws -> (Data, URLResponse) {
        precondition(request.url?.host == "fixture.test", "No live network in tests")
        if offline { throw URLError(.notConnectedToInternet) }
        requests += 1
        let data: Data
        var code = 200
        if request.url!.path == "/v1/vault" {
            precondition(request.httpMethod == "GET")
            data = try JSONEncoder().encode(VaultRemote(vault: vault, devices: []))
        } else if request.httpMethod == "GET" {
            // Match the real backend: a matching If-None-Match is a bodyless 304.
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"\(settings.revision)\"" {
                notModified += 1; code = 304; data = Data()
            } else { data = try JSONEncoder().encode(settings) }
        } else {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let ciphertext = body["yaml"] as! String
            precondition(ciphertext.hasPrefix("rota-e2ee-settings-v1:"))
            precondition(!ciphertext.contains("cursorSpeed") && !ciphertext.contains("fixture-secret-bookmark"))
            if body["baseRevision"] as! Int != settings.revision {
                code = 409; data = Data("{}".utf8)
            } else {
                settingsPuts += 1
                settings = CloudSettings(yaml: ciphertext, revision: settings.revision + 1, updatedAt: Date().timeIntervalSince1970)
                // Match the real backend: successful PUT does not echo YAML.
                data = try JSONEncoder().encode(CloudSettings(yaml: nil, revision: settings.revision, updatedAt: settings.updatedAt))
            }
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct AutomaticSyncIntegrationTests {
    @MainActor static func main() async throws {
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
            let value = try condition()
            precondition(value, message)
        }
        func firstSync(_ sync: SettingsSync) async throws {
            sync.start(); await sync.awaitLoginRestore(); await sync.synchronizeAutomatically()
            for _ in 0..<300 {
                if sync.lastSave != nil || sync.error != nil { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("First automatic sync timed out")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-sync-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = try EncryptedCloudFixture()
        var base = try AppConfiguration.parse(String(contentsOfFile: "Rotagivan/DefaultConfiguration.yaml"))
        base.profiles = [ConfigurationProfile(id: "z-work", name: "Work", settings: base.settings, shortcuts: base.shortcuts),
                         ConfigurationProfile(id: "a-home", name: "Home", settings: base.settings, shortcuts: base.shortcuts)]
        base.activeConfigurationID = "z-work"
        func projected(_ config: AppConfiguration) -> AppConfiguration {
            var result = config
            if let index = result.profiles?.firstIndex(where: { $0.id == result.activeConfigurationID }) {
                result.profiles?[index].settings = result.settings
                result.profiles?[index].shortcuts = result.shortcuts
            }
            return result
        }
        let canonical = try SyncConfigurationCodec.fields(base)
        for _ in 0..<10 {
            let decoded = try AppConfiguration.parse(base.yaml())
            let fields = try SyncConfigurationCodec.fields(decoded)
            precondition(fields == canonical, "Serialization must be stable across dictionary/set ordering")
        }
        var work = base, home = base
        work.settings.normal.cursorSpeed += 0.02
        // First upgraded Mac preserves its live edits, encrypts the old cloud copy.
        cloud.settings = CloudSettings(yaml: try base.yaml(), revision: 4, updatedAt: 1)
        func client(_ name: String, snapshot: @escaping () -> AppConfiguration, apply: @escaping (AppConfiguration) -> Void) throws -> SettingsSync {
            let db = try EncryptedSettingsDatabase(url: root.appendingPathComponent(name + "/settings.sqlite"), master: Data(repeating: 42, count: 32), scope: name)
            let preferences = try EncryptedPreferences(database: db)
            preferences.set(true, forKey: "migration.rotagivan.v1")
            let store = SettingsStore(defaults: preferences)
            store.settings.enabled = false
            var saved = cloud.local()
            let vault = CredentialVault(server: "https://fixture.test", transport: { try cloud.call($0) },
                read: { _, _ in saved }, write: { value, _, _ in saved = value })
            return SettingsSync(store: store, hid: NavigatorHIDManager(store: store),
                files: SyncFiles(directory: root.appendingPathComponent(name + "/legacy")), defaults: preferences,
                automatic: true, server: "https://fixture.test",
                credentials: SyncCredentials(read: { _ in cloud.account }, save: { _, _ in }, remove: { _ in }),
                vault: vault, transport: { try cloud.call($0) }, snapshot: snapshot, apply: apply)
        }
        let a = try client("work", snapshot: { projected(work) }, apply: { work = $0 })
        try await firstSync(a)
        precondition(a.error == nil && a.lastSave != nil, a.error ?? "First sync did not complete")
        precondition(work.settings.normal.cursorSpeed == base.settings.normal.cursorSpeed + 0.02)
        precondition(cloud.settings.yaml!.hasPrefix("rota-e2ee-settings-v1:"))
        let b = try client("home", snapshot: { projected(home) }, apply: { home = $0 })
        try await firstSync(b)
        precondition(b.error == nil, b.error ?? "")
        try check(projected(work).syncFingerprint() == projected(home).syncFingerprint(), "New Mac downloads automatically")
        precondition(home.profiles?.map(\.id) == ["z-work", "a-home"], "Profile display order must survive sync")
        let previousPuts = cloud.settingsPuts
        await a.synchronizeAutomatically(); await b.synchronizeAutomatically()
        precondition(cloud.settingsPuts == previousPuts, "Unchanged settings do not upload")
        // Triggers: a non-portable change (window focus, enable switch) costs no
        // request; an idle poll is one conditional GET answered 304 and skips
        // the vault refresh while this Mac already holds the key.
        let idleRequests = cloud.requests, idle304 = cloud.notModified
        work.settings.enabled.toggle()
        await a.synchronizeAutomatically(trigger: .localChange)
        precondition(cloud.requests == idleRequests, "A local change without portable differences must not touch the network")
        await a.synchronizeAutomatically(trigger: .poll)
        precondition(cloud.requests == idleRequests + 1 && cloud.notModified == idle304 + 1 && cloud.settingsPuts == previousPuts,
                     "An idle poll is a single conditional settings GET answered 304")
        precondition(a.error == nil && a.syncStatus == "Up to date" && a.pollDelay == SettingsSync.pollInterval)
        work.settings.normal.cursorSpeed += 0.03
        home.settings.precision.cursorSpeed += 0.04
        await a.synchronizeAutomatically(); await b.synchronizeAutomatically(); await a.synchronizeAutomatically()
        try check(projected(work).syncFingerprint() == projected(home).syncFingerprint(), "Independent edits converge")
        precondition(work.settings.normal.cursorSpeed == base.settings.normal.cursorSpeed + 0.05)
        precondition(work.settings.precision.cursorSpeed == base.settings.precision.cursorSpeed + 0.04)
        cloud.offline = true
        work.settings.normal.cursorSpeed += 0.01
        await a.synchronizeAutomatically()
        precondition(a.error != nil)
        precondition(a.pollDelay > SettingsSync.pollInterval, "Failures back off the poll")
        precondition(a.error!.hasPrefix("Sync paused. Your local settings are safe."), a.error!)
        cloud.offline = false
        await a.synchronizeAutomatically(); await b.synchronizeAutomatically()
        precondition(a.error == nil && b.error == nil && a.pollDelay == SettingsSync.pollInterval)
        try check(projected(work).syncFingerprint() == projected(home).syncFingerprint(), "Offline changes retry without manual load")
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("work/legacy/settings.yaml").path))
        if CommandLine.arguments.count > 1 {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
            let view = NSHostingView(rootView: SyncSettingsView(sync: a).padding(20).frame(width: 720, height: 820, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            panel.contentView = view
            panel.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 80_000_000)
            if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("automatic-sync.png")
                try image.representation(using: .png, properties: [:])!.write(to: output)
                print("UI fixture: " + output.path)
            }
            panel.orderOut(nil)
        }
        await a.prepareToQuit(); await b.prepareToQuit()
        let disk = try Data(contentsOf: root.appendingPathComponent("work/settings.sqlite"))
        precondition(disk.range(of: Data("cursorSpeed".utf8)) == nil)
        print("PASS AutomaticSyncIntegrationTests: legacy migration, new Mac download, independent edits, no-op local changes, conditional idle polls, backoff, offline retry, encrypted transport and local storage")
    }
}
