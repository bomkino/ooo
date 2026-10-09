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
