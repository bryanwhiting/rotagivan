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
        let deepChoices = [
            AppExplorerFavorite(direction: ExplorerSlot.slots(3)[0], name: "Left third",
                windowPlacement: ExplorerWindowPlacement(direction: .left, layout: .thirds)),
            AppExplorerFavorite(direction: ExplorerSlot.slots(3)[1], name: "Left half",
                windowPlacement: ExplorerWindowPlacement(direction: .left, layout: .halves)),
            AppExplorerFavorite(direction: ExplorerSlot.slots(3)[2], name: "Left two thirds",
                windowPlacement: ExplorerWindowPlacement(direction: .left, layout: .twoThirds))
        ]
        let deepLeft = AppExplorerFavorite(direction: .left, name: "Left half", children: deepChoices, slotCount: 3,
            windowPlacement: ExplorerWindowPlacement(direction: .left, layout: .halves))
        let settings = AppExplorerSettings(favorites: [deepLeft, favorite(.right, "Search")],
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func report(_ x: Double?, _ y: Double = 500) -> TrackpadReport {
            TrackpadReport(contacts: x.map { [FingerContact(id: 0, x: $0, y: y, touching: true, confident: true)] } ?? [],
                buttonDown: false, scanTime: 0)
        }
        controller.process(report(500))
        controller.process(report(400))
        RunLoop.main.run(until: Date().addingTimeInterval(AppExplorerSelection.deepHoldDuration + 0.04))
        controller.process(report(400))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        let deepBitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: deepBitmap)
        let deepURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingPathExtension().appendingPathExtension("deep.png")
        try deepBitmap.representation(using: .png, properties: [:])!.write(to: deepURL)
        controller.dismiss()
        precondition(!controller.isVisible)
        print("Native App Explorer HUD rotated in all four directions and rendered a held three-choice deep fan without activating an app.")
    }
}
