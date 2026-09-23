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

@MainActor private final class BindingExplorerStub: AppExplorerPresenting {
    var isVisible = false { didSet { onPresentationChanged?() } }
    var onDismiss: (() -> Void)?
    var contextIsValid: (() -> Bool)?
    var onPresentationChanged: (() -> Void)?
    func show(waitingForLift: Bool) { isVisible = true }
    func showLayer(_ id: UUID, waitingForLift: Bool) { isVisible = true }
    func showWindowManager(waitingForLift: Bool) { isVisible = true }
    func process(_ report: TrackpadReport) {}
    func dismiss() { if isVisible { isVisible = false; onDismiss?() } }
}

@MainActor private final class BindingPointerStub: ExplorerPointerControlling {
    var onInterruption: (() -> Void)?
    @discardableResult func setLocked(_ locked: Bool) -> Bool { true }
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
        var keyboardOrigin: [BindingAction] = []
        controller.onKeyboardBindingAction = { keyboardOrigin.append($0); performed.append($0) }
        controller.show(waitingForLift: false)
        precondition(controller.processLayerKey(event))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(keyboardOrigin == [url], "HUD-local keyboard bindings retain their keyboard origin")
        controller.onKeyboardBindingAction = nil
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
        hud.favorites = [ExplorerReservedGroup.recentApps.tile(at: .up)]
        controller.switchLayer(nil)
        precondition(controller.switchContainer(["g:up"]) &&
            hud.hudActionDestinations().contains { $0.path == [.group(.up)] },
            "A structural binding target opens the generated Recent Apps HUD")
        let placement = AppExplorerFavorite(direction: .left, name: "Left half",
            windowPlacement: ExplorerWindowPlacement(direction: .left))
        let windowGroup = AppExplorerFavorite(direction: .up, name: "Positions", children: [placement])
        hud.windowManager = ExplorerWindowSettings(favorites: [windowGroup])
        controller.switchLayer(nil)
        precondition(controller.switchWindowContainer(ownerTokens: [], targetTokens: ["g:up"]))
        precondition(controller.displayedEntries.map(\.name) == ["Left half"],
            "Standalone Window Manager target resolves in its own namespace")
        precondition(controller.inlineEditorWindowOwnerPath == [],
            "Standalone Window Manager inline edits target its own namespace")
        let owner = AppExplorerFavorite(direction: .right, name: "Windows", children: [windowGroup], action: .windowManager)
        hud.favorites = [owner]
        controller.switchLayer(nil)
        precondition(controller.switchWindowContainer(ownerTokens: ["g:right"], targetTokens: ["g:up"]))
        precondition(controller.displayedEntries.map(\.name) == ["Left half"],
            "Nested Window Manager target resolves beneath its owner tile")
        precondition(controller.inlineEditorWindowOwnerPath == [.group(.right)],
            "Owned Window Manager inline edits retain their owner namespace")
        precondition(!controller.switchWindowContainer(ownerTokens: ["g:up"], targetTokens: []),
            "An ordinary or missing group cannot impersonate a Window Manager owner")
        controller.switchLayer(nil)
        controller.showBuiltIn(.mediaControls)
        precondition(controller.displayedEntries.contains { $0.name == ExplorerMediaAction.mute.title },
            "Media Controls action opens the media HUD")
        controller.listWindows = { _ in [WindowTiling.AppWindow(title: "Document", minimized: false, activate: { nil })] }
        controller.showBuiltIn(.appWindows)
        precondition(controller.displayedEntries.map(\.name) == ["Document"],
            "App Windows action opens the current app's window picker")
        controller.dismiss()

