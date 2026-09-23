import AppKit
import SwiftUI

@MainActor private final class LayerActionUIState: ObservableObject {
    @Published var gestures: ProfileGestures
    @Published var globalBindings: [ActionBinding] = []

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
        LayerActionAssignmentsEditor(gestures: $state.gestures,
            globalBindings: $state.globalBindings, resolveGestures: { base in
                var settings = StoredSettings()
                settings.actionBindings = state.globalBindings
                return settings.applyingActionBindings(to: base)
            })
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

        state.gestures.gestures.tapToClick = false
        let disabledBase = state.gestures
        let globalTap = ActionBinding(trigger: BindingTrigger(gesture: .oneFingerTap), action: .tap(.rightClick))
        let globalSwipe = ActionBinding(trigger: BindingTrigger(gesture: .twoFingerLeft), action: .tap(.windowManager))
        state.globalBindings = [globalTap, globalSwipe]
        let ownerEditor = LayerActionAssignmentsEditor(
            gestures: Binding(get: { state.gestures }, set: { state.gestures = $0 }),
            globalBindings: Binding(get: { state.globalBindings }, set: { state.globalBindings = $0 }),
            resolveGestures: { base in
                var settings = StoredSettings()
                settings.actionBindings = state.globalBindings
                return settings.applyingActionBindings(to: base)
            })
        let globalHost = NSHostingView(rootView: LayerActionUIFixture(state: state, layer: layer, macro: macro))
        let globalPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        globalPanel.isReleasedWhenClosed = false
        globalPanel.contentView = globalHost
        globalPanel.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        try snapshot(globalHost, "layer-action-global-overrides")
        var changed = globalTap
        changed.action = .tap(.doubleLeftClick)
        ownerEditor.saveGlobalDraft(changed)
        precondition(state.globalBindings.first?.action == changed.action && state.gestures == disabledBase,
            "Editing a global row must not rewrite disabled profile taps")
        ownerEditor.removeGlobalBinding(id: globalSwipe.id)
        precondition(state.globalBindings.count == 1 && state.gestures == disabledBase,
            "Removing a global swipe must reveal the underlying layer without changing it")
        globalPanel.orderOut(nil); globalPanel.close()
        print("Layer action UI passed: compact rows, shared catalog, disabled-base global rows, and owner-only edit/remove.")
    }
}
