import AppKit
import SwiftUI

@main struct ExplorerAppletUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.ExplorerAppletSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        let controller = AppExplorerController(defaults: defaults)
        controller.configuration = { store.settings.appExplorer ?? AppExplorerSettings() }
        controller.frontmostPID = { 4242 }
        controller.contextIsValid = { true }
        var opened: [URL] = []
        controller.openWebURL = { opened.append($0); return true }
        func report(_ x: Double?, _ y: Double = 500) -> TrackpadReport {
            TrackpadReport(contacts: x.map { [FingerContact(id: 0, x: $0, y: y, touching: true, confident: true)] } ?? [], buttonDown: false, scanTime: 0)
        }
        func swipe(_ slot: ExplorerSlot) {
            let radians = slot.angle * .pi / 180
            controller.process(report(500))
            controller.process(report(500 + cos(radians) * 120, 500 + sin(radians) * 120))
            controller.process(report(nil))
        }
        @discardableResult func key(_ code: UInt16, down: Bool = true, repeatKey: Bool = false) -> Bool {
            controller.processLayerKey(NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code)!)
        }
        func snapshot(_ name: String) throws {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let view = NSApp.windows.first { $0.title == "App Explorer" && $0.isVisible }!.contentView!
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/\(name).png"))
        }
        for count in [4, 8, 12, 16] {
            let slots = ExplorerSlot.slots(count)
            store.settings.appExplorer = AppExplorerSettings(favorites: slots.enumerated().map {
                AppExplorerFavorite(direction: $0.element, name: "App \($0.offset + 1)", url: "https://example.com/\(count)/\($0.offset)")
            }, slotCount: count)
            for (index, slot) in slots.enumerated() {
                controller.show(waitingForLift: false)
                if index == 0 { try snapshot("slots-\(count)") }
                precondition(controller.displayedEntries.count == count)
                swipe(slot)
                precondition(!controller.isVisible && opened.last?.path == "/\(count)/\(index)")
            }
        }
        let actionKey = RecordedShortcut(keyCode: 15, modifiers: 1 << 20, keyLabel: "R")
        store.settings.appExplorer = AppExplorerSettings(favorites: [
            AppExplorerFavorite(direction: .right, name: "Hotkey docs", url: "https://example.com/hotkey",
                activationShortcut: actionKey)
        ])
        controller.show(waitingForLift: false)
        let hotkeyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
        precondition(controller.processLayerKey(hotkeyEvent))
        precondition(!controller.isVisible && opened.last?.path == "/hotkey",
            "Layer-local hotkey runs the same URL action as its tile")
        let y = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y")
        let toggleLayer = ExplorerHoldLayer(name: "Second", holdShortcut: y,
            favorites: ExplorerSlot.slots(16).map { AppExplorerFavorite(direction: $0, name: "Alternate", url: "https://example.com/alternate") }, slotCount: 16, activation: .toggle)
        store.settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .left, name: "Work", children: [], holdLayers: [toggleLayer])])
        controller.show(waitingForLift: false); swipe(.left)
        precondition(key(16)); key(16, down: false)
        precondition(controller.displayedEntries.count == 16)
        key(16, repeatKey: true); precondition(controller.displayedEntries.count == 16)
        key(16); precondition(controller.displayedEntries.isEmpty)
        controller.goBack(); precondition(!key(16)); controller.dismiss()

        var fullScreen = false, tiled = 0
        var layouts: [ExplorerWindowLayout] = [], commands: [AppExplorerAction] = []
        controller.captureWindow = { _ in
            WindowTilingTarget(isFullScreen: { fullScreen }, command: { commands.append($0); return nil },
                apply: { _, layout in tiled += 1; layouts.append(layout); return nil })
        }
        store.settings.appExplorer = AppExplorerSettings(windowManager: ExplorerWindowSettings(layers: [
            ExplorerHoldLayer(name: "Fourths", holdShortcut: y, windowLayout: .fourths, activation: .toggle)
        ], shortcuts: [
            ExplorerWindowShortcut(command: .maximize, shortcut: RecordedShortcut(keyCode: 46, modifiers: 0, keyLabel: "M")),
            ExplorerWindowShortcut(command: .toggleFullScreen, shortcut: RecordedShortcut(keyCode: 3, modifiers: 0, keyLabel: "F"))
        ]))
        controller.showWindowManager(waitingForLift: false); key(16); key(16, down: false)
        precondition(controller.displayedEntries.first?.name.contains("¼") == true)
        try snapshot("window-fourths"); swipe(.left)
        precondition(layouts == [.fourths] && !controller.isVisible)
        controller.showWindowManager(waitingForLift: false); key(46)
        precondition(commands == [.maximize] && !controller.isVisible)
        store.settings.appExplorer!.windowManager!.shortcuts[0].shortcut.modifiers = UInt64(NSEvent.ModifierFlags.command.rawValue)
        controller.showWindowManager(waitingForLift: false)
        let panel = NSApp.windows.first { $0.title == "App Explorer" && $0.isVisible }!
        let commandM = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46)!
        precondition(panel.performKeyEquivalent(with: commandM), "Recorded Command chords take precedence over app menu equivalents")
        precondition(commands == [.maximize, .maximize] && !controller.isVisible)
        store.settings.appExplorer!.windowManager!.shortcuts[0].shortcut.modifiers = 0
        fullScreen = true
        controller.showWindowManager(waitingForLift: false)
        precondition(controller.displayedEntries.count == 1 && controller.displayedEntries.first?.command == .exitFullScreen)
        try snapshot("window-fullscreen")
        key(46); key(16); swipe(.left)
        precondition(controller.isVisible && commands == [.maximize, .maximize] && tiled == 1, "Full screen blocks every layout and maximize command")
        precondition(!key(53), "Escape stays available to close the HUD")
        key(3)
        precondition(commands.last == .exitFullScreen && !controller.isVisible)
        controller.showWindowManager(waitingForLift: false); swipe(.up)
        precondition(commands.last == .exitFullScreen && !controller.isVisible)
        fullScreen = false

        var placements: [ExplorerWindowPlacement] = []
        controller.captureWindow = { _ in
            WindowTilingTarget(isFullScreen: { fullScreen }, command: { commands.append($0); return nil },
                apply: { direction, layout in placements.append(ExplorerWindowPlacement(direction: direction, layout: layout)); return nil })
        }
        let rightWide = ExplorerWindowPlacement(direction: .right, layout: .twoThirds)
        let topQuarter = ExplorerWindowPlacement(direction: .topLeft, layout: .halves)
        let wideTile = AppExplorerFavorite(direction: .up, name: "Right two thirds", windowPlacement: rightWide)
        let quarterTile = AppExplorerFavorite(direction: .left, name: "Top-left quarter", windowPlacement: topQuarter)
        let nestedWindows = AppExplorerFavorite(direction: .down, name: "More positions", children: [quarterTile], holdLayers: [
            ExplorerHoldLayer(name: "Wide", holdShortcut: y, favorites: [wideTile], windowTilesConfigured: true)
        ], slotCount: 4)
        store.settings.appExplorer = AppExplorerSettings(windowManager: ExplorerWindowSettings(favorites: [wideTile, nestedWindows,
            AppExplorerFavorite(direction: .right, name: "Fill desktop", action: .maximize)
        ], slotCount: 12))
        controller.showWindowManager(waitingForLift: false)
        precondition(controller.displayedEntries.first { $0.direction == .up }?.tilingDirection == .right)
        precondition(controller.displayedEntries.first { $0.direction == .up }?.tilingLayout == .twoThirds)
        try snapshot("window-custom-positions")
        swipe(.up)
        precondition(placements == [rightWide] && !controller.isVisible, "Swipe slot must not determine window position")
        controller.showWindowManager(waitingForLift: false); swipe(.down)
        precondition(controller.displayedEntries.first?.tilingDirection == .topLeft)
        key(16); precondition(controller.displayedEntries.first?.tilingLayout == .twoThirds)
        key(16, down: false); precondition(controller.displayedEntries.first?.tilingDirection == .topLeft)
        controller.goBack(); precondition(controller.isVisible && controller.displayedEntries.count == 3)
        swipe(.down); swipe(.left)
        precondition(placements.last == topQuarter && !controller.isVisible)
        controller.showWindowManager(waitingForLift: false); swipe(.right)
        precondition(commands.last == .maximize && !controller.isVisible)
        // Inline editing must keep the original captured window, not target Rota.
        controller.editingStore = store
        controller.showWindowManager(waitingForLift: false); swipe(.down)
        controller.beginEditing(); precondition(controller.isEditing)
        controller.finishEditing()
        precondition(controller.isVisible && !controller.isEditing && controller.displayedEntries.first?.tilingDirection == .topLeft)
        swipe(.left); precondition(placements.last == topQuarter && !controller.isVisible)
        // Tile-owned groups retain different slots than the shared applet.
        let localWindows = AppExplorerFavorite(direction: .left, name: "Custom windows", children: [quarterTile], action: .windowManager, slotCount: 4)
        store.settings.appExplorer!.favorites = [localWindows]
        controller.show(waitingForLift: false); swipe(.left)
        precondition(controller.displayedEntries.count == 1 && controller.displayedEntries.first?.tilingDirection == .topLeft)
        controller.goBack(); precondition(controller.displayedEntries.first?.isWindowManager == true)
        controller.dismiss()
        fullScreen = true
        controller.showWindowManager(waitingForLift: false)
        precondition(controller.displayedEntries.count == 1 && controller.displayedEntries.first?.command == .exitFullScreen)
        controller.beginEditing(); precondition(!controller.isEditing)
        swipe(.up); precondition(commands.last == .exitFullScreen)
        fullScreen = false
        print("Custom window groups passed: independent swipe/placement, mixed sizes, 12 slots, nested groups, scoped layers/back, command tiles, local groups, inline editing and fullscreen protection")

        var selectedWindows: [Int] = []
        controller.listWindows = { _ in (0..<20).map { index in
            WindowTiling.AppWindow(title: "Document \(index + 1)", minimized: index == 19, activate: { selectedWindows.append(index); return nil })
        } }
        store.settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: "App windows", action: .appWindows)])
        controller.show(waitingForLift: false); swipe(.up)
        precondition(controller.displayedEntries.count == 16)
        key(124)
        precondition(controller.displayedEntries.count == 4 && controller.displayedEntries.last?.name.contains("minimized") == true)
        try snapshot("app-windows-page-2")
        swipe(ExplorerSlot.slots(16)[3])
        let selectionDeadline = Date().addingTimeInterval(2)
        while selectedWindows.isEmpty && Date() < selectionDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(selectedWindows == [19] && !controller.isVisible, "Window selection: \(selectedWindows), visible: \(controller.isVisible)")
        controller.show(waitingForLift: false); swipe(.up); controller.goBack()
        precondition(controller.displayedEntries.first?.command == .appWindows)
        controller.dismiss()
        for command in [AppExplorerAction.closeWindow, .minimize] {
            store.settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: command.title, action: command)])
            controller.show(waitingForLift: false); swipe(.up)
            precondition(commands.last == command && !controller.isVisible)
        }
        var macCommands: [AppExplorerAction] = []
        controller.performMacCommand = { macCommands.append($0) }
        for command in [AppExplorerAction.missionControl, .previousDesktop, .nextDesktop, .showDesktop] {
            store.settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .up, name: command.title, action: command)])
            controller.show(waitingForLift: false); swipe(.up)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(macCommands.last == command && !controller.isVisible)
        }
        print("Explorer applets UI passed: every 4/8/12/16 slot, group toggle/repeat/back, Window Manager fourths and maximize, fullscreen exit-only safety, paged window activation, window commands, and macOS desktop command dispatch. No real windows modified.")
    }
}
