import AppKit
import SwiftUI

@main struct HUDMapUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.HUDMapSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppExplorerController(defaults: defaults)
        let shortcut = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
        func tiles(_ name: String) -> [AppExplorerFavorite] {
            [.up, .left, .right, .down].map { direction in
                AppExplorerFavorite(direction: direction, name: "\(name) \(direction.title)", shortcut: shortcut)
            }
        }
        let layers = HUDLayerPosition.allCases.map { position in
            var layer = ExplorerHoldLayer.empty(name: position.title)
            layer.position = position
            layer.favorites = tiles(position.title)
            return layer
        }
        let settings = AppExplorerSettings(favorites: tiles("Main"), holdLayers: layers)
        controller.configuration = { settings }
        controller.contextIsValid = { true }
        controller.show(waitingForLift: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let panel = NSApp.windows.first { $0.title == "App Explorer" }!
        func capture(_ window: NSWindow, _ name: String) throws {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-l", String(window.windowNumber), CommandLine.arguments[1] + "-" + name + ".png"]
            try process.run(); process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            print("Captured \(name), window: \(window.frame), view: \(window.contentView!.bounds)")
        }
        try capture(panel, "main")
        func pair(_ point: HUDMapPoint?) -> TrackpadReport {
            TrackpadReport(contacts: point.map { point in [
                FingerContact(id: 1, x: Double(point.x), y: Double(point.y), touching: true, confident: true),
                FingerContact(id: 2, x: Double(point.x + 30), y: Double(point.y), touching: true, confident: true)
            ] } ?? [], buttonDown: false, scanTime: 0)
        }
        let route: [(HUDNavigationAction, HUDLayerPosition?)] = [
            (.next, .right), (.above, .topRight), (.previous, .top), (.previous, .topLeft),
            (.below, .left), (.below, .bottomLeft), (.next, .bottom), (.next, .bottomRight),
            (.above, .right), (.previous, nil)
        ]
        for (direction, position) in route {
            let end: HUDMapPoint
            switch direction {
            case .next: end = HUDMapPoint(x: 300, y: 500)
            case .previous: end = HUDMapPoint(x: 700, y: 500)
            case .above: end = HUDMapPoint(x: 500, y: 700)
            case .below: end = HUDMapPoint(x: 500, y: 300)
            }
            controller.process(pair(HUDMapPoint(x: 500, y: 500)))
            controller.process(pair(end))
            precondition(controller.displayedOrbitProgress == 1)
            controller.process(pair(nil))
            let expected = position.flatMap { point in layers.first { $0.position == point }?.id }
            precondition(controller.displayedLayerID == expected, "A full swipe must immediately activate the spatial neighbor")
            precondition(controller.displayedHUDMap.count == 8)
            if position == .right || position == .topRight || position == .bottomLeft {
                try capture(panel, position!.rawValue)
            }
        }
        controller.dismiss()
        let store = SettingsStore(defaults: defaults)
        let settingsPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        settingsPanel.isReleasedWhenClosed = false
        settingsPanel.contentView = NSHostingView(rootView:
            ScrollView {
                AppExplorerSettingsView(store: store, configurationOverride: .constant(settings))
                    .padding(20)
            }.frame(width: 1000, height: 800))
        settingsPanel.center()
        settingsPanel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try capture(settingsPanel, "settings")
        settingsPanel.orderOut(nil); settingsPanel.close()
        print("Nine-HUD UI smoke passed: swiped through every position, immediate full-swipe handoffs, eight neighbors retained, fixed settings map rendered.")
    }
}
