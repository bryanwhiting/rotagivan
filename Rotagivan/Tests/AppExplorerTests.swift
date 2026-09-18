import Foundation

@main struct AppExplorerTests {
    static func report(_ x: Double? = nil, _ y: Double = 500, id: UInt8 = 0, confident: Bool = true, button: Bool = false) -> TrackpadReport {
        TrackpadReport(contacts: x.map { [FingerContact(id: id, x: $0, y: y, touching: true, confident: confident)] } ?? [], buttonDown: button, scanTime: 0)
    }
    static func main() throws {
        var settings = AppExplorerSettings()
        precondition(settings.mode(holdingShortcut: false) == .favorites)
        precondition(settings.mode(holdingShortcut: true) == .recent)
        settings.defaultMode = .recent
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
        let web = AppExplorerFavorite(direction: .right, name: "Docs", url: "https://example.com/docs?q=one%20two#section")
        precondition(web.isValidDestination && web.bundleID == nil)
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
        let unchanged = groups
        precondition(!groups.setFavorite(legacy, at: .right, in: [.right, .up]))
        precondition(groups == unchanged, "A stale group path cannot overwrite root favorites")
        groups.setFavorite(nil, at: .down, in: [.left])
        precondition(groups.favorite(at: [.left, .up])?.bundleID == legacy.bundleID)
        precondition(groups.favorite(at: [.left, .down]) == nil)
        var invalidGroup = AppExplorerFavorite(direction: .left, name: "Mixed", children: [])
        invalidGroup.url = "https://example.com"
        precondition(!AppExplorerSettings(favorites: [invalidGroup]).hasValidFavorites)
        precondition(!AppExplorerSettings(favorites: [AppExplorerFavorite(direction: .left, name: "Duplicate", children: [web, web])]).hasValidFavorites)
        var chain = legacy
        for i in 0..<AppExplorerSettings.maximumGroupDepth {
            chain = AppExplorerFavorite(direction: .left, name: "Level \(i)", children: [chain])
        }
        precondition(AppExplorerSettings(favorites: [chain]).hasValidFavorites)
        chain = AppExplorerFavorite(direction: .left, name: "Too deep", children: [chain])
        precondition(!AppExplorerSettings(favorites: [chain]).hasValidFavorites)
        let eight = SwipeDirection.allCases.map { AppExplorerFavorite(direction: $0, bundleID: "com.apple.Safari", name: "Safari") }
        let sixtyFour = SwipeDirection.allCases.map { AppExplorerFavorite(direction: $0, name: "Group", children: eight) }
        let excessive = SwipeDirection.allCases.map { AppExplorerFavorite(direction: $0, name: "Group", children: sixtyFour) }
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
        let directions: [(SwipeDirection, Double, Double)] = [(.up,500,400),(.topRight,600,400),(.right,600,500),(.bottomRight,600,600),(.down,500,600),(.bottomLeft,400,600),(.left,400,500),(.topLeft,400,400)]
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
