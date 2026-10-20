// Temporary audit: main-thread cost of interactions beyond the HUD open path.
import AppKit
import SwiftUI
import QuartzCore

@main struct InteractionBenchmark {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.InteractionBench.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        // A heavy but plausible configuration: 12 HUD layers × 8 tiles, 60 bookmarks, 40 macros, 3 profiles.
        var explorer = AppExplorerSettings()
        explorer.favorites = ExplorerSlot.slots(8).enumerated().map { i, slot in
            AppExplorerFavorite(direction: slot, bundleID: "com.example.app\(i)", name: "App \(i)")
        }
        explorer.holdLayers = (0..<12).map { index in
            var layer = ExplorerHoldLayer.empty(name: "Layer \(index)")
            layer.favorites = ExplorerSlot.slots(8).enumerated().map { i, slot in
                AppExplorerFavorite(direction: slot, name: "Site \(index)-\(i)", url: "https://example\(index).com/\(i)")
            }
            return layer
        }
        store.settings.appExplorer = explorer
        store.settings.hotkeyDictionary = (0..<40).map { NamedHotkey(name: "Macro \($0)", shortcut: RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")) }
        _ = store.settings.addWebsiteBookmarks((0..<60).map { BindingAction.openURL("https://bookmark\($0).example.com/path") })
        _ = store.addConfiguration(); _ = store.addConfiguration()
        func measure(_ name: String, runs: Int = 20, _ work: () throws -> Void) rethrows {
            try work()
            var samples: [Double] = []
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                try work()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            samples.sort()
            print(String(format: "%-46@ median %7.2f ms   max %7.2f ms", name, samples[samples.count / 2], samples.last!))
        }
        let encoder = JSONEncoder()
        let json = try encoder.encode(store.settings)
        print("settings JSON bytes:", json.count, " profiles:", store.configurationProfiles.count)
        try measure("settings save: encode StoredSettings") { _ = try encoder.encode(store.settings) }
        try measure("settings save: encode profile library") { _ = try encoder.encode(ConfigurationLibrary(activeID: store.activeConfigurationID, profiles: store.profileSnapshot())) }
        measure("settings save: one slider tick (didSet path)") { store.settings.normal.cursorSpeed += 0.0001 }
        try measure("sync: snapshot + fields") { _ = try SyncConfigurationCodec.fields(AppConfiguration(store: store)) }
        let fields = try SyncConfigurationCodec.fields(AppConfiguration(store: store))
        measure("sync: changes(unchanged)") { _ = SyncConfigurationCodec.changes(from: fields, to: fields) }
        let apps = (0..<600).map { ExplorerApplication(bundleID: "bench.app.\($0)", name: "Application \($0)", url: URL(fileURLWithPath: "/Applications/App\($0).app")) }
        let registered = VoiceActionRegistry.make(settings: store.settings, applications: apps, includeInactiveApplications: true)
        let actions = LauncherAction.apps(apps) + [.settings] + LauncherAction.registered(registered.filter { $0.enabled && $0.action.kind != .openApp })
        print("launcher catalog rows:", actions.count)
        measure("launcher: search per keystroke ('mail')") { _ = LauncherAction.search("mail", actions: actions) }
        measure("launcher: search per keystroke ('a')") { _ = LauncherAction.search("a", actions: actions) }
        measure("profile switch: selectConfiguration", runs: 10) {
            let other = store.configurationProfiles.first { $0.id != store.activeConfigurationID }!.id
            store.selectConfiguration(other)
        }
        let hid = NavigatorHIDManager(store: store)
        let sync = SettingsSync(store: store, hid: hid, defaults: defaults, automatic: false)
        func renderPage(_ section: String, label: String) {
            measure("settings window: first render of \(label)", runs: 5) {
                let host = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync, initialSection: section).defaultAppStorage(defaults))
                host.frame = NSRect(x: 0, y: 0, width: 1100, height: 740)
                host.layoutSubtreeIfNeeded()
                let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: image)
            }
        }
        // Live HUD: cost of one frame while the selection (and its glass lens) moves.
        let model = ExplorerModel()
        model.slotCount = 8
        model.entries = ExplorerSlot.slots(8).enumerated().map { i, slot in
            ExplorerEntry(direction: slot, bundleID: nil, name: "Site \(i)", icon: nil, url: URL(string: "https://example\(i).com"), isWebURL: true)
        }
        model.theme = .starburstAir
        let hudHost = NSHostingView(rootView: AppExplorerView(model: model, onSelect: { _ in }, onCancel: {}))
        hudHost.frame = NSRect(x: 0, y: 0, width: 950, height: 850)
        let hudPanel = NSPanel(contentRect: hudHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        hudPanel.isReleasedWhenClosed = false; hudPanel.contentView = hudHost; hudPanel.alphaValue = 0; hudPanel.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        var flip = false
        measure("live HUD: window draw per frame, lens moving", runs: 30) {
            flip.toggle(); model.selected = flip ? .up : .right
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            hudHost.layoutSubtreeIfNeeded(); hudPanel.displayIfNeeded()
            CATransaction.flush()
        }
        measure("live HUD: window draw per frame, nothing moving", runs: 30) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            hudHost.layoutSubtreeIfNeeded(); hudPanel.displayIfNeeded()
            CATransaction.flush()
        }
        measure("live HUD: full CPU raster of one frame", runs: 10) {
            flip.toggle(); model.selected = flip ? .up : .right
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let image = hudHost.bitmapImageRepForCachingDisplay(in: hudHost.bounds)!
            hudHost.cacheDisplay(in: hudHost.bounds, to: image)
        }
        if CommandLine.arguments.contains("--loop-frame") {
            let until = Date().addingTimeInterval(6)
            while Date() < until {
                flip.toggle(); model.selected = flip ? .up : .right
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                hudHost.layoutSubtreeIfNeeded(); hudPanel.displayIfNeeded()
                CATransaction.flush()
            }
            return
        }
        hudPanel.orderOut(nil)
        if CommandLine.arguments.contains("--loop-hud") {
            let until = Date().addingTimeInterval(6)
            while Date() < until {
                let host = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync, initialSection: "HUD").defaultAppStorage(defaults))
                host.frame = NSRect(x: 0, y: 0, width: 1100, height: 740)
                host.layoutSubtreeIfNeeded()
                let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: image)
            }
            return
        }
        renderPage("Actions", label: "Actions"); renderPage("General", label: "General")
        for count in [0, 4, 12] {
            var trimmed = explorer; trimmed.holdLayers = Array(explorer.holdLayers!.prefix(count))
            store.settings.appExplorer = trimmed
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            renderPage("HUD", label: "HUD page with \(count) layers")
        }
        var none = explorer; none.holdLayers = []
        store.settings.appExplorer = none
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        renderPage("Calibration", label: "HUD page opened on Calibration tab (0 layers)")
        store.settings.appExplorer = explorer
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        renderPage("Calibration", label: "HUD page opened on Calibration tab (12 layers)")
    }
}
