import AppKit
import SwiftUI

@main struct ApplicationCommandUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let suite = "Rotagivan.ApplicationCommands.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        let app = ExplorerApplication(bundleID: "com.google.Chrome", name: "Google Chrome",
            url: URL(fileURLWithPath: "/Applications/Fixture Chrome.app"))
        let apps = [app]
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func elements(_ object: Any) -> [AnyObject] {
            let element = object as AnyObject
            return [element] + (element.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func all(_ host: NSView) -> [AnyObject] { views(host).flatMap(elements) }
        func find(_ id: String, in host: NSView) -> AnyObject {
            guard let item = all(host).first(where: { $0.accessibilityIdentifier?() == id }) else {
                preconditionFailure("Missing control \(id)")
            }
            return item
        }
        func press(_ id: String, in host: NSView) {
            precondition(find(id, in: host).accessibilityPerformPress?() == true); settle()
        }
        func type(_ placeholder: String, _ text: String, in host: NSView) {
            guard let field = views(host).compactMap({ $0 as? NSTextField })
                .first(where: { $0.isEditable && $0.placeholderString == placeholder }) else {
                preconditionFailure("Missing native field \(placeholder)")
            }
            field.selectText(nil)
            let editor = field.window!.firstResponder as! NSTextView
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            field.window!.makeFirstResponder(nil); settle()
        }
        func render<V: View>(_ view: V, name: String, scheme: ColorScheme = .light, check: (NSView) -> Void) throws {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = host
            panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            panel.makeKeyAndOrderFront(nil); NSApp.activate(); settle()
            check(host); host.layoutSubtreeIfNeeded()
            panel.display(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("application-command-\(name).png"))
            panel.orderOut(nil); panel.close()
        }
        func save(_ command: ApplicationCommand) {
            var settings = store.settings
            ApplicationCommandEdits.save(command, settings: &settings)
            store.settings = settings
        }
        var invalidAction = BindingAction.openURL("")
        invalidAction.targetBrowserBundleID = app.bundleID
        let new = ApplicationCommand(bundleID: app.bundleID, appName: app.name, name: "", detail: "", action: invalidAction)
        var cancels = 0
        try render(ApplicationCommandEditor(command: new, applications: apps, existing: [], onSave: save,
            onCancel: { cancels += 1 }), name: "create") { host in
            precondition(find("application-command-save", in: host).isAccessibilityEnabled?() == false)
            type("Name, such as Open team workspace", "Team workspace", in: host)
            type("What does this command do?", "Open our team workspace in Chrome.", in: host)
            for invalid in ["javascript:alert(1)", "file:///private/tmp/fixture", "https://user:password@example.com", "not a URL"] {
                type("https://example.com/workspace", invalid, in: host)
                precondition(find("application-command-save", in: host).isAccessibilityEnabled?() == false)
            }
            type("https://example.com/workspace", "https://example.com/team", in: host)
            precondition(find("application-command-save", in: host).isAccessibilityEnabled?() == true)
            press("application-command-save", in: host)
        }
        precondition(store.settings.resolvedApplicationCommands.count == 1)
        let created = store.settings.resolvedApplicationCommands[0]
        precondition(created.id == new.id && created.action.targetBrowserBundleID == app.bundleID)
        let unrelated = ActionVocabulary(actionID: "unrelated-fixture", keywordSets: [["leave me alone"]])
        store.settings.actionVocabulary = [ActionVocabulary(actionID: created.voiceActionID, keywordSets: [["team", "workspace"]]), unrelated]
        let originalVocabulary = store.settings.actionVocabulary
        try render(ApplicationCommandEditor(command: created, applications: apps,
            existing: store.settings.resolvedApplicationCommands, onSave: save, onCancel: { cancels += 1 }),
            name: "edit") { host in
                type("Name, such as Open team workspace", "Project workspace", in: host)
                press("application-command-enabled", in: host)
                press("application-command-save", in: host)
            }
        let edited = store.settings.resolvedApplicationCommands[0]
        precondition(edited.id == created.id && edited.name == "Project workspace" && !edited.enabled)
        precondition(store.settings.actionVocabulary == originalVocabulary)
        try render(ApplicationCommandEditor(command: edited, applications: apps,
            existing: store.settings.resolvedApplicationCommands, onSave: save, onCancel: { cancels += 1 }),
            name: "cancel") { host in
                type("Name, such as Open team workspace", "Discard this edit", in: host)
                press("application-command-cancel", in: host)
            }
        precondition(cancels == 1 && store.settings.resolvedApplicationCommands[0] == edited)
        let audit = HotkeyAudit(settings: store.settings, shortcuts: ShortcutConfiguration(), layerID: 1, device: .navigator)
        let rows = ActionTableRow.make(settings: store.settings, applications: apps, audit: audit)
        let row = rows.first { $0.id == edited.voiceActionID }!
        precondition(row.customCommandID == edited.id && row.group == "Applications" && row.subgroup == app.name)
        precondition(row.keybindings.contains("Opens in Google Chrome") && row.keybindings.contains("disabled"))
        precondition(!row.keybindings.contains("App default") && !row.isDefaultAppCommand)
        try render(ApplicationCommandRemovalConfirmation(command: edited, onDelete: {
            var settings = store.settings
            ApplicationCommandEdits.remove(edited, settings: &settings); store.settings = settings
        }, onCancel: { cancels += 1 }), name: "delete-cancel") { host in
            press("application-command-delete-cancel", in: host)
        }
        precondition(store.settings.resolvedApplicationCommands == [edited] && store.settings.actionVocabulary == originalVocabulary)
        try render(ApplicationCommandRemovalConfirmation(command: edited, onDelete: {
            var settings = store.settings
            ApplicationCommandEdits.remove(edited, settings: &settings); store.settings = settings
        }, onCancel: { cancels += 1 }), name: "delete-confirm") { host in
            press("application-command-delete-confirm", in: host)
        }
        precondition(store.settings.resolvedApplicationCommands.isEmpty && store.settings.actionVocabulary == [unrelated])
        let noApp = ApplicationCommand(bundleID: "", appName: "", name: "Fixture", detail: "Fixture",
            action: .keystroke(RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")))
        try render(ApplicationCommandEditor(command: noApp, applications: apps, existing: [], onSave: save,
            onCancel: {}), name: "missing-app") { host in
                precondition(find("application-command-save", in: host).isAccessibilityEnabled?() == false)
            }
        let limit = (0..<500).map { _ in ApplicationCommand(bundleID: app.bundleID, appName: app.name,
            name: "Fixture", detail: "Fixture", action: noApp.action) }
        var valid = new; valid.name = "At capacity"; valid.detail = "Fixture"; valid.action = noApp.action
        try render(ApplicationCommandEditor(command: valid, applications: apps, existing: limit, onSave: save,
            onCancel: {}), name: "capacity") { host in
                precondition(find("application-command-save", in: host).isAccessibilityEnabled?() == false)
            }
        let shortcutCommand = ApplicationCommand(bundleID: app.bundleID, appName: app.name,
            name: "Copy selection", detail: "Copy the current selection in Chrome.", action: BindingAction(kind: .keystroke))
        try render(ApplicationCommandEditor(command: shortcutCommand, applications: apps, existing: [],
            onSave: save, onCancel: {}), name: "shortcut") { host in
                precondition(find("application-command-save", in: host).isAccessibilityEnabled?() == false)
                let recorder = views(host).compactMap { $0 as? RecordingButton }.first!
                recorder.performClick(nil)
                precondition(recorder.recording)
                recorder.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.command], timestamp: 0, windowNumber: recorder.window!.windowNumber,
                    context: nil, characters: "c", charactersIgnoringModifiers: "c",
                    isARepeat: false, keyCode: 8)!)
                settle()
                precondition(find("application-command-save", in: host).isAccessibilityEnabled?() == true)
                press("application-command-save", in: host)
            }
        let savedShortcut = store.settings.resolvedApplicationCommands.first { $0.id == shortcutCommand.id }!
        precondition(savedShortcut.action.shortcut?.keyCode == 8 && savedShortcut.action.shortcut?.isPhysicalShortcut == true)
        let shortcutRows = ActionTableRow.make(settings: store.settings, applications: apps,
            audit: HotkeyAudit(settings: store.settings, shortcuts: ShortcutConfiguration(), layerID: 1, device: .navigator))
        let shortcutRow = shortcutRows.first { $0.id == savedShortcut.voiceActionID }!
        precondition(shortcutRow.keybindings.contains("Custom command") && !shortcutRow.keybindings.contains("App default"))
        // Exercise the real Actions entry point, including SwiftUI's native
        // lazily populated menu and the organizer-owned sheet presentation.
        let organizerEncoder = JSONEncoder(); organizerEncoder.outputFormatting = .sortedKeys
        let beforeOrganizer = try organizerEncoder.encode(store.settings)
        let organizer = NSHostingView(rootView: HotkeyOrganizerView(store: store).padding(20)
            .frame(width: 1100, height: 820, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light).defaultAppStorage(defaults))
        let organizerPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled], backing: .buffered, defer: false)
        organizerPanel.isReleasedWhenClosed = false; organizerPanel.contentView = organizer
        organizerPanel.appearance = NSAppearance(named: .aqua)
        organizerPanel.makeKeyAndOrderFront(nil); NSApp.activate(); settle()
        let popups = views(organizer).compactMap { $0 as? NSPopUpButton }
        guard let addMenu = popups.first(where: {
            $0.title == "Add action" || $0.accessibilityLabel() == "Add action"
        }) else {
            print("Native popup titles/labels:", popups.map { ($0.title, $0.accessibilityLabel() ?? "") })
            preconditionFailure("Actions must expose its Add action menu")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { addMenu.menu?.cancelTracking() }
        addMenu.performClick(nil)
        guard let menu = addMenu.menu else { preconditionFailure("Add action must use a native menu") }
        menu.update()
        guard let commandIndex = menu.items.firstIndex(where: { $0.title == "Add application command…" }) else {
            preconditionFailure("Add application command entry is missing from Actions")
        }
        precondition(menu.items[commandIndex].isEnabled)
        precondition(menu.items.contains { $0.title == "Add application hotkey…" },
            "Launch hotkeys must remain distinct from scoped application commands")
        menu.performActionForItem(at: commandIndex)
        settle()
        guard let commandSheet = organizerPanel.attachedSheet, let sheetContent = commandSheet.contentView else {
            preconditionFailure("Actions command menu must present its command editor sheet")
        }
        precondition(find("application-command-save", in: sheetContent).isAccessibilityEnabled?() == false)
        precondition(all(sheetContent).contains { $0.accessibilityIdentifier?() == "application-command-app" })
        let entryBitmap = sheetContent.bitmapImageRepForCachingDisplay(in: sheetContent.bounds)!
        sheetContent.cacheDisplay(in: sheetContent.bounds, to: entryBitmap)
        try entryBitmap.representation(using: .png, properties: [:])!.write(to:
            URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("application-command-actions-entry.png"))
        press("application-command-cancel", in: sheetContent)
        settle()
        let afterOrganizer = try organizerEncoder.encode(store.settings)
        precondition(organizerPanel.attachedSheet == nil && afterOrganizer == beforeOrganizer,
            "Cancelling the actual Actions sheet must preserve settings")
        organizerPanel.orderOut(nil); organizerPanel.close()
        print("Application command UI passed native AX create/edit/disable/cancel/delete, invalid URLs/app/capacity, stable IDs/keywords and accurate custom output. No real keystrokes, apps, microphone, network or sync.")
    }
}
