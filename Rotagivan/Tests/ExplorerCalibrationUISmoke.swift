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
        settings.setFavorite(AppExplorerFavorite(direction: .right, name: "Project docs", url: "https://example.com/docs"), at: .right)
        store.settings.appExplorer = settings
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .up }) != nil)
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .up })?.size == NSSize(width: 16, height: 16))
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .left }) != nil)
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .right }) == nil, "Web favorites keep their globe icon")
        precondition(AppExplorerSettingsView.applicationIcon(for: nil) == nil)
        precondition(AppExplorerSettingsView.applicationIcon(for: AppExplorerFavorite(direction: .down, bundleID: "invalid.rotagivan.missing-app", name: "Missing app")) == nil)
        try render(AppExplorerSettingsView(store: store).padding(24).frame(width: 680, height: 570)
            .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 680, height: 570), path: CommandLine.arguments[1] + "/settings.png")
        precondition(store.settings.appExplorer == settings)
        try render(ExplorerURLFavoriteEditor(direction: .right, name: "Project docs", address: "https://example.com/docs", onSave: { _ in }, onCancel: {}),
            size: CGSize(width: 440, height: 300), path: CommandLine.arguments[1] + "/url-editor.png")
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
        var openedURLs: [URL] = []
        controller.openWebURL = { openedURLs.append($0); return true }
        controller.show(waitingForLift: false)
        precondition(controller.isVisible)
        let hud = NSApp.windows.first { $0.title == "App Explorer" }!.contentView!
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hud.layoutSubtreeIfNeeded()
        let bitmap = hud.bitmapImageRepForCachingDisplay(in: hud.bounds)!
        hud.cacheDisplay(in: hud.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/hud.png"))
        func report(_ x: Double?) -> TrackpadReport {
            TrackpadReport(contacts: x.map { [FingerContact(id: 0, x: $0, y: 500, touching: true, confident: true)] } ?? [], buttonDown: false, scanTime: 0)
        }
        controller.process(report(500)); controller.process(report(600)); controller.process(report(nil))
        controller.process(report(nil))
        precondition(!controller.isVisible && openedURLs.map(\.absoluteString) == ["https://example.com/docs"], "Open web favorite exactly once, through URL opener, not app activation")
        var openedApps: [URL] = []
        controller.openApplication = { url, options in
            precondition(!controller.isVisible, "HUD must close before activating an app")
            precondition(options.activates && !options.hides && !options.hidesOthers)
            precondition(!options.createsNewApplicationInstance && options.allowsRunningApplicationSubstitution)
            openedApps.append(url)
        }
        func chooseLeft() {
            controller.show(waitingForLift: false)
            controller.process(report(500)); controller.process(report(400)); controller.process(report(nil))
        }
        chooseLeft()
        precondition(openedApps.isEmpty, "Defer app activation until panel teardown completes")
        controller.dismiss() // Releasing the hold key after selection must not cancel the committed launch.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(openedApps.count == 1 && openedApps[0].lastPathComponent == "Finder.app")
        chooseLeft()
        controller.show(waitingForLift: false) // A newer HUD supersedes any queued activation.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(openedApps.count == 1)
        controller.dismiss()
        controller.show(waitingForLift: false)
        controller.setAlternateHeld(true)
        precondition(!controller.isVisible, "Changing modes cancels any partial selection")
        controller.show(waitingForLift: false)
        precondition(controller.isVisible)
        controller.dismiss()
        print("Favorites settings, triple-tap result, and both HUD modes passed native UI smoke checks.")
    }
}
