import AppKit

/// One serial keyboard lane for gestures and HUD tiles. Waiting for an app or
/// an inter-step delay suspends work; it never blocks input handling or the UI.
@MainActor final class MacroPlayback {
    static let shared = MacroPlayback()
    var currentApp: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var openApp: (String, pid_t?) async -> pid_t? = { await MacroApplicationLauncher.open($0, source: $1) }
    var send: (RecordedShortcut, pid_t) async -> Bool = { shortcut, target in
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { return false }
        let events = EventPoster.shortcutEvents(shortcut, heldFlags: CGEventSource.flagsState(.hidSystemState))
        guard !events.isEmpty else { return false }
        // Finish each chord's releases even if focus changes mid-chord.
        for (index, event) in events.enumerated() {
            if index > 0 { try? await Task.sleep(nanoseconds: event.type == .keyUp ? 40_000_000 : 12_000_000) }
            event.post(tap: .cghidEventTap)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target
    }
    var wait: (TimeInterval) async -> Void = { delay in
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
    var currentBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// Brings a website to the front (reusing an open tab when the browser
    /// integration offers one) and returns the browser's pid once it is frontmost.
    var openWebsite: (URL, pid_t?) async -> pid_t? = { await MacroWebsiteLauncher.open($0, source: $1) }
    private struct Job { let steps: [MacroStep]; let delay: TimeInterval; let target: pid_t?; let scope: MacroScope? }
    private var jobs: [Job] = []
    private(set) var running = false

    func enqueue(_ steps: [MacroStep], delay: TimeInterval, target: pid_t?, scope: MacroScope? = nil) {
        guard jobs.count < 32, !steps.isEmpty, steps.count <= 32, steps.allSatisfy(\.isValid),
              delay.isFinite, (0...2).contains(delay) else { return }
        jobs.append(Job(steps: steps, delay: delay, target: target, scope: scope))
        guard !running else { return }
        running = true
        Task {
            while !jobs.isEmpty {
                let job = jobs.removeFirst()
                _ = await execute(job.steps, delay: job.delay, target: job.target, scope: job.scope)
            }
            running = false
        }
    }

    /// A scoped macro first brings its app or website to the front, as a prefix
    /// step in the same serial lane, so every keystroke targets that app.
    @discardableResult func execute(_ steps: [MacroStep], delay: TimeInterval, target initialTarget: pid_t?, scope: MacroScope? = nil) async -> Bool {
        guard !steps.isEmpty, steps.count <= 32, steps.allSatisfy(\.isValid), delay.isFinite, (0...2).contains(delay) else { return false }
        var target = initialTarget
        if let scope {
            guard currentApp() == target else { return false }
            switch scope {
            case .app(let bundleID, _):
                if currentBundleID() == bundleID, let front = currentApp() { target = front }
                else {
                    guard let opened = await openApp(bundleID, target), currentApp() == opened else { return false }
                    target = opened
                }
            case .website(let url):
                guard let opened = await openWebsite(url, target), currentApp() == opened else { return false }
                target = opened
            }
        }
        for (index, step) in steps.enumerated() {
            if index > 0 || scope != nil { await wait(delay) }
            guard currentApp() == target else { return false }
            switch step.kind {
            case .openApp:
                guard let bundleID = step.bundleID, let opened = await openApp(bundleID, target), currentApp() == opened else { return false }
                target = opened
            case .keystroke:
                guard let target, let shortcut = step.shortcut, await send(shortcut, target) else { return false }
            }
        }
        return true
    }
}

@MainActor enum MacroApplicationLauncher {
    static func open(_ bundleID: String, source: pid_t?) async -> pid_t? {
        let workspace = NSWorkspace.shared
        guard workspace.frontmostApplication?.processIdentifier == source,
              let url = workspace.urlForApplication(withBundleIdentifier: bundleID),
              url.isFileURL, url.pathExtension.lowercased() == "app", Bundle(url: url)?.bundleIdentifier == bundleID else { return nil }
        let pid: pid_t? = await withCheckedContinuation { continuation in
            var finished = false
            var timeout: Task<Void, Never>?
            var focusObserver: NSObjectProtocol?
            func finish(_ pid: pid_t?) {
                guard !finished else { return }
                finished = true; timeout?.cancel()
                if let focusObserver { workspace.notificationCenter.removeObserver(focusObserver) }
                continuation.resume(returning: pid)
            }
            focusObserver = workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    if app.processIdentifier != source && app.bundleIdentifier != bundleID { finish(nil) }
                }
            }
            timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                finish(nil)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            // Launch without stealing focus during startup. Activate explicitly
            // only if the user has not moved to an unrelated app while waiting.
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            workspace.openApplication(at: url, configuration: configuration) { app, error in
                let pid = error == nil ? app?.processIdentifier : nil
                DispatchQueue.main.async {
                    guard !finished else { return }
                    guard let pid, let app = NSRunningApplication(processIdentifier: pid),
                          !app.isTerminated, app.bundleIdentifier == bundleID,
                          workspace.frontmostApplication?.processIdentifier == source || workspace.frontmostApplication?.processIdentifier == pid else { finish(nil); return }
                    guard app.activate(options: []) else { finish(nil); return }
                    finish(pid)
                }
            }
        }
        guard let pid else { return nil }
        // Activation is asynchronous. Require a finished launch and stable focus
        // before handing off to keyboard steps. Never repeatedly steal focus.
        var stable = 0
        for _ in 0..<80 {
            let front = workspace.frontmostApplication?.processIdentifier
            guard front == source || front == pid else { return nil }
            if stable > 0 && front != pid { return nil }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
            if front == pid && app.isFinishedLaunching { stable += 1 } else { stable = 0 }
            if stable >= 4 { return pid }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return nil
    }
}

/// The default website scope: open the URL in its handler and wait for that
/// browser to become frontmost. The HID manager swaps in the Chrome-aware
/// dispatcher, which reuses an open tab on the same site, at startup.
@MainActor enum MacroWebsiteLauncher {
    static func open(_ url: URL, source: pid_t?) async -> pid_t? {
        let workspace = NSWorkspace.shared
        guard workspace.frontmostApplication?.processIdentifier == source,
              let browser = workspace.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: browser)?.bundleIdentifier, workspace.open(url) else { return nil }
        return await waitForFront(bundleID: bundleID, source: source)
    }

    /// Bounded wait (2 s) for `bundleID` to hold stable focus. Focus moving to
    /// any other app means the user went elsewhere; never steal it back.
    static func waitForFront(bundleID: String, source: pid_t?, timeout: TimeInterval = 2) async -> pid_t? {
        let workspace = NSWorkspace.shared
        var stable = 0
        for _ in 0..<max(1, Int(timeout / 0.025)) {
            guard let front = workspace.frontmostApplication else { return nil }
            if front.bundleIdentifier == bundleID {
                stable += 1
                if stable >= 4 { return front.processIdentifier }
            } else if front.processIdentifier != source { return nil }
            else { stable = 0 }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return nil
    }
}
