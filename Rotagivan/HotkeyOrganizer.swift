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
        var boundAction: BindingAction? = nil
        var precedence: String = ""
        // nil: output action; empty string: globally registered input; otherwise HUD-local input.
        var inputScope: String? = nil
        var application: String? = nil
        var kind = "Assignment"
        var gesture: AppGestureTrigger? = nil
        // Output records participate in conflict analysis but fold into their
        // owning assignment for presentation and shortcut searches.
        var parentAssignmentID: String? = nil
        var outputShortcuts: [RecordedShortcut] = []
        var searchableShortcuts: [RecordedShortcut] { ([shortcut].compactMap { $0 }) + outputShortcuts }
        var searchText: String {
            "\(kind) \(scope) \(trigger) \(action) \(searchableShortcuts.map(\.readableCombination).joined(separator: " ")) \(precedence)"
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
    var displayAssignments: [Assignment] {
        let outputs = Dictionary(grouping: assignments.filter { $0.parentAssignmentID != nil }, by: { $0.parentAssignmentID! })
        return assignments.filter { $0.parentAssignmentID == nil }.map { original in
            var row = original
            row.outputShortcuts = (outputs[row.id] ?? []).compactMap(\.shortcut)
            return row
        }
    }

    init(settings: StoredSettings, shortcuts: ShortcutConfiguration, layerID: UInt32, device: GestureDevice) {
        let dictionary = settings.resolvedHotkeyDictionary
        let deviceEnabled = settings.enabled && (device == .apple ? settings.resolvedDevices.appleEnabled : settings.resolvedDevices.navigatorEnabled)
        var base = settings.effectiveGestures(for: layerID)
        if device == .apple, !settings.resolvedDevices.shareTapActions,
           let custom = settings.devices?.appleLayerGestures?[layerID] { base = custom }
        base = settings.applyingActionBindings(to: base)
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
            if !(settings.actionBindings ?? []).contains(where: { $0.trigger.gesture == trigger }) {
            assignments.append(Assignment(id: "global.\(trigger.rawValue)", scope: "Global layer actions",
                trigger: trigger.title, action: actionName(global.binding), shortcut: output(global.binding),
                enabled: deviceEnabled && global.enabled,
                precedence: apps.isEmpty ? "Default outside app-specific rules" : "Replaced in: " + apps.map(\.name).joined(separator: ", "),
                kind: "Tap or gesture"))
            }
        }
        for app in settings.resolvedAppOverrides {
            let effective = app.applying(to: base)
            for binding in app.bindings {
                let inherited = binding.trigger.assignment(in: base)
                let resolved = binding.trigger.assignment(in: effective)
                let detail = "\(binding.trigger.title): \(actionName(inherited.binding)) → \(actionName(binding))"
                let navigation = [.twoFingerLeft, .twoFingerRight, .twoFingerUp, .twoFingerDown].contains(binding.trigger)
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
                enabled: settings.enabled, boundAction: .macro(entry), precedence: "Registered globally by Rotagivan", inputScope: "", kind: "Hotkey"))
            for (index, step) in entry.resolvedSequence.enumerated() {
                guard let output = step.shortcut else { continue }
                assignments.append(Assignment(id: "dictionary.hotkey.\(entry.id).step.\(index)", scope: "Global keyboard hotkeys",
                    trigger: shortcut.readableCombination, action: output.readableCombination, shortcut: output,
                    enabled: settings.enabled, kind: "Output", parentAssignmentID: "dictionary.hotkey.\(entry.id)"))
            }
        }
        let activations: [(UInt32, ProfileShortcut)] = [(1, shortcuts.normal), (2, shortcuts.precision)] + shortcuts.additional.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        for (id, key) in activations where settings.availableLayerIDs.contains(id) && id != settings.resolvedDefaultProfileID {
            let shortcut = recorded(key)
            assignments.append(Assignment(id: "activation.\(id)", scope: "Global keyboard hotkeys", trigger: shortcut.readableCombination,
                action: "Activate \(name(id))", shortcut: shortcut, enabled: settings.enabled && key.enabled, inputScope: ""))
        }
        let own = shortcuts.profileActions[layerID]?.count == 3 ? shortcuts.profileActions[layerID]! : shortcuts.actions
        let primary = shortcuts.profileActions[settings.resolvedDefaultProfileID]?.count == 3 ? shortcuts.profileActions[settings.resolvedDefaultProfileID]! : shortcuts.actions
        let inherit = layerID != settings.resolvedDefaultProfileID && !(settings.customTapProfiles ?? []).contains(layerID)
        for (index, key) in own.prefix(3).enumerated() {
            let effective: ProfileShortcut
            if index == 2 { effective = shortcuts.resolvedDragShortcut(defaultID: settings.resolvedDefaultProfileID) }
            else { effective = inherit && primary.indices.contains(index) ? primary[index] : key }
            let shortcut = recorded(effective)
            assignments.append(Assignment(id: "mouse.\(index)", scope: "Global keyboard hotkeys", trigger: shortcut.readableCombination,
                action: ["Single click", "Double click", "Hold to drag"][index], shortcut: shortcut, enabled: settings.enabled && effective.enabled, inputScope: ""))
        }
        let explorer = settings.appExplorer ?? AppExplorerSettings()
        func bindings(_ values: [ActionBinding], path: String, global: Bool, active: Bool) {
            for binding in values {
                let key = binding.trigger.keyboard
                assignments.append(Assignment(id: path + ".binding." + binding.id.uuidString,
                    scope: path, trigger: binding.trigger.title, action: dictionary.title(for: binding.action),
                    shortcut: key, enabled: active && (binding.trigger.gesture == nil || deviceEnabled), boundAction: binding.action,
                    precedence: global ? "Global binding; app gesture rules take precedence" : "Runs while this HUD layer is visible; assigned gestures take precedence over HUD navigation",
                    inputScope: global ? "" : path, kind: binding.trigger.gesture == nil ? "Hotkey" : "Tap or gesture",
                    gesture: binding.trigger.gesture))
                if let output = binding.action.shortcut {
                    assignments.append(Assignment(id: path + ".binding.output." + binding.id.uuidString,
                        scope: path, trigger: binding.trigger.title, action: output.readableCombination,
                        shortcut: output, enabled: active, kind: "Output", gesture: binding.trigger.gesture,
                        parentAssignmentID: path + ".binding." + binding.id.uuidString))
                }
                if let id = binding.action.macroID, let macro = dictionary.first(where: { $0.id == id }) {
                    for (index, step) in macro.resolvedSequence.enumerated() {
                        guard let output = step.shortcut else { continue }
                        assignments.append(Assignment(id: path + ".binding." + binding.id.uuidString + ".step.\(index)",
                            scope: path, trigger: binding.trigger.title + " · " + macro.name,
                            action: output.readableCombination, shortcut: output,
                            enabled: active && (binding.trigger.gesture == nil || deviceEnabled), kind: "Output",
                            parentAssignmentID: path + ".binding." + binding.id.uuidString))
                    }
                }
                if let id = binding.action.macroID, !dictionary.contains(where: { $0.id == id }) {
                    findings.append(Finding(id: binding.id.uuidString + ".missing", kind: .caution,
                        title: "Missing saved action", detail: path + " / " + binding.trigger.title))
                }
                if let id = binding.action.hudLayerID, !(explorer.holdLayers ?? []).contains(where: { $0.id == id }) {
                    findings.append(Finding(id: binding.id.uuidString + ".missing", kind: .caution,
                        title: "Missing HUD layer", detail: path + " / " + binding.trigger.title))
                }
                if binding.action.hudPath != nil {
                    if !explorer.containsHUDActionTarget(binding.action) {
                        findings.append(Finding(id: binding.id.uuidString + ".missingPath", kind: .caution,
                            title: "Missing HUD layer", detail: path + " / " + binding.trigger.title))
                    }
                }
            }
        }
        bindings(settings.actionBindings ?? [], path: "Global bindings", global: true, active: settings.enabled)
        bindings(explorer.actionBindings ?? [], path: "HUD", global: false, active: settings.enabled)
        for layer in explorer.holdLayers ?? [] {
            if let key = layer.launchShortcut {
                assignments.append(Assignment(id: "hud.launch.\(layer.id)", scope: "Global keyboard hotkeys", trigger: key.readableCombination,
                    action: "Open HUD layer: \(layer.name)", shortcut: key, enabled: settings.enabled,
                    boundAction: explorer.hudActionDestinations().first { $0.windowOwnerPath == nil && $0.path == [.layer(layer.id)] }.map { .hudDestination($0) },
                    precedence: "Global HUD launcher", inputScope: ""))
            }
        }
        func layers(_ values: [ExplorerHoldLayer], path: String, depth: Int, active: Bool) {
            for layer in values {
                bindings(layer.actionBindings ?? [], path: path + " / " + layer.name, global: false, active: active)
                if let key = layer.holdShortcut {
                    assignments.append(Assignment(id: path + ".key." + layer.id.uuidString, scope: path, trigger: key.readableCombination,
                        action: "Open HUD layer: \(layer.name)", shortcut: key, enabled: active, boundAction: explorer.hudActionDestinations().first { $0.path.last == .layer(layer.id) }.map { .hudDestination($0) }, inputScope: path))
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
                if let key = tile.activationShortcut {
                    assignments.append(Assignment(id: location + ".activation", scope: path,
                        trigger: key.readableCombination, action: "Run \(tile.name)", shortcut: key,
                        enabled: enabled, boundAction: BindingAction.from(favorite: tile), precedence: "Available while this HUD layer is visible",
                        inputScope: path, kind: "Hotkey"))
                }
                if let key = tile.shortcut {
                    assignments.append(Assignment(id: location, scope: path, trigger: tile.direction.title + " · " + tile.name,
                        action: dictionary.title(for: key), shortcut: key, enabled: enabled))
                }
                if let children = tile.children { tiles(children, path: location, depth: depth + 1, count: tile.slotCount ?? 8, active: enabled && !tile.isRecentGroup) }
                bindings(tile.actionBindings ?? [], path: location, global: false, active: enabled && !tile.isRecentGroup)
                if let held = tile.holdLayers { layers(held, path: location, depth: depth, active: enabled) }
            }
        }
        tiles(explorer.favorites, path: "HUD", depth: 0, count: explorer.slotCount ?? 8, active: settings.enabled)
        layers(explorer.holdLayers ?? [], path: "HUD", depth: 0, active: settings.enabled)
        if let window = explorer.windowManager {
            bindings(window.actionBindings ?? [], path: "Window Manager", global: false, active: settings.enabled)
            tiles(window.favorites ?? [], path: "Window Manager", depth: 0, count: window.slotCount ?? 8, active: settings.enabled)
            layers(window.layers, path: "Window Manager", depth: 0, active: settings.enabled)
            for binding in window.shortcuts {
                assignments.append(Assignment(id: "window.command.\(binding.command.rawValue)", scope: "Window Manager", trigger: binding.shortcut.readableCombination,
                    action: binding.command.title, shortcut: binding.shortcut, enabled: settings.enabled, boundAction: .command(binding.command), inputScope: "Window Manager"))
            }
        }
        for row in assignments {
            if let target = row.shortcut?.assignedAction, target.kind == .hudLayer,
               !explorer.containsHUDActionTarget(target) {
                findings.append(Finding(id: row.id + ".missingTarget", kind: .caution,
                    title: "Missing HUD layer", detail: row.scope + " / " + row.trigger))
            }
            if let output = row.shortcut?.assignedAction?.shortcut {
                assignments.append(Assignment(id: row.id + ".output", scope: row.scope, trigger: row.trigger,
                    action: output.readableCombination, shortcut: output, enabled: row.enabled,
                    kind: "Output", parentAssignmentID: row.id))
            }
            if let id = row.shortcut?.macroID ?? row.shortcut?.assignedAction?.macroID {
                if let macro = dictionary.first(where: { $0.id == id }) {
                    for (index, action) in macro.resolvedSequence.enumerated() {
                        guard let step = action.shortcut else { continue }
                        assignments.append(Assignment(id: row.id + ".step.\(index)", scope: row.scope, trigger: "\(row.trigger) · \(macro.name) step \(index + 1)",
                            action: step.readableCombination, shortcut: step, enabled: row.enabled, precedence: row.precedence,
                            kind: "Output", parentAssignmentID: row.id))
                    }
                } else {
                    findings.append(Finding(id: row.id + ".missing", kind: .caution, title: "Missing macro", detail: "\(row.scope) / \(row.trigger): reassign this action; its macro was removed."))
                }
            }
            if let id = row.shortcut?.hudLayerID ?? row.shortcut?.assignedAction?.hudLayerID, !(explorer.holdLayers ?? []).contains(where: { $0.id == id }) {
                findings.append(Finding(id: row.id + ".missing", kind: .caution, title: "Missing HUD layer", detail: "\(row.scope) / \(row.trigger): the target layer was removed."))
            }
        }
        let keyed = assignments.filter { $0.enabled && $0.shortcut?.isPhysicalShortcut == true }
        let gestureInputs = assignments.filter { $0.enabled && $0.gesture != nil && $0.inputScope != nil }
        for (trigger, rows) in Dictionary(grouping: gestureInputs, by: { $0.gesture!.rawValue }) {
            for (scope, scoped) in Dictionary(grouping: rows, by: { $0.inputScope! }) where scoped.count > 1 {
                findings.append(Finding(id: "gesture.\(scope).\(trigger)", kind: .conflict,
                    title: scoped[0].trigger, detail: "Multiple actions in \(scope.isEmpty ? "Global bindings" : scope): " + scoped.map(\.action).joined(separator: ", ")))
            }
        }
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
                    detail: "Overlapping HUD controls: " + (globals + local).map(\.trigger).joined(separator: ", ") + ". Check precedence while this HUD layer is open."))
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
