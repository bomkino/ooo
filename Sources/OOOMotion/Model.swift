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

    public init(id: UUID = UUID(), time: Double, travel: Double? = nil, frame: ShotFrame,
                yaw: Float = 0, pitch: Float = 0, roll: Float = 0, lens: Float = 28, aperture: Float = 0.4,
                move: MoveKind = .glide, ease: EaseKind = .glide, breathe: Float = 0.5,
                emphasis: Emphasis = .none, label: String? = nil, cue: String? = nil) {
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
    }

    /// The establishing framing the slide arrives into: the whole slide at a
    /// gentle angle, so the first frame already has depth.
    public static func overview(slideAspect: Float = 16.0 / 9.0) -> Shot {
        Shot(time: 0, frame: .whole(), yaw: -9, pitch: 7, roll: 0, lens: 28, aperture: 0.3,
             move: .glide, ease: .glide, breathe: 0.45, label: "The whole slide")
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
    /// Comes into focus where it lies, like a photograph developing.
    case develop
    /// Turns over from its back to face you.
    case turn
    /// Glides in along a long curve and lands.
    case glide
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
        case .none: return "None"
        }
    }
    public var summary: String {
        switch self {
        case .rise: return "Rises out of the dark, straightening as it comes into focus."
        case .unfold: return "Unrolls like a print and flattens with a little give."
        case .drop: return "Falls onto the table; its shadow gathers as it lands."
        case .develop: return "Comes into focus where it lies, like a photograph developing."
        case .turn: return "Turns over from its back to face you."
        case .glide: return "Glides in on a long curve and lands."
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
