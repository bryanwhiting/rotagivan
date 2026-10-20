import AppKit

@main struct SlackChannelTests {
    @MainActor static func main() {
        let parse = SlackWindowTitle.channel(from:)
        precondition(parse("general (Channel) - Acme - Slack")! == ("general", "Acme"))
        precondition(parse("* design-team (Private Channel) - Acme - 3 new items - Slack")! == ("design-team", "Acme"))
        precondition(parse("#eng-alerts - Acme - Slack")! == ("eng-alerts", "Acme"))
        precondition(parse("Slack | random | Acme")! == ("random", "Acme"))
        precondition(parse("Jane Doe (DM) - Acme - Slack") == nil, "DMs are never remembered")
        precondition(parse("Activity - Acme - Slack") == nil && parse("Threads - Acme - Slack") == nil)
        precondition(parse("general (Channel) - Acme - Google Chrome") == nil)

        let suite = "Rotagivan.SlackChannels.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = SlackChannelRecents(defaults: defaults)
        let now = Date()
        recents.record(title: "general (Channel) - Acme - Slack", now: now)
        recents.record(title: "general (Channel) - Acme - Slack", now: now)
        precondition(recents.visits.first?.visits == 1, "Repeated samples of the same window count once")
        recents.record(title: "Jane Doe (DM) - Acme - Slack", now: now)
        recents.record(title: "general (Channel) - Acme - Slack", now: now)
        recents.record(title: "old (Channel) - Acme - Slack", now: now.addingTimeInterval(-60 * 86_400))
        precondition(recents.visits.count == 2 && recents.visits.first?.visits == 2)
        let reloaded = SlackChannelRecents.storedVisits(defaults)
        precondition(reloaded == recents.visits, "Visits persist locally")
        let actions = SlackChannelRecents.voiceActions(reloaded, now: now)
        precondition(actions.map(\.title) == ["#general", "#old"], "Frequent, recent channels rank first")
        precondition(actions[0].action == .slackChannel("general") && actions[0].action.isValid && actions[0].appBundleID == nil)
        precondition(!BindingAction.slackChannel("a\nb").isValid && !BindingAction(kind: .slackChannel).isValid)
        var withURL = BindingAction.slackChannel("general"); withURL.url = "https://example.com"
        precondition(!withURL.isValid, "Mixed fields are rejected")

        VoiceActionRegistry.supplementalActions = { actions }
        let registry = VoiceActionRegistry.make(settings: StoredSettings())
        precondition(registry.contains { $0.action == .slackChannel("general") }, "Recent channels reach voice and Actions")
        let ranked = SlackChannelRecents.ranked([
            SlackChannelVisit(name: "eng", workspace: "A", visits: 2, lastVisit: now),
            SlackChannelVisit(name: "eng", workspace: "B", visits: 3, lastVisit: now),
            SlackChannelVisit(name: "random", workspace: "A", visits: 4, lastVisit: now)], now: now)
        precondition(ranked.map(\.name) == ["eng", "random"] && ranked[0].visits == 5, "HUD ranks channels across workspaces by activity")
        let tile = ExplorerReservedGroup.slackChannels.tile(at: .up)
        precondition(tile.isSlackChannelsGroup && tile.isDynamicGroup && HUDLayerBuiltIn.allCases.contains(.slackChannels))
        recents.forget("general")
        precondition(!SlackChannelRecents.storedVisits(defaults).contains { $0.name == "general" })
        print("Slack channels passed: title parsing (channels only, never DMs), once-per-visit counting, local persistence, frecency ranking, validation, voice registry.")
    }
}
