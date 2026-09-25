import Foundation

@main struct HUDMapTests {
    static func main() throws {
        precondition(AppExplorerSettings().resolvedSwipeDirection == .inverted)
        let legacy = try JSONDecoder().decode(AppExplorerSettings.self, from: Data(#"{"defaultMode":"favorites","favorites":[]}"#.utf8))
        precondition(legacy.swipeDirection == nil && legacy.resolvedSwipeDirection == .inverted,
            "Existing profiles with no preference default to inverted")
        for mode in HUDSwipeDirection.allCases {
            let preference = AppExplorerSettings(swipeDirection: mode)
            let saved = try JSONEncoder().encode(preference)
            let restored = try JSONDecoder().decode(AppExplorerSettings.self, from: saved)
            precondition(restored.resolvedSwipeDirection == mode && restored == preference)
        }
        precondition(HUDSwipeDirection.inverted.navigation(for: .twoFingerDown) == .above)
        precondition(HUDSwipeDirection.regular.navigation(for: .twoFingerDown) == .below)
        precondition(HUDSwipeDirection.inverted.navigation(for: .oneFingerTap) == nil)
        var layers = HUDLayerPosition.allCases.map { position in
            var layer = ExplorerHoldLayer.empty(name: position.title)
            layer.position = position
            return layer
        }
        var settings = AppExplorerSettings(holdLayers: layers)
        precondition(settings.hasValidFavorites)
        let map = settings.hudMap(includingUnavailable: true)
        precondition(map.count == 9 && Set(map.map(\.point)).count == 9)
        precondition(map.first?.layerID == nil && map.first?.point == .zero)
        for origin in map {
            let offsets = map.map { $0.point - origin.point }
            for direction in HUDNavigationAction.allCases {
                let target = HUDMapPoint.nearestIndex(in: offsets, toward: direction)
                let expected: HUDMapPoint
                switch direction {
                case .next: expected = HUDMapPoint(x: origin.point.x + 1, y: origin.point.y)
                case .previous: expected = HUDMapPoint(x: origin.point.x - 1, y: origin.point.y)
                case .above: expected = HUDMapPoint(x: origin.point.x, y: origin.point.y + 1)
                case .below: expected = HUDMapPoint(x: origin.point.x, y: origin.point.y - 1)
                }
                if abs(expected.x) > 1 || abs(expected.y) > 1 {
                    precondition(target == nil, "Map edges must not cycle to another row")
                } else {
                    precondition(target.map { map[$0].point } == expected)
                }
            }
        }
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppExplorerSettings.self, from: encoded)
        precondition(decoded == settings && decoded.resolvedHUDPositions == settings.resolvedHUDPositions,
            "All eight explicit positions must survive saving")
        layers.indices.forEach { layers[$0].position = nil }
        settings.holdLayers = layers
        for (index, layer) in layers.enumerated() {
            precondition(settings.resolvedHUDPositions[layer.id] == HUDLayerPosition.legacyOrder[index])
        }
        var explicit = ExplorerHoldLayer.empty(name: "Explicit corner")
        explicit.position = .bottomRight
        settings.holdLayers = [explicit] + layers
        precondition(settings.resolvedHUDPositions[explicit.id] == .bottomRight)
        precondition(settings.resolvedHUDPositions.count == 8 && settings.holdLayers?.count == 9,
            "Keep imported overflow layers without placing a tenth HUD in the map")
        precondition(settings.hudMap().count == 9)
        let gapOffsets = [HUDMapPoint(x: -2, y: 0), HUDMapPoint(x: -1, y: -1)]
        precondition(HUDMapPoint.nearestIndex(in: gapOffsets, toward: .previous) == 0,
            "Skip an empty cell but never substitute a diagonal HUD")
        precondition(HUDMapPoint.nearestIndex(in: gapOffsets, toward: .below) == nil)
        print("HUD map tests passed: nine fixed positions, every cardinal edge, persistence, legacy assignment, gaps and lossless overflow.")
    }
}
