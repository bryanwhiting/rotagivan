import AppKit
import SwiftUI

/// Runs with an isolated defaults suite; never starts HID, sync, or action execution.
@main struct HotkeyGestureAssignmentTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let suite = "Rota.HotkeyGestureAssignment.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rota.v1")
        let store = SettingsStore(defaults: defaults)
        store.settings = StoredSettings()
        store.settings.actionBindings = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(store.settings)
        let catalog = ActionCatalogSnapshot()
        let host = NSHostingView(rootView: HotkeyOrganizerView(store: store, catalog: catalog)
            .padding(20).defaultAppStorage(defaults))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 790),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil); panel.close() }

        func wait(_ message: String, until condition: () -> Bool) {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !condition() {
                precondition(ProcessInfo.processInfo.systemUptime < deadline, message)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func accessible(_ object: Any) -> [AnyObject] {
            let value = object as AnyObject
            return [value] + (value.accessibilityChildren?() ?? []).flatMap(accessible)
        }
        func elements(_ view: NSView) -> [AnyObject] { descendants(view).flatMap(accessible) }
        func button(_ title: String, in view: NSView) -> AnyObject {
            guard let value = elements(view).first(where: { $0.accessibilityLabel?() == title }) else {
                preconditionFailure("Missing button: \(title)")
            }
            return value
        }
        wait("Catalog did not finish") { catalog.value != nil && !catalog.isRefreshing }
        guard let search = descendants(host).compactMap({ $0 as? NSTextField }).first(where: {
            $0.isEditable && $0.placeholderString == "Search actions, apps or shortcuts"
        }) else { preconditionFailure("Missing action search") }
        search.stringValue = "Lock Screen"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        let id = "assign-action-hotkey-" + VoiceRegisteredAction.id(for: .command(.lockScreen))
        wait("Missing inline Assign hotkey button") { elements(host).contains { $0.accessibilityIdentifier?() == id } }
        let assign = elements(host).first { $0.accessibilityIdentifier?() == id }!
        precondition(assign.accessibilityPerformPress?() == true)
        wait("Assign hotkey did not open its editor") { panel.sheets.first?.contentView != nil }
        let sheet = panel.sheets.first!.contentView!
        wait("Assign hotkey must offer trackpad gestures") {
            descendants(sheet).contains { ($0 as? NSPopUpButton)?.title == "Trackpad tap or swipe" }
        }
        precondition(elements(sheet).contains {
            ($0.accessibilityLabel?() ?? "").contains("Action: Lock Screen")
        }, "The clicked action must remain preselected")
        precondition(button("Cancel", in: sheet).accessibilityPerformPress?() == true)
        wait("Cancel did not dismiss the draft") { panel.sheets.isEmpty }
        let afterCancel = try encoder.encode(store.settings)
        precondition(afterCancel == before, "Cancel must not write settings")
        // Cover every existing direction and finger-count variant through the
        // same model validation, persistence and global routing used by Save.
        let key = RecordedShortcut(keyCode: 40, modifiers: 1 << 20, keyLabel: "K")
        for gesture in AppGestureTrigger.allCases {
            let trigger = BindingTrigger(gesture: gesture)
            precondition(trigger.gesture == gesture && trigger.keyboard == nil && trigger.isValid,
                "A gesture hotkey must remain a valid non-keyboard trigger")
            let binding = ActionBinding(trigger: trigger, action: .command(.lockScreen))
            precondition([binding].isValidBindings(global: true))
            precondition(![binding, ActionBinding(trigger: trigger, action: .media(.mute))].isValidBindings(global: true),
                "Duplicate gestures remain invalid")
            let roundtrip = try JSONDecoder().decode(ActionBinding.self, from: encoder.encode(binding))
            precondition(roundtrip == binding)
            var settings = StoredSettings()
            settings.actionBindings = [binding]
            let resolved = settings.applyingActionBindings(to: settings.gestures(for: settings.resolvedDefaultProfileID))
            let assignment = gesture.assignment(in: resolved)
            precondition(assignment.enabled && assignment.binding.shortcut.map { BindingAction.from(shortcut: $0) } == binding.action,
                "Every selectable gesture must route through existing global binding resolution")
        }
        precondition(!BindingTrigger(keyboard: key, gesture: .twoFingerLeft).isValid,
            "A binding must not combine a keyboard shortcut and a gesture")
        precondition(!BindingTrigger().isValid, "Unassigned drafts must remain invalid")
        let keyboardBinding = ActionBinding(trigger: BindingTrigger(keyboard: key), action: .command(.lockScreen))
        precondition([keyboardBinding].isValidBindings(global: true))
        precondition(![keyboardBinding].isValidBindings(global: true, reservedKeys: [key]))
        let bareLetter = ActionBinding(trigger: BindingTrigger(keyboard: RecordedShortcut(keyCode: 0, modifiers: 0, keyLabel: "A")),
            action: .command(.lockScreen))
        precondition(![bareLetter].isValidBindings(global: true), "Global keyboard validation must remain unchanged")
        print("Hotkey gesture assignment passed: real inline sheet, preselected action, nonmutating cancel, all \(AppGestureTrigger.allCases.count) gesture variants, mutually exclusive keyboard/gesture triggers, JSON roundtrip, duplicate/reserved/global validation and gesture routing. No live input or actions executed.")
    }
}
