import Foundation
import XCTest
@testable import OOOMotion

/// The tour as clips, and the timing edits a person makes on the timeline:
/// the edge under the pointer goes where the pointer is, and nothing else
/// changes length.
final class TimingTests: XCTestCase {
    let A: Float = 2576.0 / 1080
    let C: Float = 9.0 / 16
    let second = UUID()

    /// Four stops with room for every move; `tight` packs them so some moves are hurried.
    func stops(page: UUID? = nil, from t: Double = 5, tight: Bool = false) -> [Shot] {
        let gaps = tight ? [0, 3, 6.5, 9] : [0, 4.5, 9, 13]
        var out = [Shot(time: t + gaps[0], frame: ShotFrame(center: Vec2(0.2, 0.3), size: Vec2(0.18, 0.3)), breathe: 0.5, label: "One"),
                   Shot(time: t + gaps[1], frame: ShotFrame(center: Vec2(0.7, 0.55), size: Vec2(0.12, 0.2)), move: .arc, breathe: 0.7,
                        label: "Two"),
                   Shot(time: t + gaps[2], frame: ShotFrame(center: Vec2(0.45, 0.8), size: Vec2(0.2, 0.25)), label: "Three"),
                   Shot(time: t + gaps[3], frame: ShotFrame(center: Vec2(0.8, 0.2), size: Vec2(0.15, 0.2)), label: "Four")]
        for i in out.indices { out[i].page = page }
        return out
    }

    func input(_ shots: [Shot], pages: [PageTiming] = [], ending: Ending = .pullBack, duration: Double = 26) -> ChoreographyInput {
        ChoreographyInput(overview: .overview(slideAspect: A, canvasAspect: C), shots: shots, arrive: Arrive(), ending: ending,
                          duration: duration, slideAspect: A, canvasAspect: C, style: MotionStyle(), safe: .reel, pages: pages)
    }

    func shotClips(_ i: ChoreographyInput) -> [TimelineClip] { i.timingChoreography.clips }

    // MARK: Clips

    func testClipsRunEdgeToEdgeFromTheStartToTheEnd() {
        let pages = [PageTiming(id: second, aspect: A, change: .turn)]
        for ending in Ending.allCases {
            for i in [input(stops(), ending: ending), input(stops() + stops(page: second, from: 20), pages: pages, ending: ending, duration: 40)] {
                let c = i.timingChoreography
                let clips = c.clips
                XCTAssertEqual(clips.first?.kind, .opening)
                XCTAssertEqual(clips.first?.start ?? -1, 0, accuracy: 1e-9)
                XCTAssertEqual(clips.last?.end ?? -1, c.duration, accuracy: 1e-6, "\(ending)")
                for (a, b) in zip(clips, clips.dropFirst()) {
                    XCTAssertEqual(a.end, b.start, accuracy: 1e-6, "\(ending): \(a.kind) to \(b.kind)")
                    XCTAssertGreaterThanOrEqual(a.hold, 0)
                    XCTAssertGreaterThanOrEqual(a.move, 0)
                }
                XCTAssertEqual(clips.compactMap(\.shotID).count, i.shots.count)
                if ending != .hold { XCTAssertEqual(clips.last?.kind, .ending, "\(ending)") }
            }
        }
        let turned = input(stops() + stops(page: second, from: 20), pages: pages, duration: 40).timingChoreography.clips
        XCTAssertTrue(turned.contains { $0.kind == .change(to: 1) })
    }

    // MARK: How long a shot holds

