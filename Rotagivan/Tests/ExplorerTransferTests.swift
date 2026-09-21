import Foundation

@main struct ExplorerTransferTests {
    static func main() throws {
        let app = AppExplorerFavorite(direction: .up, bundleID: "test.app", name: "App")
        let url = AppExplorerFavorite(direction: .left, name: "Website", url: "https://example.com")
        let innerLayer = ExplorerHoldLayer(name: "More", favorites: [url], slotCount: 16, activation: .toggle)
        let inner = AppExplorerFavorite(direction: .right, name: "Inner", children: [app], holdLayers: [innerLayer], slotCount: 4)
        let group = AppExplorerFavorite(direction: .left, name: "Work", children: [inner], holdLayers: [], slotCount: 12)
        let layer = ExplorerHoldLayer(name: "Alternate", favorites: [app], slotCount: 16)
        let initial = AppExplorerSettings(favorites: [group, app], holdLayers: [layer])
        precondition(initial.hasValidFavorites)
        func lookup(_ config: AppExplorerSettings, _ path: [ExplorerTilePathStep], _ slot: ExplorerSlot) -> AppExplorerFavorite? {
            config.tileContainers().first { $0.id == path }?.favorites.first { $0.direction == slot }
        }
        func relocated(_ favorite: AppExplorerFavorite, _ slot: ExplorerSlot) -> AppExplorerFavorite {
            var moved = favorite; moved.direction = slot; return moved
        }
        func transfer(_ config: AppExplorerSettings, _ source: [ExplorerTilePathStep] = [], _ slot: ExplorerSlot = .left) -> ExplorerTileTransfer {
            ExplorerTileTransfer(snapshot: config, source: source, slot: slot)
        }
        let alt: [ExplorerTilePathStep] = [.layer(layer.id)]
        let local: [ExplorerTilePathStep] = [.group(.left), .group(.right), .layer(innerLayer.id)]
        let containers = initial.tileContainers()
        precondition(containers.contains { $0.id == local && $0.count == 16 })
        precondition(containers.contains { $0.id == alt && $0.count == 16 })

        var settings = initial
        precondition(transfer(settings).apply(to: alt, slot: .right, copy: false, settings: &settings) == nil)
        precondition(lookup(settings, [], .left) == nil)
        precondition(lookup(settings, alt, .right) == relocated(group, .right), "Move carries entire recursive group and local layers")
        precondition(lookup(settings, [], .up) == app && lookup(settings, alt, .up) == app)
        precondition(transfer(settings, alt, .right).apply(to: [], slot: .left, copy: false, settings: &settings) == nil)
        precondition(lookup(settings, [], .left) == group, "Round-trip across layers is lossless")

        settings = initial
        precondition(transfer(settings).apply(to: alt, slot: .up, copy: false, settings: &settings) == nil)
        precondition(lookup(settings, [], .left) == relocated(app, .left), "Occupied destination swaps, never overwrites")
        precondition(lookup(settings, alt, .up) == relocated(group, .up))

        settings = initial
        precondition(transfer(settings).apply(to: alt, slot: .left, copy: true, settings: &settings) == nil)
        precondition(lookup(settings, [], .left) == group && lookup(settings, alt, .left) == group)
        let decoded = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(settings))
        precondition(decoded == settings, "Copies need no new persistence schema")
        let clonedLocal = alt + [.group(.left), .group(.right), .layer(innerLayer.id)]
        precondition(settings.tileContainers().contains { $0.id == clonedLocal })
        precondition(transfer(settings, clonedLocal, .left).apply(to: local, slot: .right, copy: false, settings: &settings) == nil)
        precondition(lookup(settings, clonedLocal, .left) == nil && lookup(settings, local, .right) == relocated(url, .right))
        precondition(lookup(settings, local, .left) == url, "Copied groups are independent value trees")

        // Moving OUT of a nested group-local layer to a root layer.
        settings = initial
        precondition(transfer(settings, local, .left).apply(to: alt, slot: .right, copy: false, settings: &settings) == nil)
        precondition(lookup(settings, local, .left) == nil && lookup(settings, alt, .right) == relocated(url, .right))
        // Moving into another group's local layer.
        precondition(transfer(settings, alt, .right).apply(to: local, slot: .left, copy: false, settings: &settings) == nil)
        precondition(lookup(settings, local, .left) == url)

