import AppKit
import SwiftUI

@main struct StarburstUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = ExplorerModel()
        model.theme = .starburst
        model.animationsEnabled = false
        let titles = ["Research", "Windows", "Music", "Notes", "Workspace", "Recent apps", "Development", "Design"]
        let directions: [SwipeDirection] = [.up, .topRight, .right, .bottomRight, .down, .bottomLeft, .left, .topLeft]
        model.entries = directions.enumerated().map {
            ExplorerEntry(direction: $0.element, bundleID: nil, name: titles[$0.offset], icon: nil, url: nil, isGroup: true)
        }
        var selected: [SwipeDirection] = []
        var back = 0
        let host = NSHostingView(rootView: AppExplorerView(model: model,
            onSelect: { selected.append($0) }, onCancel: {}, onBack: { back += 1 }))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 464),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { panel.orderOut(nil); panel.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        func click(_ point: CGPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                panel.sendEvent(event)
            }
            settle()
        }
        for depth in 0...5 {
            model.groupNames = Array(["Workspace", "Design", "Research", "Projects", "Media Controls"].prefix(depth))
            model.groupDirections = Array([SwipeDirection.down, .left, .topRight, .up, .right].prefix(depth))
            model.selected = .topRight
            settle()
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("starburst-depth-\(depth).png"))
            for direction in directions {
                // AppKit has a bottom-left origin; the fixed HUD wheel is
                // centered near (235, 220), independent of nesting depth.
                let radial = ExplorerStarburstLayout.point(direction, radius: 116, center: .zero)
                let count = selected.count
                click(CGPoint(x: 235 + radial.x, y: 220 - radial.y))
                precondition(selected.count == count + 1 && selected.last == direction,
                    "Native sector hit test failed: depth \(depth), \(direction)")
            }
            let count = back
            click(CGPoint(x: 235, y: 220))
            precondition(back == count + 1, "Center must remain tappable at every level")
        }
        print("Starburst native UI passed: all eight sector buttons and center at six depths; screenshots saved. No apps launched or system pointer events posted.")
    }
}
