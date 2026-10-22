import Foundation
import ConfigurationYAML

@main struct MacroPackTests {
    static func rejected(_ yaml: String, _ fragment: String, _ label: String) {
        do { _ = try MacroPack.parse(yaml); fatalError("Accepted invalid pack: \(label)") }
        catch {
            precondition(error.localizedDescription.contains(fragment), "\(label): expected “\(fragment)” in “\(error.localizedDescription)”")
            print("Rejected \(label)")
        }
    }

    static func main() throws {
        // Chord parser: every documented spelling, modifiers in any order, symbols.
        let cmd: UInt64 = 1 << 20, shift: UInt64 = 1 << 17, opt: UInt64 = 1 << 19, ctrl: UInt64 = 1 << 18
        let table: [(String, UInt16, UInt64, String)] = [
            ("cmd+k", 40, cmd, "K"), ("Cmd+Shift+K", 40, cmd | shift, "K"), ("shift+cmd+k", 40, cmd | shift, "K"),
            ("⌘⇧K", 40, cmd | shift, "K"), ("⌘+⌥+i", 34, cmd | opt, "I"), ("command+option+control+shift+a", 0, cmd | opt | ctrl | shift, "A"),
            ("alt+shift+down", 125, opt | shift, "↓"), ("ctrl+tab", 48, ctrl, "Tab"), ("esc", 53, 0, "Escape"),
            ("escape", 53, 0, "Escape"), ("shift+esc", 53, shift, "Escape"), ("return", 36, 0, "Return"), ("enter", 76, 0, "Enter"),
            ("cmd+return", 36, cmd, "Return"), ("space", 49, 0, "Space"), ("delete", 51, 0, "Delete"), ("backspace", 51, 0, "Delete"),
            ("forwarddelete", 117, 0, "Forward Delete"), ("left", 123, 0, "←"), ("right", 124, 0, "→"), ("up", 126, 0, "↑"),
            ("down", 125, 0, "↓"), ("home", 115, 0, "Home"), ("end", 119, 0, "End"), ("pageup", 116, 0, "Page Up"),
            ("pagedown", 121, 0, "Page Down"), ("f1", 122, 0, "F1"), ("F12", 111, 0, "F12"), ("f17", 64, 0, "F17"), ("f20", 90, 0, "F20"),
            ("cmd+,", 43, cmd, ","), (".", 47, 0, "."), ("/", 44, 0, "/"), (";", 41, 0, ";"), ("'", 39, 0, "'"), ("cmd+[", 33, cmd, "["),
            ("cmd+]", 30, cmd, "]"), ("\\", 42, 0, "\\"), ("-", 27, 0, "-"), ("cmd+=", 24, cmd, "="), ("`", 50, 0, "`"),
            ("1", 18, 0, "1"), ("0", 29, 0, "0"), ("cmd+5", 23, cmd, "5"), ("n", 45, 0, "N"), (" cmd + n ", 45, cmd, "N")
        ]
        for (chord, code, modifiers, label) in table {
            let parsed = KeyChord.parse(chord)
            precondition(parsed == RecordedShortcut(keyCode: code, modifiers: modifiers, keyLabel: label), "Chord \(chord) → \(String(describing: parsed))")
            precondition(parsed!.isPhysicalShortcut)
        }
        // Every key in the table has a unique code and a unique name, and formats back to itself.
        precondition(Set(KeyChord.keys.map(\.code)).count == KeyChord.keys.count)
        precondition(Set(KeyChord.keys.map(\.name)).count == KeyChord.keys.count)
        for key in KeyChord.keys {
            let shortcut = RecordedShortcut(keyCode: key.code, modifiers: cmd | shift, keyLabel: key.label)
            precondition(KeyChord.format(shortcut) == "shift+cmd+" + key.name)
            precondition(KeyChord.parse(KeyChord.format(shortcut)!) == shortcut, "Round trip \(key.name)")
        }
        precondition(KeyChord.format(RecordedShortcut(keyCode: 71, modifiers: 0, keyLabel: "Clear")) == nil, "Keys outside the vocabulary have no spelling")
        precondition(KeyChord.format(.macro(NamedHotkey(name: "x", shortcut: RecordedShortcut(keyCode: 40, modifiers: 0, keyLabel: "K")))) == nil)
        let chordErrors: [(String, String)] = [
            ("", "empty"), ("cmd+", "empty part"), ("+k", "empty part"), ("cmd+shift", "no key"), ("cmd+foo", "unknown key “foo”"),
            ("super+k", "unknown modifier “super”"), ("k+cmd", "before its modifiers"), ("cmd+cmd+k", "repeats"), ("cmd", "no key")
        ]
        for (chord, fragment) in chordErrors {
            precondition(KeyChord.parse(chord) == nil, "Accepted bad chord \(chord)")
            do { _ = try KeyChord.parseStrictly(chord); fatalError("Accepted bad chord \(chord)") }
            catch { precondition(error.localizedDescription.contains(fragment), "\(chord): \(error.localizedDescription)") }
        }

        // Bundled packs parse, are scoped, and produce a valid macro library.
        let directory = URL(fileURLWithPath: "Rotagivan/MacroPacks", isDirectory: true)
        let builtIn = MacroPack.builtInPacks(directory: directory)
        precondition(builtIn.map(\.name) == ["Gmail", "Google Chrome", "Slack"], "\(builtIn.map(\.name))")
        precondition(MacroPack.builtInPacks(directory: nil).isEmpty && MacroPack.builtInPacks(directory: URL(fileURLWithPath: "/nonexistent")).isEmpty)
        var library: [NamedHotkey] = []
        for pack in builtIn {
            let parsed = try MacroPack.parse(contentsOf: pack.url)
            precondition(parsed.name == pack.name && parsed.scope != nil && !parsed.macros.isEmpty)
            let macros = parsed.namedHotkeys()
            precondition(macros.allSatisfy(\.isValid) && macros.allSatisfy { $0.packName == parsed.name && $0.sequence != nil && $0.steps == nil })
            precondition(macros.allSatisfy { $0.id.hasPrefix("pack:" + MacroPack.slug(parsed.name) + ":") })
            precondition(macros.allSatisfy { $0.scope == parsed.scope })
            library = try library.importing(parsed).macros
        }
        precondition(library.isValidDictionary, "Three packs coexist even where chords repeat across packs (cmd+shift+t)")
        let slack = try MacroPack.parse(contentsOf: directory.appendingPathComponent("slack.yaml"))
        precondition(slack.appBundleID == "com.tinyspeck.slackmacgap" && slack.appName == "Slack" && slack.website == nil && slack.notes != nil)
        precondition(slack.macros.count >= 12)
        precondition(slack.macros.first { $0.name == "Jump to a conversation" }?.steps == [RecordedShortcut(keyCode: 40, modifiers: cmd, keyLabel: "K")])
        let thread = slack.macros.first { $0.name == "Reply in thread, then jump back" }!
        precondition(thread.steps.count == 2 && thread.delay == 120)
        let threadMacro = slack.namedHotkeys().first { $0.name == thread.name }!
        precondition(threadMacro.resolvedDelay == 120 && threadMacro.summary == "Cmd+Shift+T → Escape")
        precondition(threadMacro.scope == .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack") && threadMacro.scope?.title == "Slack")
        let chrome = try MacroPack.parse(contentsOf: directory.appendingPathComponent("chrome.yaml"))
        precondition(chrome.appBundleID == "com.google.Chrome" && chrome.macros.count >= 10)
        let gmail = try MacroPack.parse(contentsOf: directory.appendingPathComponent("gmail.yaml"))
        precondition(gmail.website == "https://mail.google.com" && gmail.appBundleID == nil && gmail.macros.count >= 8)
        precondition(gmail.notes?.contains("keyboard shortcuts") == true, "Gmail notes must say shortcuts need enabling")
        precondition(gmail.scope == .website(URL(string: "https://mail.google.com")!) && gmail.scope?.title == "mail.google.com")
        let inbox = gmail.namedHotkeys().first { $0.name == "Go to Inbox" }!
        precondition(inbox.summary == "G → I" && inbox.website == "https://mail.google.com" && inbox.appBundleID == nil && inbox.appName == nil)
        precondition(gmail.namedHotkeys().allSatisfy { $0.scope == gmail.scope })

        // Deterministic ids and slugs.
        precondition(MacroPack.slug("Reply in thread, then jump back!") == "reply-in-thread-then-jump-back")
        precondition(MacroPack.slug("  Résumé ✨ Über ") == "resume-uber" && MacroPack.slug("✨") == "macro")
        precondition(MacroPack.macroID(pack: "Slack", macro: "Jump to a conversation") == "pack:slack:jump-to-a-conversation")
        precondition(MacroPack.macroID(pack: String(repeating: "p", count: 100), macro: String(repeating: "m", count: 200)).count <= 128)

        // Re-importing updates in place, keeps the user's global hotkey, and never duplicates.
        let original = try MacroPack.parse("""
        format: rotagivan-macro-pack/1
        name: Demo
        app: com.example.demo
        macros:
          - name: First
            keys: cmd+1
          - name: Second
            steps: [cmd+2, cmd+3]
            delay: 50
        """)
        var macros: [NamedHotkey] = [NamedHotkey(name: "Mine", shortcut: RecordedShortcut(keyCode: 40, modifiers: cmd, keyLabel: "K"))]
        let first = try macros.importing(original)
        macros = first.macros
        precondition(first.result.added == 2 && first.result.updated == 0 && macros.count == 3)
        precondition(first.result.message == "Imported 2 macros from Demo (0 updated)")
        let trigger = RecordedShortcut(keyCode: 64, modifiers: cmd, keyLabel: "F17")
        macros[1].activationShortcut = trigger
        let changed = try MacroPack.parse("""
        format: rotagivan-macro-pack/1
        name: Demo
        app: com.example.demo
        appName: Demo App
        macros:
          - name: First
            keys: cmd+shift+1
          - name: Third
            keys: cmd+4
        """)
        let second = try macros.importing(changed)
        macros = second.macros
        precondition(second.result.added == 1 && second.result.updated == 1 && macros.count == 4)
        precondition(second.result.message == "Imported 2 macros from Demo (1 updated)")
        let updated = macros.first { $0.id == MacroPack.macroID(pack: "Demo", macro: "First") }!
        precondition(updated.resolvedSequence.first?.shortcut?.modifiers == cmd | shift, "Re-import replaces the keystrokes")
        precondition(updated.activationShortcut == trigger, "Re-import keeps the assigned global hotkey")
        precondition(updated.appName == "Demo App" && macros.filter { $0.packName == "Demo" }.count == 3)
        precondition(macros.isValidDictionary && macros[0].name == "Mine" && macros[0].packName == nil)
        precondition(macros.first { $0.name == "Second" }?.resolvedDelay == 50)
        var capacity = (0..<499).map { NamedHotkey(id: "m\($0)", name: "M\($0)", shortcut: RecordedShortcut(keyCode: 0, modifiers: cmd, keyLabel: "A"), sequence: [.key(RecordedShortcut(keyCode: 0, modifiers: cmd, keyLabel: "A"))]) }
        precondition(capacity.isValidDictionary)
        do { _ = try capacity.importing(original); fatalError("Accepted import over 500 macros") }
        catch { precondition(error.localizedDescription.contains("500")) }
        capacity.removeLast(); let full = try capacity.importing(original); precondition(full.macros.count == 500)

        // Scope validation on the macro itself.
        var scoped = NamedHotkey(name: "Scoped", shortcut: RecordedShortcut(keyCode: 38, modifiers: cmd, keyLabel: "J"))
        precondition(scoped.isValid && scoped.scope == nil && scoped.hasValidPackMetadata)
        scoped.website = "https://mail.google.com"; precondition(scoped.isValid && scoped.scope?.title == "mail.google.com")
        scoped.website = "mail.google.com"; precondition(!scoped.isValid, "A website needs a scheme")
        scoped.website = "ftp://mail.google.com"; precondition(!scoped.isValid)
        scoped.website = "https://"; precondition(!scoped.isValid, "A website needs a host")
        scoped.website = "https://user:secret@mail.google.com"; precondition(!scoped.isValid, "No embedded credentials")
        scoped.website = "https://" + String(repeating: "a", count: 520) + ".com"; precondition(!scoped.isValid)
        scoped.website = "https://mail.google.com"; scoped.appBundleID = "com.google.Chrome"; precondition(!scoped.isValid, "Not both scopes")
        scoped.website = nil; precondition(scoped.isValid && scoped.scope == .app(bundleID: "com.google.Chrome", name: "com.google.Chrome"))
        scoped.appName = "Chrome"; precondition(scoped.scope == .app(bundleID: "com.google.Chrome", name: "Chrome"))
        scoped.appBundleID = "Chrome"; precondition(!scoped.isValid, "A bundle ID contains a dot")
        scoped.appBundleID = "local.rotagivan"; precondition(!scoped.isValid)
        scoped.appBundleID = "com." + String(repeating: "x", count: 260); precondition(!scoped.isValid)
        scoped.appBundleID = "com.google.Chrome"; scoped.packName = " "; precondition(!scoped.isValid)
        scoped.packName = "Chrome\u{07}"; precondition(!scoped.isValid)
        scoped.packName = "Chrome"; scoped.appName = ""; precondition(!scoped.isValid)
        scoped.appName = nil; precondition(scoped.isValid)
        var settings = StoredSettings(); settings.hotkeyDictionary = [scoped]
        precondition(settings.resolvedHotkeyDictionary.isValidDictionary)

        // Pack parse errors name the macro and the chord.
        rejected("format: rotagivan-macro-pack/2\nname: X\nmacros:\n  - name: A\n    keys: cmd+k\n", "format", "unsupported format")
        rejected("name: X\nmacros:\n  - name: A\n    keys: cmd+k\n", "format", "missing format")
        rejected("format: rotagivan-macro-pack/1\nmacros:\n  - name: A\n    keys: cmd+k\n", "needs a name", "missing name")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros: []\n", "at least one", "empty macros")
        rejected("format: rotagivan-macro-pack/1\nname: X\n", "macros", "missing macros")
        rejected("format: rotagivan-macro-pack/1\nname: X\ncolor: red\nmacros:\n  - name: A\n    keys: cmd+k\n", "Unknown key “color”", "unknown pack key")
        rejected("format: rotagivan-macro-pack/1\nname: X\napp: Slack\nmacros:\n  - name: A\n    keys: cmd+k\n", "bundle ID", "bad bundle id")
        rejected("format: rotagivan-macro-pack/1\nname: X\nwebsite: slack.com\nmacros:\n  - name: A\n    keys: cmd+k\n", "http(s)", "bad website")
        rejected("format: rotagivan-macro-pack/1\nname: X\napp: com.a.b\nwebsite: https://a.b\nmacros:\n  - name: A\n    keys: cmd+k\n", "not both", "two scopes")
        rejected("format: rotagivan-macro-pack/1\nname: X\nappName: A\nmacros:\n  - name: A\n    keys: cmd+k\n", "appName only applies", "appName without app")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: A\n    keys: cmd+k\n  - name: Reply\n    keys: cmd+foo\n", "Macro 2 “Reply”: unknown key “foo” in “cmd+foo”", "bad chord names the macro")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: Reply\n    steps: [cmd+k, shift+bogus]\n", "Macro 1 “Reply” step 2: unknown key “bogus”", "bad step names the step")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: Reply\n    keys: cmd+k\n    steps: [esc]\n", "both keys and steps", "keys and steps")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: Reply\n", "needs keys", "no keys")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: Reply\n    keys: cmd+k\n    delay: 5000\n", "delay", "delay out of range")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: Reply\n    keys: cmd+k\n    delay: 1.5\n", "delay", "fractional delay")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: Reply\n    keys: cmd+k\n    colour: red\n", "Unknown key “colour” in Macro 1", "unknown macro key")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: Same\n    keys: cmd+k\n  - name: same!\n    keys: cmd+j\n", "repeats another macro's name", "duplicate names by slug")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: Long\n    steps: [" + Array(repeating: "cmd+k", count: 33).joined(separator: ", ") + "]\n", "limit is 32", "too many steps")
        rejected("- just\n- a list\n", "mapping", "not a mapping")
        rejected("format: [a, b]\nname: X\nmacros: []\n", "format", "format not a string")
        rejected("format: rotagivan-macro-pack/1\nname: X\nmacros:\n  - name: &a A\n    keys: *a\n", "YAML", "anchors rejected")

        // Export round trip through YAML, including scope, notes and delays.
        var pack = try MacroPack(name: "Demo", exporting: macros.filter { $0.packName == "Demo" })
        pack.notes = "Needs the Demo app."
        let yaml = try pack.yaml()
        precondition(yaml.hasPrefix("# Rotagivan macro pack"))
        let reparsed = try MacroPack.parse(yaml)
        precondition(reparsed == pack, "\(yaml)")
        precondition(reparsed.namedHotkeys() == pack.namedHotkeys())
        var openApp = NamedHotkey(name: "Open", shortcut: RecordedShortcut(keyCode: 40, modifiers: cmd, keyLabel: "K"))
        openApp.sequence = [.app(bundleID: "com.example.demo", name: "Demo"), .key(openApp.shortcut)]
        do { _ = try MacroPack(name: "Demo", exporting: [openApp]); fatalError("Exported an open-app macro") }
        catch { precondition(error.localizedDescription.contains("opens an app")) }
        let unknownKey = NamedHotkey(name: "Clear", shortcut: RecordedShortcut(keyCode: 71, modifiers: 0, keyLabel: "Clear"))
        do { _ = try MacroPack(name: "Demo", exporting: [unknownKey]); fatalError("Exported a key with no spelling") }
        catch { precondition(error.localizedDescription.contains("no pack spelling")) }
        for builtInPack in builtIn {
            let parsed = try MacroPack.parse(contentsOf: builtInPack.url)
            let exported = try MacroPack(name: parsed.name, exporting: parsed.namedHotkeys())
            let survived = try MacroPack.parse(exported.yaml()).namedHotkeys()
            precondition(survived == parsed.namedHotkeys(), "Bundled pack \(parsed.name) survives export")
        }

        // Whole-configuration YAML round trip carries the new fields, and the
        // configuration validator applies the scope rules.
        var config = AppConfiguration(settings: settings, shortcuts: ShortcutConfiguration())
        config.settings.hotkeyDictionary = macros + [scoped] + library
        config.settings.appOverrides = []
        let body = try config.yaml()
        precondition(body.contains("packName: Slack") && body.contains("appBundleID: com.tinyspeck.slackmacgap") && body.contains("website: https://mail.google.com"))
        let restored = try AppConfiguration.parse(body)
        precondition(restored.settings.resolvedHotkeyDictionary == config.settings.resolvedHotkeyDictionary)
        precondition(restored.settings.resolvedHotkeyDictionary.contains { $0.scope == .website(URL(string: "https://mail.google.com")!) })
        var broken = config; broken.settings.hotkeyDictionary?[0].website = "not a url"
        do { _ = try broken.yaml(); fatalError("Exported an invalid website scope") } catch { print("Rejected invalid website scope on export") }
        do { _ = try AppConfiguration.parse(body.replacingOccurrences(of: "website: https://mail.google.com", with: "website: mail.google.com")); fatalError("Accepted invalid website scope") }
        catch { print("Rejected invalid website scope on import") }
        do { _ = try AppConfiguration.parse(body.replacingOccurrences(of: "packName: Slack", with: "packColour: Slack")); fatalError("Accepted unknown macro key") }
        catch { precondition(error.localizedDescription.contains("packColour")); print("Rejected unknown macro key") }
        let legacy = try AppConfiguration.parse(body.components(separatedBy: "\n").filter { !$0.hasSuffix("packName: Slack") }.joined(separator: "\n"))
        precondition(legacy.settings.resolvedHotkeyDictionary.contains { $0.appBundleID == "com.tinyspeck.slackmacgap" && $0.packName == nil })
        let plain = try JSONDecoder().decode(NamedHotkey.self, from: Data(#"{"id":"a","name":"A","shortcut":{"keyCode":40,"modifiers":1048576,"keyLabel":"K"}}"#.utf8))
        precondition(plain.isValid && plain.packName == nil && plain.scope == nil, "Existing macros decode unchanged")
        print("Macro pack tests passed: chord table and errors, three bundled packs, deterministic ids, in-place re-import, scope validation, export round trip and configuration YAML round trip.")
    }
}
