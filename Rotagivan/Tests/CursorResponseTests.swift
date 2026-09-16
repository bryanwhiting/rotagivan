import Foundation

@main
struct CursorResponseTests {
    static func close(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 0.000001) {
        precondition(abs(a-b) < tolerance, "\(message): \(a) != \(b)")
    }

    static func main() throws {
        let legacyJSON = """
        {"cursorSpeed":0.48,"cursorAcceleration":1.16,"scrollMultiplier":2.16,"invertScrollX":false,"invertScrollY":false,"kineticScroll":true,"kineticDecay":0.94,"fineCursorSpeed":0.18,"cursorSpeedTransition":2400}
        """
        let old = try JSONDecoder().decode(MotionProfile.self, from: Data(legacyJSON.utf8))
        precondition(old.cursorResponse == nil)
        close(old.resolvedCursorResponse.gain(at: 0), 0.18, "Legacy Fine retained")
        close(old.resolvedCursorResponse.gain(at: 100_000), 0.48 * 1.16, "Legacy peak gain retained")
        var saved = old
        saved.cursorResponse = .balanced
        let restored = try JSONDecoder().decode(MotionProfile.self, from: JSONEncoder().encode(saved))
        precondition(restored == saved)
        var copy = MotionProfile.precision
        let scroll = copy.scrollMultiplier
        copy.copyCursorSettings(from: saved)
        precondition(copy.resolvedCursorResponse == saved.resolvedCursorResponse && copy.scrollMultiplier == scroll)
        copy.cursorResponse!.setEndpoint(fast: true, gain: 2)
        precondition(copy.cursorResponse != saved.cursorResponse)
        print("Passed legacy migration, independent profile copy, and curve persistence.")

        let nodesJSON = """
        {"points":[{"x":0,"gain":0.11},{"x":0.36,"gain":0.17},{"x":0.74,"gain":1.07},{"x":1,"gain":1.78}],"inputRange":3065,"smoothing":62,"fineRelease":0.09,"fastRelease":0,"releaseShape":50}
        """
        let migrated = try JSONDecoder().decode(CursorResponse.self, from: Data(nodesJSON.utf8))
        close(migrated.fineGain, 0.11, "Node Fine gain retained")
        close(migrated.fastGain, 1.78, "Node Fast gain retained")
        close(migrated.transitionCenter, (0.36 + (0.945-0.17)/0.9*0.38)*3065, "Old halfway speed retained")
        close(migrated.smoothing, 62, "Smoothing retained")
        close(migrated.fineRelease, 0.09, "Fine release retained")
        close(migrated.fastRelease, 0, "Fast release retained")
        close(migrated.releaseShape, 50, "Release shape retained")
        let encoded = try JSONEncoder().encode(migrated)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("points"))
        let decoded = try JSONDecoder().decode(CursorResponse.self, from: encoded)
        precondition(decoded == migrated)
        print("Passed old-node migration and parameter-only persistence.")

        for center in [100.0, 700, 1_500, 4_000] {
            for width in [0.35, 0.75, 1.25] {
                var c = CursorResponse.balanced
                c.transitionCenter = center
                c.transitionWidth = width
                close(c.blend(at: 0), 0, "CDF starts at zero")
                close(c.blend(at: center), 0.5, "Center gives half gain")
                close(c.blend(at: center * exp(-width)), 0.158655253931, "Lower sigma quantile")
                close(c.blend(at: center * exp(width)), 0.841344746069, "Upper sigma quantile")
                var previous = -1.0
                for i in 0...2_000 {
                    let speed = Double(i) * 20
                    let gain = c.gain(at: speed)
                    precondition(gain.isFinite && gain >= previous - 1e-12 && gain <= c.fastGain)
                    previous = gain
                    // Continuous first derivative, including the midpoint.
                    let h = 0.001
                    if speed > h {
                        close((c.gain(at: speed)-c.gain(at: speed-h))/h,
                            (c.gain(at: speed+h)-c.gain(at: speed))/h,
                            "Continuous slope", tolerance: 0.00001)
                    }
                }
                close(c.gain(at: .infinity), c.fastGain, "Fast is asymptotic upper bound")
                precondition(c.gain(at: .nan).isFinite)
            }
        }
        print("Passed distribution quantiles, monotonicity, boundedness and slope continuity.")

