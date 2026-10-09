import Foundation

/// A live take: you lead the camera over the slides while you talk, and the
/// take becomes the tour, timed to you.
///
/// The tour as it stands is the route. Each press sends the camera to the
/// next stop (or back, or out to the whole slide, or to a detail you click),
/// and the move sets off the moment you press. The camera then holds there,
/// alive with its drift, for as long as you talk. A press it can't take yet
/// (the camera still on its way, or an emphasis still lit) waits until it
/// can; a second press before then changes where it goes. At the last stop
/// on a slide, the next press turns or melts the card to the next slide.
///
/// The path drawn while you talk holds still between moves, since nobody
/// knows yet how long you will stay. When the take ends, every hold gets its
/// slow push-in and its read-along glide back, and the moves keep exactly the
/// moments you set them off.
public struct LiveTake: Sendable {
    public enum Step: Sendable {
        case next
        case back
        /// Out to the whole slide face up.
        case whole
    }

    /// The route: the stops, slide by slide, in the order the camera visits them.
    public let script: [Shot]
    /// The path as it was set up before the take.
    public let base: ChoreographyInput
    /// Where the camera has been sent, in order: copies of the stops, each
    /// landing when its move, set off when you asked, arrives.
    public private(set) var visits: [Shot] = []
    /// When the card started to change to each slide you have gone on to.
    public private(set) var changes: [Double] = []
    /// The stop in `script` the camera was last sent to; −1 before the first.
    public private(set) var cursor = -1
    /// The path so far, to `horizon`.
    public private(set) var choreography: Choreography
    /// How far ahead the path is drawn; it moves on as the take goes on.
    public private(set) var horizon: Double
    /// When each move set off (a visit's id, or a slide change's), for checking.
    public private(set) var departures: [(id: UUID?, at: Double)] = []

    /// What each stop's hold does once its length is known.
    private var holds: [UUID: (breathe: Float, sweepTime: Double?)] = [:]
    /// The last visit, while its move has not set off: a press before then changes it.
    private var waiting: (id: UUID, depart: Double)?

    /// How far past the present the path is drawn.
    public static let ahead: Double = 600
    /// How long the read-along glide takes in a live hold.
    public static let liveSweep: Double = 1.6
    /// How long an emphasis takes to fade before the camera leaves.
    public static let emphasisFade: Double = 0.45

    /// The slide face up (0 is the first).
    public var page: Int { changes.count }
    /// How many slides the take can go through.
    public var slideCount: Int { 1 + base.pages.count }

    public init(_ input: ChoreographyInput) {
        base = input
        script = input.shots.enumerated().sorted {
            (input.page(of: $0.element), $0.element.time, $0.offset) < (input.page(of: $1.element), $1.element.time, $1.offset)
        }.map(\.element)
        horizon = Self.ahead
        choreography = Choreography(Self.input(base, visits: [], changes: [], horizon: Self.ahead))
    }

    /// The path's input with these visits and changes, drawn to `horizon`:
    /// only the slides gone on to, no turn back, nothing at the end.
    static func input(_ base: ChoreographyInput, visits: [Shot], changes: [Double], horizon: Double) -> ChoreographyInput {
        var i = base
        i.shots = visits
        i.pages = Array(base.pages.prefix(changes.count)).enumerated().map { k, p in
            var p = p
            p.at = changes[k]
            return p
        }
        i.home = nil
        i.ending = .hold
        i.duration = horizon
        i.live = true
        return i
    }

    private func input(visits: [Shot], changes: [Double]) -> ChoreographyInput {
        Self.input(base, visits: visits, changes: changes, horizon: horizon)
    }

    /// The page id shots on slide `k` carry.
    private func pageID(_ k: Int) -> UUID? { k > 0 && k <= base.pages.count ? base.pages[k - 1].id : nil }

    // MARK: Asking

    /// Goes to the next stop, back to the one before, or out to the whole
    /// slide, setting off at `now` or as soon as the camera can. False when
    /// there is nowhere to go.
    @discardableResult
    public mutating func step(_ step: Step, at now: Double) -> Bool {
        switch step {
        case .next:
            let j = cursor + 1
            if j < script.count, base.page(of: script[j]) == page {
                return send(script[j], stop: j, at: now)
            }
            if page + 1 < slideCount { return change(at: now) }
            return whole(at: now)
        case .back:
            let first = script.firstIndex { base.page(of: $0) == page } ?? script.count
            if cursor > first, cursor - 1 < script.count, base.page(of: script[cursor - 1]) == page {
                return send(script[cursor - 1], stop: cursor - 1, at: now)
            }
            guard whole(at: now) else { return false }
            cursor = first - 1
            return true
        case .whole:
            return whole(at: now)
        }
    }

