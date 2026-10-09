import Foundation

/// The tour as clips on a timeline, the way a person reads it: each clip is
/// the move into a framing and the hold that follows, edge to edge with the
/// next. The opening's move is the arrival; a change of slide is one clip
/// (the camera backing out and the card turning); the ending is the last.
public struct TimelineClip: Sendable, Equatable {
    public enum Kind: Sendable, Hashable {
        /// The slide arriving and resting whole before the first move.
        case opening
        case shot(UUID)
        /// The camera backing out and the card turning or melting to slide `to`.
        case change(to: Int)
        /// Turning back to the first slide.
        case home
        /// The pull back, fade or leave at the end.
        case ending
    }

    public let kind: Kind
    /// The beats it covers.
    public let beats: Range<Int>
    /// When its move sets off, when it lands, and when the next move sets off.
    public let start: Double
    public let land: Double
    public let end: Double
    /// The slide it frames (0 is the first).
    public let page: Int

    public var move: Double { land - start }
    public var hold: Double { end - land }
    public var length: Double { end - start }

    public var shotID: UUID? {
        if case .shot(let id) = kind { return id }
        return nil
    }
}

extension Choreography {
    /// The tour as clips, in order, edge to edge from 0 to the end.
    public var clips: [TimelineClip] {
        var out: [TimelineClip] = []
        var i = 0
        while i < beats.count {
            let b = beats[i]
            switch b.role {
            case .opening:
                out.append(TimelineClip(kind: .opening, beats: i..<(i + 1), start: 0, land: b.land, end: b.leave, page: 0))
            case .shot:
                out.append(TimelineClip(kind: .shot(b.shot.id), beats: i..<(i + 1), start: b.depart, land: b.land, end: b.leave, page: b.page))
            case .whole:
                // Backing out to the whole slide, then the turn it comes back for.
                if i + 1 < beats.count, beats[i + 1].role == .turned || beats[i + 1].role == .home {
                    let n = beats[i + 1]
                    out.append(TimelineClip(kind: n.role == .home ? .home : .change(to: n.page), beats: i..<(i + 2), start: b.depart,
                                            land: n.land, end: n.leave, page: n.page))
                    i += 1
                } else {
                    out.append(TimelineClip(kind: .change(to: b.page), beats: i..<(i + 1), start: b.depart, land: b.land, end: b.leave,
                                            page: b.page))
                }
            case .turned:
                out.append(TimelineClip(kind: .change(to: b.page), beats: i..<(i + 1), start: b.depart, land: b.land, end: b.leave, page: b.page))
            case .home:
                out.append(TimelineClip(kind: .home, beats: i..<(i + 1), start: b.depart, land: b.land, end: b.leave, page: b.page))
            case .pullBack:
                out.append(TimelineClip(kind: .ending, beats: i..<(i + 1), start: b.depart, land: b.land, end: b.leave, page: b.page))
            }
            i += 1
        }
        // A fade or a leave is the ending's own clip, taken from the end of the last.
        let tail = Self.endingTail(ending)
        if tail > 0, let last = out.last, last.kind != .ending {
            let cut = max(duration - tail, last.land)
            out[out.count - 1] = TimelineClip(kind: last.kind, beats: last.beats, start: last.start, land: last.land, end: cut, page: last.page)
            out.append(TimelineClip(kind: .ending, beats: last.beats.upperBound..<last.beats.upperBound, start: cut, land: cut,
                                    end: duration, page: last.page))
        }
        return out
    }
}

/// Something whose tour can be retimed: a project, or for tests the path's
/// input. Timing edits are written once against this.
public protocol TimingEditable {
    /// The camera's path as it plays now.
    var timingChoreography: Choreography { get }
    /// Moves the shots in `shots`, and everything else timed after `t` (slide
    /// changes set to a moment, the turn back, marks, the space for you), by
    /// `delta`. The end of the video follows when its length is set;
    /// `pinLength` sets it, to its length now plus `delta`.
    mutating func ripple(shots: Set<UUID>, after t: Double, by delta: Double, pinLength: Bool)
    /// When a shot lands.
    mutating func setLanding(_ id: UUID, to t: Double)
    /// How long the move into a shot takes; nil lets OOO choose.
    mutating func setTravel(_ id: UUID, to travel: Double?)
    /// How long the slide takes to arrive.
    mutating func setArrival(length: Double)
    /// The video's length, set.
    mutating func setLength(_ length: Double)
}

/// The edits a person makes to the tour's timing on the timeline. Each one
/// is solved against the real path, so the edge under the pointer lands
/// where the pointer is, and each stops where the engine's own rules would
/// otherwise squeeze a move: a move always keeps the time it wants.
public enum Timing {
    /// The shortest a hold gets on its own, before the next move.
    public static let shortestTravel = 0.3