        func rejected(_ config: AppExplorerSettings, source: [ExplorerTilePathStep] = [], slot: ExplorerSlot = .left,
                      destination: [ExplorerTilePathStep], target: ExplorerSlot, copy: Bool = false) {
            var result = config
            precondition(transfer(config, source, slot).apply(to: destination, slot: target, copy: copy, settings: &result) != nil)
            precondition(result == config, "Rejected operations must be atomic")
        }
        rejected(initial, destination: [], target: .left)
        rejected(initial, destination: alt, target: .up, copy: true)
        rejected(initial, destination: [.group(.left)], target: .up)
        rejected(initial, destination: local, target: .right, copy: true)
        rejected(initial, source: local, slot: .left, destination: [], target: .left)
        rejected(initial, destination: [.layer(UUID())], target: .right)
        rejected(initial, destination: [.group(.up)], target: .left)
        rejected(initial, slot: .down, destination: alt, target: .right)
        let stale = transfer(initial)
        settings = initial; settings.favorites[0].name = "Renamed elsewhere"
        let edited = settings
        precondition(stale.apply(to: alt, slot: .right, copy: false, settings: &settings) != nil && settings == edited)

        let recent = AppExplorerFavorite(direction: .down, name: "Recents", children: [app], groupMode: .recent,
                                         holdLayers: [innerLayer])
        let wm = AppExplorerFavorite(direction: .right, name: "Windows", action: .windowManager,
                                    holdLayers: [ExplorerHoldLayer(name: "Thirds", windowLayout: .thirds)])
        settings = AppExplorerSettings(favorites: [group, recent, wm], holdLayers: [layer])
        precondition(settings.hasValidFavorites)
        precondition(!settings.tileContainers().contains { $0.id == [.group(.down)] || $0.id == [.group(.right)] })
        precondition(settings.tileContainers().contains { $0.id == [.group(.down), .layer(innerLayer.id)] })
        rejected(settings, destination: [.group(.down)], target: .left)
        rejected(settings, destination: [.group(.right)], target: .left)
        precondition(transfer(settings, [], .down).apply(to: alt, slot: .left, copy: true, settings: &settings) == nil)
        precondition(lookup(settings, alt, .left)?.children == [app], "Hidden favorites inside recents survive copying")

        // A deep group cannot be inserted where its descendants would exceed depth 4.
        var deep = group
        for name in ["Middle", "Outer"] { deep = AppExplorerFavorite(direction: .left, name: name, children: [deep]) }
        let destinationGroup = AppExplorerFavorite(direction: .right, name: "Target", children: [])
        let deepConfig = AppExplorerSettings(favorites: [deep, destinationGroup])
        precondition(deepConfig.hasValidFavorites)
        rejected(deepConfig, destination: [.group(.right)], target: .left)

        // Budget validation includes all layers and copied descendants.
        let fullGrid = ExplorerSlot.slots(16).map { relocated(app, $0) }
        let fullGroup = AppExplorerFavorite(direction: .left, name: "Full", children: fullGrid, slotCount: 16)
        let fullLayers = (0..<14).map { ExplorerHoldLayer(name: "Layer \($0)", favorites: fullGrid, slotCount: 16) }
        let budget = AppExplorerSettings(favorites: [fullGroup], holdLayers: fullLayers, slotCount: 16)
        precondition(budget.hasValidFavorites)
        rejected(budget, destination: [], target: .right, copy: true)

        // Every supported capacity's empty slots work without changing the group's layout.
        for count in [4, 8, 12, 16] {
            for target in ExplorerSlot.slots(count) {
                let destinationLayer = ExplorerHoldLayer(name: "Target", slotCount: count)
                var config = AppExplorerSettings(favorites: [group], holdLayers: [destinationLayer])
                let path: [ExplorerTilePathStep] = [.layer(destinationLayer.id)]
                precondition(transfer(config).apply(to: path, slot: target, copy: false, settings: &config) == nil)
                precondition(lookup(config, path, target) == relocated(group, target))
            }
        }
        print("ExplorerTransferTests passed: cross-layer/group move, copy, swap, local scopes, capacities, stale edits, cycles, depth and budgets")
    }
}
