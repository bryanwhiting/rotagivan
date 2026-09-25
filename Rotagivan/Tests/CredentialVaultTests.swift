import AppKit
import SwiftUI
import Foundation

@MainActor private final class VaultServerFixture {
    var record: VaultRecord?
    var devices: [VaultDevice] = []
    var puts = 0
    var losePutReply = false
    var delay: UInt64 = 0
    let userID = "fixture-account"
    func call(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let path = request.url!.path
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let bytes = request.httpBody {
            let text = String(data: bytes, encoding: .utf8)!
            precondition(!text.contains("fixture-api-key"), "Plaintext API key must never go over the vault transport")
        }
        var output = Data()
        if request.httpMethod == "GET" {
            output = try JSONEncoder().encode(VaultRemote(vault: record, devices: devices))
        } else if request.httpMethod == "PUT" {
            puts += 1
            let value = VaultRecord(vaultID: body["vaultID"] as! String, publicKey: body["publicKey"] as! String,
                ciphertext: body["ciphertext"] as! String, signature: body["signature"] as! String,
                revision: (body["baseRevision"] as! Int) + 1, updatedAt: Date().timeIntervalSince1970)
            try VaultCrypto.verify(value, userID: userID)
            record = value
            if losePutReply { losePutReply = false; throw URLError(.networkConnectionLost) }
            output = try JSONEncoder().encode(value)
        } else if path.hasSuffix("/devices") {
            let publicKey = body["publicKey"] as! String
            let id = VaultCrypto.hex(SHA256.hash(data: try VaultCrypto.bytes(publicKey)))
            if !devices.contains(where: { $0.id == id }) {
                devices.append(VaultDevice(id: id, publicKey: publicKey, name: "Home", createdAt: Date().timeIntervalSince1970, grant: nil))
            }
            output = try JSONEncoder().encode(devices.first { $0.id == id }!)
        } else if path.hasSuffix("/approve") {
            let index = devices.firstIndex { $0.id == body["deviceID"] as? String }!
            let grant = VaultGrant(ephemeralKey: body["ephemeralKey"] as! String, ciphertext: body["ciphertext"] as! String,
                                   signature: body["signature"] as! String)
            devices[index].grant = String(data: try JSONEncoder().encode(grant), encoding: .utf8)!
            output = Data("{\"ok\":true}".utf8)
        } else { fatalError("Unexpected request") }
        return (output, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}
import CryptoKit

@main struct CredentialVaultTests {
    @MainActor static func main() async throws {
        let server = VaultServerFixture()
        let account = VaultAccount(token: "fixture-token", userID: server.userID)
        var workStorage: VaultLocal?, homeStorage: VaultLocal?, recoveryStorage: VaultLocal?
        func client(read: @escaping () -> VaultLocal?, write: @escaping (VaultLocal) throws -> Void) -> CredentialVault {
            let result = CredentialVault(server: "https://fixture.test", transport: { try await server.call($0) },
                read: { _, _ in read() }, write: { value, _, _ in try write(value) })
            result.setAccount(account)
            return result
        }
        let work = client(read: { workStorage }, write: { workStorage = $0 })
        precondition(server.puts == 0, "Sign in/start must not upload")
        await work.save(apiKey: "fixture-api-key-first")
        precondition(work.error == nil && work.unlocked && server.puts == 1 && workStorage?.masterKey != nil)
        let first = server.record!
        let home = client(read: { homeStorage }, write: { homeStorage = $0 })
        await home.load()
        precondition(!home.unlocked && home.hasRemote, "Login alone cannot decrypt")
        await home.requestAccess()
        precondition(home.ownCode != nil && homeStorage?.masterKey == nil)
        await work.load()
        precondition(work.pending.count == 1)
        let device = work.pending[0]
        await work.approve(device, verificationCode: "0000-0000-0000-0000-0000-0000")
        precondition(work.error != nil && server.devices[0].grant == nil)
        await work.approve(device, verificationCode: home.ownCode!)
        precondition(work.error == nil && server.devices[0].grant != nil)
        work.setAccount(nil) // Approver can be offline before Home retrieves it.
        await home.load()
        precondition(home.unlocked && homeStorage?.masterKey == workStorage?.masterKey)
        let decrypted = try VaultCrypto.open(homeStorage!.cached!, master: homeStorage!.masterKey!, userID: account.userID)
        precondition(decrypted.openRouterAPIKey == "fixture-api-key-first")
        work.setAccount(account)
        work.showRecoveryCode()
        let recovery = client(read: { recoveryStorage }, write: { recoveryStorage = $0 })
        await recovery.recover("RV1-" + String(repeating: "0", count: 64))
        precondition(!recovery.unlocked && recoveryStorage == nil)
        await recovery.recover(work.recoveryCode!)
        precondition(recovery.unlocked && recoveryStorage?.masterKey == workStorage?.masterKey)
        await work.save(apiKey: "fixture-api-key-next")
        precondition(work.error == nil && server.record?.revision == 2)
        await home.save(apiKey: "fixture-api-key-stale")
        precondition(home.error != nil && server.puts == 2)
        await home.load()
        precondition(homeStorage?.highestRevision == 2)
        server.record = first
        await home.load()
        precondition(home.error != nil && homeStorage?.highestRevision == 2, "Rollback is rejected")
        server.record = workStorage!.cached
        let before = homeStorage?.highestRevision
        server.delay = 50_000_000
        let inFlight = Task { await home.load() }
        await Task.yield()
        home.setAccount(VaultAccount(token: "other", userID: "different-user"))
        await inFlight.value
        precondition(!home.unlocked && homeStorage?.highestRevision == before)
        server.delay = 0

        let emptyServer = VaultServerFixture()
        var interrupted: VaultLocal?
        let interruptedClient = CredentialVault(server: "https://fixture.test", transport: { try await emptyServer.call($0) },
            read: { _, _ in interrupted }, write: { value, _, _ in interrupted = value })
        interruptedClient.setAccount(account)
        emptyServer.losePutReply = true
        await interruptedClient.save(apiKey: "fixture-api-key-first")
        precondition(interrupted?.masterKey != nil && interruptedClient.error != nil)
        await interruptedClient.load()
        precondition(interruptedClient.unlocked, "Lost create response recovers with the persisted original key")
        let unavailable = CredentialVault(server: "https://fixture.test", transport: { try await emptyServer.call($0) },
            read: { _, _ in nil }, write: { _, _, _ in throw VaultFailure.message("Keychain unavailable") })
        unavailable.setAccount(account)
        let putsBefore = emptyServer.puts
        await unavailable.requestAccess()
        precondition(unavailable.error != nil && emptyServer.devices.isEmpty && emptyServer.puts == putsBefore)

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: CredentialVaultView(vault: work).padding().frame(width: 680).background(Color(NSColor.windowBackgroundColor)).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        if let directory = CommandLine.arguments.dropFirst().first,
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("vault-settings.png"))
        }
        window.close()
        work.shutdown(); home.shutdown(); recovery.shutdown(); interruptedClient.shutdown(); unavailable.shutdown()
        print("Credential vault PASS: two-device asynchronous approval, recovery, no plaintext transport, stale saves, rollback, account switching, lost reply, Keychain failure, UI render")
    }
}

