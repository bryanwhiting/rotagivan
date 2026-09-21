import Foundation

@main struct ReservedGroupTests {
    static func main() throws {
        precondition(ExplorerReservedGroup.allCases.count == 3)
        for group in ExplorerReservedGroup.allCases {
            for inWindow in [false, true] {
                let tile = group.tile(at: .right, insideWindowManager: inWindow)
                let configuration = AppExplorerSettings(favorites: [tile])
                precondition(configuration.hasValidFavorites)
                let restored = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(configuration))
                precondition(configuration == restored)
            }
        }
        let windows = ExplorerReservedGroup.windowManager.tile(at: .left)
        precondition(windows.isWindowManager && windows.children == nil, "Use the existing shared/custom Window Manager path")
        let nestedWindows = ExplorerReservedGroup.windowManager.tile(at: .left, insideWindowManager: true)
        precondition(nestedWindows.isGroup && !nestedWindows.isWindowManager && nestedWindows.children?.count == 8)
        precondition(ExplorerReservedGroup.recentApps.tile(at: .up).isRecentGroup)
        let actions = ExplorerReservedGroup.actions.tile(at: .up)
        precondition(actions.isGroup && actions.children?.count == 8 && actions.slotCount == 8)
        let expected: [String: (UInt16, String, UInt64)] = [
            "Copy": (8, "C", 1 << 20), "Paste": (9, "V", 1 << 20), "Cut": (7, "X", 1 << 20),
            "Undo": (6, "Z", 1 << 20), "Redo": (6, "Z", (1 << 20) | (1 << 17)),
            "Select All": (0, "A", 1 << 20), "Find": (3, "F", 1 << 20), "Save": (1, "S", 1 << 20)
        ]
        for tile in actions.children! {
            let key = tile.shortcut!, value = expected[tile.name]!
            precondition(key.keyCode == value.0 && key.keyLabel == value.1 && key.modifiers == value.2)
            precondition(key.isValidExplorerShortcut && tile.action == nil && tile.children == nil)
        }
        var first = actions
        first.children!.removeFirst()
        precondition(ExplorerReservedGroup.actions.tile(at: .up) == actions, "Editing a placed group must not change reserved defaults")
        var settings = AppExplorerSettings(favorites: [actions])
        precondition(settings.swapFavorites(from: .up, to: .down))
        precondition(settings.favorite(at: [.down])?.children == actions.children)
        print("Reserved groups passed: catalog, window/nesting compatibility, recent mode, eight macOS shortcuts, independent instances, moves and persistence")
    }
}
