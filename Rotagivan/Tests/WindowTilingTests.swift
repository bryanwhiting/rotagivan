import AppKit

@main struct WindowTilingTests {
    static func main() throws {
        let area = CGRect(x: -1512, y: -800, width: 1511, height: 951)
        for direction in SwipeDirection.allCases {
            let tile = WindowTile.frame(direction, in: area)
            precondition(area.contains(tile) && tile.width > 0 && tile.height > 0)
        }
        let left = WindowTile.frame(.left, in: area), right = WindowTile.frame(.right, in: area)
        precondition(left.maxX == right.minX && left.union(right) == area)
        let top = WindowTile.frame(.up, in: area), bottom = WindowTile.frame(.down, in: area)
        precondition(top == CGRect(x: -1512, y: -800, width: 1511, height: 475))
        precondition(top.maxY == bottom.minY && top.union(bottom) == area)
        precondition(WindowTile.title(.up) == "Top half")
        let tl = WindowTile.frame(.topLeft, in: area), tr = WindowTile.frame(.topRight, in: area)
        let bl = WindowTile.frame(.bottomLeft, in: area), br = WindowTile.frame(.bottomRight, in: area)
        precondition(tl.union(bl) == left && tr.union(br) == right)
        precondition(tl.union(tr) == top)
        precondition(bl.union(br) == WindowTile.frame(.down, in: area))
        precondition(tl.maxY == bl.minY && tr.maxY == br.minY)
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 790)
        precondition(WindowTile.accessibilityFrame(visible, primaryTop: 900) == CGRect(x: 0, y: 30, width: 1440, height: 790))
        let upperScreen = CGRect(x: -1920, y: 900, width: 1920, height: 1080)
        precondition(WindowTile.accessibilityFrame(upperScreen, primaryTop: 900) == CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
        precondition(WindowTile.screenIndex(for: CGRect(x: -800, y: 0, width: 1000, height: 600), frames: screens) == 1)
        precondition(WindowTile.screenIndex(for: visible, frames: []) == nil)

        let manager = AppExplorerFavorite(direction: .left, name: "Window Manager", action: .windowManager)
        precondition(manager.isValidDestination && manager.isWindowManager && !manager.isGroup)
        let settings = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: "Tools", children: [manager])])
        let decoded = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(settings))
        precondition(decoded == settings && decoded.hasValidFavorites)
        var moved = decoded
        precondition(moved.swapFavorites(from: .left, to: .right, in: [.up]))
        precondition(moved.favorite(at: [.up, .right])?.isWindowManager == true)
        var invalid = manager
        invalid.bundleID = "com.apple.Safari"; precondition(!invalid.isValidDestination)
        invalid = manager; invalid.url = "https://example.com"; precondition(!invalid.isValidDestination)
        invalid = manager; invalid.children = []; precondition(invalid.isValidDestination, "Window Manager is an editable group, including an empty group")
        invalid = manager; invalid.groupMode = .recent; precondition(!invalid.isValidDestination)
        let legacy = try JSONDecoder().decode(AppExplorerFavorite.self,
            from: Data(#"{"direction":"left","name":"Safari","bundleID":"com.apple.Safari"}"#.utf8))
        precondition(legacy.action == nil && legacy.isValidDestination)
        print("Window tiling passed: eight layouts, odd dimensions, negative/display coordinates, screen selection, nested persistence, swaps, legacy defaults and invalid destinations.")
    }
}
