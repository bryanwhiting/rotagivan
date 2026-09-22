import Foundation

/// An audit of configured Rotagivan bindings, not a scan of other apps' shortcuts.
struct HotkeyAudit {
    struct Assignment: Identifiable {
        let id: String
        let scope: String
        let trigger: String
        let action: String
        let shortcut: RecordedShortcut?
        let enabled: Bool
        var precedence: String = ""
        // nil: output action; empty string: globally registered input; otherwise HUD-local input.
        var inputScope: String? = nil
        var application: String? = nil
        var kind = "Assignment"
        var searchText: String {
            "\(kind) \(scope) \(trigger) \(action) \(shortcut?.readableCombination ?? "") \(precedence)"
        }
    }
    enum Kind: String, CaseIterable { case conflict = "Conflicts", override = "App overrides", reuse = "Reused outputs", caution = "Potential overlaps" }
    struct Finding: Identifiable {
        let id: String
        let kind: Kind
        let title: String
        let detail: String
    }
    var assignments: [Assignment] = []
    var findings: [Finding] = []

    init(settings: StoredSettings, shortcuts: ShortcutConfiguration, layerID: UInt32, device: GestureDevice) {
        let dictionary = settings.resolvedHotkeyDictionary
        let deviceEnabled = settings.enabled && (device == .apple ? settings.resolvedDevices.appleEnabled : settings.resolvedDevices.navigatorEnabled)
        var base = settings.effectiveGestures(for: layerID)
        if device == .apple, !settings.resolvedDevices.shareTapActions,
           let custom = settings.devices?.appleLayerGestures?[layerID] { base = custom }
        func output(_ binding: AppGestureBinding) -> RecordedShortcut? {
            switch binding.action {
            case .shortcut: return binding.shortcut
            case .enter: return RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return")
            case .optionF19: return RecordedShortcut(keyCode: 80, modifiers: 1 << 19, keyLabel: "F19")
            default: return nil
            }
        }
        func actionName(_ binding: AppGestureBinding) -> String {
            output(binding).map { dictionary.title(for: $0) } ?? binding.action.title
        }
        for trigger in AppGestureTrigger.allCases {
            let global = trigger.assignment(in: base)
            let apps = settings.resolvedAppOverrides.filter { $0.enabled && $0.bindings.contains { $0.trigger == trigger } }
            assignments.append(Assignment(id: "global.\(trigger.rawValue)", scope: "Global layer actions",
                trigger: trigger.title, action: actionName(global.binding), shortcut: output(global.binding),
                enabled: deviceEnabled && global.enabled,
                precedence: apps.isEmpty ? "Default outside app-specific rules" : "Replaced in: " + apps.map(\.name).joined(separator: ", "),
                kind: "Tap or gesture"))
        }
        for app in settings.resolvedAppOverrides {
            let effective = app.applying(to: base)
            for binding in app.bindings {
                let inherited = binding.trigger.assignment(in: base)
                let resolved = binding.trigger.assignment(in: effective)
                let detail = "\(binding.trigger.title): \(actionName(inherited.binding)) → \(actionName(binding))"
                let navigation = binding.trigger == .twoFingerLeft || binding.trigger == .twoFingerRight
                let applies = deviceEnabled && app.enabled && (base.gestures.tapToClick || navigation)
                let explanation = !app.enabled ? "App rule disabled" : !base.gestures.tapToClick && !navigation ? "Tap actions disabled in this layer" : "Replaces the global action while \(app.name) is frontmost"
                assignments.append(Assignment(id: "app.\(app.bundleID).\(binding.trigger.rawValue)", scope: app.name,
                    trigger: binding.trigger.title, action: actionName(binding), shortcut: output(binding),
                    enabled: applies && resolved.enabled, precedence: explanation, kind: "Tap or gesture"))
                if applies {
                    findings.append(Finding(id: "override.\(app.bundleID).\(binding.trigger.rawValue)", kind: .override,
                        title: "\(app.name) overrides \(binding.trigger.title.lowercased())",
                        detail: detail + (binding.action == .none ? ". This explicitly disables the action in this app." : ". Intentional precedence, not a registration conflict.")))
                }
            }
        }
        if deviceEnabled && base.gestures.tapToClick {
            let rhythms: [(String, AppGestureTrigger, AppGestureTrigger, AppGestureTrigger)] = [
                ("One-finger", .oneFingerTap, .oneFingerDoubleTap, .oneFingerTripleTap),
                ("Two-finger", .twoFingerTap, .twoFingerDoubleTap, .twoFingerTripleTap)]
            for (name, single, double, triple) in rhythms {
                if single.assignment(in: base).enabled && (double.assignment(in: base).enabled || triple.assignment(in: base).enabled) {
                    findings.append(Finding(id: "rhythm." + name, kind: .caution, title: "\(name) multi-tap precedence",
                        detail: "Double and triple taps replace shorter tap actions. Single taps wait for the recognition window; this is intentional gesture precedence, not a duplicate hotkey."))
                }
            }
        }
        func name(_ id: UInt32) -> String { settings.profileName(for: id, fallback: id == 1 ? "Normal" : id == 2 ? "Precision" : settings.additionalProfiles?.first { $0.id == id }?.name ?? "Layer \(id)") }
        func recorded(_ key: ProfileShortcut) -> RecordedShortcut {
            let flags: UInt64 = (key.modifiers & 256 != 0 ? 1 << 20 : 0) | (key.modifiers & 4096 != 0 ? 1 << 18 : 0) |
                (key.modifiers & 2048 != 0 ? 1 << 19 : 0) | (key.modifiers & 512 != 0 ? 1 << 17 : 0)
            let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
            let label = key.keyLabel ?? functionKeys.firstIndex(of: key.keyCode).map { "F\($0 + 1)" } ?? "Key \(key.keyCode)"
            return RecordedShortcut(keyCode: UInt16(clamping: key.keyCode), modifiers: flags, keyLabel: label)
        }
        for entry in dictionary {
            guard let shortcut = entry.activationShortcut else { continue }
            assignments.append(Assignment(id: "dictionary.hotkey.\(entry.id)", scope: "Global keyboard hotkeys",
                trigger: shortcut.readableCombination, action: "Run \(entry.name): \(entry.summary)", shortcut: shortcut,
                enabled: settings.enabled, precedence: "Registered globally by Rotagivan", inputScope: "", kind: "Hotkey"))
        }
        let activations: [(UInt32, ProfileShortcut)] = [(1, shortcuts.normal), (2, shortcuts.precision)] + shortcuts.additional.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        for (id, key) in activations where id != settings.resolvedDefaultProfileID {
            let shortcut = recorded(key)
            assignments.append(Assignment(id: "activation.\(id)", scope: "Global keyboard hotkeys", trigger: "Activate \(name(id))",
                action: dictionary.title(for: shortcut), shortcut: shortcut, enabled: settings.enabled && key.enabled, inputScope: ""))
        }
        let own = shortcuts.profileActions[layerID]?.count == 3 ? shortcuts.profileActions[layerID]! : shortcuts.actions
        let primary = shortcuts.profileActions[settings.resolvedDefaultProfileID]?.count == 3 ? shortcuts.profileActions[settings.resolvedDefaultProfileID]! : shortcuts.actions
        let inherit = layerID != settings.resolvedDefaultProfileID && !(settings.customTapProfiles ?? []).contains(layerID)
        for (index, key) in own.prefix(3).enumerated() {
            let effective: ProfileShortcut
            if index == 2 { effective = shortcuts.resolvedDragShortcut(defaultID: settings.resolvedDefaultProfileID) }
            else { effective = inherit && primary.indices.contains(index) ? primary[index] : key }
            let shortcut = recorded(effective)
            assignments.append(Assignment(id: "mouse.\(index)", scope: "Global keyboard hotkeys", trigger: ["Single click", "Double click", "Hold to drag"][index],
                action: dictionary.title(for: shortcut), shortcut: shortcut, enabled: settings.enabled && effective.enabled, inputScope: ""))
        }
        let explorer = settings.appExplorer ?? AppExplorerSettings()
        for layer in explorer.holdLayers ?? [] {
            if let key = layer.launchShortcut {
                assignments.append(Assignment(id: "hud.launch.\(layer.id)", scope: layer.appName ?? "All apps", trigger: "Open HUD layer: \(layer.name)",
                    action: dictionary.title(for: key), shortcut: key, enabled: settings.enabled,
                    precedence: layer.appBundleID.map { "Registered only while \($0) is frontmost" } ?? "Global HUD launcher", inputScope: "", application: layer.appBundleID))
            }
        }
        func layers(_ values: [ExplorerHoldLayer], path: String, depth: Int, active: Bool) {
            for layer in values {
                if let key = layer.holdShortcut {
                    assignments.append(Assignment(id: path + ".key." + layer.id.uuidString, scope: path, trigger: "HUD layer: \(layer.name)",
                        action: dictionary.title(for: key), shortcut: key, enabled: active, inputScope: path))
                }
                tiles(layer.favorites, path: path + " / " + layer.name, depth: depth + 1, count: layer.slotCount ?? 8, active: active)
            }
        }
        func tiles(_ values: [AppExplorerFavorite], path: String, depth: Int, count: Int, active: Bool) {
            guard depth <= 8 else { return }
            let visible = Set(ExplorerSlot.slots(count))
            for tile in values {
                let enabled = active && visible.contains(tile.direction)
                let location = path + " / " + tile.direction.title + " · " + tile.name
                if let key = tile.shortcut {
                    assignments.append(Assignment(id: location, scope: path, trigger: tile.direction.title + " · " + tile.name,
                        action: dictionary.title(for: key), shortcut: key, enabled: enabled))
                }
                if let children = tile.children { tiles(children, path: location, depth: depth + 1, count: tile.slotCount ?? 8, active: enabled && !tile.isRecentGroup) }
                if let held = tile.holdLayers { layers(held, path: location, depth: depth, active: enabled) }
            }
        }
        tiles(explorer.favorites, path: "HUD", depth: 0, count: explorer.slotCount ?? 8, active: settings.enabled)
        layers(explorer.holdLayers ?? [], path: "HUD", depth: 0, active: settings.enabled)
        if let window = explorer.windowManager {
            tiles(window.favorites ?? [], path: "Window Manager", depth: 0, count: window.slotCount ?? 8, active: settings.enabled)
            layers(window.layers, path: "Window Manager", depth: 0, active: settings.enabled)
            for binding in window.shortcuts {
                assignments.append(Assignment(id: "window.command.\(binding.command.rawValue)", scope: "Window Manager", trigger: binding.command.title,
                    action: dictionary.title(for: binding.shortcut), shortcut: binding.shortcut, enabled: settings.enabled, inputScope: "Window Manager"))
            }
        }
        for row in assignments {
            if let id = row.shortcut?.macroID {
                if let macro = dictionary.first(where: { $0.id == id }) {
                    for (index, action) in macro.resolvedSequence.enumerated() {
                        guard let step = action.shortcut else { continue }
                        assignments.append(Assignment(id: row.id + ".step.\(index)", scope: row.scope, trigger: "\(row.trigger) · \(macro.name) step \(index + 1)",
                            action: step.readableCombination, shortcut: step, enabled: row.enabled, precedence: row.precedence))
                    }
                } else {
                    findings.append(Finding(id: row.id + ".missing", kind: .caution, title: "Missing macro", detail: "\(row.scope) / \(row.trigger): reassign this action; its macro was removed."))
                }
            }
            if let id = row.shortcut?.hudLayerID, !(explorer.holdLayers ?? []).contains(where: { $0.id == id }) {
                findings.append(Finding(id: row.id + ".missing", kind: .caution, title: "Missing HUD layer", detail: "\(row.scope) / \(row.trigger): the target layer was removed."))
            }
        }
        let keyed = assignments.filter { $0.enabled && $0.shortcut?.isPhysicalShortcut == true }
        for (identity, rows) in Dictionary(grouping: keyed, by: { $0.shortcut!.identity }).sorted(by: { $0.key < $1.key }) {
            let title = dictionary.title(for: rows[0].shortcut!)
            let inputs = rows.filter { $0.inputScope != nil }
            let outputs = rows.filter { $0.inputScope == nil }
            let globals = inputs.filter { $0.inputScope == "" }
            let competing = globals.filter { row in globals.contains { other in
                other.id != row.id && (row.application == nil || other.application == nil || row.application == other.application)
            } }
            if !competing.isEmpty {
                findings.append(Finding(id: "conflict." + identity, kind: .conflict, title: title,
                    detail: "Competing global hotkeys: " + competing.map(\.trigger).joined(separator: ", ") + ". These cannot all register together in the same app."))
            }
            let localGroups = Dictionary(grouping: inputs.filter { $0.inputScope != "" }, by: { $0.inputScope! })
            for (scope, local) in localGroups.sorted(by: { $0.key < $1.key }) where local.count > 1 || !globals.isEmpty {
                findings.append(Finding(id: "local.\(scope).\(identity)", kind: .caution, title: title + " · " + scope,
                    detail: "Overlapping HUD controls: " + (globals + local).map(\.trigger).joined(separator: ", ") + ". Check precedence while this HUD group is open."))
            }
            if !globals.isEmpty && !outputs.isEmpty {
                findings.append(Finding(id: "interception." + identity, kind: .caution, title: title,
                    detail: "This action sends a combination also used by a Rotagivan global hotkey (" + globals.map(\.trigger).joined(separator: ", ") + "). It may be intercepted instead of reaching the intended app."))
            }
            if outputs.count > 1 {
                findings.append(Finding(id: "reuse." + identity, kind: .reuse, title: title,
                    detail: "Used by " + outputs.map { $0.scope + " / " + $0.trigger }.joined(separator: "; ") + ". Reusing an output shortcut is allowed; it is not a hotkey-registration conflict."))
            }
        }
    }
}

