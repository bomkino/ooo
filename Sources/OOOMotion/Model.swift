import Foundation

// MARK: - World conventions
//
// The slide lies in the z = 0 plane, centred on the origin, one world unit
// tall and `slideAspect` wide; +x right, +y up, +z towards the camera.
// Positions on the slide are given in slide space: u across, v down, both 0…1.

/// A region of the slide the camera frames: centre in slide space, size as a
/// fraction of the slide's width and height. On any canvas the camera shows
/// at least the whole region.
public struct ShotFrame: Codable, Hashable, Sendable {
    public var center: Vec2
    public var size: Vec2

    public init(center: Vec2, size: Vec2) {
        self.center = center
        self.size = size
    }

    /// The whole slide with a margin around it.
    public static func whole(margin: Float = 0.12) -> ShotFrame {
        ShotFrame(center: Vec2(0.5, 0.5), size: Vec2(1 + margin, 1 + margin))
    }

    public var minU: Float { center.x - size.x / 2 }
    public var maxU: Float { center.x + size.x / 2 }
    public var minV: Float { center.y - size.y / 2 }
    public var maxV: Float { center.y + size.y / 2 }

    /// The frame as (u0, v0, u1, v1).
    public var bounds: SIMD4<Float> { SIMD4(minU, minV, maxU, maxV) }

    /// The region the camera actually shows on a canvas of `canvasAspect`
    /// (width / height): this frame widened or heightened to the canvas shape.
    public func visible(slideAspect: Float, canvasAspect: Float) -> ShotFrame {
        let h = max(size.y, size.x * slideAspect / canvasAspect)
        let w = h * canvasAspect / slideAspect
        return ShotFrame(center: center, size: Vec2(w, h))
    }

    /// How many times closer than the whole slide this frame is.
    public func magnification(slideAspect: Float, canvasAspect: Float) -> Float {
        let whole = ShotFrame.whole(margin: 0).visible(slideAspect: slideAspect, canvasAspect: canvasAspect).size.y
        return whole / max(visible(slideAspect: slideAspect, canvasAspect: canvasAspect).size.y, 1e-4)
    }
}

/// How the camera travels to a shot.
public enum MoveKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Flies out just enough to see where it is going, then in: the optimal
    /// zoom-and-pan path (van Wijk & Nuij, 2003).
    case glide
    /// A straight dolly: pans and zooms together in a line.
    case push
    /// Swings round on a gentle arc as it travels.
    case arc
    /// Cuts straight to the shot.
    case cut

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .glide: return "Glide"
        case .push: return "Push"
        case .arc: return "Arc"
        case .cut: return "Cut"
        }
    }
    public var summary: String {
        switch self {
        case .glide: return "Rises to see the way, then sweeps in."
        case .push: return "Travels straight there."
        case .arc: return "Swings round on a curve."
        case .cut: return "Cuts on the moment."
        }
    }
}

/// What happens on the slide while a shot holds.
public enum Emphasis: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    /// The rest of the slide dims, as if a light found the detail.
    case spotlight
    /// The detail lifts off the slide as a cut-out, throwing a shadow.
    case lift

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None"
        case .spotlight: return "Spotlight"
        case .lift: return "Lift"
        }
    }
}

