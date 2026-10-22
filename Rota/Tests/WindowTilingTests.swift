import AppKit

private final class PlacementFixture {
    var rect: CGRect
    var minimum: CGSize? = nil
    var acceptedSize: (CGSize, CGRect) -> CGSize = { size, _ in size }
    var acceptsMove = true
    var acceptsResize = true
    var current = true
    var disappears = false
    var resizeCalls = 0
    var moveCalls = 0
    var pauses = 0
    var delay = 0
    var pending: (CGSize, Int)?
    var afterPause: (() -> Void)?
    init(_ rect: CGRect) { self.rect = rect }
    var access: WindowPlacement.Access {
        WindowPlacement.Access(read: { self.disappears ? nil : self.rect }, resize: { proposed in
            self.resizeCalls += 1
            guard self.acceptsResize else { return false }
            let accepted = self.acceptedSize(proposed, self.rect)
            if self.delay == 0 { self.rect.size = accepted }
            else if self.pending?.0 != accepted { self.pending = (accepted, self.pauses + self.delay) }
            return true
        }, move: { point in
            self.moveCalls += 1
            guard self.acceptsMove else { return false }
            self.rect.origin = point; return true
        }, minimum: { self.minimum }, isCurrent: { self.current }, pause: {
            self.pauses += 1
            if let pending = self.pending, self.pauses >= pending.1 {
                self.rect.size = pending.0; self.pending = nil
            }
            self.afterPause?()
        })
    }
}

@main struct WindowTilingTests {
    static func main() throws {
        precondition(WindowDesktopTransfer.adjacent(to: 2, step: -1, displays: [[1, 2, 3], [4, 5]]) == 1)
        precondition(WindowDesktopTransfer.adjacent(to: 2, step: 1, displays: [[1, 2, 3], [4, 5]]) == 3)
        precondition(WindowDesktopTransfer.adjacent(to: 3, step: 1, displays: [[1, 2, 3], [4, 5]]) == nil)
        precondition(WindowDesktopTransfer.adjacent(to: 4, step: -1, displays: [[1, 2, 3], [4, 5]]) == nil)
        precondition(WindowDesktopTransfer.adjacent(to: 99, step: 1, displays: [[1, 2]]) == nil)
        precondition(WindowDesktopTransfer.adjacent(to: 1, step: 0, displays: [[1, 2]]) == nil)
        let area =
 CGRect(x: -1512, y: -800, width: 1511, height: 951)
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
        try ultrawidePlacement()

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

    static func ultrawidePlacement() throws {
        for scale: CGFloat in [1, 2] {
            for area in [CGRect(x: 0, y: 25, width: 5120, height: 1375),
                         CGRect(x: -5119, y: -1439, width: 5119, height: 1439),
                         CGRect(x: 1440, y: -240, width: 3440, height: 1401),
                         CGRect(x: -80, y: 30, width: 1441, height: 3361)] {
                for layout in ExplorerWindowLayout.allCases {
                    for direction in SwipeDirection.allCases {
                        let tile = WindowTile.frame(direction, in: area, layout: layout, backingScale: scale)
                        precondition(WindowTile.valid(tile) && area.contains(tile))
                        precondition(abs((tile.minX - area.minX) * scale - ((tile.minX - area.minX) * scale).rounded()) < 0.001)
                    }
                }
                let halves = [WindowTile.frame(.left, in: area, backingScale: scale), WindowTile.frame(.right, in: area, backingScale: scale)]
                precondition(halves[0].maxX == halves[1].minX && halves[0].union(halves[1]) == area)
                let thirds = WindowTile.frame(.left, in: area, layout: .thirds, backingScale: scale)
                let twoThirds = WindowTile.frame(.right, in: area, layout: .twoThirds, backingScale: scale)
                precondition(thirds.maxX == twoThirds.minX && thirds.union(twoThirds) == area)
            }
        }
        let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 2000, y: 0, width: 5120, height: 1440)]
        precondition(WindowTile.screenIndex(for: CGRect(x: -5000, y: 100, width: 600, height: 400), frames: displays) == 0,
            "Off-screen windows choose the nearest display, not an arbitrary zero-overlap winner")
        precondition(WindowTile.screenIndex(for: CGRect(x: 7400, y: 100, width: 600, height: 400), frames: displays) == 1)
        precondition(WindowTile.screenIndex(for: .null, frames: displays) == nil)
        precondition(WindowTile.screenIndex(for: displays[0], frames: [.null, displays[0]]) == 1)

