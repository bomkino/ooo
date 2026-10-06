import Foundation

/// When the cover turns over to the slide the video is about, and whether
/// (and when) it turns back before the end.
public struct CoverTiming: Hashable, Sendable {
    /// Seconds from the start when the cover starts to turn over.
    public var turn: Double
    /// Turns back to the cover before the video ends.
    public var turnBack: Bool
    /// When the turn back starts; nil places it once the tour is over.
    public var backAt: Double?

    public init(turn: Double, turnBack: Bool = true, backAt: Double? = nil) {
        self.turn = turn
        self.turnBack = turnBack
        self.backAt = backAt
    }
}

/// One turn of the card: the cover turning over to the slide on its back,
/// or (`back`) the slide turning back to the cover.
public struct Turn: Hashable, Sendable {
    /// Seconds from the start when the card starts to turn.
    public var start: Double
    public var back: Bool

    public init(start: Double, back: Bool) {
        self.start = start
        self.back = back
    }

    /// How long a turn takes: unhurried enough to feel the card's weight.
    public static let length = 1.7

    public var end: Double { start + Self.length }

    /// How far through the turn `t` is, 0…1 (0 before it, 1 after it).
    public func progress(at t: Double) -> Float { clamp01(Float((t - start) / Self.length)) }

    public func contains(_ t: Double) -> Bool { t > start && t < end }
}

/// The card turning over in a person's hand, as pure functions of the turn's
/// progress. The cover is printed on the front and the slide on the back:
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
    /// of the stock. `back` turns from the slide back to the cover.
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

/// Which way the card turns, seen from the opening's side of the slide: its
/// face turns away from the camera first, so the cover is soon edge-on and
/// the slide on its back has most of the turn to itself.
public func turnDirection(overviewYaw yaw: Float) -> Float { yaw <= 0 ? 1 : -1 }