/// One framing the camera lands on, at a moment.
public struct Shot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Seconds from the start when the camera arrives.
    public var time: Double
    /// Seconds the move into this shot takes; nil chooses from the distance.
    public var travel: Double?
    public var frame: ShotFrame
    /// The camera's angle around the framed point, degrees: yaw swings it
    /// round the slide's vertical axis (positive from the right), pitch over
    /// its horizontal axis (positive from above), roll turns the picture.
    public var yaw: Float
    public var pitch: Float
    public var roll: Float
    /// Vertical field of view, degrees. Narrow is a long lens, flatter and calmer.
    public var lens: Float
    /// 0…1 depth of field: how much falls out of focus around the framed point.
    public var aperture: Float
    public var move: MoveKind
    public var ease: EaseKind
    /// 0…1 slow push-in while the shot holds.
    public var breathe: Float
    public var emphasis: Emphasis
    /// What the shot frames, in words (from the slide's text), for the interface.
    public var label: String?
    /// The words in the voiceover this shot lands on, if any. "Cut to Voice"
    /// lands the camera just before they are said.
    public var cue: String?
    /// Reading along: how far the framing glides while the shot holds, in
    /// slide space, so a line too long to show at a readable size is read
    /// from its start to its end. Nil holds still.
    public var sweep: Vec2?
    /// Seconds the glide takes from the landing; nil takes most of the hold.
    public var sweepTime: Double?
    /// The detail the shot is about, which its emphasis lights or lifts;
    /// nil is the whole framing.
    public var focus: ShotFrame?
    /// True for a shot Direct for Me planned, until its framing is changed
    /// by hand: a planned framing follows the canvas, one you set never moves.
    public var planned: Bool?
    /// The slide this shot frames, in a video over several: the id of one of
    /// the slides after the first, or nil for the first.
    public var page: UUID?

    public var isPlanned: Bool { planned == true }

    /// Whether `other` shows the slide differently: its framing, angle, lens or read-along.
    public func framesDifferently(from other: Shot) -> Bool {
        frame != other.frame || yaw != other.yaw || pitch != other.pitch || roll != other.roll || lens != other.lens
            || sweep != other.sweep
    }

    public init(id: UUID = UUID(), time: Double, travel: Double? = nil, frame: ShotFrame,
                yaw: Float = 0, pitch: Float = 0, roll: Float = 0, lens: Float = 28, aperture: Float = 0.4,
                move: MoveKind = .glide, ease: EaseKind = .glide, breathe: Float = 0.5,
                emphasis: Emphasis = .none, label: String? = nil, cue: String? = nil, sweep: Vec2? = nil, sweepTime: Double? = nil,
                focus: ShotFrame? = nil) {
        self.id = id
        self.time = time
        self.travel = travel
        self.frame = frame
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.lens = lens
        self.aperture = aperture
        self.move = move
        self.ease = ease
        self.breathe = breathe
        self.emphasis = emphasis
        self.label = label
        self.cue = cue
        self.sweep = sweep
        self.sweepTime = sweepTime
        self.focus = focus
    }

    /// The establishing framing the slide arrives into: the whole slide at a
    /// gentle angle, so the first frame already has depth. A slide much wider
    /// than its canvas (a wide slide in a Reel) is turned further: seen at an
    /// angle it stands taller in the frame, and the frame gains depth where
    /// a flat view would leave a thin strip in a field of backdrop.
    public static func overview(slideAspect: Float = 16.0 / 9.0, canvasAspect: Float = 16.0 / 9.0, legacy: Bool = false) -> Shot {
        let angle = overviewAngle(slideAspect: slideAspect, canvasAspect: canvasAspect, legacy: legacy)
        return Shot(time: 0, frame: .whole(margin: angle.margin), yaw: angle.yaw, pitch: angle.pitch, roll: 0, lens: 28,
                    aperture: 0.3, move: .glide, ease: .glide, breathe: 0.45, label: "The whole slide")
    }

    /// The opening's angle (degrees) and margin for a slide on a canvas.
    /// `legacy` gives 0.2's, so its documents' openings still follow the canvas.
    public static func overviewAngle(slideAspect A: Float, canvasAspect C: Float,
                                     legacy: Bool = false) -> (yaw: Float, pitch: Float, margin: Float) {
        // How much wider the slide is than the canvas: 1 or less fits as is;
        // a 2.39:1 slide in 9:16 is 4.2.
        let gap = A / max(C, 0.05)
        let k = smoothstep((gap - 1.4) / 2.2)
        if legacy { return (lerp(-9, -34, k), lerp(7, 9, k), lerp(0.12, 0.06, k)) }
        return (lerp(-9, Self.wideOpeningYaw, k), lerp(7, 9, k), lerp(0.12, 0.03, k))
    }

    /// How far the opening turns a slide much wider than its canvas: a 2.39:1
    /// slide in a reel stands 28% of the frame's height at its middle (24% at 0.2's 34°).
    public static let wideOpeningYaw: Float = -44

    /// True when the shot is the default opening for some slide and canvas,
    /// so it may follow the canvas when that changes.
    public func isDefaultOverview(slideAspect: Float, canvasAspect: Float) -> Bool {
        [false, true].contains { legacy in
            let d = Shot.overview(slideAspect: slideAspect, canvasAspect: canvasAspect, legacy: legacy)
            return abs(yaw - d.yaw) < 0.01 && abs(pitch - d.pitch) < 0.01 && abs(roll) < 0.01 && frame == d.frame && lens == d.lens
        }
    }
}

