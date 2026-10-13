import AppKit
import SwiftUI

@MainActor private final class IntentionUIClock {
    var now = ContinuousClock().now
    var wall = Date(timeIntervalSince1970: 1_700_000_000)
}

@MainActor private final class IntentionUISpeechBackend: LocalIntentionSpeechBackend {
    var supportsOnDeviceRecognition = true
    var permissionGranted = true
    var permissions = 0, starts = 0, stops = 0, cancellations = 0
    var transcript: (@MainActor (String, Bool) -> Void)?
    var failure: (@MainActor () -> Void)?
    func requestPermissions() async throws -> Bool { permissions += 1; return permissionGranted }
    func start(onTranscript: @escaping @MainActor (String, Bool) -> Void, onError: @escaping @MainActor () -> Void) throws {
        starts += 1; transcript = onTranscript; failure = onError
    }
    func stop() { stops += 1 }
    func cancel() { cancellations += 1 }
}

@main struct TemporaryIntentionUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let clock = IntentionUIClock()
        let store = TemporaryIntentionStore(now: { clock.now }, wallNow: { clock.wall }, sleepUntil: { _ in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        })
        defer { store.clear() }
        let admission = VoiceMicrophoneAdmission()
        let cloudID = UUID()
        var cloudCancellations = 0
        precondition(admission.acquireCloud(cloudID, cancel: {
            cloudCancellations += 1; admission.release(cloudID); admission.endCloud(cloudID)
        }))
        let backend = IntentionUISpeechBackend()
        let speech = LocalIntentionSpeech(backend: backend, admission: admission)
        let suite = "Rotagivan.TemporaryIntentionUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("unchanged", forKey: "fixture")
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = defaults.persistentDomain(forName: suite)! as NSDictionary
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 390),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .windowBackgroundColor
        panel.isReleasedWhenClosed = false
        let editorHost = NSHostingView(rootView: TemporaryIntentionEditor(store: store, speech: speech, admission: admission)
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(NSColor.windowBackgroundColor)).environment(\.colorScheme, .dark))
        editorHost.sizingOptions = []
        var host: NSView = editorHost
        panel.contentView = host; panel.setContentSize(NSSize(width: 360, height: 520))
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate()
        defer { panel.orderOut(nil); panel.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.08)); host.layoutSubtreeIfNeeded() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func elements(_ object: Any) -> [AnyObject] {
            let element = object as AnyObject
            return [element] + (element.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func all(_ root: NSView) -> [AnyObject] { views(root).flatMap(elements) }
        func find(_ id: String, in root: NSView? = nil) -> AnyObject {
            guard let element = all(root ?? host).first(where: { $0.accessibilityIdentifier?() == id }) else {
                preconditionFailure("Missing native intention control \(id); native identifiers \(all(root ?? host).compactMap { $0.accessibilityIdentifier?() })")
            }
            return element
        }
        func press(_ id: String, in root: NSView? = nil) {
            precondition(find(id, in: root).accessibilityPerformPress?() == true); settle()
        }
        func type(_ value: String, in root: NSView? = nil, window: NSWindow? = nil) {
            let root = root ?? host, window = window ?? panel
            let field = views(root).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
            field.selectText(nil)
            let editor = window.firstResponder as! NSTextView
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            window.makeFirstResponder(nil); settle()
        }
        func capture(_ name: String, root: NSView? = nil) throws {
            guard CommandLine.arguments.count > 1 else { return }
            let root = root ?? host
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
        }
        settle()
        precondition(backend.permissions == 0 && backend.starts == 0 && admission.privateEntryActive,
            "Opening the private editor blocks cloud voice but must not request permissions or start capture")
        precondition(cloudCancellations == 1 && !admission.acquireCloud(UUID(), cancel: {}),
            "Private editor entry must synchronously cancel existing cloud capture and reject new cloud sessions")
        try capture("intention-local-initial")
        precondition(find("temporary-intention-set").isAccessibilityEnabled?() == false)
        precondition(find("temporary-intention-clear").isAccessibilityEnabled?() == false)
        _ = find("temporary-intention-empty")
        type("  Working on the marketing campaign  "); press("temporary-intention-set")
        precondition(store.snapshot().text == "Working on the marketing campaign" && store.remainingSeconds == 1800)
        _ = find("temporary-intention-active"); _ = find("temporary-intention-expiry")
        try capture("intention-local-active")
        clock.now = clock.now.advanced(by: .seconds(60))
        type("Preparing the launch"); press("temporary-intention-set")
        precondition(store.snapshot().text == "Preparing the launch" && store.remainingSeconds == 1800,
            "Replace uses the same store and resets the thirty-minute lifetime")
        let current = store.snapshot()
        press("temporary-intention-dictate")
        precondition(backend.permissions == 1 && backend.starts == 1 && speech.phase == .listening)
        panel.setContentSize(NSSize(width: 300, height: 560)); settle()
        let listeningBounds = panel.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        for id in ["temporary-intention-dictate", "temporary-intention-dictation-stop", "temporary-intention-dictation-cancel"] {
            precondition(listeningBounds.contains(find(id).accessibilityFrame?() ?? .zero), "Narrow dictation controls must remain reachable")
        }
        try capture("intention-local-listening-narrow")
        backend.transcript?("Locally dictated draft", false); settle()
        precondition(store.snapshot() == current, "Partial dictation must never commit an intention")
        precondition(views(host).compactMap { $0 as? NSTextField }.first { $0.isEditable }!.stringValue == "Locally dictated draft")
        press("temporary-intention-dictation-stop")
        backend.transcript?("Locally dictated final", true); settle()
        precondition(store.snapshot() == current && speech.phase == .finished)
        press("temporary-intention-set")
        precondition(store.snapshot().text == "Locally dictated final")
        let dictated = store.snapshot()
        press("temporary-intention-dictate")
        let lateTranscript = backend.transcript
        press("temporary-intention-dictation-cancel")
        lateTranscript?("Late cancelled private text", true); settle()
        precondition(store.snapshot() == dictated && speech.phase == .cancelled)
        backend.permissionGranted = false
        press("temporary-intention-dictate")
        precondition(speech.phase == .failed && store.snapshot() == dictated)
        _ = find("temporary-intention-dictation-status")
        backend.supportsOnDeviceRecognition = false
        let permissionCount = backend.permissions
        press("temporary-intention-dictate")
        precondition(backend.permissions == permissionCount && store.snapshot() == dictated,
            "Unavailable on-device recognition must use typed fallback without permission or network work")
        type("Preparing the launch"); press("temporary-intention-set")
        let currentAfterDictation = store.snapshot()
        type(String(repeating: "x", count: 501))
        precondition(find("temporary-intention-set").isAccessibilityEnabled?() == false)
        _ = find("temporary-intention-error")
        precondition(store.snapshot() == currentAfterDictation, "Invalid input must not alter an active intention")
        type("   ")
        precondition(find("temporary-intention-set").isAccessibilityEnabled?() == false && store.snapshot() == currentAfterDictation)
        let longText = String(repeating: "campaign ", count: 55).trimmingCharacters(in: .whitespaces)
        type(longText); press("temporary-intention-set")
        panel.setContentSize(NSSize(width: 300, height: 560)); settle()
        let visible = panel.convertToScreen(host.convert(host.bounds, to: nil))
        for id in ["temporary-intention-input", "temporary-intention-set", "temporary-intention-clear", "temporary-intention-privacy"] {
            precondition(visible.insetBy(dx: -1, dy: -1).contains(find(id).accessibilityFrame?() ?? .zero),
                "Long intentions must not push native controls outside a narrow editor")
        }
        try capture("intention-local-narrow")
        press("temporary-intention-clear")
        precondition(store.snapshot().text == nil)
        _ = find("temporary-intention-empty")
        // A separate compact HUD control reuses exactly the same editor/store.
        let compactHost = NSHostingView(rootView: TemporaryIntentionControl(store: store, compact: true, speech: speech, admission: admission)
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(NSColor.windowBackgroundColor)).environment(\.colorScheme, .dark))
        compactHost.sizingOptions = []
        host = compactHost
        panel.contentView = host; panel.setContentSize(NSSize(width: 240, height: 100)); settle()
        precondition(!admission.privateEntryActive, "A closed editor must release private entry")
        press("temporary-intention-control")
        precondition(admission.privateEntryActive)
        guard let popover = NSApp.windows.first(where: { $0 !== panel && $0.isVisible }), let popup = popover.contentView else {
            preconditionFailure("Compact intention control must open a real native popover")
        }
        type("A fresh intention", in: popup, window: popover)
        press("temporary-intention-set", in: popup)
        precondition(store.snapshot().text == "A fresh intention")
        try capture("intention-local-popover", root: popup)
        clock.now = clock.now.advanced(by: .seconds(1800)); store.refreshExpiry(); settle()
        precondition(store.snapshot().text == nil && store.remainingSeconds == nil)
        _ = find("temporary-intention-empty", in: popup)
        precondition(views(popup).compactMap { $0 as? NSTextField }.first { $0.isEditable }!.stringValue.isEmpty,
            "Expiry must clear the editor draft as well as active context")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: popover.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        popover.sendEvent(escape); settle()
        press("temporary-intention-control")
        guard let reopened = NSApp.windows.first(where: { $0 !== panel && $0.isVisible })?.contentView else { preconditionFailure("Popover must reopen") }
        _ = find("temporary-intention-empty", in: reopened)
        precondition(defaults.persistentDomain(forName: suite)! as NSDictionary == saved,
            "The isolated fixture defaults sentinel must remain unchanged")
        print("Local temporary intention UI passed native set/replace/clear, fake on-device dictation draft/stop/cancel/failure/fallback, invalid input, narrow controls, shared popover, expiry/reopen, and untouched isolated defaults sentinel; no microphone/provider access.")
    }
}
