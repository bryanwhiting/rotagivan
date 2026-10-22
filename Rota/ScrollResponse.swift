import Foundation

/// Three-parameter scroll response. Fixed-width log-normal blending keeps the
/// transition smooth; coasting after lift is deliberately a separate control.
struct ScrollResponse: Codable, Equatable {
    static let maximumMultiplier = ProfileMaximum.scrollSpeed
    static let minimumTransition = 100.0
    static let maximumTransition = 4_000.0
    static let inputRange = 8_000.0
    var slowMultiplier: Double
    var fastMultiplier: Double
    var transitionSpeed: Double

    init(slowMultiplier: Double, fastMultiplier: Double, transitionSpeed: Double = 1_500) {
        self.slowMultiplier = slowMultiplier
        self.fastMultiplier = fastMultiplier
        self.transitionSpeed = transitionSpeed
    }

    init(legacy profile: MotionProfile) {
        let slow = min(Self.maximumMultiplier, max(0, profile.scrollMultiplier))
        let exponent = profile.resolvedScrollAcceleration - 1
        let fast = min(Self.maximumMultiplier, slow * pow(Self.maximumTransition / ProfileMaximum.scrollAccelerationOnset, exponent))
        let midpoint = slow > 0 && exponent > 0.00001
            ? ProfileMaximum.scrollAccelerationOnset * pow((slow + fast) / (2 * slow), 1 / exponent) : 1_500
        self.init(slowMultiplier: slow, fastMultiplier: fast,
                  transitionSpeed: min(Self.maximumTransition, max(Self.minimumTransition, midpoint)))
    }

    var sanitized: Self {
        func bound(_ x: Double, _ low: Double, _ high: Double) -> Double { x.isFinite ? min(high,max(low,x)) : low }
        let slow = bound(slowMultiplier, 0, Self.maximumMultiplier)
        return Self(slowMultiplier: slow, fastMultiplier: bound(fastMultiplier,slow,Self.maximumMultiplier),
                    transitionSpeed: bound(transitionSpeed,Self.minimumTransition,Self.maximumTransition))
    }

    func gain(at speed: Double) -> Double {
        let c = sanitized
        guard speed > 0 else { return c.slowMultiplier }
        if speed == .infinity { return c.fastMultiplier }
        let blend = 0.5 * erfc(-log(speed / c.transitionSpeed) / (0.75 * sqrt(2)))
        return c.slowMultiplier + (c.fastMultiplier - c.slowMultiplier) * blend
    }

    mutating func setEndpoint(fast: Bool, multiplier: Double) {
        guard multiplier.isFinite else { return }
        self = sanitized
        if fast { fastMultiplier = min(Self.maximumMultiplier, max(slowMultiplier,multiplier)) }
        else { slowMultiplier = min(fastMultiplier,max(0,multiplier)) }
    }

    var transitionPercent: Double {
        get { 100 * log(sanitized.transitionSpeed / Self.minimumTransition) / log(Self.maximumTransition / Self.minimumTransition) }
        set {
            guard newValue.isFinite else { return }
            transitionSpeed = Self.minimumTransition * pow(Self.maximumTransition / Self.minimumTransition,min(100,max(0,newValue))/100)
        }
    }
    static func multiplier(forPercent percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return maximumMultiplier * expm1(4 * min(100,max(0,percent))/100) / expm1(4)
    }
    static func percent(forMultiplier multiplier: Double) -> Double {
        guard multiplier.isFinite else { return 0 }
        return 25 * log1p(min(maximumMultiplier,max(0,multiplier)) / maximumMultiplier * expm1(4))
    }
}

extension MotionProfile {
    var resolvedScrollResponse: ScrollResponse { (scrollResponse ?? ScrollResponse(legacy:self)).sanitized }

    /// Exact legacy behavior until the user edits the curve. The graph uses
    /// this same function, so merely viewing settings cannot change scrolling.
    func scrollGain(at speed: Double) -> Double {
        if let scrollResponse { return scrollResponse.gain(at:speed) }
        let speed = speed.isFinite ? max(0,speed) : 0
        return scrollMultiplier * pow(max(1,speed / ProfileMaximum.scrollAccelerationOnset),resolvedScrollAcceleration - 1)
    }

    mutating func copyScrollSettings(from source: Self) {
        scrollResponse = source.scrollResponse
        scrollMultiplier = source.scrollMultiplier
        scrollAcceleration = source.scrollAcceleration
        invertScrollX = source.invertScrollX
        invertScrollY = source.invertScrollY
        kineticScroll = source.kineticScroll
        kineticDecay = source.kineticDecay
    }
}
