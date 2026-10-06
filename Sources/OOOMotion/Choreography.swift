import Foundation

/// Everything the camera's path depends on.
public struct ChoreographyInput: Sendable {
    public var overview: Shot
    public var shots: [Shot]
    public var arrive: Arrive
    public var ending: Ending
    public var duration: Double
    public var slideAspect: Float
    public var canvasAspect: Float
    public var style: MotionStyle
    public var seed: UInt32
    /// The part of the canvas framings sit in.
    public var safe: SafeArea

    public init(overview: Shot, shots: [Shot], arrive: Arrive, ending: Ending, duration: Double,
                slideAspect: Float, canvasAspect: Float, style: MotionStyle, seed: UInt32 = 1, safe: SafeArea = .none) {
        self.overview = overview
        self.shots = shots
        self.arrive = arrive
        self.ending = ending
        self.duration = duration
        self.slideAspect = slideAspect
        self.canvasAspect = canvasAspect
        self.style = style
        self.seed = seed
        self.safe = safe
    }
}

/// The camera's whole path as a pure function of time, so scrubbing is exact
/// and the preview always matches the export.
///
/// The path is a chain of beats. Each beat travels from where the last one
/// rested to its own framing, landing exactly on its moment, then holds. A
/// move keeps a little of its momentum as it lands and the hold bleeds it away
/// along the same path, so the camera glides into each framing and settles,
/// with continuous speed everywhere. While a shot holds it can breathe (a slow
/// push-in that starts and ends at rest) and read along (glide across a line
/// too long to show whole at a readable size, starting and ending at rest).
/// On top of the path the camera leans with its own speed (swing) and drifts
/// as if held; both are smooth in time.
public struct Choreography: Sendable {
    public struct Beat: Sendable {
        public let shot: Shot
        public let isOverview: Bool
        /// The settled framing.
        public let pose: CameraPose
        /// When the move into this beat starts, when it arrives, and when the move out starts.
        public let depart: Double
        public let land: Double
        public let leave: Double

        let from: CameraPose
        let path: ZoomPath
        let curve: EaseCurve
        /// Share of the move left for the hold to finish, 0…0.2, and how
        /// steeply the hold takes it in: the rest remaining x seconds into the
        /// hold is overrun · (1 − x/hold)^tail.
        let overrun: Float
        let tail: Float
        /// Natural-log push-in over the hold.
        let breathe: Float
        let arcSign: Float
        /// Reading along: the framing the hold glides to, and when the glide
        /// sets off (a moment after landing, once the eye has found the start
        /// of the line) and ends.
        public let sweepTo: CameraPose?
        public let sweepStart: Double
        public let sweepEnd: Double

        public var travel: Double { land - depart }
        public var hold: Double { leave - land }
    }

    public let beats: [Beat]
    public let duration: Double
    public let style: MotionStyle
    public let slideAspect: Float
    public let canvasAspect: Float
    public let ending: Ending
    private let phases: (Float, Float, Float, Float, Float, Float)

    /// The shortest hold the camera keeps between two landings (a third of the
    /// interval, up to a second, when there is room).
    public static let minimumHold = 0.12

