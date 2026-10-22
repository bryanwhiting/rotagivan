// Temporary audit: main-thread cost of interactions beyond the HUD open path.
import AppKit
import SwiftUI
import QuartzCore

@main struct InteractionBenchmark {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rota.InteractionBench.\(UUID().uuidString)"
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
        let onlyChrome = CommandLine.arguments.contains("--only-chrome")
        let onlyMacro = CommandLine.arguments.contains("--only-macro")
        if onlyChrome {
            // Chrome tab switching as the HUD and bookmarks do it. Each run re-selects
            // the tab that is already active, so nothing visible changes, but Chrome
            // does come to the front. Without a running Chrome only the script
            // compile cost is measured; nothing here launches Chrome.
            if let tab = ChromeBookmarkTabs.activeTab() {
                print("chrome: active tab", tab.windowIndex, tab.tabIndex, tab.url.prefix(50))
                measure("chrome: activate open tab (HUD path)", runs: 10) { precondition(ChromeBookmarkTabs.activate(tab)) }
                measure("chrome: open bookmark URL, tab already open", runs: 10) {
                    precondition(ChromeBookmarkTabs.execute(ChromeBookmarkTabs.request(url: tab.url, preferredTab: "")).error == nil)
                }
                measure("chrome: activeTab() recency sample", runs: 10) { _ = ChromeBookmarkTabs.activeTab() }
                measure("chrome: snapshot() AppleScript only", runs: 5) { _ = ChromeBookmarkTabs.snapshotScript.call("snapshotTabs") }
                measure("chrome: snapshot() with profile history", runs: 5) { _ = ChromeBookmarkTabs.snapshot() }
            } else {
                print("chrome: not running; measuring script compile only")
                measure("chrome: compile open script") {
                    var error: NSDictionary?
                    _ = NSAppleScript(source: ChromeBookmarkTabs.script(url: "https://example.com/", preferredTab: ""))?.compileAndReturnError(&error)
                }
            }
            return
        }
        if onlyMacro {
            // Three chords end to end through the serial lane with the real chord
            // pacing but nothing posted, so it is safe with any app in front.
            func runAsync(_ work: @escaping @MainActor () async -> Void) {
                var done = false
                Task { @MainActor in await work(); done = true }
                while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            }
            let copy = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
            let chords: [MacroStep] = [.key(copy), .key(copy), .key(copy)]
            let player = MacroPlayback()
            player.currentApp = { 1 }
            func benchMacro(_ name: String, delay: TimeInterval, send: @escaping (RecordedShortcut, pid_t) async -> Bool) {
                player.send = send
                var samples: [Double] = []
                runAsync {
                    for _ in 0..<5 {
                        let start = DispatchTime.now().uptimeNanoseconds
                        let finished = await player.execute(chords, delay: delay, target: 1)
                        precondition(finished)
                        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                    }
                }
                samples.sort()
                print(String(format: "%-46@ median %7.2f ms   max %7.2f ms", name, samples[samples.count / 2], samples.last!))
            }
            benchMacro("macro: 3 chords, legacy pacing (100 / 12 / 40 ms)", delay: 0.1) { shortcut, _ in
                for (index, event) in EventPoster.shortcutEvents(shortcut).enumerated() where index > 0 {
                    try? await Task.sleep(nanoseconds: event.type == .keyUp ? 40_000_000 : 12_000_000)
                }
                return true
            }
            let defaultDelay = Double(NamedHotkey(name: "Bench", shortcut: copy).resolvedDelay) / 1000
            benchMacro("macro: 3 chords, current pacing (\(Int(defaultDelay * 1000)) ms default)", delay: defaultDelay) { shortcut, _ in
                await MacroPlayback.postChord(EventPoster.shortcutEvents(shortcut)) { _ in }
                return true
            }
            measure("macro: frontmost pid check per step") { _ = NSWorkspace.shared.frontmostApplication?.processIdentifier }
            return
        }
        let encoder = JSONEncoder()
        let json = try encoder.encode(store.settings)
        print("settings JSON bytes:", json.count, " profiles:", store.configurationProfiles.count)
        try measure("settings save: encode StoredSettings") { _ = try encoder.encode(store.settings) }
        try measure("settings save: encode profile library") { _ = try encoder.encode(ConfigurationLibrary(activeID: store.activeConfigurationID, profiles: store.profileSnapshot())) }
        measure("settings save: one slider tick (didSet path)") { store.settings.normal.cursorSpeed += 0.0001 }
        // The field codec is gone; the sync snapshot is now one configuration encode.
        try measure("sync: snapshot + encode configuration") { _ = try encoder.encode(AppConfiguration(store: store)) }
        let apps = (0..<600).map { ExplorerApplication(bundleID: "bench.app.\($0)", name: "Application \($0)", url: URL(fileURLWithPath: "/Applications/App\($0).app")) }
        // MCP: one tool call round trip through the Unix socket into the main actor.
        let socketURL = URL(fileURLWithPath: "/tmp/rb-\(Int.random(in: 1000...9999))/bridge.sock")
        defaults.set(true, forKey: MCPBridgeEndpoint.enabledKey)
        let bridge = MCPBridgeServer(defaults: defaults, socketURL: socketURL)
        bridge.attach(store: store, applications: { apps })
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        print("mcp listening:", bridge.isListening, bridge.error ?? "")
        measure("registry: VoiceActionRegistry.make (cached)") { _ = VoiceActionRegistry.make(settings: store.settings, applications: apps, includeInactiveApplications: true) }
        measure("mcp: perform(get_settings_summary) on main") { _ = bridge.perform("get_settings_summary", arguments: [:]) }
        measure("mcp: perform(list_huds) on main") { _ = bridge.perform("list_huds", arguments: [:]) }
        measure("mcp: perform(list_actions) on main") { _ = bridge.perform("list_actions", arguments: [:]) }
        var mcpSamples: [Double] = []
        for _ in 0..<15 {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = MCPBridgeClient.call(tool: "get_settings_summary", arguments: [:], socketPath: socketURL.path)
                mcpSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
        }
        mcpSamples.sort()
        print(String(format: "%-46@ median %7.2f ms   max %7.2f ms", "mcp: socket round trip (main pumped 0.5 ms)", mcpSamples[mcpSamples.count / 2], mcpSamples.last!))
        bridge.stop()
        if CommandLine.arguments.contains("--only-mcp") { return }
        let registered = VoiceActionRegistry.make(settings: store.settings, applications: apps, includeInactiveApplications: true)
        let actions = LauncherAction.apps(apps) + [.settings] + LauncherAction.registered(registered.filter { $0.enabled && $0.action.kind != .openApp })
        print("launcher catalog rows:", actions.count)
        measure("launcher: search per keystroke ('mail')") { _ = LauncherAction.search("mail", actions: actions) }
        measure("launcher: search per keystroke ('a')") { _ = LauncherAction.search("a", actions: actions) }
        // Opt-in Chrome history adds up to 3,000 rows to the same catalog.
        let history = actions + LauncherAction.chromeHistory((0..<3000).map { i in
            ChromeHistoryEntry(url: "https://site\(i % 400).example.com/path/\(i)", title: "Page \(i) about topic \(i % 37)",
                               lastVisit: Date(timeIntervalSince1970: Double(i)), visitCount: i % 9)
        })
        measure("launcher: search per keystroke (+3000 history)") { _ = LauncherAction.search("mail", actions: history) }
        measure("launcher: search per keystroke ('a', +history)") { _ = LauncherAction.search("a", actions: history) }
        measure("profile switch: hid.stop() + hid.start() (no device)", runs: 10) {
            let manager = NavigatorHIDManager(store: store); manager.stop(); manager.start(); manager.stop()
        }
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
        if CommandLine.arguments.contains("--loop-general") {
            let until = Date().addingTimeInterval(6)
            while Date() < until {
                let host = NSHostingView(rootView: ContentView(store: store, hid: hid, sync: sync, initialSection: "General").defaultAppStorage(defaults))
                host.frame = NSRect(x: 0, y: 0, width: 1100, height: 740)
                host.layoutSubtreeIfNeeded()
                let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: image)
            }
            return
        }
        if CommandLine.arguments.contains("--loop-calibration") {
            let until = Date().addingTimeInterval(6)
            while Date() < until {
                let host = NSHostingView(rootView: CalibrationSettingsView(store: store, hid: hid).frame(width: 800).defaultAppStorage(defaults))
                host.frame = NSRect(x: 0, y: 0, width: 800, height: 1400)
                host.layoutSubtreeIfNeeded()
                let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: image)
            }
            return
        }
        // Timer alert: CPU the glowing edges burn while shown (breathing animation on every screen).
        func cpuSeconds() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        if CommandLine.arguments.contains("--only-timer") { /* fallthrough: timer measured next */ }
        let alert = FocusTimerAlert(minutes: 1, onDone: {}, onSnooze: {})
        alert.show()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))   // past the three flashes
        let cpuBefore = cpuSeconds(); let wallBefore = Date()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let alertCPU = (cpuSeconds() - cpuBefore) / Date().timeIntervalSince(wallBefore) * 100
        alert.close()
        print(String(format: "%-46@ %5.1f%% of one core", "timer alert: CPU while breathing", alertCPU))
        if CommandLine.arguments.contains("--only-timer") { return }
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
