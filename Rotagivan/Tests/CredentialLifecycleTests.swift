import AppKit
import Foundation
import SwiftUI

@MainActor private final class CredentialSuspension<Value> {
    private var pending: CheckedContinuation<Value, Error>?
    private var entered: [CheckedContinuation<Void, Never>] = []
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil)
            pending = continuation
            entered.forEach { $0.resume() }; entered.removeAll()
        }
    }
    func awaitEntered() async {
        if pending != nil { return }
        await withCheckedContinuation { entered.append($0) }
    }
    func finish(_ result: Result<Value, Error>) {
        let continuation = pending; pending = nil
        precondition(continuation != nil)
        continuation!.resume(with: result)
    }
}

private final class BlockingCredentialProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let releaseGate = DispatchSemaphore(value: 0)
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func block() {
        precondition(!Thread.isMainThread, "Credential work must run off the main thread")
        lock.lock(); started = true; lock.unlock()
        releaseGate.wait()
    }
    func release() { releaseGate.signal() }
}

@main struct CredentialLifecycleTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try await testWorker()
        try await testSyncLifecycle()
        try await testRestoreUI()
        print("Credential lifecycle passed: bounded off-main worker, cancellation and release ordering, suspended restore responsiveness/quit, safe retry, operation guards, and stale auth/error protection. No real Keychain or network access.")
    }

    @MainActor static func testRestoreUI() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let suite = "Rotagivan.SyncRestoreUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-restore-ui-\(UUID().uuidString)")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        let hid = NavigatorHIDManager(store: store)
        let gate = CredentialSuspension<SyncAccount?>()
        var reads = 0, requests = 0, writes = 0, removals = 0
        let vault = CredentialVault(server: "https://sync.test", transport: { _ in fatalError("No vault network permitted") },
            read: { _, _ in nil }, write: { _, _, _ in })
        let sync = SettingsSync(store: store, hid: hid, files: SyncFiles(directory: root), defaults: defaults,
            server: "https://sync.test", credentials: SyncCredentials(read: { _ in
                reads += 1; return try await gate.wait()
            }, save: { _, _ in writes += 1 }, remove: { _ in removals += 1 }), vault: vault,
            transport: { _ in requests += 1; fatalError("Restore UI must not contact the network") })
        sync.start(); await gate.awaitEntered()
        let host = NSHostingView(rootView: SyncSettingsView(sync: sync).padding(20)
            .frame(width: 660, height: 740, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 740),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host
        panel.center(); panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        func elements(_ object: Any) -> [AnyObject] {
            let element = object as AnyObject
            return [element] + (element.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func allElements() -> [AnyObject] {
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            return views(host).flatMap(elements)
        }
        func find(_ identifier: String) -> AnyObject? {
            allElements().first { $0.accessibilityIdentifier?() == identifier }
        }
        func capture(_ name: String) throws {
            guard CommandLine.arguments.count > 1 else { return }
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(for: .milliseconds(200))
        precondition(find("sync-save")?.isAccessibilityEnabled?() == false && find("sync-load")?.isAccessibilityEnabled?() == false)
        precondition(find("sync-restore-retry") == nil, "Pending reads must not expose a retry that spawns another call")
        precondition(find("sync-vault-awaiting-account") != nil,
            "Pending account restore must explain that encrypted-key status is unknown")
        precondition(!allElements().contains { $0.accessibilityLabel?() == "Not saved" },
            "Unknown account must not imply that its encrypted keys are missing")
        precondition(!allElements().contains { $0.accessibilityLabel?() == "Sign in" },
            "Unknown saved login must not render a signed-out fallback")
        sync.retryLoginRestore()
        precondition(reads == 1 && sync.restoringLogin)
        try capture("sync-restore-loading")
        gate.finish(.failure(ConfigurationError("Fixture Keychain is locked. Unlock it and retry.")))
        await sync.awaitLoginRestore()
        try await Task.sleep(for: .milliseconds(150))
        guard let retry = find("sync-restore-retry") else { preconditionFailure("Terminal errors need a native Retry button") }
        precondition(retry.isAccessibilityEnabled?() == true)
        precondition(find("sync-vault-awaiting-account") != nil)
        precondition(!allElements().contains { $0.accessibilityLabel?() == "Not saved" })
        precondition(find("sync-save")?.isAccessibilityEnabled?() == false && find("sync-load")?.isAccessibilityEnabled?() == false)
        try capture("sync-restore-error")
        precondition(retry.accessibilityPerformPress?() == true)
        await gate.awaitEntered()
        precondition(reads == 2 && sync.restoringLogin)
        try await Task.sleep(for: .milliseconds(100))
        precondition(find("sync-restore-retry") == nil)
        sync.retryLoginRestore(); precondition(reads == 2)
        gate.finish(.success(SyncAccount(token: "ui-fixture-token", userID: "ui-fixture", email: "fixture@example.test", expiresAt: 2_000_000_000)))
        await sync.awaitLoginRestore(); await vault.awaitLocalRestore()
        try await Task.sleep(for: .milliseconds(150))
        precondition(sync.credentialsReady && !sync.restoringLogin)
        precondition(find("sync-save")?.isAccessibilityEnabled?() == true && find("sync-load")?.isAccessibilityEnabled?() == true)
        precondition(find("sync-restore-retry") == nil)
        try capture("sync-restore-ready")
        precondition(find("sync-vault-awaiting-account") == nil,
            "Known account replaces the placeholder with the shared vault view")
        precondition(requests == 0 && writes == 0 && removals == 0 && !FileManager.default.fileExists(atPath: sync.localURL.path),
            "A native Retry restores login only, without settings/vault transfers or credential writes")
        await sync.prepareToQuit()
        print("Sync restore native UI passed pending/error/retry/ready AX states, exactly-one retry, and no implicit file/network transfers.")
    }

    @MainActor static func testWorker() async throws {
        let worker = CredentialWorker()
        let probe = BlockingCredentialProbe()
        let blocked = Task { try await worker.run { probe.block(); return 7 } }
        while !probe.entered { await Task.yield() }
        for _ in 0..<20 {
            do { _ = try await worker.run { preconditionFailure("A busy worker must not enqueue calls") } as Int; preconditionFailure() }
            catch CredentialWorkerError.busy {}
        }
        blocked.cancel()
        do { _ = try await blocked.value; preconditionFailure("Cancellation must return without joining blocked work") }
        catch is CancellationError {}
        do { _ = try await worker.run { 9 }; preconditionFailure("Cancellation must not free a running Security call's slot") }
        catch CredentialWorkerError.busy {}
        probe.release()
        var result: Int?
        while result == nil {
            do { result = try await worker.run { precondition(!Thread.isMainThread); return 8 } }
            catch CredentialWorkerError.busy { await Task.yield() }
        }
        precondition(result == 8)
        // Immediately chaining work verifies slot release precedes publication.
        for index in 0..<20 {
            let next = try await worker.run { index }
            precondition(next == index)
        }
        do {
            let _: Int = try await worker.run { throw ConfigurationError("Fixture credential error") }
            preconditionFailure()
        } catch { precondition(error.localizedDescription.contains("Fixture credential error")) }
        let afterFailure = try await worker.run { 10 }
        precondition(afterFailure == 10, "Errors must release worker capacity before publication")
        let cancelled = Task { try await worker.run { 1 } }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure() } catch is CancellationError {}
    }

    @MainActor static func testSyncLifecycle() async throws {
        let suite = "Rotagivan.CredentialLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-lifecycle-\(UUID().uuidString)")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        let hid = NavigatorHIDManager(store: store)
        let files = SyncFiles(directory: root)
        let account = SyncAccount(token: "fixture-token", userID: "fixture-user", email: "fixture@example.test", expiresAt: 2_000_000_000)
        func fakeVault() -> CredentialVault {
            CredentialVault(server: "https://sync.test", transport: { _ in fatalError("No vault network permitted") },
                read: { _, _ in nil }, write: { _, _, _ in })
        }
        let gate = CredentialSuspension<SyncAccount?>()
        var reads = 0, writes = 0, removals = 0, requests = 0, snapshots = 0
        let sync = SettingsSync(store: store, hid: hid, files: files, defaults: defaults, server: "https://sync.test",
            credentials: SyncCredentials(read: { _ in reads += 1; return try await gate.wait() },
                save: { _, _ in writes += 1 }, remove: { _ in removals += 1 }), vault: fakeVault(),
            transport: { _ in requests += 1; fatalError("Unresolved login must not send a request") },
            snapshot: { snapshots += 1; return AppConfiguration(settings: store.settings, shortcuts: ShortcutConfiguration()) })
        sync.start(); sync.start(); sync.retryLoginRestore()
        precondition(sync.restoringLogin && !sync.credentialsReady)
        await gate.awaitEntered()
        precondition(reads == 1)
        var mainActorProgress = false
        await Task { @MainActor in mainActorProgress = true }.value
        precondition(mainActorProgress, "A suspended credential restore leaves the main actor responsive")
        await sync.save(); await sync.load(); await sync.authenticate(email: "fixture", password: "fixture-password", create: false)
        let unknownPreview = await sync.prepareCloudLoad()
        precondition(unknownPreview == nil)
        precondition(writes == 0 && removals == 0 && requests == 0 && snapshots == 0)
        precondition(!FileManager.default.fileExists(atPath: files.file.path), "Unknown login must not fall back to local Save")
        let restoreWait = Task { await sync.awaitLoginRestore() }
        await Task.yield()
        await sync.prepareToQuit()
        precondition(!sync.restoringLogin && !sync.credentialsReady && !sync.busy)
        gate.finish(.success(account))
        await restoreWait.value
        precondition(sync.account == nil && sync.lastSave == nil && sync.error == nil,
            "Post-quit restore result must not publish credentials or errors")

        let failedGate = CredentialSuspension<SyncAccount?>()
        let lateFailure = SettingsSync(store: store, hid: hid, files: files, defaults: defaults, server: "https://sync.test",
            credentials: SyncCredentials(read: { _ in try await failedGate.wait() }, save: { _, _ in }, remove: { _ in }),
            vault: fakeVault(), transport: { _ in fatalError("No network permitted") })
        lateFailure.start(); await failedGate.awaitEntered()
        let failedWait = Task { await lateFailure.awaitLoginRestore() }
        await Task.yield(); await lateFailure.prepareToQuit()
        failedGate.finish(.failure(ConfigurationError("Late fixture error")))
        await failedWait.value
        precondition(lateFailure.error == nil && !lateFailure.restoringLogin && !lateFailure.credentialsReady,
            "An error delivered after shutdown must not publish UI state")

        var attempts = 0
        let retry = SettingsSync(store: store, hid: hid, files: files, defaults: defaults, server: "https://sync.test",
            credentials: SyncCredentials(read: { _ in
                attempts += 1
                if attempts == 1 { throw ConfigurationError("Fixture Keychain unavailable") }
                return nil
            }, save: { _, _ in }, remove: { _ in }), vault: fakeVault(),
            transport: { _ in fatalError("Startup must not contact network") })
        retry.start(); await retry.awaitLoginRestore()
        precondition(!retry.credentialsReady && !retry.restoringLogin && retry.error?.contains("unavailable") == true)
        retry.retryLoginRestore(); await retry.awaitLoginRestore()
        precondition(attempts == 2 && retry.credentialsReady && retry.account == nil && retry.error == nil)
        retry.start(); retry.retryLoginRestore()
        precondition(attempts == 2, "Success must not spawn another read")
        await retry.prepareToQuit()

        let authGate = CredentialSuspension<(Data, URLResponse)>()
        var authRequests = 0, authWrites = 0
        let auth = SettingsSync(store: store, hid: hid, files: files, defaults: defaults, server: "https://sync.test",
            credentials: SyncCredentials(read: { _ in nil }, save: { _, _ in authWrites += 1 }, remove: { _ in removals += 1 }),
            vault: fakeVault(), transport: { request in
                authRequests += 1
                if authRequests == 1 { return try await authGate.wait() }
                return (try JSONEncoder().encode(account), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        auth.start(); await auth.awaitLoginRestore()
        let cancelledAuth = Task { await auth.authenticate(email: "fixture", password: "fixture-password", create: false) }
        await authGate.awaitEntered()
        cancelledAuth.cancel()
        let response = HTTPURLResponse(url: URL(string: "https://sync.test/login")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        authGate.finish(.success((Data(#"{"error":"expired fixture"}"#.utf8), response)))
        await cancelledAuth.value
        precondition(!auth.busy && auth.account == nil && auth.error == nil && removals == 0 && authWrites == 0)
        await auth.authenticate(email: "fixture", password: "fixture-password", create: false)
        await auth.vault.awaitLocalRestore()
        precondition(auth.account == account && !auth.busy && authWrites == 1,
            "Cancelled operation cleanup must allow a later successful sign-in")
        await auth.prepareToQuit()

        for lateWriteFails in [false, true] {
            let writeGate = CredentialSuspension<Void>()
            var delayedWrites = 0
            let delayedAuth = SettingsSync(store: store, hid: hid, files: files, defaults: defaults, server: "https://sync.test",
                credentials: SyncCredentials(read: { _ in nil }, save: { _, _ in
                    delayedWrites += 1; try await writeGate.wait()
                }, remove: { _ in preconditionFailure("Delayed sign-in must not remove credentials") }),
                vault: fakeVault(), transport: { request in
                    (try JSONEncoder().encode(account), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            delayedAuth.start(); await delayedAuth.awaitLoginRestore()
            let pendingWrite = Task { await delayedAuth.authenticate(email: "fixture", password: "fixture-password", create: false) }
            await writeGate.awaitEntered()
            precondition(delayedAuth.busy && delayedWrites == 1)
            var heartbeat = false
            await Task { @MainActor in heartbeat = true }.value
            precondition(heartbeat, "Suspended credential persistence must leave the main actor responsive")
            await delayedAuth.prepareToQuit()
            if lateWriteFails { writeGate.finish(.failure(ConfigurationError("Late fixture write failed"))) }
            else { writeGate.finish(.success(())) }
            await pendingWrite.value
            precondition(delayedAuth.account == nil && delayedAuth.vault.account == nil && delayedAuth.error == nil && !delayedAuth.busy,
                "Neither a late credential write result nor its error may publish an account, vault state, or UI changes after quit")
        }

        var expiredRequests = 0, expiredRemovals = 0
        let expired = SettingsSync(store: store, hid: hid, files: files, defaults: defaults, server: "https://sync.test",
            credentials: SyncCredentials(read: { _ in account }, save: { _, _ in }, remove: { _ in
                expiredRemovals += 1; throw CredentialWorkerError.busy
            }), vault: fakeVault(), transport: { request in
                expiredRequests += 1
                return (Data(#"{"error":"fixture expired"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            })
        expired.start(); await expired.awaitLoginRestore(); await expired.vault.awaitLocalRestore()
        let expiredPreview = await expired.prepareCloudLoad()
        precondition(expiredPreview == nil && expired.account == nil && !expired.busy)
        precondition(expired.error?.contains("saved login could not be removed") == true,
            "Failed credential deletion must never imply the saved login was erased")
        await Task.yield()
        precondition(expiredRequests == 1 && expiredRemovals == 1, "Expired credentials must not trigger hidden retries")
        await expired.prepareToQuit()
    }
}