    public init(_ input: ChoreographyInput) {
        duration = max(input.duration, 0.1)
        style = input.style
        slideAspect = input.slideAspect
        canvasAspect = input.canvasAspect
        ending = input.ending
        let seed = Int(input.seed)
        phases = (hashSigned(seed, 11) * .pi, hashSigned(seed, 12) * .pi, hashSigned(seed, 13) * .pi,
                  hashSigned(seed, 14) * .pi, hashSigned(seed, 15) * .pi, hashSigned(seed, 16) * .pi)

        let A = input.slideAspect, C = input.canvasAspect
        let arriveEnd = min(input.arrive.end, duration)

        // The overview, then the shots in time order, never before the slide has
        // arrived and never two on the same moment.
        var plan: [(shot: Shot, overview: Bool)] = []
        var overview = input.overview
        overview.time = arriveEnd
        plan.append((overview, true))
        var last = arriveEnd
        for var s in input.shots.sorted(by: { $0.time < $1.time }) {
            s.time = max(s.time, last + 0.25)
            last = s.time
            plan.append((s, false))
        }
        if input.ending == .pullBack {
            var back = input.overview
            back.id = UUID(uuidString: "00000000-0000-0000-0000-00000000B4CC")!
            // Lands with time to settle and rest on the whole slide before the end.
            back.time = max(last + 1.6, duration - 1.1)
            back.travel = nil
            back.ease = .breathe
            back.breathe = 0
            back.label = "The whole slide"
            last = back.time
            plan.append((back, true))
        }

        let poses = plan.map { CameraPose(shot: $0.shot, slideAspect: A, canvasAspect: C, safe: input.safe) }
        let sweeps: [CameraPose?] = plan.map {
            $0.shot.sweep == nil ? nil : CameraPose(sweepEndOf: $0.shot, slideAspect: A, canvasAspect: C, safe: input.safe)
        }
        /// Where a beat's hold leaves the camera, before its breath.
        let rests = poses.indices.map { sweeps[$0] ?? poses[$0] }
        let w = { (h: Float) -> Float in h * C.squareRoot() }
        let rho = input.style.rho
        let settleScale = input.style.paceScale.squareRoot()

        // Travel times first (they decide the holds, which decide the breaths).
        var departs: [Double] = []
        for (i, item) in plan.enumerated() {
            let land = item.shot.time
            if i == 0 {
                departs.append(input.arrive.kind == .none ? land : 0)
                continue
            }
            if item.shot.move == .cut {
                departs.append(land)
                continue
            }
            let prevLand = plan[i - 1].shot.time
            // Keep part of every interval still, so each detail is seen, not just passed.
            let interval = land - prevLand
            let gap = interval - max(Choreography.minimumHold, min(0.32 * interval, 1.0))
            let wanted = item.shot.travel ?? Choreography.autoTravel(from: rests[i - 1], to: poses[i], ease: item.shot.ease,
                                                                       move: item.shot.move, style: input.style, canvasAspect: C)
            let travel = gap < 0.25 ? max(land - prevLand - 0.05, 0.08) : min(max(wanted, 0.25), gap)
            departs.append(land - travel)
        }

        var built: [Beat] = []
        for (i, item) in plan.enumerated() {
            let land = item.shot.time
            let depart = departs[i]
            let leave = i + 1 < plan.count ? departs[i + 1] : duration
            let hold = max(leave - land, 0)
            let pose = poses[i]
            // Where the move starts: the previous beat at the end of its breath,
            // or for the overview the camera's opening position.
            var from: CameraPose
            if i == 0 {
                from = Arrival.cameraStart(pose, arrive: input.arrive)
            } else {
                from = rests[i - 1]
                from.height *= expf(-built[i - 1].breathe)
            }
            // Short holds keep still: a breath needs room to be a breath.
            let breathe = item.shot.breathe * 0.085 * smootherstep(Float((hold - 0.4) / 2.8))
            let curve = (i == 0 ? EaseKind.linger : item.shot.ease).curve
            let path = ZoomPath(from: from.target, w0: w(from.height), to: pose.target, w1: w(pose.height), rho: rho)
            let travel = land - depart
            // The landing keeps its momentum: the move aims short by δ and the hold
            // takes in the rest along (1 − x/H)^n, which starts at the move's own
            // landing speed when δ/(1 − δ) = e′(1)·s/T with s = H/n, and slows
            // steadily to rest as the hold ends. n ≥ 2.5 keeps that ending smooth.
            var overrun: Float = 0
            var tail: Float = 3
            if travel > 1e-3 && hold > 1e-3 {
                let slope = Double(max(curve.landingSpeed, 1e-4))
                let s = min(item.shot.ease.settle * settleScale, hold / 2.5, 0.25 * travel / slope)
                let k = slope * s / travel
                overrun = Float(k / (1 + k))
                tail = Float(hold / s)
            }
            let dx = pose.target.x - from.target.x
            // The glide along a line keeps clear of the move out.
            let glide = hold > 0.5 ? sweeps[i] : nil
            let sweepEnd = max(land + min(Self.readLead + (item.shot.sweepTime ?? hold * 0.82), hold - 0.2), land + 0.3)
            let sweepStart = land + min(Self.readLead, (sweepEnd - land) * 0.25)
            built.append(Beat(shot: item.shot, isOverview: item.overview, pose: pose, depart: depart, land: land, leave: leave,
                              from: from, path: path, curve: curve, overrun: overrun, tail: tail,
                              breathe: breathe, arcSign: dx >= 0 ? 1 : -1, sweepTo: glide,
                              sweepStart: sweepStart, sweepEnd: sweepEnd))
        }
        beats = built
    }

