// Manual live macOS integration test. Args: fixture executable, scratch directory,
// persistent signing identity. Launches only disposable apps and restores focus.
import AppKit

@main struct AppExplorerActivationSmoke {
    @MainActor static func wait(_ message: String, timeout: Double = 8, until condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if !condition() { throw NSError(domain: "AppExplorerActivationSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let workspace = NSWorkspace.shared
        let previous = workspace.frontmostApplication
        let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let prefix = "local.rotagivan.activation-test." + UUID().uuidString.lowercased()
        let identifiers = [prefix + ".source", prefix + ".target"]
        let suite = prefix + ".settings"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            for app in workspace.runningApplications where identifiers.contains(app.bundleIdentifier ?? "") { app.terminate() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            defaults.removePersistentDomain(forName: suite)
            if let url = previous?.bundleURL {
                let options = AppExplorerController.activationConfiguration(); options.addsToRecentItems = false
                workspace.openApplication(at: url, configuration: options) { _, _ in }
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            }
        }
        var bundles: [URL] = []
        for (index, id) in identifiers.enumerated() {
            let bundle = scratch.appendingPathComponent("ActivationTest\(index).app")
            let macOS = bundle.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: macOS.appendingPathComponent("Fixture"))
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "Rotagivan activation test \(index)",
                "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "NSHighResolutionCapable": true]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            let signing = Process()
            signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signing.arguments = ["--force", "--sign", CommandLine.arguments[3], bundle.path]
            try signing.run(); signing.waitUntilExit()
            precondition(signing.terminationStatus == 0)
            bundles.append(bundle)
        }

        func foreground(_ url: URL) throws {
            let options = AppExplorerController.activationConfiguration(); options.addsToRecentItems = false
            var completed = false
            workspace.openApplication(at: url, configuration: options) { _, error in
                DispatchQueue.main.async { precondition(error == nil); completed = true }
            }
            try wait("Launch Services completion missing") { completed }
        }
        try foreground(bundles[1])
        try wait("Target did not launch") { workspace.runningApplications.contains { $0.bundleIdentifier == identifiers[1] } }
        var target = workspace.runningApplications.first { $0.bundleIdentifier == identifiers[1] }!
        let originalPID = target.processIdentifier
        try foreground(bundles[0])
        try wait("Source not frontmost") { workspace.frontmostApplication?.bundleIdentifier == identifiers[0] }
        let controller = AppExplorerController(defaults: defaults)
        // Launch Services excludes these /tmp fixtures from bundle-ID lookup.
        // Supply discovery only; launch and activation still use the real OS.
        controller.applicationURL = { id in identifiers.firstIndex(of: id).map { bundles[$0] } }
        controller.configuration = { AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .left, bundleID: identifiers[1], name: "Test target")]) }
        controller.contextIsValid = { true }
        controller.openApplication = { url, options, completion in
            options.addsToRecentItems = false
            workspace.openApplication(at: url, configuration: options) { app, error in
                precondition(error == nil)
                let pid = app?.processIdentifier
                Task { @MainActor in completion(pid) }
            }
        }
        func selectTarget() throws {
            controller.show(waitingForLift: false)
            precondition(controller.isVisible)
            func report(_ x: Double?) -> TrackpadReport {
                TrackpadReport(contacts: x.map { [FingerContact(id: 0, x: $0, y: 500, touching: true, confident: true)] } ?? [], buttonDown: false, scanTime: 0)
            }
            controller.process(report(500)); controller.process(report(400)); controller.process(report(nil))
            try wait("Selected app did not become frontmost") { workspace.frontmostApplication?.bundleIdentifier == identifiers[1] }
            precondition(!controller.isVisible)
        }
        try selectTarget()
        precondition(workspace.frontmostApplication?.processIdentifier == originalPID, "Must reuse an existing instance")
        print("Live running-app selection activated the existing process.")

        try foreground(bundles[0])
        try wait("Source not frontmost") { workspace.frontmostApplication?.bundleIdentifier == identifiers[0] }
        target.hide()
        try wait("Target did not hide") { target.isHidden }
        try selectTarget()
        try wait("Hidden app was not unhidden") { !target.isHidden }
        precondition(workspace.frontmostApplication?.processIdentifier == originalPID)
        print("Live hidden-app selection unhid and activated the existing process.")

        target.terminate()
        try wait("Disposable target did not quit") { target.isTerminated }
        try foreground(bundles[0])
        try wait("Source not frontmost") { workspace.frontmostApplication?.bundleIdentifier == identifiers[0] }
        try selectTarget()
        target = workspace.runningApplications.first { $0.bundleIdentifier == identifiers[1] }!
        precondition(target.processIdentifier != originalPID)
        precondition(workspace.runningApplications.filter { $0.bundleIdentifier == identifiers[1] }.count == 1)
        print("Live closed-app selection launched and activated exactly one new process.")
    }
}
