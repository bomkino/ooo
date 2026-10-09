import Foundation

/// Everything the camera's path depends on.
public struct ChoreographyInput: Sendable {
    public var overview: Shot
    public var shots: [Shot]
    public var arrive: Arrive
    public var ending: Ending
    public var duration: Double
    /// The first slide's width / height.
    public var slideAspect: Float
    public var canvasAspect: Float
    public var style: MotionStyle
    public var seed: UInt32
    /// The part of the canvas framings sit in.
    public var safe: SafeArea
    /// The slides after the first, in order, and how and when the card
    /// changes to each. A shot frames the slide its `page` names.
    public var pages: [PageTiming]
    /// Turning back to the first slide before the end; nil stays on the last.
    public var home: HomeTiming?
    /// Where the stage rises to leave room below; nil for never.
    public var lift: Lift?
    /// The share of the frame an opening title needs above the slide while
    /// the stage is up (0 without one).
    public var titleRoom: Float
    /// A path drawn during a live take, whose holds last until someone asks
    /// for the next move: nothing in a hold depends on how long it lasts
    /// (see `LiveTake`).
    public var live = false

    public init(overview: Shot, shots: [Shot], arrive: Arrive, ending: Ending, duration: Double,
                slideAspect: Float, canvasAspect: Float, style: MotionStyle, seed: UInt32 = 1, safe: SafeArea = .none,
                pages: [PageTiming] = [], home: HomeTiming? = nil, lift: Lift? = nil, titleRoom: Float = 0) {
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
        self.pages = pages
        self.home = home
        self.lift = lift
        self.titleRoom = titleRoom
    }

    /// Every slide's width / height, the first first.
    public var aspects: [Float] { [slideAspect] + pages.map(\.aspect) }