    // MARK: Timing

    /// The fastest the view may change at its peak, in e-folds of scale per
    /// second (OpenScreen caps its zooms near 2.8; past that a move reads as a lurch).
    public static let peakRate = 2.6

    /// The fastest the camera may turn at its peak, in degrees per second:
    /// past it a turn reads as a whip, however slowly the view itself moves.
    public static let peakTurn = 40.0

    /// A move's natural length in seconds: longer for distant or steeply turned
    /// framings, never so short that the ease's peak outruns `peakRate` or
    /// `peakTurn`, and scaled by the style's pace.
    public static func autoTravel(from a: CameraPose, to b: CameraPose, ease: EaseKind = .glide, move: MoveKind = .glide,
                                  style: MotionStyle, canvasAspect: Float) -> Double {
        let w = canvasAspect.squareRoot()
        let path = ZoomPath(from: a.target, w0: a.height * w, to: b.target, w1: b.height * w, rho: style.rho)
        let turn = max(abs(b.yaw - a.yaw), abs(b.pitch - a.pitch), abs(b.roll - a.roll))
        let raw = 0.62 + 0.34 * abs(path.length) + 0.55 * Double(turn / radians(30))
        let shortest = shortestTravel(from: a, to: b, ease: ease, move: move, style: style, canvasAspect: canvasAspect)
        return min(max(max(raw * style.paceScale, shortest), 0.45), 4.0)
    }

    /// The shortest a move can take without its peak outrunning `peakRate`
    /// or `peakTurn`, whatever the style's pace.
    public static func shortestTravel(from a: CameraPose, to b: CameraPose, ease: EaseKind = .glide, move: MoveKind = .glide,
                                      style: MotionStyle, canvasAspect: Float) -> Double {
        guard move != .cut else { return 0 }
        let slope = Double(ease.curve.peakSlope)
        let zoom = span(from: a, to: b, move: move, rho: style.rho, canvasAspect: canvasAspect) * slope
        var turn = Double(max(abs(b.yaw - a.yaw), abs(b.pitch - a.pitch), abs(b.roll - a.roll))) * slope
        // An arc swings out and back on top of the turn, fastest a sixth of the way in.
        if move == .arc { turn += Double(radians(9) * (0.5 + style.flight)) * 3.75 }
        return max(zoom / peakRate, turn / Double(radians(Float(peakTurn))))
    }

    /// How much of the view a move changes, in e-folds: along the flight's
    /// path, or for a push straight across and in.
    static func span(from a: CameraPose, to b: CameraPose, move: MoveKind, rho: Float, canvasAspect: Float) -> Double {
        if move == .push {
            let h = Double(max(min(a.height, b.height), 1e-4))
            return max(Double((b.target - a.target).length) / h, Double(abs(logf(max(b.height, 1e-4) / max(a.height, 1e-4)))))
        }
        let w = canvasAspect.squareRoot()
        let path = ZoomPath(from: a.target, w0: a.height * w, to: b.target, w1: b.height * w, rho: rho)
        return Double(rho) * abs(path.length)
    }

