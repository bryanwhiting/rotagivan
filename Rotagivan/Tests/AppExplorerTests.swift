import Foundation

@main struct AppExplorerTests {
    static func report(_ x: Double? = nil, _ y: Double = 500, id: UInt8 = 0, confident: Bool = true, button: Bool = false) -> TrackpadReport {
        TrackpadReport(contacts: x.map { [FingerContact(id: id, x: $0, y: y, touching: true, confident: confident)] } ?? [], buttonDown: button, scanTime: 0)
    }
    static func main() throws {
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
        print("App Explorer passed: eight directions, trigger drain, one selection on lift, center cancellation, invalid input, bounded MRU, and binding persistence.")
    }
}