    func testDraggingTheEndChangesOnlyThatHold() {
        let base = input(stops())
        let before = shotClips(base)
        for k in 1...3 {
            for d in [0.8, 2.5, -0.3, -0.6] {
                let target = before[k].end + d
                let after = Timing.setEnd(base, clip: k, to: target)
                let now = shotClips(after)
                XCTAssertEqual(now.count, before.count)
                let reached = abs(now[k].end - target) < 2e-3
                if d > 0 { XCTAssertTrue(reached, "clip \(k) by \(d): \(now[k].end) for \(target)") }
                if reached {
                    // Everything after slides by exactly as much; nothing else changes length.
                    let delta = now[k].end - before[k].end
                    for j in before.indices where j != k {
                        XCTAssertEqual(now[j].move, before[j].move, accuracy: 2e-3, "move of \(j), clip \(k) by \(d)")
                        if j < before.count - 1 { XCTAssertEqual(now[j].hold, before[j].hold, accuracy: 2e-3, "hold of \(j), clip \(k) by \(d)") }
                        if j > k { XCTAssertEqual(now[j].start, before[j].start + delta, accuracy: 2e-3) }
                        if j < k { XCTAssertEqual(now[j].start, before[j].start, accuracy: 1e-6) }
                    }
                    XCTAssertEqual(now[k].move, before[k].move, accuracy: 1e-6)
                    XCTAssertEqual(after.duration, base.duration + delta, accuracy: 1e-6)
                }
            }
        }
    }

    func testHurriedMovesStillFollowThePointer() {
        let base = input(stops(tight: true))
        let before = shotClips(base)
        for k in 1...3 {
            for d in [0.4, 1.5] {
                let after = Timing.setEnd(base, clip: k, to: before[k].end + d)
                let now = shotClips(after)
                XCTAssertEqual(now[k].end, before[k].end + d, accuracy: 2e-3, "clip \(k) by \(d)")
                for j in (k + 1)..<before.count - 1 { XCTAssertEqual(now[j].hold, before[j].hold, accuracy: 2e-3, "hold of \(j)") }
                // A move that was hurried may take the time it wanted, never less than it had.
                for j in (k + 1)..<before.count { XCTAssertGreaterThanOrEqual(now[j].move, before[j].move - 2e-3) }
            }
        }
    }

    func testAHoldStopsShortWhereTheNextMoveWouldBeSqueezed() {
        let base = input(stops())
        let before = shotClips(base)
        let after = Timing.setEnd(base, clip: 1, to: before[1].land + 0.01)
        let c = after.timingChoreography
        let now = c.clips
        // The hold gave up what it could, and the next move kept all the time it wants.
        XCTAssertLessThan(now[1].hold, before[1].hold - 0.3)
        XCTAssertGreaterThan(now[1].hold, 0.1)
        let next = c.beats[now[2].beats.lowerBound]
        XCTAssertGreaterThanOrEqual(next.travel, next.wanted - 2e-3)
        XCTAssertEqual(now[2].move, before[2].move, accuracy: 2e-3)
        // Pulling further changes nothing more.
        let further = Timing.setEnd(after, clip: 1, to: before[1].land - 1)
        XCTAssertEqual(shotClips(further)[1].end, now[1].end, accuracy: 2e-3)
    }

    func testTheOpeningRestAndTheLastHold() {
        let base = input(stops())
        let before = shotClips(base)
        // The opening rests longer: every shot comes later, each as it was.
        let rested = Timing.setEnd(base, clip: 0, to: before[0].end + 1.5)
        let now = shotClips(rested)
        XCTAssertEqual(now[0].end, before[0].end + 1.5, accuracy: 2e-3)
        for j in 1..<before.count - 1 {
            XCTAssertEqual(now[j].hold, before[j].hold, accuracy: 2e-3)
            XCTAssertEqual(now[j].land, before[j].land + 1.5, accuracy: 2e-3)
        }
        // The last shot holds longer: the video runs longer, and the pull back is as it was.
        let last = before.count - 2
        let longer = Timing.setEnd(base, clip: last, to: before[last].end + 2)
        let l = shotClips(longer)
        XCTAssertEqual(l[last].end, before[last].end + 2, accuracy: 2e-3)
        XCTAssertEqual(l.last?.move ?? 0, before.last?.move ?? 0, accuracy: 2e-3)
        XCTAssertEqual(longer.duration, base.duration + 2, accuracy: 2e-3)
    }

