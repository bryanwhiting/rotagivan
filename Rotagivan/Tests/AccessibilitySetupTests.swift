import AppKit
import SwiftUI

@main struct AccessibilitySetupTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = output.appendingPathComponent("Rotagivan Test.app", isDirectory: true)
        let contents = fixture.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "local.rotagivan", "CFBundleName": "Rotagivan"], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        precondition(AccessibilityAppFile.validatedURL(fixture) == fixture.standardizedFileURL)
        precondition(AccessibilityAppFile.validatedURL(output) == nil)
        precondition(AccessibilityAppFile.validatedURL(URL(string: "https://example.com/Rotagivan.app")!) == nil)
        precondition(AccessibilityAppFile.validatedURL(URL(fileURLWithPath: "/Applications/System Settings.app")) == nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        precondition(pasteboard.writeObjects([AccessibilityAppFile.pasteboardWriter(for: fixture)!]))
        let fileURL = pasteboard.string(forType: .fileURL)!
        precondition(URL(string: fileURL) == fixture.standardizedFileURL, "Drag must carry the actual app file URL, including encoded spaces")

        var permission = false
        var grants = 0
        var settingsRequests = 0
        var revealed: URL?
        let state = AccessibilitySetupState(probe: { permission })
        let controller = AccessibilitySetupController(state: state, appURL: fixture,
            openSettings: { settingsRequests += 1; return false }, revealApp: { revealed = $0 })
        controller.show { grants += 1 }
        let panel = controller.panel!
        let host = panel.contentView!
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        func elements(_ object: Any) -> [AnyObject] {
            let item = object as AnyObject
            return [item] + (item.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func find(_ id: String) -> AnyObject {
            guard let item = views(host).flatMap(elements).first(where: { $0.accessibilityIdentifier?() == id }) else {
                preconditionFailure("Missing native control: \(id)")
            }
            return item
        }
        func press(_ id: String) {
            precondition(find(id).accessibilityPerformPress?() == true)
            settle()
        }
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        settle()
        precondition(state.isMonitoring && !state.trusted && grants == 0)
        precondition(panel.level == .floating && !panel.hidesOnDeactivate, "Guide must remain visible beside System Settings")
        let drag = views(host).compactMap { $0 as? AccessibilityAppDragView }.first!
        precondition(drag.appURL == fixture.standardizedFileURL)
        _ = find("accessibility-app-drag")
        _ = find("accessibility-check-again")
        try capture("accessibility-waiting")
        press("accessibility-open-settings")
        precondition(settingsRequests == 1 && state.settingsOpenFailed)
        press("accessibility-show-finder")
        precondition(revealed == fixture.standardizedFileURL)
        try capture("accessibility-settings-fallback")
        permission = true
        press("accessibility-check-again")
        precondition(state.trusted && grants == 1)
        state.refresh(); state.startMonitoring()
        precondition(grants == 1, "Repeated checks must not reconnect repeatedly")
        try capture("accessibility-granted")
        permission = false; state.refresh()
        precondition(!state.trusted)
        permission = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        precondition(state.trusted && grants == 2, "Grant is detected while guide is open without pressing a button")
        press("accessibility-close")
        precondition(!state.isMonitoring && !panel.isVisible)
        controller.show { grants += 1 }; settle()
        precondition(controller.panel === panel && state.isMonitoring && grants == 2)
        panel.close(); settle()
        precondition(!state.isMonitoring && state.onGranted == nil)
        print("Accessibility setup PASS: app file-URL drag payload, invalid-target rejection, native guide controls, settings/Finder fallbacks, live grant/revoke/regrant, one reconnect per transition, reuse and timer cleanup. No real permissions or settings changed.")
        print("Screenshots: \(output.path)")
    }
}
