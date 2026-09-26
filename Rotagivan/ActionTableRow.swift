import Foundation

struct ActionTableRow: Identifiable {
    let action: BindingAction
    let id: String
    let group: String
    let name: String
    let detail: String
    let keybindings: String
    let subgroup: String
    let appBundleID: String?
    let keywords: String
    let isAppScoped: Bool

    static func group(for action: BindingAction) -> String {
        switch action.kind {
        case .macro: return "Macros"
        case .keystroke: return "Shortcuts"
        case .openApp: return "Applications"
        case .openURL: return "Websites"
        case .media: return "Audio & media"
        case .windowPlacement: return "Window layouts"
        case .hudLayer, .hudNavigation: return "HUDs"
        case .tap: return "Pointer & keys"
        case .command:
            if action.command == .mediaControls || action.command == .windowManager { return "HUDs" }
            return action.command.map { AppExplorerAction.windowCommands.contains($0) } == true ? "Windows" : "Mac controls"
        }
    }

    static func make(settings: StoredSettings, applications: [ExplorerApplication], audit: HotkeyAudit) -> [Self] {
        let inputs = audit.assignments.filter { $0.inputScope != nil && $0.shortcut?.isPhysicalShortcut == true && $0.boundAction != nil }
        let byAction = Dictionary(grouping: inputs, by: { $0.boundAction!.identity })
        let records = VoiceActionRegistry.make(settings: settings, applications: applications, includeInactiveApplications: true)
        var rows: [Self] = []
        for record in records {
            let assignments = byAction[record.action.identity] ?? []
            let keys: [String] = assignments.map { input in
                let scope = input.inputScope == "" ? "Global" : input.scope
                let status = input.enabled ? "" : " (inactive)"
                return input.trigger + " · " + scope + status
            }
            let macro = settings.resolvedHotkeyDictionary.first { $0.id == record.action.macroID }
            let name = record.actionName ?? macro?.name ?? record.action.name ?? record.title
            var keybindings = Array(Set(keys)).sorted().joined(separator: "\n")
            if record.appBundleID != nil {
                keybindings = record.overrideTrigger.map { $0.title + (record.enabled ? "" : " (disabled)") }
                    ?? ((record.action.shortcut?.readableCombination ?? "") + " · App default")
            }
            let bundleID = record.appBundleID ?? record.action.bundleID
            let subgroup = record.appName ?? (record.action.kind == .openApp ? name : "")
            rows.append(Self(action: record.action, id: record.id, group: bundleID == nil ? group(for: record.action) : "Applications",
                name: name, detail: record.detail, keybindings: keybindings, subgroup: subgroup, appBundleID: bundleID,
                keywords: record.keywordSets.map { $0.joined(separator: ", ") }.joined(separator: "\n"), isAppScoped: record.appBundleID != nil))
        }
        return rows.sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.subgroup != $1.subgroup { return $0.subgroup.localizedStandardCompare($1.subgroup) == .orderedAscending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
