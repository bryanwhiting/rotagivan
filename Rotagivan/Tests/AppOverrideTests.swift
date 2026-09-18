import Foundation
import CoreGraphics

@main struct AppOverrideTests {
    static func main() throws {
        let base = ProfileGestures(gestures: GestureSettings(), oneFingerTap: .leftClick, twoFingerTap: .enter)
        let chrome = AppGestureOverride.chrome.applying(to: base)
        precondition(chrome.oneFingerTap == .leftClick && chrome.twoFingerTap == .enter && chrome.gestures == base.gestures)
        precondition(chrome.twoFingerSwipe?.right?.keyCode == 33 && chrome.twoFingerSwipe?.left?.keyCode == 30)
        precondition(chrome.twoFingerSwipe?.right?.modifiers == 1 << 20)
        var custom = AppGestureOverride(bundleID:"test.app", name:"Test", bindings:[AppGestureBinding(trigger:.oneFingerTap, action:.none)])
        precondition(custom.applying(to:base).oneFingerTap == .none)
        custom.enabled = false
        precondition(custom.applying(to:base) == base)
        custom.enabled = true
        custom.bindings = [AppGestureBinding(trigger:.singleDown, action:.appExplorer)]
        var disabled = base
        disabled.singleTapSwipe = DoubleTapSwipeSettings(enabled:false, left:RecordedShortcut(keyCode:1,modifiers:0,keyLabel:"S"))
        let resolved = custom.applying(to:disabled)
        precondition(resolved.singleTapSwipe!.action(for:.down) == .appExplorer)
        precondition(resolved.singleTapSwipe!.action(for:.left) == .none, "Do not activate unrelated disabled bindings")
        let decoded = try JSONDecoder().decode(AppGestureOverride.self, from:JSONEncoder().encode(custom))
        precondition(decoded == custom)
        precondition(StoredSettings().resolvedAppOverrides == [.chrome])
        var empty = StoredSettings(); empty.appOverrides = []
        precondition(empty.resolvedAppOverrides.isEmpty)

        let settings = chrome.twoFingerSwipe!
        let t = Date(timeIntervalSince1970:1000)
        func report(_ dx:Double=0, _ dy:Double=0, count:Int=2) -> TrackpadReport {
            TrackpadReport(contacts:(0..<count).map { FingerContact(id:UInt8($0),x:500+Double($0)*200+dx,y:500+dy,touching:true,confident:true) },buttonDown:false,scanTime:0)
        }
        for sign in [-1.0,1.0] {
            var recognizer = TwoFingerNavigationRecognizer()
            precondition(recognizer.update(report(),settings:settings,profileID:1,at:t).consumed)
            precondition(recognizer.update(report(sign*100),settings:settings,profileID:1,at:t+0.08).consumed)
            precondition(recognizer.update(report(sign*100,count:1),settings:settings,profileID:1,at:t+0.1).direction == nil)
            precondition(recognizer.update(report(count:0),settings:settings,profileID:1,at:t+0.12).direction == (sign<0 ? .left : .right))
        }
        for vertical in [false,true] {
            var recognizer = TwoFingerNavigationRecognizer()
            _ = recognizer.update(report(),settings:settings,profileID:1,at:t)
            let outcome = recognizer.update(report(vertical ? 0 : 20,vertical ? 50 : 0),settings:settings,profileID:1,at:t+(vertical ? 0.03 : 0.25))
            precondition(!outcome.consumed && outcome.direction == nil, "Vertical and slow motions scroll")
            precondition(!recognizer.update(report(200),settings:settings,profileID:1,at:t+0.28).consumed, "Scroll cannot become navigation mid-touch")
        }
        var cancel = TwoFingerNavigationRecognizer()
        _ = cancel.update(report(),settings:settings,profileID:1,at:t)
        _ = cancel.update(report(100),settings:settings,profileID:1,at:t+0.08)
        precondition(cancel.update(report(count:0),settings:nil,profileID:1,at:t+0.1).direction == nil)
        print("App overrides passed: Chrome shortcuts, inheritance, explicit none, disabled rules, persistence, navigation directions, staggered lifts, scroll arbitration, and cancellation.")
    }
}
