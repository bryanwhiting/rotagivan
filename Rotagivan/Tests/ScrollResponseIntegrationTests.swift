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
    @MainActor static func sample(speed:Double,curve:ScrollResponse?,jitter:Double=0,invert:Bool=false,
        hardwareTime:Bool=true, processingDelay:Double=0) -> Double {
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
        now=now.addingTimeInterval(0.01+jitter+processingDelay)
        engine.process(report(speed*0.01,hardwareTime ? 100 : 0),receivedAt:1000.01+jitter)
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
        precondition(abs(sample(speed:1000,curve:nil)-pow(1000/250,1.2-1))<1e-12,
            "Legacy acceleration formula stays the same, measured using hardware time")
        for response in [Optional(curve), nil] {
            let baseline = sample(speed:1200,curve:response)
            for jitter in [-0.009, 0.04] {
                precondition(abs(sample(speed:1200,curve:response,jitter:jitter,processingDelay:0.08)-baseline)<1e-9,
                    "Queued and delayed reports must not distort either scroll response mode")
            }
            let fallback = sample(speed:1200,curve:response,hardwareTime:false)
            precondition(abs(fallback-baseline)<1e-8)
            precondition(abs(sample(speed:1200,curve:response,hardwareTime:false,processingDelay:0.08)-fallback)<1e-9,
                "Missing scan time uses capture uptime, not time spent waiting for UI")
        }
        print("Scroll integration passed: both modes resist callback/processing jitter; capture-time fallback, slow/fast separation, inversion, true zero, unchanged acceleration formula.")
    }
}