    /// Index of the beat governing time `t`: the last one whose move has begun.
    public func beatIndex(at t: Double) -> Int {
        guard !beats.isEmpty else { return 0 }
        var lo = 0, hi = beats.count - 1
        if t < beats[0].depart { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if beats[mid].depart <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The moments the camera lands, for the transport and snapping.
    public var landings: [Double] { beats.map(\.land) }

    /// The time of a cut inside (a, b], if there is one: motion blur must not span it.
    public func cut(between a: Double, and b: Double) -> Double? {
        let lo = min(a, b), hi = max(a, b)
        for beat in beats where beat.shot.move == .cut && !beat.isOverview && beat.land > lo && beat.land <= hi {
            return beat.land
        }
        return nil
    }

    // MARK: Poses

    /// The camera at time `t`.
    public func pose(at t: Double) -> CameraPose {
        var p = basePose(at: t)
        // Swing: the camera leans against its own travel across the frame, as if
        // it had weight; a cut has no travel to lean on.
        if style.swing > 0.001 {
            let h = 1.0 / 120
            let a = basePose(at: t - h), b = basePose(at: t + h)
            if cut(between: t - h, and: t + h) == nil {
                let v = (b.target - a.target) / Float(2 * h) / max(p.height, 1e-4)
                p.yaw -= style.swing * radians(3.2) * tanhf(v.x / 0.9)
                p.pitch -= style.swing * radians(2.4) * tanhf(v.y / 0.9)
                p.roll += style.swing * radians(0.6) * tanhf(v.x / 1.2)
            }
        }
        // Drift: three slow, unrelated waves, never a shake.
        if style.drift > 0.001 {
            let k = style.drift
            let tt = Float(t) * 2 * .pi
            let ph = phases
            p.target.x += p.height * k * 0.0042 * (sinf(0.071 * tt + ph.0) + 0.55 * sinf(0.173 * tt + ph.1))
            p.target.y += p.height * k * 0.0036 * (sinf(0.093 * tt + ph.2) + 0.5 * sinf(0.151 * tt + ph.3))
            p.yaw += k * radians(0.55) * sinf(0.061 * tt + ph.4)
            p.pitch += k * radians(0.4) * sinf(0.083 * tt + ph.5)
            p.roll += k * radians(0.12) * sinf(0.047 * tt + ph.1)
        }
        return p
    }

    /// The camera at `t` without swing or drift.
    public func basePose(at t: Double) -> CameraPose {
        guard !beats.isEmpty else { return CameraPose(target: .zero, height: 1) }
        let i = beatIndex(at: t)
        let beat = beats[i]
        if t < beat.land {
            // Travelling.
            let span = max(beat.land - beat.depart, 1e-6)
            let u = Float(max(t - beat.depart, 0) / span)
            let progress = (1 - beat.overrun) * beat.curve.value(u)
            return interpolate(beat, progress, time: u)
        }
        // Holding: take in the last of the move, and breathe.
        let x = t - beat.land
        let hold = max(beat.leave - beat.land, 1e-6)
        let left = Float(max(1 - x / hold, 0))
        let rest = beat.overrun > 0 ? beat.overrun * powf(left, beat.tail) : 0
        var p = interpolate(beat, 1 - rest, time: 1)
        if let to = beat.sweepTo {
            let e = Curves.along(Float((t - beat.sweepStart) / max(beat.sweepEnd - beat.sweepStart, 1e-3)))
            p.target += (to.target - beat.pose.target) * e
            p.height *= powf(to.height / max(beat.pose.height, 1e-5), e)
            p.yaw = lerp(p.yaw, to.yaw, e)
            p.pitch = lerp(p.pitch, to.pitch, e)
        }
        if beat.breathe > 0 {
            p.height *= expf(-beat.breathe * smootherstep(Float(x / hold)))
        }
        return p
    }

    /// The pose `progress` of the way along the beat's move, `time` (0…1) of
    /// the way through its travel.
    private func interpolate(_ beat: Beat, _ progress: Float, time u: Float) -> CameraPose {
        let a = beat.from, b = beat.pose
        let p = clamp01(progress)
        var out = CameraPose(target: b.target, height: b.height,
                             yaw: lerp(a.yaw, b.yaw, p), pitch: lerp(a.pitch, b.pitch, p), roll: lerp(a.roll, b.roll, p),
                             fov: lerp(a.fov, b.fov, p), aperture: lerp(a.aperture, b.aperture, p))
        switch beat.shot.move {
        case .push:
            out.target = lerp(a.target, b.target, p)
            out.height = expf(lerp(logf(a.height), logf(b.height), p))
        case .glide, .arc:
            let v = beat.path.at(p)
            out.target = v.center
            out.height = v.w / canvasAspect.squareRoot()
            if beat.shot.move == .arc {
                // The swing follows the clock, not the eased progress: an ease that
                // covers most of the ground early would whip it out and back.
                let bump = Curves.bump(powf(clamp01(u), 0.75))
                out.yaw += beat.arcSign * radians(9) * (0.5 + style.flight) * bump
                out.pitch += radians(3.5) * bump
            }
        case .cut:
            out.target = b.target
            out.height = b.height
            out.yaw = b.yaw; out.pitch = b.pitch; out.roll = b.roll
            out.fov = b.fov; out.aperture = b.aperture
        }
        return out
    }

    // MARK: Emphasis and ending

    /// The shot whose emphasis shows at `t`, and how far it has come in (0…1).
    public func emphasis(at t: Double) -> (beat: Int, amount: Float)? {
        guard !beats.isEmpty else { return nil }
        let i = beatIndex(at: t)
        // Coming in just before a landing belongs to the beat being landed on.
        for j in [i, i + 1] where j < beats.count {
            let b = beats[j]
            guard b.shot.emphasis != .none, !b.isOverview, let (rises, falls) = emphasisSpan(j) else { continue }
            let rise = smootherstep(Float((t - rises.lowerBound) / (rises.upperBound - rises.lowerBound)))
            let fall: Float = falls.map { 1 - smootherstep(Float((t - $0.lowerBound) / ($0.upperBound - $0.lowerBound))) } ?? 1
            let amount = rise * fall
            if amount > 0.001 { return (j, amount) }
        }
        return nil
    }

    /// When beat `i`'s emphasis comes in and goes out, or nil when its hold
    /// has no room for one. It comes in as the camera lands and falls before
    /// the camera leaves, and before a Leave ending sets the slide off, so the
    /// slide goes as it is. In a short hold both are quicker, never cut short.
    func emphasisSpan(_ i: Int) -> (rise: ClosedRange<Double>, fall: ClosedRange<Double>?)? {
        let b = beats[i]
        let start = b.land - 0.15
        let end: Double? = b.leave < duration - 1e-6 ? b.leave : (ending == .leave ? duration - Self.leaveLength : nil)
        let room = (end ?? .infinity) - start
        guard room >= Self.emphasisRoom else { return nil }
        let rise = min(0.55, 0.45 * room)
        let fall = min(0.45, 0.30 * room)
        return (start...(start + rise), end.map { ($0 - fall)...$0 })
    }

    /// The shortest hold an emphasis comes in for: less, and it would be
    /// gone before it could be seen.
    public static let emphasisRoom = 0.75

    /// How settled the camera is at `t`, 0…1: 1 while it holds on a framing
    /// (reading along included), 0 while it travels, easing between the two
    /// over the first half-second of a hold and the last third of one.
    public func settled(at t: Double) -> Float {
        guard !beats.isEmpty else { return 0 }
        let b = beats[beatIndex(at: t)]
        guard t >= b.land else { return 0 }
        let rise = smootherstep(Float((t - b.land) / 0.5))
        let fall: Float = b.leave >= duration - 1e-6 ? 1 : 1 - smootherstep(Float((t - (b.leave - 0.3)) / 0.3))
        return rise * fall
    }

    /// How far the ending has come at `t` (0 before it starts, 1 at the end).
    public func endingProgress(at t: Double) -> Float {
        switch ending {
        case .hold, .pullBack: return 0
        case .fade: return smootherstep(Float((t - (duration - 1.1)) / 1.1))
        case .leave: return smootherstep(Float((t - (duration - Self.leaveLength)) / Self.leaveLength))
        }
    }

    /// The time beyond a glance that `text` takes to read: about 0.3 s a
    /// word, past the first four.
    public static func readingTime(_ text: String?) -> Double {
        let words = text?.split(whereSeparator: \.isWhitespace).count ?? 0
        return max(Double(words) * 0.30 - 1.2, 0)
    }

    /// How long a Leave ending takes, in seconds.
    public static let leaveLength = 1.6

    /// How long a read-along rests on the start of its line before gliding.
    public static let readLead = 0.4

    /// A natural length for a video with these shots and no voiceover.
    public static func naturalDuration(shots: [Shot], arrive: Arrive, ending: Ending) -> Double {
        let last = max(shots.map(\.time).max() ?? arrive.end, arrive.end)
        // A shot that reads along a line holds for its glide; one with more
        // to read than a glance holds for that.
        let lastShot = shots.max { $0.time < $1.time }
        let glide = lastShot?.sweep == nil ? 0 : max(readLead + (lastShot?.sweepTime ?? 1.6) - 1.2, 0)
        let reading = lastShot?.sweep == nil ? min(readingTime(lastShot?.cue), 2.4) : 0
        var d = last + (shots.isEmpty ? 2.6 : 2.4) + glide + reading
        switch ending {
        // The pull-back's flight comes out of this, so the last shot still holds.
        case .pullBack: d += 3.4
        case .fade: d += 0.6
        case .leave: d += 1.0
        case .hold: break
        }
        return d
    }
}
