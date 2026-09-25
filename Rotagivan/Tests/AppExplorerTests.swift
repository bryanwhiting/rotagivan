import Foundation

@main struct AppExplorerTests {
    static func testSlotSwaps() throws {
        let app = AppExplorerFavorite(direction: .left, bundleID: "com.apple.finder", name: "Finder")
        let web = AppExplorerFavorite(direction: .right, name: "Docs", url: "https://example.com")
        let group = AppExplorerFavorite(direction: .up, name: "Work", children: [app, web])
        let recent = AppExplorerFavorite(direction: .down, name: "Recent", children: [], groupMode: .recent)
        let original = AppExplorerSettings(favorites: [app, web, group, recent])
        var settings = original
        let drag = ExplorerSlotDrag(source: .left, path: [], settings: settings)!
        precondition(drag.apply(to: .right, in: [], settings: &settings))
        precondition(settings.favorite(at: [.right])?.bundleID == app.bundleID)
        precondition(settings.favorite(at: [.left])?.url == web.url)
        precondition(settings.favorites.count == 4)
        let swapped = settings
        precondition(!drag.apply(to: .right, in: [], settings: &settings), "One drag cannot commit twice")
        precondition(settings == swapped)
        precondition(settings.swapFavorites(from: .right, to: .bottomRight))
        precondition(settings.favorite(at: [.right]) == nil && settings.favorite(at: [.bottomRight])?.bundleID == app.bundleID)
        precondition(settings.swapFavorites(from: .up, to: .down))
        precondition(settings.favorite(at: [.down])?.children == group.children, "Whole group contents move together")
        precondition(settings.favorite(at: [.up])?.isRecentGroup == true)
        precondition(settings.swapFavorites(from: .left, to: .right, in: [.down]))
        precondition(settings.favorite(at: [.down, .right])?.bundleID == app.bundleID)
        precondition(settings.favorite(at: [.down, .left])?.url == web.url)
        let stable = settings
        for path: [ExplorerSlot] in [[.up], [.topLeft], [.down, .right]] {
            precondition(!settings.swapFavorites(from: .left, to: .right, in: path))
            precondition(ExplorerSlotDrag(source: .left, path: path, settings: settings) == nil)
        }
        precondition(!settings.swapFavorites(from: .left, to: .left))
        precondition(!settings.swapFavorites(from: .topLeft, to: .left))
        precondition(settings == stable, "Invalid, empty, recent, and self drops do not mutate settings")
        let nested = ExplorerSlotDrag(source: .left, path: [.down], settings: settings)!
        precondition(!nested.apply(to: .right, in: [], settings: &settings), "Cannot drop across a changed group")
        settings.favorites[0].name = "Changed by sync"
        let changed = settings
        precondition(!nested.apply(to: .right, in: [.down], settings: &settings))
        precondition(settings == changed, "Concurrent changes are never overwritten")
        let restored = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(settings))
        precondition(restored == settings)
        for source in ExplorerSlot.allCases {
            for destination in ExplorerSlot.allCases where source != destination {
                var full = AppExplorerSettings(favorites: ExplorerSlot.allCases.map {
                    AppExplorerFavorite(direction: $0, bundleID: "test.\($0.rawValue)", name: $0.title)
                })
                precondition(full.swapFavorites(from: source, to: destination))
                precondition(full.favorite(at: [destination])?.bundleID == "test.\(source.rawValue)")
                precondition(full.favorite(at: [source])?.bundleID == "test.\(destination.rawValue)")
                precondition(full.hasValidFavorites && full.favorites.count == 8)
            }
        }
        print("Slot swaps passed: all 56 pairs, empty moves, nested groups, recents read-only, persistence, and stale-drag cancellation.")
    }

    static func report(_ x: Double? = nil, _ y: Double = 500, id: UInt8 = 0, confident: Bool = true, button: Bool = false) -> TrackpadReport {
        TrackpadReport(contacts: x.map { [FingerContact(id: id, x: $0, y: y, touching: true, confident: confident)] } ?? [], buttonDown: button, scanTime: 0)
    }
    static func main() throws {
        let chord = RecordedShortcut(keyCode: 64, modifiers: (1 << 19) | (1 << 20), keyLabel: "F17")
        let keyFavorite = AppExplorerFavorite(direction: .up, name: "Voice input", shortcut: chord)
        precondition(keyFavorite.isValidDestination)
        var keySettings = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .left, name: "Tools", children: [keyFavorite])])
        precondition(keySettings.hasValidFavorites)
        precondition(keySettings.swapFavorites(from: .up, to: .right, in: [.left]))
        precondition(keySettings.favorite(at: [.left, .right])?.shortcut == chord)
        let keyRoundtrip = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(keySettings))
        precondition(keyRoundtrip == keySettings)
        for invalidChord in [RecordedShortcut(keyCode: 128, modifiers: 0, keyLabel: "Bad"),
                             RecordedShortcut(keyCode: 64, modifiers: 1 << 63, keyLabel: "F17"),
                             RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: ""),
                             RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17\n")] {
            precondition(!AppExplorerFavorite(direction: .up, name: "Invalid", shortcut: invalidChord).isValidDestination)
        }
        precondition(!AppExplorerFavorite(direction: .up, bundleID: "com.apple.Safari", name: "Mixed", shortcut: chord).isValidDestination)
        precondition(!AppExplorerFavorite(direction: .up, name: "Mixed", url: "https://example.com", shortcut: chord).isValidDestination)
        precondition(AppExplorerFavorite(direction: .up, name: "Deep shortcut", children: [], shortcut: chord).isValidDestination)
        precondition(!AppExplorerFavorite(direction: .up, name: "Mixed", action: .windowManager, shortcut: chord).isValidDestination)
        let actionKey = RecordedShortcut(keyCode: 15, modifiers: 1 << 20, keyLabel: "R")
        let keyedAction = AppExplorerFavorite(direction: .right, name: "Docs", url: "https://example.com",
            activationShortcut: actionKey)
        precondition(keyedAction.isValidDestination)
        precondition(!AppExplorerFavorite(direction: .right, name: "Reserved", url: "https://example.com",
            activationShortcut: RecordedShortcut(keyCode: 14, modifiers: 0, keyLabel: "E")).isValidDestination)
        precondition(!AppExplorerSettings(favorites: [keyedAction,
            AppExplorerFavorite(direction: .left, name: "Duplicate", url: "https://example.com/other",
                activationShortcut: actionKey)]).hasValidFavorites)
        precondition(Set(AppExplorerAction.macOSCommands).count == AppExplorerAction.macOSCommands.count)
        for command in AppExplorerAction.allCases {
            precondition(!command.description.isEmpty)
            let action = BindingAction.command(command)
            precondition(action.isValid && !action.description.isEmpty)
            precondition(try! JSONDecoder().decode(BindingAction.self, from: JSONEncoder().encode(action)) == action)
        }
        for command in [AppExplorerAction.toggleDock, .previousApp, .nextAppWindow, .previousAppWindow, .hideApp, .hideOtherApps, .appExpose] {
            precondition(command.resolvedMacOSShortcut(symbolicHotKeys: nil) != nil)
            precondition(AppExplorerAction.macOSCommands.contains(command))
        }
        precondition(AppExplorerAction.previousApp.macOSShortcut?.keyCode == 48)
        precondition(AppExplorerAction.nextAppWindow.macOSShortcut?.keyCode == 50)
        precondition(AppExplorerAction.moveWindowNextDesktop.macOSShortcut == nil)
        precondition(AppExplorerAction.moveWindowPreviousDesktop.macOSShortcut == nil)
        precondition(AppExplorerAction.missionControl.resolvedMacOSShortcut(symbolicHotKeys: nil) == RecordedShortcut(keyCode: 126,
            modifiers: UInt64(1 << 18), keyLabel: "Up Arrow"))
        let customized: [String: Any] = ["32": ["enabled": NSNumber(value: true), "value": ["parameters": [
            NSNumber(value: 105), NSNumber(value: 34), NSNumber(value: 917_504)
        ]]]]
        precondition(AppExplorerAction.missionControl.resolvedMacOSShortcut(symbolicHotKeys: customized) == RecordedShortcut(
            keyCode: 34, modifiers: 917_504, keyLabel: "Mission Control"))
        precondition(AppExplorerAction.showDesktop.resolvedMacOSShortcut(symbolicHotKeys: nil)?.keyCode == 103)
        precondition(AppExplorerAction.lockScreen.resolvedMacOSShortcut(symbolicHotKeys: nil) ==
            RecordedShortcut(keyCode: 12, modifiers: UInt64((1 << 18) | (1 << 20)), keyLabel: "Q"))
        precondition(BindingAction.command(.lockScreen).isValid)
        let lockTile = AppExplorerFavorite(direction: .up, name: "Lock Screen", action: .lockScreen)
        precondition(lockTile.isValidDestination)
        let restoredLock = try! JSONDecoder().decode(AppExplorerFavorite.self, from: JSONEncoder().encode(lockTile))
        precondition(restoredLock == lockTile)
        precondition(AppExplorerAction.appWindows.macOSShortcut == nil, "App windows uses Rotagivan's window picker")
        print("Explorer shortcut destinations passed: nested persistence, swaps, invalid keys/modifiers/labels and mixed-type rejection.")
        try testSlotSwaps()
        var settings = AppExplorerSettings()
        precondition(settings.mode(holdingShortcut: false) == .favorites)
        precondition(settings.mode(holdingShortcut: true) == .favorites)
        settings.defaultMode = .recent
        precondition(settings.mode(holdingShortcut: false) == .favorites, "Legacy Recent root mode is inert")
        precondition(settings.mode(holdingShortcut: true) == .favorites)
        settings.setFavorite(AppExplorerFavorite(direction: .up, bundleID: "com.apple.Safari", name: "Safari"), at: .right)
        settings.setFavorite(AppExplorerFavorite(direction: .up, bundleID: "com.apple.finder", name: "Finder"), at: .up)
        precondition(settings.favorites.first?.direction == .right, "Slots must not compact or reorder")
        settings.setFavorite(nil, at: .right)
        precondition(settings.favorites.count == 1 && settings.favorites[0].direction == .up)
        settings.holdShortcut = RecordedShortcut(keyCode: 64, modifiers: 1 << 19, keyLabel: "F17")
        let restored = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(settings))
        precondition(restored == settings)
        let legacy = try JSONDecoder().decode(AppExplorerFavorite.self, from: Data(#"{"direction":"up","bundleID":"com.apple.Safari","name":"Safari"}"#.utf8))
        precondition(legacy.url == nil && legacy.children == nil && legacy.bundleID == "com.apple.Safari" && legacy.isValidDestination)
        let web = AppExplorerFavorite(direction: .right, name: "Docs", url: "https://example.com/docs?q=one%20two#section",
            iconSymbol: "book.closed.fill")
        precondition(web.isValidDestination && web.bundleID == nil && WebsiteIconCatalog.symbols.contains(web.iconSymbol!))
        var invalidWebIcon = web; invalidWebIcon.iconSymbol = "not.a.real.rotagivan.icon"
        precondition(!invalidWebIcon.isValidDestination)
        var iconOnApp = legacy; iconOnApp.iconSymbol = "star.fill"
        precondition(!iconOnApp.isValidDestination, "Custom web icons must not attach to app tiles")
        settings.setFavorite(web, at: .up)
        precondition(settings.favorites[0].url == web.url && settings.favorites[0].bundleID == nil)
        let webRestored = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(settings))
        precondition(webRestored == settings)
        for valid in ["https://example.com", "http://localhost:8080/path", "https://example.com/path?q=hello#anchor"] {
            precondition(AppExplorerFavorite.webURL(valid) != nil)
        }
        for invalid in ["", "example.com", "https://", "https://exa mple.com", "https://example.com/\nsecret", "javascript:alert(1)", "file:///tmp/test", "data:text/html,hello", "mailto:test@example.com", "custom://open", "https://user:password@example.com", "https://user@example.com", "https://example.com:0", "https://example.com:65536", "https://example.com/" + String(repeating: "a", count: 4096)] {
            precondition(AppExplorerFavorite.webURL(invalid) == nil, "Reject invalid or non-web destinations")
        }
        var ambiguous = web; ambiguous.bundleID = "com.apple.Safari"
        precondition(!ambiguous.isValidDestination)
        precondition(!AppExplorerFavorite(direction: .up, name: "Missing destination").isValidDestination)
        settings.setFavorite(legacy, at: .up)
        precondition(settings.favorites[0].url == nil && settings.favorites[0].bundleID == "com.apple.Safari")
        var groups = AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .left, name: "Work", children: [])])
        precondition(groups.hasValidFavorites)
        precondition(groups.setFavorite(legacy, at: .up, in: [.left]))
        precondition(groups.setFavorite(AppExplorerFavorite(direction: .down, name: "Research", children: [web]), at: .down, in: [.left]))
        precondition(groups.favorites(at: [.left])?.count == 2)
        precondition(groups.favorite(at: [.left, .down, .right]) == web)
        var renamed = groups.favorite(at: [.left])!
        renamed.name = "Projects"
        groups.setFavorite(renamed, at: .left)
        precondition(groups.favorite(at: [.left, .down, .right]) == web, "Renaming preserves descendants")
        let groupRoundtrip = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(groups))
        precondition(groupRoundtrip == groups)
        let originalGroup = groups.favorite(at: [.left])!
        var recentGroup = originalGroup
        recentGroup.groupMode = .recent
        groups.setFavorite(recentGroup, at: .left)
        precondition(groups.hasValidFavorites && groups.favorite(at: [.left])!.isRecentGroup)
        precondition(groups.favorites(at: [.left]) == [])
        precondition(groups.favorites(at: [.left, .down]) == nil, "Do not navigate into hidden favorites")
        precondition(!groups.setFavorite(web, at: .up, in: [.left]), "Recent slots are automatic, not editable favorites")
        let recentRoundtrip = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(groups))
        precondition(recentRoundtrip == groups)
        precondition(groups.favorite(at: [.left])?.children == originalGroup.children)
        recentGroup.name = "Last used"
        recentGroup.groupMode = .favorites
        groups.setFavorite(recentGroup, at: .left)
        precondition(groups.favorite(at: [.left, .down, .right]) == web, "Switching back restores all assigned favorites")
        precondition(legacy.groupMode == nil && !legacy.isRecentGroup)
        var invalidMode = legacy; invalidMode.groupMode = .recent
        precondition(!invalidMode.isValidDestination, "Only groups have a contents mode")
        precondition(AppExplorerSettings.recentDirections == [.left, .topLeft, .up, .topRight, .right, .bottomRight, .down, .bottomLeft])
        let ranked = AppExplorerRecents(["one", "two", "three", "four", "five", "six", "seven", "eight"])
        let slots = Dictionary(uniqueKeysWithValues: zip(AppExplorerSettings.recentDirections,
            ranked.ordered(available: ranked.identifiers, excluding: [])))
        precondition(slots[.left] == "one" && slots[.topLeft] == "two" && slots[.up] == "three" && slots[.bottomLeft] == "eight")
        print("Recent groups passed: clockwise ranking, legacy decoding, persistence, read-only slots, and reversible contents switching.")
        let unchanged = groups
        precondition(!groups.setFavorite(legacy, at: .right, in: [.right, .up]))
        precondition(groups == unchanged, "A stale group path cannot overwrite root favorites")
        groups.setFavorite(nil, at: .down, in: [.left])
        precondition(groups.favorite(at: [.left, .up])?.bundleID == legacy.bundleID)
        precondition(groups.favorite(at: [.left, .down]) == nil)
        var deepURL = AppExplorerFavorite(direction: .left, name: "Deep URL", children: [])
        deepURL.url = "https://example.com"
        precondition(AppExplorerSettings(favorites: [deepURL]).hasValidFavorites)
        precondition(!AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .left, name: "Duplicate", children: [web, web])]).hasValidFavorites)
        var chain = legacy
        for i in 0..<AppExplorerSettings.maximumGroupDepth {
            chain = AppExplorerFavorite(direction: .left, name: "Level \(i)", children: [chain])
        }
        precondition(AppExplorerSettings(favorites: [chain]).hasValidFavorites)
        chain = AppExplorerFavorite(direction: .left, name: "Too deep", children: [chain])
        precondition(!AppExplorerSettings(favorites: [chain]).hasValidFavorites)
        let eight = ExplorerSlot.allCases.map { AppExplorerFavorite(direction: $0, bundleID: "com.apple.Safari", name: "Safari") }
        let sixtyFour = ExplorerSlot.allCases.map { AppExplorerFavorite(direction: $0, name: "Group", children: eight) }
        let excessive = ExplorerSlot.allCases.map { AppExplorerFavorite(direction: $0, name: "Group", children: sixtyFour) }
        precondition(!AppExplorerSettings(favorites: excessive).hasValidFavorites)
        let time = Date(timeIntervalSince1970: 1_000)
        var centerTap = AppExplorerSelection(waitingForLift: false)
        _ = centerTap.process(report(500), at: time)
        _ = centerTap.process(report(510), at: time.addingTimeInterval(0.02))
        precondition(centerTap.process(report(), at: time.addingTimeInterval(0.05)) == .back)
        precondition(centerTap.process(report(), at: time.addingTimeInterval(0.06)) == .waiting)
        var hold = AppExplorerSelection(waitingForLift: false)
        _ = hold.process(report(500), at: time)
        precondition(hold.process(report(), at: time.addingTimeInterval(0.6)) == .cancel, "A hold is not a back tap")
        let directions: [(ExplorerSlot, Double, Double)] = [(.up,500,400),(.topRight,600,400),(.right,600,500),(.bottomRight,600,600),(.down,500,600),(.bottomLeft,400,600),(.left,400,500),(.topLeft,400,400)]
        for (direction, x, y) in directions {
            var input = AppExplorerSelection(waitingForLift: true)
            precondition(input.process(report(500)) == .waiting)
            precondition(input.process(report(x,y)) == .waiting, "Trigger swipe must never select an app")
            precondition(input.process(report()) == .waiting)
            precondition(input.process(report(500)) == .waiting)
            precondition(input.process(report(x,y)) == .highlight(direction))
            precondition(input.process(report(x,y)) == .waiting, "Unchanged sector must not redraw")
            precondition(input.process(report()) == .select(direction))
            precondition(input.process(report()) == .waiting, "Select once")
        }
        var input = AppExplorerSelection(waitingForLift: false)
        _ = input.process(report(500)); _ = input.process(report(600))
        precondition(input.process(report(510)) == .highlight(nil))
        precondition(input.process(report()) == .cancel, "Return to center cancels")
        for invalid in 0..<5 {
            var input = AppExplorerSelection(waitingForLift: false)
            _ = input.process(report(500))
            let invalidReport: TrackpadReport
            switch invalid {
            case 0: invalidReport = report(1000)
            case 1: invalidReport = report(600, id: 1)
            case 2: invalidReport = report(600, confident: false)
            case 3: invalidReport = report(600, button: true)
            default:
                invalidReport = TrackpadReport(contacts: report(500).contacts + report(600,id:1).contacts, buttonDown: false, scanTime: 0)
            }
            precondition(input.process(invalidReport) == .cancel)
            precondition(input.process(report()) == .waiting)
        }
        let activeRecents = AppExplorerRecents(["recent", "active", "older", "closed"])
        precondition(activeRecents.activeFirst(available: ["active", "recent", "older"], active: "active") == ["active", "recent", "older"])
        precondition(activeRecents.activeFirst(available: ["recent", "older"], active: "closed") == ["recent", "older"])
        precondition(activeRecents.activeFirst(available: ["active", "recent"], active: "active", limit: 1) == ["active"])
        precondition(activeRecents.activeFirst(available: ["active"], active: "active", limit: 0).isEmpty)
        let clockwise = ExplorerSlot.slots(8).sorted {
            ($0.angle + 180).truncatingRemainder(dividingBy: 360) < ($1.angle + 180).truncatingRemainder(dividingBy: 360)
        }
        precondition(clockwise == [.left, .topLeft, .up, .topRight, .right, .bottomRight, .down, .bottomLeft])
        var recents = AppExplorerRecents(["b","a","b",""])
        recents.record("c"); recents.record("a")
        precondition(recents.identifiers == ["a","c","b"])
        precondition(recents.ordered(available: ["a","b","d"], excluding:["a"]) == ["b","d"])
        for i in 0..<80 { recents.record("app\(i)") }
        precondition(recents.identifiers.count == 64)
        precondition(recents.ordered(available:recents.identifiers, excluding:[]).count == 8)
        var swipe = DoubleTapSwipeSettings(enabled: true)
        swipe.setAction(.appExplorer, for: .down)
        precondition(swipe.isConfigured && swipe.action(for:.down) == .appExplorer && swipe.down == nil)
        let decoded = try JSONDecoder().decode(DoubleTapSwipeSettings.self, from: JSONEncoder().encode(swipe))
        precondition(decoded == swipe)
        swipe.down = RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17")
        swipe.setAction(.shortcut, for:.down)
        precondition(swipe.action(for:.down) == .shortcut && swipe.down != nil)
        swipe.setAction(.none, for:.down)
        precondition(!swipe.isConfigured && swipe.down == nil)
        print("App Explorer passed: eight directions, center back tap, cancellation, group edits/rename, nested persistence, invalid/stale paths, depth/size limits, trigger drain and bounded MRU.")
    }
}
