// Manual native-window smoke check; never selects or activates another app.
import AppKit

@main struct AppExplorerHUDSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.HUDSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppExplorerController(defaults: defaults)
        func favorite(_ direction: ExplorerSlot, _ name: String) -> AppExplorerFavorite {
            AppExplorerFavorite(direction: direction, name: name,
                url: "https://example.com/\(name.lowercased())", iconSymbol: "link")
        }
        var right = ExplorerHoldLayer.empty(name: "Work")
        right.position = .right
        right.favorites = [favorite(.left, "Mail"), favorite(.right, "Calendar")]
        var top = ExplorerHoldLayer.empty(name: "Create")
        top.position = .top
        top.favorites = [favorite(.up, "Canvas"), favorite(.down, "Notes")]
        var bottom = ExplorerHoldLayer.empty(name: "Focus")
        bottom.position = .bottom
        bottom.favorites = [favorite(.up, "Timer"), favorite(.down, "Music")]
        let settings = AppExplorerSettings(favorites: [favorite(.left, "Home"), favorite(.right, "Search")],
            holdLayers: [right, top, bottom])
        controller.configuration = { settings }
        controller.contextIsValid = { true }
        controller.show(waitingForLift: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(controller.isVisible)
        precondition(controller.navigateHUD(.next), "A horizontal swipe should rotate to the right-hand HUD")
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        let window = NSApp.windows.first { $0.title == "App Explorer" }!
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        precondition(controller.navigateHUD(.previous), "The reverse horizontal swipe should return to Main HUD")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(controller.navigateHUD(.above), "An upward swipe should rotate to the upper HUD")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(controller.navigateHUD(.below), "A downward swipe should return to Main HUD")
        controller.dismiss()
        precondition(!controller.isVisible)
        print("Native App Explorer HUD rotated in all four directions, rendered mid-transition, and dismissed without activating an app.")
    }
}
