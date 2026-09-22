import AppKit
import SwiftUI

@MainActor private final class LayerActionUIState: ObservableObject {
    @Published var gestures: ProfileGestures

    init() {
        var value = ProfileGestures(
            gestures: GestureSettings(tapToClick: true),
            oneFingerTap: .leftClick,
            twoFingerTap: .enter
        )
        value.oneFingerDoubleTap = .appExplorer
        value.singleTapSwipe = .singleTapDefaults
        value.singleTapSwipe?.enabled = true
        value.singleTapSwipe?[.right] = RecordedShortcut(
            keyCode: 8, modifiers: 1 << 20, keyLabel: "C"
        )
        gestures = value
    }
}

private struct LayerActionUIFixture: View {
    @ObservedObject var state: LayerActionUIState
    let layer: ExplorerHoldLayer
    let macro: NamedHotkey

    var body: some View {
        LayerActionAssignmentsEditor(gestures: $state.gestures)
            .environment(\.hudActionLayers, [layer])
            .environment(\.hotkeyDictionary, [macro])
            .padding(20)
            .frame(width: 650, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main struct LayerActionAssignmentsUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let state = LayerActionUIState()
        let before = state.gestures
        let layer = ExplorerHoldLayer.empty(name: "Research")
        let shortcut = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
        let macro = NamedHotkey(name: "Copy selection", shortcut: shortcut)
        let host = NSHostingView(rootView: LayerActionUIFixture(state: state, layer: layer, macro: macro))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        func snapshot(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name + ".png")
            )
        }
        func menus(in view: NSView) -> [NSPopUpButton] {
            ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(menus)
        }

        try snapshot(host, "layer-action-assignments")
        precondition(state.gestures == before, "Rendering the assignment list must not rewrite migrated settings")
        precondition(menus(in: host).count >= 4, "Every visible assignment needs one compact action menu")
        panel.orderOut(nil)
        panel.close()

        let addHost = NSHostingView(rootView: AddLayerActionSheet(
            existing: [.oneFingerTap],
            onSave: { _, _, _ in },
            onCancel: {}
        )
            .environment(\.hudActionLayers, [layer])
            .environment(\.hotkeyDictionary, [macro]))
        let addPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        addPanel.isReleasedWhenClosed = false
        addPanel.contentView = addHost
        addPanel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        try snapshot(addHost, "layer-action-add-sheet")
        precondition(menus(in: addHost).count >= 3, "The add sheet needs separate tap, optional swipe, and action controls")
        addPanel.orderOut(nil)
        addPanel.close()
        print("Layer action UI passed: compact key-value rows, one action menu per row, and three-step tap / optional swipe / action sheet.")
    }
}
