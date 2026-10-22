import AppKit
import SwiftUI

/// Uses isolated value settings; never starts hardware, sync, or Keychain access.
@main struct ExplorerTransferUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let child = AppExplorerFavorite(direction: .up, bundleID: "com.apple.finder", name: "Finder")
        let group = AppExplorerFavorite(direction: .left, name: "Work tools", children: [child],
            holdLayers: [ExplorerHoldLayer(name: "Writing", favorites: [child])])
        var settings = AppExplorerSettings(favorites: [group],
            holdLayers: [ExplorerHoldLayer(name: "Focus", favorites: [])])
        let transfer = ExplorerTileTransfer(snapshot: settings, source: [], slot: .left)
        var saved = false
        let root = ExplorerTileTransferEditor(transfer: transfer, onSave: { destination, slot, copy in
            let error = transfer.apply(to: destination, slot: slot, copy: copy, settings: &settings)
            saved = error == nil
            return error
        }, onCancel: {})
        let host = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(x: 150, y: 150, width: 570, height: 460),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/\(name).png"))
        }
        try capture("transfer-picker")
        func click(_ x: CGFloat, _ y: CGFloat) {
            let point = host.convert(NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            NSApp.postEvent(event(.leftMouseUp), atStart: true)
            panel.sendEvent(event(.leftMouseDown))
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { panel.sendEvent(up) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        // Slot centers in the fixed-size native fixture, clockwise from the top.
        click(352, 226) // Right: empty destination.
        try capture("transfer-selected")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        panel.sendEvent(enter)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(saved, "Native destination click and Return must save the transfer")
        precondition(settings.favorite(at: [.left]) == nil)
        precondition(settings.favorite(at: [.right])?.children == [child])
        precondition(settings.favorite(at: [.right])?.holdLayers == group.holdLayers)
        panel.orderOut(nil); panel.close()
        print("Explorer transfer UI passed: rendered destination picker, native slot selection, keyboard commit, recursive contents preserved")
    }
}
