import Combine
import Foundation

struct ActionCatalogInput {
    let settings: StoredSettings
    let shortcuts: ShortcutConfiguration
    let applications: [ExplorerApplication]
    let layerID: UInt32
    let device: GestureDevice
}

struct ActionCatalogValue {
    struct Entry {
        let row: ActionTableRow
        let searchText: String
    }
    let audit: HotkeyAudit
    let entries: [Entry]
    let groups: [String]
    let subgroups: [String: [String]]
    var rows: [ActionTableRow] { entries.map(\.row) }

    static func build(_ input: ActionCatalogInput) -> Self {
        let audit = HotkeyAudit(settings: input.settings, shortcuts: input.shortcuts,
            layerID: input.layerID, device: input.device)
        let rows = ActionTableRow.make(settings: input.settings, applications: input.applications, audit: audit)
        let groups = Array(Set(rows.map(\.group))).sorted()
        var subgroups: [String: [String]] = [:]
        for group in groups {
            subgroups[group] = Array(Set(rows.filter { $0.group == group }.map(\.subgroup)))
                .filter { !$0.isEmpty }.sorted()
        }
        subgroups["All groups"] = Array(Set(rows.map(\.subgroup))).filter { !$0.isEmpty }.sorted()
        return Self(audit: audit, entries: rows.map { row in
            Entry(row: row, searchText: [row.id, row.group, row.subgroup, row.name,
                row.detail, row.keybindings, row.keywords].joined(separator: " "))
        }, groups: groups, subgroups: subgroups)
    }

    func filtered(group: String, subgroup: String, search: String) -> [ActionTableRow] {
        entries.compactMap { entry in
            guard (group == "All groups" || entry.row.group == group),
                  (subgroup == "All subgroups" || entry.row.subgroup == subgroup),
                  search.isEmpty || entry.searchText.localizedCaseInsensitiveContains(search) else { return nil }
            return entry.row
        }
    }
}

/// One physical build at a time, with one replaceable pending revision. Search and
/// visual state never invalidate this snapshot; execution still validates live state.
@MainActor final class ActionCatalogSnapshot: ObservableObject {
    @Published private(set) var value: ActionCatalogValue?
    @Published private(set) var isRefreshing = false
    private(set) var buildCount = 0
    private(set) var publishedRevision: UInt64 = 0
    private var revision: UInt64 = 0
    private var pending: (revision: UInt64, input: ActionCatalogInput)?
    private var work: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private weak var store: SettingsStore?
    private weak var keys: ShortcutSettings?
    private weak var apps: VoiceApplicationIndex?
    private var layerID: UInt32 = 1
    private var device: GestureDevice = .navigator
    private let build: (ActionCatalogInput) async -> ActionCatalogValue

    init(build: @escaping (ActionCatalogInput) async -> ActionCatalogValue = { input in
        await Task.detached(priority: .userInitiated) { ActionCatalogValue.build(input) }.value
    }) { self.build = build }

    func connect(store: SettingsStore, keys: ShortcutSettings, apps: VoiceApplicationIndex,
                 layerID: UInt32, device: GestureDevice) {
        if self.store === store && self.keys === keys && self.apps === apps {
            setScope(layerID: layerID, device: device)
            return
        }
        disconnect()
        self.store = store; self.keys = keys; self.apps = apps
        self.layerID = layerID; self.device = device
        store.$settings.dropFirst().sink { [weak self] _ in self?.scheduleCapture() }.store(in: &subscriptions)
        keys.objectWillChange.sink { [weak self] _ in self?.scheduleCapture() }.store(in: &subscriptions)
        apps.$applications.dropFirst().sink { [weak self] _ in self?.scheduleCapture() }.store(in: &subscriptions)
        captureCurrent()
    }

    func setScope(layerID: UInt32, device: GestureDevice) {
        guard self.layerID != layerID || self.device != device else { return }
        self.layerID = layerID; self.device = device
        scheduleCapture()
    }

    func disconnect() {
        subscriptions.removeAll(); capture?.cancel(); capture = nil
        store = nil; keys = nil; apps = nil
        revision &+= 1; pending = nil
        // Keep the physical build admitted until it drains, even across reconnect.
    }

    private func scheduleCapture() {
        // Published callbacks run before their owning property is committed.
        // Yield once to capture a complete configuration and coalesce a replace.
        revision &+= 1
        capture?.cancel()
        capture = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.capture = nil
            self.captureCurrent()
        }
    }

    private func captureCurrent() {
        guard let store, let keys, let apps else { return }
        submit(ActionCatalogInput(settings: store.settings, shortcuts: ShortcutConfiguration(keys),
            applications: apps.applications, layerID: layerID, device: device))
    }

    func submit(_ input: ActionCatalogInput) {
        revision &+= 1
        pending = (revision, input)
        isRefreshing = true
        guard work == nil else { return }
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            while let request = pending {
                pending = nil; buildCount += 1
                let result = await build(request.input)
                guard request.revision == revision else { continue }
                value = result; publishedRevision = request.revision
            }
            work = nil; isRefreshing = false
        }
    }

    func awaitIdle() async {
        while capture != nil || work != nil {
            if let capture { await capture.value }
            if let work { await work.value }
        }
    }
}