    /// Goes to `target`, a framing on the slide face up (a stop you clicked,
    /// or a detail); `stop` is its place in the route, if it has one, so the
    /// next stop follows on from it.
    @discardableResult
    public mutating func look(_ target: Shot, stop: Int? = nil, at now: Double) -> Bool {
        guard base.page(of: target) == page else { return false }
        return send(target, stop: stop, at: now)
    }

    /// Keeps the path drawn well ahead of `now`. True when it moved on.
    @discardableResult
    public mutating func keepUp(at now: Double) -> Bool {
        guard now > horizon - Self.ahead / 4 else { return false }
        horizon = now + Self.ahead
        choreography = Choreography(input(visits: visits, changes: changes))
        return true
    }

    private mutating func whole(at now: Double) -> Bool {
        let k = page
        var target = Shot.overview(like: base.overview, baseAspect: base.slideAspect, slideAspect: base.aspects[k],
                                   canvasAspect: base.canvasAspect)
        target.label = "The whole slide"
        target.page = pageID(k)
        // Already there, or on the way.
        if let last = choreography.beats.last, last.isOverview || !last.shot.framesDifferently(from: target) { return false }
        return send(target, stop: nil, at: now)
    }

    /// Sends the camera to a copy of `stop` on the slide face up.
    private mutating func send(_ stop: Shot, stop index: Int?, at now: Double) -> Bool {
        var d = now
        // A press before the last move set off changes where it goes.
        if let w = waiting, w.depart > now + 1e-6 {
            visits.removeAll { $0.id == w.id }
            holds[w.id] = nil
            departures.removeAll { $0.id == w.id }
            d = max(d, w.depart)
            choreography = Choreography(input(visits: visits, changes: changes))
        }
        waiting = nil
        if let last = choreography.beats.last { d = max(d, Self.readyToLeave(last, at: now)) }

        var v = stop
        v.id = UUID()
        v.page = pageID(page)
        holds[v.id] = (v.breathe, v.sweepTime)
        // While you talk nobody knows how long a hold will be, so it holds
        // still; a read-along glides at its own pace.
        v.breathe = 0
        if v.sweep != nil { v.sweepTime = v.sweepTime ?? Self.liveSweep }
        v.time = d + 1
        var built = choreography
        for _ in 0..<16 {
            built = Choreography(input(visits: visits + [v], changes: changes))
            guard let i = built.beats.firstIndex(where: { $0.shot.id == v.id }) else { break }
            let b = built.beats[i]
            let previous = i > 0 ? built.beats[i - 1] : nil
            if let previous, v.move != .cut {
                // Every interval keeps a still share before the move sets off.
                let w = max(b.wanted, 0.25)
                d = max(d, previous.land + Choreography.room(forTravel: w) - w)
            }
            let error = d - b.depart
            if abs(error) < 1e-4 { break }
            v.time = max(b.land + error, (previous?.land ?? 0) + 0.3)
        }
        if let b = built.beats.first(where: { $0.shot.id == v.id }) {
            v.time = b.land
            d = b.depart
        }
        visits.append(v)
        choreography = built
        departures.append((v.id, d))
        waiting = (v.id, d)
        if let index { cursor = index }
        return true
    }

    /// Turns or melts the card to the next slide, setting off at `now` or as
    /// soon as the camera can. A melt lands on the next slide's first stop.
    private mutating func change(at now: Double) -> Bool {
        let k = page + 1
        guard k < slideCount else { return false }
        waiting = nil
        var d = now
        if let last = choreography.beats.last { d = max(d, Self.readyToLeave(last, at: now)) }
        let first = cursor + 1 < script.count && base.page(of: script[cursor + 1]) == k ? cursor + 1 : nil
        var added: [Shot] = []
        if base.pages[k - 1].change == .melt, let j = first {
            // The melt cuts, unseen, to the next slide's first stop.
            var v = script[j]
            v.id = UUID()
            v.page = pageID(k)
            holds[v.id] = (v.breathe, v.sweepTime)
            v.breathe = 0
            if v.sweep != nil { v.sweepTime = v.sweepTime ?? Self.liveSweep }
            added = [v]
        }
        let n = choreography.beats.count
        var at = d
        var built = choreography
        for _ in 0..<16 {
            built = Choreography(input(visits: visits + added, changes: changes + [at]))
            guard n < built.beats.count else { break }
            let error = d - built.beats[n].depart
            if abs(error) < 1e-4 { break }
            at += error
        }
        guard let start = built.changes.first(where: { $0.to == k && !$0.back })?.start else { return false }
        changes.append(start)
        for i in added.indices {
            if let b = built.beats.first(where: { $0.shot.id == added[i].id }) { added[i].time = b.land }
        }
        visits += added
        choreography = Choreography(input(visits: visits, changes: changes))
        departures.append((added.first?.id, n < choreography.beats.count ? choreography.beats[n].depart : start))
        if added.first != nil, let j = first { cursor = j }
        return true
    }

