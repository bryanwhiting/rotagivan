import Foundation

struct MCPToolError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Agent-facing settings tools. Each call works on a copy of the settings and
/// reports whether it changed anything; the caller saves only validated copies.
/// Deliberately excludes credentials, sync state, the vault and anything that
/// runs actions or sends keystrokes.
struct MCPSettingsTools {
    var applications: [ExplorerApplication] = []
    static let maximumBookmarksPerCall = 200
    static let maximumVocabularyEntries = 2_000

    struct Outcome {
        var result: Any
        var changed = false
    }

    static func render(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    func call(_ name: String, arguments: [String: Any], settings: inout StoredSettings) throws -> Outcome {
        switch name {
        case "get_settings_summary": try only([], arguments); return Outcome(result: summary(settings))
        case "list_bookmarks": try only([], arguments); return Outcome(result: ["bookmarks": settings.resolvedWebsiteBookmarks.map(bookmark)])
        case "add_bookmarks": return try addBookmarks(arguments, settings: &settings)
        case "remove_bookmark": return try removeBookmark(arguments, settings: &settings)
        case "list_actions": return try listActions(arguments, settings: settings)
        case "set_action_keywords": return try setKeywords(arguments, settings: &settings)
        case "list_huds": try only([], arguments); return Outcome(result: ["huds": huds(settings)])
        case "set_hud_tile": return try setTile(arguments, settings: &settings)
        case "clear_hud_tile": return try clearTile(arguments, settings: &settings)
        case "list_macros": try only([], arguments); return Outcome(result: ["macros": settings.resolvedHotkeyDictionary.map(macro)])
        default: throw MCPToolError("Unknown tool: \(name)")
        }
    }

    // MARK: Arguments

    private func only(_ allowed: Set<String>, _ arguments: [String: Any]) throws {
        if let unknown = arguments.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw MCPToolError("Unknown argument “\(unknown)”.")
        }
    }
    private func text(_ arguments: [String: Any], _ key: String, required: Bool = false, maximum: Int = 4096) throws -> String? {
        guard let value = arguments[key], !(value is NSNull) else {
            if required { throw MCPToolError("“\(key)” is required.") }
            return nil
        }
        guard let string = value as? String else { throw MCPToolError("“\(key)” must be a string.") }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !required else { throw MCPToolError("“\(key)” must not be empty.") }
        guard trimmed.count <= maximum else { throw MCPToolError("“\(key)” must be \(maximum) characters or fewer.") }
        guard !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MCPToolError("“\(key)” must be a single line without control characters.")
        }
        return trimmed.isEmpty ? nil : trimmed
    }
    private func flag(_ arguments: [String: Any], _ key: String) throws -> Bool {
        guard let value = arguments[key] else { return false }
        guard let bool = value as? Bool else { throw MCPToolError("“\(key)” must be true or false.") }
        return bool
    }
    private func integer(_ arguments: [String: Any], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = arguments[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue, range.contains(number.intValue) else {
            throw MCPToolError("“\(key)” must be an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return number.intValue
    }

    static func browserBundleID(_ value: String?) throws -> String? {
        switch value?.lowercased() {
        case nil, "default": return nil
        case "chrome": return "com.google.Chrome"
        case "safari": return "com.apple.Safari"
        default: throw MCPToolError("“browser” must be chrome, safari or default.")
        }
    }
    static func browserName(_ bundleID: String?) -> String {
        switch bundleID {
        case nil: return "default"
        case "com.google.Chrome": return "chrome"
        case "com.apple.Safari": return "safari"
        case let other?: return other
        }
    }
    /// Same rules as the Add bookmarks sheet: https is assumed, only http(s) web links pass.
    static func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AppExplorerFavorite.webURL(trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }
    static func defaultName(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    private func websiteAction(url text: String, name: String?, browser: String?) throws -> BindingAction {
        guard let url = Self.normalizedURL(text) else { throw MCPToolError("“\(text)” is not a valid http or https address.") }
        var action = BindingAction.openURL(url.absoluteString)
        action.name = name ?? Self.defaultName(url)
        action.targetBrowserBundleID = try Self.browserBundleID(browser)
        guard action.isValid else { throw MCPToolError("“\(text)” is not a valid bookmark.") }
        return action
    }

    // MARK: Summary and bookmarks

    private func summary(_ settings: StoredSettings) -> [String: Any] {
        let explorer = settings.appExplorer ?? AppExplorerSettings()
        return [
            "rota_enabled": settings.enabled,
            "website_bookmarks": settings.resolvedWebsiteBookmarks.count,
            "huds": 1 + (explorer.holdLayers ?? []).count,
            "main_hud_tiles": explorer.favorites.count,
            "macros": settings.resolvedHotkeyDictionary.count,
            "actions": registry(settings).count,
            "actions_with_voice_keywords": (settings.actionVocabulary ?? []).count,
            "application_commands": settings.resolvedApplicationCommands.count,
            "action_bindings": (settings.actionBindings ?? []).count,
            "limits": ["website_bookmarks": StoredSettings.maximumWebsiteBookmarks, "bookmarks_per_call": Self.maximumBookmarksPerCall]
        ]
    }

    private func bookmark(_ action: BindingAction) -> [String: Any] {
        ["name": action.name ?? action.title, "url": action.url ?? "",
         "browser": Self.browserName(action.targetBrowserBundleID), "action_id": VoiceRegisteredAction.id(for: action)]
    }

    private func addBookmarks(_ arguments: [String: Any], settings: inout StoredSettings) throws -> Outcome {
        try only(["bookmarks"], arguments)
        guard let items = arguments["bookmarks"] as? [Any], !items.isEmpty else { throw MCPToolError("“bookmarks” must be a non-empty array.") }
        guard items.count <= Self.maximumBookmarksPerCall else { throw MCPToolError("Add at most \(Self.maximumBookmarksPerCall) bookmarks per call.") }
        var seen = Set(settings.resolvedWebsiteBookmarks.compactMap(\.url))
        var accepted: [BindingAction] = [], duplicates: [String] = [], rejected: [[String: Any]] = []
        for (index, item) in items.enumerated() {
            guard let entry = item as? [String: Any] else { rejected.append(["index": index, "reason": "Each bookmark must be an object."]); continue }
            let raw = entry["url"] as? String ?? ""
            do {
                try only(["url", "name", "browser"], entry)
                let action = try websiteAction(url: try text(entry, "url", required: true) ?? "",
                    name: try text(entry, "name", maximum: 512), browser: try text(entry, "browser", maximum: 16))
                guard seen.insert(action.url!).inserted else { duplicates.append(action.url!); continue }
                guard settings.resolvedWebsiteBookmarks.count + accepted.count < StoredSettings.maximumWebsiteBookmarks else {
                    rejected.append(["index": index, "url": raw, "reason": "The \(StoredSettings.maximumWebsiteBookmarks)-bookmark limit is reached."]); continue
                }
                accepted.append(action)
            } catch let error as MCPToolError {
                rejected.append(["index": index, "url": raw, "reason": error.message])
            }
        }
        let added = accepted.isEmpty ? 0 : settings.addWebsiteBookmarks(accepted)
        return Outcome(result: ["added": accepted.prefix(added).map(bookmark), "duplicates": duplicates, "rejected": rejected,
                                "total_bookmarks": settings.resolvedWebsiteBookmarks.count], changed: added > 0)
    }

    private func removeBookmark(_ arguments: [String: Any], settings: inout StoredSettings) throws -> Outcome {
        try only(["url"], arguments)
        let url = try text(arguments, "url", required: true)!
        let normalized = Self.normalizedURL(url)?.absoluteString
        let matches = settings.resolvedWebsiteBookmarks.filter { $0.url == url || ($0.url != nil && $0.url == normalized) }
        guard !matches.isEmpty else { throw MCPToolError("No bookmark has the URL “\(url)”. Use list_bookmarks to see saved URLs.") }
        for match in matches { settings.removeWebsiteBookmark(identity: match.identity) }
        return Outcome(result: ["removed": matches.map(bookmark), "total_bookmarks": settings.resolvedWebsiteBookmarks.count], changed: true)
    }

    // MARK: Actions and voice keywords

    private func registry(_ settings: StoredSettings) -> [VoiceRegisteredAction] {
        VoiceActionRegistry.make(settings: settings, applications: applications, includeInactiveApplications: true)
    }
    private func actionRow(_ record: VoiceRegisteredAction, settings: StoredSettings) -> [String: Any] {
        let macro = settings.resolvedHotkeyDictionary.first { $0.id == record.action.macroID }
        let bundleID = record.appBundleID ?? record.action.bundleID
        var row: [String: Any] = [
            "id": record.id,
            "name": record.actionName ?? macro?.name ?? record.action.name ?? record.title,
            "group": bundleID == nil ? ActionTableRow.group(for: record.action) : "Applications",
            "detail": record.detail,
            "keyword_sets": record.keywordSets
        ]
        if let bundleID { row["app_bundle_id"] = bundleID }
        if let app = record.appName { row["app_name"] = app }
        if record.appBundleID != nil { row["app_scoped"] = true }
        return row
    }

    private func listActions(_ arguments: [String: Any], settings: StoredSettings) throws -> Outcome {
        try only(["query", "group", "limit", "offset"], arguments)
        let query = try text(arguments, "query", maximum: 200)?.lowercased()
        let group = try text(arguments, "group", maximum: 100)
        let limit = try integer(arguments, "limit", default: 50, range: 1...500)
        let offset = try integer(arguments, "offset", default: 0, range: 0...100_000)
        let rows = registry(settings).map { actionRow($0, settings: settings) }
        let groups = Set(rows.compactMap { $0["group"] as? String }).sorted()
        let matching = rows.filter { row in
            if let group, (row["group"] as? String)?.caseInsensitiveCompare(group) != .orderedSame { return false }
            guard let query else { return true }
            let keywords = (row["keyword_sets"] as? [[String]] ?? []).flatMap { $0 }
            return ([row["name"], row["group"], row["detail"], row["app_name"]].compactMap { $0 as? String } + keywords)
                .contains { $0.lowercased().contains(query) }
        }.sorted {
            let (a, b) = ($0["group"] as! String, $1["group"] as! String)
            if a != b { return a < b }
            return ($0["name"] as! String).localizedStandardCompare($1["name"] as! String) == .orderedAscending
        }
        return Outcome(result: ["total": matching.count, "offset": offset, "groups": groups,
                                "actions": Array(matching.dropFirst(offset).prefix(limit))])
    }

    private func setKeywords(_ arguments: [String: Any], settings: inout StoredSettings) throws -> Outcome {
        try only(["action_id", "keyword_sets"], arguments)
        let id = try text(arguments, "action_id", required: true, maximum: 200)!
        guard let record = registry(settings).first(where: { $0.id == id }) else {
            throw MCPToolError("No action has id “\(id)”. Use list_actions to find ids.")
        }
        guard let raw = arguments["keyword_sets"] as? [Any] else { throw MCPToolError("“keyword_sets” must be an array of phrase arrays.") }
        guard raw.count <= 20 else { throw MCPToolError("Use at most 20 keyword sets.") }
        var sets: [[String]] = []
        for item in raw {
            guard let phrases = item as? [Any] else { throw MCPToolError("Each keyword set must be an array of phrases.") }
            guard phrases.count <= 12 else { throw MCPToolError("Use at most 12 phrases per keyword set.") }
            var set: [String] = []
            for phrase in phrases {
                guard let phrase = phrase as? String else { throw MCPToolError("Each phrase must be a string.") }
                let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1...120).contains(trimmed.count) else { throw MCPToolError("Each phrase must be 1–120 characters.") }
                // Commas and newlines delimit phrases and sets in the Actions editor.
                guard !trimmed.contains(","), !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw MCPToolError("Phrases cannot contain commas, newlines or control characters. Put alternatives in separate phrases.")
                }
                set.append(trimmed)
            }
            if !set.isEmpty { sets.append(set) }
        }
        var entries = settings.actionVocabulary ?? []
        let existed = entries.contains { $0.actionID == id }
        guard existed || sets.isEmpty || entries.count < Self.maximumVocabularyEntries else {
            throw MCPToolError("At most \(Self.maximumVocabularyEntries) actions can have voice keywords.")
        }
        let previous = entries.first { $0.actionID == id }?.keywordSets ?? []
        entries.removeAll { $0.actionID == id }
        if !sets.isEmpty { entries.append(ActionVocabulary(actionID: id, keywordSets: sets)) }
        settings.actionVocabulary = entries.isEmpty ? nil : entries
        var row = actionRow(record, settings: settings)
        row["keyword_sets"] = sets
        return Outcome(result: ["action": row], changed: previous != sets)
    }

    // MARK: HUDs

    private struct HUDTarget {
        let layerIndex: Int?
        let name: String
        let slotCount: Int
        let favorites: [AppExplorerFavorite]
        let builtIn: HUDLayerBuiltIn?
        var editable: Bool { builtIn == nil || builtIn == .actions || builtIn == .mediaControls }
    }

    private func targets(_ explorer: AppExplorerSettings) -> [HUDTarget] {
        [HUDTarget(layerIndex: nil, name: "Main HUD", slotCount: explorer.slotCount ?? 8, favorites: explorer.favorites, builtIn: nil)] +
        (explorer.holdLayers ?? []).enumerated().map { index, layer in
            HUDTarget(layerIndex: index, name: layer.name, slotCount: layer.slotCount ?? explorer.slotCount ?? 8,
                      favorites: layer.editableFavorites, builtIn: layer.builtIn)
        }
    }

    private func tile(_ favorite: AppExplorerFavorite) -> [String: Any] {
        var result: [String: Any] = ["direction": favorite.direction.rawValue, "name": favorite.name]
        if favorite.isGroup {
            result["kind"] = "group"
            result["tile_count"] = favorite.children?.count ?? 0
        } else if let bundleID = favorite.bundleID {
            result["kind"] = "app"; result["bundle_id"] = bundleID
        } else if let url = favorite.url {
            result["kind"] = "website"; result["url"] = url
        } else if favorite.windowPlacement != nil {
            result["kind"] = "window_placement"
        } else if favorite.action != nil {
            result["kind"] = "command"
        } else {
            result["kind"] = "action"
            if let url = favorite.shortcut?.assignedAction?.url { result["url"] = url }
        }
        if !favorite.isPureGroup, let action = BindingAction.from(favorite: favorite) {
            result["action_id"] = VoiceRegisteredAction.id(for: action)
        }
        return result
    }

    private func huds(_ settings: StoredSettings) -> [[String: Any]] {
        let explorer = settings.appExplorer ?? AppExplorerSettings()
        let positions = explorer.resolvedHUDPositions
        let layers = explorer.holdLayers ?? []
        return targets(explorer).map { target in
            let order = ExplorerSlot.slots(target.slotCount)
            var hud: [String: Any] = [
                "name": target.name,
                "editable": target.editable,
                "slot_count": target.slotCount,
                "slots": order.map(\.rawValue),
                "tiles": target.favorites.sorted { (order.firstIndex(of: $0.direction) ?? .max) < (order.firstIndex(of: $1.direction) ?? .max) }.map(tile)
            ]
            if let index = target.layerIndex {
                let layer = layers[index]
                hud["id"] = layer.id.uuidString
                hud["position"] = positions[layer.id]?.rawValue ?? NSNull()
                if let builtIn = target.builtIn { hud["built_in"] = builtIn.rawValue }
            } else {
                hud["id"] = "main"; hud["position"] = "center"
            }
            return hud
        }
    }

    private func resolveHUD(_ arguments: [String: Any], explorer: AppExplorerSettings) throws -> HUDTarget {
        let key = try text(arguments, "hud", required: true, maximum: 200)!
        let all = targets(explorer)
        let layers = explorer.holdLayers ?? []
        let target: HUDTarget?
        if key.caseInsensitiveCompare("main") == .orderedSame || key.caseInsensitiveCompare("Main HUD") == .orderedSame {
            target = all[0]
        } else if let id = UUID(uuidString: key), let index = layers.firstIndex(where: { $0.id == id }) {
            target = all[index + 1]
        } else {
            let named = all.dropFirst().filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
            guard named.count <= 1 else { throw MCPToolError("More than one HUD is named “\(key)”. Use its id from list_huds.") }
            target = named.first
        }
        guard let target else { throw MCPToolError("No HUD matches “\(key)”. Use list_huds to see ids and names.") }
        guard target.editable else {
            throw MCPToolError("“\(target.name)” is a generated \(target.builtIn?.rawValue ?? "built-in") HUD; its tiles can't be edited.")
        }
        return target
    }

    private func slot(_ arguments: [String: Any], in target: HUDTarget) throws -> ExplorerSlot {
        let raw = try text(arguments, "direction", required: true, maximum: 32)!
        let slots = ExplorerSlot.slots(target.slotCount)
        guard let slot = ExplorerSlot(rawValue: raw), slots.contains(slot) else {
            throw MCPToolError("“\(raw)” is not a slot of \(target.name). Use one of: " + slots.map(\.rawValue).joined(separator: ", ") + ".")
        }
        return slot
    }

    /// Writes into a top-level HUD, mirroring the settings editor's save path.
    private func write(_ favorite: AppExplorerFavorite?, at slot: ExplorerSlot, in target: HUDTarget,
                       explorer: inout AppExplorerSettings) throws {
        var next = explorer
        if let index = target.layerIndex, var layers = next.holdLayers {
            var projected = next.projected(layerID: layers[index].id)
            projected.setFavorite(favorite, at: slot)
            if layers[index].builtIn == .mediaControls || layers[index].builtIn == .actions { layers[index].builtIn = nil }
            layers[index].favorites = projected.favorites
            next.holdLayers = layers
        } else {
            next.setFavorite(favorite, at: slot)
        }
        guard next.hasValidFavorites else {
            throw MCPToolError("That change would break the HUD limits (16 layers, 256 tiles, unique hotkeys). Nothing was changed.")
        }
        explorer = next
    }

    private func setTile(_ arguments: [String: Any], settings: inout StoredSettings) throws -> Outcome {
        try only(["hud", "direction", "action_id", "url", "app_bundle_id", "name", "browser", "replace_group"], arguments)
        var explorer = settings.appExplorer ?? AppExplorerSettings()
        let target = try resolveHUD(arguments, explorer: explorer)
        let slot = try slot(arguments, in: target)
        let name = try text(arguments, "name", maximum: 512)
        let actionID = try text(arguments, "action_id", maximum: 200)
        let url = try text(arguments, "url")
        let bundleID = try text(arguments, "app_bundle_id", maximum: 255)
        guard [actionID, url, bundleID].compactMap({ $0 }).count == 1 else {
            throw MCPToolError("Give exactly one of action_id, url or app_bundle_id.")
        }
        guard arguments["browser"] == nil || url != nil else { throw MCPToolError("“browser” applies only with url.") }
        let action: BindingAction
        if let actionID {
            guard let record = registry(settings).first(where: { $0.id == actionID }) else {
                throw MCPToolError("No action has id “\(actionID)”. Use list_actions or list_bookmarks to find ids.")
            }
            action = record.action
        } else if let url {
            action = try websiteAction(url: url, name: name, browser: try text(arguments, "browser", maximum: 16))
        } else {
            guard let bundleID, BindingAction.isValidBundleID(bundleID) else {
                throw MCPToolError("“\(bundleID ?? "")” is not a valid application bundle id.")
            }
            let appName = name ?? applications.first { $0.bundleID == bundleID }?.name ?? bundleID
            action = .openApp(bundleID: bundleID, name: appName)
        }
        guard var favorite = action.favorite(at: slot) else { throw MCPToolError("That action can't be placed on a HUD tile.") }
        if let name { favorite.name = name }
        if let existing = target.favorites.first(where: { $0.direction == slot }), existing.isGroup, try !flag(arguments, "replace_group") {
            throw MCPToolError("The \(slot.rawValue) slot holds the group “\(existing.name)” with \(existing.children?.count ?? 0) tiles. Pass replace_group=true to replace it.")
        }
        guard favorite.isValidDestination else { throw MCPToolError("That tile is not valid.") }
        try write(favorite, at: slot, in: target, explorer: &explorer)
        let changed = settings.appExplorer != explorer
        settings.appExplorer = explorer
        return Outcome(result: ["hud": target.name, "tile": tile(favorite)], changed: changed)
    }

    private func clearTile(_ arguments: [String: Any], settings: inout StoredSettings) throws -> Outcome {
        try only(["hud", "direction", "remove_group"], arguments)
        var explorer = settings.appExplorer ?? AppExplorerSettings()
        let target = try resolveHUD(arguments, explorer: explorer)
        let slot = try slot(arguments, in: target)
        guard let existing = target.favorites.first(where: { $0.direction == slot }) else {
            return Outcome(result: ["hud": target.name, "cleared": false, "message": "That slot is already empty."])
        }
        if existing.isGroup, try !flag(arguments, "remove_group") {
            throw MCPToolError("The \(slot.rawValue) slot holds the group “\(existing.name)” with \(existing.children?.count ?? 0) tiles. Pass remove_group=true to remove it and its tiles.")
        }
        try write(nil, at: slot, in: target, explorer: &explorer)
        settings.appExplorer = explorer
        return Outcome(result: ["hud": target.name, "cleared": true, "removed": tile(existing)], changed: true)
    }

    // MARK: Macros

    private func macro(_ entry: NamedHotkey) -> [String: Any] {
        var result: [String: Any] = ["id": entry.id, "name": entry.name, "summary": entry.summary,
            "step_count": entry.resolvedSequence.count, "step_delay_ms": entry.resolvedDelay,
            "action_id": VoiceRegisteredAction.id(for: .macro(entry))]
        if let key = entry.activationShortcut { result["activation_hotkey"] = key.readableCombination }
        return result
    }
}
