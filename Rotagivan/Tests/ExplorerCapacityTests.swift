import Foundation

@main struct ExplorerCapacityTests {
    static func main() throws {
        precondition(SwipeDirection.allCases.count == 8, "Physical gesture bindings stay eight-way")
        for count in 2...16 {
            let slots = ExplorerSlot.slots(count)
            precondition(slots.count == count && Set(slots).count == count)
            for slot in slots {
                let radians = slot.angle * .pi / 180
                precondition(ExplorerSlot.classify(dx: cos(radians) * 100, dy: sin(radians) * 100, count: count) == slot)
                let edge = (slot.angle + 180 / Double(count)) * .pi / 180
                precondition(ExplorerSlot.classify(dx: cos(edge) * 100, dy: sin(edge) * 100, count: count) == nil)
                let decoded = try JSONDecoder().decode(ExplorerSlot.self, from: JSONEncoder().encode(slot))
                precondition(decoded == slot)
                var selection = AppExplorerSelection(waitingForLift: false, slotCount: count)
                func report(_ x: Double?, _ y: Double = 500) -> TrackpadReport {
                    TrackpadReport(contacts: x.map { [FingerContact(id: 0, x: $0, y: y, touching: true, confident: true)] } ?? [], buttonDown: false, scanTime: 0)
                }
                _ = selection.process(report(500))
                _ = selection.process(report(500 + cos(radians) * 100, 500 + sin(radians) * 100))
                precondition(selection.process(report(nil)) == .select(slot))
            }
            let favorites = slots.enumerated().map { AppExplorerFavorite(direction: $0.element, bundleID: "app.\($0.offset)", name: "App \($0.offset)") }
            let settings = AppExplorerSettings(favorites: favorites, slotCount: count)
            precondition(settings.hasValidFavorites)
            let restored = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(settings))
            precondition(restored == settings)
        }
        var base = AppExplorerSettings(favorites: ExplorerSlot.legacy.map { AppExplorerFavorite(direction: $0, name: $0.title, url: "https://example.com") })
        let originalNames = Set(base.favorites.map(\.name))
        base.holdLayers = [ExplorerHoldLayer(name: "Second", favorites: base.favorites)]
        precondition(base.resize(to: 12, at: []) && base.hasValidFavorites)
        precondition(Set(base.favorites.map(\.name)) == originalNames && base.holdLayers?.first?.slotCount == 8)
        let snapshot = base
        precondition(!base.resize(to: 4, at: []) && base == snapshot)
        precondition(base.resize(to: 16, at: []) && base.hasValidFavorites)
        let group = AppExplorerFavorite(direction: .left, name: "Recent", children: snapshot.favorites,
            groupMode: .recent, slotCount: 12)
        var nested = AppExplorerSettings(favorites: [group])
        precondition(nested.resize(to: 16, at: [.left]))
        precondition(Set(nested.favorite(at: [.left])!.children!.map(\.name)) == originalNames, "Resizing recents preserves hidden assigned favorites")
        let y = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y")
        let alternate = ExplorerHoldLayer(name: "Toggled", holdShortcut: y, favorites: [], slotCount: 16, activation: .toggle)
        base = AppExplorerSettings(holdLayers: [alternate])
        var keys = ExplorerScopedHeldKeys()
        precondition(keys.press(key: 16, modifiers: 0, path: [], settings: base))
        keys.release(key: 16)
        precondition(keys.activeID == alternate.id && keys.resolved(base).count(at: []) == 16)
        precondition(keys.press(key: 16, modifiers: 0, path: [], settings: base))
        precondition(keys.activeID == nil)
        var invalid = base; invalid.slotCount = 17; precondition(!invalid.hasValidFavorites)
        invalid = base; invalid.favorites = [AppExplorerFavorite(direction: ExplorerSlot.slots(16)[1], name: "Hidden", url: "https://example.com")]
        precondition(!invalid.hasValidFavorites, "Reject unreachable slots for the chosen count")
        let recents = AppExplorerRecents((0..<20).map { "app.\($0)" })
        precondition(recents.ordered(available: (0..<20).map { "app.\($0)" }, excluding: [], limit: 16).count == 16)
        let deepChildren = ExplorerSlot.slots(3).enumerated().map {
            AppExplorerFavorite(direction: $0.element, name: "Deep \($0.offset)",
                windowPlacement: ExplorerWindowPlacement(direction: .left, layout: $0.offset == 0 ? .thirds : .twoThirds))
        }
        let deepTile = AppExplorerFavorite(direction: .left, name: "Left half", children: deepChildren,
            slotCount: 3, windowPlacement: ExplorerWindowPlacement(direction: .left))
        precondition(AppExplorerSettings(favorites: [deepTile]).hasValidFavorites,
            "A tile may keep its quick action while owning an independently sized deep fan")
        func report(_ x: Double?, _ y: Double = 500) -> TrackpadReport {
            TrackpadReport(contacts: x.map { [FingerContact(id: 0, x: $0, y: y, touching: true, confident: true)] } ?? [], buttonDown: false, scanTime: 0)
        }
        let time = Date(timeIntervalSince1970: 1_000)
        var quickSelection = AppExplorerSelection(waitingForLift: false, deepSlots: [.left])
        _ = quickSelection.process(report(500), at: time)
        _ = quickSelection.process(report(400), at: time.addingTimeInterval(0.01))
        precondition(quickSelection.process(report(nil), at: time.addingTimeInterval(0.2)) == .select(.left),
            "A quick release must keep the tile's primary action")
        var deepSelection = AppExplorerSelection(waitingForLift: false, deepSlots: [.left])
        _ = deepSelection.process(report(500), at: time)
        precondition(deepSelection.process(report(400), at: time.addingTimeInterval(0.01)) == .highlight(.left))
        guard case .deepen(.left, let continuation) = deepSelection.process(report(400),
            at: time.addingTimeInterval(AppExplorerSelection.deepHoldDuration + 0.02)) else {
            preconditionFailure("Holding a programmed sector should open its deep fan")
        }
        var fanSelection = AppExplorerSelection(continuing: continuation, slotCount: 3, fanOrigin: .left)
        let expected = DeepSwipeFan.classify(dx: -100, dy: 0, count: 3, origin: .left)!
        precondition(fanSelection.process(report(400), at: time.addingTimeInterval(0.6)) == .highlight(expected))
        precondition(fanSelection.process(report(nil), at: time.addingTimeInterval(0.61)) == .select(expected))
        print("Explorer capacities passed: 2–16 sectors, deep fan hold/selection, uneven branch density, dead seams, lossless resizing, nested recents and invalid imports.")
    }
}