    /// The earliest the camera can leave `beat`, asked at `now`, without
    /// anything snapping: a lit emphasis fades first, a read-along finishes.
    static func readyToLeave(_ beat: Choreography.Beat, at now: Double) -> Double {
        var t = now
        if beat.shot.emphasis != .none && !beat.isOverview {
            // Room for it to come in and go out at its own pace, whenever the press comes.
            t = max(t, now + emphasisFade, beat.land + 1.35)
        }
        if beat.sweepTo != nil { t = max(t, beat.sweepEnd + 0.2) }
        return t
    }

    // MARK: Ending

    /// The tour the take leaves, ended at `end`: every visit whose move had
    /// set off, its hold given back its push-in and glide, and when the card
    /// changed to each slide. A slide not gone on to waits until after `end`.
    public func finished(at end: Double) -> (shots: [Shot], changes: [Double?]) {
        let gone = Set(departures.filter { $0.at < end }.compactMap(\.id))
        let kept = visits.filter { gone.contains($0.id) }
        var out: [Double?] = base.pages.map(\.at)
        let turned = changes.filter { $0 < end }.count
        for k in 0..<turned { out[k] = changes[k] }
        if turned < out.count {
            // The rest come once you have finished: the first as soon as the
            // camera can go after `end`, the others each finding its own moment.
            var rest = self
            rest.visits = kept
            rest.changes = Array(changes.prefix(turned))
            rest.waiting = nil
            rest.cursor = script.count
            rest.choreography = Choreography(rest.input(visits: kept, changes: rest.changes))
            out[turned] = rest.change(at: end + 0.3) ? rest.changes.last : end + 2.2
            for k in (turned + 1)..<out.count { out[k] = nil }
        }
        let shots = kept.map { v -> Shot in
            var v = v
            if let h = holds[v.id] {
                v.breathe = h.breathe
                v.sweepTime = h.sweepTime
            }
            return v
        }
        return (shots, out)
    }

    /// How long the video runs once the take ended at `end` is the tour
    /// (`input`: its shots and slide changes as `finished` gives them): on
    /// past `end` only for the ending, which sets off as you finish, never
    /// while you are still talking. `least` is the shortest it may run on.
    public static func length(_ input: ChoreographyInput, end: Double, least: Double = 0) -> Double {
        let own = Set(input.shots.map(\.id))
        var i = input
        var d = end + max(least, tail(input.ending))
        for _ in 0..<12 {
            i.duration = d
            let c = Choreography(i)
            var need = d
            // The ending's first move sets off once you have finished.
            let last = c.beats.lastIndex { own.contains($0.shot.id) } ?? 0
            if last + 1 < c.beats.count { need += max(end + 0.15 - c.beats[last + 1].depart, 0) }
            // Each of its moves takes the time it wants, however late your last press.
            for j in c.beats.indices where j > max(last, 0) && c.beats[j].wanted > 0 {
                let short = c.beats[j - 1].land + Choreography.room(forTravel: c.beats[j].wanted) - c.beats[j].land
                if short > 1e-3 { need = max(need, d + short) }
            }
            // And lands, with time to rest, before the end.
            if let final = c.beats.last {
                switch final.role {
                case .pullBack: need = max(need, final.land + 1.1)
                case .home: need = max(need, final.land + Choreography.coverRest + Choreography.endingTail(input.ending))
                default: need = max(need, final.land + 1.2 + Choreography.endingTail(input.ending))
                }
            }
            if need - d < 1e-3 { break }
            d = need
        }
        return d
    }

    /// The least the video runs on past the end of a take for its ending.
    static func tail(_ ending: Ending) -> Double {
        switch ending {
        case .hold: return 1.2
        case .pullBack: return 2.6
        case .fade: return 1.7
        case .leave: return Choreography.leaveLength + 0.5
        }
    }

    // MARK: Looking