extension AppGestureTrigger {
    func assignment(in taps: ProfileGestures) -> (binding: AppGestureBinding, enabled: Bool) {
        var action: TapAction = .none
        var shortcut: RecordedShortcut?
        var enabled = taps.gestures.tapToClick
        switch self {
        case .oneFingerTap: action = taps.oneFingerTap; shortcut = taps.oneFingerShortcut
        case .twoFingerTap: action = taps.twoFingerTap; shortcut = taps.twoFingerShortcut
        case .oneFingerDoubleTap: action = taps.oneFingerDoubleTap ?? .none; shortcut = taps.oneFingerDoubleShortcut
        case .twoFingerDoubleTap: action = taps.twoFingerDoubleTap ?? .none; shortcut = taps.twoFingerDoubleShortcut
        case .oneFingerTripleTap: action = taps.oneFingerTripleTap ?? .none; shortcut = taps.oneFingerTripleShortcut
        case .twoFingerTripleTap: action = taps.twoFingerTripleTap ?? .none; shortcut = taps.twoFingerTripleShortcut
        default:
            let swipe: DoubleTapSwipeSettings?
            switch rawValue.split(separator: ".").first {
            case "single": swipe = taps.singleTapSwipe
            case "double": swipe = taps.doubleTapSwipe
            case "twoSingle": swipe = taps.twoFingerSingleTapSwipe
            case "twoDouble": swipe = taps.twoFingerDoubleTapSwipe
            default: swipe = taps.twoFingerSwipe; enabled = true // Navigation does not require tap-to-click.
            }
            if let swipe, let direction {
                action = swipe.action(for: direction); shortcut = swipe[direction]
                enabled = enabled && swipe.enabled
            } else { enabled = false }
        }
        return (AppGestureBinding(trigger: self, action: action, shortcut: shortcut), enabled && action != .none)
    }
}
