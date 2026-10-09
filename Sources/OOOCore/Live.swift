import Foundation
import OOOMotion

/// A live take as the project sees it: what plays while you talk, and what
/// the take leaves behind.
extension OOOProject {
    /// The project as it plays during a take: no voiceover (yours is being
    /// recorded), no marks yet (you draw them as you go) and, while the
    /// camera films you, the stage up from the first moment, leaving you the room.
    public func liveStage(filming: Bool) -> OOOProject {
        var p = self
        p.voice = nil
        p.face = nil
        p.marks = nil
        p.length = nil
        if filming { p.lift = Lift(room: lift?.room ?? Lift.defaultRoom, spans: [LiftSpan(start: 0, end: nil)]) }
        return p
    }

    /// The take, ended at `end`, as the project: the moves and slide changes
    /// at the moments you set them off, `voice` as the voiceover from the
    /// first moment and `face` in the room, then the stage settles and the
    /// ending plays. Called on the project as it played during the take
    /// (`liveStage`), so the marks drawn during it stay. `recorded` is how
    /// long the recording ran: on through the closing to the very end, you
    /// stay in the room to the last frame; stopped as you closed (as 1.1
    /// did), you leave as the stage settles back down.
    public func taken(_ take: LiveTake, end: Double, voice: Voiceover?, face: FaceClip?, recorded: Double? = nil) -> OOOProject {
        var p = self
        let (shots, changes) = take.finished(at: end)
        p.shots = shots
        if var all = pages {
            for k in all.indices where k < changes.count { all[k].at = changes[k] }
            p.pages = all
        }
        if p.home != nil { p.home?.at = nil }
        p.voice = voice
        p.face = face
        p.length = nil
        let length = closingLength(take, end: end, filming: face != nil)
        p.length = length
        if face != nil {
            let heard = max(recorded ?? end, end)
            if heard >= length - 0.05 {
                p.lift = Lift(room: lift?.room ?? Lift.defaultRoom, spans: [LiftSpan(start: 0, end: nil)])
            } else {
                // You leave as the stage settles back down.
                let settled = heard - 0.2 + Lift.rise
                p.lift = Lift(room: lift?.room ?? Lift.defaultRoom, spans: [LiftSpan(start: 0, end: settled)])
                p.length = max(length, settled + 0.2)
            }
        }
        return p
    }

    /// How long the video runs once a take closes at `end`: on past `end` for
    /// its ending (and any slide not gone on to), which sets off once you
    /// have finished. Filming, long enough for the stage to settle too.
    public func closingLength(_ take: LiveTake, end: Double, filming: Bool) -> Double {
        var p = self
        let (shots, changes) = take.finished(at: end)
        p.shots = shots
        if var all = pages {
            for k in all.indices where k < changes.count { all[k].at = changes[k] }
            p.pages = all
        }
        if p.home != nil { p.home?.at = nil }
        let least = filming ? Lift.rise + 0.2 : 0
        return LiveTake.length(p.choreographyInput(duration: end + 30), end: end, least: least)
    }

    /// What a click at `point` on the slide face up during `take` asks the
    /// camera to look at (see `LiveTake.target`). `view` is the framing on screen.
    public func liveTarget(_ take: LiveTake, at point: Vec2, view: ShotFrame) -> (shot: Shot, stop: Int?) {
        let k = take.page
        return take.target(at: point, details: reading(k) ?? [], view: view,
                           minViewHeight: slide(k).sharpViewHeight(canvasHeight: format.height))
    }
}
