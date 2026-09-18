import Foundation

@main struct ScrollResponseTests {
    static func main() throws {
        var curve = ScrollResponse(slowMultiplier:0.1,fastMultiplier:3,transitionSpeed:1200)
        precondition(abs(curve.gain(at:1200)-1.55)<1e-12)
        precondition(curve.gain(at:0)==0.1 && curve.gain(at:.infinity)==3)
        precondition(curve.gain(at:.nan).isFinite)
        var previous = 0.0
        for speed in stride(from:0.0,through:16000,by:1) {
            let gain = curve.gain(at:speed)
            precondition(gain >= previous && gain >= 0.1 && gain <= 3)
            precondition(gain - previous < 0.101)
            previous = gain
        }
        let oldSlow = curve.slowMultiplier
        curve.setEndpoint(fast:true,multiplier:0)
        precondition(curve.slowMultiplier == oldSlow && curve.fastMultiplier == oldSlow)
        curve.setEndpoint(fast:false,multiplier:5)
        precondition(curve.slowMultiplier == oldSlow && curve.fastMultiplier == oldSlow)
        for percent in stride(from:0.0,through:100,by:0.1) {
            precondition(abs(ScrollResponse.percent(forMultiplier:ScrollResponse.multiplier(forPercent:percent))-percent)<1e-9)
            curve.transitionPercent = percent
            precondition(abs(curve.transitionPercent-percent)<1e-9)
        }
        precondition(ScrollResponse.multiplier(forPercent:0)==0)
        precondition(abs(ScrollResponse.multiplier(forPercent:100)-ProfileMaximum.scrollSpeed)<1e-12)
        let zero = ScrollResponse(slowMultiplier:0,fastMultiplier:0)
        precondition(zero.gain(at:8000)==0)
        for acceleration in [1.0,1.2,1.5] {
            var legacy = MotionProfile.normal
            legacy.scrollAcceleration = acceleration
            for speed in [0.0,100,250,1000,8000] {
                precondition(legacy.scrollGain(at:speed)==legacy.scrollMultiplier*pow(max(1,speed/250),acceleration-1))
            }
            _ = legacy.resolvedScrollResponse
            precondition(legacy.scrollResponse == nil, "Viewing the graph must not migrate saved settings")
        }
        var profile = MotionProfile.normal
        profile.scrollResponse = curve
        let decoded = try JSONDecoder().decode(MotionProfile.self,from:JSONEncoder().encode(profile))
        precondition(decoded == profile)
        var target = MotionProfile.precision
        let cursorBefore = target.resolvedCursorResponse
        target.copyScrollSettings(from:profile)
        precondition(target.scrollResponse==profile.scrollResponse && target.scrollAcceleration==profile.scrollAcceleration)
        precondition(target.resolvedCursorResponse==cursorBefore)
        print("Scroll curve passed: bounds, zero, monotonic smooth blend, midpoint, independent edits, precision scales, legacy preservation, persistence, and section copying.")
    }
}
