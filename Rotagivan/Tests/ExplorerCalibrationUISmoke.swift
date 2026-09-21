// Renders isolated settings; synthetic mouse events stay inside its own windows.
import AppKit
import SwiftUI

@main struct ExplorerCalibrationUISmoke {
    @MainActor static func confirmPicker(query: String, applications: [ExplorerApplication]) -> AppExplorerFavorite? {
        var saved: AppExplorerFavorite?
        let picker = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        picker.isReleasedWhenClosed = false
        picker.contentView = NSHostingView(rootView: ExplorerDestinationPicker(direction: .left,
            onSave: { favorite, _ in saved = favorite }, onCancel: {}, query: query,
            loadApplications: { applications }))
        picker.makeKeyAndOrderFront(nil)
        NSApp.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: picker.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        picker.sendEvent(enter)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        picker.orderOut(nil); picker.close()
        return saved
    }

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
        RunLoop.main.run(until: Date().addingTimeInterval(0.15)) // Let newly occupied slots finish native-view layout.
    }

    @MainActor static func render<V: View>(_ root: V, size: CGSize, path: String, settle: TimeInterval = 0.3) throws {
        let view = NSHostingView(rootView: root)
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let faviconBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let faviconColor = NSColor(deviceRed: 0.35, green: 0.25, blue: 0.8, alpha: 1)
        let faviconWhite = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        for y in 0..<32 { for x in 0..<32 {
            faviconBitmap.setColor((x > 10 && x < 21) || (y > 10 && y < 21) ? faviconWhite : faviconColor, atX: x, y: y)
        } }
        let faviconPNG = faviconBitmap.representation(using: .png, properties: [:])!
        let faviconService = FaviconService(fetch: { url, _ in
            guard url.host == "icon.example", url.path == "/favicon.ico" else { return nil }
            return FaviconResponse(data: faviconPNG, url: url)
        })
        try render(HStack(spacing: 32) {
            VStack { WebsiteFavicon(url: URL(string: "https://icon.example/private"), size: 42, service: faviconService); Text("Website icon") }
            VStack { WebsiteFavicon(url: URL(string: "https://missing.example/"), size: 42, service: faviconService); Text("Fallback") }
            VStack { WebsiteFavicon(url: URL(string: "https://icon.example/"), size: 16, service: faviconService); Text("Settings icon") }
        }.padding(24), size: CGSize(width: 400, height: 140), path: CommandLine.arguments[1] + "/favicons.png", settle: 0.8)
        let suite = "Rotagivan.ExplorerCalibrationUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let searchFixture = [
            ExplorerApplication(bundleID: "com.google.Chrome", name: "Google Chrome", url: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
            ExplorerApplication(bundleID: "test.Gmail", name: "Gmail", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized/Gmail.app"))
        ]
        try render(ExplorerDestinationPicker(direction: .left, onSave: { _, _ in }, onCancel: {}, query: "gchr", loadApplications: { searchFixture }),
            size: CGSize(width: 540, height: 500), path: CommandLine.arguments[1] + "/fuzzy-app-picker.png")
        try render(ExplorerDestinationPicker(direction: .left, onSave: { _, _ in }, onCancel: {}, query: "https://example.com/docs", loadApplications: { [] }),
            size: CGSize(width: 540, height: 500), path: CommandLine.arguments[1] + "/url-picker.png")
        var settings = AppExplorerSettings()
        settings.theme = .starburst // Exercise actual group routing with the radial HUD too.
        settings.setFavorite(AppExplorerFavorite(direction: .up, bundleID: "com.apple.Safari", name: "Safari"), at: .up)
        settings.setFavorite(AppExplorerFavorite(direction: .left, bundleID: "com.apple.finder", name: "Finder"), at: .left)
        settings.setFavorite(AppExplorerFavorite(direction: .right, name: "Project docs", url: "https://example.com/docs"), at: .right)
        store.settings.appExplorer = settings
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .up }) != nil)
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .up })?.size == NSSize(width: 16, height: 16))
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .left }) != nil)
        precondition(AppExplorerSettingsView.applicationIcon(for: settings.favorites.first { $0.direction == .right }) == nil, "Web favorites load their icon asynchronously, not through app lookup")
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
        var presentations: [String] = []
        // Capture denial must close a not-yet-presented panel without reopening it.
        controller.onPresentationChanged = { [weak controller] in
            if controller?.isVisible == true { controller?.dismiss() }
        }
        controller.show(waitingForLift: false)
        precondition(!controller.isVisible, "Owner can safely decline HUD presentation")
        controller.onPresentationChanged = { [weak controller] in
            guard let controller else { return }
            presentations.append(!controller.isVisible ? "closed" : controller.isEditing ? "editing" : "hud")
        }
        var openedURLs: [URL] = []
        controller.openWebURL = { openedURLs.append($0); return true }
        controller.show(waitingForLift: false)
        precondition(controller.isVisible)
        precondition(presentations == ["hud"])
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
        precondition(presentations == ["hud", "closed"], "Pointer lifecycle sees selection dismissal")
        var openedApps: [URL] = []
        controller.openApplication = { url, options, _ in
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
        var completion: (@MainActor (pid_t?) -> Void)?
        var centered: [pid_t] = []
        let originalPointer = CGPoint(x: -350, y: 240)
        controller.cursorPosition = { originalPointer }
        controller.openApplication = { _, _, finished in completion = finished }
        controller.centerApplication = { pid, origin, valid in
            precondition(!controller.isVisible && valid() && origin == originalPointer,
                "Centering must follow dismissal/restore and use the successful app PID")
            centered.append(pid)
        }
        chooseLeft(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        completion?(42)
        precondition(centered.isEmpty, "Centering defaults off")
        settings.centerCursorOnAppSwitch = true
        chooseLeft(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        completion?(nil)
        precondition(centered.isEmpty, "Failed app launch never centers")
        chooseLeft(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        completion?(42)
        precondition(centered == [42])
        chooseLeft(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.show(waitingForLift: false)
        completion?(43)
        precondition(centered == [42], "A newer HUD cancels pending centering")
        controller.dismiss()
        chooseLeft(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        settings.centerCursorOnAppSwitch = false
        completion?(44)
        precondition(centered == [42], "Turning the flag off cancels pending centering")
        settings.centerCursorOnAppSwitch = nil
        controller.openApplication = { url, _, _ in openedApps.append(url) }
        print("App selection centering passed: opt-in, successful PID, restored origin, failed launch, newer HUD and changed setting.")
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
        precondition(controller.displayedLevelDirections == [.left])
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
        precondition(controller.displayedLevelDirections == [.left, .left], "Duplicate-direction groups still occupy distinct rings")
        centerTap()
        precondition(controller.groupPath == [.left] && dismissals == 0)
        precondition(controller.displayedLevelDirections == [.left], "Back removes exactly one ring")
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
        // Resolve actual native drag handles so toolbar additions don't break the fixture.
        func dragHandles(_ view: NSView) -> [NSView] {
            if String(describing: type(of: view)).contains("ExplorerSlotDragView") { return [view] }
            return view.subviews.flatMap(dragHandles)
        }
        let centers = dragHandles(editView).map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
        precondition(centers.count >= 3)
        let sourcePoint = centers.min { abs($0.x - 130) < abs($1.x - 130) }!
        let targetPoint = centers.min { abs($0.x - 550) < abs($1.x - 550) }!
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
        precondition(Array(presentations.suffix(4)) == ["hud", "editing", "closed", "hud"], "Pointer lifecycle releases for editing and recaptures after Done")
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
            // Activation is queued after panel teardown. A fixed 100 ms sleep
            // races native layout under test/compiler load; wait for the
            // actual callback, retaining the exact-once assertion below.
            let activationDeadline = Date().addingTimeInterval(2)
            while openedApps.count == count && Date() < activationDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            precondition(!controller.isVisible && openedApps.count == count + 1,
                "Recent selection: visible=\(controller.isVisible), opens=\(openedApps.count), expected=\(count + 1), target=\(first.name)")
            precondition(openedApps.last == first.url, "Left selects the most recently used eligible app")
        } else {
            centerTap()
            precondition(controller.groupPath.isEmpty, "Empty recent groups still allow back navigation")
        }
        controller.dismiss()
        print("Native UI passed: inline editing, E shortcut, group preservation, native sheet/text focus, save and resume, nested HUD and app/URL dispatch, recent-group ordering/back/edit/activation.")
        let safari = ExplorerApplicationCatalog.application(at: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")!)!
        precondition(confirmPicker(query: "sfri", applications: [safari])?.bundleID == safari.bundleID,
                     "Return chooses the fuzzy-matched app without launching it")
        precondition(confirmPicker(query: "https://example.com/docs", applications: [])?.url == "https://example.com/docs",
                     "Return adds the pasted website")
        precondition(confirmPicker(query: "file:///tmp/unsafe", applications: []) == nil,
                     "Invalid/non-web URLs cannot be submitted")
        print("Native picker passed: fuzzy app selection, pasted URL, and invalid URL rejection via Return.")
        // Exercise real HUD navigation with a fake window target. Never move a user's windows.
        store.settings.appExplorer = AppExplorerSettings(favorites: [
            AppExplorerFavorite(direction: .left, name: "Tools", children: [
                AppExplorerFavorite(direction: .left, name: "Window Manager", action: .windowManager)
            ])
        ])
        var tiled: [SwipeDirection] = []
        var tileError: String?
        var captureAvailable = true
        controller.captureWindow = { _ in
            captureAvailable ? WindowTilingTarget { direction, _ in tiled.append(direction); return tileError } : nil
        }
        for direction in SwipeDirection.allCases {
            controller.show(waitingForLift: false)
            swipeLeft(); swipeLeft()
            precondition(controller.isVisible && controller.displayedEntries.count == 8)
            precondition(controller.displayedEntries.allSatisfy { $0.tilingDirection != nil })
            controller.beginEditing()
            precondition(!controller.isEditing, "Tiling mode must not activate the editor or lose the original window")
            if direction == .left {
                let tilingPanel = NSApp.windows.first { $0.title == "App Explorer" && $0.isVisible }!
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let view = tilingPanel.contentView!
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/window-manager.png"))
                centerTap()
                precondition(controller.isVisible && controller.groupPath == [.left] && controller.displayedEntries.first?.isWindowManager == true)
                swipeLeft()
            }
            let dx: Double = [.left, .topLeft, .bottomLeft].contains(direction) ? -100 : ([.right, .topRight, .bottomRight].contains(direction) ? 100 : 0)
            let dy: Double = [.up, .topLeft, .topRight].contains(direction) ? -100 : ([.down, .bottomLeft, .bottomRight].contains(direction) ? 100 : 0)
            controller.process(report(500))
            controller.process(TrackpadReport(contacts: [FingerContact(id: 0, x: 500 + dx, y: 500 + dy, touching: true, confident: true)], buttonDown: false, scanTime: 0))
            controller.process(report(nil))
            precondition(!controller.isVisible && tiled.last == direction, "A fresh swipe tiles once and closes the HUD")
        }
        precondition(tiled.count == 8)
        controller.show(waitingForLift: false); swipeLeft(); swipeLeft()
        tileError = "This window cannot be resized."
        swipeLeft()
        precondition(controller.isVisible, "Failed tiling keeps navigation and retry available")
        tileError = nil
        swipeLeft()
        precondition(!controller.isVisible)
        captureAvailable = false
        controller.show(waitingForLift: false); swipeLeft(); swipeLeft()
        let previousTileCount = tiled.count
        swipeLeft()
        precondition(controller.isVisible && tiled.count == previousTileCount)
        centerTap(); centerTap()
        precondition(controller.groupPath.isEmpty && controller.isVisible)
        controller.dismiss()
        precondition(tiled.count == previousTileCount, "Back/cancel/missing targets never tile")
        print("Window Manager native HUD passed: all directions, nested back navigation, capture failure, retry, and no editor/app activation.")
        captureAvailable = true
        store.settings.appExplorer = AppExplorerSettings(defaultMode: .recent)
        controller.showWindowManager(waitingForLift: true)
        precondition(controller.displayedEntries.count == 8 && controller.displayedEntries.allSatisfy { $0.tilingDirection != nil }, "Direct action bypasses favorites and recent apps")
        swipeLeft()
        precondition(tiled.count == previousTileCount && controller.isVisible, "Drain any remainder of the tap trigger")
        let directPanel = NSApp.windows.first { $0.title == "App Explorer" && $0.isVisible }!
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let directView = directPanel.contentView!
        let directBitmap = directView.bitmapImageRepForCachingDisplay(in: directView.bounds)!
        directView.cacheDisplay(in: directView.bounds, to: directBitmap)
        try directBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/direct-window-manager.png"))
        centerTap()
        precondition(!controller.isVisible && tiled.count == previousTileCount, "Center closes a directly opened manager")
        controller.showWindowManager(waitingForLift: false)
        swipeLeft()
        precondition(!controller.isVisible && tiled.count == previousTileCount + 1 && tiled.last == .left)
        controller.show(waitingForLift: false)
        precondition(controller.displayedEntries.allSatisfy { $0.tilingDirection == nil }, "Direct mode does not leak into future App Explorer openings")
        controller.dismiss()
        print("Direct Window Manager passed: independent of Explorer mode/favorites, trigger drain, center close, tiling dispatch and mode reset.")
        let chord = RecordedShortcut(keyCode: 64, modifiers: (1 << 19) | (1 << 20), keyLabel: "F17")
        try render(ExplorerShortcutEditor(direction: .up, name: "Voice input", shortcut: chord, onSave: { _ in }, onCancel: {}),
            size: CGSize(width: 440, height: 245), path: CommandLine.arguments[1] + "/shortcut-editor.png")
        store.settings.appExplorer = AppExplorerSettings(favorites: [
            AppExplorerFavorite(direction: .left, name: "Tools", children: [
                AppExplorerFavorite(direction: .up, name: "Voice input", shortcut: chord)
            ])
        ])
        var sentKeys: [RecordedShortcut] = []
        let actualPID: pid_t = 4242 // Deterministic focus source; no real key events are posted.
        var simulatedPID = actualPID
        controller.frontmostPID = { simulatedPID }
        controller.sendShortcut = { key in
            precondition(!controller.isVisible, "Close the HUD before sending keys")
            sentKeys.append(key)
        }
        func swipeUp() {
            controller.process(report(500))
            controller.process(TrackpadReport(contacts: [FingerContact(id: 0, x: 500, y: 400, touching: true, confident: true)], buttonDown: false, scanTime: 0))
            controller.process(report(nil))
        }
        for cancel in 0..<4 {
            simulatedPID = actualPID
            controller.contextIsValid = { true }
            controller.show(waitingForLift: false); swipeLeft()
            precondition(controller.displayedEntries.first?.shortcut == chord)
            swipeUp(); controller.process(report(nil))
            let count = sentKeys.count
            precondition(!controller.isVisible && count == (cancel == 0 ? 0 : 1), "Dispatch waits for panel teardown")
            switch cancel {
            case 1: simulatedPID = -1 // Foreground changed before the queued key event.
            case 2: controller.contextIsValid = { false }
            case 3: controller.show(waitingForLift: false) // Newer HUD supersedes selection.
            default: break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            precondition(sentKeys.count == (cancel == 0 ? count + 1 : count), "Shortcut case \(cancel): before \(count), after \(sentKeys.count)")
            controller.dismiss()
        }
        precondition(sentKeys == [chord], "Nested swipe-up sends exactly one unchanged chord, with no actual key events in tests")
        controller.contextIsValid = { true }
        simulatedPID = actualPID
        controller.show(waitingForLift: false); swipeLeft(); centerTap(); controller.dismiss()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(sentKeys.count == 1, "Back and cancel never send a shortcut")
        print("Explorer shortcut native HUD passed: nested swipe-up, dispatch after teardown, exact chord, no duplicates, focus/context/new-HUD cancellation and back safety.")
        controller.frontmostPID = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let y = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y")
        let u = RecordedShortcut(keyCode: 32, modifiers: 0, keyLabel: "U")
        let heldLayer = ExplorerHoldLayer(name: "Thirds", holdShortcut: y, favorites: [
            AppExplorerFavorite(direction: .left, name: "Layer docs", url: "https://example.com/layer")
        ], windowLayout: .thirds)
        let wideLayer = ExplorerHoldLayer(name: "Wide", holdShortcut: u, windowLayout: .twoThirds)
        store.settings.appExplorer = AppExplorerSettings(favorites: [
            AppExplorerFavorite(direction: .left, name: "Window Manager", action: .windowManager),
            AppExplorerFavorite(direction: .right, name: "Media Controls", action: .mediaControls)
        ], holdLayers: [heldLayer, wideLayer])
        try render(ExplorerHoldLayerEditor(layer: heldLayer, settings: store.settings.appExplorer!, onSave: { _ in }, onCancel: {}),
            size: CGSize(width: 450, height: 360), path: CommandLine.arguments[1] + "/hold-layer-editor.png")
        try render(AppExplorerSettingsView(store: store, initialLayerID: heldLayer.id).padding(24).frame(width: 680, height: 500).background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 680, height: 500), path: CommandLine.arguments[1] + "/held-layer-grid.png")
        func layerKey(_ code: UInt16, down: Bool, repeatKey: Bool = false) {
            let window = NSApp.windows.first { $0.title == "App Explorer" && $0.isVisible }!
            let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: code == 16 ? "y" : "u", charactersIgnoringModifiers: code == 16 ? "y" : "u", isARepeat: repeatKey, keyCode: code)!
            window.sendEvent(event)
        }
        controller.show(waitingForLift: false)
        layerKey(16, down: true)
        precondition(controller.isVisible && controller.displayedEntries.first?.name == "Layer docs", "Native Y keydown selects Explorer layer")
        layerKey(16, down: true, repeatKey: true)
        layerKey(32, down: true)
        precondition(controller.displayedEntries.isEmpty)
        layerKey(32, down: false)
        precondition(controller.displayedEntries.first?.name == "Layer docs")
        layerKey(16, down: false)
        precondition(controller.displayedEntries.first?.isWindowManager == true)
        controller.process(report(500)); controller.process(report(400))
        layerKey(16, down: true)
        let urlsBeforeLayer = openedURLs.count
        controller.process(report(nil))
        precondition(controller.isVisible && openedURLs.count == urlsBeforeLayer, "Changing layers mid-swipe requires a fresh swipe")
        swipeLeft()
        precondition(!controller.isVisible && openedURLs.last?.path == "/layer")
        var layouts: [ExplorerWindowLayout] = []
        controller.captureWindow = { _ in WindowTilingTarget { _, layout in layouts.append(layout); return nil } }
        controller.showWindowManager(waitingForLift: false)
        layerKey(16, down: true)
        precondition(controller.displayedEntries.first?.name.contains("⅓") == true)
        let thirdsPanel = NSApp.windows.first { $0.title == "App Explorer" && $0.isVisible }!
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let thirdsView = thirdsPanel.contentView!
        let thirdsBitmap = thirdsView.bitmapImageRepForCachingDisplay(in: thirdsView.bounds)!
        thirdsView.cacheDisplay(in: thirdsView.bounds, to: thirdsBitmap)
        try thirdsBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/thirds-hud.png"))
        swipeLeft()
        precondition(layouts == [.thirds])
        controller.showWindowManager(waitingForLift: false)
        layerKey(32, down: true); swipeLeft()
        precondition(layouts == [.thirds, .twoThirds])
        controller.showWindowManager(waitingForLift: false)
        layerKey(16, down: true); layerKey(16, down: false); swipeLeft()
        precondition(layouts.last == .halves)
        var mediaActions: [ExplorerMediaAction] = []
        controller.performMedia = { mediaActions.append($0) }
        controller.show(waitingForLift: false)
        controller.process(report(500)); controller.process(report(600)); controller.process(report(nil))
        precondition(controller.isVisible && controller.displayedEntries.count == 6 && controller.displayedEntries.allSatisfy { $0.mediaAction != nil })
        let mediaPanel = NSApp.windows.first { $0.title == "App Explorer" && $0.isVisible }!
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let mediaView = mediaPanel.contentView!
        let mediaBitmap = mediaView.bitmapImageRepForCachingDisplay(in: mediaView.bounds)!
        mediaView.cacheDisplay(in: mediaView.bounds, to: mediaBitmap)
        try mediaBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/media-hud.png"))
        swipeUp(); controller.process(report(nil)); swipeUp()
        precondition(mediaActions == [.volumeUp, .volumeUp] && controller.isVisible)
        controller.process(report(500))
        controller.process(TrackpadReport(contacts: [FingerContact(id: 0, x: 600, y: 400, touching: true, confident: true)], buttonDown: false, scanTime: 0))
        controller.process(report(nil))
        precondition(mediaActions.last == .playPause && controller.isVisible)
        centerTap()
        precondition(controller.displayedEntries.contains { $0.isMediaControls })
        controller.dismiss()
        precondition(mediaActions.count == 3)
        print("Explorer layers/media native UI passed: Y/U holds, repeat/release priority, mid-swipe drain, alternate apps, thirds/two-thirds/default tiling, repeated volume, play/pause and back.")
        let localThirds = ExplorerHoldLayer(name: "Local thirds", holdShortcut: y, windowLayout: .thirds)
        let localWide = ExplorerHoldLayer(name: "Local wide", holdShortcut: y, windowLayout: .twoThirds)
        store.settings.appExplorer = AppExplorerSettings(favorites: [
            AppExplorerFavorite(direction: .left, name: "Narrow windows", action: .windowManager, holdLayers: [localThirds]),
            AppExplorerFavorite(direction: .right, name: "Wide windows", action: .windowManager, holdLayers: [localWide]),
            AppExplorerFavorite(direction: .up, name: "Work", children: [
                AppExplorerFavorite(direction: .left, name: "Default docs", url: "https://example.com/default")
            ], holdLayers: [heldLayer])
        ])
        let localSettings = AppExplorerSettings(holdLayers: [localThirds])
        try render(AppExplorerSettingsView(store: store, initialLayerID: localThirds.id,
            configurationOverride: .constant(localSettings), scopeTitle: "Narrow windows", windowManagerOnly: true)
            .padding(24).background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 660, height: 350), path: CommandLine.arguments[1] + "/tile-window-layers.png")
        func scopedKey(_ down: Bool, repeatKey: Bool = false) -> Bool {
            controller.processLayerKey(NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: "y", charactersIgnoringModifiers: "y", isARepeat: repeatKey, keyCode: 16)!)
        }
        controller.show(waitingForLift: false)
        precondition(!scopedKey(true), "Tile keys must not activate at Explorer root")
        swipeLeft()
        precondition(scopedKey(true) && controller.displayedEntries.first?.name.contains("⅓") == true)
        precondition(scopedKey(false) && controller.displayedEntries.first?.name.contains("⅓") == false)
        _ = scopedKey(true)
        centerTap()
        precondition(controller.displayedEntries.contains { $0.name == "Wide windows" })
        controller.process(report(500)); controller.process(report(600)); controller.process(report(nil))
        precondition(controller.displayedEntries.first?.name.contains("⅔") == false)
        _ = scopedKey(true, repeatKey: true)
        precondition(controller.displayedEntries.first?.name.contains("⅔") == false, "Repeat from an exited tile must not activate another tile")
        _ = scopedKey(false)
        precondition(scopedKey(true) && controller.displayedEntries.first?.name.contains("⅔") == true)
        swipeLeft()
        precondition(layouts.last == .twoThirds && !controller.isVisible)
        controller.show(waitingForLift: false); swipeUp()
        precondition(controller.displayedEntries.first?.name == "Default docs")
        precondition(scopedKey(true) && controller.displayedEntries.first?.name == "Layer docs")
        precondition(scopedKey(false) && controller.displayedEntries.first?.name == "Default docs")
        centerTap()
        precondition(!scopedKey(true), "Leaving a scoped group restores root key behavior")
        controller.dismiss()
        print("Tile layers native HUD passed: reused Y, independent window layouts, release/back cleanup, repeat safety and local app replacement.")
        for theme in ExplorerTheme.allCases {
            let themedModel = ExplorerModel()
            themedModel.theme = theme
            themedModel.layerHint = "Y: Thirds · U: Wide"
            themedModel.canEdit = true
            themedModel.entries = [
                ExplorerEntry(direction: .topLeft, bundleID: nil, name: "Safari", icon: NSWorkspace.shared.icon(forFile: "/Applications/Safari.app"), url: URL(fileURLWithPath: "/Applications/Safari.app")),
                ExplorerEntry(direction: .up, bundleID: nil, name: "Window Manager", icon: nil, url: nil, isWindowManager: true),
                ExplorerEntry(direction: .topRight, bundleID: nil, name: "Music", icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app"), url: URL(fileURLWithPath: "/System/Applications/Music.app")),
                ExplorerEntry(direction: .left, bundleID: nil, name: "Finder", icon: NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app"), url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")),
                ExplorerEntry(direction: .right, bundleID: nil, name: "Focus", icon: nil, url: nil, shortcut: RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17")),
                ExplorerEntry(direction: .bottomLeft, bundleID: nil, name: "Recent apps", icon: nil, url: nil, isGroup: true, isRecentGroup: true),
                ExplorerEntry(direction: .down, bundleID: nil, name: "Workspace", icon: nil, url: nil, isGroup: true),
                ExplorerEntry(direction: .bottomRight, bundleID: nil, name: "Media Controls", icon: nil, url: nil, isMediaControls: true)
            ]
            themedModel.selected = .right
            let view = AppExplorerView(model: themedModel, onSelect: { _ in }, onCancel: {})
            try render(view, size: CGSize(width: 470, height: 520), path: CommandLine.arguments[1] + "/theme-\(theme.rawValue).png")
            let reducedView = AppExplorerView(model: themedModel, onSelect: { _ in }, onCancel: {}, forceReduceMotion: true)
            try render(reducedView, size: CGSize(width: 470, height: 520), path: CommandLine.arguments[1] + "/theme-\(theme.rawValue)-reduced-motion.png")
            if theme == .starburst {
                let names = ["Workspace", "Design", "Research", "Projects", "Media Controls"]
                let directions: [ExplorerSlot] = [.down, .left, .topRight, .up, .right]
                for depth in 1...5 {
                    themedModel.groupNames = Array(names.prefix(depth))
                    themedModel.groupDirections = Array(directions.prefix(depth))
                    try render(view, size: CGSize(width: 470, height: 520),
                        path: CommandLine.arguments[1] + "/starburst-level-\(depth + 1).png")
                }
                themedModel.groupNames = []
                themedModel.groupDirections = []
            }
            themedModel.showingWindowManager = true
            themedModel.canEdit = false
            themedModel.groupNames = ["Window Manager"]
            themedModel.layerName = "Precision layout"
            themedModel.windowLayout = .thirds
            themedModel.entries = ExplorerModel.directions.map {
                ExplorerEntry(direction: $0, bundleID: nil, name: WindowTile.title($0.swipeDirection!, layout: .thirds), icon: nil, url: nil, tilingDirection: $0.swipeDirection)
            }
            themedModel.selected = .topRight
            try render(view, size: CGSize(width: 470, height: 520), path: CommandLine.arguments[1] + "/theme-\(theme.rawValue)-layouts.png")
        }
        try render(ExplorerThemePicker(theme: .constant(.vector)).padding(16).frame(width: 510).background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 510, height: 150), path: CommandLine.arguments[1] + "/theme-picker.png")
        print("Explorer theme snapshots passed: Classic/Vector/Ember/Starburst, nested Starburst levels, Reduce Motion, selected layouts, and appearance picker.")
        precondition(!ExplorerHUDMotion.enabled(theme: .vector, preference: true, reduceMotion: true))
        precondition(!ExplorerHUDMotion.enabled(theme: .ember, preference: false, reduceMotion: false))
        precondition(!ExplorerHUDMotion.enabled(theme: .native, preference: true, reduceMotion: false))
        precondition(ExplorerHUDMotion.nearestAngle(from: 180, to: -135) == 225)
        precondition(ExplorerHUDMotion.nearestAngle(from: -135, to: 180) == -180)
    }
}
