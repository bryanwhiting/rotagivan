import AppKit
import SQLite3

@main struct BrowserURLDispatcherTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dispatcher = BrowserURLDispatcher()
        dispatcher.defaultBrowserBundleID = { _ in "test.browser" }
        let url = URL(string: "https://example.com/work")!
        let browser = URL(fileURLWithPath: "/Applications/Fixture Browser.app")
        var lookups: [String] = []
        var targeted: [(URL, URL)] = []
        var defaults: [URL] = []
        var failures: [String] = []
        dispatcher.applicationURL = { lookups.append($0); return browser }
        dispatcher.validateApplication = { $0 == browser && $1 == "test.browser" }
        dispatcher.openTargeted = { targeted.append(($0, $1)); $2(nil) }
        dispatcher.openDefault = { defaults.append($0); return true }
        dispatcher.onFailure = { failures.append($0) }
        dispatcher.open(url, targetBrowserBundleID: "test.browser")
        precondition(lookups == ["test.browser"] && targeted.count == 1)
        precondition(targeted[0].0 == url && targeted[0].1 == browser && defaults.isEmpty && failures.isEmpty)
        dispatcher.open(url, targetBrowserBundleID: nil)
        precondition(defaults == [url] && lookups.count == 1, "Legacy URLs continue using the default browser")
        dispatcher.applicationURL = { _ in nil }
        dispatcher.open(url, targetBrowserBundleID: "test.missing")
        precondition(targeted.count == 1 && defaults.count == 1 && failures.count == 1)
        precondition(failures[0].contains("not installed"), "Missing targets must report a visible actionable error")
        dispatcher.applicationURL = { _ in browser }
        dispatcher.openTargeted = { _, _, completion in completion(NSError(domain: "Fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Fixture open failure"])) }
        dispatcher.open(url, targetBrowserBundleID: "test.browser")
        precondition(failures.count == 2 && failures[1].contains("Error code: 1") && defaults.count == 1)
        precondition(!failures[1].contains("Fixture open failure"), "Launch error payloads must not expose private URL contents")
        dispatcher.applicationURL = { _ in URL(string: "https://example.com/not-an-installed-app") }
        dispatcher.open(url, targetBrowserBundleID: "test.browser")
        precondition(failures.count == 3 && defaults.count == 1, "Nonlocal application lookup results must not be opened")
        dispatcher.applicationURL = { _ in browser }
        dispatcher.validateApplication = { _, _ in false }
        dispatcher.open(url, targetBrowserBundleID: "test.browser")
        precondition(failures.count == 4 && defaults.count == 1, "A lookup resolving a different bundle must fail closed")
        dispatcher.open(URL(string: "javascript:alert(1)")!, targetBrowserBundleID: "test.browser")
        precondition(failures.count == 4, "Invalid URL schemes are never dispatched")

        var chromeOpens = 0
        dispatcher.openChrome = { _, _, completion in chromeOpens += 1; completion(nil) }
        dispatcher.open(url, targetBrowserBundleID: "com.google.Chrome")
        dispatcher.defaultBrowserBundleID = { _ in "com.google.Chrome" }
        dispatcher.open(url, targetBrowserBundleID: nil)
        precondition(chromeOpens == 2 && defaults.count == 1, "Explicit and default Chrome use tab reuse")
        dispatcher.openChrome = { _, _, completion in completion(-1743) }
        dispatcher.open(url, targetBrowserBundleID: "com.google.Chrome")
        precondition(failures.count == 5 && defaults.count == 1, "Automation denial must not open duplicates")

        let tabs = ChromeBookmarkTabs(run: { request in
            let source = request.source
            precondition(source.contains("mode of w is \"normal\""))
            precondition(source.contains("set exactMatch to (tabURL is requestedURL"))
            if source.contains("set preferredID to \"fixture-tab\"") { return ("fixture-tab", nil) }
            precondition(source.contains("set preferredID to \"\""))
            return ("fixture-tab", nil)
        })
        await withCheckedContinuation { continuation in
            tabs.open(url) { code in precondition(code == nil); continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            tabs.open(url) { code in precondition(code == nil); continuation.resume() }
        }
        precondition(ChromeBookmarkTabs.literal("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"")
        precondition(ChromeBookmarkTabs.script(url: "https://example.com?account=one#section", preferredTab: "")
            .contains("set normalizedURL to \"https://example.com/?account=one#section\""),
            "Bare origins must match Chrome's slash normalization without dropping query or fragment")
        precondition(ChromeBookmarkTabs.sitePrefix("https://mail.google.com") == "https://mail.google.com/")
        precondition(ChromeBookmarkTabs.sitePrefix("https://mail.google.com/mail/u/1/?tab=rm#inbox") == "https://mail.google.com/mail/u/1/",
            "Bookmarks reuse any open tab under their origin and path")
        precondition(ChromeBookmarkTabs.script(url: "https://mail.google.com/", preferredTab: "", recentURL: "https://mail.google.com/mail/u/0/#inbox")
            .contains("set recentURL to \"https://mail.google.com/mail/u/0/#inbox\""))
        var compileError: NSDictionary?
        let script = NSAppleScript(source: ChromeBookmarkTabs.script(url: url.absoluteString, preferredTab: ""))!
        precondition(script.compileAndReturnError(&compileError), "Chrome script must compile: \(String(describing: compileError))")
        let request = ChromeBookmarkTabs.request(url: "https://example.com?account=one#section", preferredTab: "tab-9", recentURL: "https://example.com/recent")
        precondition(request.normalizedURL == "https://example.com/?account=one#section" && request.sitePrefix == "https://example.com/"
            && request.preferredTab == "tab-9" && request.recentURL == "https://example.com/recent")
        // Compiled-once handlers: parameters travel as Apple event arguments, not
        // as literals escaped into source, and the compiled script is reused.
        let echo = ChromeScript(source: "on echo(headValue, tailValue)\nreturn headValue & \"-\" & tailValue\nend echo")
        let echoed = echo.call("echo", [NSAppleEventDescriptor(string: "a\"b"), NSAppleEventDescriptor(int32: 7)])
        precondition(echoed.error == nil && echoed.result?.stringValue == "a\"b-7", "\(String(describing: echoed))")
        let missing = echo.call("absent")
        precondition(missing.error != nil && missing.result == nil, "Unknown handlers report an AppleScript error number")
        let broken = ChromeScript(source: "on broken(\nend")
        precondition(broken.call("broken").error != nil, "Compile failures report an error, never crash")
        for (name, source) in [("open", ChromeBookmarkTabs.openHandlerSource)] {
            var handlerError: NSDictionary?
            precondition(NSAppleScript(source: source)!.compileAndReturnError(&handlerError), "\(name) handler must compile: \(String(describing: handlerError))")
        }
        precondition(ChromeBookmarkTabs.openHandlerSource.contains("URL of every tab of w") && !ChromeBookmarkTabs.openHandlerSource.contains("\n                    activate"),
            "Tabs are read per window, and Chrome is brought forward from Swift, not by the slow AppleScript activate")
        let rowScript = NSAppleScript(source: """
            return "1" & \(ChromeBookmarkTabs.appleScriptFieldSeparator) & "2" & \(ChromeBookmarkTabs.appleScriptFieldSeparator) & "Title" & \(ChromeBookmarkTabs.appleScriptFieldSeparator) & "https://fixture.test/"
            """)!
        var rowError: NSDictionary?
        precondition(rowScript.executeAndReturnError(&rowError).stringValue == "1\t2\tTitle\thttps://fixture.test/",
            "Chrome's AppleScript rows must contain real tab delimiters, not the Chrome tab class")

        let historyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rota-ChromeHistory-\(UUID().uuidString)", isDirectory: true)
        let historyProfile = historyRoot.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: historyProfile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: historyRoot) }
        var historyDB: OpaquePointer?
        precondition(sqlite3_open(historyProfile.appendingPathComponent("History").path, &historyDB) == SQLITE_OK)
        precondition(sqlite3_exec(historyDB, """
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE visits(url INTEGER, visit_time INTEGER);
            INSERT INTO urls VALUES (1, 'https://fixture.test/older'), (2, 'https://fixture.test/newer');
            INSERT INTO visits VALUES (1, 5), (1, 10), (2, 20);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(historyDB)
        let workProfile = historyRoot.appendingPathComponent("Profile 2", isDirectory: true)
        try FileManager.default.createDirectory(at: workProfile, withIntermediateDirectories: true)
        precondition(sqlite3_open(workProfile.appendingPathComponent("History").path, &historyDB) == SQLITE_OK)
        precondition(sqlite3_exec(historyDB, """
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE visits(url INTEGER, visit_time INTEGER);
            INSERT INTO urls VALUES (1, 'https://fixture.test/older');
            INSERT INTO visits VALUES (1, 4);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(historyDB)
        let localState = ["profile": ["info_cache": ["Default": ["name": "Home"],
                                                      "Profile 2": ["name": "Work"]]]]
        try JSONSerialization.data(withJSONObject: localState).write(to: historyRoot.appendingPathComponent("Local State"))
        let historyTabs = [
            ChromeRecentTab(windowIndex: 1, tabIndex: 1, title: "Active", url: "https://fixture.test/active"),
            ChromeRecentTab(windowIndex: 1, tabIndex: 2, title: "Older", url: "https://fixture.test/older"),
            ChromeRecentTab(windowIndex: 1, tabIndex: 3, title: "Newer", url: "https://fixture.test/newer")]
        let historyVisits = ChromeLocalHistory.lastVisits(for: historyTabs, profileRoot: historyRoot)
        precondition(historyVisits["https://fixture.test/older"] == 10 && historyVisits["https://fixture.test/newer"] == 20)
        let profileVisits = ChromeLocalHistory.profileVisits(for: historyTabs, profileRoot: historyRoot)
        precondition(profileVisits["https://fixture.test/newer"]?.name == "Home")
        precondition(profileVisits["https://fixture.test/newer"]?.isEstimated == false)
        precondition(profileVisits["https://fixture.test/older"]?.name == "Home")
        precondition(profileVisits["https://fixture.test/older"]?.isEstimated == true,
            "A URL seen in multiple profiles must not be presented as an exact match")
        precondition(profileVisits["https://fixture.test/active"] == nil,
            "Never invent a profile for an unrecorded tab")
        precondition(ChromeLocalHistory.historyFirst(historyTabs, lastVisits: historyVisits).map(\.title) == ["Active", "Newer", "Older"],
            "Only open tabs are ranked; the current tab stays first")

        let suite = "Rota.BrowserDispatch.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "migration.rota.v1")
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: preferences)
        store.settings.enabled = true
        let hid = NavigatorHIDManager(store: store)
        var opened: [(URL, URL)] = []
        hid.browserURLDispatcher.applicationURL = { id in precondition(id == "test.browser"); return browser }
        hid.browserURLDispatcher.validateApplication = { $0 == browser && $1 == "test.browser" }
        hid.browserURLDispatcher.openDefault = { _ in preconditionFailure("Targeted routes must never use default browser") }
        hid.browserURLDispatcher.onFailure = { preconditionFailure($0) }
        hid.browserURLDispatcher.openTargeted = { opened.append(($0, $1)); $2(nil) }
        var action = BindingAction.openURL(url.absoluteString)
        action.targetBrowserBundleID = "test.browser"
        hid.executeBindingAction(action)
        hid.executeBindingAction(action, fromKeyboard: true)
        precondition(opened.count == 2, "Gesture and keyboard executor routes both preserve browser target")

        let controller = AppExplorerController(defaults: preferences)
        controller.frontmostPID = { 4242 }
        controller.frontmostBundleID = { "test.source" }
        controller.contextIsValid = { true }
        controller.onBindingAction = { hid.executeBindingAction($0) }
        controller.onKeyboardBindingAction = { hid.executeBindingAction($0, fromKeyboard: true) }
        var favorite = action.favorite(at: .up)!
        let key = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
        favorite.activationShortcut = key
        controller.configuration = { AppExplorerSettings(favorites: [favorite]) }
        func report(_ y: Double?) -> TrackpadReport {
            TrackpadReport(contacts: y.map { [FingerContact(id: 1, x: 500, y: $0, touching: true, confident: true)] } ?? [],
                           buttonDown: false, scanTime: 0)
        }
        controller.show(waitingForLift: false)
        controller.process(report(500)); controller.process(report(400)); controller.process(report(nil))
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(opened.count == 3, "Targeted favorite selection must retain its assigned browser action")
        controller.show(waitingForLift: false)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        precondition(controller.processLayerKey(event))
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(opened.count == 4, "Targeted favorite keyboard activation must retain its browser action")
        precondition(opened.allSatisfy { $0.0 == url && $0.1 == browser })
        store.settings.enabled = false
        hid.executeBindingAction(action)
        precondition(opened.count == 4, "Disabled input must not launch browsers")
        print("Browser URL dispatch passed: explicit targets, unchanged default route, errors without fallback, gesture/keyboard/favorite routes, disabled input. No applications launched.")
    }
}
