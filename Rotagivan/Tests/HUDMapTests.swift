import Foundation

@main struct HUDMapTests {
    static func main() throws {
        precondition(AppExplorerSettings().resolvedSwipeDirection == .inverted)
        precondition(!AppExplorerSettings().resolvedInvertPickerDirection)
        let legacy = try JSONDecoder().decode(AppExplorerSettings.self, from: Data(#"{"defaultMode":"favorites","favorites":[]}"#.utf8))
        precondition(legacy.swipeDirection == nil && legacy.resolvedSwipeDirection == .inverted,
            "Existing profiles with no preference default to inverted")
        for mode in HUDSwipeDirection.allCases {
            for invertedPicker in [false, true] {
            let preference = AppExplorerSettings(swipeDirection: mode, invertPickerDirection: invertedPicker)
            let saved = try JSONEncoder().encode(preference)
            let restored = try JSONDecoder().decode(AppExplorerSettings.self, from: saved)
            precondition(restored.resolvedSwipeDirection == mode && restored == preference)
            precondition(restored.resolvedInvertPickerDirection == invertedPicker)
            let directions: [(Double, Double, HUDNavigationAction)] = [
                (-100, 0, .previous), (100, 0, .next), (0, -100, .above), (0, 100, .below),
                (-100, -100, .topLeft), (100, -100, .topRight), (-100, 100, .bottomLeft), (100, 100, .bottomRight)]
            for (dx, dy, expected) in directions {
                let sign = mode == .inverted ? -1.0 : 1.0
                precondition(preference.resolvedSwipeDirection.navigation(dx: dx * sign, dy: dy * sign) == expected,
                    "Picker preference cannot change cardinal or diagonal HUD navigation")
            }
            }
        }
        precondition(legacy.invertPickerDirection == nil && !legacy.resolvedInvertPickerDirection)
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
                let expected = HUDMapPoint(x: origin.point.x + direction.step.x, y: origin.point.y + direction.step.y)
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
        var builtIns = AppExplorerSettings()
        var emptyMap = AppExplorerSettings(holdLayers: [ExplorerHoldLayer.empty(name: "Legacy right")])
        let legacyID = emptyMap.holdLayers![0].id
        for position in HUDLayerPosition.allCases where position != .right {
            let newID = emptyMap.assignEmptyHUD(at: position)!
            precondition(emptyMap.resolvedHUDPositions[newID] == position)
            precondition(emptyMap.resolvedHUDPositions[legacyID] == .right,
                "Adding a blank HUD must not move implicit legacy HUDs")
            precondition(emptyMap.projected(layerID: newID).favorites.isEmpty)
            let before = emptyMap
            precondition(emptyMap.assignEmptyHUD(at: position) == nil && emptyMap == before,
                "A stale empty-position click must never overwrite a HUD")
        }
        precondition(emptyMap.hudMap().count == 9 && emptyMap.hasValidFavorites)
        let emptyRoundTrip = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(emptyMap))
        precondition(emptyRoundTrip == emptyMap, "Blank HUDs and positions survive saving")
        for (kind, position) in zip(HUDLayerBuiltIn.allCases, HUDLayerPosition.legacyOrder) {
            let id = builtIns.assignBuiltIn(kind, at: position)!
            precondition(builtIns.holdLayers?.first { $0.id == id }?.builtIn == kind)
            precondition(builtIns.hudMap().first { $0.layerID == id }?.builtIn == kind)
            let before = builtIns
            precondition(builtIns.assignBuiltIn(.actions, at: position) == nil && builtIns == before,
                "Occupied map assignments must never be overwritten")
        }
        precondition(builtIns.hasValidFavorites)
        let decodedBuiltIns = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(builtIns))
        precondition(decodedBuiltIns == builtIns)
        for template in HUDLayerTemplate.allCases {
            var custom = AppExplorerSettings()
            let id = custom.assignTemplate(template, at: .right)!
            let layer = custom.holdLayers!.first!
            precondition(layer.builtIn == nil && !layer.favorites.isEmpty && custom.hasValidFavorites)
            let before = custom
            precondition(custom.assignTemplate(template, at: .right) == nil && custom == before)
            let roundTrip = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(custom))
            precondition(roundTrip == custom)
            custom.holdLayers![0].favorites = []
            precondition(custom.projected(layerID: id).favorites.isEmpty && custom.hudMap()[1].favorites.isEmpty,
                "Cleared templates must never repopulate")
        }
        var legacyMedia = AppExplorerSettings()
        let mediaID = legacyMedia.assignBuiltIn(.mediaControls, at: .left)!
        let preset = legacyMedia.projected(layerID: mediaID).favorites
        precondition(preset.count == 6 && legacyMedia.hudMap()[1].favorites == preset)
        precondition(legacyMedia.applying(legacyMedia.holdLayers![0], at: []).favorites == preset)
        precondition(Set(preset.compactMap { BindingAction.from(favorite: $0)?.media }) == Set(ExplorerMediaAction.allCases))
        // A custom entry in an imported legacy media layer must not be replaced.
        legacyMedia.holdLayers![0].favorites = [AppExplorerFavorite(direction: .left, name: "Lock", action: .lockScreen)]
        precondition(legacyMedia.projected(layerID: mediaID).favorites.first?.action == .lockScreen)
        print("HUD map tests passed: nine fixed positions, every cardinal edge, persistence, legacy assignment, gaps and lossless overflow.")
    }
}
