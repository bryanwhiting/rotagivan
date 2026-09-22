import AppKit
import SwiftUI

@main struct ExplorerActionMenuUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.ActionMenuUISmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rotagivan.v1")
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        store.settings.appExplorer = AppExplorerSettings(favorites: [])
        let host = NSHostingView(rootView: AppExplorerSettingsView(store: store, compact: true)
            .frame(width: 760, height: 760, alignment: .topLeading))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSPopUpButton] {
            let own = (view as? NSPopUpButton).map { [$0] } ?? []
            return own + view.subviews.flatMap(buttons)
        }
        let popups = buttons(host)
        // SwiftUI lazily materializes menu items when the native button opens.
        let slot = popups.last { $0.menu?.items.isEmpty == true }!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { slot.menu?.cancelTracking() }
        slot.performClick(nil)
        let candidates = popups.compactMap(\.menu)
        candidates.forEach { $0.update() }
        guard let menu = candidates.first(where: { $0.items.contains { $0.title == "Keybindings and Macros" } }) else {
            print("Native menu titles:", candidates.map { $0.items.map(\.title) })
            fatalError("Tile actions must be backed by a native macOS menu")
        }
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        for title in ["Keybindings and Macros", "App launches", "Built-in HUD layers", "Create HUD layer…", "Window management", "Mac commands", "Media controls"] {
            precondition(titles.contains(title), "Missing action category: \(title)")
        }
        func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
            let result = menu.items.first { $0.title == title }!.submenu!
            result.update()
            return result
        }
        let windows = submenu("Window management", in: menu)
        let macCommands = submenu("Mac commands", in: menu)
        let reserved = submenu("Built-in HUD layers", in: menu)
        precondition(reserved.items.map(\.title) == ExplorerReservedGroup.allCases.map(\.title))
        let resize = submenu("Resize window", in: windows)
        precondition(resize.items.contains { $0.title == "Fill desktop" })
        for layout in ExplorerWindowLayout.allCases {
            let positions = submenu(layout.title, in: resize)
            precondition(positions.items.filter { !$0.isSeparatorItem }.count == SwipeDirection.allCases.count)
        }
        let fullScreen = submenu("Full screen", in: windows)
        precondition(fullScreen.items.contains { $0.title == "Toggle full screen" })
        precondition(fullScreen.items.contains { $0.title == "Exit full screen" })
        for action in [AppExplorerAction.minimize, .closeWindow] {
            precondition(windows.items.contains { $0.title == action.title })
        }
        precondition(macCommands.items.filter { !$0.isSeparatorItem }.map(\.title) == AppExplorerAction.macOSCommands.map(\.title))
        macCommands.performActionForItem(at: macCommands.items.firstIndex { $0.title == "Mission Control" }!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(store.settings.appExplorer?.favorites.first?.action == .missionControl)
        precondition(submenu("App launches", in: menu).items.contains { $0.title == "Open URL…" })
        precondition(submenu("Keybindings and Macros", in: menu).items.contains { $0.title == "Assign macro or keystroke…" })
        // Selecting a menu entry configures a tile; it must not act on a real window.
        let minimizeIndex = windows.items.firstIndex { $0.title == "Minimize window" }!
        windows.performActionForItem(at: minimizeIndex)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(store.settings.appExplorer?.favorites.count == 1)
        precondition(store.settings.appExplorer?.favorites.first?.action == .minimize)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { slot.menu?.cancelTracking() }
        slot.performClick(nil)
        let refreshed = submenu("Built-in HUD layers", in: slot.menu!)
        refreshed.performActionForItem(at: refreshed.items.firstIndex { $0.title == "Actions" }!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let actions = store.settings.appExplorer!.favorites.first!
        precondition(actions.name == "Actions" && actions.children?.count == 8)
        precondition(actions.children?.first { $0.name == "Copy" }?.shortcut?.keyCode == 8)
        print("Native action menus passed: built-in HUD layer assignment, all 32 resize placements, full-screen/window and Mac commands, URL/keybinding choices, and assignment without executing the action.")
    }
}
