import AppKit
import SwiftUI

@main struct ActionPickerTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let macro = NamedHotkey(name: "Research workspace", shortcut: RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C"))
        let apps = [ExplorerApplication(bundleID: "test.slack", name: "Slack", url: URL(fileURLWithPath: "/Applications/Slack.app"))]
        let items = ActionPickerCatalog.make(dictionary: [macro], layers: [], destinations: [], applications: apps, allowPointer: true)
        precondition(Set(items.map(\.id)).count == items.count)
        precondition(items.allSatisfy { !$0.detail.isEmpty && $0.action.isValid })
        precondition(ActionPickerCatalog.search(items, query: "research", category: .all).first?.action.macroID == macro.id)
        precondition(ActionPickerCatalog.search(items, query: "slack", category: .apps).first?.action.bundleID == "test.slack")
        precondition(ActionPickerCatalog.search(items, query: "volume", category: .media).count == 2)
        precondition(ActionPickerCatalog.search(items, query: "volume", category: .macros).isEmpty)
        precondition(ActionPickerCatalog.search(items, query: "zzzz-no-match", category: .all).isEmpty)
        precondition(!ActionPickerCatalog.make(dictionary: [], layers: [], destinations: [], applications: [], allowPointer: false)
            .contains { $0.category == .pointer })
        for dark in [false, true] {
            var chosen: BindingAction?
            var cancelled = false
            let picker = ActionPickerModal(current: .media(.mute), dictionary: [macro], layers: [], destinations: [],
                loadApplications: { apps }, onSelect: { chosen = $0 }, onCancel: { cancelled = true })
            let host = NSHostingView(rootView: picker.environment(\.colorScheme, dark ? .dark : .light))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = host
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            precondition(chosen == nil && !cancelled, "Opening or browsing must not change an assignment")
            precondition(host.fittingSize.width <= 760 && host.fittingSize.height <= 620)
            func capture(_ suffix: String) throws {
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/picker-\(dark ? "dark" : "light")-\(suffix).png"))
            }
            try capture("all")
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let field = descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString?.contains("Search actions") == true }!
            panel.makeFirstResponder(field)
            let editor = field.currentEditor() as! NSTextView
            editor.selectAll(nil); editor.insertText("volume", replacementRange: editor.selectedRange())
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            precondition(chosen == nil)
            try capture("search")
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!), isARepeat: false, keyCode: 125)!
            panel.sendEvent(down)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            panel.sendEvent(enter)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            precondition(chosen?.media == .volumeUp, "Arrow keys navigate search results and Enter confirms the selected action")
            chosen = nil
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            panel.sendEvent(escape)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            precondition(cancelled && chosen == nil, "Escape cancels without changing the assignment")
            panel.orderOut(nil); panel.close()
        }
        // The reusable control must present the modal directly, not a giant menu
        // or an intermediate popover, even from a smaller assignment editor.
        let launcher = NSHostingView(rootView: BindingActionPicker(action: .constant(.media(.mute)))
            .padding(20).frame(width: 500, height: 100))
        let parent = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.contentView = launcher
        parent.center(); parent.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let point = launcher.convert(NSPoint(x: 250, y: 50), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            parent.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: parent.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(parent.sheets.count == 1, "The action control must open one shared modal sheet")
        let sheet = parent.sheets[0]
        precondition(sheet.frame.width >= 760 && sheet.frame.height >= 620)
        parent.endSheet(sheet); parent.orderOut(nil); parent.close()
        print("Action picker passed: catalog coverage, search, categories, pointer restriction, native keyboard confirmation, light/dark renders")
    }
}
