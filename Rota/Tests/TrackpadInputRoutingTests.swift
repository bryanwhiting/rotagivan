import Foundation

@main struct TrackpadInputRoutingTests {
    static func main() {
        var gate = TrackpadInputRouting()
        let apple = TrackpadInputSource.apple(7)
        let otherApple = TrackpadInputSource.apple(8)
        precondition(!gate.accept(.navigator, touching: false), "Idle frames cannot claim a session")
        precondition(gate.accept(apple, touching: true))
        precondition(gate.accept(.navigator, touching: true), "Navigator preempts a resting Apple contact outside a HUD")
        precondition(!gate.accept(apple, touching: true), "Preempted Apple contact drains until lift")
        precondition(gate.accept(.navigator, touching: false))
        precondition(!gate.accept(apple, touching: true))
        precondition(!gate.accept(apple, touching: false))
        precondition(gate.accept(.navigator, touching: true))
        precondition(gate.source == .navigator)
        precondition(gate.accept(.navigator, touching: false))
        precondition(!gate.accept(apple, touching: true, lockedTo: .navigator), "HUD/calibration remains source-bound between touches")
        precondition(!gate.accept(apple, touching: false, lockedTo: .navigator))
        precondition(gate.accept(apple, touching: true))
        precondition(!gate.accept(otherApple, touching: true), "Two Apple trackpads are distinct")
        precondition(gate.accept(apple, touching: false))
        gate.reset()
        precondition(gate.source == nil && !gate.contactsDown)
        precondition(gate.accept(otherApple, touching: true))
        gate.reset(draining: otherApple)
        precondition(!gate.accept(otherApple, touching: true), "Restart drains a contact inherited from the old stream")
        precondition(!gate.accept(otherApple, touching: false))
        precondition(gate.accept(otherApple, touching: true), "Fresh contact works after restart lift")
        precondition(!gate.accept(.navigator, touching: true, lockedTo: otherApple), "Navigator cannot preempt a source-locked HUD/calibration")
        print("Trackpad input routing passed: device ownership, competing-contact draining, HUD/calibration locks, and reset.")
    }
}
