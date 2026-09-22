import AppKit
import SwiftUI

private struct ContrastBackdrop: View {
    var bright: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: bright ? [Color.white, Color(red: 0.80, green: 0.89, blue: 1)] :
                [Color(red: 0.16, green: 0.07, blue: 0.28), Color(red: 0.04, green: 0.26, blue: 0.34)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 18) {
                Text("WORKSPACE / PROJECT NOTES").font(.system(size: 14, weight: .semibold, design: .monospaced))
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<3) { column in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(["RESEARCH", "IN PROGRESS", "UP NEXT"][column]).font(.headline)
                            ForEach(0..<6) { row in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Project \(column + 1) · Note \(row + 1)").font(.subheadline.weight(.semibold))
                                    Text("Review the latest updates\nand prepare the next steps.").font(.caption)
                                    Rectangle().fill(Color.teal.opacity(0.55)).frame(height: 3)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(bright ? Color.white.opacity(0.95) : Color.white.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }.padding(24).foregroundStyle(bright ? Color.black.opacity(0.7) : Color.white.opacity(0.7))
        }
    }
}

@main struct StarburstAirGlassUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let model = ExplorerModel()
        model.theme = .starburstAir
        model.animationsEnabled = false
        model.canEdit = true
        let labels = ["Window Manager", "Music", "Focus", "Volume", "Workspace", "Recent apps", "Finder", "Actions"]
        func entries(_ count: Int) -> [ExplorerEntry] {
            ExplorerSlot.slots(count).enumerated().map { i, slot in
                ExplorerEntry(direction: slot, bundleID: nil, name: count == 8 ? labels[i] : "Group \(i + 1)",
                    icon: nil, url: nil, isGroup: true)
            }
        }
        model.entries = entries(8)
        model.selected = .topRight
        func render(_ name: String, bright: Bool, opaque: Bool = false) throws {
            let view = ZStack {
                ContrastBackdrop(bright: bright)
                AppExplorerView(model: model, onSelect: { _ in }, onCancel: {},
                    forceReduceMotion: true, forceReduceTransparency: opaque)
            }.frame(width: 760, height: 640)
            let host = NSHostingView(rootView: view)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = host; panel.center(); panel.orderFront(nil)
            defer { panel.orderOut(nil); panel.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                CommandLine.arguments[1] + "/" + name + ".png"))
        }
        try render("air-glass-bright", bright: true)
        try render("air-glass-dark", bright: false)
        try render("air-glass-opaque", bright: true, opaque: true)
        for depth in [1, 3, 5] {
            model.groupNames = Array(["Workspace", "Design", "Tools", "Windows", "Layout"].prefix(depth))
            model.groupDirections = Array([ExplorerSlot.left, .topRight, .up, .right, .down].prefix(depth))
            model.groupSlotCounts = Array(repeating: 8, count: depth)
            try render("air-glass-depth-\(depth)", bright: true)
        }
        model.groupNames = []; model.groupDirections = []; model.groupSlotCounts = []
        for count in [4, 12, 16] {
            model.slotCount = count; model.entries = entries(count); model.selected = .up
            try render("air-glass-slots-\(count)", bright: false)
        }
        precondition(!ExplorerHUDMotion.enabled(theme: .starburstAir, preference: true, reduceMotion: true))
        print("Starburst Air rendered over bright/dark busy desktops, opaque accessibility fallback, 1/3/5 nested levels, and 4/8/12/16 slots. No input, settings, apps or sync started.")
    }
}
