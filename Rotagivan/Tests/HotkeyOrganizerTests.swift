import Foundation

@main struct HotkeyOrganizerTests {
    static func main() throws {
        let key = RecordedShortcut(keyCode: 8, modifiers: (1 << 20) | (1 << 17), keyLabel: "C")
        let trigger = RecordedShortcut(keyCode: 64, modifiers: (1 << 20) | (1 << 19), keyLabel: "F17")
        let named = NamedHotkey(name: "Capture selection", shortcut: key, activationShortcut: trigger)
        precondition([named].title(for: key) == "Capture selection (Cmd+Shift+C)")
        var alias = key; alias.keyLabel = "Different layout"
        precondition([named].label(for: alias) == named.name, "Names must match physical key/modifiers, not display labels")
        precondition(![named, NamedHotkey(name: "Duplicate", shortcut: alias)].isValidDictionary)
        precondition(![NamedHotkey(name: " ", shortcut: key)].isValidDictionary)
        let otherOutput = RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17")
        precondition(![named, NamedHotkey(name: "Duplicate trigger", shortcut: otherOutput, activationShortcut: trigger)].isValidDictionary)
        precondition(!NamedHotkey(name: "Bare letter", shortcut: key,
            activationShortcut: RecordedShortcut(keyCode: 8, modifiers: 0, keyLabel: "C")).isValid)
        precondition([NamedHotkey(name: "Résumé ✨", shortcut: key)].isValidDictionary)
        var settings = StoredSettings()
        settings.appOverrides = []
        settings.hotkeyDictionary = [named]
        var keys = ShortcutConfiguration()
        keys.precision.enabled = false
        var taps = settings.gestures(for: 1)
        taps.gestures.tapToClick = true
        taps.oneFingerTap = .shortcut; taps.oneFingerShortcut = key
        taps.twoFingerTap = .shortcut; taps.twoFingerShortcut = key
        settings.profileGestures = [1: taps]
        let layerActionKey = RecordedShortcut(keyCode: 15, modifiers: 1 << 20, keyLabel: "R")
        settings.appExplorer = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .left, name: "Group", children: [
            AppExplorerFavorite(direction: .up, name: "Existing name", shortcut: key,
                activationShortcut: layerActionKey)
        ])])
        func audit(_ layer: UInt32 = 1, _ device: GestureDevice = .navigator) -> HotkeyAudit {
            HotkeyAudit(settings: settings, shortcuts: keys, layerID: layer, device: device)
        }
        precondition(audit().assignments.contains { $0.id == "dictionary.hotkey.\(named.id)" && $0.inputScope == "" })
        precondition(audit().assignments.first { $0.id == "global.oneFingerTap" }?.kind == "Tap or gesture")
        precondition(audit().findings.contains { $0.kind == .reuse })
        precondition(!audit().findings.contains { $0.kind == .conflict }, "Repeated outgoing shortcuts are not registration conflicts")
        precondition(audit().assignments.contains { $0.scope.contains("Group") && $0.action == "Capture selection (Cmd+Shift+C)" })
        precondition(audit().assignments.contains {
            $0.kind == "Hotkey" && $0.shortcut == layerActionKey && $0.action == "Run Existing name" && $0.inputScope?.contains("Group") == true
        })
        settings.appOverrides = [AppGestureOverride(bundleID: "test.app", name: "Editor", bindings: [AppGestureBinding(trigger: .oneFingerTap, action: .none)])]
        let rule = audit().findings.first { $0.kind == .override }!
        precondition(rule.detail.contains("Capture selection") && rule.detail.contains("Nothing"))
        precondition(audit().assignments.first { $0.id == "global.oneFingerTap" }!.precedence.contains("Editor"))
        settings.appOverrides?[0].enabled = false
        precondition(!audit().findings.contains { $0.kind == .override })
        keys.precision = ProfileShortcut(keyCode: 8, modifiers: 256 | 512, enabled: true, keyLabel: "C")
        keys.actions[0] = keys.precision
        precondition(audit().findings.filter { $0.kind == .conflict }.count == 1, "Carbon and Cocoa modifier representations normalize to the same key")
        precondition(audit().findings.contains { $0.id.hasPrefix("interception.") })
        settings.defaultProfileID = 2
        precondition(!audit().findings.contains { $0.kind == .conflict }, "Default layer activation never registers")
        settings.defaultProfileID = 1
        keys.actions[0].enabled = false
        precondition(!audit().findings.contains { $0.kind == .conflict })
        settings.customTapProfiles = [2]
        var different = taps; different.oneFingerTap = .rightClick; different.twoFingerTap = .none
        settings.profileGestures?[2] = different
        precondition(audit(2).assignments.first { $0.id == "global.oneFingerTap" }?.action == "Right click")
        settings.devices = ProfileDevices(shareTapActions: false, appleLayerGestures: [1: different])
        precondition(audit(1, .apple).assignments.first { $0.id == "global.oneFingerTap" }?.action == "Right click")
        settings.profileGestures?[1]?.gestures.tapToClick = false
        settings.appOverrides = [.chrome]
        precondition(audit().findings.filter { $0.kind == .override }.count == 2, "Two-finger navigation works independently of taps")
        let a = ExplorerHoldLayer(name: "First", holdShortcut: key)
        let b = ExplorerHoldLayer(name: "Second", holdShortcut: key)
        settings.appExplorer?.holdLayers = [a, b]
        precondition(audit().findings.contains { $0.id.hasPrefix("local.") })
        settings.appExplorer?.holdLayers = nil
        settings.appExplorer?.holdShortcut = key
        precondition(!audit().assignments.contains { $0.id == "hud.open" }, "Retired root shortcut is not an active hotkey")
        keys.precision.enabled = false
        settings.appExplorer?.favorites = [
            AppExplorerFavorite(direction: .left, name: "A", children: [], holdLayers: [a]),
            AppExplorerFavorite(direction: .right, name: "B", children: [], holdLayers: [b])
        ]
        precondition(!audit().findings.contains { $0.id.hasPrefix("local.") }, "Keys in separate groups are not simultaneous conflicts")
        let decoded = try JSONDecoder().decode(StoredSettings.self, from: JSONEncoder().encode(settings))
        precondition(decoded.hotkeyDictionary == [named])
        precondition(StoredSettings().resolvedHotkeyDictionary.isEmpty, "No example shortcuts are seeded")
        let independentTap = ActionBinding(trigger: BindingTrigger(gesture: .oneFingerTap), action: .macro(named))
        settings.actionBindings = [independentTap]
        settings.appExplorer?.actionBindings = [ActionBinding(trigger: BindingTrigger(keyboard: layerActionKey),
            action: .openURL("https://example.com"))]
        let unifiedAudit = audit()
        precondition(unifiedAudit.assignments.contains { $0.gesture == .oneFingerTap && $0.inputScope == "" })
        precondition(!unifiedAudit.assignments.contains { $0.id == "global.oneFingerTap" },
            "A unified gesture replaces the inherited row, rather than appearing twice")
        precondition(unifiedAudit.assignments.contains { $0.id.contains(independentTap.id.uuidString) && $0.kind == "Output" && $0.shortcut == key },
            "Macros triggered by unified bindings expose physical outputs for interception analysis")
        precondition(unifiedAudit.assignments.contains { $0.action == "https://example.com" && $0.shortcut == layerActionKey },
            "Independent Default HUD actions appear in the assignment inventory")
        print("Hotkey organizer passed: global action triggers, tap inventory, dictionary identity/labels, inheritance/device scope, conflicts vs reuse, app precedence, nested HUDs and persistence")
    }
}
