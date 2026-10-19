import AppKit

@main struct FocusTimerTests {
    @MainActor static func main() {
        let presets = FocusTimerPreset.swipes
        precondition(presets.map(\.minutes) == [5, 10, 15, 20, 30, 45, 55, 60] && FocusTimerPreset.centerMinutes == 25)
        precondition(Set(presets.map(\.direction)).count == 8, "Each direction has one length")
        let byDirection = Dictionary(uniqueKeysWithValues: presets.map { ($0.direction, $0.minutes) })
        precondition(byDirection[.up] == 5 && byDirection[.topRight] == 10 && byDirection[.right] == 15 && byDirection[.bottomRight] == 20)
        precondition(byDirection[.down] == 30 && byDirection[.bottomLeft] == 45 && byDirection[.left] == 55 && byDirection[.topLeft] == 60)

        let timer = FocusTimer.shared
        var alerts: [Int] = []
        timer.presentAlert = { alerts.append($0) }
        let now = Date()
        timer.start(minutes: 25, now: now)
        precondition(timer.endsAt == now.addingTimeInterval(1500) && timer.minutes == 25)
        timer.start(minutes: 10, now: now)
        precondition(timer.minutes == 10, "Starting again replaces the running timer")
        timer.finish()
        precondition(alerts == [10] && timer.endsAt == nil, "Finishing alerts once and clears the timer")
        timer.finish()
        precondition(alerts == [10], "No second alert")
        timer.start(minutes: 0); timer.start(minutes: 500)
        precondition(timer.endsAt == nil, "Out-of-range lengths are ignored")

        let action = BindingAction.command(.timer)
        precondition(action.isValid && VoiceActionRegistry.make(settings: StoredSettings()).contains { $0.action == action },
                     "Timer is an action voice and the Actions list can use")
        print("Focus timer passed: 25-minute center and eight swipe lengths, replace-on-restart, single alert, range checks, registered action. Nothing drawn on screen.")
    }
}
