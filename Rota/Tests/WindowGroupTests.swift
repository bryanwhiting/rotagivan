import Foundation

@main struct WindowGroupTests {
    static func main() throws {
        let y = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y")
        let legacy = ExplorerHoldLayer(name: "Thirds", holdShortcut: y, windowLayout: .thirds)
        var deepLegacy = AppExplorerFavorite(direction: .left, name: "Windows", action: .windowManager, holdLayers: [legacy])
        for index in 0..<AppExplorerSettings.maximumGroupDepth {
            deepLegacy = AppExplorerFavorite(direction: .left, name: "Group \(index)", children: [deepLegacy])
        }
        precondition(AppExplorerSettings(favorites: [deepLegacy]).hasValidFavorites, "Legacy window presets remain valid at the existing nesting limit")
        var settings = AppExplorerSettings(windowManager: ExplorerWindowSettings(layout: .halves, layers: [legacy]))
        let old = settings
        var editor = settings.windowEditor()
        precondition(editor.favorites.count == 8 && editor.hasValidFavorites)
        precondition(editor.favorites.first { $0.direction == .left }?.windowPlacement == ExplorerWindowPlacement(direction: .left))
        precondition(editor.holdLayers?.first?.favorites.allSatisfy { $0.windowPlacement?.layout == .thirds } == true)
        precondition(settings == old, "Reading legacy presets must not mutate settings")
        let placement = ExplorerWindowPlacement(direction: .right, layout: .twoThirds)
        editor.setFavorite(AppExplorerFavorite(direction: .up, name: placement.title, windowPlacement: placement), at: .up)
        precondition(settings.saveWindowEditor(editor))
        precondition(settings.windowEditor() == editor, "Explicit window slots round-trip through the ordinary editor")
        precondition(settings.windowEditor().favorite(at: [.up])?.windowPlacement == placement)
        precondition(editor.swapFavorites(from: .up, to: .left))
        precondition(editor.favorite(at: [.left])?.windowPlacement == placement, "Slot swaps never change window placement")
        precondition(settings.saveWindowEditor(editor))
        editor.holdLayers![0].favorites = []
        precondition(settings.saveWindowEditor(editor))
        precondition(settings.windowEditor().holdLayers?.first?.favorites.isEmpty == true, "A custom empty layer must not regenerate presets")
        editor.favorites = []
        editor.slotCount = 4
        precondition(settings.saveWindowEditor(editor) && settings.windowEditor().favorites.isEmpty)
        precondition(settings.windowEditor().slotCount == 4)
        let shortcut = ExplorerWindowShortcut(command: .maximize, shortcut: y)
        settings.windowManager!.shortcuts = [shortcut]
        editor.holdLayers = [] // Avoid duplicate shortcut key.
        precondition(settings.saveWindowEditor(editor))
        precondition(settings.windowManager!.shortcuts == [shortcut], "Grid edits preserve direct window hotkeys")

        let child = AppExplorerFavorite(direction: .down, name: "Nested", children: [
            AppExplorerFavorite(direction: .up, name: "Fill", action: .maximize)
        ])
        let local = AppExplorerFavorite(direction: .left, name: "My windows", action: .windowManager)
        var main = AppExplorerSettings(favorites: [local])
        var localEditor = main.windowEditor(at: [.left])
        localEditor.favorites = [child]
        localEditor.slotCount = 12
        precondition(main.saveWindowEditor(localEditor, at: [.left]))
        precondition(main.favorite(at: [.left])?.isWindowManager == true && main.favorite(at: [.left])?.isGroup == true)
        precondition(main.windowEditor(at: [.left]) == localEditor)
        precondition(main.swapFavorites(from: .left, to: .right))
        precondition(main.windowEditor(at: [.right]) == localEditor, "Customized window groups move intact")
        var keys = ExplorerScopedHeldKeys()
        localEditor.holdLayers = [ExplorerHoldLayer(name: "Custom", holdShortcut: y, favorites: [child], windowTilesConfigured: true)]
        precondition(main.saveWindowEditor(localEditor, at: [.right]))
        let resolved = main.windowEditor(at: [.right])
        precondition(keys.press(key: 16, modifiers: 0, path: [], settings: resolved))
        precondition(keys.resolved(resolved).favorites == [child])
        let json = try JSONEncoder().encode(main)
        let decoded = try JSONDecoder().decode(AppExplorerSettings.self, from: json)
        precondition(decoded == main)
        let nestedManager = AppExplorerSettings(windowManager: ExplorerWindowSettings(favorites: [
            AppExplorerFavorite(direction: .up, name: "Another window group", action: .windowManager, holdLayers: [legacy])
        ]))
        let nestedGrid = nestedManager.windowEditor()
        precondition(nestedGrid.favorite(at: [.up])?.isGroup == true && nestedGrid.favorite(at: [.up])?.isWindowManager == false)
        precondition(nestedGrid.favorites(at: [.up])?.count == 8, "Nested manager references become normal groups rather than reopen the root")
        precondition(nestedGrid.favorite(at: [.up])?.holdLayers?.first?.favorites.allSatisfy { $0.windowPlacement?.layout == .thirds } == true)
        for layout in ExplorerWindowLayout.allCases {
            for direction in SwipeDirection.allCases {
                let tile = AppExplorerFavorite(direction: .up, name: "Move", windowPlacement: ExplorerWindowPlacement(direction: direction, layout: layout))
                precondition(tile.isValidDestination)
                var invalid = tile; invalid.action = .maximize
                precondition(!invalid.isValidDestination)
                invalid = tile; invalid.children = []
                invalid.slotCount = 4
                precondition(invalid.isValidDestination, "A window placement may expose a programmable deep-swipe fan")
                invalid = tile; invalid.url = "https://example.com"
                precondition(!invalid.isValidDestination)
            }
        }
        print("Window groups passed: legacy presets, independent placements, swaps, custom layers/empty grids, nested groups, direct hotkeys, persistence and mixed-type rejection")
    }
}
