import AppKit
import SwiftUI

@main struct ReleaseSettingsTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        // SwiftUI creates its semantic AX nodes only when accessibility is requested.
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let suite = "Rotagivan.ReleaseSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        store.settings.appExplorer = AppExplorerSettings()
        store.settings.appOverrides = []
        let hid = NavigatorHIDManager(store: store)
        let sync = SettingsSync(store: store, hid: hid) // Never start input, microphone, or sync.

        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func elements(_ object: Any) -> [AnyObject] {
            // SwiftUI.AccessibilityNode implements these ObjC methods without declaring
            // NSAccessibilityProtocol conformance, so a protocol cast loses real controls.
            let element = object as AnyObject
            return [element] + (element.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func semanticElements(in host: NSView) -> [AnyObject] {
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            return views(host).flatMap(elements)
        }
        func find(_ identifier: String, in host: NSView) -> AnyObject? {
            let accessible = semanticElements(in: host)
            if ProcessInfo.processInfo.environment["DEBUG_RELEASE_AX"] == "1" {
                for element in accessible {
                    let line = "AX \(element.accessibilityRole?()?.rawValue ?? "nil") | \(element.accessibilityIdentifier?() ?? "nil") | \(element.accessibilityLabel?() ?? "nil")\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
            return accessible.first { $0.accessibilityIdentifier?() == identifier }
        }
        func render(_ section: String, check: (NSView) -> Void) {
            let host = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync,
                initialSection: section).defaultAppStorage(defaults))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 740),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            settle()
            host.layoutSubtreeIfNeeded()
            check(host)
            if let directory = CommandLine.arguments.dropFirst().first,
               ["Voice mode", "Actions"].contains(section),
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let destination = URL(fileURLWithPath: directory).appendingPathComponent("release-\(section).png")
                try! bitmap.representation(using: .png, properties: [:])!.write(to: destination)
            }
            panel.orderOut(nil)
            panel.close()
        }
        render("Voice mode") { host in
            precondition(find("settings-section-Voice mode", in: host) != nil)
            precondition(find("settings-section-Calibration", in: host) == nil)
            precondition(find("settings-section-App overrides", in: host) == nil)
            guard let autoDecide = find("voice-auto-decide", in: host) else {
                preconditionFailure("Voice mode must render its confirmation setting")
            }
            precondition(find("voice-auto-start", in: host) != nil,
                "Voice mode must render automatic listening without starting the microphone")
            precondition(autoDecide.accessibilityPerformPress?() == true)
            settle()
            precondition(store.settings.appExplorer?.resolvedVoiceAutoDecide == true,
                "The rendered toggle must update the selected profile")
            precondition(store.settings.appExplorer?.resolvedVoiceAutoStart == false)
        }
        render("General") { host in
            precondition(find("voice-auto-decide", in: host) == nil)
            precondition(find("voice-auto-start", in: host) == nil)
        }
        for section in ["Actions", "Calibration", "App overrides"] {
            render(section) { host in
                precondition(find("manage-application-overrides", in: host) != nil,
                    "Overrides must remain reachable with no application rows, including legacy navigation")
                precondition(find("tap-calibration", in: host) != nil,
                    "Actions and legacy calibration navigation must expose shared tap calibration")
            }
        }
        store.settings.appOverrides = [AppGestureOverride(bundleID: "test.disabled", name: "Disabled", enabled: false)]
        render("Actions") { host in
            precondition(find("manage-application-overrides", in: host) != nil,
                "Disabled overrides must remain manageable")
        }
        let savedProfile = store.addProfile()
        store.setActiveProfile(savedProfile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settingsBefore = try encoder.encode(store.settings)
        let activeBefore = store.activeProfileID
        let motionBefore = store.activeProfile
        let shortcutsBefore = ShortcutSettings.shared.additional
        let actionShortcutsBefore = ShortcutSettings.shared.profileActions
        for section in ["Pointer & scrolling", "Pointer layers", "Profiles", "Unknown legacy section"] {
            render(section) { host in
                let labels = semanticElements(in: host).compactMap { $0.accessibilityLabel?() }
                precondition(!labels.contains("Pointer layers"),
                    "Pointer settings and legacy routes must not expose the pointer-layer editor")
                if section != "Unknown legacy section" {
                    precondition(!labels.contains("Add layer"), "Pointer settings must not expose pointer layer creation")
                    precondition(find("pointer-device-picker", in: host) != nil && find("pointer-pane-navigator", in: host) != nil,
                        "Pointer settings must retain device-specific motion controls")
                }
            }
            let settingsAfter = try encoder.encode(store.settings)
            precondition(settingsAfter == settingsBefore,
                "Removing the pointer-layer editor must preserve saved profiles and settings")
            precondition(store.activeProfileID == activeBefore && store.activeProfile == motionBefore,
                "Rendering current and legacy settings routes must preserve effective pointer behavior")
            precondition(ShortcutSettings.shared.additional == shortcutsBefore && ShortcutSettings.shared.profileActions == actionShortcutsBefore,
                "Saved profile activation and action shortcuts must remain intact")
        }
        precondition(hid.calibrationSession == nil)
        print("Release settings native UI passed: Voice controls, calibration and overrides routes, pointer-layer editor removal, legacy navigation, and preserved pointer settings/profiles/shortcuts. No microphone, live input, or sync started.")
    }
}