        let area = CGRect(x: -5120, y: -1400, width: 5120, height: 1380)
        let requested = WindowTile.frame(.bottomRight, in: area, layout: .thirds, backingScale: 2)
        let start = CGRect(x: -4900, y: -1200, width: 2200, height: 900)
        let exact = PlacementFixture(start)
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: true, access: exact.access) == .exact)
        precondition(exact.rect == requested)

        let minSize = PlacementFixture(start)
        minSize.minimum = CGSize(width: 1900, height: 700)
        minSize.acceptedSize = { size, _ in CGSize(width: max(1900, size.width), height: max(700, size.height)) }
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: true, access: minSize.access) == .constrained)
        precondition(area.contains(minSize.rect) && minSize.rect.maxX == area.maxX && minSize.rect.maxY == area.maxY)

        let hiddenMin = PlacementFixture(start)
        hiddenMin.acceptedSize = minSize.acceptedSize // app never reports its actual minimum
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: true, access: hiddenMin.access) == .constrained)
        precondition(hiddenMin.rect == minSize.rect)

        let terminal = PlacementFixture(start)
        terminal.acceptedSize = { size, _ in CGSize(width: floor(size.width / 9) * 9, height: floor(size.height / 17) * 17) }
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: true, access: terminal.access) == .constrained)
        precondition(terminal.rect.maxX == area.maxX && terminal.rect.maxY == area.maxY)

        let fixed = PlacementFixture(CGRect(x: -4600, y: -1000, width: 900, height: 600))
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: false, access: fixed.access) == .constrained)
        precondition(fixed.resizeCalls == 0 && fixed.rect.maxX == area.maxX && fixed.rect.maxY == area.maxY)

        let maximum = PlacementFixture(start)
        maximum.acceptedSize = { size, _ in CGSize(width: min(size.width, 1200), height: min(size.height, 900)) }
        precondition(WindowPlacement.apply(requested: area, area: area, direction: nil,
            resizable: true, access: maximum.access) == .constrained)
        precondition(maximum.rect.midX == area.midX && maximum.rect.midY == area.midY)

        let delayed = PlacementFixture(start); delayed.delay = 3
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: true, access: delayed.access) == .exact)
        precondition(delayed.rect == requested && delayed.pauses >= 3)

        let blocked = PlacementFixture(start); blocked.acceptsMove = false
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: true, access: blocked.access) == .failed)
        let vanished = PlacementFixture(start)
        vanished.afterPause = { vanished.disappears = true }
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: true, access: vanished.access) == .unavailable)
        let switched = PlacementFixture(start)
        switched.afterPause = { switched.current = false }
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: true, access: switched.access) == .cancelled)
        precondition(switched.moveCalls == 1, "Focus loss must stop later moves")

        let huge = PlacementFixture(start)
        huge.acceptedSize = { _, _ in CGSize(width: area.width + 300, height: area.height + 300) }
        precondition(WindowPlacement.apply(requested: requested, area: area, direction: .bottomRight,
            resizable: true, access: huge.access) == .oversized)
        precondition(huge.rect.origin == area.origin, "Keep oversized title bars reachable")

        // macOS may initially cap a resize against the old right/Dock edge.
        // Moving by max(current size, target size) must release that restriction.
        let edge = PlacementFixture(CGRect(x: -320, y: area.minY, width: 320, height: area.height))
        edge.acceptedSize = { size, rect in CGSize(width: min(size.width, area.maxX - rect.minX), height: size.height) }
        let right = WindowTile.frame(.right, in: area, layout: .thirds)
        precondition(WindowPlacement.apply(requested: right, area: area, direction: .right,
            resizable: true, access: edge.access) == .exact)
        precondition(edge.rect == right)
        let invalid = PlacementFixture(start)
        precondition(WindowPlacement.apply(requested: .null, area: area, direction: .right,
            resizable: true, access: invalid.access) == .unavailable)
        precondition(invalid.moveCalls == 0 && invalid.resizeCalls == 0)
        print("Ultrawide placement passed: 1×/2× pixels, 32:9/21:9/portrait, complementary fractions, nearest display, minimum/maximum/fixed sizes, terminal increments, delayed AX, focus cancellation, invalid/disappearing windows and old-edge restrictions. Mock windows only.")
    }
}
