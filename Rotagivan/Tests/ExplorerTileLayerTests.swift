import Foundation

@main struct ExplorerTileLayerTests {
    static func main() throws {
        let y = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y")
        let u = RecordedShortcut(keyCode: 32, modifiers: 0, keyLabel: "U")
        let thirds = ExplorerHoldLayer(name: "Thirds", holdShortcut: y, windowLayout: .thirds)
        let wide = ExplorerHoldLayer(name: "Wide", holdShortcut: y, windowLayout: .twoThirds)
        let left = AppExplorerFavorite(direction: .left, name: "Left manager", action: .windowManager, holdLayers: [thirds])
        let right = AppExplorerFavorite(direction: .right, name: "Right manager", action: .windowManager, holdLayers: [wide])
        var settings = AppExplorerSettings(favorites: [left, right])
        precondition(settings.hasValidFavorites, "Same key may have different meanings on different tiles")
        var keys = ExplorerScopedHeldKeys()
        precondition(!keys.press(key: 16, modifiers: 0, path: [], settings: settings))
        precondition(keys.press(key: 16, modifiers: 0, path: [.left], settings: settings))
        precondition(keys.activeLayer(at: [.left], in: settings)?.windowLayout == .thirds)
        precondition(keys.activeLayer(at: [.right], in: settings) == nil)
        precondition(keys.resolved(settings) == settings, "Window layers never replace other app tiles")
        keys.leave(to: [])
        precondition(keys.activeID == nil)
        precondition(keys.press(key: 16, modifiers: 0, path: [.right], settings: settings))
        precondition(keys.activeLayer(at: [.right], in: settings)?.windowLayout == .twoThirds)
        keys.release(key: 16)
        precondition(keys.activeID == nil)
        precondition(settings.swapFavorites(from: .left, to: .up))
        precondition(settings.favorite(at: [.up])?.holdLayers == [thirds], "Layers move with tiles")
        let restored = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(settings))
        precondition(restored == settings)
        let baseApp = AppExplorerFavorite(direction: .left, bundleID: "test.base", name: "Base")
        let alternateApp = AppExplorerFavorite(direction: .right, bundleID: "test.alternate", name: "Alternate")
        let childLayer = ExplorerHoldLayer(name: "Child", holdShortcut: u, favorites: [alternateApp])
        let child = AppExplorerFavorite(direction: .down, name: "Child group", children: [baseApp], holdLayers: [childLayer])
        let alternate = ExplorerHoldLayer(name: "Work", holdShortcut: y, favorites: [child])
        let group = AppExplorerFavorite(direction: .up, name: "Work", children: [baseApp], holdLayers: [alternate])
        settings = AppExplorerSettings(favorites: [group, right])
        precondition(settings.hasValidFavorites)
        precondition(keys.press(key: 16, modifiers: 0, path: [.up], settings: settings))
        precondition(keys.resolved(settings).favorites(at: [.up]) == [child])
        precondition(keys.resolved(settings).favorite(at: [.right]) == right)
        precondition(keys.press(key: 32, modifiers: 0, path: [.up, .down], settings: settings))
        precondition(keys.resolved(settings).favorites(at: [.up, .down]) == [alternateApp])
        keys.release(key: 16); keys.reconcile(settings)
        precondition(keys.activeID == nil && keys.resolved(settings) == settings, "Parent release invalidates a layer in its removed alternate child")
        let global = ExplorerHoldLayer(name: "Legacy", holdShortcut: y, favorites: [baseApp])
        settings = AppExplorerSettings(favorites: [left,
            AppExplorerFavorite(direction: .down, name: "No overrides", children: [], holdLayers: [])],
            holdLayers: [global])
        precondition(settings.hasValidFavorites)
        precondition(settings.layerScope(at: [.left]) == [.left])
        precondition(!keys.press(key: 16, modifiers: 0, path: [.down], settings: settings), "Explicit empty tile layers must not fall through")
        precondition(keys.press(key: 16, modifiers: 0, path: [], settings: settings))
        precondition(keys.resolved(settings).favorites == [baseApp], "Preserve existing root layers")
        var invalid = settings
        invalid.favorites[0].holdLayers = [thirds, wide]
        precondition(!invalid.hasValidFavorites, "Keys must be unique within one tile")
        invalid = settings; invalid.favorites[0].holdLayers![0].favorites = [baseApp]
        precondition(!invalid.hasValidFavorites, "Window sizing layers cannot contain unused app slots")
        invalid = settings; invalid.favorites = [baseApp]; invalid.favorites[0].holdLayers = [thirds]
        precondition(!invalid.hasValidFavorites, "Terminal app tiles do not open layer scopes")
        invalid = settings; invalid.holdShortcut = y
        precondition(!invalid.hasValidFavorites, "Mode hotkey cannot conflict with a nested layer")
        var deep = baseApp
        for index in 0..<4 { deep = AppExplorerFavorite(direction: .left, name: "Group \(index)", children: [deep]) }
        invalid = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: "Owner", children: [],
            holdLayers: [ExplorerHoldLayer(name: "Too deep", holdShortcut: y, favorites: [deep])])])
        precondition(!invalid.hasValidFavorites, "Layer subtrees count toward the effective group-depth bound")
        print("Tile layers passed: isolated/reused keys, window sizes, child projections, parent release, explicit opt-out, legacy root keys, swaps, persistence and validation.")
    }
}
