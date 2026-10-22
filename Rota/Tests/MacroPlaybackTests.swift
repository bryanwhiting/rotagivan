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
        precondition(!MacroStep.app(bundleID: "local.rota", name: "Self").isValid)
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
        // Typed-text steps post the string through the type hook, to the same
        // target, between the surrounding chords and delays.
        var typedTexts: [String] = []
        player.type = { text, target in
            precondition(front == target)
            typedTexts.append(text); log.append("text:\(text):\(target)"); return true
        }
        let newline = RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return")
        let launchClaude: [MacroStep] = [.key(RecordedShortcut(keyCode: 45, modifiers: 1 << 20, keyLabel: "N")), .text("claude --continue"), .key(newline)]
        precondition(NamedHotkey(name: "Claude", shortcut: newline, sequence: launchClaude).isValid)
        front = 10; frontBundle = "test.other"; log = []; waits = []
        player.openApp = { bundle, _ in log.append("open:\(bundle)"); front = 40; frontBundle = bundle; return 40 }
        let typedRun = await player.execute(launchClaude, delay: 0.6, target: 10, scope: .app(bundleID: "com.example.slack", name: "Slack"))
        precondition(typedRun && log == ["open:com.example.slack", "key:N:40", "text:claude --continue:40", "key:Return:40"] && waits == [0.6, 0.6, 0.6], "\(log) \(waits)")
        precondition(typedTexts == ["claude --continue"])
        log = []; front = 10
        player.type = { _, _ in false }
        let typingFailed = await player.execute([.text("claude"), .key(copy)], delay: 0, target: 10)
        precondition(!typingFailed && log.isEmpty, "A failed text step stops the macro before later keys")
        player.type = { _, _ in front = 55; return true }
        let focusMoved = await player.execute([.text("claude"), .key(copy)], delay: 0, target: 10)
        precondition(!focusMoved && log.isEmpty, "Focus leaving during typing cancels the rest")
        let emptyText = await player.execute([.text("")], delay: 0, target: 10)
        let tabbedText = await player.execute([.text("a\tb")], delay: 0, target: 10)
        precondition(!emptyText && !tabbedText, "Invalid text never runs")
        // The default hook builds unicode keyboard events: one down/up pair per
        // character with no modifiers, newlines as Return key events.
        let events = EventPoster.textEvents("hi\n!")
        precondition(events.count == 8, "\(events.count)")
        func typedString(_ event: CGEvent) -> String {
            var length = 0; var units = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
            return String(utf16CodeUnits: units, count: length)
        }
        precondition(events[0].type == .keyDown && events[1].type == .keyUp && typedString(events[0]) == "h" && typedString(events[1]) == "h")
        precondition(typedString(events[2]) == "i" && events[0].flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty)
        precondition(events[4].type == .keyDown && events[4].getIntegerValueField(.keyboardEventKeycode) == 36 && events[5].type == .keyUp && events[5].getIntegerValueField(.keyboardEventKeycode) == 36)
        precondition(typedString(events[6]) == "!" && typedString(events[7]) == "!")
        precondition(EventPoster.textEvents("").isEmpty && EventPoster.textEvents("a\u{07}").isEmpty && EventPoster.textEvents(String(repeating: "x", count: 513)).isEmpty)
        precondition(EventPoster.textEvents("世界").count == 4 && typedString(EventPoster.textEvents("世界")[2]) == "界")
        // Chord pacing: modifier changes and the key down post back-to-back; only
        // the key up waits for the hold, so a chord costs one hold, not 64 ms.
        let chord = EventPoster.shortcutEvents(copy)
        precondition(chord.count == 4 && MacroPlayback.chordGaps(chord) == [0, 0, MacroPlayback.keyHold, 0])
        precondition(MacroPlayback.chordGaps(chord).reduce(0, +) <= 10_000_000, "A chord must finish within 10 ms")
        var posted: [CGEventType] = []
        let chordStart = DispatchTime.now().uptimeNanoseconds
        await MacroPlayback.postChord(chord) { posted.append($0.type) }
        let chordMillis = Double(DispatchTime.now().uptimeNanoseconds - chordStart) / 1e6
        precondition(posted == [.flagsChanged, .keyDown, .keyUp, .flagsChanged] && chordMillis >= 8 && chordMillis < 60, "\(posted) \(chordMillis)")
        precondition(NamedHotkey(name: "Default", shortcut: copy).resolvedDelay == 35, "Default inter-step delay is 35 ms")
        print("Macro playback passed: pack scopes (app/website prefix step), typed-text steps (hook order, failure and focus cancellation, unicode key events), app-before-keys, active apps, delays, failed/misdirected opens, focus cancellation, explicit multi-app sequences, serialization, legacy-compatible data and invalid steps. No apps launched or keys posted.")
    }
}
