import AppKit

private final class BindingPoster: GestureEventPosting {
    var dragging = false
    var posted: [RecordedShortcut] = []
    func performTap(_ action: TapAction, shortcut: RecordedShortcut?) {
        if let shortcut { posted.append(shortcut) }
    }
    func click(button: CGMouseButton, count: Int) {}
    func move(dx: Double, dy: Double) {}
    func scroll(dx: Double, dy: Double, momentum: Bool) {}
    func beginDrag() { dragging = true }
    func endDrag() { dragging = false }
}

@main struct ActionBindingRuntimeTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.BindingRuntime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.settings.defaultProfileID = 1
        store.setActiveProfile(1)
        store.foregroundBundleID = "com.apple.finder"
        var profile = store.settings.gestures(for: 1)
        profile.gestures.tapToClick = true
        profile.gestures.tapMaxDuration = 0.25
        profile.gestures.tapMaxMovement = 30
        profile.oneFingerTap = .none
        profile.oneFingerDoubleTap = TapAction.none
        profile.oneFingerTripleTap = TapAction.none
        store.updateGestures(profile, for: 1)

        let key = RecordedShortcut(keyCode: 38, modifiers: 1 << 20, keyLabel: "J")
        let url = BindingAction.openURL("https://example.com/docs")
        let keyboard = ActionBinding(trigger: BindingTrigger(keyboard: key), action: url)
        let tap = ActionBinding(trigger: BindingTrigger(gesture: .oneFingerTap), action: .media(.mute))
        let empty = ExplorerHoldLayer(actionBindings: [keyboard, tap], name: "Empty", holdShortcut: nil)
        var hud = AppExplorerSettings(holdLayers: [empty])
        precondition(hud.hasValidFavorites, "An empty HUD layer may own independent bindings")
        let controller = AppExplorerController(defaults: defaults)
        controller.configuration = { hud }
        controller.gestureSettings = { store.activeGestures }
        controller.frontmostPID = { 4242 }
        controller.frontmostBundleID = { "com.apple.finder" }
        controller.contextIsValid = { true }
        var performed: [BindingAction] = []
        controller.onBindingAction = { performed.append($0) }
        controller.showLayer(empty.id, waitingForLift: false)
        precondition(controller.isVisible && controller.displayedEntries.isEmpty)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j",
            isARepeat: false, keyCode: key.keyCode)!
        precondition(controller.processLayerKey(event))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed == [url], "Independent keyboard action runs on an empty HUD layer")
        controller.showLayer(empty.id, waitingForLift: false)
        func report(_ touching: Bool, x: Double = 500, y: Double = 500) -> TrackpadReport {
            TrackpadReport(contacts: touching ? [FingerContact(id: 1, x: x, y: y, touching: true, confident: true)] : [],
                buttonDown: false, scanTime: 0)
        }
        controller.process(report(true))
        controller.process(report(false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed.last == .media(.mute), "Bound HUD tap runs its independent action")

        // The default HUD is also a scope, even when it has no tiles.
        hud.holdLayers = []
        hud.actionBindings = [keyboard, tap]
        controller.show(waitingForLift: false)
        precondition(controller.displayedEntries.isEmpty && controller.processLayerKey(event))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed.last == url, "Default HUD keyboard action needs no tile")
        controller.show(waitingForLift: false)
        controller.process(report(true))
        controller.process(report(false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed.last == .media(.mute), "Default HUD tap action needs no tile")

        var validContext = true
        controller.contextIsValid = { validContext }
        controller.show(waitingForLift: false)
        let countBeforeInvalidation = performed.count
        precondition(controller.processLayerKey(event))
        validContext = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed.count == countBeforeInvalidation,
            "A binding queued before a context change must not dispatch later")
        validContext = true

        // A different bound gesture activates the recognizer, but an unbound
        // one-finger HUD swipe still selects its tile through the original gate.
        hud.actionBindings = [ActionBinding(trigger: BindingTrigger(gesture: .twoFingerTap), action: .media(.mute))]
        hud.favorites = [AppExplorerFavorite(direction: .up, name: "Docs", url: "https://example.com/docs")]
        var opened: [URL] = []
        controller.openWebURL = { opened.append($0); return true }
        controller.show(waitingForLift: false)
        controller.process(report(true))
        controller.process(report(true, y: 400))
        controller.process(report(false))
        precondition(opened.map(\.absoluteString) == ["https://example.com/docs"],
            "Unbound swipe still selects the visible HUD tile")

        let nested = ExplorerHoldLayer(name: "Nested", holdShortcut: nil,
            favorites: [AppExplorerFavorite(direction: .up, name: "Nested docs", url: "https://example.com/nested")])
        hud.favorites = [AppExplorerFavorite(direction: .left, name: "Group", children: [], holdLayers: [nested])]
        controller.show(waitingForLift: false)
        let nestedPath = [ExplorerTilePathStep.group(.left).token, ExplorerTilePathStep.layer(nested.id).token]
        precondition(controller.switchContainer(nestedPath))
        precondition(controller.displayedEntries.map(\.name) == ["Nested docs"],
            "A structural binding target opens a nested HUD layer")
        precondition(!controller.switchContainer(["l:\(UUID().uuidString)"]))
        precondition(controller.displayedEntries.map(\.name) == ["Nested docs"],
            "A removed layer target cannot switch the HUD")
        controller.switchLayer(nil)
        controller.showBuiltIn(.mediaControls)
        precondition(controller.displayedEntries.contains { $0.name == ExplorerMediaAction.mute.title },
            "Media Controls action opens the media HUD")
        controller.listWindows = { _ in [WindowTiling.AppWindow(title: "Document", minimized: false, activate: { nil })] }
        controller.showBuiltIn(.appWindows)
        precondition(controller.displayedEntries.map(\.name) == ["Document"],
            "App Windows action opens the current app's window picker")
        controller.dismiss()

        let double = ActionBinding(trigger: BindingTrigger(gesture: .oneFingerDoubleTap), action: .media(.playPause))
        hud.favorites = []
        hud.actionBindings = [double]
        profile.gestures.doubleTapInterval = 0.1
        profile.gestures.tripleTapFirstInterval = 0.6
        controller.gestureSettings = { profile }
        controller.show(waitingForLift: false)
        controller.process(report(true)); controller.process(report(false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        precondition(performed.last != .media(.playPause),
            "Only the calibrated double-tap window delays a lone tap")
        controller.dismiss()
        controller.show(waitingForLift: false)
        controller.process(report(true)); controller.process(report(false))
        controller.process(report(true)); controller.process(report(false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed.last == .media(.playPause), "A double tap inside the calibrated window fires")
        let beforeMixed = performed.count
        controller.show(waitingForLift: false)
        controller.process(report(true)); controller.process(report(false))
        let pair = TrackpadReport(contacts: [
            FingerContact(id: 1, x: 500, y: 500, touching: true, confident: true),
            FingerContact(id: 2, x: 530, y: 500, touching: true, confident: true)],
            buttonDown: false, scanTime: 0)
        controller.process(pair); controller.process(report(false))
        precondition(performed.count == beforeMixed, "Mixed finger counts cannot form a double tap")
        controller.dismiss()
        hud.actionBindings = [tap]
        controller.show(waitingForLift: false)
        let beforeExcursion = performed.count
        controller.process(report(true))
        controller.process(report(true, y: 390))
        controller.process(report(true))
        controller.process(report(false))
        precondition(performed.count == beforeExcursion,
            "A stroke that moves away and returns is not a stationary tap")
        controller.dismiss()

        // The same action reference can travel through the unchanged tap page.
        let poster = BindingPoster()
        let engine = GestureEngine(store: store, poster: poster)
        var emitted: [BindingAction] = []
        engine.onBindingAction = { emitted.append($0) }
        profile.oneFingerTap = .shortcut
        profile.oneFingerShortcut = .assigned(.command(.missionControl))
        store.updateGestures(profile, for: 1)
        engine.process(report(true), receivedAt: 1000)
        engine.process(report(false), receivedAt: 1000.03)
        precondition(emitted == [.command(.missionControl)] && poster.posted.isEmpty,
            "Legacy tap action sends arbitrary assigned actions to the shared executor")

        // Global gesture binding resolves before an app-specific override.
        store.settings.actionBindings = [ActionBinding(trigger: BindingTrigger(gesture: .oneFingerTap), action: url)]
        precondition(store.activeGestures.oneFingerShortcut?.assignedAction == url)
        store.settings.appOverrides = [AppGestureOverride(bundleID: "com.apple.finder", name: "Finder",
            bindings: [AppGestureBinding(trigger: .oneFingerTap, action: .rightClick)])]
        precondition(store.activeGestures.oneFingerTap == .rightClick,
            "App override retains precedence over the global binding")
        controller.dismiss()
        print("Action binding runtime tests passed: empty-layer keyboard, HUD gesture and navigation, legacy tap action, and global override precedence.")
    }
}