        // HUD tiles use the same action catalog and must run assigned-action
        // references from both sector selection and tile activation keys.
        hud.actionBindings = []
        let tileMedia = BindingAction.media(.next)
        hud.favorites = [tileMedia.favorite(at: .up)!]
        controller.show(waitingForLift: false)
        controller.process(report(true))
        controller.process(report(true, y: 400))
        controller.process(report(false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed.last == tileMedia, "Selecting a HUD tile runs an assigned media action")
        var pointerTile = BindingAction.tap(.rightClick).favorite(at: .left)!
        pointerTile.activationShortcut = RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17")
        hud.favorites = [pointerTile]
        controller.show(waitingForLift: false)
        let tileKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 64)!
        precondition(controller.processLayerKey(tileKey))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed.last == .tap(.rightClick),
            "A tile activation key runs an assigned pointer action")
        let target = BindingAction(kind: .hudLayer, hudPath: nestedPath, name: "Nested")
        hud.favorites = [AppExplorerFavorite(direction: .left, name: "Group", children: [], holdLayers: [nested]),
                         target.favorite(at: .right)!]
        controller.onBindingAction = { action in
            performed.append(action)
            if let path = action.hudPath { precondition(controller.switchContainer(path)) }
        }
        controller.show(waitingForLift: false)
        controller.process(report(true))
        controller.process(report(true, x: 600))
        controller.process(report(false))
        precondition(performed.last == target && controller.isVisible &&
                     controller.displayedEntries.map(\.name) == ["Nested docs"],
            "A HUD tile can jump to a nested HUD target without closing its panel")
        controller.dismiss()
        controller.onBindingAction = { performed.append($0) }

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

        func pairReport(_ firstX: Double?, _ secondX: Double?) -> TrackpadReport {
            var fingers: [FingerContact] = []
            if let firstX { fingers.append(FingerContact(id: 1, x: firstX, y: 500, touching: true, confident: true)) }
            if let secondX { fingers.append(FingerContact(id: 2, x: secondX, y: 500, touching: true, confident: true)) }
            return TrackpadReport(contacts: fingers, buttonDown: false, scanTime: 0)
        }
        hud.actionBindings = [ActionBinding(trigger: BindingTrigger(gesture: .twoFingerLeft), action: .media(.previous))]
        controller.show(waitingForLift: false)
        let beforePinch = performed.count
        controller.process(pairReport(500, 530))
        controller.process(pairReport(300, 530))
        controller.process(pairReport(nil, nil))
        precondition(performed.count == beforePinch, "One stationary finger cannot trigger a two-finger swipe")
        controller.dismiss()
        controller.show(waitingForLift: false)
        controller.process(pairReport(500, 530))
        controller.process(pairReport(390, 420))
        controller.process(pairReport(nil, nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed.last == .media(.previous), "Two coherent fingers can trigger a HUD swipe")
        hud.actionBindings = [ActionBinding(trigger: BindingTrigger(gesture: .twoSingleLeft), action: .media(.next))]
        controller.show(waitingForLift: false)
        controller.process(pairReport(500, 530)); controller.process(pairReport(nil, nil))
        controller.process(pairReport(500, nil))
        controller.process(pairReport(500, 530))
        controller.process(pairReport(400, 430))
        controller.process(pairReport(nil, nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(performed.last == .media(.next),
            "A two-finger tap and swipe accepts the follow-up fingers landing on adjacent reports")

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
        engine.reset()
        emitted.removeAll()
        profile.oneFingerTap = .none
        profile.oneFingerShortcut = nil
        var singleSwipe = DoubleTapSwipeSettings.singleTapDefaults
        singleSwipe.enabled = true
        singleSwipe.left = .assigned(.tap(.rightClick))
        profile.singleTapSwipe = singleSwipe
        store.updateGestures(profile, for: 1)
        engine.process(report(true), receivedAt: 1002)
        engine.process(report(false), receivedAt: 1002.03)
        engine.process(report(true), receivedAt: 1002.10)
        engine.process(report(true, x: 390), receivedAt: 1002.13)
        engine.process(report(false), receivedAt: 1002.15)
        precondition(emitted == [.tap(.rightClick)] && poster.posted.isEmpty,
            "Tap-and-swipe assigned pointer action follows the action callback, not keyboard posting")
        engine.reset()
        emitted.removeAll()
        profile.singleTapSwipe = nil
        var rawPair = DoubleTapSwipeSettings(enabled: true)
        rawPair.left = .assigned(.tap(.doubleLeftClick))
        profile.twoFingerSwipe = rawPair
        store.updateGestures(profile, for: 1)
        engine.process(pairReport(500, 530), receivedAt: 1003)
        engine.process(pairReport(390, 420), receivedAt: 1003.05)
        engine.process(pairReport(nil, nil), receivedAt: 1003.08)
        precondition(emitted == [.tap(.doubleLeftClick)] && poster.posted.isEmpty,
            "Raw two-finger assigned pointer action follows the action callback")

        // Global gesture binding resolves before an app-specific override.
        store.settings.actionBindings = [ActionBinding(trigger: BindingTrigger(gesture: .oneFingerTap), action: url)]
        precondition(store.activeGestures.oneFingerShortcut?.assignedAction == url)
        store.settings.appOverrides = [AppGestureOverride(bundleID: "com.apple.finder", name: "Finder",
            bindings: [AppGestureBinding(trigger: .oneFingerTap, action: .rightClick)])]
        precondition(store.activeGestures.oneFingerTap == .rightClick,
            "App override retains precedence over the global binding")

        // Carbon-origin HUD launches relinquish any previous device owner;
        // trackpad-origin launches keep the device that invoked them.
        store.settings.appOverrides = []
        store.settings.actionBindings = []
        profile.oneFingerTap = .none
        profile.oneFingerShortcut = nil
        store.updateGestures(profile, for: 1)
        store.settings.appExplorer = AppExplorerSettings(
            favorites: [AppExplorerFavorite(direction: .left, name: "Group", children: [], holdLayers: [nested])],
            holdLayers: [empty])
        let explorerStub = BindingExplorerStub()
        let hid = NavigatorHIDManager(store: store, explorer: explorerStub,
            inputPreferences: defaults, explorerPointer: BindingPointerStub(), appleHUDDelay: 0)
        hid.receive(report(true), from: .apple(7), at: 1000)
        hid.receive(report(false), from: .apple(7), at: 1000.03)
        for action in [BindingAction.hudLayer(nil), BindingAction.hudLayer(empty),
                       BindingAction(kind: .hudLayer, hudPath: nestedPath, name: "Nested")] {
            hid.executeBindingAction(action, fromKeyboard: true)
            precondition(explorerStub.isVisible && hid.explorerInputSource == nil,
                "Keyboard-opened HUD must wait for the next trackpad owner")
            explorerStub.dismiss()
        }
        for action in [BindingAction.command(.windowManager), .command(.appWindows),
                       .command(.mediaControls), .tap(.appExplorer), .tap(.windowManager)] {
            hid.executeBindingAction(action, fromKeyboard: true)
            precondition(explorerStub.isVisible && hid.explorerInputSource == nil,
                "Every keyboard-opened HUD action must release a stale trackpad owner")
            explorerStub.dismiss()
        }
        hid.receive(report(true), from: .navigator, at: 1001)
        hid.receive(report(false), from: .navigator, at: 1001.03)
        for action in [BindingAction.hudLayer(nil), BindingAction.hudLayer(empty),
                       BindingAction(kind: .hudLayer, hudPath: nestedPath, name: "Nested")] {
            hid.executeBindingAction(action)
            precondition(explorerStub.isVisible && hid.explorerInputSource == .navigator,
                "Trackpad-opened HUD retains its input owner")
            explorerStub.dismiss()
        }
        for action in [BindingAction.command(.windowManager), .command(.appWindows),
                       .command(.mediaControls), .tap(.appExplorer), .tap(.windowManager)] {
            hid.executeBindingAction(action)
            precondition(explorerStub.isVisible && hid.explorerInputSource == .navigator,
                "Gesture-opened HUD actions retain their invoking trackpad owner")
            explorerStub.dismiss()
        }
        let hotKeys = HotKeyManager()
        var routed: [Bool] = []
        var globalCount = 0
        hotKeys.onHUDKey = { _, _, down in routed.append(down); return down }
        func dispatch(_ down: Bool) {
            if !hotKeys.routeHUDHotkey(signature: 0x52424E44, id: 7, down: down,
                                       key: (key.keyCode, key.modifiers)) { globalCount += 1 }
        }
        dispatch(true)
        dispatch(true)
        dispatch(false)
        precondition(routed == [true, false] && globalCount == 0,
            "A HUD-captured Carbon hotkey suppresses repeat and global press/release")
        hotKeys.onHUDKey = { _, _, _ in false }
        dispatch(true)
        dispatch(false)
        precondition(globalCount == 2, "Unmatched Carbon keys continue to their global action")
        hotKeys.onHUDKey = { _, _, down in routed.append(down); return down }
        dispatch(true)
        hotKeys.cancelHUDCaptures()
        precondition(routed.suffix(2).elementsEqual([true, false]),
            "Re-registering a captured key releases its HUD-local hold")
        dispatch(false)
        precondition(globalCount == 2,
            "A cancelled capture consumes its late release instead of releasing a reused global ID")
        dispatch(true)
        dispatch(false)
        precondition(routed.suffix(2).elementsEqual([true, false]),
            "The same Carbon ID can be captured again after re-registration")
        hotKeys.beginShortcutRecording()
        precondition(!hotKeys.routeHUDHotkey(signature: 0x52424E44, id: 7, down: true,
                                             key: (key.keyCode, key.modifiers)),
            "Queued Carbon keydowns cannot invoke HUD actions during shortcut recording")
        controller.dismiss()
        print("Action binding runtime tests passed: empty-layer keyboard, HUD gesture and navigation, legacy tap action, and global override precedence.")
    }
}