    /// Which slide `shot` frames (0 is the first); a slide no longer in the
    /// video counts as the first.
    public func page(of shot: Shot) -> Int {
        guard let id = shot.page, let k = pages.firstIndex(where: { $0.id == id }) else { return 0 }
        return k + 1
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
///
/// Over several slides, the card changes from one to the next. Before it
/// turns over, the camera comes back to rest on the whole slide, and while it
/// turns it eases to the whole of the next. Before it melts, the camera rests
/// on its last shot, and as the melt starts it cuts, unseen, to the first
/// shot on the next slide, which looks from the same angle, while the old
/// slide is kept exactly where the eye had it (see `meltHandoff`). With a
/// Lift, every beat is framed twice, for the whole canvas and for the part
/// left above the room, and the camera eases from one path to the other as
/// the stage rises and settles.
public struct Choreography: Sendable {
    /// What a beat is for.
    public enum Role: Sendable {
        /// The whole first slide, as it arrives.
        case opening
        case shot
        /// Back to the whole slide before the card turns over.
        case whole
        /// The whole of the next slide, while the card turns over to it.
        case turned
        /// The whole first slide again, while the card turns back to it.
        case home
        /// The whole slide again at the end.
        case pullBack
    }

    public struct Beat: Sendable {
        public let shot: Shot
        public let isOverview: Bool
        public let role: Role
        /// The slide this beat frames (0 is the first).
        public let page: Int
        /// The camera cuts here unseen as the card melts to this slide.
        public let melts: Bool
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
        /// The travel this move would take with all the room it wants.
        public let wanted: Double
        /// How long the hold takes to bleed away the last of the move: the
        /// whole hold, or less where the card changes soon after landing.
        let settling: Double

        public var travel: Double { land - depart }
        public var hold: Double { leave - land }
    }

    public let beats: [Beat]
    /// The same beats framed in the part of the canvas above a Lift's room
    /// (same times, same moves); nil without a Lift.
    public let lifted: [Beat]?
    public let lift: Lift?
    /// The card changing from slide to slide, in time order.
    public let changes: [SlideChange]
    /// Every slide's width / height, the first first.
    public let aspects: [Float]
    /// Which way the card turns (see `turnDirection`).
    public let turnSign: Float
    public let duration: Double
    public let style: MotionStyle
    public let slideAspect: Float
    public let canvasAspect: Float
    public let ending: Ending
    /// Drawn during a live take (see `ChoreographyInput.live`).
    public let live: Bool
    private let phases: (Float, Float, Float, Float, Float, Float)

    /// The shortest hold the camera keeps between two landings (a third of the
    /// interval, up to a second, when there is room).
    public static let minimumHold = 0.12
    /// After a turn, the card settles a moment before the camera sets off.
    public static let turnSettle = 0.3
    /// The camera lands on the whole slide this long before it turns.
    public static let backLead = 0.4
    /// How long a slide with no shots of its own rests before it turns over,
    /// at the least, and how long the first rests after the card has turned
    /// back, before the ending.
    public static let coverRest = 1.6
    /// How long the camera takes, about, to fly back to the whole slide.
    public static let flightBack = 1.5
    static let pullBackID = UUID(uuidString: "00000000-0000-0000-0000-00000000B4CC")!

    /// The card's turns over, in time order.
    public var turns: [SlideChange] { changes.filter { $0.kind == .turn } }

    public init(_ input: ChoreographyInput) {
        duration = max(input.duration, 0.1)
        style = input.style
        slideAspect = input.slideAspect
        canvasAspect = input.canvasAspect
        ending = input.ending
        live = input.live
        aspects = input.aspects
        turnSign = turnDirection(overviewYaw: input.overview.yaw)
        let seed = Int(input.seed)
        phases = (hashSigned(seed, 11) * .pi, hashSigned(seed, 12) * .pi, hashSigned(seed, 13) * .pi,
                  hashSigned(seed, 14) * .pi, hashSigned(seed, 15) * .pi, hashSigned(seed, 16) * .pi)

        let C = input.canvasAspect
        let aspects = input.aspects
        let (plan, changes) = Self.layout(input, duration: duration)
        self.changes = changes

        let poses = plan.map { CameraPose(shot: $0.shot, slideAspect: aspects[$0.page], canvasAspect: C, safe: input.safe) }
        let sweeps: [CameraPose?] = plan.map {
            $0.shot.sweep == nil ? nil : CameraPose(sweepEndOf: $0.shot, slideAspect: aspects[$0.page], canvasAspect: C, safe: input.safe)
        }
        /// Where a beat's hold leaves the camera, before its breath.
        let rests = poses.indices.map { sweeps[$0] ?? poses[$0] }

        // Travel times first (they decide the holds, which decide the breaths).
        var departs: [Double] = []
        var wanted: [Double] = []
        for (i, item) in plan.enumerated() {
            let land = item.shot.time
            if i == 0 {
                departs.append(input.arrive.kind == .none ? land : 0)
                wanted.append(0)
                continue
            }
            if let from = item.turnFrom {
                // Reframes for the next slide while the card turns over to it.
                departs.append(min(from, land))
                wanted.append(0)
                continue
            }
            if item.shot.move == .cut {
                departs.append(land)
                wanted.append(0)
                continue
            }
            let prevLand = plan[i - 1].shot.time
            // Keep part of every interval still, so each detail is seen, not just passed.
            let interval = land - prevLand
            let gap = interval - max(Choreography.minimumHold, min(0.32 * interval, 1.0))
            let want = item.shot.travel ?? Choreography.autoTravel(from: rests[i - 1], to: poses[i], ease: item.shot.ease,
                                                                     move: item.shot.move, style: input.style, canvasAspect: C)
            let travel = gap < 0.25 ? max(land - prevLand - 0.05, 0.08) : min(max(want, 0.25), gap)
            var depart = land - travel
            // Nothing sets off while the card is still changing, and the first
            // move after it takes the time it wants (the card's own settle is the hold).
            if let settled = item.notBefore { depart = min(max(land - max(want, 0.25), settled), land - 0.08) }
            departs.append(depart)
            wanted.append(want)
        }

        beats = Self.build(plan, poses: poses, sweeps: sweeps, departs: departs, wanted: wanted, changes: changes,
                           input: input, duration: duration)

        if let lift = input.lift, !lift.isEmpty {
            // The same tour, framed above the room.
            let up = lift.safe(input.safe)
            var opening = up
            opening.top = min(up.top + input.titleRoom, 1 - up.bottom - 0.25)
            let safe = { (i: Int) -> SafeArea in plan[i].overview ? opening : up }
            let liftedPoses = plan.indices.map {
                CameraPose(shot: plan[$0].shot, slideAspect: aspects[plan[$0].page], canvasAspect: C, safe: safe($0))
            }
            let liftedSweeps: [CameraPose?] = plan.indices.map {
                plan[$0].shot.sweep == nil ? nil
                    : CameraPose(sweepEndOf: plan[$0].shot, slideAspect: aspects[plan[$0].page], canvasAspect: C, safe: safe($0))
            }
            lifted = Self.build(plan, poses: liftedPoses, sweeps: liftedSweeps, departs: departs, wanted: wanted, changes: changes,
                                input: input, duration: duration)
            self.lift = lift
        } else {
            lifted = nil
            self.lift = nil
        }
    }

    /// One beat of the plan, before its move is timed.
    struct Item {
        var shot: Shot
        var overview: Bool
        var role: Role
        var page: Int
        var melts = false
        /// Departs as the card starts to turn, landing as it lands.
        var turnFrom: Double?
        /// Sets off no earlier than this: the card has settled after a change.
        var notBefore: Double?
    }

    /// The beats in time order and the card's changes between them. Every
    /// slide's shots come in turn, never before the slide has arrived (or
    /// the card has changed to it) and never two on the same moment; each
    /// change waits for the slide before it to be seen. Without a `duration`
    /// it stops there (for the natural length); with one it adds the turn
    /// back to the first slide, or the pull back to the whole slide.
    static func layout(_ input: ChoreographyInput, duration: Double?) -> (items: [Item], changes: [SlideChange]) {
        let aspects = input.aspects, C = input.canvasAspect
        let n = aspects.count
        let arriveEnd = duration.map { min(input.arrive.end, $0) } ?? input.arrive.end
        var byPage = Array(repeating: [Shot](), count: n)
        for s in input.shots.sorted(by: { $0.time < $1.time }) { byPage[input.page(of: s)].append(s) }
        func overview(_ k: Int) -> Shot {
            Shot.overview(like: input.overview, baseAspect: aspects[0], slideAspect: aspects[k], canvasAspect: C)
        }
        func pose(_ s: Shot, _ k: Int) -> CameraPose { CameraPose(shot: s, slideAspect: aspects[k], canvasAspect: C, safe: input.safe) }
        func rest(_ item: Item) -> CameraPose {
            item.shot.sweep == nil ? pose(item.shot, item.page)
                : CameraPose(sweepEndOf: item.shot, slideAspect: aspects[item.page], canvasAspect: C, safe: input.safe)
        }

        var items: [Item] = []
        var changes: [SlideChange] = []
        var opening = overview(0)
        opening.time = arriveEnd
        items.append(Item(shot: opening, overview: true, role: .opening, page: 0))
        var last = arriveEnd
        // When the card has settled after its last change.
        var settled = arriveEnd

        func place(_ list: [Shot], page k: Int, afterChange: Bool) {
            for (j, var s) in list.enumerated() {
                s.time = max(s.time, last + 0.25)
                var item = Item(shot: s, overview: false, role: .shot, page: k)
                if j == 0 && afterChange {
                    // The first move sets off once the card has settled, and takes the time it wants.
                    if s.move != .cut {
                        let want = s.travel ?? autoTravel(from: rest(items[items.count - 1]), to: pose(s, k), ease: s.ease,
                                                          move: s.move, style: input.style, canvasAspect: C)
                        s.time = max(s.time, settled + max(want, 0.6))
                    } else {
                        s.time = max(s.time, settled + 0.3)
                    }
                    item.shot = s
                    item.notBefore = settled
                }
                last = s.time
                items.append(item)
            }
        }

        place(byPage[0], page: 0, afterChange: false)
        for k in 1..<max(n, 1) {
            let next = input.pages[k - 1]
            var list = byPage[k]
            let previous = items[items.count - 1]
            let onShot = !previous.overview
            let from = max(last, settled)
            // A slide with no shots of its own rests a moment before it changes;
            // a last shot holds for what it has to say.
            let seen = onShot ? holdBeforeChange(previous.shot) : max(coverRest - (from - previous.shot.time), 0.3)
            let start: Double
            switch next.change {
            case .turn:
                // The flight back to the whole slide takes the time it wants.
                let flight = onShot ? autoTravel(from: rest(previous), to: pose(overview(k - 1), k - 1), ease: .breathe,
                                                 style: input.style, canvasAspect: C) : 0
                let least = from + (onShot ? room(forTravel: flight) + backLead : 0.3)
                let natural = from + seen + (onShot ? flight + backLead : 0)
                // Turning as late as the next slide's first shot allows, so the
                // last one here holds while it is still being talked about.
                let ideal = list.first.map { s -> Double in
                    let want = s.travel ?? autoTravel(from: pose(overview(k), k), to: pose(s, k), ease: s.ease, move: s.move,
                                                      style: input.style, canvasAspect: C)
                    return s.time - (next.change.length + turnSettle + max(want, 0.6))
                }
                start = next.at.map { max($0, least) } ?? max(natural, ideal ?? natural)
                if onShot {
                    var whole = overview(k - 1)
                    whole.id = Self.generatedID(1, k - 1)
                    whole.time = start - backLead
                    whole.travel = nil
                    whole.ease = .breathe
                    whole.breathe = 0
                    whole.label = "The whole slide"
                    items.append(Item(shot: whole, overview: true, role: .whole, page: k - 1))
                }
                changes.append(SlideChange(start: start, kind: .turn, from: k - 1, to: k))
                var turned = overview(k)
                turned.id = Self.generatedID(2, k)
                turned.time = start + next.change.length
                turned.move = .push
                turned.ease = .glide
                turned.travel = nil
                turned.label = "Slide \(k + 1)"
                items.append(Item(shot: turned, overview: true, role: .turned, page: k, turnFrom: start))
                last = turned.time
                settled = start + next.change.length + turnSettle
            case .melt:
                let least = from + 0.6
                let natural = from + max(seen, 0.6)
                // The next slide's first shot lands as the melt starts.
                start = next.at.map { max($0, least) } ?? max(natural, list.first?.time ?? natural)
                changes.append(SlideChange(start: start, kind: .melt, from: k - 1, to: k))
                var first: Shot
                var whole = false
                if list.isEmpty {
                    first = overview(k)
                    first.id = Self.generatedID(3, k)
                    first.label = "Slide \(k + 1)"
                    whole = true
                } else {
                    first = list.removeFirst()
                }
                first.time = start
                first.move = .cut
                first.travel = nil
                items.append(Item(shot: first, overview: whole, role: whole ? .turned : .shot, page: k, melts: true))
                last = start
                settled = start + next.change.length
            }
            place(list, page: k, afterChange: true)
        }

        guard let duration else { return (items, changes) }
        let current = items[items.count - 1]
        let onShot = !current.overview
        if let home = input.home, n > 1 {
            // Back to the whole slide, settled, before it turns back to the first.
            let auto = duration - (backLead + PageChange.turn.length + coverRest + endingTail(input.ending))
            var land = max(last + (onShot ? 1.6 : 0.25), home.at.map { $0 - backLead } ?? auto)
            land = max(min(land, duration - backLead - PageChange.turn.length - 0.2), last + 0.25)
            var start = land + backLead
            if onShot {
                var whole = overview(current.page)
                whole.id = Self.generatedID(1, current.page)
                whole.time = land
                whole.travel = nil
                whole.ease = .breathe
                whole.breathe = 0
                whole.label = "The whole slide"
                whole.page = nil
                items.append(Item(shot: whole, overview: true, role: .whole, page: current.page))
            } else {
                start = max(start, last + 0.3)
            }
            changes.append(SlideChange(start: start, kind: .turn, from: n - 1, to: 0, back: true))
            var first = overview(0)
            first.id = Self.generatedID(4, 0)
            first.time = start + PageChange.turn.length
            first.move = .push
            first.ease = .glide
            first.travel = nil
            first.label = "Back to the first slide"
            items.append(Item(shot: first, overview: true, role: .home, page: 0, turnFrom: start))
        } else if input.ending == .pullBack {
            var back = overview(current.page)
            back.id = Self.pullBackID
            // Lands with time to settle and rest on the whole slide before the end.
            back.time = max(last + 1.6, duration - 1.1)
            back.travel = nil
            back.ease = .breathe
            back.breathe = 0
            back.label = "The whole slide"
            items.append(Item(shot: back, overview: true, role: .pullBack, page: current.page))
        }
        return (items, changes)
    }

    /// The least time between two landings that leaves a move of `travel`
    /// seconds all of it, with the hold every interval keeps.
    static func room(forTravel travel: Double) -> Double {
        travel <= 2.125 ? max(travel / 0.68, travel + minimumHold) : travel + 1.0
    }

    /// How long a last shot holds before the card changes: long enough to
    /// read what it frames, or to glide along its line.
    static func holdBeforeChange(_ shot: Shot) -> Double {
        let glide = shot.sweep == nil ? 0 : readLead + (shot.sweepTime ?? 1.6)
        return max(1.6 + min(readingTime(shot.cue), 2.0), glide + 0.4)
    }

    /// A fixed id for a beat the path adds itself.
    static func generatedID(_ kind: UInt8, _ k: Int) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0xC0, kind, UInt8(truncatingIfNeeded: k >> 8), UInt8(truncatingIfNeeded: k)))
    }

    /// The beats for one framing of the plan: each move from where the last
    /// rested to its pose, its landing, hold, breath and read-along.
    private static func build(_ plan: [Item], poses: [CameraPose], sweeps: [CameraPose?],
                              departs: [Double], wanted: [Double], changes: [SlideChange], input: ChoreographyInput,
                              duration: Double) -> [Beat] {
        let C = input.canvasAspect
        var rests = poses.indices.map { sweeps[$0] ?? poses[$0] }
        let w = { (h: Float) -> Float in h * C.squareRoot() }
        let rho = input.style.rho
        let settleScale = input.style.paceScale.squareRoot()
        var built: [Beat] = []
        for (i, item) in plan.enumerated() {
            let land = item.shot.time
            let depart = departs[i]
            let leave = i + 1 < plan.count ? departs[i + 1] : duration
            let hold = max(leave - land, 0)
            // The camera is still before the card changes: the last of the move
            // is taken in by the time the change starts. Live, a hold's length
            // isn't known while it holds, so it settles as if it had all the time.
            var settling = input.live ? Self.openHold : hold
            if !input.live, let change = changes.first(where: { $0.start >= land - 1e-9 && $0.start < leave }) {
                settling = min(hold, max(change.start - land, 0.6))
            }
            var pose = poses[i]
            if item.melts, i > 0 {
                // The cut under a melt keeps the angle, lens and depth the camera
                // had come to rest with, so the old slide can be kept exactly
                // where the eye had it.
                let before = built[i - 1]
                let end = before.sweepTo ?? before.pose
                pose.yaw = end.yaw
                pose.pitch = end.pitch
                pose.roll = before.pose.roll
                pose.fov = before.pose.fov
                pose.aperture = before.pose.aperture
                if sweeps[i] == nil { rests[i] = pose }
            }
            // Where the move starts: the previous beat at the end of its breath,
            // or for the overview the camera's opening position.
            var from: CameraPose
            if i == 0 {
                from = Arrival.cameraStart(pose, arrive: input.arrive)
            } else if input.live {
                // Wherever the hold has the camera as it sets off.
                from = Self.held(built[i - 1], at: depart, canvasAspect: C, flight: input.style.flight)
            } else {
                from = rests[i - 1]
                from.height *= expf(-built[i - 1].breathe)
            }
            // Short holds keep still: a breath needs room to be a breath. Live,
            // nobody knows yet how long a hold will be, so none breathes.
            let breathe = input.live ? 0 : item.shot.breathe * 0.085 * smootherstep(Float((hold - 0.4) / 2.8))
            let curve = (i == 0 ? EaseKind.linger : item.shot.ease).curve
            let path = ZoomPath(from: from.target, w0: w(from.height), to: pose.target, w1: w(pose.height), rho: rho)
            let travel = land - depart
            // The landing keeps its momentum: the move aims short by δ and the hold
            // takes in the rest along (1 − x/H)^n, which starts at the move's own
            // landing speed when δ/(1 − δ) = e′(1)·s/T with s = H/n, and slows
            // steadily to rest as the hold ends. n ≥ 2.5 keeps that ending smooth.
            var overrun: Float = 0
            var tail: Float = 3
            if travel > 1e-3 && settling > 1e-3 {
                let slope = Double(max(curve.landingSpeed, 1e-4))
                let s = min(item.shot.ease.settle * settleScale, settling / 2.5, 0.25 * travel / slope)
                let k = slope * s / travel
                overrun = Float(k / (1 + k))
                tail = Float(settling / s)
            }
            let dx = pose.target.x - from.target.x
            // The glide along a line keeps clear of the move out.
            let glide = hold > 0.5 ? sweeps[i] : nil
            let sweepEnd = max(land + min(Self.readLead + (item.shot.sweepTime ?? hold * 0.82), hold - 0.2), land + 0.3)
            let sweepStart = land + min(Self.readLead, (sweepEnd - land) * 0.25)
            built.append(Beat(shot: item.shot, isOverview: item.overview, role: item.role, page: item.page, melts: item.melts,
                              pose: pose, depart: depart, land: land, leave: leave,
                              from: from, path: path, curve: curve, overrun: overrun, tail: tail,
                              breathe: breathe, arcSign: dx >= 0 ? 1 : -1, sweepTo: glide,
                              sweepStart: sweepStart, sweepEnd: sweepEnd, wanted: wanted[i], settling: settling))
        }
        return built
    }

    /// How long an ending takes at the very end of the video.
    public static func endingTail(_ ending: Ending) -> Double {
        switch ending {
        case .hold, .pullBack: return 0
        case .fade: return 1.1
        case .leave: return leaveLength
        }
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
        for beat in beats where beat.shot.move == .cut && (!beat.isOverview || beat.melts) && beat.land > lo && beat.land <= hi {
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
        // While the card turns, the camera gives it a little room.
        for turn in changes where turn.kind == .turn && turn.contains(t) {
            p.height *= 1 + CardTurn.cameraRoom(turn.progress(at: t))
        }
        return p
    }

    // MARK: Slides

    /// The change under way at `t`, and how far through it, when the card is changing.
    public func change(at t: Double) -> (change: SlideChange, progress: Float)? {
        for c in changes where c.contains(t) { return (c, c.progress(at: t)) }
        return nil
    }

    /// The slide face up at `t` (0 is the first): the one the card last
    /// changed to, once the change has started.
    public func page(at t: Double) -> Int {
        changes.last { $0.start <= t }?.to ?? 0
    }

    /// The two views either side of the unseen cut a melt starts with: the
    /// camera resting on the old slide, and the same view on the new one.
    /// Every point the first sees on the old slide, the second sees at
    /// `to.target + (p − from.target) · to.height / from.height`, so the old
    /// slide, moved and scaled that way, stays exactly where the eye had it.
    public func meltHandoff(_ melt: SlideChange) -> (from: CameraPose, to: CameraPose) {
        (basePose(at: melt.start - 1e-4), basePose(at: melt.start))
    }

    /// The camera at `t` without swing or drift: on the tour as framed for
    /// the whole canvas, or above a Lift's room as far as the stage has risen.
    public func basePose(at t: Double) -> CameraPose {
        let p = pose(in: beats, at: t)
        guard let lifted else { return p }
        let w = liftAmount(at: t)
        return w > 0 ? .blend(p, pose(in: lifted, at: t), w) : p
    }

    /// How far the stage has risen at `t`, 0…1.
    public func liftAmount(at t: Double) -> Float {
        lift?.amount(at: t, duration: duration) ?? 0
    }

    private func pose(in beats: [Beat], at t: Double) -> CameraPose {
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
        return Self.held(beat, at: t, canvasAspect: canvasAspect, flight: style.flight)
    }

    /// How long a live hold settles over (see `ChoreographyInput.live`).
    static let openHold = 1000.0

    /// The camera at `t` while `beat` holds: taking in the last of the move,
    /// reading along, breathing.
    static func held(_ beat: Beat, at t: Double, canvasAspect: Float, flight: Float) -> CameraPose {
        let x = max(t - beat.land, 0)
        let hold = max(beat.leave - beat.land, 1e-6)
        let left = Float(max(1 - x / max(beat.settling, 1e-6), 0))
        let rest = beat.overrun > 0 ? beat.overrun * powf(left, beat.tail) : 0
        var p = interpolate(beat, 1 - rest, time: 1, canvasAspect: canvasAspect, flight: flight)
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
        Self.interpolate(beat, progress, time: u, canvasAspect: canvasAspect, flight: style.flight)
    }

    private static func interpolate(_ beat: Beat, _ progress: Float, time u: Float, canvasAspect: Float, flight: Float) -> CameraPose {
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
                out.yaw += beat.arcSign * radians(9) * (0.5 + flight) * bump
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
        let i = beatIndex(at: t)
        let b = beats[i]
        guard t >= b.land else {
            // Live, the camera sets off the moment it is asked to, so the hold
            // eases out over the first moments of the move that leaves it.
            guard live, i > 0, t < beats[i - 1].leave + 0.3 else { return 0 }
            let a = beats[i - 1]
            let had = a.melts ? 1 : smootherstep(Float((a.leave - a.land) / 0.5))
            return had * (1 - smootherstep(Float((t - a.leave) / 0.3)))
        }
        // A melt's cut is unseen: the camera holds still across it.
        let rise = b.melts ? 1 : smootherstep(Float((t - b.land) / 0.5))
        let stays = live || b.leave >= duration - 1e-6 || (i + 1 < beats.count && beats[i + 1].melts)
        let fall: Float = stays ? 1 : 1 - smootherstep(Float((t - (b.leave - 0.3)) / 0.3))
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

    /// A natural length for a video with these slides and shots and no
    /// voiceover: every shot holds for what it has to say, every change has
    /// its time, and turning back, there is time for the flight back to the
    /// whole slide, the turn and a rest on the first.
    public static func naturalDuration(shots: [Shot], arrive: Arrive, ending: Ending) -> Double {
        naturalDuration(ChoreographyInput(overview: .overview(), shots: shots, arrive: arrive, ending: ending, duration: 0,
                                          slideAspect: 16.0 / 9.0, canvasAspect: 16.0 / 9.0, style: MotionStyle()))
    }

    public static func naturalDuration(_ input: ChoreographyInput) -> Double {
        let (items, _) = layout(input, duration: nil)
        let lastItem = items.last
        let last = max(lastItem?.shot.time ?? input.arrive.end, input.arrive.end)
        // A shot that reads along a line holds for its glide; one with more
        // to read than a glance holds for that.
        let lastShot = lastItem.flatMap { $0.overview ? nil : $0.shot }
        let glide = lastShot?.sweep == nil ? 0 : max(readLead + (lastShot?.sweepTime ?? 1.6) - 1.2, 0)
        let reading = lastShot != nil && lastShot?.sweep == nil ? min(readingTime(lastShot?.cue), 2.4) : 0
        var d = last + (lastShot == nil ? 2.6 : 2.4) + glide + reading
        if let home = input.home, !input.pages.isEmpty {
            let tail = backLead + PageChange.turn.length + coverRest + endingTail(input.ending)
            d += (lastShot == nil ? 0.4 : 2.3) + tail
            if let at = home.at { d = max(d, at + PageChange.turn.length + coverRest + endingTail(input.ending)) }
            return d
        }
        switch input.ending {
        // The pull-back's flight comes out of this, so the last shot still holds.
        case .pullBack: d += 3.4
        case .fade: d += 0.6
        case .leave: d += 1.0
        case .hold: break
        }
        return d
    }
}