    /// What a click at `point` on the slide face up (0…1 from the top left)
    /// asks the camera to look at: the stop on the route about what is
    /// there, else the detail there framed to be read (`details` is what
    /// Direct for Me read on the slide), else a closer look around the point
    /// than `view`, the framing on screen. `stop` is the stop's place in the route.
    public func target(at point: Vec2, details: [SlideDetail], view: ShotFrame,
                       minViewHeight: Float? = nil) -> (shot: Shot, stop: Int?) {
        let k = page
        let A = base.aspects[k], C = base.canvasAspect
        func contains(_ f: ShotFrame, pad: Float = 0) -> Bool {
            point.x >= f.minU - pad && point.x <= f.maxU + pad && point.y >= f.minV - pad && point.y <= f.maxV + pad
        }
        func area(_ f: ShotFrame) -> Float { f.size.x * f.size.y }

        // A stop about what is there: the closest one, if several are.
        let stops = script.indices.filter { base.page(of: script[$0]) == k }.filter { j in
            let s = script[j]
            if let focus = s.focus { return contains(focus, pad: 0.01) }
            return contains(ShotFrame(center: s.frame.center, size: s.frame.size * 0.6))
        }
        if let j = stops.min(by: { area(script[$0].focus ?? script[$0].frame) < area(script[$1].focus ?? script[$1].frame) }) {
            return (script[j], j)
        }

        // The detail there, framed as Direct for Me would.
        let blocks = Director.blocks(details).filter { b in
            contains(ShotFrame(center: b.center, size: b.size), pad: max(b.lineHeight * 0.5, 0.01))
        }
        if let b = blocks.min(by: { $0.size.x * $0.size.y < $1.size.x * $1.size.y }) {
            let overview = Shot.overview(like: base.overview, baseAspect: base.slideAspect, slideAspect: A, canvasAspect: C)
            let opening = CameraPose(shot: overview, slideAspect: A, canvasAspect: C, safe: base.safe)
            var shot = Director.shot(for: b, slideAspect: A, canvasAspect: C, safe: base.safe, minViewHeight: minViewHeight,
                                     overviewHeight: opening.height)
            shot.page = pageID(k)
            return (shot, nil)
        }

        // Nothing read there: a closer look, as near as the slide stays sharp.
        var size = view.size * 0.5
        let least = max(minViewHeight ?? 0, 0.08)
        if size.y < least { size = size * (least / size.y) }
        func onSlide(_ c: Float, _ s: Float) -> Float { s >= 1 ? 0.5 : min(max(c, s / 2), 1 - s / 2) }
        let center = Vec2(onSlide(point.x, size.x), onSlide(point.y, size.y))
        var shot = Shot(time: 0, frame: ShotFrame(center: center, size: size), yaw: clamp((point.x - 0.5) * 10, -6, 6),
                        pitch: clamp((0.5 - point.y) * 8, -5, 6), lens: 28, aperture: 0.45, breathe: 0.5, label: "A closer look")
        shot.page = pageID(k)
        return (shot, nil)
    }
}

extension Director {
    /// One shot of the block `b`, framed and angled the way a tour frames it.
    public static func shot(for b: DetailBlock, slideAspect A: Float, canvasAspect C: Float, safe: SafeArea = .none,
                            minViewHeight: Float? = nil, overviewHeight: Float? = nil) -> Shot {
        let (frame, sweep) = framing(for: b, slideAspect: A, canvasAspect: C, safe: safe, minViewHeight: minViewHeight,
                                     overviewHeight: overviewHeight)
        let reads = b.role == .headline || b.role == .text || b.role == .smallPrint
        // Seen from the side away from the rest of the slide; lines being read stay nearly square-on.
        let yaw = reads ? clamp((b.center.x - 0.5) * 10, -6, 6) : clamp((b.center.x - 0.5) * 26, -15, 15)
        let pitch = reads ? clamp((0.5 - b.center.y) * 8, -5, 6) : clamp((0.5 - b.center.y) * 14, -8, 9)
        let words = Double(b.text.split(separator: " ").count)
        return Shot(time: 0, frame: frame, yaw: yaw, pitch: pitch, roll: 0, lens: b.role == .smallPrint ? 24 : 28,
                    aperture: b.role == .figure ? 0.55 : 0.45, move: .glide, ease: b.role == .smallPrint ? .linger : .glide,
                    breathe: sweep == nil ? 0.55 : 0.25, emphasis: .none, label: label(for: b), cue: b.role == .figure ? nil : b.text,
                    sweep: sweep, sweepTime: sweep == nil ? nil : min(max(words * 0.32, 1.3), 3.4),
                    focus: ShotFrame(center: b.center, size: b.size))
    }
}
