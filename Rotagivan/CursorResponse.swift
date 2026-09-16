import Foundation

struct CursorSample: Equatable {
    var profileID: UInt32 = 0
    var speed = 0.0
    var gain = 0.0
    var touching = false
}

/// Latest-value buffer, deliberately not observable. HID processing never
/// publishes UI updates: the small live overlay samples this on its own clock.
@MainActor
final class CursorTelemetry {
    private(set) var latest = CursorSample()

    func record(_ sample: CursorSample) { latest = sample }
    func endTouch() { latest.touching = false }
    func reset() { latest = CursorSample() }
}

struct ResponsePoint: Codable, Equatable {
    var x: Double
    var gain: Double
}

/// Log-normal CDF: gain = fine + (fast - fine) * Phi(log(speed / center) / width).
/// Analytic, monotone and smooth, with no segment joins or hard fast threshold.
struct CursorResponse: Codable, Equatable {
    static let maximumGain = 3.36
    static let maximumRelease = 0.45
    static let minimumCenter = 100.0
    static let maximumCenter = 4_000.0
    static let minimumWidth = 0.35
    static let maximumWidth = 1.25
    // Fixed plot scale: changing a parameter must visibly change the curve.
    var inputRange: Double { 8_000 }
    var fineGain: Double = 0.18
    var fastGain: Double = 1.15
    var transitionCenter: Double = 1_500
    var transitionWidth: Double = 0.75
    var smoothing: Double = 30 // 0–100 -> 0–50 ms velocity time constant
    var fineRelease: Double = 0
    var fastRelease: Double = 0
    var releaseShape: Double = 50

    init(legacy profile: MotionProfile) {
        fineGain = profile.resolvedFineCursorSpeed
        fastGain = max(fineGain, profile.cursorSpeed * min(1.4, max(1, profile.cursorAcceleration)))
        transitionCenter = min(Self.maximumCenter, max(Self.minimumCenter,
            profile.resolvedCursorSpeedTransition * 0.75))
        func release(_ coefficient: Double) -> Double {
            guard coefficient > 0 else { return 0 }
            return min(Self.maximumRelease, log(0.015) / log(min(0.85, coefficient)) / 60)
        }
        fineRelease = release(profile.resolvedFineCursorFalloff)
        fastRelease = release(profile.resolvedCursorFalloff)
    }

    static var balanced: Self {
        var curve = Self(legacy: .normal)
        curve.fineGain = 0.18
        curve.fastGain = 1.15
        curve.transitionCenter = 1_500
        curve.fineRelease = 0
        curve.fastRelease = 0
        return curve
    }

    private enum CodingKeys: String, CodingKey {
        case fineGain, fastGain, transitionCenter, transitionWidth
        case smoothing, fineRelease, fastRelease, releaseShape
        case points, inputRange // Read-only compatibility with the node editor.
    }

    init(from decoder: Decoder) throws {
        self = .balanced
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let points = try values.decodeIfPresent([ResponsePoint].self, forKey: .points),
           points.count >= 2 {
            let range = try values.decodeIfPresent(Double.self, forKey: .inputRange) ?? 4_000
            fineGain = points.first!.gain
            fastGain = points.last!.gain
            // Preserve endpoint sensitivities and estimate the old halfway
            // speed. Deliberately replace sharp bends with a broad distribution.
            let halfway = (fineGain + fastGain) / 2
            if let i = (1..<points.count).first(where: { points[$0].gain > halfway }) {
                let a = points[i-1], b = points[i]
                let fraction = (halfway - a.gain) / (b.gain - a.gain)
                transitionCenter = (a.x + fraction * (b.x-a.x)) * range
            }
        }
        fineGain = try values.decodeIfPresent(Double.self, forKey: .fineGain) ?? fineGain
        fastGain = try values.decodeIfPresent(Double.self, forKey: .fastGain) ?? fastGain
        transitionCenter = try values.decodeIfPresent(Double.self, forKey: .transitionCenter) ?? transitionCenter
        transitionWidth = try values.decodeIfPresent(Double.self, forKey: .transitionWidth) ?? transitionWidth
        smoothing = try values.decodeIfPresent(Double.self, forKey: .smoothing) ?? smoothing
        fineRelease = try values.decodeIfPresent(Double.self, forKey: .fineRelease) ?? fineRelease
        fastRelease = try values.decodeIfPresent(Double.self, forKey: .fastRelease) ?? fastRelease
        releaseShape = try values.decodeIfPresent(Double.self, forKey: .releaseShape) ?? releaseShape
        self = sanitized
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let c = sanitized
        try values.encode(c.fineGain, forKey: .fineGain)
        try values.encode(c.fastGain, forKey: .fastGain)
        try values.encode(c.transitionCenter, forKey: .transitionCenter)
        try values.encode(c.transitionWidth, forKey: .transitionWidth)
        try values.encode(c.smoothing, forKey: .smoothing)
        try values.encode(c.fineRelease, forKey: .fineRelease)
        try values.encode(c.fastRelease, forKey: .fastRelease)
        try values.encode(c.releaseShape, forKey: .releaseShape)
    }

