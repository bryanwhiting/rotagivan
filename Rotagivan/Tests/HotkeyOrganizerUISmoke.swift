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
        store.settings.hotkeyDictionary = [NamedHotkey(name: "Capture selection", shortcut: shortcut, activationShortcut: shortcut)]
        var taps = store.settings.gestures(for: 1)
        taps.gestures.tapToClick = true; taps.oneFingerTap = .shortcut; taps.oneFingerShortcut = shortcut
        store.updateGestures(taps, for: 1)
        store.settings.appOverrides = [AppGestureOverride(bundleID: "test.editor", name: "Editor", bindings: [AppGestureBinding(trigger: .oneFingerTap, action: .rightClick)])]
        store.settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .left, name: "Old label", shortcut: shortcut)])
        let hid = NavigatorHIDManager(store: store) // Never start live input or sync.
        let sync = SettingsSync(store: store, hid: hid)
        let host = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync, initialSection: "Keybindings and Macros"))
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
        click(494, 228)
        try snapshot("hotkey-conflicts")
        click(666, 228)
        try snapshot("hotkey-assignments")
        click(838, 228)
        try snapshot("hotkey-keyboard")
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
        let macro = NamedHotkey(name: "Copy and paste", shortcut: shortcut,
            steps: [shortcut, RecordedShortcut(keyCode: 9, modifiers: 1 << 20, keyLabel: "V")], stepDelayMilliseconds: 100)
        store.settings.hotkeyDictionary = [macro]
        let editorLayer = ExplorerHoldLayer(name: "Editor commands", holdShortcut: nil,
            favorites: [AppExplorerFavorite(direction: .left, name: macro.name, shortcut: .macro(macro),
                activationShortcut: RecordedShortcut(keyCode: 3, modifiers: 1 << 20, keyLabel: "F"))],
            launchShortcut: RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17"), appBundleID: "test.editor", appName: "Editor")
        store.settings.appExplorer = AppExplorerSettings(holdLayers: [editorLayer])
        controller.frontmostBundleID = { "other.app" }
        controller.showLayer(editorLayer.id, waitingForLift: false)
        precondition(controller.isVisible && controller.displayedEntries.first?.shortcut?.macroID == macro.id,
            "Legacy app metadata must not restrict a global HUD launch")
        precondition(controller.displayedEntries.first?.name == "Copy and paste (Cmd+Shift+C → Cmd+V)")
        controller.dismiss()
        store.settings.appExplorer?.favorites = [AppExplorerFavorite(direction: .right, name: "Editor layer", shortcut: .hudLayer(editorLayer))]
        controller.show(waitingForLift: false)
        for x in [500.0, 650.0] {
            controller.process(TrackpadReport(contacts: [FingerContact(id: 0, x: x, y: 500, touching: true, confident: true)], buttonDown: false, scanTime: 0))
        }
        controller.process(TrackpadReport(contacts: [], buttonDown: false, scanTime: 0))
        precondition(controller.isVisible && controller.displayedEntries.first?.shortcut?.macroID == macro.id,
            "A HUD-layer tile switches in place without dismissing the HUD or releasing its pointer lock")
        controller.dismiss()
        controller.showLayer(UUID(), waitingForLift: false)
        precondition(!controller.isVisible, "Removed layers must not fall back to unrelated tiles")
        func renderEditor<V: View>(_ view: V, name: String, size: NSSize) throws {
            let editorHost = NSHostingView(rootView: view)
            let window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = editorHost
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            editorHost.layoutSubtreeIfNeeded()
            let bitmap = editorHost.bitmapImageRepForCachingDisplay(in: editorHost.bounds)!
            editorHost.cacheDisplay(in: editorHost.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name + ".png"))
        }
        try renderEditor(NamedHotkeyEditor(entry: macro, existing: [macro], onSave: { _ in }, onCancel: {}), name: "macro-editor", size: NSSize(width: 608, height: 570))
        var appMacro = macro
        appMacro.steps = nil
        appMacro.sequence = [.app(bundleID: "test.editor", name: "Editor"), .key(shortcut), .key(RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return"))]
        appMacro.activationShortcut = RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17")
        try renderEditor(NamedHotkeyEditor(entry: appMacro, existing: [appMacro], requiresGlobalHotkey: true, onSave: { _ in }, onCancel: {}), name: "macro-app-editor", size: NSSize(width: 638, height: 650))
        try renderEditor(HUDLayerHotkeyEditor(store: store, layer: editorLayer, settings: store.settings.appExplorer!,
            onSave: { _, _ in true }, onCancel: {}), name: "hud-layer-editor", size: NSSize(width: 560, height: 720))
        let defaultLayer = ExplorerHoldLayer(name: "Default", holdShortcut: nil,
            favorites: editorLayer.favorites, slotCount: 8)
        try renderEditor(HUDLayerHotkeyEditor(store: store, layer: defaultLayer,
            settings: store.settings.appExplorer!, onSave: { _, _ in true }, onCancel: {},
            isDefaultLayer: true), name: "default-hud-hotkeys", size: NSSize(width: 620, height: 560))
        print("Macro and HUD layer native UI passed: custom and default action-hotkey pairs render, legacy global launch remains compatible, unknown-target rejection and sequence labels. No real events posted.")
        print("Hotkey UI rendered saved actions, tap assignments, audit, exact-hotkey search and keyboard map; no actual shortcuts sent.")
    }
}
