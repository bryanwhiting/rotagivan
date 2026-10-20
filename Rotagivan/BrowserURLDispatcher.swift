import AppKit
import ApplicationServices
import SQLite3

/// Chrome History records navigations, not switches to an already-open tab.
/// Use it only to order open tabs that Rotagivan has not observed being focused.
/// No history rows are stored by Rotagivan or included in settings sync.
enum ChromeLocalHistory {
    struct ProfileVisit {
        let name: String
        let timestamp: Int64
        let isEstimated: Bool
    }

    static var profileRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    static func lastVisits(for tabs: [ChromeRecentTab], profileRoot: URL = profileRoot) -> [String: Int64] {
        profileVisits(for: tabs, profileRoot: profileRoot).mapValues(\.timestamp)
    }

    /// Chrome's scripting interface does not identify a tab's profile. Associate
    /// open URLs with the profiles whose local History contains them. A URL in
    /// multiple profiles is explicitly marked as an estimate.
    static func profileVisits(for tabs: [ChromeRecentTab], profileRoot: URL = profileRoot) -> [String: ProfileVisit] {
        let urls = Array(Set(tabs.map(\.url).filter { !$0.isEmpty }))
        guard !urls.isEmpty,
              let profiles = try? FileManager.default.contentsOfDirectory(at: profileRoot,
                  includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [:] }
        let names = profileNames(at: profileRoot)
        var visits: [String: ProfileVisit] = [:]
        for profile in profiles where profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile ") {
            let history = profile.appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: history.path) else { continue }
            // Prefer the live read-only connection (which includes WAL data).
            // Chrome can hold an exclusive lock; immutable reads the on-disk
            // checkpoint without waiting or copying private history files.
            let uri = history.absoluteString
            if let rows = read(uri: uri + "?mode=ro", urls: urls)
                ?? read(uri: uri + "?immutable=1", urls: urls) {
                let name = names[profile.lastPathComponent] ?? profile.lastPathComponent
                for (url, time) in rows {
                    if let old = visits[url] {
                        visits[url] = ProfileVisit(name: time > old.timestamp ? name : old.name,
                            timestamp: max(time, old.timestamp), isEstimated: true)
                    } else {
                        visits[url] = ProfileVisit(name: name, timestamp: time, isEstimated: false)
                    }
                }
            }
        }
        return visits
    }

    private static func profileNames(at root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = document["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [:] }
        return cache.compactMapValues { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return name
        }
    }

    private static func read(uri: String, urls: [String]) -> [String: Int64]? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database else { if database != nil { sqlite3_close(database) }; return nil }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var result: [String: Int64] = [:]
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for start in stride(from: 0, to: urls.count, by: 200) {
            let chunk = Array(urls[start..<min(start + 200, urls.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let query = """
                SELECT urls.url, MAX(visits.visit_time)
                FROM urls JOIN visits ON visits.url = urls.id
                WHERE urls.url IN (\(placeholders))
                GROUP BY urls.url
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else { if statement != nil { sqlite3_finalize(statement) }; return nil }
            for (offset, url) in chunk.enumerated() {
                _ = url.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient) }
            }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) {
                    result[String(cString: text)] = sqlite3_column_int64(statement, 1)
                }
                status = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            guard status == SQLITE_DONE else { return nil }
        }
        return result
    }

    static func historyFirst(_ tabs: [ChromeRecentTab], lastVisits: [String: Int64]) -> [ChromeRecentTab] {
        guard let active = tabs.first else { return [] }
        return [active] + tabs.dropFirst().enumerated().sorted { lhs, rhs in
            let left = lastVisits[lhs.element.url] ?? 0
            let right = lastVisits[rhs.element.url] ?? 0
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }
}

/// In-memory tab focus and app activation order on one shared clock, so apps and
/// tabs compare directly. This is HUD state, not Screen Time data: it is never
/// written to disk or included in settings sync.
@MainActor final class ChromeTabRecency {
    static let shared = ChromeTabRecency()
    private var visits: [String: UInt64] = [:]
    private var appVisits: [String: UInt64] = [:]
    private var clock: UInt64 = 0
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var sampling = false
    /// Chrome's focused window title at the last sample. It changes whenever the
    /// selected tab changes, so an unchanged title skips the AppleScript round trip.
    private var lastWindowTitle: String?
    private func key(_ tab: ChromeRecentTab) -> String { tab.url.isEmpty ? tab.id : tab.url }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in ChromeTabRecency.shared.sampleIfChromeIsActive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if let app = NSWorkspace.shared.frontmostApplication { recordApp(app) }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { ChromeTabRecency.shared.recordApp(app) }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
    }

    func recordApp(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let identifier = app.bundleIdentifier else { return }
        recordApp(identifier)
    }

    func recordApp(_ identifier: String) {
        guard identifier != "local.rotagivan" else { return }
        clock &+= 1
        appVisits[identifier] = clock
        if appVisits.count > 512 { appVisits = [identifier: clock] }
        // Stamp the selected tab now rather than at the next two-second sample.
        if identifier == RecentPlaces.chromeBundleID { sampleIfChromeIsActive(force: true) }
    }

    func stamp(app identifier: String) -> UInt64? { appVisits[identifier] }
    func stamp(tab: ChromeRecentTab) -> UInt64? { visits[key(tab)] }

    private func sampleIfChromeIsActive(force: Bool = false) {
        guard !sampling, let chrome = NSWorkspace.shared.frontmostApplication,
              chrome.bundleIdentifier == "com.google.Chrome" else { return }
        // The window title is a cheap Accessibility read; the tab's URL costs an
        // AppleEvent round trip into Chrome, so only pay it when the title moved.
        let title = Self.focusedWindowTitle(pid: chrome.processIdentifier)
        if !force, let title, title == lastWindowTitle { return }
        lastWindowTitle = title
        sampling = true
        Task.detached(priority: .utility) {
            let tab = ChromeBookmarkTabs.activeTab()
            await MainActor.run {
                if let tab { ChromeTabRecency.shared.record(tab) }
                ChromeTabRecency.shared.sampling = false
            }
        }
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    /// The most recently focused tab URL that starts with `prefix`, if any.
    func mostRecentURL(withPrefix prefix: String) -> String? {
        visits.filter { $0.key.hasPrefix(prefix) }.max { $0.value < $1.value }?.key
    }

    func record(_ tab: ChromeRecentTab) {
        let id = key(tab)
        guard visits[id] != clock else { return }
        clock &+= 1
        visits[id] = clock
        if visits.count > 512 { visits = [id: clock] }
    }

    /// The first tab is Chrome's currently selected tab; ties retain tab-strip order.
    /// The selected tab is only a fresh visit while Chrome is frontmost.
    func ranked(_ tabs: [ChromeRecentTab]) -> [ChromeRecentTab] {
        guard let active = tabs.first else { return [] }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == RecentPlaces.chromeBundleID { record(active) }
        return [active] + tabs.dropFirst().enumerated().sorted { lhs, rhs in
            let left = visits[key(lhs.element)] ?? 0
            let right = visits[key(rhs.element)] ?? 0
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }
}

/// Explicit browser targets never fall back to the user's default browser.
@MainActor final class BrowserURLDispatcher {
    var applicationURL: (String) -> URL? = { ExplorerApplicationCatalog.applicationURL(for: $0) }
    var validateApplication: (URL, String) -> Bool = { url, bundleID in
        ExplorerApplicationCatalog.bundleIdentifier(at: url) == bundleID
    }
    var openDefault: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var defaultBrowserBundleID: (URL) -> String? = {
        NSWorkspace.shared.urlForApplication(toOpen: $0).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
    // The second argument is the most recently visited open tab on the bookmark's site.
    var openChrome: (URL, String, @escaping @MainActor (Int?) -> Void) -> Void = { url, recentURL, completion in
        ChromeBookmarkTabs.shared.open(url, recentURL: recentURL, completion: completion)
    }
    var openTargeted: (URL, URL, @escaping @MainActor (Error?) -> Void) -> Void = { url, application, completion in
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { running, error in
            let failure = error ?? (running == nil ? NSError(domain: "Rotagivan.Browser", code: 1) : nil)
            Task { @MainActor in completion(failure) }
        }
    }
    var onFailure: (String) -> Void = { BrowserURLDispatcher.showFailure($0) }
    private static var failurePanel: NSPanel?

    private static func showFailure(_ message: String) {
        failurePanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 155),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Application unavailable"
        panel.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = NSRect(x: 20, y: 57, width: 420, height: 78)
        panel.contentView?.addSubview(label)
        let button = NSButton(title: "OK", target: panel, action: #selector(NSWindow.performClose(_:)))
        button.frame = NSRect(x: 365, y: 15, width: 75, height: 30)
        button.keyEquivalent = "\r"
        panel.contentView?.addSubview(button)
        failurePanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func open(_ url: URL, targetBrowserBundleID: String?) {
        guard AppExplorerFavorite.webURL(url.absoluteString) != nil else { return }
        if targetBrowserBundleID == "com.google.Chrome" ||
            (targetBrowserBundleID == nil && defaultBrowserBundleID(url) == "com.google.Chrome") {
            let recentURL = ChromeTabRecency.shared.mostRecentURL(withPrefix: ChromeBookmarkTabs.sitePrefix(url.absoluteString)) ?? ""
            openChrome(url, recentURL) { [weak self] code in
                guard let code else { return }
                self?.onFailure("Could not focus the Chrome bookmark tab. Allow Rotagivan to control Google Chrome in System Settings → Privacy & Security → Automation, then retry. Error code: \(code).")
            }
            return
        }
        guard let targetBrowserBundleID else {
            _ = openDefault(url)
            return
        }
        guard let application = applicationURL(targetBrowserBundleID), application.isFileURL,
              validateApplication(application, targetBrowserBundleID) else {
            onFailure("The selected application (\(targetBrowserBundleID)) is not installed or could not be located. Install it or choose another application in Actions.")
            return
        }
        openTargeted(url, application) { [weak self] error in
            guard let error else { return }
            // Launch Services error text may contain private URL query tokens.
            // Show a useful failure without copying URLs into logs or alerts.
            self?.onFailure("macOS could not open the URL in the selected application (\(targetBrowserBundleID)). Check that the application can be opened, then try again. Error code: \((error as NSError).code).")
        }
    }
}

/// Chrome owns the live tab index. Query it on demand rather than polling browser
/// history. The serial queue makes rapid repeat opens observe the previous result.
final class ChromeBookmarkTabs: @unchecked Sendable {
    static let shared = ChromeBookmarkTabs()
    // Inside `tell application "Google Chrome"`, `tab` resolves to Chrome's
    // tab class, not AppleScript's tab character. Use the explicit character.
    static let appleScriptFieldSeparator = "(ASCII character 9)"
    private let queue = DispatchQueue(label: "Rotagivan.ChromeBookmarkTabs", qos: .userInitiated)
    private var lastTabs: [String: String] = [:] // queue-confined, never synced
    typealias Runner = (String) -> (tabID: String?, error: Int?)
    private let run: Runner

    init(run: @escaping Runner = ChromeBookmarkTabs.execute) { self.run = run }

    func open(_ url: URL, recentURL: String = "", completion: @escaping @MainActor (Int?) -> Void) {
        queue.async { [self] in
            let key = url.absoluteString
            let result = run(Self.script(url: key, preferredTab: lastTabs[key] ?? "", recentURL: recentURL))
            if let tab = result.tabID, result.error == nil {
                if lastTabs.count >= 1_000 && lastTabs[key] == nil { lastTabs.removeAll(keepingCapacity: true) }
                lastTabs[key] = tab
            }
            Task { @MainActor in completion(result.error) }
        }
    }

    static func snapshot() -> [ChromeRecentTab] {
        let source = """
        if application "Google Chrome" is not running then return ""
        set activeOutput to ""
        set otherOutput to ""
        try
            tell application "Google Chrome"
                repeat with w in windows
                    set wi to index of w
                    set activeIndex to active tab index of w
                    -- Two round trips per window instead of two per tab.
                    set tabTitles to title of every tab of w
                    set tabURLs to URL of every tab of w
                    repeat with ti from 1 to count of tabTitles
                        if ti > (count of tabURLs) then exit repeat
                        set rowText to (wi as text) & \(appleScriptFieldSeparator) & (ti as text) & \(appleScriptFieldSeparator) & (item ti of tabTitles) & \(appleScriptFieldSeparator) & (item ti of tabURLs) & linefeed
                        if wi is 1 and ti is activeIndex then
                            set activeOutput to rowText
                        else
                            set otherOutput to otherOutput & rowText
                        end if
                    end repeat
                end repeat
            end tell
        on error
            return ""
        end try
        return activeOutput & otherOutput
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return [] }
        let result = script.executeAndReturnError(&error)
        guard error == nil, let text = result.stringValue, !text.isEmpty else { return [] }
        let tabs: [ChromeRecentTab] = text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let window = Int(fields[0]), let tab = Int(fields[1]) else { return nil }
            return ChromeRecentTab(windowIndex: window, tabIndex: tab, title: String(fields[2]), url: String(fields[3]))
        }
        let visits = ChromeLocalHistory.profileVisits(for: tabs)
        let enriched = tabs.map { tab -> ChromeRecentTab in
            var tab = tab
            tab.profileName = visits[tab.url]?.name
            tab.profileIsEstimated = visits[tab.url]?.isEstimated ?? false
            return tab
        }
        return ChromeLocalHistory.historyFirst(enriched, lastVisits: visits.mapValues(\.timestamp))
    }

    static func activeTab() -> ChromeRecentTab? {
        let source = """
        if application "Google Chrome" is not running then return ""
        try
            tell application "Google Chrome"
                set w to front window
                set ti to active tab index of w
                set t to tab ti of w
                return "1" & \(appleScriptFieldSeparator) & (ti as text) & \(appleScriptFieldSeparator) & (title of t) & \(appleScriptFieldSeparator) & (URL of t)
            end tell
        on error
            return ""
        end try
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil, let text = result.stringValue else { return nil }
        let fields = text.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, let index = Int(fields[1]) else { return nil }
        return ChromeRecentTab(windowIndex: 1, tabIndex: index, title: String(fields[2]), url: String(fields[3]))
    }

    static func activate(_ tab: ChromeRecentTab) -> Bool {
        let source = """
        try
            tell application "Google Chrome"
                if (count of windows) < \(tab.windowIndex) then return false
                set w to window \(tab.windowIndex)
                if (count of tabs of w) < \(tab.tabIndex) then return false
                set t to tab \(tab.tabIndex) of w
                if (URL of t as text) is not \(literal(tab.url)) then return false
                set active tab index of w to \(tab.tabIndex)
                set minimized of w to false
                set index of w to 1
                activate
                return true
            end tell
        on error
            return false
        end try
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    static func execute(_ source: String) -> (tabID: String?, error: Int?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (nil, -2700) }
        let result = script.executeAndReturnError(&error)
        if let error { return (nil, (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -2700) }
        guard let id = result.stringValue, !id.isEmpty else { return (nil, -2700) }
        return (id, nil)
    }

    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// A bookmark covers every tab under its origin and path, so a Gmail bookmark
    /// for https://mail.google.com/ reuses https://mail.google.com/mail/u/0/#inbox.
    static func sitePrefix(_ url: String) -> String {
        guard var parts = URLComponents(string: url), parts.host?.isEmpty == false else { return url }
        parts.query = nil; parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url?.absoluteString ?? url
    }

    static func script(url: String, preferredTab: String, recentURL: String = "") -> String {
        // Chrome adds '/' to bare origins. Keep query and fragment intact.
        var parts = URLComponents(string: url)
        if parts?.path.isEmpty == true { parts?.path = "/" }
        let normalizedURL = parts?.url?.absoluteString ?? url
        return """
        set requestedURL to \(literal(url))
        set normalizedURL to \(literal(normalizedURL))
        set preferredID to \(literal(preferredTab))
        set recentURL to \(literal(recentURL))
        set sitePrefix to \(literal(sitePrefix(url)))
        with timeout of 15 seconds
            tell application "Google Chrome"
                -- Our last selection, any exact match, the most recent tab on the site,
                -- then any tab on the site. Only when none is open does a new tab appear.
                repeat with passNumber from 1 to 4
                    repeat with w in windows
                        if mode of w is "normal" then
                            set tabNumber to 0
                            repeat with t in tabs of w
                                set tabNumber to tabNumber + 1
                                set tabURL to URL of t as text
                                set exactMatch to (tabURL is requestedURL or tabURL is normalizedURL)
                                if (passNumber is 1 and exactMatch and (id of t as text) is preferredID) or (passNumber is 2 and exactMatch) or (passNumber is 3 and recentURL is not "" and tabURL is recentURL) or (passNumber is 4 and tabURL starts with sitePrefix) then
                                    set selectedID to id of t as text
                                    set active tab index of w to tabNumber
                                    set minimized of w to false
                                    set index of w to 1
                                    activate
                                    return selectedID
                                end if
                            end repeat
                        end if
                    end repeat
                end repeat
                set destinationWindow to missing value
                repeat with w in windows
                    if mode of w is "normal" then
                        set destinationWindow to w
                        exit repeat
                    end if
                end repeat
                if destinationWindow is missing value then
                    set destinationWindow to make new window with properties {mode:"normal"}
                    set URL of active tab of destinationWindow to requestedURL
                    set newTab to active tab of destinationWindow
                else
                    set newTab to make new tab at end of tabs of destinationWindow with properties {URL:requestedURL}
                    set active tab index of destinationWindow to count of tabs of destinationWindow
                end if
                set selectedID to id of newTab as text
                set minimized of destinationWindow to false
                set index of destinationWindow to 1
                activate
                return selectedID
            end tell
        end timeout
        """
    }
}
