import Foundation

@MainActor private final class BuildGate {
    var requests: [ActionCatalogInput] = []
    var continuation: CheckedContinuation<Void, Never>?
    var active = 0
    var maximumActive = 0
    func build(_ input: ActionCatalogInput) async -> ActionCatalogValue {
        active += 1; maximumActive = max(active, maximumActive); requests.append(input)
        await withCheckedContinuation { continuation = $0 }
        active -= 1
        return ActionCatalogValue.build(input)
    }
    func waitForRequest(_ count: Int) async {
        let deadline = Date().addingTimeInterval(10)
        while requests.count < count || continuation == nil {
            precondition(Date() < deadline, "Timed out waiting for an admitted build")
            await Task.yield()
        }
    }
    func release() { let next = continuation; continuation = nil; next?.resume() }
}

@main struct ActionCatalogSnapshotTests {
    @MainActor static func main() async throws {
        let apps = [ExplorerApplication(bundleID: "fixture.slack", name: "Café Slack",
            url: URL(fileURLWithPath: "/synthetic/Slack.app"))]
        var settings = StoredSettings()
        settings.actionBindings = [ActionBinding.defaultHUDLauncher]
        func input(_ settings: StoredSettings, layer: UInt32 = 1, device: GestureDevice = .navigator) -> ActionCatalogInput {
            ActionCatalogInput(settings: settings, shortcuts: ShortcutConfiguration(), applications: apps, layerID: layer, device: device)
        }
        let source = input(settings)
        let value = ActionCatalogValue.build(source)
        let legacy = ActionTableRow.make(settings: settings, applications: apps, audit: value.audit)
        precondition(value.rows.map(\.id) == legacy.map(\.id))
        for query in ["", "SLACK", "café", "cafe", "launch", "Option+Space", "does not exist"] {
            let expected = legacy.filter { row in
                query.isEmpty || [row.id, row.group, row.subgroup, row.name, row.detail, row.keybindings, row.keywords]
                    .joined(separator: " ").localizedCaseInsensitiveContains(query)
            }
            precondition(value.filtered(group: "All groups", subgroup: "All subgroups", search: query).map(\.id) == expected.map(\.id))
        }
        precondition(value.filtered(group: "Applications", subgroup: "Café Slack", search: "").count == 1)
        let gate = BuildGate()
        let model = ActionCatalogSnapshot(build: { await gate.build($0) })
        model.submit(source)
        await gate.waitForRequest(1)
        for index in 0..<20 {
            var changed = settings
            changed.actionVocabulary = [ActionVocabulary(actionID: "fixture", keywordSets: [["revision \(index)"]])]
            model.submit(input(changed, layer: 2, device: .apple))
        }
        precondition(gate.requests.count == 1, "Only one physical catalog build can be admitted")
        gate.release(); await gate.waitForRequest(2)
        precondition(model.value == nil, "A stale result must never publish")
        precondition(gate.requests.last?.settings.actionVocabulary?.first?.keywordSets == [["revision 19"]])
        precondition(gate.requests.last?.layerID == 2 && gate.requests.last?.device == .apple)
        gate.release(); await model.awaitIdle()
        precondition(model.value != nil && model.buildCount == 2 && gate.maximumActive == 1)
        let count = model.buildCount
        for _ in 0..<100 { _ = model.value?.filtered(group: "All groups", subgroup: "All subgroups", search: "slack") }
        precondition(model.buildCount == count, "Search must not rebuild catalogs")
        model.submit(source); await gate.waitForRequest(3)
        let previous = model.publishedRevision
        model.disconnect(); gate.release(); await model.awaitIdle()
        precondition(model.publishedRevision == previous, "A disconnected build must not publish")
        model.submit(source); await gate.waitForRequest(4)
        model.disconnect(); model.submit(input(settings, layer: 2))
        gate.release(); await gate.waitForRequest(5)
        precondition(model.publishedRevision == previous && gate.maximumActive == 1)
        gate.release(); await model.awaitIdle()
        precondition(model.publishedRevision > previous, "A reconnect must publish after the old build drains")

        // Real observation path: capture after Published commits, including keys.
        let suite = "Rotagivan.Catalog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let keys = ShortcutSettings(defaults: defaults)
        let index = VoiceApplicationIndex(scan: { .init(applications: apps, errors: []) })
        let observed = ActionCatalogSnapshot()
        observed.connect(store: store, keys: keys, apps: index, layerID: 1, device: .navigator)
        await observed.awaitIdle()
        let oldIDs = Set(observed.value!.rows.map(\.id))
        let added = NamedHotkey(name: "New cached macro", shortcut: RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C"))
        store.settings.hotkeyDictionary = [added]
        await observed.awaitIdle()
        precondition(observed.value!.rows.contains { $0.action.macroID == added.id })
        precondition(!oldIDs.contains(VoiceRegisteredAction.id(for: .macro(added))))
        store.settings.actionVocabulary = [ActionVocabulary(actionID: VoiceRegisteredAction.id(for: .macro(added)), keywordSets: [["learnedword"]])]
        await observed.awaitIdle()
        precondition(observed.value!.filtered(group: "All groups", subgroup: "All subgroups", search: "learnedword").contains { $0.action.macroID == added.id })
        await index.refresh(force: true); await observed.awaitIdle()
        precondition(observed.value!.rows.contains { $0.name == "Café Slack" })
        keys.precision.keyCode = 99
        await observed.awaitIdle()
        precondition(observed.value!.audit.assignments.contains { $0.id == "activation.2" && $0.shortcut?.keyCode == 99 },
            "Shortcut snapshots must read the committed replacement, not the Published old value")
        observed.setScope(layerID: 2, device: .apple); await observed.awaitIdle()
        precondition(!observed.isRefreshing)
        observed.disconnect()
        print("Action catalog snapshot PASS: parity, Unicode, one-build admission, stale rejection, coalescing, non-rebuilding search, and live settings/apps/scope invalidation")
    }
}
