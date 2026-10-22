import AppKit

@main struct MacroPlaybackTests {
    @MainActor static func main() async throws {
        let copy = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
        let paste = RecordedShortcut(keyCode: 9, modifiers: 1 << 20, keyLabel: "V")
        let app = MacroStep.app(bundleID: "test.editor", name: "Editor")
        let sequence: [MacroStep] = [app, .key(copy), .key(paste)]
        let macro = NamedHotkey(name: "Editor workflow", shortcut: copy, sequence: sequence)
        precondition(macro.isValid && macro.summary == "Open Editor → Cmd+C → Cmd+V")
        let decoded = try JSONDecoder().decode(NamedHotkey.self, from: JSONEncoder().encode(macro))
        precondition(decoded == macro)
        precondition(!MacroStep.app(bundleID: "file:///tmp/tool", name: "Tool").isValid)
        precondition(!MacroStep.app(bundleID: "local.rotagivan", name: "Self").isValid)
        precondition(!MacroStep(kind: .openApp, shortcut: copy, bundleID: "test.editor", appName: "Editor").isValid)
        var ambiguous = macro; ambiguous.steps = [copy]; precondition(!ambiguous.isValid)
        let player = MacroPlayback()
        var front: pid_t? = 10
        var log: [String] = []
        var waits: [TimeInterval] = []
        player.currentApp = { front }
        player.wait = { waits.append($0) }
        player.send = { key, target in
            precondition(front == target)
            log.append("key:\(key.keyLabel):\(target)"); return true
        }
        player.openApp = { bundle, source in
            precondition(bundle == "test.editor" && source == front)
            log.append("open")
            await Task.yield()
            precondition(!log.contains(where: { $0.hasPrefix("key:") }), "No keystroke before launch completes")
            front = 20; return 20
        }
        let opened = await player.execute(sequence, delay: 0.125, target: 10)
        precondition(opened && log == ["open", "key:C:20", "key:V:20"] && waits == [0.125, 0.125])
        // An already-running/active app still completes its open step before keys.
        log = []; waits = []; front = 20
        let active = await player.execute(sequence, delay: 0, target: 20)
        precondition(active && log == ["open", "key:C:20", "key:V:20"])
        // Failure or activation to the wrong app must never send the following keys.
        log = []; front = 10
        player.openApp = { _, _ in nil }
        let failed = await player.execute(sequence, delay: 0, target: 10)
        precondition(!failed && log.isEmpty)
        player.openApp = { _, _ in front = 30; return 20 }
        let wrong = await player.execute(sequence, delay: 0, target: 10)
        precondition(!wrong && log.isEmpty)
        // User focus changes during a configured delay cancel, not retarget.
        front = 10; log = []
        player.wait = { _ in front = 99 }
        let interrupted = await player.execute([.key(copy), .key(paste)], delay: 0.1, target: 10)
        precondition(!interrupted && log == ["key:C:10"])
        // Multiple explicit app switches carry the intended target forward.
        front = 10; log = []; player.wait = { _ in }
        player.openApp = { _, source in front = (source ?? 0) + 1; return front }
        let multiple = await player.execute([app, .key(copy), app, .key(paste)], delay: 0, target: 10)
        precondition(multiple && log == ["key:C:11", "key:V:12"])
        // One keyboard lane serializes whole sequences, not independent steps.
        front = 10; log = []
        player.enqueue([.key(copy), .key(paste)], delay: 0, target: 10)
        player.enqueue([.key(paste), .key(copy)], delay: 0, target: 10)
        while player.running { await Task.yield() }
        precondition(log == ["key:C:10", "key:V:10", "key:V:10", "key:C:10"])
        log = []
        let stale = await player.execute(sequence, delay: 0, target: 99)
        precondition(!stale && log.isEmpty)
        // Pack scopes: the app or website comes to the front as a prefix step
        // in the same lane, and keys target it. An app already in front is not relaunched.
        var frontBundle: String? = "test.other"
        var sites: [String] = []
        player.currentBundleID = { frontBundle }
        player.wait = { waits.append($0) }
        player.openApp = { bundle, source in
            precondition(bundle == "com.example.slack" && source == front)
            log.append("open:\(bundle)"); front = 40; frontBundle = bundle; return 40
        }
        player.openWebsite = { url, source in
            precondition(source == front)
            sites.append(url.absoluteString); log.append("site"); front = 50; frontBundle = "com.google.Chrome"; return 50
        }
        front = 10; log = []; waits = []
        let slack = MacroScope.app(bundleID: "com.example.slack", name: "Slack")
        let launched = await player.execute([.key(copy)], delay: 0.1, target: 10, scope: slack)
        precondition(launched && log == ["open:com.example.slack", "key:C:40"] && waits == [0.1], "\(log) \(waits)")
        log = []; waits = []
        let alreadyFront = await player.execute([.key(copy), .key(paste)], delay: 0.1, target: 40, scope: slack)
        precondition(alreadyFront && log == ["key:C:40", "key:V:40"] && waits == [0.1, 0.1], "No relaunch when the scope is frontmost")
        log = []; front = 10; frontBundle = "test.other"
        let site = await player.execute([.key(copy)], delay: 0, target: 10, scope: .website(URL(string: "https://mail.google.com")!))
        precondition(site && sites == ["https://mail.google.com"] && log == ["site", "key:C:50"])
        log = []; front = 10; frontBundle = "test.other"
        player.openWebsite = { _, _ in nil }
        let noSite = await player.execute([.key(copy)], delay: 0, target: 10, scope: .website(URL(string: "https://mail.google.com")!))
        precondition(!noSite && log.isEmpty)
        player.openApp = { _, _ in front = 77; return 40 }
        let wrongFront = await player.execute([.key(copy)], delay: 0, target: 10, scope: slack)
        precondition(!wrongFront && log.isEmpty, "Focus elsewhere after launch cancels")
        let staleSource = await player.execute([.key(copy)], delay: 0, target: 99, scope: slack)
        precondition(!staleSource && log.isEmpty, "Stale source cancels before any launch")
        front = 10; frontBundle = "test.other"; log = []
        player.openApp = { bundle, _ in front = 40; frontBundle = bundle; return 40 }
        player.enqueue([.key(copy)], delay: 0, target: 10, scope: slack)
        while player.running { await Task.yield() }
        precondition(log == ["key:C:40"], "Scoped jobs run through the serial lane")
        print("Macro playback passed: pack scopes (app/website prefix step), app-before-keys, active apps, delays, failed/misdirected opens, focus cancellation, explicit multi-app sequences, serialization, legacy-compatible data and invalid steps. No apps launched or keys posted.")
    }
}
