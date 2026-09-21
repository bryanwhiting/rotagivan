import SwiftUI

@main struct StarburstTests {
    static func main() throws {
        precondition(ExplorerTheme.starburst.title == "Starburst" && ExplorerTheme.starburst.isHUD)
        precondition(!ExplorerHUDMotion.enabled(theme: .starburst, preference: true, reduceMotion: true))
        precondition(!ExplorerHUDMotion.enabled(theme: .starburst, preference: false, reduceMotion: false))
        let rect = CGRect(x: 0, y: 0, width: 418, height: 310)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for depth in 0...5 {
            let inner = ExplorerStarburstLayout.innerRadius(depth: depth)
            if depth > 0 { precondition(ExplorerStarburstLayout.ringRadius(depth - 1) + 6 < inner) }
            for direction in ExplorerSlot.allCases {
                let point = ExplorerStarburstLayout.point(direction, radius: 116, center: center)
                let path = ExplorerStarburstSector(direction: direction, innerRadius: inner, outerRadius: 143, tip: 11).path(in: rect)
                precondition(path.contains(point), "Every label stays in its hit target at all nesting levels")
                precondition(!path.contains(center), "Rays cannot swallow the center/back button")
                precondition(rect.contains(path.boundingRect), "Rays must fit the HUD")
                for other in ExplorerSlot.allCases where other != direction {
                    precondition(!path.contains(ExplorerStarburstLayout.point(other, radius: 116, center: center)),
                        "Eight hit targets must not overlap")
                }
            }
        }
        precondition(ExplorerStarburstLayout.angle(.up) == -90)
        precondition(ExplorerStarburstLayout.angle(.left) == 180)
        let settings = AppExplorerSettings(theme: .starburst)
        let restored = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(settings))
        precondition(restored.resolvedTheme == .starburst)
        precondition(AppExplorerSettings().resolvedTheme == .vector, "Do not change the user's existing theme")
        print("Starburst passed: eight direction mappings, non-overlapping hit targets, center exclusion, five ancestor rings, bounds, persistence, unchanged default and reduced motion.")
    }
}
