import AppKit
import SwiftUI

@main struct WebsiteActionTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func elements(_ object: Any) -> [AnyObject] {
            let value = object as AnyObject
            return [value] + (value.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func edit(current: BindingAction, create: Bool, title: String, address: String,
                  expectedName: String?, cancel: Bool = false) throws {
            var chosen: BindingAction?
            var cancelled = false
            let host = NSHostingView(rootView: ActionPickerModal(current: current, dictionary: [], layers: [], destinations: [],
                loadApplications: { [] }, onSelect: { chosen = $0 }, onCancel: { cancelled = true }))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = host
            panel.makeKeyAndOrderFront(nil); NSApp.activate()
            defer { panel.orderOut(nil); panel.close() }
            settle()
            func find(_ id: String) -> AnyObject {
                guard let result = views(host).flatMap(elements).first(where: { $0.accessibilityIdentifier?() == id }) else {
                    preconditionFailure("Missing website control: \(id)")
                }
                return result
            }
            if create {
                precondition(find("action-picker-create-website").accessibilityPerformPress?() == true)
                settle()
            }
            func field(_ placeholder: String) -> NSTextField {
                guard let field = views(host).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == placeholder }) else {
                    preconditionFailure("Missing editable text field: \(placeholder)")
                }
                return field
            }
            let titleField = field("For example, Client dashboard")
            let addressField = field("https://example.com")
            if !create {
                precondition(titleField.stringValue == (current.name ?? ""), "Editing must restore the saved title")
                precondition(addressField.stringValue == current.url, "Editing must restore the saved URL")
            }
            func type(_ text: String, in field: NSTextField) {
                panel.makeFirstResponder(field)
                let editor = field.currentEditor() as! NSTextView
                editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
                settle()
            }
            type(title, in: titleField)
            type(address, in: addressField)
            precondition(chosen == nil, "Editing must not commit or execute the action")
            host.layoutSubtreeIfNeeded()
            if !cancel, expectedName != nil, let path = CommandLine.arguments.dropFirst().first,
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let output = URL(fileURLWithPath: path)
                let imageURL = output.pathExtension.lowercased() == "png" ? output : output.appendingPathComponent("website-action.png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
            }
            if cancel {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                panel.sendEvent(event); settle()
                precondition(cancelled && chosen == nil)
                return
            }
            precondition(find("action-picker-confirm").accessibilityPerformPress?() == true)
            settle()
            guard let chosen else { preconditionFailure("Website action was not committed") }
            precondition(chosen.name == expectedName && chosen.url == address.trimmingCharacters(in: .whitespacesAndNewlines))
            precondition(chosen.targetBrowserBundleID == current.targetBrowserBundleID, "Renaming must preserve the selected browser")
            let decoded = try JSONDecoder().decode(BindingAction.self, from: JSONEncoder().encode(chosen))
            precondition(decoded == chosen && decoded.title == (expectedName ?? chosen.url!))
            let favorite = chosen.favorite(at: .up)!
            precondition(BindingAction.from(favorite: favorite) == chosen, "The named action must survive HUD assignment")
        }
        try edit(current: .media(.mute), create: true, title: "  Client dashboard  ", address: "https://example.com/dashboard", expectedName: "Client dashboard")
        var existing = BindingAction.openURL("https://example.com/old")
        existing.name = "Old title"; existing.targetBrowserBundleID = "com.google.Chrome"
        try edit(current: existing, create: false, title: "New title", address: "https://example.com/new", expectedName: "New title")
        try edit(current: existing, create: false, title: "   ", address: "https://example.com/old", expectedName: nil)
        try edit(current: existing, create: false, title: "Discard me", address: "https://example.com/unsaved", expectedName: nil, cancel: true)
        let catalog = ActionPickerCatalog.make(dictionary: [], layers: [], destinations: [], applications: [], allowPointer: false)
        precondition(ActionPickerCatalog.search(catalog, query: "sync settings", category: .all).first?.action == .command(.syncSettings))
        precondition(VoiceActionRegistry.make(settings: StoredSettings()).contains { $0.action == .command(.syncSettings) })
        print("Website action PASS: native create/title editing, existing URL/title/browser preservation, clearing title, cancel, JSON/HUD roundtrip; Sync settings catalog discovery.")
    }
}