    func testRollingTakesTheTimeFromTheNextShotOnly() {
        let base = input(stops())
        let before = shotClips(base)
        let after = Timing.setEnd(base, clip: 1, to: before[1].end + 0.5, rolling: true)
        let now = shotClips(after)
        XCTAssertEqual(now[1].end, before[1].end + 0.5, accuracy: 2e-3)
        XCTAssertEqual(now[2].hold, before[2].hold - 0.5, accuracy: 2e-3)
        for j in 3..<before.count {
            XCTAssertEqual(now[j].start, before[j].start, accuracy: 1e-6)
            XCTAssertEqual(now[j].land, before[j].land, accuracy: 1e-6)
        }
        XCTAssertEqual(after.duration, base.duration, accuracy: 1e-9)
        // Never so far that the move after the next is squeezed.
        let far = shotClips(Timing.setEnd(base, clip: 1, to: before[2].end + 3, rolling: true))
        let c = Timing.setEnd(base, clip: 1, to: before[2].end + 3, rolling: true).timingChoreography
        let b3 = c.beats[far[3].beats.lowerBound]
        XCTAssertGreaterThanOrEqual(b3.travel, b3.wanted - 2e-3)
        XCTAssertGreaterThan(far[2].hold, 0.05)
    }

    func testAcrossATurnAndAMelt() {
        for change in [PageChange.turn, .melt] {
            let pages = [PageTiming(id: second, aspect: A, change: change)]
            let base = input(stops() + stops(page: second, from: 22), pages: pages, duration: 40)
            let before = shotClips(base)
            // The second slide's first shot holds longer: the rest of the slide follows.
            guard let k = before.firstIndex(where: { $0.page == 1 && $0.shotID != nil }) else { return XCTFail() }
            let after = Timing.setEnd(base, clip: k, to: before[k].end + 1.2)
            let now = shotClips(after)
            XCTAssertEqual(now[k].end, before[k].end + 1.2, accuracy: 2e-3, "\(change)")
            for j in (k + 1)..<before.count - 1 { XCTAssertEqual(now[j].hold, before[j].hold, accuracy: 2e-3, "\(change) \(j)") }
            // A shot on the first slide holds longer: the change and the second slide come later, as they were.
            let earlier = Timing.setEnd(base, clip: 2, to: before[2].end + 1)
            let e = shotClips(earlier)
            XCTAssertEqual(e[2].end, before[2].end + 1, accuracy: 2e-3, "\(change)")
            let c0 = base.timingChoreography.changes[0].start, c1 = earlier.timingChoreography.changes[0].start
            XCTAssertEqual(c1, c0 + 1, accuracy: 2e-3, "\(change)")
        }
    }

    // MARK: How long a move takes

    func testTheSeamSetsTheMoveAndEverythingAfterFollows() {
        let base = input(stops())
        let before = shotClips(base)
        let k = 2
        let after = Timing.setLand(base, clip: k, to: before[k].start + before[k].move + 0.6)
        let now = shotClips(after)
        XCTAssertEqual(now[k].start, before[k].start, accuracy: 2e-3)
        XCTAssertEqual(now[k].move, before[k].move + 0.6, accuracy: 2e-3)
        XCTAssertEqual(now[k].hold, before[k].hold, accuracy: 2e-3)
        for j in (k + 1)..<before.count - 1 {
            XCTAssertEqual(now[j].start, before[j].start + 0.6, accuracy: 2e-3)
            XCTAssertEqual(now[j].hold, before[j].hold, accuracy: 2e-3)
        }
        XCTAssertNotNil(after.shots.first { $0.label == "Two" }?.travel)
        // Shorter, down to a quick move.
        let quick = shotClips(Timing.setLand(base, clip: k, to: before[k].start + 0.1))
        XCTAssertEqual(quick[k].move, Timing.shortestTravel, accuracy: 2e-3)
        XCTAssertEqual(quick[k].start, before[k].start, accuracy: 2e-3)
    }

