import Foundation
import OOOMotion

/// The project's tour retimed on the timeline (see `Timing`): the shots,
/// the slide changes set to a moment, the turn back, marks and the space
/// for you all move together; the voiceover and you on camera stay where
/// they are, since they are what the picture keeps time with.
extension OOOProject: TimingEditable {
    public var timingChoreography: Choreography { choreography() }

    public mutating func ripple(shots ids: Set<UUID>, after t: Double, by delta: Double, pinLength: Bool) {
        let was = duration
        for i in shots.indices where ids.contains(shots[i].id) { shots[i].time += delta }
        if var all = pages {
            for k in all.indices { if let at = all[k].at, at > t { all[k].at = at + delta } }
            pages = all
        }
        if let at = home?.at, at > t { home?.at = at + delta }
        if var m = marks {
            for i in m.indices where m[i].time > t { m[i].time = max(m[i].time + delta, 0) }
            marks = m
        }
        if var l = lift {
            for j in l.spans.indices {
                if l.spans[j].start > t { l.spans[j].start += delta }
                if let e = l.spans[j].end, e > t { l.spans[j].end = e + delta }
            }
            lift = l
        }
        if pinLength {
            length = max(was + delta, 1)
        } else if t.isFinite, let l = length {
            length = max(l + delta, 1)
        }
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
        self.length = max(length, 1)
    }

    /// The shots on one slide in a new order (see `Timing.reorder`). A mark
    /// drawn while a shot held goes with it.
    public func reordered(_ order: [UUID]) -> OOOProject {
        let before = choreography().clips
        var held: [UUID: (shot: UUID, offset: Double)] = [:]
        for m in marks ?? [] {
            guard let c = before.first(where: { $0.shotID != nil && m.time >= $0.land - 1e-6 && m.time < $0.end }),
                  let id = c.shotID, order.contains(id) else { continue }
            held[m.id] = (id, m.time - c.land)
        }
        var p = Timing.reorder(self, order)
        let after = p.choreography().clips
        if var m = p.marks {
            for i in m.indices {
                guard let h = held[m[i].id], let c = after.first(where: { $0.shotID == h.shot }) else { continue }
                m[i].time = c.land + h.offset
            }
            p.marks = m
        }
        return p
    }

    /// The clip on the timeline that shot `id` is.
    public func clipIndex(of id: UUID) -> Int? {
        choreography().clips.firstIndex { $0.shotID == id }
    }
}
