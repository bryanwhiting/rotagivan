import AppKit

@main struct BrowserURLDispatcherTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dispatcher = BrowserURLDispatcher()
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

        let suite = "Rotagivan.BrowserDispatch.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "migration.rotagivan.v1")
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
