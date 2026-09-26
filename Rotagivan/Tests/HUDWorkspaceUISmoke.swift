import AppKit
import SwiftUI

@MainActor private final class WorkspaceViewportGeometry {
    var rect: CGRect?
    var canvasCount = 0
}

private struct WorkspaceViewportProbe: ViewModifier {
    let geometry: WorkspaceViewportGeometry
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(HUDWorkspaceViewportAnchors.self) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors.last {
                    let rect = proxy[anchor]
                    Color.clear.allowsHitTesting(false)
                        .onAppear { geometry.rect = rect; geometry.canvasCount = anchors.count }
                        .onChange(of: rect) { _, value in geometry.rect = value }
                        .onChange(of: anchors.count) { _, count in geometry.canvasCount = count }
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

@main struct HUDWorkspaceUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let suite = "Rotagivan.HUDWorkspace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        func tiles(_ prefix: String) -> [AppExplorerFavorite] {
            let key = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
            return [AppExplorerFavorite(direction: .left, name: prefix + " Left", shortcut: key),
                AppExplorerFavorite(direction: .right, name: prefix + " Right", shortcut: key),
                AppExplorerFavorite(direction: .up, name: prefix + " Group", children: [
                    AppExplorerFavorite(direction: .left, name: prefix + " Nested left", shortcut: key),
                    AppExplorerFavorite(direction: .right, name: prefix + " Nested right", shortcut: key)]),
                AppExplorerFavorite(direction: .down, name: prefix + " Down", shortcut: key)]
        }
        var layers = HUDLayerPosition.allCases.enumerated().map { index, position in
            ExplorerHoldLayer(name: "Layer \(index)", position: position, holdShortcut: nil, favorites: tiles("Layer \(index)"))
        }
        let overflow = ExplorerHoldLayer(name: "Legacy overflow", holdShortcut: nil, favorites: tiles("Overflow"))
        layers.append(overflow)
        store.settings.appExplorer = AppExplorerSettings(favorites: tiles("Main"), holdLayers: layers,
            theme: .starburstAir, animationsEnabled: false,
            windowManager: ExplorerWindowSettings(favorites: [
                AppExplorerFavorite(direction: .left, name: "Window left", windowPlacement: ExplorerWindowPlacement(direction: .left)),
                AppExplorerFavorite(direction: .right, name: "Window right", windowPlacement: ExplorerWindowPlacement(direction: .right))]))
        precondition(store.settings.appExplorer!.hasValidFavorites)
        let hid = NavigatorHIDManager(store: store)
        let vault = CredentialVault(server: "https://fixture.test", transport: { _ in fatalError("No network") },
            read: { _, _ in fatalError("HUD browsing must not read credentials") }, write: { _, _, _ in fatalError("No credential writes") })
        let sync = SettingsSync(store: store, hid: hid, defaults: defaults, server: "https://fixture.test",
            credentials: SyncCredentials(read: { _ in fatalError("HUD browsing must not start sync") },
                save: { _, _ in fatalError("No credential writes") }, remove: { _ in fatalError("No credential deletes") }), vault: vault,
            transport: { _ in fatalError("No network") })
        let viewportGeometry = WorkspaceViewportGeometry()
        let host = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync, initialSection: "HUD")
            .modifier(WorkspaceViewportProbe(geometry: viewportGeometry))
            .defaultAppStorage(defaults).environment(\.colorScheme, .dark))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 740),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate()
        defer { panel.orderOut(nil); panel.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.22)); host.layoutSubtreeIfNeeded() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func elements(_ object: Any) -> [AnyObject] {
            let element = object as AnyObject
            return [element] + (element.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func all(_ root: NSView) -> [AnyObject] { views(root).flatMap(elements) }
        func find(_ id: String, in root: NSView? = nil) -> AnyObject {
            guard let element = all(root ?? host).first(where: { $0.accessibilityIdentifier?() == id }) else {
                preconditionFailure("Missing native workspace control \(id)")
            }
            return element
        }
        func button(_ label: String, in root: NSView? = nil) -> AnyObject {
            guard let element = all(root ?? host).first(where: { $0.accessibilityRole?() == .button && $0.accessibilityLabel?() == label }) else {
                preconditionFailure("Missing native button \(label)")
            }
            return element
        }
        func frame(_ element: AnyObject) -> NSRect {
            guard let rect = element.accessibilityFrame?(), rect.width > 0, rect.height > 0 else {
                preconditionFailure("Native geometry must belong to a visible rendered element")
            }
            return rect
        }
        func press(_ id: String, in root: NSView? = nil) {
            precondition(find(id, in: root).accessibilityPerformPress?() == true); settle()
        }
        func capture(_ name: String, root: NSView? = nil) throws {
            guard CommandLine.arguments.count > 1 else { return }
            let root = root ?? host
            root.layoutSubtreeIfNeeded()
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
        }
        func tile(_ direction: ExplorerSlot, name: String) -> AnyObject {
            button(direction.title + ": " + name)
        }
        func geometry(_ prefix: String, size: NSSize) {
            precondition(viewportGeometry.canvasCount == 1, "The workspace must have one actual editing canvas")
            precondition(abs(host.bounds.width - size.width) < 1 && abs(host.bounds.height - size.height) < 1,
                "Actual ContentView must adopt the requested viewport")
            guard let viewport = viewportGeometry.rect else { preconditionFailure("Actual canvas must publish its bounds anchor") }
            let workspace = panel.convertToScreen(host.convert(viewport, to: nil))
            let left = frame(tile(.left, name: prefix + " Left")), right = frame(tile(.right, name: prefix + " Right"))
            let up = frame(tile(.up, name: prefix + " Group")), down = frame(tile(.down, name: prefix + " Down"))
            // Derive the selected wheel center from its actual rendered tile
            // buttons, not an invisible marker or the outer orbit canvas.
            let center = NSPoint(x: (left.midX + right.midX) / 2, y: (up.midY + down.midY) / 2)
            precondition(abs(center.x - workspace.midX) <= 2 && abs(center.y - workspace.midY) <= 2,
                "Rendered selected wheel must center in the visible HUD workspace: \(center) vs \(workspace)")
            precondition([left, right, up, down].allSatisfy { workspace.insetBy(dx: -2, dy: -2).contains($0) },
                "Every cardinal tile must remain completely inside the visible canvas")
            let visible = panel.convertToScreen(host.convert(host.bounds, to: nil))
            precondition(visible.insetBy(dx: -2, dy: -2).contains(workspace), "Workspace must be visible in the real settings page: \(workspace) vs \(visible)")
        }
        func send(_ type: NSEvent.EventType, screen: NSPoint) {
            let location = panel.convertPoint(fromScreen: screen)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            panel.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        func hitPoint(_ element: AnyObject, direction: ExplorerSlot) -> NSPoint {
            let rect = frame(element)
            // A starburst Button's AX frame covers the entire sector canvas;
            // its hit shape occupies only its wedge. Use the renderer's label
            // radius, converting hardware-downward Y to screen-upward Y.
            let scale = rect.width / 418
            let local = ExplorerStarburstLayout.point(direction, radius: 116 * scale,
                center: CGPoint(x: rect.midX, y: -rect.midY))
            return NSPoint(x: local.x, y: -local.y)
        }
        func drag(_ source: AnyObject, to target: AnyObject) {
            let a = frame(source), b = frame(target)
            precondition(a.width > 0 && b.width > 0)
            let start = hitPoint(source, direction: .left), end = hitPoint(target, direction: .right)
            send(.leftMouseDown, screen: start)
            for step in 1...12 {
                let fraction = CGFloat(step) / 12
                send(.leftMouseDragged, screen: NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction))
            }
            send(.leftMouseUp, screen: end); settle()
        }
        func closePopover() {
            if let popover = NSApp.windows.first(where: { $0 !== panel && $0 !== panel.attachedSheet && $0.isVisible }) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: popover.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                popover.sendEvent(event); settle()
            }
        }
        settle()
        var baseline = store.settings.appExplorer!
        // Vacant map cells are actual, clickable circles, not decorative hints.
        var sparse = baseline
        sparse.holdLayers = layers.filter { layer in
            layer.position.map { [.left, .right, .top, .bottom].contains($0) } ?? false
        }
        store.settings.appExplorer = sparse; settle()
        try capture("hud-workspace-empty-circles")
        let corners: [HUDLayerPosition] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for position in corners {
            let circle = frame(find("hud-add-position-" + position.rawValue))
            let viewport = panel.convertToScreen(host.convert(viewportGeometry.rect!, to: nil))
            precondition(viewport.contains(circle), "Empty corner circles must not be clipped by the canvas")
        }
        precondition(!all(host).contains { $0.accessibilityIdentifier?() == "hud-add-position-right" },
            "Occupied positions must not show add circles")
        try capture("hud-workspace-empty-circles")
        let target = frame(find("hud-add-position-topLeft"))
        send(.leftMouseDown, screen: NSPoint(x: target.midX, y: target.midY))
        send(.leftMouseUp, screen: NSPoint(x: target.midX, y: target.midY)); settle()
        guard let added = store.settings.appExplorer?.holdLayers?.first(where: { $0.position == .topLeft }) else {
            preconditionFailure("Clicking the top-left circle must create a HUD at that position")
        }
        precondition(added.favorites.isEmpty && added.builtIn == nil)
        let selectedButton = find("hud-layer-button-" + added.id.uuidString) as? NSObject
        let selectedValue = selectedButton?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String
        precondition(selectedValue == "Selected",
            "New HUD must become the selected editable layer")
        precondition(!all(host).contains { $0.accessibilityIdentifier?() == "hud-add-position-topLeft" })
        precondition(sparse.holdLayers!.allSatisfy { existing in
            store.settings.appExplorer!.holdLayers!.contains(existing)
        }, "Adding a HUD must preserve every existing layer")
        try capture("hud-workspace-added-corner")
        press("hud-layer-button-main")
        for position in corners.dropFirst() { press("hud-add-position-" + position.rawValue); press("hud-layer-button-main") }
        precondition(!all(host).contains { ($0.accessibilityIdentifier?() ?? "").hasPrefix("hud-add-position-") },
            "No add circles remain when all eight positions are occupied")
        var vacant = baseline; vacant.holdLayers = []
        store.settings.appExplorer = vacant
        panel.setContentSize(NSSize(width: 860, height: 680)); settle()
        try capture("hud-workspace-all-empty-min")
        for position in HUDLayerPosition.allCases {
            let circle = frame(find("hud-add-position-" + position.rawValue))
            let viewport = panel.convertToScreen(host.convert(viewportGeometry.rect!, to: nil))
            precondition(viewport.contains(circle), "Every adjacent add circle must fit the minimum viewport")
            send(.leftMouseDown, screen: NSPoint(x: circle.midX, y: circle.midY))
            send(.leftMouseUp, screen: NSPoint(x: circle.midX, y: circle.midY)); settle()
            precondition(store.settings.appExplorer!.resolvedHUDPositions.values.contains(position),
                "Every empty map position must support an actual mouse click")
            press("hud-layer-button-main")
        }
        store.settings.appExplorer = baseline; settle()
        // Capture the supported minimum before assertions, including the extra
        // Window Manager toolbar, so a failure still leaves useful visual evidence.
        panel.setContentSize(NSSize(width: 860, height: 680)); settle()
        try capture("hud-workspace-min-main")
        let captureWindowLayer = ExplorerHoldLayer(builtIn: .windowManager, name: "Window HUD", position: .right, holdShortcut: nil)
        var captureSettings = baseline
        captureSettings.holdLayers![1] = captureWindowLayer
        store.settings.appExplorer = captureSettings; settle()
        press("hud-layer-button-" + captureWindowLayer.id.uuidString)
        try capture("hud-workspace-min-window-manager")
        for theme in ExplorerTheme.allCases {
            store.settings.appExplorer!.theme = theme; settle()
            try capture("hud-workspace-min-window-manager-" + theme.rawValue)
        }
        store.settings.appExplorer = baseline; settle()
        press("hud-layer-button-main")
        for size in [NSSize(width: 940, height: 740), NSSize(width: 860, height: 680), NSSize(width: 1240, height: 900)] {
            panel.setContentSize(size); settle()
            try capture("hud-workspace-initial-\(Int(size.width))-\(Int(size.height))")
            press("hud-layer-button-main")
            geometry("Main", size: size)
            for (index, layer) in layers.enumerated() {
                press("hud-layer-button-" + layer.id.uuidString)
                geometry(index == 8 ? "Overflow" : "Layer \(index)", size: size)
            }
            precondition(store.settings.appExplorer == baseline, "Selecting every mapped/legacy HUD must not mutate settings")
            try capture("hud-workspace-\(Int(size.width))-\(Int(size.height))")
        }
        panel.setContentSize(NSSize(width: 940, height: 740)); settle()
        let selected = layers[0]
        press("hud-layer-button-" + selected.id.uuidString)
        press("hud-visual-actions")
        guard let settingsSheet = panel.attachedSheet, let settingsRoot = settingsSheet.contentView else {
            preconditionFailure("Selected HUD settings must open a native editor sheet")
        }
        guard let nameField = views(settingsRoot).compactMap({ $0 as? NSTextField })
            .first(where: { $0.isEditable && $0.placeholderString == "HUD layer name" }) else { preconditionFailure("HUD editor needs its selected layer name") }
        precondition(nameField.stringValue == selected.name, "Direct edit must target the selected HUD")
        nameField.selectText(nil)
        let textEditor = settingsSheet.firstResponder as! NSTextView
        textEditor.insertText("Renamed layer zero", replacementRange: NSRange(location: 0, length: (textEditor.string as NSString).length))
        settingsSheet.makeFirstResponder(nil); settle()
        precondition(button("Save", in: settingsRoot).accessibilityPerformPress?() == true); settle()
        baseline.holdLayers![0].name = "Renamed layer zero"
        precondition(store.settings.appExplorer == baseline, "Native direct HUD settings save must change only its selected layer")
        drag(tile(.left, name: "Layer 0 Left"), to: tile(.right, name: "Layer 0 Right"))
        var afterDrag = store.settings.appExplorer!
        let edited = afterDrag.holdLayers!.first { $0.id == selected.id }!
        precondition(edited.favorites.first { $0.direction == .right }?.name == "Layer 0 Left" &&
            edited.favorites.first { $0.direction == .left }?.name == "Layer 0 Right")
        afterDrag.holdLayers = baseline.holdLayers
        precondition(afterDrag == baseline, "Native drag must edit only the selected HUD layer")
        precondition(tile(.up, name: "Layer 0 Group").accessibilityPerformPress?() == true); settle()
        guard let popover = NSApp.windows.first(where: { $0 !== panel && $0.isVisible }), let popupRoot = popover.contentView else {
            preconditionFailure("Actual workspace tile must open a native popover")
        }
        precondition(button("Edit HUD layer…", in: popupRoot).accessibilityPerformPress?() == true); settle()
        let nestedBefore = store.settings.appExplorer!
        drag(tile(.left, name: "Layer 0 Nested left"), to: tile(.right, name: "Layer 0 Nested right"))
        let nestedAfter = store.settings.appExplorer!
        let nestedLayer = nestedAfter.holdLayers!.first { $0.id == selected.id }!
        precondition(nestedLayer.favorites.first { $0.direction == .up }?.children?.first { $0.direction == .right }?.name == "Layer 0 Nested left")
        var expected = nestedBefore
        var expectedLayer = expected.holdLayers!.first { $0.id == selected.id }!
        var projected = AppExplorerSettings(favorites: expectedLayer.favorites)
        precondition(projected.swapFavorites(from: .left, to: .right, in: [.up]))
        expectedLayer.favorites = projected.favorites
        expected.holdLayers![0] = expectedLayer
        precondition(nestedAfter == expected, "Nested routed drop must preserve every unrelated layer and root path")
        press("hud-layer-button-main")
        let beforeDefaultTaps = store.settings.appExplorer
        press("hud-default-taps")
        guard let tapSheet = panel.attachedSheet, let tapRoot = tapSheet.contentView else { preconditionFailure("Default tap actions need a native sheet") }
        _ = find("default-tap-settings", in: tapRoot)
        try capture("hud-default-taps-sheet", root: tapRoot)
        precondition(button("Done", in: tapRoot).accessibilityPerformPress?() == true); settle()
        precondition(panel.attachedSheet == nil, "Native dismissal must release the sheet and mouse responder state")
        precondition(store.settings.appExplorer == beforeDefaultTaps)
        let windowLayer = ExplorerHoldLayer(builtIn: .windowManager, name: "Window HUD", position: .right, holdShortcut: nil)
        var beforeWindow = store.settings.appExplorer!
        beforeWindow.holdLayers![1] = windowLayer
        store.settings.appExplorer = beforeWindow; settle()
        press("hud-layer-button-" + windowLayer.id.uuidString)
        precondition(viewportGeometry.canvasCount == 1, "Window Manager must replace, not duplicate, the editing canvas")
        let renderedTiles = all(host).filter { $0.accessibilityRole?() == .button && $0.accessibilityLabel?() == "Left: Window left" }
        precondition(Set(renderedTiles.map(ObjectIdentifier.init)).count == 1,
            "Window Manager must show only one editable renderer in the actual HUD page")
        try capture("hud-workspace-window-manager-before-drag")
        drag(tile(.left, name: "Window left"), to: tile(.right, name: "Window right"))
        let afterWindow = store.settings.appExplorer!
        precondition(afterWindow.windowManager?.favorites?.first { $0.direction == .right }?.name == "Window left" &&
            afterWindow.windowManager?.favorites?.first { $0.direction == .left }?.name == "Window right",
            "Window drag must swap scoped favorites: \(String(describing: afterWindow.windowManager?.favorites))")
        var untouched = afterWindow; untouched.windowManager = beforeWindow.windowManager
        precondition(untouched == beforeWindow, "Window Manager editing must save only to the window configuration")
        try capture("hud-workspace-window-manager")
        closePopover()
        // Ordinary settings pages keep their native controls reachable when
        // resized. Any wide content must have a real horizontal scroll path.
        for section in ["Voice mode", "Pointer & scrolling", "Actions"] {
            let ordinaryHost = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync,
                initialSection: section).defaultAppStorage(defaults).environment(\.colorScheme, .dark))
            panel.contentView = ordinaryHost
            for size in [NSSize(width: 940, height: 740), NSSize(width: 860, height: 680), NSSize(width: 1240, height: 900)] {
                panel.setContentSize(size); settle(); ordinaryHost.layoutSubtreeIfNeeded()
                precondition(abs(ordinaryHost.bounds.width - size.width) < 1 && abs(ordinaryHost.bounds.height - size.height) < 1)
                if section == "Voice mode" || section == "Actions" {
                    let visible = panel.convertToScreen(ordinaryHost.convert(ordinaryHost.bounds, to: nil))
                    let heading = frame(find("settings-page-heading", in: ordinaryHost))
                    let topInset = visible.maxY - heading.maxY
                    precondition((75...120).contains(topInset),
                        "Ordinary settings page must retain its top alignment at \(size): inset \(topInset)")
                }
                if section == "Voice mode" {
                    for id in ["voice-auto-start", "voice-auto-decide"] {
                        let element = find(id, in: ordinaryHost)
                        let visible = panel.convertToScreen(ordinaryHost.convert(ordinaryHost.bounds, to: nil))
                        precondition(visible.contains(frame(element)), "Voice controls must be visible at the supported width")
                    }
                } else if section == "Pointer & scrolling" {
                    _ = find("pointer-device-picker", in: ordinaryHost)
                } else {
                    let tables = views(ordinaryHost).compactMap { $0 as? NSTableView }
                    precondition(!tables.isEmpty, "Actions must retain its native table at every viewport")
                    for table in tables {
                        if let scroll = table.enclosingScrollView, table.bounds.width > scroll.contentView.bounds.width + 1 {
                            let end = max(0, table.bounds.width - scroll.contentView.bounds.width)
                            scroll.contentView.scroll(to: NSPoint(x: end, y: scroll.contentView.bounds.minY))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            precondition(scroll.contentView.bounds.minX > 0, "Wide Actions columns must be reachable through native horizontal scrolling")
                        }
                    }
                }
                if size.width == 860 { try capture("hud-other-page-" + section.replacingOccurrences(of: " ", with: "-"), root: ordinaryHost) }
            }
        }
        print("HUD workspace passed actual ContentView viewport centering, all mapped/legacy layers, inert browsing, selected/nested drag persistence, native tile popover, and default taps access.")
    }
}
