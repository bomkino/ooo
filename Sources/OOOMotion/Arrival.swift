import Foundation

/// The slide's own pose and finish at one moment of its entrance or exit,
/// relative to where it rests.
public struct SlidePose: Sendable, Equatable {
    /// World units.
    public var offset: Vec3 = .zero
    /// Radians: x pitches (positive brings the top towards you), y yaws
    /// (positive sends the right edge away), z rolls. Applied yaw, pitch, roll.
    public var rotation: Vec3 = .zero
    /// −1…1 cylindrical curl, positive bringing the side edges towards you.
    public var curl: Float = 0
    /// 0…1 travelling buckle, and its phase.
    public var fold: Float = 0
    public var foldPhase: Float = 0
    public var opacity: Float = 1
    /// Extra defocus, in pixels of a 1080-pixel-wide frame.
    public var blur: Float = 0
    /// Multiplies the slide's light.
    public var exposure: Float = 1
    /// Extra brightness, 0 = none.
    public var glow: Float = 0
    /// Bends like paper (curl at full strength) rather than card stock.
    public var paper = false

    public init() {}

    public static let rest = SlidePose()
}

/// The slide's entrances and exit as pure functions of time.
public enum Arrival {
    /// Where the camera starts before settling on the overview as the slide arrives.
    public static func cameraStart(_ overview: CameraPose, arrive: Arrive) -> CameraPose {
        var p = overview
        let k = lerp(0.5, 1.3, clamp01(arrive.intensity))
        switch arrive.kind {
        case .rise:
            p.height *= 1 + 0.16 * k
            p.yaw += radians(5) * k
            p.pitch += radians(3) * k
        case .unfold:
            p.height *= 1 + 0.1 * k
            p.yaw -= radians(4) * k
        case .drop:
            p.height *= 1 + 0.2 * k
            p.roll -= radians(1.2) * k
        case .develop:
            p.height *= 1 + 0.08 * k
        case .turn:
            p.height *= 1 + 0.12 * k
            p.yaw -= radians(3) * k
        case .glide:
            p.height *= 1 + 0.12 * k
            p.pitch -= radians(2) * k
        case .none:
            break
        }
        return p
    }

    /// The moment the slide touches down or completes its entrance, for sound and ticks.
    public static func contact(_ arrive: Arrive) -> Double? {
        let d = arrive.duration
        switch arrive.kind {
        case .drop: return d * Double(dropContact)
        case .rise: return d * 0.62
        case .unfold: return d * 0.55
        case .turn: return d * 0.6
        case .glide: return d * 0.58
        case .develop: return d * 0.7
        case .none: return nil
        }
    }

    static let dropContact: Float = 0.52

