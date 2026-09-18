import Foundation
import CoreGraphics

private final class ScrollPoster: GestureEventPosting {
    var dragging = false
    var scrolls: [Double] = []
    func performTap(_ action:TapAction,shortcut:RecordedShortcut?) {}
    func click(button:CGMouseButton,count:Int) {}
    func move(dx:Double,dy:Double) {}
    func scroll(dx:Double,dy:Double,momentum:Bool) { scrolls.append(dy) }
    func beginDrag() { dragging=true }
    func endDrag() { dragging=false }
}

@main struct ScrollResponseIntegrationTests {
    @MainActor static func sample(speed:Double,curve:ScrollResponse?,jitter:Double=0,invert:Bool=false) -> Double {
        let suite = "Rotagivan.ScrollCurveTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"migration.rotagivan.v1")
        defer { prefs.removePersistentDomain(forName:suite) }
        let store = SettingsStore(defaults:prefs)
        store.settings.defaultProfileID=1; store.setActiveProfile(1)
        var profile = store.motion(for:1)
        profile.scrollResponse=curve; profile.kineticScroll=false; profile.invertScrollY=invert
        profile.scrollMultiplier=1; profile.scrollAcceleration=1.2
        store.updateMotion(profile,for:1)
        var taps = store.activeGestures
        taps.gestures.tapMaxMovement=0
        store.updateGestures(taps,for:1)
        let poster = ScrollPoster()
        var now = Date(timeIntervalSince1970:1000)
        let engine = GestureEngine(store:store,poster:poster,clock:{now})
        defer {engine.reset()}
        func report(_ delta:Double,_ scan:UInt16) -> TrackpadReport {
            TrackpadReport(contacts:[0,1].map {FingerContact(id:UInt8($0),x:500+Double($0)*200,y:500+delta,touching:true,confident:true)},buttonDown:false,scanTime:scan)
        }
        engine.process(report(0,0),receivedAt:1000)
        now=now.addingTimeInterval(0.01+jitter)
        engine.process(report(speed*0.01,100),receivedAt:1000.01+jitter)
        return (poster.scrolls.last ?? 0)/(speed*0.01)
    }
    @MainActor static func main() {
        let curve=ScrollResponse(slowMultiplier:0.1,fastMultiplier:3,transitionSpeed:1200)
        let slow=sample(speed:100,curve:curve),fast=sample(speed:4000,curve:curve)
        precondition(fast>slow*10)
        precondition(abs(sample(speed:1200,curve:curve)-curve.gain(at:1200))<1e-9)
        precondition(abs(sample(speed:1200,curve:curve,jitter:0.04)-sample(speed:1200,curve:curve))<1e-9)
        precondition(sample(speed:1000,curve:curve,invert:true)<0)
        precondition(sample(speed:1000,curve:ScrollResponse(slowMultiplier:0,fastMultiplier:0))==0)
        // Date's reference epoch slightly rounds a 10 ms interval. Compare
        // against the same measured interval used by the legacy engine.
        let start = Date(timeIntervalSince1970:1000)
        let legacyInterval = start.addingTimeInterval(0.01).timeIntervalSince(start)
        precondition(abs(sample(speed:1000,curve:nil)-pow(10/legacyInterval/250,1.2-1))<1e-12)
        print("Scroll integration passed: runtime curve, slow/fast separation, hardware timing despite callback jitter, inversion, true zero, and unchanged legacy acceleration.")
    }
}
