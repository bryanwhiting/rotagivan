import AppKit

@main struct ExplorerLayerMediaTests {
    @MainActor static func main() throws {
        let blank = ExplorerHoldLayer.empty()
        precondition(blank.favorites.isEmpty && blank.holdShortcut == nil && blank.launchShortcut == nil)
        precondition(blank.appBundleID == nil && blank.appName == nil && blank.activation == nil && blank.slotCount == 8)
        let blankSettings = AppExplorerSettings(holdLayers: [blank])
        precondition(blankSettings.hasValidFavorites && blankSettings.projected(layerID: blank.id).favorites.isEmpty)
        precondition(blankSettings.windowEditor().holdLayers?.first?.favorites.isEmpty == true,
                     "A new empty window layer must not regenerate legacy window presets")
        let blankDecoded = try JSONDecoder().decode(ExplorerHoldLayer.self, from: JSONEncoder().encode(blank))
        precondition(blankDecoded == blank && ExplorerHoldLayer.empty().id != blank.id)
        let y = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y")
        let u = RecordedShortcut(keyCode: 32, modifiers: 1 << 19, keyLabel: "U")
        let media = AppExplorerFavorite(direction: .up, name: "Media", action: .mediaControls)
        let first = ExplorerHoldLayer(name: "Thirds", holdShortcut: y, favorites: [media], windowLayout: .thirds)
        let second = ExplorerHoldLayer(name: "Wide", holdShortcut: u, windowLayout: .twoThirds)
        let settings = AppExplorerSettings(favorites: [], holdLayers: [first, second])
        precondition(settings.hasValidFavorites)
        let decoded = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(settings))
        precondition(decoded == settings)
        precondition(settings.projected(layerID: first.id).favorites == [media])
        precondition(settings.projected(layerID: first.id).holdLayers == nil)
        var keys = ExplorerHeldKeys()
        precondition(!keys.press(key: 16, modifiers: 1 << 20, layers: [first, second]))
        precondition(keys.press(key: 16, modifiers: 0, layers: [first, second]))
        precondition(keys.press(key: 16, modifiers: 0, layers: [first, second]))
        precondition(keys.activeID == first.id)
        precondition(keys.press(key: 32, modifiers: 1 << 19, layers: [first, second]))
        precondition(keys.activeID == second.id)
        keys.updateModifiers(0)
        precondition(keys.activeID == first.id)
        keys.release(key: 16)
        precondition(keys.activeID == nil)
        var invalid = settings
        invalid.holdLayers![1].holdShortcut = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Different label")
        precondition(!invalid.hasValidFavorites)
        invalid = settings; invalid.holdShortcut = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Other Y")
        precondition(invalid.hasValidFavorites, "Retired root shortcut must not reserve a HUD layer key")
        invalid = settings; invalid.holdLayers![0].holdShortcut?.keyCode = 53
        precondition(!invalid.hasValidFavorites)
        invalid = settings; invalid.holdLayers![1].id = first.id
        precondition(!invalid.hasValidFavorites)
        let area = CGRect(x: -1500, y: -500, width: 1200, height: 900)
        for layout in ExplorerWindowLayout.allCases {
            for direction in SwipeDirection.allCases {
                let frame = WindowTile.frame(direction, in: area, layout: layout)
                precondition(area.contains(frame))
            }
        }
        precondition(WindowTile.frame(.left, in: area, layout: .thirds).width == 400)
        precondition(WindowTile.frame(.right, in: area, layout: .twoThirds) == CGRect(x: -1100, y: -500, width: 800, height: 900))
        precondition(WindowTile.frame(.topRight, in: area, layout: .thirds) == CGRect(x: -700, y: -500, width: 400, height: 300))
        for action in ExplorerMediaAction.allCases {
            let events = ExplorerMediaAction.events(for: action)
            precondition(events.count == 2)
            for (index, event) in events.enumerated() {
                precondition(event.type == .systemDefined && event.subtype.rawValue == 8)
                precondition(event.data1 >> 16 == action.rawValue)
                precondition((event.data1 >> 8) & 0xff == (index == 0 ? 0xa : 0xb))
                precondition(event.cgEvent != nil)
            }
        }
        print("Explorer hold layers passed: persistence, projection, key priority/repeat/release/modifiers, duplicate/reserved-key validation and thirds/two-thirds geometry.")
        print("Media controls passed: six native key-down/up event pairs and action mappings; no media events posted.")
    }
}
