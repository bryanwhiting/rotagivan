import AppKit

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
    var openChrome: (URL, @escaping @MainActor (Int?) -> Void) -> Void = { url, completion in
        ChromeBookmarkTabs.shared.open(url, completion: completion)
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
            openChrome(url) { [weak self] code in
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
    private let queue = DispatchQueue(label: "Rotagivan.ChromeBookmarkTabs", qos: .userInitiated)
    private var lastTabs: [String: String] = [:] // queue-confined, never synced
    typealias Runner = (String) -> (tabID: String?, error: Int?)
    private let run: Runner

    init(run: @escaping Runner = ChromeBookmarkTabs.execute) { self.run = run }

    func open(_ url: URL, completion: @escaping @MainActor (Int?) -> Void) {
        queue.async { [self] in
            let key = url.absoluteString
            let result = run(Self.script(url: key, preferredTab: lastTabs[key] ?? ""))
            if let tab = result.tabID, result.error == nil {
                if lastTabs.count >= 1_000 && lastTabs[key] == nil { lastTabs.removeAll(keepingCapacity: true) }
                lastTabs[key] = tab
            }
            Task { @MainActor in completion(result.error) }
        }
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

    static func script(url: String, preferredTab: String) -> String {
        // Chrome adds '/' to bare origins. Keep query and fragment intact.
        var parts = URLComponents(string: url)
        if parts?.path.isEmpty == true { parts?.path = "/" }
        let normalizedURL = parts?.url?.absoluteString ?? url
        return """
        set requestedURL to \(literal(url))
        set normalizedURL to \(literal(normalizedURL))
        set preferredID to \(literal(preferredTab))
        with timeout of 15 seconds
            tell application "Google Chrome"
                -- First recover our last selection, then any existing exact match.
                repeat with passNumber from 1 to 2
                    repeat with w in windows
                        if mode of w is "normal" then
                            set tabNumber to 0
                            repeat with t in tabs of w
                                set tabNumber to tabNumber + 1
                                if URL of t is requestedURL or URL of t is normalizedURL then
                                    if passNumber is 2 or (id of t as text) is preferredID then
                                        set selectedID to id of t as text
                                        set active tab index of w to tabNumber
                                        set minimized of w to false
                                        set index of w to 1
                                        activate
                                        return selectedID
                                    end if
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
