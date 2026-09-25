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
        var settings = AppExplorerSettings(actionBindings: [
            ActionBinding(trigger: BindingTrigger(keyboard: RecordedShortcut(keyCode: 49, modifiers: 0, keyLabel: "Space")),
                action: .media(.mute))
        ], favorites: [deepLeft, favorite(.right, "Search")],
            holdLayers: [right, top, bottom])
        controller.configuration = { settings }
        controller.contextIsValid = { true }
        controller.show(waitingForLift: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(controller.isVisible)
        func orbitPair(_ x: Double?) -> TrackpadReport {
            TrackpadReport(contacts: x.map { value in [
                FingerContact(id: 1, x: value, y: 500, touching: true, confident: true),
                FingerContact(id: 2, x: value + 30, y: 500, touching: true, confident: true)
            ] } ?? [], buttonDown: false, scanTime: 0)
        }
        for (name, distance) in [("rest", 0.0), ("partial", 65.0), ("near-complete", 160.0)] {
            if distance > 0 { controller.process(orbitPair(500)) }
            if distance > 0 { controller.process(orbitPair(500 - distance)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            let orbitWindow = NSApp.windows.first { $0.title == "App Explorer" }!
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(orbitWindow.windowNumber), CommandLine.arguments[1] + ".screen-" + name + ".png"]
            try capture.run(); capture.waitUntilExit()
            let content = orbitWindow.contentView!

            content.layoutSubtreeIfNeeded()
            let image = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1] + "." + name + ".png"))
            if distance > 0 { controller.process(orbitPair(500)) }
            if distance > 0 { controller.process(orbitPair(nil)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }

        controller.process(orbitPair(500))
        controller.process(orbitPair(390))
        controller.process(orbitPair(nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(controller.displayedEntries.contains { $0.name == "Mail" }, "Animated release must finish on the incoming HUD")
        precondition(controller.navigateHUD(.previous))
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

        // Vertical swipes remain useful even when the next HUD has only a
        // horizontal map position: they fall back to the same cyclic stack.
        settings.holdLayers = [right]
        controller.show(waitingForLift: false)
        func pair(_ y: Double?) -> TrackpadReport {
            TrackpadReport(contacts: y.map { value in [
                FingerContact(id: 1, x: 480, y: value, touching: true, confident: true),
                FingerContact(id: 2, x: 520, y: value, touching: true, confident: true)
            ] } ?? [], buttonDown: false, scanTime: 0)
        }
        controller.process(pair(500))
        controller.process(pair(620))
        controller.process(pair(nil))
        precondition(controller.displayedEntries.contains { $0.name == "Mail" },
            "A two-finger downward swipe must navigate the HUD even without a layer below")
        controller.dismiss()
        print("Native App Explorer HUD rendered orbit phases and navigated all four directions, captured vertical two-finger navigation, and rendered a held three-choice deep fan without activating an app.")
    }
}
