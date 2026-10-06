import Foundation

/// How the card changes from one slide to the next.
public enum PageChange: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The card turns over in the hand, the next slide printed on its back.
    case turn
    /// The card stays where it is and the next slide washes through it from
    /// where you are looking: whatever is on both slides holds still.
    case melt

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .turn: return "Turn"
        case .melt: return "Melt"
        }
    }
    public var summary: String {
        switch self {
        case .turn: return "Turns over in the hand to the next slide."
        case .melt: return "Stays put while the next slide washes in from where you're looking."
        }
    }

    /// How long the change takes: a turn unhurried enough to feel the card's
    /// weight, a melt long enough to watch it spread.
    public var length: Double {
        switch self {
        case .turn: return 1.7
        case .melt: return 1.8
        }
    }
}

/// Another slide the card changes to, as the camera's path needs it.
public struct PageTiming: Hashable, Sendable {
    public var id: UUID
    /// Width / height.
    public var aspect: Float
    public var change: PageChange
    /// Seconds from the start when the change starts; nil finds its own moment.
    public var at: Double?

    public init(id: UUID, aspect: Float, change: PageChange = .turn, at: Double? = nil) {
        self.id = id
        self.aspect = aspect
        self.change = change
        self.at = at
    }
}

/// Turning back to the first slide before the end.
public struct HomeTiming: Hashable, Sendable {
    /// When the turn back starts; nil places it once the tour is over.
    public var at: Double?

    public init(at: Double? = nil) {
        self.at = at
    }
}

/// One change of the card from a slide to another: turning over to the
/// next, melting into it, or (`back`) turning back to the first.
public struct SlideChange: Hashable, Sendable {
    /// Seconds from the start when the change starts.
    public var start: Double
    public var kind: PageChange
    /// The slides it changes from and to (0 is the first).
    public var from: Int
    public var to: Int
    /// Turns back the way the card came.
    public var back: Bool

    public init(start: Double, kind: PageChange, from: Int, to: Int, back: Bool = false) {
        self.start = start
        self.kind = kind
        self.from = from
        self.to = to
        self.back = back
    }

    public var length: Double { kind.length }
    public var end: Double { start + length }

    /// How far through the change `t` is, 0…1 (0 before it, 1 after it).
    public func progress(at t: Double) -> Float { clamp01(Float((t - start) / length)) }

    public func contains(_ t: Double) -> Bool { t > start && t < end }
}

/// The card turning over in a person's hand, as pure functions of the turn's
/// progress. One slide is printed on the front and the next on the back:
/// the card is pressed back a touch, lifts and bows a little as it swings
/// over, and lands on its back with a little give.
public enum CardTurn {
    /// How far the card has turned (radians, 0…π and a little past it)
    /// `progress` (0…1) of the way through turning over. Turning back runs
    /// the other way: π − angle.
    public static func angle(_ progress: Float) -> Float {
        let a = clamp01(progress)
        let u = clamp01((a - 0.1) / 0.9)
        // A soft lift-off, the bulk of the turn through the middle, then it
        // swings a couple of degrees past flat and settles back.
        let swing = Curves.settle(u) + 0.026 * Curves.bump((u - 0.55) / 0.45)
        // First the card is pressed back a little, the way a finger lifts an edge.
        let press = radians(3) * Curves.bump(a / 0.24)
        return .pi * swing - press
    }

    /// The card `progress` of the way through a turn: its turn about its own
    /// upright (`rotation.y`, `direction` · angle, so it swings away from the
    /// camera first), the lean and lift of being turned by hand, and the bow
    /// of the stock. `back` turns back the way it came.
    public static func pose(_ progress: Float, back: Bool, direction: Float) -> SlidePose {
        let a = clamp01(progress)
        let lift = Curves.bump(a)
        var p = SlidePose()
        let turned = back ? .pi - angle(a) : angle(a)
        p.rotation = Vec3(radians(4) * lift, direction * turned, direction * radians(2) * lift)
        p.offset = Vec3(0, 0.05 * lift, 0.16 * lift)
        p.curl = 0.3 * lift
        return p
    }

    /// How much the camera eases back while the card turns (a share of the
    /// view's height): the turning card comes towards it, and it gives it room.
    public static func cameraRoom(_ progress: Float) -> Float { 0.06 * Curves.bump(progress) }

    /// How much of a turn is under way at `progress`, 0…1: the card's surface
    /// catches the light while it turns and settles back to the reading look.
    public static func activity(_ progress: Float) -> Float {
        guard progress > 0, progress < 1 else { return 0 }
        return smoothstep(progress / 0.12) * (1 - smoothstep((progress - 0.82) / 0.18))
    }
}

/// The next slide washing through the card, as pure functions of the
/// melt's progress. It spreads from a point under the eye at an even rate
/// of growth, the way ink spreads in water, so on screen it keeps the same
/// unhurried pace from the first bloom to the frame's edges and on past
/// them to the card's far corners.
public enum Melt {
    /// How far the melt has spread, in world units, `progress` (0…1) of the
    /// way through: from `start` (a few hundredths of the view) to `reach`,
    /// beyond the card's farthest corner.
    public static func radius(_ progress: Float, start: Float, reach: Float) -> Float {
        let p = clamp01(progress)
        guard p > 0 else { return 0 }
        let r0 = max(start, 1e-4)
        let e = smootherstep(p)
        return r0 * powf(max(reach / r0, 1), e) * smoothstep(p / 0.12)
    }

    /// The width of the melt's soft front at radius `r`, in a view `view` tall:
    /// it widens as it spreads, like a wet edge.
    public static func front(_ r: Float, view: Float) -> Float { 0.3 * r + 0.02 * view }

    /// The radius that leaves nothing of the old slide within `farthest` of
    /// the melt's centre, its soft front included.
    public static func reach(farthest: Float, view: Float) -> Float { (farthest + 0.02 * view) / 0.7 + 0.01 }
}

/// Which way the card turns, seen from the opening's side of the slide: its
/// face turns away from the camera first, so the slide on it is soon
/// edge-on and the next one, on its back, has most of the turn to itself.
public func turnDirection(overviewYaw yaw: Float) -> Float { yaw <= 0 ? 1 : -1 }

extension Shot {
    /// The opening framing on another slide: `base`, as set for a slide of
    /// `baseAspect`, follows the other slide's shape unless it was set by hand.
    public static func overview(like base: Shot, baseAspect: Float, slideAspect: Float, canvasAspect: Float) -> Shot {
        guard abs(baseAspect - slideAspect) > 1e-4, base.isDefaultOverview(slideAspect: baseAspect, canvasAspect: canvasAspect) else {
            return base
        }
        let d = Shot.overview(slideAspect: slideAspect, canvasAspect: canvasAspect)
        var s = base
        s.frame = d.frame
        s.yaw = d.yaw
        s.pitch = d.pitch
        return s
    }
}
