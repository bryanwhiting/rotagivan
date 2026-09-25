import AppKit
import SwiftUI

@MainActor private final class PreviewState: ObservableObject {
    @Published var settings = AppExplorerSettings()
    @Published var selectedLayerID: UUID?
    @Published var selection: ExplorerSlot = .up
    @Published var groupPath: [ExplorerSlot] = []
    @Published var editing: ExplorerSlot?
    @Published var editingEnabled = false
    var editorAppeared: ExplorerSlot?
    var drag: ExplorerSlotDrag?
    var drops = 0
}

private struct PreviewFixture: View {
    @ObservedObject var state: PreviewState
    var body: some View {
        ExplorerHUDSettingsPreview(settings: state.settings.projected(layerID: state.selectedLayerID), theme: state.settings.resolvedTheme, dictionary: [], groupPath: state.groupPath,
            layerName: state.settings.holdLayers?.first { $0.id == state.selectedLayerID }?.name, rootSettings: state.settings, selectedLayerID: state.selectedLayerID, onSelectLayer: { state.selectedLayerID = $0; state.groupPath = []; state.editing = nil }, selection: $state.selection, onBack: { if !state.groupPath.isEmpty { state.groupPath.removeLast() } }, onDrag: { source, _ in
                if state.drag == nil { state.drag = ExplorerSlotDrag(source: source, path: state.groupPath, settings: state.settings) }
            }, onDrop: { _, target in
                defer { state.drag = nil }
                guard let drag = state.drag, let target else { return }
                var next = state.settings
                if drag.apply(to: target, in: state.groupPath, settings: &next) { state.settings = next; state.selection = target; state.drops += 1 }
            }, editingTile: $state.editing, editor: state.editingEnabled ? { slot in
                AnyView(ExplorerDestinationPicker(direction: slot, onSave: { favorite, _ in
                    state.settings.setFavorite(favorite, at: slot, in: state.groupPath)
                    state.editing = nil
                }, onCancel: { state.editing = nil }, loadApplications: {
                    [ExplorerApplication(bundleID: "test.editor", name: "Test Editor",
                        url: URL(fileURLWithPath: "/Applications/Test Editor.app"))]
                })
                    .onAppear { state.editorAppeared = slot })
            } : nil)
    }
}

