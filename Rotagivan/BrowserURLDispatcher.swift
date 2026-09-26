import AppKit

/// Explicit browser targets never fall back to the user's default browser.
@MainActor final class BrowserURLDispatcher {
    var applicationURL: (String) -> URL? = { ExplorerApplicationCatalog.applicationURL(for: $0) }
    var validateApplication: (URL, String) -> Bool = { url, bundleID in
        ExplorerApplicationCatalog.application(at: url)?.bundleID == bundleID
    }
    var openDefault: (URL) -> Bool = { NSWorkspace.shared.open($0) }
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
