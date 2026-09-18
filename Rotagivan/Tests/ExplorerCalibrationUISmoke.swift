// Renders isolated settings; synthetic mouse events stay inside its own windows.
import AppKit
import SwiftUI

@main struct ExplorerCalibrationUISmoke {
    @MainActor static func drag(in window: NSWindow, from: NSPoint, to: NSPoint, cancel: Bool = false) {
        let start = ProcessInfo.processInfo.systemUptime
        func send(_ type: NSEvent.EventType, _ point: NSPoint, _ step: Int) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: start + Double(step) * 0.02, windowNumber: window.windowNumber,
                context: nil, eventNumber: step, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        send(.leftMouseDown, from, 0)
        for step in 1...10 {
            let fraction = Double(step) / 10
            send(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * fraction,
                                            y: from.y + (to.y - from.y) * fraction), step)
        }
        if cancel {
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: start + 0.21, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            window.sendEvent(escape)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        send(.leftMouseUp, to, 11)
    }

    @MainActor static func render<V: View>(_ root: V, size: CGSize, path: String) throws {
        let view = NSHostingView(rootView: root)
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.ExplorerCalibrationUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var settings = AppExplorerSettings()
        settings.setFavorite(AppExplorerFavorite(direction: .up, bundleID: "com.apple.Safari", name: "Safari"), at: .up)
        settings.setFavorite(AppExplorerFavorite(direction: .left, bundleID: "com.apple.finder", name: "Finder"), at: .left)
        settings.setFavorite(AppExplorerFavorite(direction: .right, name: "Project docs", url: "https://example.com/docs"), at: .right)
        store.settings.appExplorer = settings
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .up }) != nil)
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .up })?.size == NSSize(width: 16, height: 16))
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .left }) != nil)
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .right }) == nil, "Web favorites keep their globe icon")
        precondition(AppExplorerSettingsView.applicationIcon(for: nil) == nil)
        precondition(AppExplorerSettingsView.applicationIcon(for: AppExplorerFavorite(direction: .down, bundleID: "invalid.rotagivan.missing-app", name: "Missing app")) == nil)
        try render(AppExplorerSettingsView(store: store).padding(24).frame(width: 680, height: 570)
            .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 680, height: 570), path: CommandLine.arguments[1] + "/settings.png")
        precondition(store.settings.appExplorer == settings)
        try render(ExplorerURLFavoriteEditor(direction: .right, name: "Project docs", address: "https://example.com/docs", onSave: { _ in }, onCancel: {}),
            size: CGSize(width: 440, height: 300), path: CommandLine.arguments[1] + "/url-editor.png")
        var taps = store.settings.gestures(for: 1)
        taps.gestures.tapMaxDuration = 0.2
        taps.gestures.tapMaxMovement = 30
        let session = GestureCalibrationSession(profileID: 1, profileName: "Default", mode: .tripleTap, gestures: taps)
        func send(_ t: Double, down: Bool) {
            session.process(TrackpadReport(contacts: down ? [FingerContact(id: 0, x: 500, y: 500, touching: true, confident: true)] : [], buttonDown: false, scanTime: 0), at: t)
        }
        send(0, down: false)
        for i in 0..<10 {
            let t = 1 + Double(i) * 2
            send(t, down: true); send(t + 0.03, down: false)
            send(t + 0.15, down: true); send(t + 0.18, down: false)
            send(t + 0.4, down: true); send(t + 0.43, down: false)
        }
        precondition(session.isComplete)
        try render(GestureCalibrationView(session: session, onApply: {}, onCancel: {}),
            size: CGSize(width: 520, height: 650), path: CommandLine.arguments[1] + "/calibration.png")
        let controller = AppExplorerController(defaults: defaults)
        controller.configuration = { settings }
        controller.contextIsValid = { true }
        var openedURLs: [URL] = []
        controller.openWebURL = { openedURLs.append($0); return true }
        controller.show(waitingForLift: false)
        precondition(controller.isVisible)
        let hud = NSApp.windows.first { $0.title == "App Explorer" }!.contentView!
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hud.layoutSubtreeIfNeeded()
        let bitmap = hud.bitmapImageRepForCachingDisplay(in: hud.bounds)!
        hud.cacheDisplay(in: hud.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/hud.png"))
        func report(_ x: Double?) -> TrackpadReport {
            TrackpadReport(contacts: x.map { [FingerContact(id: 0, x: $0, y: 500, touching: true, confident: true)] } ?? [], buttonDown: false, scanTime: 0)
        }
        controller.process(report(500)); controller.process(report(600)); controller.process(report(nil))
        controller.process(report(nil))
        precondition(!controller.isVisible && openedURLs.map(\.absoluteString) == ["https://example.com/docs"], "Open web favorite exactly once, through URL opener, not app activation")
        var openedApps: [URL] = []
        controller.openApplication = { url, options in
            precondition(!controller.isVisible, "HUD must close before activating an app")
            precondition(options.activates && !options.hides && !options.hidesOthers)
            precondition(!options.createsNewApplicationInstance && options.allowsRunningApplicationSubstitution)
            openedApps.append(url)
        }
        func chooseLeft() {
            controller.show(waitingForLift: false)
            controller.process(report(500)); controller.process(report(400)); controller.process(report(nil))
        }
        chooseLeft()
        precondition(openedApps.isEmpty, "Defer app activation until panel teardown completes")
        controller.dismiss() // Releasing the hold key after selection must not cancel the committed launch.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(openedApps.count == 1 && openedApps[0].lastPathComponent == "Finder.app")
        chooseLeft()
        controller.show(waitingForLift: false) // A newer HUD supersedes any queued activation.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(openedApps.count == 1)
        controller.dismiss()
        controller.show(waitingForLift: false)
        controller.setAlternateHeld(true)
        precondition(!controller.isVisible, "Changing modes cancels any partial selection")
        controller.show(waitingForLift: false)
        precondition(controller.isVisible)
        controller.dismiss()
        controller.setAlternateHeld(false)
        settings.setFavorite(AppExplorerFavorite(direction: .left, name: "Work", children: [
            AppExplorerFavorite(direction: .right, name: "Docs", url: "https://example.com/work"),
            AppExplorerFavorite(direction: .left, name: "Development", children: [
                AppExplorerFavorite(direction: .left, bundleID: "com.apple.finder", name: "Finder")
            ]),
            AppExplorerFavorite(direction: .up, name: "Empty group", children: [])
        ]), at: .left)
        store.settings.appExplorer = settings
        try render(AppExplorerSettingsView(store: store).padding(24).frame(width: 680, height: 600)
            .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 680, height: 600), path: CommandLine.arguments[1] + "/group-settings.png")
        try render(AppExplorerSettingsView(store: store, groupPath: [.left]).padding(24).frame(width: 680, height: 600)
            .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 680, height: 600), path: CommandLine.arguments[1] + "/inside-group-settings.png")
        try render(ExplorerGroupNameEditor(name: "Work", isNew: false, onSave: { _ in }, onCancel: {}),
            size: CGSize(width: 448, height: 220), path: CommandLine.arguments[1] + "/group-name.png")
        var dismissals = 0
        controller.onDismiss = { dismissals += 1 }
        func swipeLeft() {
            controller.process(report(500)); controller.process(report(400)); controller.process(report(nil))
        }
        func centerTap() { controller.process(report(500)); controller.process(report(nil)) }
        controller.show(waitingForLift: true)
        controller.process(report(500)); controller.process(report(400)); controller.process(report(nil))
        precondition(controller.groupPath.isEmpty, "Drain trigger before entering a group")
        swipeLeft()
        precondition(controller.isVisible && controller.groupPath == [.left] && dismissals == 0)
        controller.process(report(nil))
        precondition(controller.groupPath == [.left], "Trailing lift cannot go back")
        controller.process(report(500))
        controller.process(TrackpadReport(contacts: [FingerContact(id: 0, x: 500, y: 400, touching: true, confident: true)], buttonDown: false, scanTime: 0))
        controller.process(report(nil))
        precondition(controller.groupPath == [.left, .up] && controller.isVisible, "Empty groups remain navigable")
        centerTap()
        precondition(controller.groupPath == [.left])
        let groupHUD = NSApp.windows.first { $0.title == "App Explorer" && $0.isVisible }!.contentView!
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        groupHUD.layoutSubtreeIfNeeded()
        let groupBitmap = groupHUD.bitmapImageRepForCachingDisplay(in: groupHUD.bounds)!
        groupHUD.cacheDisplay(in: groupHUD.bounds, to: groupBitmap)
        try groupBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/group-hud.png"))
        swipeLeft()
        precondition(controller.groupPath == [.left, .left] && controller.isVisible)
        centerTap()
        precondition(controller.groupPath == [.left] && dismissals == 0)
        controller.process(report(500))
        controller.goBack() // Clicking center while a contact remains down drains it.
        controller.process(report(400)); controller.process(report(nil))
        precondition(controller.groupPath.isEmpty && controller.isVisible)
        centerTap()
        precondition(!controller.isVisible && dismissals == 1)
        controller.show(waitingForLift: false)
        swipeLeft()
        controller.process(report(500)); controller.process(report(600)); controller.process(report(nil))
        precondition(!controller.isVisible && openedURLs.last?.absoluteString == "https://example.com/work")
        controller.show(waitingForLift: false)
        swipeLeft(); swipeLeft(); swipeLeft()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(!controller.isVisible && openedApps.count == 2, "Nested app dispatch still uses deferred activation")
        controller.show(waitingForLift: false)
        swipeLeft()
        controller.contextIsValid = { false }
        centerTap()
        precondition(!controller.isVisible, "Changing profile or settings invalidates nested navigation")
        controller.contextIsValid = { true }
        controller.show(waitingForLift: false)
        precondition(controller.groupPath.isEmpty, "Reopening always starts at the root")
        controller.dismiss()
        controller.editingStore = store
        controller.configuration = { store.settings.appExplorer ?? AppExplorerSettings() }
        var editingChanges: [Bool] = []
        controller.onEditingChanged = { editingChanges.append($0) }
        controller.show(waitingForLift: false)
        swipeLeft()
        precondition(controller.groupPath == [.left])
        let selectionPanel = NSApp.windows.first { $0.title == "App Explorer" && $0.isVisible }!
        let editKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: selectionPanel.windowNumber, context: nil, characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14)!
        selectionPanel.keyDown(with: editKey)
        precondition(controller.isVisible && controller.isEditing && editingChanges == [true])
        let editPanel = NSApp.windows.first { $0.title == "Edit App Explorer" && $0.isVisible }!
        precondition(!editPanel.styleMask.contains(.nonactivatingPanel), "Editor must allow native text focus")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let editView = editPanel.contentView!
        editView.layoutSubtreeIfNeeded()
        let editBitmap = editView.bitmapImageRepForCachingDisplay(in: editView.bounds)!
        editView.cacheDisplay(in: editView.bounds, to: editBitmap)
        try editBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/inline-editor.png"))
        let previousOpenCount = openedApps.count
        let beforeDrag = store.settings.appExplorer!
        // Centers of the middle-row labels in this fixed 680 x 500 editor fixture.
        // Dispatch locally to the window; never move the user's cursor or require TCC access.
        let labelY = editView.isFlipped ? 268.0 : editView.bounds.height - 268.0
        let sourcePoint = editView.convert(NSPoint(x: 130, y: labelY), to: nil)
        let targetPoint = editView.convert(NSPoint(x: 550, y: labelY), to: nil)
        drag(in: editPanel, from: sourcePoint, to: targetPoint)
        precondition(store.settings.appExplorer!.favorite(at: [.left, .right])?.name == "Development",
                     "Actual mouse drag must swap group with URL")
        precondition(store.settings.appExplorer!.favorite(at: [.left, .left])?.name == "Docs")
        precondition(controller.isEditing && openedApps.count == previousOpenCount, "Dragging must not launch apps or leave edit mode")
        drag(in: editPanel, from: targetPoint, to: sourcePoint)
        precondition(store.settings.appExplorer!.favorite(at: [.left, .left])?.children == beforeDrag.favorite(at: [.left, .left])?.children)
        precondition(store.settings.appExplorer!.favorite(at: [.left, .right])?.url == beforeDrag.favorite(at: [.left, .right])?.url)
        let beforeCancelledDrag = store.settings.appExplorer!
        drag(in: editPanel, from: sourcePoint, to: NSPoint(x: -20, y: sourcePoint.y))
        precondition(store.settings.appExplorer == beforeCancelledDrag, "Dropping outside the grid cancels")
        drag(in: editPanel, from: sourcePoint, to: NSPoint(x: 340, y: sourcePoint.y))
        precondition(store.settings.appExplorer == beforeCancelledDrag, "Dropping on the center cancels")
        drag(in: editPanel, from: sourcePoint, to: targetPoint, cancel: true)
        precondition(store.settings.appExplorer == beforeCancelledDrag, "Escape cancels without saving")
        let emptyPoint = NSPoint(x: sourcePoint.x, y: sourcePoint.y - 94)
        drag(in: editPanel, from: sourcePoint, to: emptyPoint)
        precondition(store.settings.appExplorer!.favorite(at: [.left, .left]) == nil)
        precondition(store.settings.appExplorer!.favorite(at: [.left, .bottomLeft])?.name == "Development")
        drag(in: editPanel, from: emptyPoint, to: sourcePoint)
        precondition(store.settings.appExplorer!.favorite(at: [.left, .left])?.name == "Development")
        precondition(store.settings.appExplorer!.favorite(at: [.left, .bottomLeft]) == nil)
        print("Native mouse dragging passed: swap/reverse, empty move, outside/center/Escape cancellation, no app activation.")
        swipeLeft()
        precondition(controller.isEditing && controller.groupPath == [.left] && openedApps.count == previousOpenCount,
            "Raw edit-mode contacts cannot navigate or launch favorites")
        let picker = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        picker.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 20, y: 35, width: 280, height: 24))
        picker.contentView?.addSubview(field)
        editPanel.beginSheet(picker)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(picker.makeFirstResponder(field) && controller.isEditing, "Opening a native picker/sheet must preserve edit mode and text focus")
        editPanel.endSheet(picker); picker.orderOut(nil); picker.close()
        var editedSettings = store.settings.appExplorer!
        editedSettings.setFavorite(AppExplorerFavorite(direction: .down, name: "New URL", url: "https://example.com/new"), at: .down, in: [.left])
        store.settings.appExplorer = editedSettings
        controller.finishEditing()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(controller.isVisible && !controller.isEditing && controller.groupPath == [.left] && editingChanges == [true, false])
        precondition(store.settings.appExplorer?.favorite(at: [.left, .down])?.name == "New URL")
        controller.process(report(500))
        controller.process(TrackpadReport(contacts: [FingerContact(id: 0, x: 500, y: 600, touching: true, confident: true)], buttonDown: false, scanTime: 0))
        controller.process(report(nil))
        precondition(!controller.isVisible && openedURLs.last?.absoluteString == "https://example.com/new", "Edited slot works immediately")
        controller.show(waitingForLift: false); controller.beginEditing(); controller.dismiss()
        precondition(!controller.isEditing && editingChanges.suffix(2) == [true, false], "Closing editor always restores input mode")
        store.settings.appExplorer = AppExplorerSettings(favorites: [
            AppExplorerFavorite(direction: .left, name: "Recent apps", children: [], groupMode: .recent)
        ])
        try render(AppExplorerSettingsView(store: store, groupPath: [.left]).padding(24).frame(width: 680, height: 600)
            .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 680, height: 600),
            path: CommandLine.arguments[1] + "/recent-group-settings.png")
        controller.show(waitingForLift: false)
        precondition(controller.displayedEntries.first?.isRecentGroup == true)
        swipeLeft()
        precondition(controller.isVisible && controller.groupPath == [.left], "Recent groups must remain nested, not switch root modes")
        let recentEntries = controller.displayedEntries
        precondition(recentEntries.count <= 8 && recentEntries.allSatisfy { !$0.isGroup && !$0.isWebURL })
        for (index, entry) in recentEntries.enumerated() {
            precondition(entry.direction == AppExplorerSettings.recentDirections[index])
            precondition(entry.bundleID != "local.rotagivan")
        }
        controller.beginEditing()
        precondition(controller.isEditing && controller.groupPath == [.left])
        controller.finishEditing()
        precondition(!controller.isEditing && controller.groupPath == [.left], "Done returns to the recent group")
        centerTap()
        precondition(controller.isVisible && controller.groupPath.isEmpty, "Center tap goes back, not close")
        swipeLeft()
        if let first = controller.displayedEntries.first {
            let count = openedApps.count
            swipeLeft()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            precondition(!controller.isVisible && openedApps.count == count + 1)
            precondition(openedApps.last == first.url, "Left selects the most recently used eligible app")
        } else {
            centerTap()
            precondition(controller.groupPath.isEmpty, "Empty recent groups still allow back navigation")
        }
        controller.dismiss()
        print("Native UI passed: inline editing, E shortcut, group preservation, native sheet/text focus, save and resume, nested HUD and app/URL dispatch, recent-group ordering/back/edit/activation.")
    }
}