@main struct HUDLayoutPreviewUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let state = PreviewState()
        state.settings = AppExplorerSettings(favorites: [
            AppExplorerFavorite(direction: .left, name: "Copy", shortcut: RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")),
            AppExplorerFavorite(direction: .right, name: "Paste", shortcut: RecordedShortcut(keyCode: 9, modifiers: 1 << 20, keyLabel: "V")),
            ExplorerReservedGroup.actions.tile(at: .up)
        ], theme: .starburstAir)
        let host = NSHostingView(rootView: PreviewFixture(state: state))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host; panel.center()
        panel.makeKeyAndOrderFront(nil); NSApp.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func snapshot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name + ".png"))
        }
        func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, fullLayout: Bool = false) {
            let x = x + (fullLayout ? 0 : (host.bounds.width - 470) / 2)
            let y = y + (fullLayout ? 0 : (host.bounds.height - 520) / 2)
            let point = host.convert(NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            panel.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        try snapshot("hud-preview-before")
        // Label centers in the shared fixed-size HUD (470 × 520).
        send(.leftMouseDown, x: 119, y: 220); send(.leftMouseUp, x: 119, y: 220)
        precondition(state.selection == .left, "Preview clicks select tiles without sending their shortcuts")
        send(.leftMouseDown, x: 119, y: 220)
        for i in 1...10 { send(.leftMouseDragged, x: 119 + CGFloat(i) * 23.2, y: 220) }
        send(.leftMouseUp, x: 351, y: 220)
        precondition(state.drops == 1 && state.settings.favorite(at: [.right])?.name == "Copy" && state.settings.favorite(at: [.left])?.name == "Paste", "Dragging actual HUD tiles must swap their saved destinations")
        let saved = state.settings
        send(.leftMouseDown, x: 119, y: 220)
        send(.leftMouseDragged, x: 160, y: 220); send(.leftMouseDragged, x: 235, y: 220)
        send(.leftMouseUp, x: 235, y: 220)
        precondition(state.settings == saved && state.drops == 1, "Dropping into the center must not move tiles")
        send(.leftMouseDown, x: 235, y: 336); send(.leftMouseUp, x: 235, y: 336)
        precondition(state.selection == .down, "Empty slots must be selectable for assignment")
        state.groupPath = [.up]
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try snapshot("hud-preview-nested-actions")
        send(.leftMouseDown, x: 235, y: 220); send(.leftMouseUp, x: 235, y: 220)
        precondition(state.groupPath.isEmpty, "The preview center must navigate back through groups")
        for theme in ExplorerTheme.allCases {
            state.settings.theme = theme
            for count in [4, 8, 12, 16] {
                state.settings.slotCount = count
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                try snapshot("hud-preview-\(theme.rawValue)-\(count)")
            }
        }
        state.editingEnabled = true
        state.settings.slotCount = 8
        for theme in ExplorerTheme.allCases {
            state.settings.theme = theme
            state.editorAppeared = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            send(.leftMouseDown, x: 119, y: 220); send(.leftMouseUp, x: 119, y: 220)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            precondition(state.editing == .left && state.editorAppeared == .left,
                         "Clicking a tile must present its app picker in a native popover for \(theme)")
            guard let popover = NSApp.windows.first(where: { $0 !== panel && $0.isVisible && $0.contentView != nil }),
                  let content = popover.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                preconditionFailure("The app picker must be a visible native popover, not an inspector below the preview")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                CommandLine.arguments[1] + "/hud-tile-popover-\(theme.rawValue).png"))
            let leftFrame = popover.frame
            state.editing = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            state.editorAppeared = nil
            send(.leftMouseDown, x: 351, y: 220); send(.leftMouseUp, x: 351, y: 220)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            precondition(state.editing == .right && state.editorAppeared == .right)
            let rightFrame = NSApp.windows.first { $0 !== panel && $0.isVisible && $0.contentView != nil }!.frame
            precondition(panel.screen?.visibleFrame.contains(panel.frame.insetBy(dx: -400, dy: 0)) != true || rightFrame.midX > leftFrame.midX + 80,
                         "When screen space permits, the popover must follow its tile; AppKit may clamp it at screen edges")
            state.editing = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        // Real mouse events on satellite HUDs must select the saved layer,
        // not execute its tiles or open a tile editor before selection.
        state.settings.theme = .starburstAir
        let layer = ExplorerHoldLayer(name: "Other HUD", position: .right, holdShortcut: nil,
            favorites: [AppExplorerFavorite(direction: .up, name: "Lock", action: .lockScreen)])
        state.settings.holdLayers = [layer]
        panel.setContentSize(NSSize(width: 950, height: 850))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let right = HUDMapProjection(x: 1, y: 0)
        send(.leftMouseDown, x: 475 + right.offsetX, y: 425 - 38 + right.offsetY, fullLayout: true)
        send(.leftMouseUp, x: 475 + right.offsetX, y: 425 - 38 + right.offsetY, fullLayout: true)
        precondition(state.selectedLayerID == layer.id && state.editing == nil,
            "Clicking a satellite selects that HUD without executing or editing its tiles")
        try snapshot("hud-preview-selected-layer")
        let left = HUDMapProjection(x: -1, y: 0)
        send(.leftMouseDown, x: 475 + left.offsetX, y: 425 - 38 + left.offsetY, fullLayout: true)
        send(.leftMouseUp, x: 475 + left.offsetX, y: 425 - 38 + left.offsetY, fullLayout: true)
        precondition(state.selectedLayerID == nil, "The Main HUD is selectable from another layer")
        try snapshot("hud-preview-main-return")
        panel.orderOut(nil); panel.close()
        let suite = "Rotagivan.VisualHUDSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        store.settings.appExplorer = state.settings
        let savedSettings = store.settings.appExplorer
        let settingsHost = NSHostingView(rootView: AppExplorerSettingsView(store: store).padding())
        let settingsPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1080),
            styleMask: [.titled], backing: .buffered, defer: false)
        settingsPanel.isReleasedWhenClosed = false; settingsPanel.contentView = settingsHost
        settingsPanel.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        settingsHost.layoutSubtreeIfNeeded()
        let bitmap = settingsHost.bitmapImageRepForCachingDisplay(in: settingsHost.bounds)!
        settingsHost.cacheDisplay(in: settingsHost.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
            CommandLine.arguments[1] + "/hud-unified-settings.png"))
        precondition(store.settings.appExplorer == savedSettings, "Browsing the visual editor must preserve settings")
        settingsPanel.orderOut(nil); settingsPanel.close()
        print("HUD preview UI passed: inert selection, native drag-to-swap, tile-anchored app-picker popovers in every theme, shared rendering for 4/8/12/16 slots. No actions executed.")
    }
}
