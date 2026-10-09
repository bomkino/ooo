import Foundation
import OOOCore
import OOOMotion

/// Timing on the timeline and in the inspector. A drag is worked out afresh
/// at every step from the project as it was when the hand went down (see
/// `Timing`), so the edge under the pointer stays under it and nothing drifts.
extension OOOSession {
    /// The clip that is shot `id`.
    public func clip(of id: UUID) -> TimelineClip? {
        choreography.clips.first { $0.shotID == id }
    }

    /// The clip that is shot `id`, and its place on the timeline.
    public func clipIndex(of id: UUID) -> Int? {
        choreography.clips.firstIndex { $0.shotID == id }
    }

    /// The timeline zoomed in (more than 1) or out, never further out than the whole video.
    public func zoomTimeline(by k: Double) {
        timelineZoom = min(max(timelineZoom * k, 1), 40)
    }

    /// A timing drag begins: one undo step, the scale held still under the hand.
    func beginTiming(_ name: String) {
        beginEdit(name)
        timingBase = project
        holdTimeline(true)
    }

    /// A step of the drag, worked out from where it began.
    func timing(_ change: (OOOProject) -> OOOProject) {
        guard let base = timingBase else { return }
        let p = change(base)
        live { $0 = p }
    }

    /// The drag ends; the timeline eases to fit.
    func endTiming(_ name: String) {
        timingBase = nil
        commitEdit(name)
        holdTimeline(false)
    }

    /// Clip `k` holds for `seconds`; everything after slides along.
    public func holdFor(clip k: Int, seconds: Double) {
        let clips = choreography.clips
        guard clips.indices.contains(k) else { return }
        let edge = clips[k].land + max(seconds, 0.1)
        update("Hold") { p in p = Timing.setEnd(p, clip: k, to: edge) }
    }

    /// The move into clip `k` takes `seconds`; everything after slides along.
    public func moveFor(clip k: Int, seconds: Double) {
        let clips = choreography.clips
        guard clips.indices.contains(k) else { return }
        let land = clips[k].start + max(seconds, Timing.shortestTravel)
        update("Move Length") { p in p = Timing.setLand(p, clip: k, to: land) }
    }

    /// Clip `k` holds for `seconds`, as a slider moves: no undo step of its own.
    func liveHold(clip k: Int, seconds: Double) {
        let clips = choreography.clips
        guard clips.indices.contains(k) else { return }
        let edge = clips[k].land + max(seconds, 0.1)
        live { p in p = Timing.setEnd(p, clip: k, to: edge) }
    }

    /// The move into clip `k` takes `seconds`, as a slider moves.
    func liveMove(clip k: Int, seconds: Double) {
        let clips = choreography.clips
        guard clips.indices.contains(k) else { return }
        let land = clips[k].start + max(seconds, Timing.shortestTravel)
        live { p in p = Timing.setLand(p, clip: k, to: land) }
    }

    /// The opening arrives over `seconds`; everything after slides along.
    public func arriveOver(_ seconds: Double) {
        guard choreography.clips.first?.kind == .opening else { return }
        update("Opening Length") { p in p = Timing.setLand(p, clip: 0, to: seconds) }
    }

    /// Clip `k` selected, and the playhead resting on it.
    public func selectClip(_ k: Int) {
        let clips = choreography.clips
        guard clips.indices.contains(k) else { return }
        let c = clips[k]
        if let id = c.shotID {
            select(.shot(id))
            return
        }
        select(.overview, show: false)
        previewUntil = nil
        clock.playing = false
        clock.time = min(c.land + min(0.4, c.hold * 0.3), clock.duration)
        touch()
    }

    /// Plays clip `k` from just before its move sets off, and stops where the next one does.
    public func watchClip(_ k: Int) {
        let clips = choreography.clips
        guard clips.indices.contains(k) else { return }
        let c = clips[k]
        let from = max(c.start - 0.3, 0)
        let stop = min(c.end, clock.duration - 0.12)
        clock.playing = false
        clock.time = from
        previewUntil = stop > from + 0.2 ? stop : nil
        clock.playing = true
        touch()
    }

    /// Lets OOO time the move into shot `id` from how far it goes.
    public func autoTravel(_ id: UUID) {
        updateShot(id, "Let OOO Time the Move") { $0.travel = nil }
    }

    /// Shot `id` one place earlier (−1) or later (1) among the shots on its
    /// slide. Every shot keeps how long it holds.
    public func moveShot(_ id: UUID, by step: Int) {
        let p = project
        guard let shot = p.shots.first(where: { $0.id == id }) else { return }
        let k = p.pageIndex(shot.page)
        let mine = Set(p.shots.filter { p.pageIndex($0.page) == k }.map(\.id))
        var order = choreography.clips.compactMap(\.shotID).filter { mine.contains($0) }
        guard let i = order.firstIndex(of: id), order.indices.contains(i + step) else { return }
        order.swapAt(i, i + step)
        reorderShots(order)
    }

    /// The shots on one slide played in `order`.
    public func reorderShots(_ order: [UUID]) {
        update("Reorder Shots") { $0 = $0.reordered(order) }
    }

    /// Whether shot `id` can go a place earlier (−1) or later (1) on its slide.
    public func canMoveShot(_ id: UUID, by step: Int) -> Bool {
        let p = project
        guard let shot = p.shots.first(where: { $0.id == id }) else { return false }
        let k = p.pageIndex(shot.page)
        let mine = Set(p.shots.filter { p.pageIndex($0.page) == k }.map(\.id))
        let order = choreography.clips.compactMap(\.shotID).filter { mine.contains($0) }
        guard let i = order.firstIndex(of: id) else { return false }
        return order.indices.contains(i + step)
    }
}