        let base = CursorResponse.balanced
        var tuned = base
        tuned.transitionCenter *= 2
        precondition(tuned.gain(at: base.transitionCenter) < base.gain(at: base.transitionCenter))
        tuned = base
        tuned.transitionWidth = CursorResponse.maximumWidth
        let h = 1.0
        let baseSlope = base.gain(at: base.transitionCenter+h) - base.gain(at: base.transitionCenter-h)
        let broadSlope = tuned.gain(at: tuned.transitionCenter+h) - tuned.gain(at: tuned.transitionCenter-h)
        precondition(broadSlope < baseSlope * 0.7)
        tuned.setEndpoint(fast: true, gain: 2)
        close(tuned.fineGain, base.fineGain, "Fast adjustment preserves Fine")
        tuned.setEndpoint(fast: false, gain: 0.05)
        close(tuned.fastGain, 2, "Fine adjustment preserves Fast")
        for percent in [0.0, 25, 50, 75, 100] {
            tuned.centerPercent = percent
            close(tuned.centerPercent, percent, "Center control roundtrip")
        }
        tuned.fineGain = 0; tuned.fastGain = 0
        for speed in [0.0, 100, 4_000, 1e6] { close(tuned.gain(at: speed), 0, "Zero means no motion") }
        tuned.fineGain = 0.5; tuned.fastGain = 0.5
        for speed in [0.0, 100, 4_000, 1e6] { close(tuned.gain(at: speed), 0.5, "Equal endpoints disable acceleration") }
        tuned.transitionWidth = 0
        precondition(tuned.sanitized.transitionWidth == CursorResponse.minimumWidth)
        print("Passed independent controls, broader transition, zero gain and constant gain.")

        let c = CursorResponse.balanced
        for duration in [0.0, 0.01, 0.2, 0.45] {
            close(c.releaseLevel(elapsed: duration, duration: duration), 0, "Release stops at deadline")
            close(c.releaseLevel(elapsed: duration+1, duration: duration), 0, "Release stays stopped")
            let total = c.releaseIntegral(from: 0, to: 1, duration: duration)
            var partitioned = 0.0
            for i in 0..<137 {
                partitioned += c.releaseIntegral(from: Double(i)/137, to: Double(i+1)/137, duration: duration)
            }
            close(total, partitioned, "Timer batching does not change distance")
        }
        print("Passed release deadlines and frame-rate-independent release distance.")

        var timing = CursorTiming()
        _ = timing.interval(scanTime: 65_500, receivedAt: 1)
        close(timing.interval(scanTime: 44, receivedAt: 1.001), 0.008, "Scan-time rollover")
        close(timing.interval(scanTime: 124, receivedAt: 1.002), 0.008, "Queued callback timing")
        close(timing.interval(scanTime: 124, receivedAt: 1.010), 0.008, "Stalled scan fallback")
        var filters = [CursorVelocityFilter(), CursorVelocityFilter()]
        _ = filters[0].update(dx: 0, dy: 0, dt: 0.008, smoothing: 40)
        _ = filters[1].update(dx: 0, dy: 0, dt: 0.016, smoothing: 40)
        for _ in 0..<20 { _ = filters[0].update(dx: 8, dy: 0, dt: 0.008, smoothing: 40) }
        for _ in 0..<10 { _ = filters[1].update(dx: 16, dy: 0, dt: 0.016, smoothing: 40) }
        close(filters[0].speed, filters[1].speed, "Filter is sample-rate independent")
        for _ in 0..<20 { _ = filters[0].update(dx: 0, dy: 0, dt: 0.008, smoothing: 40) }
        precondition(filters[0].speed < 1)
        print("Passed hardware timing, sample-rate invariance, and stationary-speed decay.")
    }
}
