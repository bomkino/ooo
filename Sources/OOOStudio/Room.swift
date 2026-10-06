import AppKit
import Foundation
import OOOCore
import OOOMotion
import SwiftUI
import UniformTypeIdentifiers

/// The room left for you below the stage.
extension OOOSession {
    // MARK: Room for you

    /// Lifts the stage for a stretch from `t` (the playhead), or for the
    /// whole video, leaving the bottom of the frame clear for you.
    public func addRoom(at t: Double? = nil, whole: Bool = false) {
        let d = choreography.duration
        let span: LiftSpan
        if whole {
            span = LiftSpan(start: 0, end: nil)
        } else {
            let start = min(max(t ?? clock.time, 0), max(d - Lift.shortest, 0))
            // A stretch of about six seconds, or to the end when that is near.
            span = LiftSpan(start: start, end: start + 6 >= d - 1.5 ? nil : start + 6)
        }
        update(whole ? "Room for You" : "Add Room for You") { p in
            var lift = p.lift ?? Lift()
            if whole { lift.spans = [span] } else { lift.spans.append(span) }
            p.lift = lift
        }
        showRoom = true
    }

    /// Changes one stretch during a drag on the timeline.
    public func liveRoom(_ id: UUID, _ change: (inout LiftSpan) -> Void) {
        live { p in
            guard var lift = p.lift, let i = lift.spans.firstIndex(where: { $0.id == id }) else { return }
            change(&lift.spans[i])
            p.lift = lift
        }
    }

    public func removeRoom(_ id: UUID) {
        update("Remove Room for You") { p in p.lift?.spans.removeAll { $0.id == id } }
    }

    public func removeAllRoom() {
        update("Remove Room for You") { p in p.lift?.spans.removeAll() }
    }

    /// The share of the frame left clear for you.
    public var roomBinding: Binding<Float> {
        Binding(get: { self.project.lift?.room ?? Lift.defaultRoom },
                set: { v in self.live { p in
                    var lift = p.lift ?? Lift()
                    lift.room = v
                    p.lift = lift
                } })
    }
}