    var sanitized: Self {
        var result = self
        func bounded(_ value: Double, _ low: Double, _ high: Double) -> Double {
            value.isFinite ? min(high, max(low, value)) : low
        }
        result.fineGain = bounded(fineGain, 0, Self.maximumGain)
        result.fastGain = bounded(fastGain, result.fineGain, Self.maximumGain)
        result.transitionCenter = bounded(transitionCenter, Self.minimumCenter, Self.maximumCenter)
        result.transitionWidth = bounded(transitionWidth, Self.minimumWidth, Self.maximumWidth)
        result.smoothing = bounded(smoothing, 0, 100)
        result.fineRelease = bounded(fineRelease, 0, Self.maximumRelease)
        result.fastRelease = bounded(fastRelease, 0, Self.maximumRelease)
        result.releaseShape = bounded(releaseShape, 0, 100)
        return result
    }

    mutating func setEndpoint(fast: Bool, gain: Double) {
        guard gain.isFinite else { return }
        self = sanitized
        if fast { fastGain = min(Self.maximumGain, max(fineGain, gain)) }
        else { fineGain = min(fastGain, max(0, gain)) }
    }

    /// Logarithmic median-speed control: equal slider travel means equal
    /// ratios of finger speed, giving fine-motion tuning usable resolution.
    var centerPercent: Double {
        get {
            log(sanitized.transitionCenter / Self.minimumCenter)
                / log(Self.maximumCenter / Self.minimumCenter) * 100
        }
        set {
            guard newValue.isFinite else { return }
            transitionCenter = Self.minimumCenter * pow(Self.maximumCenter / Self.minimumCenter,
                min(100, max(0, newValue)) / 100)
        }
    }

    func blend(at speed: Double) -> Double {
        guard speed > 0 else { return 0 }
        if speed == .infinity { return 1 }
        guard speed.isFinite else { return 0 }
        let c = sanitized
        return 0.5 * erfc(-log(speed / c.transitionCenter) / (c.transitionWidth * sqrt(2)))
    }

    func gain(at speed: Double) -> Double {
        let c = sanitized
        return c.fineGain + (c.fastGain - c.fineGain) * c.blend(at: speed)
    }

    func releaseDuration(at speed: Double) -> Double {
        let c = sanitized
        return c.fineRelease + (c.fastRelease - c.fineRelease) * c.blend(at: speed)
    }

    func releaseLevel(elapsed: Double, duration: Double) -> Double {
        guard duration > 0, elapsed < duration else { return 0 }
        return pow(max(0, 1 - max(0, elapsed) / duration), 1 + sanitized.releaseShape / 25)
    }

    /// Integrate the plotted envelope over actual elapsed time, so delayed
    /// timer ticks do not extend the release or change its distance.
    func releaseIntegral(from start: Double, to end: Double, duration: Double) -> Double {
        guard duration > 0, end > start else { return 0 }
        let power = 2 + sanitized.releaseShape / 25
        let a = min(1, max(0, start / duration)), b = min(1, max(0, end / duration))
        return duration / power * (pow(1-a, power) - pow(1-b, power))
    }
}

/// PTP scan time wraps at UInt16 and uses 100 µs units. Callback uptime is a
/// fallback; main-thread scheduling delay must not determine finger speed.
struct CursorTiming {
    private var scan: UInt16?
    private var uptime: TimeInterval?
    mutating func interval(scanTime: UInt16, receivedAt: TimeInterval) -> TimeInterval {
        defer { scan = scanTime; uptime = receivedAt }
        if let scan, let uptime, receivedAt - uptime < 0.25 {
            let hardware = Double(scanTime &- scan) * 0.0001
            if hardware >= 0.0001 && hardware <= 0.1 { return hardware }
        }
        guard let uptime else { return 1.0 / 125 }
        return min(0.1, max(0.001, receivedAt - uptime))
    }
}

struct CursorVelocityFilter {
    private(set) var speed = 0.0
    private var initialized = false
    private var previousDX = 0.0
    private var previousDY = 0.0
    mutating func update(dx: Double, dy: Double, dt: Double, smoothing: Double) -> Double {
        let instant = hypot(dx, dy) / max(0.0001, dt)
        let reversed = dx * previousDX + dy * previousDY < 0
        let tau = min(100, max(0, smoothing)) * 0.0005
        let alpha = tau > 0 ? 1 - exp(-dt / tau) : 1
        if !initialized || reversed { speed = instant; initialized = true }
        else { speed += alpha * (instant - speed) }
        previousDX = dx; previousDY = dy
        return speed
    }
}

/// A smooth curve in velocity space can still give abrupt gain changes in
/// time, especially through a steep middle section. Filter relative gain
/// changes separately, without averaging pointer positions or directions.
struct CursorGainFilter {
    private(set) var gain = 0.0
    private var initialized = false

    mutating func update(target: Double, dt: Double, smoothing: Double) -> Double {
        let target = target.isFinite ? min(CursorResponse.maximumGain, max(0, target)) : 0
        let amount = min(100, max(0, smoothing)) / 100
        let interval = min(0.1, max(0.0001, dt))
        guard initialized, amount > 0, target > 0 else {
            gain = target
            initialized = true
            return gain
        }
        // Relative interpolation makes a change from 0.1 to 0.2 as gradual
        // as 1 to 2. Drop sensitivity faster when returning to fine control.
        let rising = target > gain
        let tau = amount * (rising ? 0.030 : 0.015)
        let alpha = 1 - exp(-interval / tau)
        if gain <= 0 {
            gain = target * alpha
            return gain
        }
        let logCurrent = log(gain)
        let requestedChange = alpha * (log(target) - logCurrent)
        let maximumChange = interval / (amount * (rising ? 0.075 : 0.0375))
        let change = min(maximumChange, max(-maximumChange, requestedChange))
        gain = exp(logCurrent + change)
        return gain
    }
}
