import AppKit
import SwiftUI

@main struct StarburstUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = ExplorerModel()
        model.theme = .starburstAir
        model.animationsEnabled = false
        let titles = ["Research", "Windows", "Music", "Notes", "Workspace", "Recent apps", "Development", "Design"]
        let directions: [ExplorerSlot] = [.up, .topRight, .right, .bottomRight, .down, .bottomLeft, .left, .topLeft]
        model.entries = directions.enumerated().map {
            ExplorerEntry(direction: $0.element, bundleID: nil, name: titles[$0.offset], icon: nil, url: nil, isGroup: true)
        }
        var selected: [ExplorerSlot] = []
        var back = 0
        let view = AppExplorerView(model: model,
            onSelect: { selected.append($0) }, onCancel: {}, onBack: { back += 1 })
        let host = NSHostingView(rootView: AnyView(view))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
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
        for theme in [ExplorerTheme.starburst, .starburstAir] {
        model.theme = theme
        for depth in 0...5 {
            model.groupNames = Array(["Workspace", "Design", "Research", "Projects", "Media Controls"].prefix(depth))
            model.groupDirections = Array([ExplorerSlot.down, .left, .topRight, .up, .right].prefix(depth))
            model.selected = .topRight
            settle()
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(theme.rawValue)-depth-\(depth).png"))
            if theme.isFloating {
                precondition(bitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.01,
                    "Air must keep transparent corners outside its rounded glass")
                precondition(bitmap.colorAt(x: bitmap.pixelsWide / 12, y: bitmap.pixelsHigh / 2)!.alphaComponent > 0.1,
                    "Air must provide glass behind the gaps between HUD elements")
            }
            for direction in directions {
                // AppKit has a bottom-left origin; the fixed HUD wheel is
                // centered near (235, 248), independent of nesting depth.
                let radial = ExplorerStarburstLayout.point(direction, radius: 116, center: .zero)
                let count = selected.count
                click(CGPoint(x: 235 + radial.x, y: 248 - radial.y))
                precondition(selected.count == count + 1 && selected.last == direction,
                    "Native sector hit test failed: depth \(depth), \(direction)")
            }
            let count = back
            click(CGPoint(x: 235, y: 248))
            precondition(back == count + 1, "Center must remain tappable at every level")
        }
        }
        for light in [true, false] {
            model.theme = .starburstAir
            model.groupNames = []; model.groupDirections = []
            host.rootView = AnyView(view.background(light ? Color.white : Color.black))
            settle()
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("air-\(light ? "light" : "dark").png"))
        }
        var reducedView = view
        reducedView.forceReduceTransparency = true
        host.rootView = AnyView(reducedView)
        settle()
        let reduced = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: reduced)
        precondition(reduced.colorAt(x: 0, y: 0)!.alphaComponent < 0.01)
        precondition(reduced.colorAt(x: reduced.pixelsWide / 12, y: reduced.pixelsHigh / 2)!.alphaComponent > 0.99,
            "Reduce Transparency must make the whole glass backing opaque, not only its tiles")
        try reduced.representation(using: .png, properties: [:])!.write(to:
            URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("air-reduced-transparency.png"))
        print("Starburst/Starburst Air native UI passed: sector and center hit tests at six depths, glass coverage with transparent corners, opaque accessibility fallback, and light/dark screenshots. No apps launched or system pointer events posted.")
    }
}
