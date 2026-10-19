import AppKit
import ApplicationServices

/// A channel the user opened in Slack, learned from Slack's window title.
/// Only channel names are kept (never messages or DMs), on this Mac only.
struct SlackChannelVisit: Codable, Equatable {
    var name: String
    var workspace: String
    var visits: Int
    var lastVisit: Date

    /// Frequent and recent channels first; a week-old visit counts half.
    func score(now: Date = Date()) -> Double {
        Double(visits) / (1 + max(0, now.timeIntervalSince(lastVisit)) / (7 * 86_400))
    }
}

enum SlackWindowTitle {
    /// Parses titles such as "general (Channel) - Acme - Slack",
    /// "* design (Private Channel) - Acme - 3 new items - Slack",
    /// "#general - Acme - Slack" or the older "Slack | general | Acme".
    /// DMs, Activity, Threads and other views return nil.
    static func channel(from rawTitle: String) -> (name: String, workspace: String)? {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("Slack | ") {
            let parts = title.components(separatedBy: " | ").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first else { return nil }
            return cleaned(first, workspace: parts.dropFirst().first ?? "", requireMarker: false)
        }
        guard title.hasSuffix(" - Slack") else { return nil }
        title = String(title.dropLast(" - Slack".count))
        while let first = title.first, first == "*" || first == "!" { title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let parts = title.components(separatedBy: " - ")
        guard let conversation = parts.first, parts.count >= 2 else { return nil }
        return cleaned(conversation, workspace: parts[1], requireMarker: true)
    }

    private static func cleaned(_ conversation: String, workspace: String, requireMarker: Bool) -> (name: String, workspace: String)? {
        var name = conversation.trimmingCharacters(in: .whitespaces)
        var marked = false
        for suffix in [" (Channel)", " (Private Channel)", " (Private channel)", " (channel)"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)); marked = true
        }
        if name.hasPrefix("#") { name = String(name.dropFirst()); marked = true }
        if name.hasSuffix(")") && name.contains(" (") { return nil }   // (DM), (Group DM), (Canvas)…
        guard marked || !requireMarker else { return nil }
        name = name.trimmingCharacters(in: .whitespaces)
        guard BindingAction.isValidSlackChannel(name), !name.contains(" ") || marked else { return nil }
        return (name, workspace.trimmingCharacters(in: .whitespaces))
    }
}

/// Remembers Slack channels as the user visits them, by sampling the title
/// of Slack's focused window every two seconds while Slack is frontmost.
@MainActor final class SlackChannelRecents {
    static let shared = SlackChannelRecents()
    nonisolated static let bundleID = "com.tinyspeck.slackmacgap"
    nonisolated static let storageKey = "slack.channelVisits"
    static let maximumRemembered = 200
    nonisolated static let maximumSuggested = 40

    private let defaults: UserDefaults
    private var timer: Timer?
    private var lastSeen: String?
    private(set) var visits: [SlackChannelVisit]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        visits = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([SlackChannelVisit].self, from: $0) } ?? []
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in SlackChannelRecents.shared.sampleIfSlackIsActive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        VoiceActionRegistry.supplementalActions = { Self.voiceActions(Self.storedVisits()) }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func sampleIfSlackIsActive() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == Self.bundleID,
              AXIsProcessTrusted() else { lastSeen = nil; return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let title = title as? String else { return }
        record(title: title)
    }

    /// Counts a visit once per arrival, not once per two-second sample.
    func record(title: String, now: Date = Date()) {
        guard let channel = SlackWindowTitle.channel(from: title) else { lastSeen = nil; return }
        let key = channel.workspace + "/" + channel.name
        guard key != lastSeen else { return }
        lastSeen = key
        if let index = visits.firstIndex(where: { $0.name == channel.name && $0.workspace == channel.workspace }) {
            visits[index].visits += 1; visits[index].lastVisit = now
        } else {
            visits.append(SlackChannelVisit(name: channel.name, workspace: channel.workspace, visits: 1, lastVisit: now))
        }
        if visits.count > Self.maximumRemembered {
            visits = Array(visits.sorted { $0.score(now: now) > $1.score(now: now) }.prefix(Self.maximumRemembered))
        }
        defaults.set(try? JSONEncoder().encode(visits), forKey: Self.storageKey)
    }

    func forget(_ name: String) {
        visits.removeAll { $0.name == name }
        defaults.set(try? JSONEncoder().encode(visits), forKey: Self.storageKey)
    }

    nonisolated static func storedVisits(_ defaults: UserDefaults = .standard) -> [SlackChannelVisit] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([SlackChannelVisit].self, from: $0) } ?? []
    }

    /// The most-used channels become voice actions and Actions-table rows.
    /// The same channel name in two workspaces is one action.
    nonisolated static func voiceActions(_ visits: [SlackChannelVisit], now: Date = Date()) -> [VoiceRegisteredAction] {
        var merged: [String: (visit: SlackChannelVisit, workspaces: Set<String>)] = [:]
        for visit in visits {
            var entry = merged[visit.name] ?? (visit, [])
            if entry.visit != visit {
                entry.visit.visits += visit.visits
                entry.visit.lastVisit = max(entry.visit.lastVisit, visit.lastVisit)
            }
            if !visit.workspace.isEmpty { entry.workspaces.insert(visit.workspace) }
            merged[visit.name] = entry
        }
        return merged.values.sorted { $0.visit.score(now: now) > $1.visit.score(now: now) }
            .prefix(maximumSuggested).map { entry in
                let action = BindingAction.slackChannel(entry.visit.name)
                let place = entry.workspaces.isEmpty ? "" : " in " + entry.workspaces.sorted().joined(separator: " or ")
                return VoiceRegisteredAction(action: action,
                    detail: "Open the #\(entry.visit.name) Slack channel\(place). You have visited it \(entry.visit.visits) \(entry.visit.visits == 1 ? "time" : "times").",
                    actionName: "#" + entry.visit.name)
            }
    }
}

/// Opens a channel through Slack's quick switcher (⌘K, name, Return). Every
/// keystroke checks that Slack is still frontmost, so nothing is typed into
/// another app if focus moves.
@MainActor enum SlackChannelOpener {
    static func open(_ name: String) {
        guard BindingAction.isValidSlackChannel(name),
              let url = ExplorerApplicationCatalog.applicationURL(for: SlackChannelRecents.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            Task { @MainActor in await type(name) }
        }
    }

    private static var slackIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SlackChannelRecents.bundleID
    }

    private static func type(_ name: String) async {
        for _ in 0..<40 where !slackIsFrontmost { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard slackIsFrontmost else { return }
        post(RecordedShortcut(keyCode: 40, modifiers: 1 << 20, keyLabel: "K"))
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard slackIsFrontmost else { return }
        let source = CGEventSource(stateID: .privateState)
        for character in name {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
        }
        // Let Slack's switcher rank the results before choosing the top one.
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard slackIsFrontmost else { return }
        post(RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return"))
    }

    private static func post(_ shortcut: RecordedShortcut) {
        EventPoster.shortcutEvents(shortcut).forEach { $0.post(tap: .cghidEventTap) }
    }
}
