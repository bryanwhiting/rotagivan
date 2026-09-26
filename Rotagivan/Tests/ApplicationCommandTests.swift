import Foundation

@main struct ApplicationCommandTests {
    @MainActor static func main() throws {
        let chrome = "com.google.Chrome"
        let key = BindingAction.keystroke(RecordedShortcut(keyCode: 3, modifiers: 1 << 20, keyLabel: "F"))
        var command = ApplicationCommand(bundleID: chrome, appName: "Google Chrome", name: "Find project", detail: "Find project text in Chrome.", action: key)
        precondition(command.isValid)
        let originalID = command.voiceActionID
        var settings = StoredSettings()
        settings.applicationCommands = [command]
        settings.actionVocabulary = [ActionVocabulary(actionID: originalID, keywordSets: [["project search", "find my project"]])]
        let all = VoiceActionRegistry.make(settings: settings, includeInactiveApplications: true)
        let active = VoiceActionRegistry.make(settings: settings, activeBundleID: chrome)
        let inactive = VoiceActionRegistry.make(settings: settings, activeBundleID: "com.apple.finder")
        let record = active.first { $0.id == originalID }!
        precondition(record.customCommandID == command.id && record.title == command.name && record.appBundleID == chrome)
        precondition(record.keywordSets == [["project search", "find my project"]])
        var duplicateVocabulary = settings
        duplicateVocabulary.actionVocabulary?.append(ActionVocabulary(actionID: originalID, keywordSets: [["later duplicate"]]))
        precondition(VoiceActionRegistry.make(settings: duplicateVocabulary, activeBundleID: chrome)
            .first { $0.id == originalID }?.keywordSets == record.keywordSets,
            "Indexed vocabulary preserves the existing first-match behavior for duplicate IDs")
        precondition(all.contains { $0.id == originalID } && !inactive.contains { $0.id == originalID })
        precondition(!inactive.contains { $0.action == command.action }, "Scoped payload must not leak into global recursive scan")
        command.name = "Renamed project search"
        command.detail = "Search the current page."
        command.action = .keystroke(RecordedShortcut(keyCode: 5, modifiers: 1 << 20, keyLabel: "G"))
        precondition(command.voiceActionID == originalID, "Editing a custom command keeps portable vocabulary identity")
        settings.applicationCommands = [command]
        let edited = VoiceActionRegistry.make(settings: settings, activeBundleID: chrome).first { $0.id == originalID }!
        precondition(edited.action == command.action && edited.keywordSets == record.keywordSets)
        settings.applicationCommands?[0].enabled = false
        precondition(!VoiceActionRegistry.make(settings: settings, activeBundleID: chrome).contains { $0.id == originalID })
        precondition(VoiceActionRegistry.make(settings: settings, includeInactiveApplications: true).first { $0.id == originalID }?.enabled == false)
        let json = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(StoredSettings.self, from: json)
        precondition(restored.applicationCommands == settings.applicationCommands && restored.actionVocabulary == settings.actionVocabulary)
        precondition(StoredSettings().resolvedApplicationCommands.isEmpty)

        var targeted = BindingAction.openURL("https://example.com/project")
        targeted.targetBrowserBundleID = chrome
        let urlCommand = ApplicationCommand(bundleID: chrome, appName: "Google Chrome", name: "Project", detail: "Open the project in Chrome.", action: targeted)
        precondition(urlCommand.isValid && targeted.description.contains(chrome))
        let favorite = targeted.favorite(at: .up)!
        precondition(favorite.url == nil && favorite.shortcut?.assignedAction == targeted,
            "Targeted URLs retain their dispatcher through assigned HUD destinations")
        let favoriteRestored = try JSONDecoder().decode(AppExplorerFavorite.self, from: JSONEncoder().encode(favorite))
        precondition(BindingAction.from(favorite: favoriteRestored) == targeted)
        var invalid = urlCommand
        invalid.action.targetBrowserBundleID = "com.apple.Safari"
        precondition(!invalid.isValid)
        invalid.action.targetBrowserBundleID = nil
        precondition(!invalid.isValid)
        invalid = urlCommand; invalid.action.url = "file:///private/tmp/example"
        precondition(!invalid.isValid)
        invalid = urlCommand; invalid.action.url = "https://user:password@example.com"
        precondition(!invalid.isValid)
        invalid = command; invalid.action = .command(.lockScreen)
        precondition(!invalid.isValid)
        invalid = command; invalid.bundleID = "bad identifier"
        precondition(!invalid.isValid)
        invalid = command; invalid.name = " \n "
        precondition(!invalid.isValid)
        invalid = command; invalid.detail = String(repeating: "x", count: 2001)
        precondition(!invalid.isValid)
        var wrongKind = key; wrongKind.targetBrowserBundleID = chrome
        precondition(!wrongKind.isValid)
        var badTarget = targeted; badTarget.targetBrowserBundleID = "bad identifier"
        precondition(!badTarget.isValid)

        let oldAction = BindingAction.openURL("https://example.com")
        let encodedOld = String(data: try JSONEncoder().encode(oldAction), encoding: .utf8)!
        precondition(!encodedOld.contains("targetBrowserBundleID"), "Absent target does not change legacy action identity")
        let legacyRecord = VoiceRegisteredAction(action: oldAction, detail: "Legacy")
        precondition(legacyRecord.id == VoiceRegisteredAction.id(for: oldAction))
        for slack in VoiceActionRegistry.slackDefaults {
            let same = VoiceRegisteredAction(action: slack.action, detail: slack.detail,
                appBundleID: slack.appBundleID, appName: slack.appName, actionName: slack.actionName)
            precondition(same.id == slack.id, "Slack IDs remain on the existing identity algorithm")
        }
        let defaults = VoiceActionRegistry.chromeDefaults
        precondition(defaults.count == 17 && Set(defaults.map(\.id)).count == defaults.count)
        precondition(defaults.allSatisfy { $0.appBundleID == chrome && $0.customCommandID == nil && $0.action.isValid })
        let expected: [(String, UInt16, UInt64)] = [
            ("History", 16, 1 << 20), ("Bookmark manager", 11, (1 << 20) | (1 << 19)),
            ("Downloads", 38, (1 << 20) | (1 << 17)), ("Next tab", 124, (1 << 20) | (1 << 19)),
            ("Previous tab", 123, (1 << 20) | (1 << 19)), ("Last tab", 25, 1 << 20)]
        for (name, code, modifiers) in expected {
            let shortcut = defaults.first { $0.title == name }!.action.shortcut!
            precondition(shortcut.keyCode == code && shortcut.modifiers == modifiers)
        }
        for (index, code) in [UInt16(18), 19, 20, 21, 23, 22, 26, 28].enumerated() {
            precondition(defaults.first { $0.title == "Tab \(index + 1)" }!.action.shortcut?.keyCode == code)
        }
        precondition(defaults.first { $0.title == "Last tab" }!.detail.contains("not specifically tab nine"))
        precondition(inactive.allSatisfy { $0.appBundleID != chrome })
        precondition(active.filter { $0.appBundleID == chrome && $0.customCommandID == nil && $0.overrideTrigger == nil }.count == 17)
        testCatalogLoad()
        testValidationEquivalence()
        print("Application commands passed stable IDs/vocabulary, active-only scopes, disabled visibility, no global payload leak, Chrome defaults, validation, and targeted HUD roundtrip.")
    }

