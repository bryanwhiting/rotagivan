import AppKit
import SwiftUI

@main struct HotkeyOrganizerUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.HotkeyUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.settings = StoredSettings()
        let shortcut = RecordedShortcut(keyCode: 8, modifiers: (1 << 20) | (1 << 17), keyLabel: "C")
        store.settings.hotkeyDictionary = [NamedHotkey(name: "Capture selection", shortcut: shortcut)]
        var taps = store.settings.gestures(for: 1)
        taps.gestures.tapToClick = true; taps.oneFingerTap = .shortcut; taps.oneFingerShortcut = shortcut
        store.updateGestures(taps, for: 1)
        store.settings.appOverrides = [AppGestureOverride(bundleID: "test.editor", name: "Editor", bindings: [AppGestureBinding(trigger: .oneFingerTap, action: .rightClick)])]
        store.settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .left, name: "Old label", shortcut: shortcut)])
        let hid = NavigatorHIDManager(store: store) // Never start live input or sync.
        let sync = SettingsSync(store: store, hid: hid)
        let host = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync, initialSection: "Hotkeys"))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host
        panel.makeKeyAndOrderFront(nil); NSApp.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func snapshot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name + ".png"))
        }
        func click(_ x: CGFloat, _ y: CGFloat) {
            let point = host.convert(NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            NSApp.postEvent(event(.leftMouseUp), atStart: true)
            panel.sendEvent(event(.leftMouseDown))
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { panel.sendEvent(up) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        try snapshot("hotkey-dictionary")
        click(555, 228)
        try snapshot("hotkey-conflicts")
        click(805, 228)
        try snapshot("hotkey-assignments")
        panel.orderOut(nil); panel.close()
        let controller = AppExplorerController(defaults: defaults)
        controller.configuration = { store.settings.appExplorer! }
        controller.hotkeyDictionary = { store.settings.resolvedHotkeyDictionary }
        controller.contextIsValid = { true }
        controller.show(waitingForLift: false)
        precondition(controller.displayedEntries.first?.name == "Capture selection (Cmd+Shift+C)")
        controller.dismiss()
        store.settings.hotkeyDictionary?[0].name = "Capture renamed"
        controller.show(waitingForLift: false)
        precondition(controller.displayedEntries.first?.name == "Capture renamed (Cmd+Shift+C)", "Renames must update existing HUD assignments")
        controller.dismiss()
        store.settings.hotkeyDictionary = []
        controller.show(waitingForLift: false)
        precondition(controller.displayedEntries.first?.name == "Old label", "Removing a dictionary entry must preserve the assigned shortcut and original tile name")
        precondition(controller.displayedEntries.first?.shortcut == shortcut)
        controller.dismiss()
        print("Hotkey UI rendered dictionary, audit and assignments; HUD labels follow dictionary renames/removal without rebinding. No actual shortcuts sent.")
    }
}