    /// The slide at time `t` (seconds from the start) of `arrive`.
    public static func slide(at t: Double, arrive: Arrive, canvasAspect: Float) -> SlidePose {
        guard arrive.kind != .none, arrive.duration > 0, t < arrive.duration else { return .rest }
        let a = Float(max(t, 0) / arrive.duration)
        let s = lerp(0.55, 1.35, clamp01(arrive.intensity))
        var p = SlidePose()
        switch arrive.kind {
        case .rise:
            let move = Curves.approach(a, k: 6.2)
            let turn = Curves.approach(max(a - 0.06, 0) / 0.94, k: 5.4)
            p.offset = Vec3(0, -0.55 * s, -2.4 * s) * (1 - move)
            p.rotation = Vec3(radians(-30 * s), radians(16 * s), radians(-3 * s)) * (1 - turn)
            p.curl = 0.22 * s * (1 - turn)
            p.opacity = smoothstep(a / 0.22)
            p.exposure = lerp(0.35, 1, smoothstep(a / 0.6))

        case .unfold:
            p.paper = true
            let open = Curves.spring(a, bounce: 0.18, wobbles: 1.4)
            let move = Curves.approach(a, k: 6)
            let turn = Curves.approach(a, k: 5)
            p.curl = 1 - open
            p.fold = 0.45 * s * (1 - smoothstep(a / 0.8))
            p.foldPhase = a * 3.2
            p.offset = Vec3(0, -0.18 * s, -0.6 * s) * (1 - move)
            p.rotation = Vec3(radians(10 * s), radians(-14 * s), radians(2 * s)) * (1 - turn)
            p.opacity = smoothstep(a / 0.15)
            p.exposure = lerp(0.6, 1, smoothstep(a / 0.5))

        case .drop:
            p.paper = true
            let c = dropContact
            if a < c {
                let fall = Curves.fall(a / c)
                p.offset.z = 1.3 * s * (1 - fall)
            } else {
                // One small rebound on touching down, then still.
                p.offset.z = 0.018 * s * Curves.bump((a - c) / 0.16)
            }
            let air = 1 - smoothstep(a / c)
            p.rotation = Vec3(radians(6 * s) * air, radians(-5 * s) * air,
                              radians(10 * s) * (1 - Curves.spring(a, bounce: 0.25, wobbles: 2.0)))
            p.fold = 0.35 * s * air + 0.12 * s * Curves.bump((a - c) / 0.2)
            p.foldPhase = a * 7
            p.opacity = smoothstep(a / 0.12)

        case .develop:
            let resolve = Curves.approach(a, k: 4.5)
            p.blur = 48 * (1 - resolve)
            p.exposure = lerp(0.12, 1, Curves.approach(a, k: 3.8))
            p.glow = 0.18 * Curves.bump(clamp01((a - 0.45) / 0.55))
            p.opacity = smoothstep(a / 0.25)

        case .turn:
            let turn = Curves.spring(a, bounce: 0.12, wobbles: 1.2)
            let arc = Curves.bump(min(a / 0.9, 1))
            p.rotation = Vec3(0, .pi * (1 - turn), radians(4 * s) * (1 - turn))
            p.offset = Vec3(0, 0.06 * s * arc, 0.42 * s * arc)
            p.curl = 0.3 * arc
            p.opacity = smoothstep(a / 0.1)

        case .glide:
            // It sweeps in on a bow, not a straight line, and comes the last
            // stretch straight on; the turn finishes after the travel, so it
            // squares up into place.
            let move = Curves.approach(a, k: 5.5)
            let turn = Curves.approach(a, k: 4.8)
            let start: Vec3, bow: Vec3
            if canvasAspect < 0.9 {
                start = Vec3(0, -2.6 * s, -0.3 * s)
                bow = Vec3(0.5 * s, 0, -0.4 * s)
                p.rotation = Vec3(radians(-38 * s), radians(6 * s), 0) * (1 - turn)
            } else {
                start = Vec3(3.2 * s, 0, -0.3 * s)
                bow = Vec3(0, -0.4 * s, -0.4 * s)
                p.rotation = Vec3(0, radians(-40 * s), radians(-2 * s)) * (1 - turn)
            }
            p.offset = along([start, start * 0.6 + bow, start * 0.15, .zero], move)
            p.curl = 0.18 * (1 - turn)
            p.opacity = smoothstep(a / 0.12)

        case .none:
            break
        }
        return p
    }

    /// The point `f` (0…1) of the way along a cubic Bézier by distance, not
    /// by its parameter, so the ease alone sets the speed along the curve.
    static func along(_ p: [Vec3], _ f: Float) -> Vec3 {
        func point(_ u: Float) -> Vec3 {
            let v = 1 - u
            return p[0] * (v * v * v) + p[1] * (3 * v * v * u) + p[2] * (3 * v * u * u) + p[3] * (u * u * u)
        }
        let n = 48
        var lengths = [Float](repeating: 0, count: n + 1)
        var last = point(0)
        for i in 1...n {
            let q = point(Float(i) / Float(n))
            lengths[i] = lengths[i - 1] + (q - last).length
            last = q
        }
        let target = clamp01(f) * lengths[n]
        var i = 1
        while i < n && lengths[i] < target { i += 1 }
        let step = max(lengths[i] - lengths[i - 1], 1e-6)
        return point((Float(i - 1) + clamp01((target - lengths[i - 1]) / step)) / Float(n))
    }

    /// The slide sinking away into the dark (`progress` 0…1).
    public static func leaving(_ progress: Float) -> SlidePose {
        var p = SlidePose()
        let e = clamp01(progress)
        let away = Curves.fall(e)
        p.offset = Vec3(0, 0.35, -2.6) * away
        p.rotation = Vec3(radians(-26) * away, radians(-8) * away, 0)
        p.curl = 0.15 * away
        p.opacity = 1 - smoothstep((e - 0.55) / 0.45)
        p.exposure = 1 - 0.65 * e
        return p
    }
}
