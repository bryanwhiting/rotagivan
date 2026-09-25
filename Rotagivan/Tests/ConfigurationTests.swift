import Foundation
import ConfigurationYAML

@main
struct ConfigurationTests {
    static func canonical(_ value: Any, key: String = "") -> Any {
        if let map = value as? [String: Any] {
            return map.mapValues { $0 }.reduce(into: [String: Any]()) { out, pair in
                out[pair.key] = canonical(pair.value, key: pair.key)
            }
        }
        if let list = value as? [Any] {
            if ["profileNames", "profileGestures", "appleLayerGestures", "sliderBaselines", "additional", "profileActions"].contains(key) {
                precondition(list.count % 2 == 0)
                var map: [String: Any] = [:]
                for i in stride(from: 0, to: list.count, by: 2) {
                    map[String(describing: list[i])] = canonical(list[i+1])
                }
                return map
            }
            if ["customTapProfiles", "removedLayerIDs"].contains(key) { return list.map { String(describing: $0) }.sorted() }
            return list.map { canonical($0) }
        }
        return value
    }

    static func equal<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
        let a = canonical(try JSONSerialization.jsonObject(with: JSONEncoder().encode(lhs))) as! [String: Any]
        let b = canonical(try JSONSerialization.jsonObject(with: JSONEncoder().encode(rhs))) as! [String: Any]
        return NSDictionary(dictionary: a).isEqual(to: b)
    }

    static func rejected(_ text: String, _ label: String) {
        do { _ = try AppConfiguration.parse(text); fatalError("Accepted invalid config: \(label)") }
        catch { print("Rejected \(label)") }
    }

    @MainActor static func main() throws {
        let yaml = try String(contentsOfFile: "Rotagivan/DefaultConfiguration.yaml", encoding: .utf8)
        let factory = try AppConfiguration.parse(yaml)
        var builtInConfig = factory
        var builtInMap = AppExplorerSettings()
        for (kind, position) in zip(HUDLayerBuiltIn.allCases, HUDLayerPosition.legacyOrder) {
            precondition(builtInMap.assignBuiltIn(kind, at: position) != nil)
        }
        builtInConfig.settings.appExplorer = builtInMap
        let builtInYAML = try builtInConfig.yaml()
        let restoredBuiltIns = try AppConfiguration.parse(builtInYAML)
        precondition(restoredBuiltIns.settings.appExplorer == builtInMap,
            "Built-in HUD assignments must survive manual YAML save/load")
        let builtInFingerprintMatches = try restoredBuiltIns.syncFingerprint() == builtInConfig.syncFingerprint()
        precondition(builtInFingerprintMatches)
        var macroConfig = factory
        let firstStep = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
        let macro = NamedHotkey(name: "Copy then paste", shortcut: firstStep,
            steps: [firstStep, RecordedShortcut(keyCode: 9, modifiers: 1 << 20, keyLabel: "V")], stepDelayMilliseconds: 150,
            activationShortcut: RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17"))
        let hudLayer = ExplorerHoldLayer(name: "Editor", holdShortcut: nil, favorites: [AppExplorerFavorite(direction: .up, name: macro.name, shortcut: .macro(macro))],
            launchShortcut: RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17"), appBundleID: "test.editor", appName: "Editor")
        macroConfig.settings.hotkeyDictionary = [macro]
        macroConfig.settings.appExplorer = AppExplorerSettings(holdLayers: [hudLayer])
        var macroTaps = macroConfig.settings.gestures(for: 1)
        macroTaps.twoFingerDoubleTap = .shortcut; macroTaps.twoFingerDoubleShortcut = .hudLayer(hudLayer)
        macroTaps.oneFingerTap = .shortcut; macroTaps.oneFingerShortcut = .macro(macro)
        macroConfig.settings.profileGestures = [1: macroTaps]
        let macroYAML = try macroConfig.yaml()
        let macroRoundtrip = try AppConfiguration.parse(macroYAML)
        precondition(tryEqual(macroConfig, macroRoundtrip))
        rejected(macroYAML.replacingOccurrences(of: "stepDelayMilliseconds: 150", with: "stepDelayMilliseconds: 9999"), "invalid macro delay")
        var invalidMacro = macroConfig; invalidMacro.settings.hotkeyDictionary?[0].steps = [.macro(macro)]
        do { try invalidMacro.validate(); fatalError("Accepted recursive macro") } catch { print("Rejected recursive macro") }
        print("Macro/HUD YAML passed: ordered steps, delays, stable action references, legacy layer metadata and import")
        var appMacroConfig = macroConfig
        appMacroConfig.settings.hotkeyDictionary?[0].steps = nil
        appMacroConfig.settings.hotkeyDictionary?[0].sequence = [.app(bundleID: "test.editor", name: "Editor"), .key(firstStep)]
        let appMacroYAML = try appMacroConfig.yaml()
        let appMacroRoundtrip = try AppConfiguration.parse(appMacroYAML)
        precondition(tryEqual(appMacroConfig, appMacroRoundtrip))
        rejected(appMacroYAML.replacingOccurrences(of: "kind: openApp", with: "kind: shellCommand"), "unknown macro step")
        var badAppMacro = appMacroConfig
        badAppMacro.settings.hotkeyDictionary?[0].sequence?[0].bundleID = "file:///tmp/script"
        do { try badAppMacro.validate(); fatalError("Accepted executable path as app step") } catch { print("Rejected non-app macro target") }
        print("Open-app macro YAML passed: typed sequence, global trigger, portable bundle ID, validation and roundtrip")

        // Unified actions travel through independent bindings, HUD tiles, and
        // legacy gesture payloads without depending on a tile slot.
        var unified = factory
        let actions: [BindingAction] = [
            .keystroke(firstStep), .macro(macro), .hudLayer(nil), .hudLayer(hudLayer),
            BindingAction(kind: .hudLayer, hudPath: [ExplorerTilePathStep.group(.left).token], name: "Nested"),
            BindingAction(kind: .hudLayer, hudPath: [], windowOwnerPath: [], name: "Window Manager"),
            BindingAction(kind: .hudLayer, hudPath: [], windowOwnerPath: [ExplorerTilePathStep.group(.right).token], name: "Owned window"),
            .openApp(bundleID: "com.apple.Safari", name: "Safari"), .openURL("https://example.com/docs"),
            .command(.missionControl), .command(.lockScreen), .media(.playPause),
            .windowPlacement(ExplorerWindowPlacement(direction: .left)), .tap(.rightClick)
        ]
        let independent = actions.enumerated().map { index, action in
            ActionBinding(trigger: BindingTrigger(keyboard: RecordedShortcut(keyCode: UInt16(64 + index),
                modifiers: 1 << 20, keyLabel: "Test \(index)")), action: action)
        }
        unified.settings.hotkeyDictionary = [macro]
        unified.settings.actionBindings = independent
        unified.settings.appExplorer = AppExplorerSettings(actionBindings: independent, favorites: [
            AppExplorerFavorite(actionBindings: independent, direction: .left, name: "Nested", children: []),
            AppExplorerFavorite(direction: .right, name: "Owned window", action: .windowManager)
        ], holdLayers: [ExplorerHoldLayer(actionBindings: independent, name: "Independent", holdShortcut: nil)],
        windowManager: ExplorerWindowSettings(actionBindings: independent))
        var unifiedTaps = unified.settings.gestures(for: 1)
        precondition(unifiedTaps.setLayerAction(.shortcut, shortcut: .assigned(.openURL("https://example.com/tap")),
            for: .oneFingerTap))
        precondition(unifiedTaps.setLayerAction(.shortcut, shortcut: .assigned(.media(.next)),
            for: .twoDoubleUp))
        unified.settings.profileGestures = [1: unifiedTaps]
        let unifiedYAML = try unified.yaml()
        let unifiedRoundtrip = try AppConfiguration.parse(unifiedYAML)
        precondition(tryEqual(unified, unifiedRoundtrip), "Every action and binding scope must survive YAML/sync")
        let projected = unified.settings.appExplorer!.projected(layerID: unified.settings.appExplorer!.holdLayers![0].id)
        precondition(projected.actionBindings == independent && projected.favorites.isEmpty,
            "Empty alternate layers own their bindings independently of root tiles")
        var windows = unified.settings.appExplorer!
        var windowEditor = windows.windowEditor()
        precondition(windowEditor.actionBindings == independent)
        windowEditor.actionBindings = []
        precondition(windows.saveWindowEditor(windowEditor) && windows.windowManager?.actionBindings == [],
            "Window editor can clear its own bindings without changing root bindings")
        precondition(windows.actionBindings == independent)
        var duplicate = unified
        duplicate.settings.actionBindings?.append(independent[0])
        do { try duplicate.validate(); fatalError("Accepted duplicate binding") } catch {}
        var duplicateHUD = unified.settings.appExplorer!
        duplicateHUD.favorites.append(AppExplorerFavorite(direction: .down, name: "Conflict",
            url: "https://example.com", activationShortcut: independent[0].trigger.keyboard))
        precondition(!duplicateHUD.hasValidFavorites, "Tile and independent binding cannot consume the same local key")
        precondition(!BindingAction(kind: .openURL, url: "file:///tmp/private").isValid)
        precondition(!BindingAction(kind: .openURL, url: "https://example.com", tap: .rightClick).isValid)
        precondition(!RecordedShortcut(keyCode: 0, modifiers: 0, keyLabel: "Mixed",
            macroID: macro.id, assignedAction: .tap(.rightClick)).isValidExplorerShortcut)
        precondition(![ActionBinding(trigger: BindingTrigger(keyboard: firstStep, gesture: .oneFingerTap),
            action: .tap(.leftClick))].isValidBindings())
        rejected(unifiedYAML.replacingOccurrences(of: "kind: openURL", with: "kind: shell"), "unknown unified action")
        print("Unified bindings passed: every action, scope, YAML/sync roundtrip, empty layer projection, window isolation, duplicate and malformed rejection")
        var namedConfig = factory
        let namedKey = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
        namedConfig.settings.hotkeyDictionary = [NamedHotkey(name: "Copy selection", shortcut: namedKey)]
        let namedYAML = try namedConfig.yaml()
        let namedRoundtrip = try AppConfiguration.parse(namedYAML)
        precondition(tryEqual(namedConfig, namedRoundtrip), "Hotkey dictionary survives YAML and sync")
        namedConfig.settings.hotkeyDictionary?.append(NamedHotkey(name: "Duplicate", shortcut: namedKey))
        do { try namedConfig.validate(); fatalError("Accepted duplicate named combination") } catch { print("Rejected duplicate dictionary combination") }
        rejected(namedYAML.replacingOccurrences(of: "Copy selection", with: ""), "empty dictionary name")
        var calibrated = factory
        calibrated.settings.navigatorTapCalibration = TapCalibrationSettings(doubleTapInterval: 0.18, tripleTapFirstInterval: 0.2,
            tripleTapSecondInterval: 0.22, singleSwipeWindow: 0.3, singleSwipeDuration: 0.12, doubleSwipeWindow: 0.4)
        calibrated.settings.appleTapCalibration = TapCalibrationSettings(doubleTapInterval: 0.25)
        let calibratedYAML = try calibrated.yaml()
        let calibratedRoundtrip = try AppConfiguration.parse(calibratedYAML)
        precondition(tryEqual(calibrated, calibratedRoundtrip), "Shared calibration survives YAML sync")
        rejected(calibratedYAML.replacingOccurrences(of: "singleSwipeDuration: 0.12", with: "singleSwipeDuration: 9.0"), "invalid shared calibration duration")
        rejected(calibratedYAML.replacingOccurrences(of: "doubleSwipeWindow: 0.4", with: "doubleSwipeWindow: 0.01"), "invalid shared calibration window")
        var reserved = factory
        reserved.settings.appExplorer = AppExplorerSettings(favorites: [
            ExplorerReservedGroup.actions.tile(at: .up),
            ExplorerReservedGroup.recentApps.tile(at: .left),
            ExplorerReservedGroup.windowManager.tile(at: .right)
        ])
        let reservedRoundtrip = try AppConfiguration.parse(reserved.yaml())
        precondition(tryEqual(reserved, reservedRoundtrip), "Reserved group instances and editing shortcuts must survive YAML")
        print("Reserved group YAML passed: Actions shortcuts, recent apps, and window groups preserve existing schema")
        var customWindows = factory
        customWindows.settings.appExplorer = AppExplorerSettings(windowManager: ExplorerWindowSettings(favorites: [
            AppExplorerFavorite(direction: .up, name: "Right two thirds", windowPlacement: ExplorerWindowPlacement(direction: .right, layout: .twoThirds))
        ], slotCount: 12))
        let windowRoundtrip = try AppConfiguration.parse(customWindows.yaml())
        precondition(tryEqual(customWindows, windowRoundtrip), "Custom window placements must survive YAML")
        let windowYAML = try customWindows.yaml()
        rejected(windowYAML.replacingOccurrences(of: "twoThirds", with: "invalidPlacementSize"), "unknown window size")
        print("Custom window-group YAML passed: per-slot placements and slot counts roundtrip; invalid sizes rejected")
        var sharedPointer = factory
        sharedPointer.settings.pointerMotion = factory.settings.resolvedPointerMotion
        sharedPointer.settings.pointerCoastBaseline = 0.83
        let pointerRoundtrip = try AppConfiguration.parse(sharedPointer.yaml())
        precondition(tryEqual(sharedPointer, pointerRoundtrip), "Shared pointer tuning must survive YAML export/import")
        let pointerYAML = try sharedPointer.yaml()
        rejected(pointerYAML.replacingOccurrences(of: "pointerCoastBaseline: 0.83", with: "pointerCoastBaseline: 4.0"), "out-of-range shared pointer baseline")
        print("Profile-wide pointer YAML passed: legacy compatibility, shared tuning roundtrip and baseline bounds")
        var profileDragging = factory
        profileDragging.settings.navigatorDragging = DraggingSettings(
            touchAndHoldDrag: false, dragRegrip: true, dragRegripWindow: 0.9)
        profileDragging.settings.navigatorRegripBaseline = 0.4
        profileDragging.shortcuts.dragShortcut = ProfileShortcut(
            keyCode: 64, modifiers: 256, enabled: true, keyLabel: "F17")
        let draggingYAML = try profileDragging.yaml()
        let draggingRoundtrip = try AppConfiguration.parse(draggingYAML)
        precondition(tryEqual(profileDragging, draggingRoundtrip),
                     "Profile-wide Navigator dragging must survive YAML export/import")
        rejected(draggingYAML.replacingOccurrences(of: "dragRegripWindow: 0.9", with: "dragRegripWindow: 9"),
                 "out-of-range profile-wide regrip window")
        rejected(draggingYAML.replacingOccurrences(of: "navigatorRegripBaseline: 0.4", with: "navigatorRegripBaseline: 9"),
                 "out-of-range profile-wide regrip baseline")
        var legacyDragShortcuts = factory.shortcuts
        legacyDragShortcuts.dragShortcut = nil
        legacyDragShortcuts.profileActions[factory.settings.resolvedDefaultProfileID]![2] = ProfileShortcut(keyCode: 106)
        precondition(legacyDragShortcuts.resolvedDragShortcut(defaultID: factory.settings.resolvedDefaultProfileID).keyCode == 106)
        print("Profile-wide dragging YAML passed: settings, shortcut, bounds and default-layer migration fallback.")
        var nested = factory
        nested.profiles = [ConfigurationProfile(id: "work", name: "Work", settings: factory.settings, shortcuts: factory.shortcuts),
            ConfigurationProfile(id: "travel", name: "Travel", settings: factory.settings, shortcuts: factory.shortcuts)]
        nested.activeConfigurationID = "work"
        nested.profiles![1].settings.devices = ProfileDevices(navigatorEnabled: false, appleEnabled: true, shareTapActions: false,
            appleLayerGestures: [1: ProfileGestures(gestures: GestureSettings(), oneFingerTap: .appExplorer, twoFingerTap: .windowManager)])
        let nestedRoundtrip = try AppConfiguration.parse(nested.yaml())
        precondition(tryEqual(nested, nestedRoundtrip), "All profiles and device overrides must survive YAML roundtrip")
        var invalidProfile = nested
        invalidProfile.profiles![1].settings.devices!.appleLayerGestures![999] = invalidProfile.profiles![1].settings.devices!.appleLayerGestures![1]
        do { try invalidProfile.validate(); fatalError("Accepted Apple override for a missing layer") } catch {}
        invalidProfile = nested
        invalidProfile.activeConfigurationID = "missing"
        do { try invalidProfile.validate(); fatalError("Accepted missing active profile") } catch {}
        print("Multi-profile YAML passed: inactive settings, Explorer/shortcuts, device overrides and invalid-reference rejection.")
        let exported = try factory.yaml()
        let roundtrip = try AppConfiguration.parse(exported)
        precondition(tryEqual(factory, roundtrip))
        precondition(factory.settings.defaultProfileID == 2)
        precondition(factory.shortcuts.normal.keyCode == 106)
        precondition(factory.shortcuts.normal.enabled)
        precondition(!factory.shortcuts.precision.enabled)
        precondition(factory.settings.precision.cursorResponse != nil)
        var withSingleSwipe = factory
        withSingleSwipe.settings.appExplorer = AppExplorerSettings(defaultMode: .favorites,
            favorites: [AppExplorerFavorite(direction: .topLeft, bundleID: "com.apple.Safari", name: "Safari")],
            holdShortcut: RecordedShortcut(keyCode: 64, modifiers: 1 << 19, keyLabel: "F17"))
        withSingleSwipe.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .right, name: "Project docs", url: "https://example.com/docs?q=hello%20world#intro", iconSymbol: "book.closed.fill",
            activationShortcut: RecordedShortcut(keyCode: 15, modifiers: 1 << 20, keyLabel: "R")), at: .right)
        withSingleSwipe.settings.precision.scrollResponse = ScrollResponse(slowMultiplier:0.25,fastMultiplier:2.5,transitionSpeed:1300)
        withSingleSwipe.settings.appOverrides = [.chrome]
        var gestures = withSingleSwipe.settings.gestures(for: 1)
        gestures.singleTapSwipe = .singleTapDefaults
        gestures.singleTapSwipe!.enabled = true
        gestures.singleTapSwipe!.fastSwipeDuration = 0.125
        gestures.singleTapSwipe!.topRight = RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17")
        gestures.singleTapSwipe!.setAction(.appExplorer, for: .down)
        gestures.twoFingerSingleTapSwipe = gestures.singleTapSwipe
        gestures.twoFingerDoubleTapSwipe = DoubleTapSwipeSettings(enabled: true)
        gestures.twoFingerDoubleTapSwipe!.bottomLeft = RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17")
        gestures.oneFingerDoubleTap = .appExplorer
        gestures.oneFingerTripleTap = .windowManager
        gestures.twoFingerTripleTap = .windowManager
        gestures.gestures.tripleTapFirstInterval = 0.14
        gestures.gestures.tripleTapSecondInterval = 0.24
        withSingleSwipe.settings.profileGestures?[1] = gestures
        let singleSwipeYAML = try withSingleSwipe.yaml()
        let singleSwipeRoundtrip = try AppConfiguration.parse(singleSwipeYAML)
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).oneFingerTripleTap == .windowManager)
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).twoFingerTripleTap == .windowManager)
        var inheritedWindowManager = singleSwipeRoundtrip.settings
        inheritedWindowManager.defaultProfileID = 1
        inheritedWindowManager.customTapProfiles = []
        precondition(inheritedWindowManager.effectiveGestures(for: 2).oneFingerTripleTap == .windowManager)
        var grouped = withSingleSwipe
        grouped.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .left, name: "Work", children: [
            AppExplorerFavorite(direction: .up, name: "Research", children: [
                AppExplorerFavorite(direction: .right, name: "Docs", url: "https://example.com/docs"),
                AppExplorerFavorite(direction: .left, bundleID: "com.apple.Safari", name: "Safari")
            ])
        ]), at: .left)
        let groupRoundtrip = try AppConfiguration.parse(grouped.yaml())
        precondition(groupRoundtrip.settings.appExplorer == grouped.settings.appExplorer)
        var tiling = grouped
        tiling.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .down, name: "Window Manager", action: .windowManager), at: .down, in: [.left, .up])
        let tilingYAML = try tiling.yaml()
        let tilingRoundtrip = try AppConfiguration.parse(tilingYAML)
        precondition(tilingRoundtrip.settings.appExplorer == tiling.settings.appExplorer)
        rejected(tilingYAML.replacingOccurrences(of: "windowManager", with: "untrustedAction"), "unknown explorer action")
        var invalidTiling = tiling
        invalidTiling.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .down, name: "Mixed", url: "https://example.com", action: .windowManager), at: .down)
        rejected(try ConfigurationYAML.encode(invalidTiling), "mixed window manager destination")
        print("Window Manager YAML roundtrip and action validation passed.")
        var keyExplorer = grouped
        let explorerChord = RecordedShortcut(keyCode: 64, modifiers: (1 << 19) | (1 << 20), keyLabel: "F17")
        keyExplorer.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .down, name: "Voice input", shortcut: explorerChord), at: .down, in: [.left, .up])
        let keyYAML = try keyExplorer.yaml()
        let keyRestored = try AppConfiguration.parse(keyYAML)
        precondition(keyRestored.settings.appExplorer == keyExplorer.settings.appExplorer)
        var badKeyExplorer = keyExplorer
        badKeyExplorer.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .up, name: "Invalid", shortcut: RecordedShortcut(keyCode: 128, modifiers: 0, keyLabel: "Bad")), at: .up)
        rejected(try ConfigurationYAML.encode(badKeyExplorer), "invalid Explorer shortcut")
        badKeyExplorer = keyExplorer
        badKeyExplorer.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .up, name: "Mixed", url: "https://example.com", shortcut: explorerChord), at: .up)
        rejected(try ConfigurationYAML.encode(badKeyExplorer), "mixed Explorer URL/shortcut")
        print("Explorer shortcut YAML roundtrip and validation passed.")
        var layeredExplorer = grouped
        layeredExplorer.settings.appExplorer!.holdLayers = [ExplorerHoldLayer(name: "Thirds", holdShortcut: RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y"),
            favorites: [AppExplorerFavorite(direction: .up, name: "Media Controls", action: .mediaControls)], windowLayout: .thirds)]
        let layerYAML = try layeredExplorer.yaml()
        let layerRestored = try AppConfiguration.parse(layerYAML)
        precondition(layerRestored.settings.appExplorer == layeredExplorer.settings.appExplorer)
        rejected(layerYAML.replacingOccurrences(of: "windowLayout: thirds", with: "windowLayout: invalid"), "unknown window layout")
        print("Explorer hold layers and media controls YAML roundtrip passed.")
        var tileLayerConfig = layeredExplorer
        let localY = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y")
        tileLayerConfig.settings.appExplorer!.favorites = [
            AppExplorerFavorite(direction: .left, name: "Local manager", action: .windowManager,
                holdLayers: [ExplorerHoldLayer(name: "Local thirds", holdShortcut: localY, windowLayout: .thirds)]),
            AppExplorerFavorite(direction: .right, name: "Local apps", children: [],
                holdLayers: [ExplorerHoldLayer(name: "Alternate apps", holdShortcut: localY,
                    favorites: [AppExplorerFavorite(direction: .up, bundleID: "com.apple.finder", name: "Finder")])])
        ]
        let tileLayerYAML = try tileLayerConfig.yaml()
        let tileLayerRoundtrip = try AppConfiguration.parse(tileLayerYAML)
        precondition(tileLayerRoundtrip.settings.appExplorer == tileLayerConfig.settings.appExplorer)
        print("Tile-owned Explorer layers YAML roundtrip passed with reused keys in independent scopes.")
        var capacityConfig = factory
        capacityConfig.settings.appExplorer = AppExplorerSettings(favorites: ExplorerSlot.slots(16).enumerated().map {
            AppExplorerFavorite(direction: $0.element, name: "Command \($0.offset)", action: $0.offset == 0 ? .missionControl : .appWindows)
        }, slotCount: 16, windowManager: ExplorerWindowSettings(layout: .fourths,
            layers: [ExplorerHoldLayer(name: "Halves", holdShortcut: localY, activation: .toggle)],
            shortcuts: [ExplorerWindowShortcut(command: .maximize, shortcut: RecordedShortcut(keyCode: 46, modifiers: 0, keyLabel: "M"))]))
        let capacityYAML = try capacityConfig.yaml()
        let capacityRestored = try AppConfiguration.parse(capacityYAML)
        precondition(capacityRestored.settings.appExplorer == capacityConfig.settings.appExplorer)
        precondition(capacityRestored.settings.appExplorer?.favorites.first?.action == .missionControl)
        rejected(capacityYAML.replacingOccurrences(of: "slotCount: 16", with: "slotCount: 7"), "unsupported Explorer capacity")
        print("Explorer capacities, toggle layers and Window Manager commands YAML roundtrip passed.")
        precondition(AppExplorerSettings().resolvedTheme == .starburstAir)
        precondition(AppExplorerSettings().resolvedAnimationsEnabled)
        precondition(!AppExplorerSettings().resolvedCenterCursorOnAppSwitch)
        var centeredExplorer = layeredExplorer
        centeredExplorer.settings.appExplorer!.centerCursorOnAppSwitch = true
        let centeredYAML = try centeredExplorer.yaml()
        let centeredRoundtrip = try AppConfiguration.parse(centeredYAML)
        precondition(centeredRoundtrip.settings.appExplorer == centeredExplorer.settings.appExplorer)
        precondition(centeredRoundtrip.settings.appExplorer!.projected(layerID:
            centeredRoundtrip.settings.appExplorer!.holdLayers!.first!.id).resolvedCenterCursorOnAppSwitch)
        rejected(centeredYAML.replacingOccurrences(of: "centerCursorOnAppSwitch: true",
            with: "centerCursorOnAppSwitch: notABoolean"), "invalid cursor-centering flag")
        for theme in ExplorerTheme.allCases {
            var themed = layeredExplorer
            themed.settings.appExplorer!.theme = theme
            themed.settings.appExplorer!.animationsEnabled = false
            let themeYAML = try themed.yaml()
            let restored = try AppConfiguration.parse(themeYAML)
            precondition(restored.settings.appExplorer == themed.settings.appExplorer)
            if theme == .starburstAir {
                for legacy in ["vector", "ember"] {
                    let imported = try AppConfiguration.parse(themeYAML.replacingOccurrences(of: "theme: starburstAir", with: "theme: \(legacy)"))
                    precondition(imported.settings.appExplorer == themed.settings.appExplorer, "Retired themes migrate without changing layouts or other preferences")
                }
            }
            let projection = themed.settings.appExplorer!.projected(layerID: themed.settings.appExplorer!.holdLayers!.first!.id)
            precondition(projection.resolvedTheme == theme && !projection.resolvedAnimationsEnabled)
            rejected(themeYAML.replacingOccurrences(of: "theme: \(theme.rawValue)", with: "theme: unknownTheme"), "unknown Explorer theme")
            rejected(themeYAML.replacingOccurrences(of: "animationsEnabled: false", with: "animationsEnabled: notABoolean"), "invalid animation setting")
        }
        print("Explorer themes passed: legacy fallback, all-theme YAML roundtrip, animation preference, layer inheritance, and invalid input rejection.")
        var invalidGroup = grouped
        invalidGroup.settings.appExplorer!.favorites.append(AppExplorerFavorite(direction: .down,
            bundleID: "com.example.invalid", name: "Mixed", url: "https://example.com", children: []))
        rejected(try ConfigurationYAML.encode(invalidGroup), "group with multiple destination types")
        invalidGroup = grouped
        invalidGroup.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .down, name: "Unsafe nested URL", url: "file:///tmp/test"), at: .down, in: [.left, .up])
        rejected(try ConfigurationYAML.encode(invalidGroup), "unsafe URL inside nested group")
        invalidGroup = grouped
        invalidGroup.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .down, name: "Duplicate", children: [
            AppExplorerFavorite(direction: .up, name: "First", children: []),
            AppExplorerFavorite(direction: .up, name: "Second", children: [])
        ]), at: .down)
        rejected(try ConfigurationYAML.encode(invalidGroup), "duplicate nested group directions")
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).twoFingerSingleTapSwipe == gestures.twoFingerSingleTapSwipe)
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).twoFingerDoubleTapSwipe == gestures.twoFingerDoubleTapSwipe)
        var invalidPair = withSingleSwipe
        invalidPair.settings.profileGestures?[1]?.twoFingerDoubleTapSwipe?.swipeDistance = 999
        rejected(try ConfigurationYAML.encode(invalidPair), "out-of-range two-finger swipe distance")
        precondition(singleSwipeRoundtrip.settings.appExplorer == withSingleSwipe.settings.appExplorer)
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).gestures.tripleTapSecondInterval == 0.24)
        precondition(singleSwipeRoundtrip.settings.effectiveGestures(for: 2).gestures.tripleTapSecondInterval == withSingleSwipe.settings.effectiveGestures(for: 2).gestures.tripleTapSecondInterval)
        var invalidExplorer = withSingleSwipe
        var recentExplorer = withSingleSwipe
        recentExplorer.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .left, name: "Recent apps", children: [], groupMode: .recent), at: .left)
        let recentExport = try recentExplorer.yaml()
        let recentImport = try AppConfiguration.parse(recentExport)
        precondition(tryEqual(recentExplorer, recentImport))
        precondition(recentImport.settings.appExplorer!.favorite(at: [.left])!.isRecentGroup)
        rejected(recentExport.replacingOccurrences(of: "groupMode: recent", with: "groupMode: unknown"), "unknown recent group mode")
        var invalidRecent = recentExplorer
        invalidRecent.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .left, bundleID: "com.apple.Safari", name: "Invalid", groupMode: .recent), at: .left)
        rejected(try ConfigurationYAML.encode(invalidRecent), "recent mode on an app instead of a group")
        print("Recent-group YAML roundtrip and destination validation passed.")
        invalidExplorer.settings.appExplorer!.favorites.append(invalidExplorer.settings.appExplorer!.favorites[0])
        rejected(try ConfigurationYAML.encode(invalidExplorer), "duplicate explorer slot")
        for destination in ["file:///tmp/unsafe", "javascript:alert(1)", "https://user:password@example.com", "https://"] {
            var invalid = withSingleSwipe
            invalid.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .right, name: "Invalid", url: destination), at: .right)
            rejected(try ConfigurationYAML.encode(invalid), "unsafe or invalid favorite URL")
        }
        var ambiguousFavorite = withSingleSwipe
        ambiguousFavorite.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .right, bundleID: "com.apple.Safari", name: "Ambiguous", url: "https://example.com"), at: .right)
        rejected(try ConfigurationYAML.encode(ambiguousFavorite), "favorite with both app and URL")
        var longLink = withSingleSwipe
        longLink.settings.appExplorer!.setFavorite(AppExplorerFavorite(direction: .right, name: "Long link", url: "https://example.com/?q=" + String(repeating: "a", count: 600)), at: .right)
        let longRestored = try AppConfiguration.parse(longLink.yaml())
        precondition(longRestored.settings.appExplorer == longLink.settings.appExplorer)
        var invalidTriple = withSingleSwipe
        invalidTriple.settings.profileGestures?[1]?.gestures.tripleTapSecondInterval = 0.9
        rejected(try ConfigurationYAML.encode(invalidTriple), "triple-tap timing outside bounds")
        precondition(singleSwipeRoundtrip.settings.precision.scrollResponse == withSingleSwipe.settings.precision.scrollResponse)
        var invalidScroll = withSingleSwipe
        invalidScroll.settings.precision.scrollResponse = ScrollResponse(slowMultiplier:3,fastMultiplier:1)
        rejected(try ConfigurationYAML.encode(invalidScroll), "scroll slow speed above fast speed")
        invalidScroll.settings.precision.scrollResponse = ScrollResponse(slowMultiplier:0,fastMultiplier:7)
        rejected(try ConfigurationYAML.encode(invalidScroll), "scroll curve exceeds maximum")
        invalidScroll.settings.precision.scrollResponse = ScrollResponse(slowMultiplier:0,fastMultiplier:1,transitionSpeed:0)
        rejected(try ConfigurationYAML.encode(invalidScroll), "invalid scroll transition")
        precondition(singleSwipeRoundtrip.settings.appOverrides == [.chrome])
        var invalidApp = withSingleSwipe
        invalidApp.settings.appOverrides = [.chrome, .chrome]
        rejected(try ConfigurationYAML.encode(invalidApp), "duplicate app overrides")
        invalidApp.settings.appOverrides = [AppGestureOverride(bundleID:"test.app",name:"Test",bindings:[AppGestureBinding(trigger:.oneFingerTap,action:.shortcut)])]
        rejected(try ConfigurationYAML.encode(invalidApp), "app keyboard override missing shortcut")
        precondition(singleSwipeRoundtrip.settings.gestures(for: 1).singleTapSwipe == gestures.singleTapSwipe)
        rejected(singleSwipeYAML.replacingOccurrences(of: "fastSwipeDuration: 0.125", with: "fastSwipeDuration: 0.5"), "slow single-swipe duration")
        print("Passed full YAML roundtrip: profiles, recorded taps, activation/click/drag shortcuts, calibration, and general settings.")

        rejected("", "empty input")
        rejected("bad: [", "malformed YAML")
        rejected("formatVersion: 1", "missing fields")
        rejected(exported.replacingOccurrences(of: "formatVersion: 1", with: "formatVersion: 900"), "unsupported version")
        rejected(exported + "\nformatVersion: 1\n", "duplicate keys")
        rejected(exported + "\n---\nhello: world\n", "multiple documents")
        rejected("formatVersion: &version 1\nsettings: *version", "aliases")
        rejected(String(repeating: "x", count: 1_048_577), "oversized input")
        let nonfinite = exported.replacingOccurrences(of: "smoothing: [^\\n]+", with: "smoothing: .nan", options: .regularExpression)
        precondition(nonfinite != exported)
        rejected(nonfinite, "non-finite smoothing")
        rejected(exported.replacingOccurrences(of: "smoothing:", with: "smothing:"), "unknown setting")
        rejected("a: " + String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000), "excessive nesting")
        var bad = factory
        bad.settings.defaultProfileID = 999
        rejected(try ConfigurationYAML.encode(bad), "missing default profile")
        bad = factory
        bad.settings.normal.scrollMultiplier = -1
        rejected(try ConfigurationYAML.encode(bad), "negative scroll speed")
        bad = factory
        bad.settings.precision.cursorResponse!.transitionCenter = 9_000
        // CursorResponse.encode sanitizes; corrupt the raw text to test preflight.
        let invalidCenter = exported.replacingOccurrences(of: "transitionCenter: [^\\n]+",
                                                          with: "transitionCenter: 9000", options: .regularExpression)
        precondition(invalidCenter != exported)
        rejected(invalidCenter, "out-of-range center before model sanitization")
        bad = factory
        bad.shortcuts.actions.removeLast()
        rejected(try ConfigurationYAML.encode(bad), "incomplete action shortcuts")
        bad = factory
        bad.settings.additionalProfiles = [.init(id: 1, name: "Duplicate", motion: .normal)]
        rejected(try ConfigurationYAML.encode(bad), "duplicate profile IDs")
        var removedLayer = factory
        let removedID: UInt32 = removedLayer.settings.resolvedDefaultProfileID == 1 ? 2 : 1
        removedLayer.settings.removedLayerIDs = [removedID]
        removedLayer.settings.profileNames?.removeValue(forKey: removedID)
        removedLayer.settings.profileGestures?.removeValue(forKey: removedID)
        removedLayer.settings.customTapProfiles?.remove(removedID)
        removedLayer.settings.sliderBaselines?.removeValue(forKey: removedID)
        removedLayer.settings.devices?.appleLayerGestures?.removeValue(forKey: removedID)
        removedLayer.shortcuts.profileActions.removeValue(forKey: removedID)
        if removedID == 1 { removedLayer.shortcuts.normal.enabled = false }
        else { removedLayer.shortcuts.precision.enabled = false }
        let removedRoundtrip = try AppConfiguration.parse(removedLayer.yaml())
        precondition(tryEqual(removedLayer, removedRoundtrip) && !removedRoundtrip.settings.availableLayerIDs.contains(removedID))
        var noLayers = factory
        noLayers.settings.removedLayerIDs = [1, 2]
        rejected(try ConfigurationYAML.encode(noLayers), "removing every layer")

        let suite = "Rotagivan.ConfigurationTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        // Use an isolated suite; don't consult any real legacy-app domain.
        try factory.seedIfNeeded(preferences, considerLegacySettings: false)
        let store = SettingsStore(defaults: preferences, factorySettings: factory.settings)
        precondition(tryEqual(store.settings, factory.settings))
        precondition(store.activeProfileID == factory.settings.defaultProfileID)
        precondition(preferences.bool(forKey: "migration.rotagivan.cursorTransitionRange.v1"))
        let original = preferences.data(forKey: "settings.v1")
        rejected("not: valid", "invalid import leaves preferences unchanged")
        precondition(preferences.data(forKey: "settings.v1") == original)
        store.settings.normal.scrollMultiplier = 0.123
        try factory.seedIfNeeded(preferences, considerLegacySettings: false)
        let loaded = SettingsStore(defaults: preferences, factorySettings: factory.settings)
        precondition(loaded.settings.normal.scrollMultiplier == 0.123)
        loaded.reset()
        precondition(tryEqual(loaded.settings, factory.settings))
        print("Passed isolated first-launch defaults, no renormalization, existing-preference preservation, reset and invalid-import safety.")

        var multiple = factory
        multiple.settings.additionalProfiles = [.init(id: 100, name: "Quiet: #1 🧭", motion: .precision)]
        multiple.settings.profileNames?[100] = "Quiet: #1 🧭"
        multiple.shortcuts.additional[100] = ProfileShortcut(keyCode: 90, modifiers: 512, enabled: true)
        let extraRoundtrip = try AppConfiguration.parse(multiple.yaml())
        precondition(tryEqual(multiple, extraRoundtrip))
        print("Passed additional profile, Unicode name, comments, and full shortcut roundtrip.")
        for name in ["true", "null", "123", "2026-09-15", "a: b # c"] {
            multiple.settings.profileNames?[100] = name
            let decoded = try AppConfiguration.parse(multiple.yaml())
            precondition(decoded.settings.profileNames?[100] == name)
        }
        var precise = factory
        precise.settings.precision.cursorResponse!.fineGain = 0.32493574766355143
        let preciseRoundtrip = try AppConfiguration.parse(precise.yaml())
        precondition(preciseRoundtrip.settings.precision.cursorResponse!.fineGain == 0.32493574766355143)
        print("Passed ambiguous string names and exact floating-point preservation.")
        var swipes = factory
        var taps = swipes.settings.gestures(for: swipes.settings.resolvedDefaultProfileID)
        taps.doubleTapSwipe = DoubleTapSwipeSettings(enabled: true,
            left: RecordedShortcut(keyCode: 123, modifiers: 1048576, keyLabel: "Left arrow"),
            up: RecordedShortcut(keyCode: 126, modifiers: 0, keyLabel: "Up arrow"))
        let swipeProfileID = swipes.settings.resolvedDefaultProfileID
        swipes.settings.profileGestures?[swipeProfileID] = taps
        let swipeYAML = try swipes.yaml()
        let swipeRoundtrip = try AppConfiguration.parse(swipeYAML)
        precondition(tryEqual(swipes, swipeRoundtrip))
        rejected(swipeYAML.replacingOccurrences(of: "swipeWindow: [^\\n]+", with: "swipeWindow: 99", options: .regularExpression), "out-of-range swipe window")
        print("Passed double-tap swipe settings and shortcut YAML roundtrip.")
        // Old configurations still load without adding any diagonal bindings.
        let legacySwipe = swipeRoundtrip.settings.gestures(for: swipeProfileID).doubleTapSwipe!
        precondition(legacySwipe.topLeft == nil && legacySwipe.topRight == nil && legacySwipe.bottomLeft == nil && legacySwipe.bottomRight == nil)
        for (index, direction) in [SwipeDirection.topLeft, .topRight, .bottomLeft, .bottomRight].enumerated() {
            taps.doubleTapSwipe![direction] = RecordedShortcut(keyCode: UInt16(18 + index), modifiers: 1048576, keyLabel: direction.title)
        }
        taps.oneFingerTap = .doubleLeftClick
        taps.twoFingerDoubleTap = .doubleLeftClick
        swipes.settings.profileGestures?[swipeProfileID] = taps
        let expandedYAML = try swipes.yaml()
        let expandedRoundtrip = try AppConfiguration.parse(expandedYAML)
        precondition(tryEqual(swipes, expandedRoundtrip))
        precondition(expandedRoundtrip.settings.gestures(for: swipeProfileID).oneFingerTap == .doubleLeftClick)
        var invalidDiagonal = swipes
        invalidDiagonal.settings.profileGestures?[swipeProfileID]?.doubleTapSwipe?.topLeft?.keyCode = 999
        rejected(try ConfigurationYAML.encode(invalidDiagonal), "invalid diagonal shortcut key code")
        print("Passed four diagonal bindings, double-left-click actions, legacy defaults, and YAML roundtrip.")
        precondition(swipeRoundtrip.settings.gestures(for: swipeProfileID).gestures.resolvedKeepCursorStillForTaps)
        for enabled in [false, true] {
            swipes.settings.profileGestures?[swipeProfileID]?.gestures.keepCursorStillForTaps = enabled
            let stationaryRoundtrip = try AppConfiguration.parse(swipes.yaml())
            precondition(tryEqual(swipes, stationaryRoundtrip))
            precondition(stationaryRoundtrip.settings.gestures(for: swipeProfileID).gestures.resolvedKeepCursorStillForTaps == enabled)
        }
        print("Passed stationary-tap YAML opt-in, opt-out, and legacy default.")
        precondition(swipeRoundtrip.settings.gestures(for: swipeProfileID).oneFingerTripleTap == nil)
        swipes.settings.profileGestures?[swipeProfileID]?.oneFingerTripleTap = .tripleLeftClick
        swipes.settings.profileGestures?[swipeProfileID]?.twoFingerTripleTap = .shortcut
        swipes.settings.profileGestures?[swipeProfileID]?.twoFingerTripleShortcut = RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return")
        let tripleRoundtrip = try AppConfiguration.parse(swipes.yaml())
        precondition(tryEqual(swipes, tripleRoundtrip))
        swipes.settings.profileGestures?[swipeProfileID]?.twoFingerTripleShortcut = nil
        rejected(try ConfigurationYAML.encode(swipes), "triple tap shortcut missing its key binding")
        print("Triple-tap actions, shortcut YAML roundtrip, legacy defaults and validation passed.")
    }

    static func tryEqual<T: Encodable>(_ a: T, _ b: T) -> Bool { try! equal(a, b) }
}
