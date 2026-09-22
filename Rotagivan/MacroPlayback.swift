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
    private struct Job { let steps: [MacroStep]; let delay: TimeInterval; let target: pid_t? }
    private var jobs: [Job] = []
    private(set) var running = false

    func enqueue(_ steps: [MacroStep], delay: TimeInterval, target: pid_t?) {
        guard jobs.count < 32, !steps.isEmpty, steps.count <= 32, steps.allSatisfy(\.isValid),
              delay.isFinite, (0...2).contains(delay) else { return }
        jobs.append(Job(steps: steps, delay: delay, target: target))
        guard !running else { return }
        running = true
        Task {
            while !jobs.isEmpty {
                let job = jobs.removeFirst()
                _ = await execute(job.steps, delay: job.delay, target: job.target)
            }
            running = false
        }
    }

    @discardableResult func execute(_ steps: [MacroStep], delay: TimeInterval, target initialTarget: pid_t?) async -> Bool {
        guard !steps.isEmpty, steps.count <= 32, steps.allSatisfy(\.isValid), delay.isFinite, (0...2).contains(delay) else { return false }
        var target = initialTarget
        for (index, step) in steps.enumerated() {
            if index > 0 { await wait(delay) }
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
