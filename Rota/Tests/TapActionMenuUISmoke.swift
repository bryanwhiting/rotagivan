import AppKit
import SwiftUI

@MainActor private final class ActionState: ObservableObject {
    @Published var action: TapAction = .leftClick
    @Published var shortcut: RecordedShortcut?
}

private struct ActionFixture: View {
    @ObservedObject var state: ActionState
    let layer: ExplorerHoldLayer
    var keyboardOnly = false
    var physicalKeysOnly = false
    var body: some View {
        TapActionEditor(title: "One-finger tap", action: $state.action, shortcut: $state.shortcut,
            keyboardOnly: keyboardOnly, physicalKeysOnly: physicalKeysOnly)
            .environment(\.hudActionLayers, [layer])
            .padding(16).frame(width: 322)
    }
}

@main struct TapActionMenuUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let layer = ExplorerHoldLayer.empty(name: "Tools")
        for mode in 0..<3 {
            let state = ActionState()
            let host = NSHostingView(rootView: ActionFixture(state: state, layer: layer,
                keyboardOnly: mode == 1, physicalKeysOnly: mode == 2))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 322, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = host; panel.makeKeyAndOrderFront(nil)
            defer { panel.orderOut(nil); panel.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            func buttons(_ view: NSView) -> [NSPopUpButton] {
                ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
            }
            let menus = buttons(host)
            precondition(menus.count == 1, "HUD layer must be inside the single action menu")
            let button = menus[0]
            precondition(button.bounds.width >= 28, "Action menu must have room for an unsquashed chevron: \(button.bounds)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { button.menu?.cancelTracking() }
            button.performClick(nil)
            let menu = button.menu!; menu.update()
            let hud = menu.items.first { $0.title == "HUD layer" }?.submenu
            if mode == 2 {
                precondition(hud == nil, "Physical-key recorders must not offer HUD actions")
            } else {
                precondition(hud != nil)
                hud!.update()
                precondition(hud!.items.contains { $0.title == "Favorites" } == (mode == 0))
                hud!.performActionForItem(at: hud!.items.firstIndex { $0.title == "Tools" }!)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                precondition(state.action == .shortcut && state.shortcut?.hudLayerID == layer.id)
            }
            if mode == 0 {
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            }
        }
        print("Tap action menu passed: one dropdown, HUD-layer assignment, adequate chevron width, keyboard/physical-only restrictions.")
    }
}
