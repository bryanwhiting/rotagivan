import AppKit
import SwiftUI

@main struct ProfileRenameUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.RenameUI.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var cancelled = false
        let host = NSHostingView(rootView: ProfileNameEditor(name: store.activeConfigurationName,
            onSave: { store.renameConfiguration($0) }, onCancel: { cancelled = true }))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 428, height: 230),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host; panel.center()
        panel.makeKeyAndOrderFront(nil); NSApp.activate()
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func key(_ code: UInt16, _ characters: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)!
            if !panel.performKeyEquivalent(with: event) { panel.sendEvent(event) }
            settle()
        }
        settle()
        let field = descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        func type(_ value: String) {
            field.selectText(nil)
            let editor = panel.firstResponder as! NSTextView
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            settle()
        }
        type("  ")
        key(36, "\r")
        precondition(store.activeConfigurationName == "Default")
        type(String(repeating: "a", count: 81))
        key(36, "\r")
        precondition(store.activeConfigurationName == "Default")
        type("  Work laptop  ")
        precondition(store.activeConfigurationName == "Default", "Typing must not save partial names")
        key(36, "\r")
        precondition(store.activeConfigurationName == "Work laptop")
        type("Discard this")
        key(53, "\u{1b}")
        precondition(cancelled && store.activeConfigurationName == "Work laptop")
        panel.orderOut(nil); panel.close()
        let hid = NavigatorHIDManager(store: store)
        let sync = SettingsSync(store: store, hid: hid) // Never start input or sync.
        let settings = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync, initialSection: "Devices"))
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 740),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = settings; window.orderFront(nil); settle()
        let bitmap = settings.bitmapImageRepForCachingDisplay(in: settings.bounds)!
        settings.cacheDisplay(in: settings.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
            CommandLine.arguments[1] + "/profile-rename-settings.png"))
        window.orderOut(nil); window.close()
        print("Profile rename UI passed: editing drafts, blank/long rejection, save, cancel and settings header rendering. No live input or sync.")
    }
}