    /// The `k`th clip's right edge moved to `edge`: how long it holds. Rolling,
    /// only the next clip gives up or takes the time; otherwise everything
    /// after slides along by exactly as much, and nothing else changes length.
    /// It stops at the shortest hold that keeps the next move whole.
    public static func setEnd<D: TimingEditable>(_ doc: D, clip k: Int, to edge: Double, rolling: Bool = false) -> D {
        let path0 = doc.timingChoreography
        let clips = path0.clips
        guard clips.indices.contains(k) else { return doc }
        let clip = clips[k]
        if clip.kind == .ending {
            var d = doc
            d.setLength(max(edge, clip.land + 0.6))
            return d
        }
        let isLast = k == (clips.lastIndex { $0.kind != .ending } ?? k)
        let nextShot = clips.indices.contains(k + 1) ? clips[k + 1].shotID : nil
        let roll = rolling && !isLast && nextShot != nil && clips.indices.contains(k + 2)
        let later = Set(clips.suffix(from: k + 1).compactMap(\.shotID))

        // The document with everything after moved by `delta`, and how it plays.
        typealias Tried = (doc: D, path: Choreography, clips: [TimelineClip])
        var cache: [Double: Tried] = [:]
        func attempt(_ delta: Double) -> Tried {
            if let t = cache[delta] { return t }
            var d = doc
            if roll, let id = nextShot {
                d.ripple(shots: [id], after: .infinity, by: delta, pinLength: false)
            } else {
                d.ripple(shots: later, after: clip.end - 1e-6, by: delta, pinLength: isLast)
            }
            let c = d.timingChoreography
            let t: Tried = (d, c, c.clips)
            cache[delta] = t
            return t
        }
        func end(_ delta: Double) -> Double {
            let t = attempt(delta)
            return t.clips.indices.contains(k) ? t.clips[k].end : clip.end
        }
        // Whether the moves after it still have the time they want (or, one
        // already hurried, no less than it had).
        func whole(_ delta: Double) -> Bool {
            let t = attempt(delta)
            guard t.clips.count == clips.count, t.clips[k].kind == clip.kind else { return false }
            let last = min(k + (roll ? 2 : 1), clips.count - 1)
            guard k + 1 <= last else { return true }
            for j in (k + 1)...last {
                guard t.clips[j].kind == clips[j].kind else { return false }
                for (i, i0) in zip(t.clips[j].beats, clips[j].beats) where i < t.path.beats.count && i0 < path0.beats.count {
                    let b = t.path.beats[i]
                    let had = path0.beats[i0].travel
                    if b.wanted > 0, b.shot.move != .cut, b.travel < min(max(b.wanted, 0.25), had) - 1e-3 { return false }
                }
            }
            return true
        }

        let delta0 = edge - clip.end
        if abs(delta0) < 1e-6 { return doc }
        if whole(delta0), abs(end(delta0) - edge) < 1e-4 { return attempt(delta0).doc }

        if delta0 > 0 {
            var hi = max(delta0, 0.05)
            if roll {
                // The next shot gives up its hold no further than the move after it allows.
                let limit = boundary(in: 0...max(clips[k + 2].land - clips[k + 1].land, 0)) { !whole($0) }
                hi = min(hi, limit)
                if end(hi) <= edge { return attempt(hi).doc }
            } else {
                var n = 0
                while end(hi) < edge && n < 12 {
                    hi *= 2
                    n += 1
                }
            }
            return attempt(solve(edge, in: 0...hi, end)).doc
        }
        // Shorter: no shorter than keeps the next move whole.
        let span = clips.indices.contains(k + 1) ? max(clips[k + 1].land - clip.land, 0) : max(clip.hold, 0)
        let least = -boundary(in: 0...span) { !whole(-$0) }
        if end(least) >= edge { return attempt(least).doc }
        return attempt(solve(edge, in: least...0, end)).doc
    }

