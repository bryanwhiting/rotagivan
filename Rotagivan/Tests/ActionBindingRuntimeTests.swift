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

        // Switching prepared HUDs must not repeat app resolution or wait after
        // a fully completed drag, even with animations enabled.
        let originalResolver = controller.applicationURL
        var resolutions = 0
        controller.applicationURL = { _ in resolutions += 1; return nil }
        var cachedLayer = ExplorerHoldLayer.empty(name: "Cached HUD")
        cachedLayer.position = .right
        cachedLayer.favorites = [AppExplorerFavorite(direction: .up, bundleID: "test.orbit.target", name: "Prepared target")]
        hud = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, bundleID: "test.orbit.main", name: "Prepared main")],
            holdLayers: [cachedLayer], animationsEnabled: true)
        controller.show(waitingForLift: false)
        let warmResolutions = resolutions
        precondition(warmResolutions == 2, "Initial presentation prepares both HUDs")
        for _ in 0..<5 {
            controller.switchLayer(cachedLayer.id)
            controller.switchLayer(nil)
        }
        precondition(resolutions == warmResolutions, "Warm rotations must reuse app URLs and icons")
        controller.process(pairReport(500, 530))
        controller.process(pairReport(300, 330))
        controller.process(pairReport(nil, nil))
        precondition(controller.displayedEntries.first?.name == "Prepared target",
            "A completed drag must activate its HUD synchronously without a timer")
        precondition(resolutions == warmResolutions)
        hud.holdLayers?[0].favorites[0].name = "Updated target"
        controller.switchLayer(nil)
        controller.switchLayer(cachedLayer.id)
        precondition(resolutions > warmResolutions && controller.displayedEntries.first?.name == "Updated target",
            "Configuration edits invalidate prepared entries")
        controller.dismiss()
        let beforeReopen = resolutions
        controller.show(waitingForLift: false)
        precondition(resolutions > beforeReopen, "Reopening refreshes machine-local app information")
        controller.dismiss()
        controller.applicationURL = originalResolver

        // Continuous navigation follows fingers before lift, supports slow holds,
        // and cancels when the user reverses below the release threshold.
        var orbitLayer = ExplorerHoldLayer.empty(name: "Orbit target")
        orbitLayer.position = .right
        orbitLayer.favorites = [AppExplorerFavorite(direction: .up, name: "Orbit tile", shortcut: key)]
        hud = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: "Main tile", shortcut: key)],
            holdLayers: [orbitLayer], animationsEnabled: false)
        controller.show(waitingForLift: false)
        controller.process(pairReport(500, 530))
        controller.process(pairReport(460, 490))
        precondition(controller.displayedOrbitProgress > 0 && controller.displayedOrbitProgress < 0.45,
            "A partial drag must update orbit progress before lift")
        precondition(controller.displayedEntries.first?.name == "Main tile", "Scrubbing must not activate the destination early")
        controller.process(pairReport(495, 525))
        controller.process(pairReport(nil, nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        precondition(controller.displayedOrbitProgress == 0 && controller.displayedEntries.first?.name == "Main tile",
            "Reversing before release cancels the transition")
        controller.process(pairReport(500, 530))
        for _ in 0..<240 { controller.process(pairReport(400, 430)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        controller.process(pairReport(400, nil))
        precondition(controller.displayedEntries.first?.name == "Main tile", "One finger lifting must not commit early")
        controller.process(pairReport(nil, nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        precondition(controller.displayedEntries.first?.name == "Orbit tile",
            "Slow scrubs beyond the threshold must commit exactly once, including staggered lift")
        controller.dismiss()
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

        // A fixed 3x3 world, not eight positions re-packed around each active HUD.
        controller.dismiss()
        let mapLayers = HUDLayerPosition.allCases.map { position in
            var layer = ExplorerHoldLayer.empty(name: position.title)
            layer.position = position
            layer.favorites = [AppExplorerFavorite(direction: .up, name: position.title, shortcut: key)]
            return layer
        }
        hud = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: "Main map", shortcut: key)],
            holdLayers: mapLayers, animationsEnabled: false)
        controller.show(waitingForLift: false)
        let world = hud.hudMap()
        for origin in world {
            controller.switchLayer(origin.layerID)
            precondition(controller.displayedHUDMap.count == 8)
            for node in world where node.id != origin.id {
                precondition(controller.displayedHUDMap.first { $0.id == node.id }?.offset == node.point - origin.point)
            }
            for direction in HUDNavigationAction.allCases {
                controller.switchLayer(origin.layerID)
                let target = HUDMapPoint.nearestIndex(in: world.map { $0.point - origin.point }, toward: direction)
                precondition(controller.navigateHUD(direction) == (target != nil))
                if let target {
                    precondition(controller.displayedLayerID == world[target].layerID)
                    // End-of-drag camera coordinates equal the committed map for EVERY face.
                    let delta = world[target].point - origin.point
                    for node in world {
                        let before = (node.point - origin.point) - delta
                        let after = node.point - world[target].point
                        precondition(before == after)
                        let first = HUDMapProjection(x: Double(before.x), y: Double(before.y))
                        let second = HUDMapProjection(x: Double(after.x), y: Double(after.y))
                        precondition(first.offsetX == second.offsetX && first.offsetY == second.offsetY && first.scale == second.scale)
                    }
                } else { precondition(controller.displayedLayerID == origin.layerID) }
            }
        }
        let rightMap = mapLayers.first { $0.position == .right }!
        let bottomMap = mapLayers.first { $0.position == .bottom }!
        let bottomRightMap = mapLayers.first { $0.position == .bottomRight }!
        controller.switchLayer(rightMap.id)
        precondition(controller.displayedHUDMap.first { $0.id == bottomMap.id.uuidString }?.offset == HUDMapPoint(x: -1, y: -1),
            "Bottom stays below Main, not below the active right-hand HUD")
        func verticalPair(_ y: Double?) -> TrackpadReport {
            TrackpadReport(contacts: y.map { value in [
                FingerContact(id: 1, x: 480, y: value, touching: true, confident: true),
                FingerContact(id: 2, x: 520, y: value, touching: true, confident: true)
            ] } ?? [], buttonDown: false, scanTime: 0)
        }
        controller.process(verticalPair(500))
        controller.process(verticalPair(400))
        precondition(controller.displayedOrbitOffset == HUDMapPoint(x: 0, y: -1))
        precondition(controller.displayedLayerID == rightMap.id)
        controller.process(verticalPair(nil))
        precondition(controller.displayedLayerID == bottomRightMap.id,
            "Inverted swipe up from Right targets Bottom right, not Bottom")
        controller.process(verticalPair(500))
        controller.process(verticalPair(300))
        controller.process(verticalPair(nil))
        precondition(controller.displayedLayerID == bottomRightMap.id, "An edge swipe cannot wrap")
        controller.dismiss()

        // Each direction mode tracks physical motion, including partial reversal.
        let strokes: [(AppGestureTrigger, Int, Int, HUDLayerPosition, HUDLayerPosition)] = [
            (.twoFingerLeft, -1, 0, .right, .left),
            (.twoFingerRight, 1, 0, .left, .right),
            (.twoFingerUp, 0, -1, .bottom, .top),
            (.twoFingerDown, 0, 1, .top, .bottom),
            (.twoFingerLeft, -1, -1, .bottomRight, .topLeft),
            (.twoFingerRight, 1, -1, .bottomLeft, .topRight),
            (.twoFingerLeft, -1, 1, .topRight, .bottomLeft),
            (.twoFingerRight, 1, 1, .topLeft, .bottomRight)
        ]
        func strokePair(_ x: Double?, _ y: Double = 500) -> TrackpadReport {
            TrackpadReport(contacts: x.map { value in [
                FingerContact(id: 1, x: value, y: y, touching: true, confident: true),
                FingerContact(id: 2, x: value + 30, y: y, touching: true, confident: true)
            ] } ?? [], buttonDown: false, scanTime: 0)
        }
        for mode in HUDSwipeDirection.allCases {
            hud.swipeDirection = mode
            controller.show(waitingForLift: false)
            for (_, dx, dy, invertedTarget, regularTarget) in strokes {
                controller.switchLayer(nil)
                controller.process(strokePair(500))
                controller.process(strokePair(500 + Double(dx) * 40, 500 + Double(dy) * 40))
                precondition(controller.displayedOrbitProgress > 0 && controller.displayedOrbitProgress < 0.45)
                controller.process(strokePair(500))
                controller.process(strokePair(nil))
                precondition(controller.displayedLayerID == nil && controller.displayedOrbitProgress == 0,
                    "Reversing a partial drag cancels in either direction mode")
                controller.process(strokePair(500))
                controller.process(strokePair(500 + Double(dx) * 200, 500 + Double(dy) * 200))
                precondition(controller.displayedOrbitProgress == 1)
                controller.process(strokePair(nil))
                let target = mode == .inverted ? invertedTarget : regularTarget
                precondition(controller.displayedLayerID == mapLayers.first { $0.position == target }?.id,
                    "Every physical swipe must respect the selected direction mode")
            }
            controller.dismiss()
        }
        hud.swipeDirection = .regular
        controller.show(waitingForLift: false)
        controller.switchLayer(mapLayers.first { $0.position == .topLeft }!.id)
        let edgeID = controller.displayedLayerID
        controller.process(strokePair(500))
        controller.process(strokePair(300, 300))
        precondition(controller.displayedOrbitOffset == HUDMapPoint(x: -1, y: 1))
        precondition(controller.displayedOrbitProgress > 0 && controller.displayedOrbitProgress < 0.12,
            "Missing diagonal resists instead of silently ignoring the drag")
        controller.process(strokePair(nil))
        precondition(controller.displayedLayerID == edgeID && controller.displayedOrbitProgress == 0,
            "Missing diagonal returns without switching HUDs")
        controller.dismiss()
        let savedMapLayers = hud.holdLayers
        hud.holdLayers?.removeAll { $0.position == .topRight }
        controller.show(waitingForLift: false)
        controller.process(strokePair(500))
        controller.process(strokePair(700, 300))
        precondition(controller.displayedOrbitProgress > 0 && controller.displayedOrbitProgress < 0.12)
        controller.process(strokePair(nil))
        precondition(controller.displayedLayerID == nil && controller.displayedOrbitProgress == 0,
            "An empty in-grid corner bounces back to Main")
        controller.dismiss()
        hud.holdLayers = savedMapLayers
        // An explicit cross-axis binding is not inverted again and must scrub
        // along the physical gesture, not the destination's axis.
        hud.swipeDirection = .inverted
        hud.actionBindings = [ActionBinding(trigger: BindingTrigger(gesture: .twoFingerLeft), action: .hudNavigation(.above))]
        controller.show(waitingForLift: false)
        controller.process(strokePair(500))
        controller.process(strokePair(400))
        precondition(controller.displayedOrbitProgress > 0.45 && controller.displayedOrbitOffset == HUDMapPoint(x: 0, y: 1))
        controller.process(strokePair(nil))
        precondition(controller.displayedLayerID == mapLayers.first { $0.position == .top }?.id,
            "Explicit gesture navigation overrides the direction preference")
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
        let mediaController = AppExplorerController(defaults: defaults)
        mediaController.configuration = { AppExplorerSettings(favorites: []) }
        mediaController.contextIsValid = { true }
        var mediaActions: [ExplorerMediaAction] = []
        mediaController.performMedia = { mediaActions.append($0) }
        mediaController.show(waitingForLift: false)
        mediaController.showBuiltIn(.mediaControls)
        mediaController.process(report(true))
        mediaController.process(report(false))
        precondition(mediaActions == [.playPause], "Single media tap toggles playback once")
        precondition(mediaController.isVisible, "Media tap keeps controls open")
        mediaController.centerTap()
        precondition(mediaActions == [.playPause, .playPause], "Center button also toggles playback")
        mediaController.dismiss()
        mediaController.centerTap()
        precondition(mediaActions.count == 2, "Hidden HUD does not send media commands")
        print("Action binding runtime tests passed: empty-layer keyboard, HUD gesture and navigation, legacy tap action, and global override precedence.")
    }
}
