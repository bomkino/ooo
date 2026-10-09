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

}
