import SwiftUI

@main struct StarburstTests {
    static func main() throws {
        precondition(ExplorerTheme.starburst.title == "Starburst" && ExplorerTheme.starburst.isHUD)
        precondition(!ExplorerHUDMotion.enabled(theme: .starburst, preference: true, reduceMotion: true))
        precondition(!ExplorerHUDMotion.enabled(theme: .starburst, preference: false, reduceMotion: false))
        let rect = CGRect(x: 0, y: 0, width: 418, height: 310)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for theme in ExplorerTheme.allCases {
            for count in [4, 8, 12, 16] where theme.isRadial || count != 8 {
                for depth in 0...4 {
                    for slot in ExplorerSlot.slots(count) {
                        let point = ExplorerStarburstLayout.point(slot, radius: 116, center: center)
                        precondition(ExplorerPreviewGeometry.dropTarget(at: point, from: .up, theme: theme, count: count, depth: depth) == slot)
                    }
                    precondition(ExplorerPreviewGeometry.dropTarget(at: center, from: .up, theme: theme, count: count, depth: depth) == nil)
                    precondition(ExplorerPreviewGeometry.dropTarget(at: CGPoint(x: -20, y: 0), from: .up, theme: theme, count: count, depth: depth) == nil)
                }
            }
        }
        precondition(ExplorerPreviewGeometry.dropTarget(at: CGPoint(x: 341, y: 49), from: .left, theme: .native, count: 8, depth: 0) == .right)
        precondition(ExplorerPreviewGeometry.dropTarget(at: CGPoint(x: 203, y: 49), from: .left, theme: .native, count: 8, depth: 0) == nil)
        print("HUD preview drop targets passed: actual sector paths, every theme/capacity/depth, center/outside rejection and Classic layout")
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
        precondition(ExplorerTheme.allCases == [.native, .starburst, .starburstAir])
        precondition(AppExplorerSettings().resolvedTheme == .starburstAir)
        for legacy in ["vector", "ember"] {
            let current = try JSONEncoder().encode(AppExplorerSettings(theme: .starburstAir))
            let legacyJSON = String(decoding: current, as: UTF8.self).replacingOccurrences(of: "starburstAir", with: legacy)
            let migrated = try JSONDecoder().decode(AppExplorerSettings.self, from: Data(legacyJSON.utf8))
            precondition(migrated.resolvedTheme == .starburstAir)
            let saved = try JSONEncoder().encode(migrated)
            precondition(String(decoding: saved, as: UTF8.self).contains("starburstAir"))
        }
        for theme in ExplorerTheme.allCases {
            let decoded = try JSONDecoder().decode(ExplorerTheme.self, from: JSONEncoder().encode(theme))
            precondition(decoded == theme)
        }
        precondition(ExplorerTheme.starburstAir.isRadial && ExplorerTheme.starburstAir.isFloating)
        for count in [4, 8, 12, 16] {
            for depth in 0...5 {
                for slot in ExplorerSlot.slots(count) {
                    let halfAngle = 180 / Double(count) - 2
                    let shape = ExplorerStarburstSector(direction: slot,
                        innerRadius: ExplorerStarburstLayout.innerRadius(depth: depth),
                        outerRadius: 143, tip: 2, halfAngle: halfAngle, roundedRim: true)
                    let angle = (slot.angle + halfAngle * 0.5) * .pi / 180
                    let point = CGPoint(x: center.x + cos(angle) * 144, y: center.y + sin(angle) * 144)
                    precondition(shape.path(in: rect).contains(point), "Air's curved glass rim must be selectable")
                    precondition(ExplorerPreviewGeometry.dropTarget(at: point, from: .up, theme: .starburstAir,
                        count: count, depth: depth) == slot, "Editor and rendered glass must use identical curved hit targets")
                    precondition(!shape.path(in: rect).contains(center))
                    precondition(rect.contains(shape.path(in: rect).boundingRect))
                }
            }
        }
        precondition(!ExplorerHUDMotion.enabled(theme: .starburstAir, preference: true, reduceMotion: true))
        print("Starburst passed: radial geometry, hit targets, center exclusion, nested rings, three-theme catalog, retired-theme migration, persistence and reduced motion.")
    }
}
