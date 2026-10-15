import AppKit
import SwiftUI

@main struct LocalUsageUISmoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let url = directory.appendingPathComponent("synthetic/usage.sqlite")
        let suite = "Rotagivan.UsageSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date().timeIntervalSince1970
        do {
            let db = try UsageDatabase(url: url)
            for index in 0..<20 {
                let start = now - 600 + Double(index) * 20
                try db.append(.init(start: start, end: start + 20, app: .init(id: "com.fixture.browser", name: "Example browser"), host: "example.com"))
            }
            try db.recordAction(id: "example", name: "Example command", category: "action", at: now - 60)
        }
        let tracker = LocalUsageTracker(defaults: defaults, databaseURL: url, monitorSystem: false)
        tracker.refresh()
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(!tracker.enabled && !tracker.personalize && !tracker.websites, "UI smoke must never enable collection")
        precondition(tracker.report.total == 400 && tracker.actions.first?.count == 1)
        let view = NSHostingView(rootView: LocalUsageView(activity: tracker))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Activity — synthetic test"; window.contentView = view; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("activity.png"))
        precondition(!tracker.enabled && !RotaActionUsage.enabled, "Rendering cannot opt in or enable command instrumentation")
        window.orderOut(nil)
        print("Native activity report rendered using only isolated synthetic data; collection remains off")
    }
}
