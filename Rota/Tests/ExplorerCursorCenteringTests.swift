import AppKit

@MainActor private final class CenteringFixture {
    let centering = ExplorerCursorCentering(interval: 5_000_000, attempts: 12)
    var frontmost: pid_t? = 10
    var point = CGPoint(x: -200, y: 150)
    var frame: CGRect? = CGRect(x: -1000, y: 100, width: 800, height: 600)
    var valid = true
    var moves: [CGPoint] = []
    init() {
        centering.frontmostPID = { [unowned self] in frontmost }
        centering.position = { [unowned self] in point }
        centering.windowFrame = { [unowned self] pid in precondition(pid == 20); return frame }
        centering.displays = { [CGRect(x: -1440, y: 0, width: 1440, height: 900)] }
        centering.move = { [unowned self] in moves.append($0) }
    }
    func start() { centering.start(pid: 20, origin: point, isValid: { [weak self] in self?.valid == true }) }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
}

@main struct ExplorerCursorCenteringTests {
    @MainActor static func main() {
        let screen = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        precondition(ExplorerCursorCentering.target(window: CGRect(x: -1200, y: -800, width: 600, height: 400), displays: [screen]) == CGPoint(x: -900, y: -600))
        precondition(ExplorerCursorCentering.target(window: CGRect(x: -1600, y: -800, width: 300, height: 200), displays: [screen]) == CGPoint(x: -1370, y: -700))
        precondition(ExplorerCursorCentering.target(window: CGRect(x: 50, y: 50, width: 300, height: 200), displays: [screen]) == nil)
        precondition(ExplorerCursorCentering.target(window: .zero, displays: [screen]) == nil)
        precondition(ExplorerCursorCentering.target(window: screen, displays: []) == nil)

        let normal = CenteringFixture()
        normal.start(); normal.frontmost = 20; normal.settle()
        precondition(normal.moves == [CGPoint(x: -600, y: 400)])
        let delayedWindow = CenteringFixture()
        delayedWindow.frame = nil
        delayedWindow.start(); delayedWindow.frontmost = 20
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        delayedWindow.frame = CGRect(x: -800, y: 0, width: 800, height: 600)
        delayedWindow.settle()
        precondition(delayedWindow.moves == [CGPoint(x: -400, y: 300)])
        for scenario in 0..<6 {
            let f = CenteringFixture()
            f.start()
            switch scenario {
            case 0: f.valid = false; f.frontmost = 20
            case 1: f.point.x += 20; f.frontmost = 20
            case 2: f.frontmost = 30
            case 3: f.centering.cancel(); f.frontmost = 20
            case 4: f.frame = nil; f.frontmost = 20
            default: break // Target never activates.
            }
            f.settle()
            precondition(f.moves.isEmpty, "No late cursor jump on cancelled/failed/stale activation or user movement (\(scenario))")
        }
        print("Explorer centering passed: stable focused window, delayed window, multiple displays, clipped window, failed activation, no window, changed focus/settings, cancellation, manual movement. No real cursor moves.")
    }
}
