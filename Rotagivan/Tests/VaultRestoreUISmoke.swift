import AppKit
import SwiftUI

@main struct VaultRestoreUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        var continuation: CheckedContinuation<VaultLocal?, Error>?
        var attempts = 0
        let vault = CredentialVault(server: "https://fixture.test", transport: { _ in fatalError("No network") },
            read: { _, _ in
                attempts += 1
                if attempts == 1 { return try await withCheckedThrowingContinuation { continuation = $0 } }
                return nil
            }, write: { _, _, _ in fatalError("No Keychain writes") })
        vault.setAccount(VaultAccount(token: "fixture", userID: "fixture-user"))
        let host = NSHostingView(rootView: CredentialVaultView(vault: vault).padding()
            .frame(width: 720).background(Color(nsColor: .windowBackgroundColor)))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host
        panel.makeKeyAndOrderFront(nil); NSApp.activate()
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        func elements(_ object: Any) -> [AnyObject] {
            let item = object as AnyObject
            return [item] + (item.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func controls() -> [AnyObject] { views(host).flatMap(elements) }
        func button(_ label: String) -> AnyObject {
            guard let item = controls().first(where: { $0.accessibilityLabel?() == label && $0.accessibilityRole?() == .button }) else {
                preconditionFailure("Missing accessible button: \(label)")
            }
            return item
        }
        func capture(_ state: String) throws {
            host.layoutSubtreeIfNeeded(); panel.display(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("vault-restore-\(state).png"))
        }
        settle()
        precondition(continuation != nil && vault.restoringLocal && !vault.localReady)
        precondition(button("Save encrypted key").isAccessibilityEnabled?() == false)
        precondition(button("Load / refresh").isAccessibilityEnabled?() == false)
        precondition(button("Use recovery code…").isAccessibilityEnabled?() == false)
        try capture("loading")
        continuation!.resume(throwing: CredentialWorkerError.busy); continuation = nil; settle()
        precondition(!vault.restoringLocal && !vault.localReady && vault.error != nil)
        precondition(button("Save encrypted key").isAccessibilityEnabled?() == false)
        precondition(button("Use recovery code…").isAccessibilityEnabled?() == true)
        let retry = controls().first { $0.accessibilityIdentifier?() == "vault-restore-retry" }!
        precondition(retry.isAccessibilityEnabled?() == true)
        try capture("error")
        precondition(retry.accessibilityPerformPress?() == true); settle()
        precondition(vault.localReady && attempts == 2 && vault.error == nil)
        precondition(button("Save encrypted key").isAccessibilityEnabled?() == true)
        try capture("ready")
        vault.shutdown(); panel.close()
        print("Vault restore UI PASS: native loading/error gates, explicit recovery, AX retry, ready controls; no Security or network")
    }
}
