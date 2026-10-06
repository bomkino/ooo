import Foundation

/// How a camera move leaves one framing and lands on the next.
///
/// Every ease is the integral of a bell-shaped speed curve, v(u) = uᵖ·e^(−qu):
/// it lifts off from rest with no jolt (zero speed and zero acceleration), peaks
/// early or late, and still carries a little speed when it lands. That last bit
/// of momentum is not dropped: the hold that follows bleeds it away (see
/// `Choreography`), so a move glides into its framing and settles instead of
/// stopping dead.
public enum EaseKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Soft lift-off, a long graceful landing. The default.
    case glide
    /// Unhurried and nearly symmetric, like a slow breath.
    case breathe
    /// Leaves decisively and settles long, like a practised hand.
    case swift
    /// Starts gently and takes its time to settle.
    case linger

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .glide: return "Glide"
        case .breathe: return "Breathe"
        case .swift: return "Swift"
        case .linger: return "Linger"
        }
    }

    public var summary: String {
        switch self {
        case .glide: return "Lifts off softly and lands long."
        case .breathe: return "Slow and even, in and out."
        case .swift: return "Leaves at once, then settles."
        case .linger: return "Takes its time arriving."
        }
    }

    /// Shape of the speed curve: p softens the lift-off, q lengthens the landing.
    var shape: (p: Double, q: Double) {
        switch self {
        case .glide: return (2.2, 6.5)
        case .breathe: return (3.0, 8.0)
        case .swift: return (1.5, 9.0)
        case .linger: return (2.5, 10.0)
        }
    }

    /// How long, in seconds, the landing's last momentum takes to settle.
    public var settle: Double {
        switch self {
        case .glide: return 0.45
        case .breathe: return 0.65
        case .swift: return 0.38
        case .linger: return 0.6
        }
    }

    public var curve: EaseCurve { EaseCurve.cached(self) }
}

/// A normalised ease: value(0) = 0, value(1) = 1, monotonic.
public struct EaseCurve: Sendable {
    public let p: Double
    public let q: Double
    /// Cumulative integral of the speed curve, normalised, sampled uniformly.
    private let table: [Float]
    private let total: Double

    public init(p: Double, q: Double, resolution: Int = 2048) {
        self.p = p
        self.q = q
        // Integrate v(s) = s^p e^(−qs) with Simpson's rule on each table step.
        var cumulative = [Double](repeating: 0, count: resolution + 1)
        let h = 1.0 / Double(resolution)
        func v(_ s: Double) -> Double { s <= 0 ? 0 : pow(s, p) * exp(-q * s) }
        var acc = 0.0
        for i in 0..<resolution {
            let a = Double(i) * h, b = a + h
            acc += (v(a) + 4 * v((a + b) / 2) + v(b)) * h / 6
            cumulative[i + 1] = acc
        }
        total = acc
        table = cumulative.map { Float($0 / acc) }
    }

    /// Progress at normalised time u in 0…1.
    public func value(_ u: Float) -> Float {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        let x = u * Float(table.count - 1)
        let i = min(Int(x), table.count - 2)
        let f = x - Float(i)
        return table[i] + (table[i + 1] - table[i]) * f
    }

    /// d(value)/du at u: the speed, in progress per unit of normalised time.
    public func slope(_ u: Float) -> Float {
        let s = Double(min(max(u, 0), 1))
        return s <= 0 ? 0 : Float(pow(s, p) * exp(-q * s) / total)
    }

    /// The speed still carried at the landing, as a fraction of the average speed.
    public var landingSpeed: Float { slope(1) }

    /// The fastest the ease moves, as a multiple of its average speed (at u = p/q).
    public var peakSlope: Float { slope(Float(min(p / q, 1))) }

    private static let all: [EaseKind: EaseCurve] = {
        var d: [EaseKind: EaseCurve] = [:]
        for k in EaseKind.allCases { d[k] = EaseCurve(p: k.shape.p, q: k.shape.q) }
        return d
    }()

    public static func cached(_ kind: EaseKind) -> EaseCurve { all[kind]! }
}

/// Small analytic curves for the slide's own arrival.
public enum Curves {
    /// A critically damped approach from 0 to 1, normalised so it lands at u = 1.
    /// `k` sets how early the bulk of the move happens (higher = earlier, longer tail).
    public static func approach(_ u: Float, k: Float = 7) -> Float {
        let t = clamp01(u)
        let raw = 1 - (1 + k * t) * expf(-k * t)
        let end = 1 - (1 + k) * expf(-k)
        return raw / end
    }

    /// An underdamped spring from 0 to 1 (overshoots slightly, settles by u = 1).
    /// `bounce` 0…1 sets how far it overshoots; `wobbles` the number of half swings.
    public static func spring(_ u: Float, bounce: Float = 0.2, wobbles: Float = 1.6) -> Float {
        let t = clamp01(u)
        if t >= 1 { return 1 }
        let zeta = max(0.12, 1 - bounce)
        let omega = Float.pi * wobbles / max(sqrtf(max(1 - zeta * zeta, 0.05)), 0.05)
        let wd = omega * sqrtf(max(1 - zeta * zeta, 1e-4))
        let decay = expf(-zeta * omega * t)
        let raw = 1 - decay * (cosf(wd * t) + (zeta * omega / wd) * sinf(wd * t))
        // Blend into exactly 1 over the last tenth, so it never pops at the end.
        let tail = smoothstep(0.9, 1.0, t)
        return raw + (1 - raw) * tail
    }

    /// Accelerates from rest like a falling object, landing at u = 1.
    public static func fall(_ u: Float) -> Float { let t = clamp01(u); return t * t }

    /// Reading along a line: eases up to an even pace, keeps it, and eases
    /// to rest, so the middle of the line passes at reading speed.
    public static func along(_ u: Float, ramp r: Float = 0.24) -> Float {
        let t = clamp01(u)
        func integral(_ x: Float) -> Float { x * x * x - x * x * x * x / 2 }
        let p: Float
        if t < r {
            p = r * integral(t / r)
        } else if t > 1 - r {
            p = r / 2 + (1 - 2 * r) + r * (0.5 - integral((1 - t) / r))
        } else {
            p = r / 2 + (t - r)
        }
        return p / (1 - r)
    }

    /// From rest to rest the way a hand moves something it cares about:
    /// leaves softly, covers most of the way just before halfway, and comes
    /// to rest so gently its last moments can't be told from stillness
    /// (speed u²(1 − u)³, normalised: no jolt at either end).
    public static func settle(_ u: Float) -> Float {
        let t = clamp01(u)
        let t3 = t * t * t
        return t3 * (20 + t * (-45 + t * (36 - 10 * t)))
    }

    /// A bell 0 → 1 → 0 over 0…1, smooth at both ends.
    public static func bump(_ u: Float) -> Float {
        let t = clamp01(u)
        let s = sinf(.pi * t)
        return s * s
    }
}
