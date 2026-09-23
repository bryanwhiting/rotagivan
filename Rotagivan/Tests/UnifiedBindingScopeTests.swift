import Foundation

@main struct UnifiedBindingScopeTests {
    static func main() throws {
        let key = RecordedShortcut(keyCode: 38, modifiers: 1 << 20, keyLabel: "J")
        let binding = ActionBinding(trigger: BindingTrigger(keyboard: key), action: .media(.mute))
        let recent = ExplorerReservedGroup.recentApps.tile(at: .left)
        let nested = AppExplorerFavorite(direction: .up, name: "Inside window", children: [])
        let windowLayer = ExplorerHoldLayer(name: "Window alternate", holdShortcut: nil,
            favorites: [nested], windowTilesConfigured: true)
        let windowTile = AppExplorerFavorite(direction: .right, name: "Owned window", action: .windowManager,
            holdLayers: [windowLayer])
        let alternate = ExplorerHoldLayer(name: "Explorer alternate", holdShortcut: nil,
            favorites: [windowTile])
        var settings = AppExplorerSettings(favorites: [recent, windowTile], holdLayers: [alternate],
            windowManager: ExplorerWindowSettings(layers: [windowLayer]))
        precondition(settings.hasValidFavorites)
        let destinations = settings.hudActionDestinations()
        precondition(Set(destinations.map(\.id)).count == destinations.count, "Namespaces need unique IDs")
        precondition(!settings.tileContainers().contains { $0.id == [.group(.left)] },
            "Recent Apps is not an editable transfer destination")
        precondition(destinations.contains { $0.windowOwnerPath == nil && $0.path == [.group(.left)] },
            "Recent Apps is a navigation destination")
        let rootWindow = destinations.first { $0.windowOwnerPath == [] && $0.path == [.layer(windowLayer.id), .group(.up)] }!
        let ownedWindow = destinations.first { $0.windowOwnerPath == [.group(.right)] && $0.path == [.layer(windowLayer.id), .group(.up)] }!
        let alternateWindow = destinations.first {
            $0.windowOwnerPath == [.layer(alternate.id), .group(.right)] && $0.path == [.layer(windowLayer.id), .group(.up)]
        }!
        for target in [rootWindow, ownedWindow, alternateWindow] {
            let action = BindingAction.hudDestination(target)
            precondition(action.isValid && settings.containsHUDActionTarget(action))
            let roundTrip = try JSONDecoder().decode(BindingAction.self, from: JSONEncoder().encode(action))
            precondition(roundTrip == action)
        }
        precondition(settings.windowActionSettings(ownerPath: [.group(.left)]) == nil,
            "A Recent Apps tile must not be mistaken for a Window Manager owner")
        var missing = BindingAction.hudDestination(ownedWindow)
        missing.windowOwnerPath = [ExplorerTilePathStep.group(.down).token]
        precondition(!settings.containsHUDActionTarget(missing))
        precondition(!BindingAction(kind: .media, windowOwnerPath: [], media: .mute).isValid)
        precondition(!BindingAction(kind: .hudLayer, windowOwnerPath: []).isValid,
            "Window namespace requires an explicit relative HUD path")

        // New independent assignments cannot hide older controls in the same
        // scope, while reuse in isolated child scopes remains valid.
        let legacyLayer = ExplorerHoldLayer(name: "Legacy", holdShortcut: key)
        settings = AppExplorerSettings(actionBindings: [binding], holdLayers: [legacyLayer])
        precondition(!settings.hasValidFavorites, "Default binding cannot shadow a layer activation key")
        settings.actionBindings = nil
        settings.holdLayers?[0].actionBindings = [binding]
        precondition(!settings.hasValidFavorites, "Alternate binding cannot shadow its activation key")
        settings.holdLayers?[0].actionBindings = nil
        settings.favorites = [AppExplorerFavorite(actionBindings: [binding], direction: .up,
            name: "Inherited controls", children: [])]
        precondition(!settings.hasValidFavorites, "Nested groups inherit parent layer activation controls")
        settings.favorites[0].holdLayers = []
        precondition(settings.hasValidFavorites, "Explicitly isolated group scope may reuse a parent key")
        settings = AppExplorerSettings(windowManager: ExplorerWindowSettings(actionBindings: [binding],
            shortcuts: [ExplorerWindowShortcut(command: .maximize, shortcut: key)]))
        precondition(!settings.hasValidFavorites, "Independent window binding cannot shadow a legacy command")
        settings.windowManager?.actionBindings = nil
        settings.windowManager?.layers = [ExplorerHoldLayer(actionBindings: [binding], name: "Window layer", holdShortcut: nil)]
        precondition(!settings.hasValidFavorites, "Window commands also apply inside alternate window layers")
        var stored = StoredSettings()
        var dormant = stored.gestures(for: stored.resolvedDefaultProfileID)
        _ = dormant.setLayerAction(.leftClick, shortcut: nil, for: .oneFingerTap)
        _ = dormant.setLayerAction(.rightClick, shortcut: nil, for: .twoFingerTap)
        _ = dormant.setLayerAction(.shortcut, shortcut: key, for: .singleLeft)
        dormant.gestures.tapToClick = false
        stored.actionBindings = [ActionBinding(trigger: BindingTrigger(gesture: .singleRight), action: .tap(.rightClick))]
        let effective = stored.applyingActionBindings(to: dormant)
        precondition(AppGestureTrigger.singleRight.assignment(in: effective).enabled)
        precondition(!AppGestureTrigger.singleLeft.assignment(in: effective).enabled &&
                     !AppGestureTrigger.oneFingerTap.assignment(in: effective).enabled &&
                     !AppGestureTrigger.twoFingerTap.assignment(in: effective).enabled,
            "A global gesture must not reactivate unrelated disabled layer actions")
        precondition(!dormant.gestures.tapToClick && dormant.oneFingerTap == .leftClick,
            "Effective resolution must leave editable layer source values untouched")
        print("Unified binding scopes passed: navigation vs transfer, Recent Apps, standalone/owned/alternate window namespaces, roundtrip, missing targets and legacy key collisions")
    }
}