    func testTheArrivalsLength() {
        let base = input(stops())
        let before = shotClips(base)
        let after = Timing.setLand(base, clip: 0, to: before[0].land + 0.8)
        let now = shotClips(after)
        XCTAssertEqual(now[0].land, before[0].land + 0.8, accuracy: 1e-6)
        XCTAssertEqual(now[0].hold, before[0].hold, accuracy: 2e-3)
        XCTAssertEqual(now[1].land, before[1].land + 0.8, accuracy: 2e-3)
    }

    // MARK: Order

    func testReorderingKeepsEachHold() {
        let base = input(stops())
        let before = shotClips(base)
        var holds: [UUID: Double] = [:]
        for c in before { if let id = c.shotID { holds[id] = c.hold } }
        let ids = before.compactMap(\.shotID)
        let order = [ids[0], ids[2], ids[1], ids[3]]
        let after = Timing.reorder(base, order)
        let now = shotClips(after)
        XCTAssertEqual(now.compactMap(\.shotID), order)
        for c in now.dropLast(2) { if let id = c.shotID { XCTAssertEqual(c.hold, holds[id] ?? -1, accuracy: 2e-3) } }
        XCTAssertEqual(now[1].start, before[1].start, accuracy: 1e-6)
    }

    // MARK: Solving

    func testSolveAndBoundary() {
        XCTAssertEqual(Timing.solve(3, in: 0...10) { $0 * $0 }, 3.0.squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(Timing.solve(-1, in: 0...10) { $0 }, 0)
        XCTAssertEqual(Timing.solve(20, in: 0...10) { $0 }, 10)
        XCTAssertEqual(Timing.boundary(in: 0...10) { $0 > 4 }, 4, accuracy: 1e-5)
        XCTAssertEqual(Timing.boundary(in: 0...10) { _ in false }, 10)
        XCTAssertEqual(Timing.boundary(in: 0...10) { _ in true }, 0)
    }
}

/// Leading the camera by its numbered positions, and closing a take.
final class LiveCloseTests: XCTestCase {
    let A: Float = 2576.0 / 1080
    let C: Float = 9.0 / 16
    let second = UUID()

    func stops(page: UUID? = nil, from t: Double = 5) -> [Shot] {
        var out = [Shot(time: t, frame: ShotFrame(center: Vec2(0.2, 0.3), size: Vec2(0.18, 0.3)), breathe: 0.5, label: "One"),
                   Shot(time: t + 3, frame: ShotFrame(center: Vec2(0.7, 0.55), size: Vec2(0.12, 0.2)), move: .arc, breathe: 0.7,
                        label: "Two"),
                   Shot(time: t + 6, frame: ShotFrame(center: Vec2(0.45, 0.8), size: Vec2(0.2, 0.25)), label: "Three")]
        for i in out.indices { out[i].page = page }
        return out
    }

    func input(_ shots: [Shot], pages: [PageTiming] = [], ending: Ending = .pullBack, lift: Lift? = nil) -> ChoreographyInput {
        ChoreographyInput(overview: .overview(slideAspect: A, canvasAspect: C), shots: shots, arrive: Arrive(), ending: ending,
                          duration: 30, slideAspect: A, canvasAspect: C, style: MotionStyle(), safe: .reel, pages: pages, lift: lift)
    }

    /// The length a take ended at `end` runs to, as the project works it out.
    func length(_ take: LiveTake, end: Double) -> Double {
        let (shots, changes) = take.finished(at: end)
        var i = take.base
        i.shots = shots
        for k in i.pages.indices { i.pages[k].at = changes[k] }
        if i.home != nil { i.home?.at = nil }
        i.duration = end + 30
        return LiveTake.length(i, end: end)
    }