/// The slide's entrance.
public enum ArriveKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Rises out of the dark from depth, straightening as it comes into focus.
    case rise
    /// Unrolls like a print, flattening with a little give.
    case unfold
    /// Falls onto the table and settles, its shadow gathering under it.
    case drop
    /// Comes up where it lies like a print in the developer, the darks first.
    case develop
    /// Turns over from its back to face you.
    case turn
    /// Glides in along a long curve and lands.
    case glide
    /// Knits itself together from threads that shoot in from both sides.
    case weave
    /// Already there.
    case none

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .rise: return "Rise"
        case .unfold: return "Unfold"
        case .drop: return "Drop"
        case .develop: return "Develop"
        case .turn: return "Turn"
        case .glide: return "Glide"
        case .weave: return "Weave"
        case .none: return "None"
        }
    }
    public var summary: String {
        switch self {
        case .rise: return "Rises out of the dark, straightening as it comes into focus."
        case .unfold: return "Unrolls like a print and flattens with a little give."
        case .drop: return "Falls onto the table; its shadow gathers as it lands."
        case .develop: return "Comes up where it lies like a print in the developer, the darks first."
        case .turn: return "Turns over from its back to face you."
        case .glide: return "Glides in on a long curve and lands."
        case .weave: return "Knits itself together, thread by thread, from both sides."
        case .none: return "Already there when the video starts."
        }
    }
    public var defaultDuration: Double {
        switch self {
        case .rise: return 2.1
        case .unfold: return 2.2
        case .drop: return 1.7
        case .develop: return 2.4
        case .turn: return 1.9
        case .glide: return 1.9
        case .weave: return 2.6
        case .none: return 0
        }
    }
    /// The slide lies on a surface rather than floating.
    public var onTable: Bool { self == .drop }
}

public struct Arrive: Codable, Hashable, Sendable {
    public var kind: ArriveKind
    public var duration: Double
    /// 0…1: how far it travels and how much it turns.
    public var intensity: Float

    public init(kind: ArriveKind = .rise, duration: Double? = nil, intensity: Float = 0.6) {
        self.kind = kind
        self.duration = duration ?? kind.defaultDuration
        self.intensity = intensity
    }

    /// When the slide has arrived and the camera rests on the overview.
    public var end: Double { kind == .none ? 0 : max(duration, 0.2) }
}

/// How the video ends.
public enum Ending: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Stays on the last shot.
    case hold
    /// Pulls back to the whole slide.
    case pullBack
    /// Fades to black on the last shot.
    case fade
    /// The slide sinks away into the dark.
    case leave

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .hold: return "Hold"
        case .pullBack: return "Pull Back"
        case .fade: return "Fade"
        case .leave: return "Leave"
        }
    }
}

/// The camera's temperament, shared by every move.
public struct MotionStyle: Codable, Hashable, Sendable {
    /// 0…1: how high a glide flies out between distant details.
    public var flight: Float = 0.5
    /// 0…1: how much the camera leans with its own momentum.
    public var swing: Float = 0.5
    /// 0…1: a slow, breathing drift, as if the camera were held.
    public var drift: Float = 0.35
    /// 0…1: how quickly moves are made when their time is left to the camera.
    public var pace: Float = 0.5

    public init(flight: Float = 0.5, swing: Float = 0.5, drift: Float = 0.35, pace: Float = 0.5) {
        self.flight = flight
        self.swing = swing
        self.drift = drift
        self.pace = pace
    }

    /// The zoom-and-pan trade-off of a glide (ρ in van Wijk & Nuij).
    public var rho: Float { lerp(1.05, 1.9, clamp01(flight)) }
    /// Multiplies automatic travel times.
    public var paceScale: Double { Double(lerp(1.35, 0.72, clamp01(pace))) }
}

// MARK: - Voice

/// One recognised word in the voiceover, times in seconds from the video's start.
public struct SpokenWord: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Float

    public init(text: String, start: Double, end: Double, confidence: Float = 1) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}
