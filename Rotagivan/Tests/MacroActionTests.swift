import AppKit

private final class MacroPoster: GestureEventPosting {
    var dragging = false
    var sent: [RecordedShortcut] = []
    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) { if let shortcut { sent.append(shortcut) } }
    func click(button: CGMouseButton, count: Int) {}
    func move(dx: Double, dy: Double) {}
    func scroll(dx: Double, dy: Double, momentum: Bool) {}
    func beginDrag() { dragging = true }
    func endDrag() { dragging = false }
}

@main struct MacroActionTests {
    @MainActor static func main() throws {
        let copy = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
        let paste = RecordedShortcut(keyCode: 9, modifiers: 1 << 20, keyLabel: "V")
        let macro = NamedHotkey(name: "Copy and paste", shortcut: copy, steps: [copy, paste], stepDelayMilliseconds: 125)
        precondition(macro.isValid && macro.resolvedSteps == [copy, paste])
        let legacy = try JSONDecoder().decode(NamedHotkey.self, from: JSONEncoder().encode(NamedHotkey(name: "Copy", shortcut: copy)))
        precondition(legacy.resolvedSteps == [copy])
        let reference = RecordedShortcut.macro(macro)
        precondition(reference.isValidExplorerShortcut && !reference.isPhysicalShortcut)
        precondition(EventPoster.shortcutEvents(reference).isEmpty, "References must never emit key code zero")
        var recursive = macro; recursive.steps = [reference]; precondition(!recursive.isValid)
        var oversized = macro; oversized.steps = Array(repeating: copy, count: 33); precondition(!oversized.isValid)
        var empty = macro; empty.steps = []; precondition(!empty.isValid)
        var delay = macro; delay.stepDelayMilliseconds = 2001; precondition(!delay.isValid)
        var renamed = macro; renamed.name = "Updated"; precondition([renamed].title(for: reference).hasPrefix("Updated"))
        let layer = ExplorerHoldLayer(name: "Editor commands", holdShortcut: RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y"),
            favorites: [AppExplorerFavorite(direction: .left, name: macro.name, shortcut: reference)],
            launchShortcut: RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17"), appBundleID: "test.editor", appName: "Editor")
        let hud = AppExplorerSettings(holdLayers: [layer])
        precondition(hud.hasValidFavorites && layer.isAvailable(in: "test.editor") && !layer.isAvailable(in: "other.app"))
        var held = ExplorerScopedHeldKeys()
        precondition(!held.press(key: 16, modifiers: 0, path: [], settings: hud, bundleID: "other.app"))
        precondition(held.press(key: 16, modifiers: 0, path: [], settings: hud, bundleID: "test.editor"))
        held.release(key: 16)
        precondition(held.selectRootLayer(layer.id, settings: hud))
        held.release(key: 64); held.updateModifiers(0)
        precondition(held.resolved(hud).favorites == layer.favorites, "Direct launch must remain selected after key release")
        precondition(!held.selectRootLayer(UUID(), settings: hud))
        let suite = "Rotagivan.MacroActions.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.settings.defaultProfileID = 1; store.setActiveProfile(1)
        store.settings.hotkeyDictionary = [macro]; store.settings.appExplorer = hud
        for mode in [GestureEngine.InputMode.navigator, .nativeActions] {
            let poster = MacroPoster()
            var now = Date(timeIntervalSince1970: 1000)
            let engine = GestureEngine(store: store, poster: poster, clock: { now }, inputMode: mode)
            var taps = store.settings.gestures(for: 1)
            taps.gestures.tapToClick = true; taps.gestures.touchAndHoldDrag = false
            taps.oneFingerTap = .shortcut; taps.oneFingerShortcut = reference
            taps.oneFingerDoubleTap = TapAction.none; taps.oneFingerTripleTap = TapAction.none
            taps.twoFingerTap = .none; taps.twoFingerDoubleTap = .shortcut
            taps.twoFingerDoubleShortcut = .hudLayer(layer); taps.twoFingerTripleTap = TapAction.none
            taps.singleTapSwipe = nil; taps.doubleTapSwipe = nil
            taps.twoFingerSingleTapSwipe = nil; taps.twoFingerDoubleTapSwipe = nil
            store.updateGestures(taps, for: 1)
            func send(_ t: Double, _ fingers: Int) {
                now = Date(timeIntervalSince1970: 1000 + t)
                let contacts = (0..<fingers).map { FingerContact(id: UInt8($0), x: 500 + Double($0 * 30), y: 500, touching: true, confident: true) }
                engine.process(TrackpadReport(contacts: contacts, buttonDown: false, scanTime: 0), receivedAt: 1000 + t)
            }
            send(0, 1); send(0.03, 0)
            precondition(poster.sent == [copy, paste], "Macro steps must dispatch in order for both devices")
            engine.reset(); poster.sent = []
            var opened: [UUID] = []; engine.onHUDLayer = { opened.append($0) }
            send(1, 2); send(1.03, 0); send(1.12, 2); send(1.15, 0)
            precondition(opened == [layer.id] && poster.sent.isEmpty, "Two-finger double tap must open its target HUD layer")
            engine.reset()
            store.settings.hotkeyDictionary = []
            send(2, 1); send(2.03, 0)
            precondition(poster.sent.isEmpty, "Deleted macros fail closed")
            engine.reset()
            taps.oneFingerShortcut = .hudLayer(layer)
            taps.oneFingerDoubleTap = TapAction.none
            store.updateGestures(taps, for: 1)
            opened = []
            send(3, 1); send(3.03, 0)
            precondition(opened == [layer.id] && poster.sent.isEmpty, "Single tap must open a HUD layer without a keyboard event")
            engine.reset()
            taps.oneFingerTap = .none
            taps.oneFingerDoubleTap = .shortcut; taps.oneFingerDoubleShortcut = .hudLayer(layer)
            store.updateGestures(taps, for: 1)
            opened = []
            send(4, 1); send(4.03, 0); send(4.12, 1); send(4.15, 0)
            precondition(opened == [layer.id] && poster.sent.isEmpty, "One-finger double tap must open a HUD layer without a keyboard event")
            store.settings.hotkeyDictionary = [macro]; engine.reset()
        }
        print("Macro action tests passed: ordered dispatch on both devices, two-finger double-tap HUD targets, app scoping, sticky direct launch, legacy decoding and invalid/reference output rejection. No real events posted.")
    }
}