    /// The seam in the `k`th clip, between its move and its hold, moved to
    /// `land`: how long the move takes. The move still sets off where it
    /// did and everything after slides along. It stops where the hold
    /// before would have to give up time.
    public static func setLand<D: TimingEditable>(_ doc: D, clip k: Int, to land: Double) -> D {
        let clips = doc.timingChoreography.clips
        guard clips.indices.contains(k) else { return doc }
        let clip = clips[k]
        let isLast = k == (clips.lastIndex { $0.kind != .ending } ?? k)
        let later = Set(clips.suffix(from: k + 1).compactMap(\.shotID))
        switch clip.kind {
        case .opening:
            // The arrival's length; the rest on the whole slide stays as it was.
            let length = max(land, 0.4)
            var d = doc
            d.setArrival(length: length)
            d.ripple(shots: later, after: clip.land - 1e-6, by: length - clip.land, pinLength: isLast)
            return d
        case .shot(let id):
            let start = clip.start
            func apply(_ travel: Double) -> D {
                var d = doc
                d.setTravel(id, to: travel)
                let delta = start + travel - clip.land
                d.ripple(shots: later.union([id]), after: clip.land - 1e-6, by: delta, pinLength: isLast)
                return d
            }
            func exact(_ travel: Double) -> Bool {
                let c = apply(travel).timingChoreography.clips
                guard c.count == clips.count, c[k].kind == clip.kind else { return false }
                return abs(c[k].move - travel) < 2e-3 && abs(c[k].start - start) < 2e-3
            }
            let want = max(land - start, shortestTravel)
            if exact(want) { return apply(want) }
            // The longest move the hold before leaves room for, setting off where it does.
            let most = boundary(in: shortestTravel...max(want, shortestTravel + 0.01)) { !exact($0) }
            return apply(max(min(want, most - 1e-3), shortestTravel))
        default:
            return doc
        }
    }

    /// The shots on one slide played in a new order: each keeps how long it
    /// holds, the first sets off where the first did, and every move takes
    /// the time it wants from where it now comes from.
    public static func reorder<D: TimingEditable>(_ doc: D, _ order: [UUID]) -> D {
        let clips = doc.timingChoreography.clips
        var holds: [UUID: Double] = [:]
        var lands: [Double] = []
        for c in clips {
            guard let id = c.shotID, order.contains(id) else { continue }
            holds[id] = c.hold
            lands.append(c.land)
        }
        guard lands.count == order.count else { return doc }
        var d = doc
        // The same moments, in the new order; then each hold as it was.
        for (j, id) in order.enumerated() { d.setLanding(id, to: lands[j]) }
        for id in order {
            let now = d.timingChoreography.clips
            guard let k = now.firstIndex(where: { $0.shotID == id }), let hold = holds[id] else { continue }
            d = setEnd(d, clip: k, to: now[k].land + hold)
        }
        return d
    }

    // MARK: Solving

    /// The `x` in `range` where `f(x)` (which never falls as `x` grows) is
    /// `target`, found by halving; the nearer end of the range if it is out of reach.
    public static func solve(_ target: Double, in range: ClosedRange<Double>, iterations: Int = 48, _ f: (Double) -> Double) -> Double {
        var lo = range.lowerBound, hi = range.upperBound
        if f(lo) >= target { return lo }
        if f(hi) <= target { return hi }
        for _ in 0..<iterations {
            let mid = (lo + hi) / 2
            if f(mid) < target { lo = mid } else { hi = mid }
            if hi - lo < 1e-7 { break }
        }
        return (lo + hi) / 2
    }

    /// The least `x` in `range` where `past(x)` holds, for a `past` that
    /// never stops holding once it does; the top of the range if it never does.
    public static func boundary(in range: ClosedRange<Double>, iterations: Int = 40, _ past: (Double) -> Bool) -> Double {
        var lo = range.lowerBound, hi = range.upperBound
        if past(lo) { return lo }
        if !past(hi) { return hi }
        for _ in 0..<iterations {
            let mid = (lo + hi) / 2
            if past(mid) { hi = mid } else { lo = mid }
            if hi - lo < 1e-6 { break }
        }
        return lo
    }
}

extension ChoreographyInput: TimingEditable {
    public var timingChoreography: Choreography { Choreography(self) }

    public mutating func ripple(shots ids: Set<UUID>, after t: Double, by delta: Double, pinLength: Bool) {
        for i in shots.indices where ids.contains(shots[i].id) { shots[i].time += delta }
        for k in pages.indices { if let at = pages[k].at, at > t { pages[k].at = at + delta } }
        if let at = home?.at, at > t { home?.at = at + delta }
        if var l = lift {
            for j in l.spans.indices {
                if l.spans[j].start > t { l.spans[j].start += delta }
                if let e = l.spans[j].end, e > t { l.spans[j].end = e + delta }
            }
            lift = l
        }
        if t.isFinite || pinLength { duration += delta }
    }

    public mutating func setLanding(_ id: UUID, to t: Double) {
        if let i = shots.firstIndex(where: { $0.id == id }) { shots[i].time = t }
    }

    public mutating func setTravel(_ id: UUID, to travel: Double?) {
        if let i = shots.firstIndex(where: { $0.id == id }) { shots[i].travel = travel }
    }

    public mutating func setArrival(length: Double) {
        arrive.duration = length
    }

    public mutating func setLength(_ length: Double) {
        duration = length
    }
}