    func testNumberedPositionsGoStraightThere() {
        var take = LiveTake(input(stops()))
        XCTAssertEqual(take.stops(on: 0), [0, 1, 2])
        XCTAssertTrue(take.go(to: 2, at: 4))
        XCTAssertEqual(take.visits.last?.label, "Three")
        XCTAssertEqual(take.cursor, 2)
        XCTAssertEqual(take.departures.last?.at ?? -1, 4, accuracy: 1e-3)
        // Already there: nothing to do.
        XCTAssertFalse(take.go(to: 2, at: 9))
        XCTAssertEqual(take.current, 2)
        XCTAssertTrue(take.go(to: 0, at: 10))
        XCTAssertEqual(take.current, 0)
        // Next follows on from where you went.
        take.step(.next, at: 15)
        XCTAssertEqual(take.visits.last?.label, "Two")
        XCTAssertFalse(take.go(to: 7, at: 20))
    }

    func testTheNextSlideFromAnywhere() {
        let pages = [PageTiming(id: second, aspect: A, change: .turn)]
        var take = LiveTake(input(stops() + stops(page: second, from: 20), pages: pages))
        take.step(.next, at: 4)
        XCTAssertTrue(take.nextSlide(at: 8))
        XCTAssertEqual(take.page, 1)
        XCTAssertEqual(take.stops(on: 1), [3, 4, 5])
        XCTAssertFalse(take.go(to: 1, at: 14))
        take.step(.next, at: 14)
        XCTAssertEqual(take.visits.last?.label, "One")
        XCTAssertEqual(take.visits.last?.page, second)
        XCTAssertFalse(take.nextSlide(at: 18))
    }

    func testClosingPlaysOnFromWhatYouSawWithoutAJump() {
        for ending in Ending.allCases {
            var take = LiveTake(input(stops(), ending: ending, lift: Lift(spans: [LiftSpan(start: 0, end: nil)])))
            for t in [3.5, 7.0, 10.2] { take.step(.next, at: t) }
            let end = 13.4
            let L = length(take, end: end)
            let close = take.closing(at: end, length: L)
            XCTAssertEqual(close.duration, L, accuracy: 1e-9)
            for t in stride(from: 0.0, through: end, by: 0.1) {
                let a = take.choreography.pose(at: t), b = close.pose(at: t)
                XCTAssertLessThan((a.target - b.target).length / a.height, 1e-3, "\(ending) at \(t)")
                XCTAssertEqual(logf(a.height / b.height), 0, accuracy: 1e-3, "\(ending) at \(t)")
            }
            // On from there, smoothly, to the end.
            let h = 1.0 / 60
            var t = end
            while t < L - h {
                let p0 = close.pose(at: t), p1 = close.pose(at: t + h)
                XCTAssertLessThan((p1.target - p0.target).length / p0.height, 0.08, "\(ending) at \(t)")
                t += h
            }
            if ending == .pullBack {
                let pull = close.beats.last
                XCTAssertEqual(pull?.role, .pullBack)
                XCTAssertGreaterThanOrEqual(pull?.depart ?? 0, end + 0.1)
                XCTAssertLessThanOrEqual(pull?.land ?? 99, L - 1.0)
            }
        }
    }

    func testClosingWaitsForALitEmphasisToFade() {
        var shots = stops()
        shots[1].emphasis = .lift
        var take = LiveTake(input(shots))
        take.step(.next, at: 3.5)
        take.step(.next, at: 7.0)
        let end = take.visits.last.map { $0.time + 1.4 } ?? 10
        let L = length(take, end: end)
        let close = take.closing(at: end, length: L)
        let pull = close.beats.last
        XCTAssertGreaterThanOrEqual(pull?.depart ?? 0, end + LiveTake.emphasisFade - 1e-3)
    }
}
