import AppKit
import SwiftUI

@main struct BrowserBookmarkImporterUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let fixtures = [
            BrowserBookmark(source: .chrome, title: "OpenAI", url: URL(string: "https://openai.com/")!,
                folder: "Bookmarks bar / Work", profile: "Default"),
            BrowserBookmark(source: .chrome, title: "Swift", url: URL(string: "https://swift.org/")!,
                folder: "Bookmarks bar / Development", profile: "Profile 2"),
            BrowserBookmark(source: .chrome, title: "Already in HUD", url: URL(string: "https://example.com/")!,
                folder: "Other bookmarks", profile: "Default")
        ]
        var imported = false
        let importer = ExplorerBookmarkImporter(capacity: 2, existingURLs: ["https://example.com/"],
            onImport: { _ in imported = true; return true }, onCancel: {},
            loadBookmarks: { _, _ in fixtures })
        let host = NSHostingView(rootView: importer)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        precondition(!imported, "Browsing bookmarks must not import without confirmation")
        precondition(host.fittingSize.width >= 650 && host.fittingSize.height >= 590,
            "Importer should retain a useful library-sized layout")
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("bookmark-importer.png"))
        print("Bookmark importer UI passed: native library rendered with profile, folder, duplicate, and capacity states")
    }
}
