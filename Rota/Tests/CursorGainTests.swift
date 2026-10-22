import Foundation

@main
struct CursorGainTests {
    static func main() {
        var curve = CursorResponse.balanced
        curve.fineGain = 0.11
        curve.fastGain = 1.78
        curve.transitionCenter = 2_100
        curve.transitionWidth = 0.75
        let dt = 0.008, smoothing = 62.0
        let low = curve.gain(at: 0.43 * 3065)
        let high = curve.gain(at: 0.66 * 3065)
        var filter = CursorGainFilter()
        _ = filter.update(target: low, dt: dt, smoothing: smoothing)
        let eased = filter.update(target: high, dt: dt, smoothing: smoothing)
        precondition(eased > low && eased < high)
        precondition(eased / low <= exp(dt / (smoothing / 100 * 0.075)) + 1e-12)
        print(String(format: "Mid-curve surge: raw gain step %.1f%%, applied first step %.1f%%.", (high/low-1)*100, (eased/low-1)*100))
        // Quantify steady midpoint jitter, after filter settling.
        var raw: [Double] = [], applied: [Double] = []
        filter = CursorGainFilter()
        for i in 0..<250 {
            let target = curve.gain(at: (i % 2 == 0 ? 0.50 : 0.58) * 3065)
            let gain = filter.update(target: target, dt: dt, smoothing: smoothing)
            if i > 100 { raw.append(target); applied.append(gain) }
        }
        let rawSpan = raw.max()! - raw.min()!
        let appliedSpan = applied.max()! - applied.min()!
        precondition(appliedSpan < rawSpan * 0.4)
        print(String(format: "Synthetic midpoint gain oscillation reduced %.1f%%.", (1-appliedSpan/rawSpan)*100))

        // Target and direction are not changed; a stable speed reaches the
        // exact requested sensitivity. A lower/zero target must never overshoot.
        for _ in 0..<200 { _ = filter.update(target: high, dt: dt, smoothing: smoothing) }
        precondition(abs(filter.gain-high) < 1e-9)
        var previous = filter.gain
        for _ in 0..<200 {
            let gain = filter.update(target: low, dt: dt, smoothing: smoothing)
            precondition(gain >= low-1e-12 && gain <= previous+1e-12)
            previous = gain
        }
        precondition(abs(filter.gain-low) < 1e-9)
        precondition(filter.update(target: 0, dt: dt, smoothing: smoothing) == 0)
        precondition(filter.update(target: high, dt: dt, smoothing: 0) == high)
        filter = CursorGainFilter()
        precondition(filter.update(target: high, dt: dt, smoothing: smoothing) == high)

        // Equivalent time intervals should produce equivalent results when
        // smoothing a moderate step (below the rate limit).
        var a = CursorGainFilter(), b = CursorGainFilter()
        _ = a.update(target: 0.5, dt: 0.008, smoothing: smoothing)
        _ = b.update(target: 0.5, dt: 0.004, smoothing: smoothing)
        for _ in 0..<10 { _ = a.update(target: 0.6, dt: 0.008, smoothing: smoothing) }
        for _ in 0..<20 { _ = b.update(target: 0.6, dt: 0.004, smoothing: smoothing) }
        precondition(abs(a.gain-b.gain) < 1e-9)
        print("Passed gain slew limit, midpoint noise, target convergence, immediate zero, bypass, reset, and sample-rate invariance.")
    }
}
