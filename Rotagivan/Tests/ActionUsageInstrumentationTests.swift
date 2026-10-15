import Foundation

@main struct ActionUsageInstrumentationTests {
    static func main() {
        var count = 0
        let action = BindingAction.command(.activateVoiceMode)
        let observer = NotificationCenter.default.addObserver(forName: .init("local.rotagivan.action.invoked"), object: nil, queue: nil) { note in
            precondition(note.object as? BindingAction == action); count += 1
        }
        defer { NotificationCenter.default.removeObserver(observer); RotaActionUsage.enabled = false }
        RotaActionUsage.enabled = false
        RotaActionUsage.record(action)
        precondition(count == 0, "No command events before Screen Time opt-in")
        RotaActionUsage.enabled = true
        RotaActionUsage.begin(action)
        RotaActionUsage.record(action)
        RotaActionUsage.begin(action)
        RotaActionUsage.end(); RotaActionUsage.end()
        precondition(count == 1, "Nested macro/dispatch helpers cannot double count parent command")
        RotaActionUsage.record(action)
        precondition(count == 2, "Independent action invocation counted")
        RotaActionUsage.enabled = false
        RotaActionUsage.record(action)
        precondition(count == 2, "Opt-out immediately stops command events")
        print("Action usage consent/deduplication checks passed; no actions executed")
    }
}
