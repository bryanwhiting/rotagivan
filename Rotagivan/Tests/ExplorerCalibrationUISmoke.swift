// Renders isolated settings and a completed calibration; emits no input events.
import AppKit
import SwiftUI

@main struct ExplorerCalibrationUISmoke {
    @MainActor static func render<V: View>(_ root: V, size: CGSize, path: String) throws {
        let view = NSHostingView(rootView: root)
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.ExplorerCalibrationUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var settings = AppExplorerSettings()
        settings.setFavorite(AppExplorerFavorite(direction: .up, bundleID: "com.apple.Safari", name: "Safari"), at: .up)
        settings.setFavorite(AppExplorerFavorite(direction: .left, bundleID: "com.apple.finder", name: "Finder"), at: .left)
        store.settings.appExplorer = settings
        try render(AppExplorerSettingsView(store: store).padding(24).frame(width: 680, height: 570)
            .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 680, height: 570), path: CommandLine.arguments[1] + "/settings.png")
        precondition(store.settings.appExplorer == settings)
        var taps = store.settings.gestures(for: 1)
        taps.gestures.tapMaxDuration = 0.2
        taps.gestures.tapMaxMovement = 30
        let session = GestureCalibrationSession(profileID: 1, profileName: "Default", mode: .tripleTap, gestures: taps)
        func send(_ t: Double, down: Bool) {
            session.process(TrackpadReport(contacts: down ? [FingerContact(id: 0, x: 500, y: 500, touching: true, confident: true)] : [], buttonDown: false, scanTime: 0), at: t)
        }
        send(0, down: false)
        for i in 0..<10 {
            let t = 1 + Double(i) * 2
            send(t, down: true); send(t + 0.03, down: false)
            send(t + 0.15, down: true); send(t + 0.18, down: false)
            send(t + 0.4, down: true); send(t + 0.43, down: false)
        }
        precondition(session.isComplete)
        try render(GestureCalibrationView(session: session, onApply: {}, onCancel: {}),
            size: CGSize(width: 520, height: 650), path: CommandLine.arguments[1] + "/calibration.png")
        let controller = AppExplorerController(defaults: defaults)
        controller.configuration = { settings }
        controller.contextIsValid = { true }
        controller.show(waitingForLift: false)
        precondition(controller.isVisible)
        controller.setAlternateHeld(true)
        precondition(!controller.isVisible, "Changing modes cancels any partial selection")
        controller.show(waitingForLift: false)
        precondition(controller.isVisible)
        controller.dismiss()
        print("Favorites settings, triple-tap result, and both HUD modes passed native UI smoke checks.")
    }
}
