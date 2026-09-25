import AppKit

@main struct HUDTemplateTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.TemplateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppExplorerController(defaults: defaults)
        controller.contextIsValid = { true }
        var settings = AppExplorerSettings()
        let mediaID = settings.assignBuiltIn(.mediaControls, at: .right)!
        controller.configuration = { settings }
        controller.show(waitingForLift: false)
        precondition(controller.navigateHUD(.next))
        precondition(controller.displayedLayerID == mediaID)
        precondition(Set(controller.displayedEntries.compactMap(\.mediaAction)) == Set(ExplorerMediaAction.allCases),
            "Legacy media layers must render all six editable actions")
        controller.dismiss()
        settings.holdLayers![0].builtIn = nil
        settings.holdLayers![0].favorites = HUDLayerTemplate.mediaControls.favorites
        settings.holdLayers![0].favorites.removeAll { $0.direction == .left }
        settings.holdLayers![0].favorites.append(AppExplorerFavorite(direction: .left, name: "Custom Lock", action: .lockScreen))
        controller.show(waitingForLift: false)
        precondition(controller.navigateHUD(.next))
        precondition(controller.displayedEntries.first { $0.direction == .left }?.command == .lockScreen,
            "Runtime must honor template edits instead of regenerating media controls")
        precondition(controller.displayedEntries.filter { $0.mediaAction != nil }.count == 5)
        controller.dismiss()
        for tile in HUDLayerTemplate.macActions.favorites {
            let entry = AppExplorerController.makeEntry(tile, depth: 0, dictionary: [])
            precondition(entry.command == tile.action)
            precondition(BindingAction.from(favorite: tile)?.description.isEmpty == false)
        }
        print("HUD templates passed: legacy media, customized live media entries, Mac commands and descriptions; no actions executed")
    }
}