    static func testValidationEquivalence() {
        func legacyBundleID(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 255 && value != "local.rotagivan" && value.contains(".") &&
            value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }
        }
        func legacyWebURL(_ value: String) -> URL? {
            guard value.count <= 4096,
                  !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
                  let parts = URLComponents(string: value),
                  let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
            return parts.url
        }
        var identifiers = ["", "local.rotagivan", "com.google.Chrome", "COM.Example-App", ".", "withoutdot",
            String(repeating: "x", count: 255) + ".", "com.éxample", "com.应用"]
        var urls = ["", "https://example.com", "HTTP://EXAMPLE.COM/path?x=1#section", "file:///tmp/a", "chrome://history",
            "https://user:pass@example.com", "https://example.com:0", "https://example.com:65535", "https://example.com:65536",
            "https://例子.com/path", "https://example.com/é", "https://example.com/%20",
            "https://example.com/" + String(repeating: "x", count: 4096)]
        // Include every ASCII/control/Latin-1 scalar plus representative Unicode
        // whitespace and format characters, using the exact previous validators.
        for code in 0...255 {
            let scalar = String(UnicodeScalar(code)!)
            identifiers.append("com.example" + scalar)
            urls.append("https://example.com/path" + scalar)
        }
        for scalar in ["\u{200B}", "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{3000}"] {
            identifiers.append("com.example" + scalar)
            urls.append("https://example.com/" + scalar)
        }
        for value in identifiers { precondition(legacyBundleID(value) == BindingAction.isValidBundleID(value)) }
        for value in urls { precondition(legacyWebURL(value) == AppExplorerFavorite.webURL(value)) }
        precondition(AppExplorerFavorite.webURL("file:///tmp/a") == nil)
        precondition(AppExplorerFavorite.webURL("https://user:pass@example.com") == nil)
        precondition(AppExplorerFavorite.webURL("https://example.com/\n") == nil)
        precondition(!BindingAction.isValidBundleID("com.example\u{3000}"))
        print("Cached validator equivalence passed \(identifiers.count) bundle IDs and \(urls.count) URLs, retaining scheme, credentials, control characters, Unicode whitespace, ports, and length protections.")
    }

    @MainActor static func testCatalogLoad() {
        let chrome = "com.google.Chrome", other = "com.example.Editor"
        let commands = (0..<500).map { index in
            var action = BindingAction.openURL("https://example.com/command/\(index)")
            let bundleID = index.isMultiple(of: 2) ? chrome : other
            action.targetBrowserBundleID = bundleID
            return ApplicationCommand(bundleID: bundleID, appName: bundleID == chrome ? "Google Chrome" : "Fixture Editor",
                name: "Load command \(index)", detail: "Open fixture page \(index) in its assigned application.", action: action)
        }
        let fixtures = (0..<32).map { index in
            ExplorerApplication(bundleID: "com.example.Fixture\(index)", name: "Fixture \(index)",
                url: URL(fileURLWithPath: "/Applications/Fixture\(index).app"))
        }
        let ids = Set(commands.map(\.voiceActionID))
        precondition(ids.count == 500 && commands.allSatisfy(\.isValid))
        var settings = StoredSettings()
        settings.applicationCommands = commands
        settings.actionVocabulary = commands.enumerated().map { index, command in
            ActionVocabulary(actionID: command.voiceActionID, keywordSets: [["fixture phrase \(index)", "page \(index)"]])
        }
        func check(_ records: [VoiceRegisteredAction], expected: Set<String>) {
            precondition(Set(records.map(\.id)).count == records.count)
            let custom = records.filter { $0.customCommandID != nil }
            precondition(Set(custom.map(\.id)) == expected)
            let byID = Dictionary(uniqueKeysWithValues: custom.map { ($0.id, $0) })
            for (index, command) in commands.enumerated() where expected.contains(command.voiceActionID) {
                let record = byID[command.voiceActionID]!
                precondition(record.action == command.action && record.appBundleID == command.bundleID)
                precondition(record.keywordSets == [["fixture phrase \(index)", "page \(index)"]])
            }
            for fixture in fixtures {
                precondition(records.contains { $0.action.kind == .openApp && $0.action.bundleID == fixture.bundleID })
            }
        }
        let chromeIDs = Set(commands.filter { $0.bundleID == chrome }.map(\.voiceActionID))
        let otherIDs = ids.subtracting(chromeIDs)
        check(VoiceActionRegistry.make(settings: settings, applications: fixtures, activeBundleID: chrome), expected: chromeIDs)
        check(VoiceActionRegistry.make(settings: settings, applications: fixtures, activeBundleID: other), expected: otherIDs)
        check(VoiceActionRegistry.make(settings: settings, applications: fixtures, activeBundleID: "com.apple.finder"), expected: [])
        check(VoiceActionRegistry.make(settings: settings, applications: fixtures, includeInactiveApplications: true), expected: ids)

        // Diagnostics only: report scaling rather than enforce machine-specific
        // timing limits. Fixture construction and assertions are outside timing.
        for count in [50, 250, 500] {
            var sample = settings
            sample.applicationCommands = Array(commands.prefix(count))
            sample.actionVocabulary = Array(settings.actionVocabulary!.prefix(count))
            let iterations = 5
            let start = ProcessInfo.processInfo.systemUptime
            var totalRecords = 0
            for _ in 0..<iterations {
                totalRecords += VoiceActionRegistry.make(settings: sample, applications: fixtures,
                    includeInactiveApplications: true).count
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            print(String(format: "Catalog load diagnostic: %d commands with vocabulary, 32 app fixtures, %d runs, %.1f ms total (%.1f ms/run), %d output records.",
                count, iterations, elapsed * 1000, elapsed * 1000 / Double(iterations), totalRecords))
        }
        print("Catalog load passed: 500 commands, scoped 250/250/0, unique stable IDs, all vocabulary and 32 installed-app fixtures.")
    }
}
