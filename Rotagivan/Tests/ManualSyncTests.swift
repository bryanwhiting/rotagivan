import AppKit
import Foundation
import SwiftUI

@MainActor private final class CloudStub {
    var calls: [String] = []
    var remote: CloudSettings
    var loginID = "alice"
    var failPut = false
    var beforeGet: (() async -> Void)?
    init(yaml: String) { remote = CloudSettings(yaml: yaml, revision: 3, updatedAt: 1_700_000_000) }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        precondition(request.url?.host == "sync.test", "Tests must never use a real account")
        let path = request.url!.lastPathComponent
        let method = request.httpMethod!
        calls.append(method + " " + path)
        let data: Data
        var status = 200
        switch (method, path) {
        case ("POST", "login"), ("POST", "register"), ("POST", "password"):
            data = try JSONEncoder().encode(SyncAccount(token: "test-token", userID: loginID,
                email: loginID + "@example.test", expiresAt: 2_000_000_000))
        case ("POST", "logout"):
            data = Data(#"{"ok":true}"#.utf8)
        case ("GET", "settings"):
            let hook = beforeGet; beforeGet = nil
            await hook?()
            data = try JSONEncoder().encode(remote)
        case ("PUT", "settings"):
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(body["baseRevision"] as? Int == remote.revision)
            if failPut {
                status = 409
                data = Data(#"{"error":"Concurrent save"}"#.utf8)
            } else {
                remote = CloudSettings(yaml: body["yaml"] as? String, revision: remote.revision + 1,
                    updatedAt: (remote.updatedAt ?? 1_700_000_000) + 1)
                data = try JSONEncoder().encode(CloudSettings(yaml: nil, revision: remote.revision, updatedAt: remote.updatedAt))
            }
        default: fatalError("Unexpected request: \(method) \(path)")
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct ManualSyncTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.ManualSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manual-sync-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        let hid = NavigatorHIDManager(store: store)
        let files = SyncFiles(directory: root)
        var base = try AppConfiguration.parse(String(contentsOfFile: "Rotagivan/DefaultConfiguration.yaml", encoding: .utf8))
        base.settings.appExplorer = AppExplorerSettings(swipeDirection: .regular)
        let roundTrip = try AppConfiguration.parse(base.yaml())
        precondition(roundTrip.settings.appExplorer?.resolvedSwipeDirection == .regular,
            "Sync must round-trip the HUD swipe-direction preference")
        var edited = base
        edited.settings.normal.cursorSpeed += 0.01
        var newer = base
        newer.settings.normal.cursorSpeed += 0.02
        var working = base
        var applications = 0
        var savedAccount: SyncAccount? = SyncAccount(token: "test-token", userID: "alice",
            email: "alice@example.test", expiresAt: 2_000_000_000)
        let credentials = SyncCredentials(read: { _ in savedAccount },
            save: { value, _ in savedAccount = value }, remove: { _ in savedAccount = nil })
        let cloud = CloudStub(yaml: try edited.yaml())
        func makeSync() -> SettingsSync {
            SettingsSync(store: store, hid: hid, files: files, defaults: defaults, server: "https://sync.test",
                credentials: credentials,
                vault: CredentialVault(server: "https://sync.test", transport: { _ in
                    fatalError("Manual sync must never access the real vault or network")
                }, read: { _, _ in nil }, write: { _, _, _ in }),
                transport: { try await cloud.send($0) },
                snapshot: { working }, apply: { working = $0; applications += 1 }, computerName: { "Studio Mac" })
        }
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        _ = try await files.save(edited, expectedDigest: nil)
        let originalDisk = try await files.rawDigest()
        let sync = makeSync()
        sync.start(); sync.start()
        await sync.awaitLoginRestore()
        await sync.vault.awaitLocalRestore()
        check(cloud.calls.isEmpty && applications == 0, "Startup must not load YAML or touch the cloud")
        check(try await files.rawDigest() == originalDisk, "Startup must not export app settings")
        check(sync.lastSave == nil, "Unknown cloud timestamps must not claim a save")
        working = newer
        store.settings.normal.cursorSpeed += 0.03
        _ = try await files.save(base, expectedDigest: originalDisk)
        let externalDisk = try await files.rawDigest()
        try await Task.sleep(for: .milliseconds(2200))
        check(cloud.calls.isEmpty && applications == 0, "Edits and external YAML changes must never trigger transfers")
        check(try await files.rawDigest() == externalDisk, "No debounced automatic file save")
        check(try working.syncFingerprint() == newer.syncFingerprint(), "External YAML edits must not auto-import")

        let legacyPreview = await sync.prepareCloudLoad()
        check(legacyPreview?.savedAt == Date(timeIntervalSince1970: 1_700_000_000),
              "Confirmation displays server save time")
        check(legacyPreview?.computer == nil &&
              legacyPreview?.confirmationMessage.contains("Unknown computer") == true,
              "Older saves must not guess their source computer")
        let previewDisk = try await files.rawDigest()
        check(applications == 0 && previewDisk == externalDisk,
              "Preview must not apply or export settings")
        let metadataYAML = CloudSettings.uploadYAML(try edited.yaml(), computer: "Bryan’s Mac Studio")
        cloud.remote.yaml = metadataYAML
        let namedPreview = await sync.prepareCloudLoad()
        check(namedPreview?.computer == "Bryan’s Mac Studio", "Unicode computer names round-trip")
        check(try AppConfiguration.parse(metadataYAML).syncFingerprint() == edited.syncFingerprint(),
              "Provenance must not change settings")
        cloud.remote.revision += 1
        await sync.load(expectedCloudSave: namedPreview)
        check(applications == 0 && sync.error?.contains("cloud save changed") == true,
              "Do not load a different revision from the confirmed one")
        cloud.remote.revision -= 1
        let wrongAccount = CloudLoadPreview(accountID: "other", revision: cloud.remote.revision,
            savedAt: nil, computer: nil)
        let callsBeforeAccountCheck = cloud.calls.count
        await sync.load(expectedCloudSave: wrongAccount)
        check(applications == 0 && cloud.calls.count == callsBeforeAccountCheck,
              "Do not load from a different account than the confirmed one")
        cloud.remote.yaml = try edited.yaml()
        cloud.calls = []
        await sync.load()
        check(cloud.calls == ["GET settings"] && applications == 1, "Load must download exactly once and never upload")
        check(try working.syncFingerprint() == edited.syncFingerprint(), "Load applies the requested cloud copy")
        check(try await files.rawDigest() == externalDisk, "Cloud Load must not implicitly export a YAML snapshot")
        check(sync.lastSave == Date(timeIntervalSince1970: 1_700_000_000), "Last save uses remote save time, not load time")

        cloud.calls = []
        working = base
        cloud.beforeGet = { working = newer }
        await sync.save()
        check(cloud.calls == ["GET settings", "PUT settings"], "Save performs one revision read and one upload")
        check(cloud.remote.savedByComputer == "Studio Mac", "Explicit saves include the saving computer")
        let uploaded = try AppConfiguration.parse(cloud.remote.yaml!)
        check(try uploaded.syncFingerprint() == base.syncFingerprint(), "Save uploads the snapshot from the button press")
        check(try working.syncFingerprint() == newer.syncFingerprint(), "Save must not overwrite later app edits")
        let localSaved = try await files.read()!
        check(try localSaved.0.syncFingerprint() == base.syncFingerprint(), "Local file and cloud use the same save snapshot")
        let savedTime = sync.lastSave
        check(savedTime == Date(timeIntervalSince1970: 1_700_000_001), "Save publishes the acknowledged cloud timestamp")
        let restart = makeSync()
        cloud.calls = []
        restart.start()
        await restart.awaitLoginRestore()
        await restart.vault.awaitLocalRestore()
        check(restart.lastSave == savedTime && cloud.calls.isEmpty, "Restart restores the cached timestamp without checking cloud")
        await restart.prepareToQuit()

        let beforeStaleLoad = applications
        working = base
        cloud.beforeGet = { working = newer }
        await sync.load()
        check(applications == beforeStaleLoad && sync.error?.contains("newer edits") == true,
            "Load cannot discard edits made during a request")
        check(try working.syncFingerprint() == newer.syncFingerprint(), "Concurrent local edit survives")
        cloud.remote.yaml = "invalid: ["
        await sync.load()
        check(applications == beforeStaleLoad && sync.error != nil, "Invalid cloud configuration cannot be applied")
        cloud.remote.yaml = nil
        await sync.load()
        check(applications == beforeStaleLoad && sync.error?.contains("No saved cloud") == true, "Empty cloud is not an upload invitation")
        cloud.remote.yaml = try edited.yaml()

        cloud.calls = []
        cloud.failPut = true
        await sync.save()
        check(sync.error?.contains("Saved to settings.yaml, but not to the cloud") == true, "Report partial saves accurately")
        check(sync.lastSave == savedTime, "Failed cloud saves must not advance its timestamp")
        let afterFailure = cloud.calls
        try await Task.sleep(for: .milliseconds(2200))
        check(cloud.calls == afterFailure, "A failed save must not schedule a retry")
        cloud.failPut = false

        cloud.calls = []
        let beforeAccountChange = try await files.rawDigest()
        await sync.signOut()
        check(cloud.calls == ["POST logout"], "Sign out must not transfer settings")
        check(sync.lastSave != nil, "Signing out restores the separate local-file save time")
        cloud.calls = []
        cloud.loginID = "bob"
        await sync.authenticate(email: "bob@example.test", password: "test-password-only", create: false)
        check(cloud.calls == ["POST login"] && sync.lastSave == nil, "Another account must not transfer settings or leak Alice's timestamp")
        check(try await files.rawDigest() == beforeAccountChange, "Sign-in must not save the local file")
        cloud.calls = []
        await sync.changePassword(current: "test-password-only", new: "test-password-again")
        check(cloud.calls == ["POST password"], "Password changes must not sync")
        await sync.signOut()
        cloud.calls = []
        await sync.authenticate(email: "bob@example.test", password: "test-password-only", create: true)
        check(cloud.calls == ["POST register"], "Registration must not auto-upload")
        await sync.signOut()

        cloud.calls = []
        working = edited
        await sync.save()
        check(cloud.calls.isEmpty && sync.error == nil && sync.lastSave != nil, "Signed-out Save is local only")
        working = newer
        await sync.load()
        check(try working.syncFingerprint() == edited.syncFingerprint(), "Signed-out Load imports only on demand")
        check(cloud.calls.isEmpty, "Local Load never contacts cloud")
        let timestamp = try await files.modificationDate()
        check(sync.lastSave == timestamp, "Local last-save label uses the file's saved time")

        if CommandLine.arguments.count > 1 {
            let host = NSHostingView(rootView: SyncSettingsView(sync: sync).padding(20).frame(width: 620).background(Color(nsColor: .windowBackgroundColor)))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.center(); panel.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("manual-sync.png"))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(panel.windowNumber),
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("manual-sync-native.png").path]
            try capture.run(); capture.waitUntilExit()
            precondition(capture.terminationStatus == 0)
            panel.orderOut(nil); panel.close()
        }
        let beforeQuit = try await files.rawDigest()
        working = newer
        store.settings.normal.cursorSpeed += 0.04
        await sync.prepareToQuit()
        await sync.save(); await sync.load()
        check(try await files.rawDigest() == beforeQuit && cloud.calls.isEmpty, "Quit must not flush settings or allow later transfers")
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("backup"), includingPropertiesForKeys: nil)
        check(!backups.isEmpty, "Replacement operations must retain recoverable backups")
        print("Manual sync passed: no startup/edit/file-watch/login/quit transfers; explicit Save/Load; captured snapshots; stale-load rejection; invalid/empty cloud; CAS failure without retry; per-account timestamps; local mode; backups; YAML HUD preference roundtrip.")
    }
}
