import Foundation
import XCTest
@testable import OOOMotion

/// A live take: the camera goes where you ask, when you ask, and the tour it
/// leaves keeps those moments.
final class LiveTests: XCTestCase {
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

    func input(_ shots: [Shot], pages: [PageTiming] = [], lift: Lift? = nil) -> ChoreographyInput {
        ChoreographyInput(overview: .overview(slideAspect: A, canvasAspect: C), shots: shots, arrive: Arrive(), ending: .pullBack,
                          duration: 30, slideAspect: A, canvasAspect: C, style: MotionStyle(), safe: .reel, pages: pages, lift: lift)
    }

    /// The tour the take leaves, as the app plays it afterwards.
    func after(_ take: LiveTake, end: Double) -> Choreography {
        let (shots, changes) = take.finished(at: end)
        var i = take.base
        i.shots = shots
        for k in i.pages.indices { i.pages[k].at = changes[k] }
        i.duration = max(Choreography.naturalDuration(i), end + 2.6)
        return Choreography(i)
    }

    func departs(_ c: Choreography, _ id: UUID?) -> Double? {
        c.beats.first { $0.shot.id == id }?.depart
    }

    func testEachMoveSetsOffWhenAsked() {
        var take = LiveTake(input(stops()))
        for t in [4.0, 8.0, 12.5] { XCTAssertTrue(take.step(.next, at: t)) }
        XCTAssertEqual(take.visits.map(\.label), ["One", "Two", "Three"])
        XCTAssertEqual(take.cursor, 2)
        for (d, t) in zip(take.departures, [4.0, 8.0, 12.5]) {
            XCTAssertEqual(d.at, t, accuracy: 1e-3)
            XCTAssertEqual(departs(take.choreography, d.id) ?? -1, t, accuracy: 1e-3)
        }
        // Each stop lands its own travel after the press.
        for (v, d) in zip(take.visits, take.departures) { XCTAssertGreaterThan(v.time, d.at + 0.4) }
    }

    func testTheTourKeepsTheMomentsAfterwards() {
        var take = LiveTake(input(stops()))
        for t in [4.0, 8.0, 12.5, 17.0] { take.step(.next, at: t) }
        let c = after(take, end: 21)
        for d in take.departures where d.id != nil {
            XCTAssertEqual(departs(c, d.id) ?? -1, d.at, accuracy: 1e-3)
        }
        // While you talk the holds keep still; afterwards they breathe as planned.
        XCTAssertTrue(take.visits.allSatisfy { $0.breathe == 0 })
        let (shots, _) = take.finished(at: 21)
        XCTAssertEqual(shots.map(\.breathe), [0.5, 0.7, 0.5, 0.45])
        XCTAssertEqual(shots.last?.label, "The whole slide")
    }

    func testAPressTooSoonWaitsAndTheNextChangesWhereItGoes() {
        var take = LiveTake(input(stops()))
        take.step(.next, at: 4.0)
        // Still on the way to the first stop: the second move waits until it has landed and settled.
        take.step(.next, at: 4.3)
        XCTAssertEqual(take.visits.count, 2)
        let waits = take.departures[1].at
        XCTAssertGreaterThan(waits, take.visits[0].time)
        // Pressed again before it set off: it goes to the third instead, at the same moment.
        take.step(.next, at: 4.5)
        XCTAssertEqual(take.visits.map(\.label), ["One", "Three"])
        XCTAssertEqual(take.cursor, 2)
        XCTAssertEqual(take.departures[1].at, waits, accuracy: 1e-3)
    }

    func testBackAndTheWholeSlide() {
        var take = LiveTake(input(stops()))
        take.step(.next, at: 4)
        take.step(.next, at: 8)
        XCTAssertTrue(take.step(.back, at: 12))
        XCTAssertEqual(take.visits.last?.label, "One")
        XCTAssertEqual(take.cursor, 0)
        // Back from the first stop is the whole slide; next goes on from the first stop again.
        XCTAssertTrue(take.step(.back, at: 16))
        XCTAssertEqual(take.visits.last?.label, "The whole slide")
        XCTAssertFalse(take.step(.whole, at: 20))
        take.step(.next, at: 20)
        XCTAssertEqual(take.visits.last?.label, "One")
        // Past the last stop of the last slide, out to the whole slide, then nowhere.
        take.step(.next, at: 24)
        take.step(.next, at: 28)
        XCTAssertTrue(take.step(.next, at: 32))
        XCTAssertEqual(take.visits.last?.label, "The whole slide")
        XCTAssertFalse(take.step(.next, at: 36))
    }

    func testTheCardTurnsWhenAsked() {
        let pages = [PageTiming(id: second, aspect: A, change: .turn)]
        var take = LiveTake(input(stops() + stops(page: second, from: 20), pages: pages))
        for t in [4.0, 8.0, 12.0] { take.step(.next, at: t) }
        XCTAssertEqual(take.page, 0)
        XCTAssertTrue(take.step(.next, at: 16))
        XCTAssertEqual(take.page, 1)
        // The camera sets off back to the whole slide as you ask, and the card turns once it is there.
        XCTAssertEqual(take.departures.last?.at ?? -1, 16, accuracy: 1e-3)
        XCTAssertGreaterThan(take.changes[0], 16)
        take.step(.next, at: 22)
        XCTAssertEqual(take.visits.last?.label, "One")
        XCTAssertEqual(take.visits.last?.page, second)
        XCTAssertEqual(take.departures.last?.at ?? -1, 22, accuracy: 1e-3)
        // Afterwards the card turns at the same moment, and every move keeps its own.
        let c = after(take, end: 30)
        XCTAssertEqual(c.changes.first?.start ?? -1, take.changes[0], accuracy: 1e-3)
        for d in take.departures where d.id != nil {
            XCTAssertEqual(departs(c, d.id) ?? -1, d.at, accuracy: 1e-3)
        }
    }

    func testAMeltLandsOnTheNextSlidesFirstStop() {
        let pages = [PageTiming(id: second, aspect: A, change: .melt)]
        var take = LiveTake(input(stops() + stops(page: second, from: 20), pages: pages))
        for t in [4.0, 8.0, 12.0] { take.step(.next, at: t) }
        XCTAssertTrue(take.step(.next, at: 16))
        XCTAssertEqual(take.page, 1)
        XCTAssertEqual(take.changes[0], 16, accuracy: 1e-3)
        XCTAssertEqual(take.visits.last?.label, "One")
        XCTAssertEqual(take.cursor, 3)
        take.step(.next, at: 21)
        XCTAssertEqual(take.visits.last?.label, "Two")
    }

    func testANotLitEmphasisFadesBeforeTheCameraLeaves() {
        var shots = stops()
        shots[0].emphasis = .spotlight
        var take = LiveTake(input(shots))
        take.step(.next, at: 4)
        let landed = take.visits[0].time
        take.step(.next, at: landed + 2)
        XCTAssertEqual(take.departures[1].at, landed + 2 + LiveTake.emphasisFade, accuracy: 1e-3)
        // It fades, rather than going out at once.
        let c = take.choreography
        let lit = c.emphasis(at: landed + 2)?.amount ?? 0
        let fading = c.emphasis(at: landed + 2 + LiveTake.emphasisFade / 2)?.amount ?? 0
        XCTAssertGreaterThan(lit, 0.9)
        XCTAssertGreaterThan(fading, 0.05)
        XCTAssertLessThan(fading, lit)
    }

    /// A press changes the path only from that moment on: the frame on
    /// screen as you press stays where it was, and the camera sets off from
    /// there without a jolt.
    func testThePictureNeverJumpsAtAPress() {
        let pages = [PageTiming(id: second, aspect: A, change: .turn)]
        var shots = stops() + stops(page: second, from: 20)
        shots[1].sweep = Vec2(0.1, 0)
        shots[4].emphasis = .lift
        var take = LiveTake(input(shots, pages: pages, lift: Lift(spans: [LiftSpan(start: 0, end: nil)])))
        for t in [1.2, 3.1, 7.3, 9.0, 9.1, 13.7, 15.2, 21.4, 23.0, 24.0, 30.0, 33.0] {
            let before = take.choreography
            take.step(.next, at: t)
            let now = take.choreography
            for dt in [0.0, 1.0 / 60, 0.25, 1.0] {
                let a = before.pose(at: t + dt), b = now.pose(at: t + dt)
                if dt == 0 || before.beats.count == now.beats.count && (now.beats.last?.depart ?? 0) > t + dt {
                    // Until the new move sets off, nothing changes.
                    XCTAssertLessThan((a.target - b.target).length / a.height, 1e-3, "at \(t + dt)")
                    XCTAssertEqual(logf(a.height / b.height), 0, accuracy: 1e-3, "at \(t + dt)")
                }
            }
            // Smooth from frame to frame across the moment it sets off.
            if let d = take.departures.last?.at {
                let h = 1.0 / 120
                let p0 = now.pose(at: d - h), p1 = now.pose(at: d), p2 = now.pose(at: d + h)
                let v0 = (p1.target - p0.target).length / p1.height, v1 = (p2.target - p1.target).length / p1.height
                XCTAssertLessThan(abs(v1 - v0), 0.004, "speed at \(d)")
                XCTAssertEqual(logf(p1.height / p0.height), logf(p2.height / p1.height), accuracy: 0.004, "zoom at \(d)")
            }
        }
    }

    func testTheHorizonMovesOn() {
        var take = LiveTake(input(stops()))
        take.step(.next, at: 4)
        XCTAssertFalse(take.keepUp(at: 100))
        XCTAssertTrue(take.keepUp(at: LiveTake.ahead - 10))
        XCTAssertGreaterThan(take.choreography.duration, LiveTake.ahead * 1.5)
    }

    func testASlideNotGoneOnToComesAfterTheEnd() {
        let pages = [PageTiming(id: second, aspect: A, change: .turn)]
        var take = LiveTake(input(stops() + stops(page: second, from: 20), pages: pages))
        take.step(.next, at: 4)
        take.step(.next, at: 8)
        let (_, changes) = take.finished(at: 14)
        XCTAssertGreaterThan(changes[0] ?? 0, 14)
        let c = after(take, end: 14)
        let whole = c.beats.first { $0.role == .whole }
        XCTAssertGreaterThanOrEqual(whole?.depart ?? 0, 14)
    }
}

/// Clicking the slide during a take, and how long the video runs on after it.
final class LiveLookTests: XCTestCase {
    let A: Float = 2576.0 / 1080
    let C: Float = 9.0 / 16

    func take(_ shots: [Shot], ending: Ending = .pullBack) -> LiveTake {
        LiveTake(ChoreographyInput(overview: .overview(slideAspect: A, canvasAspect: C), shots: shots, arrive: Arrive(), ending: ending,
                                   duration: 30, slideAspect: A, canvasAspect: C, style: MotionStyle(), safe: .reel))
    }

    let headline = SlideDetail(frame: ShotFrame(center: Vec2(0.3, 0.15), size: Vec2(0.4, 0.08)), text: "Revenue doubled in a year")
    let figure = SlideDetail(frame: ShotFrame(center: Vec2(0.75, 0.6), size: Vec2(0.3, 0.5)), kind: .figure)

    func testAClickOnAStopGoesThereAndTheRouteFollowsOn() {
        var stop = Shot(time: 5, frame: ShotFrame(center: Vec2(0.75, 0.6), size: Vec2(0.4, 0.6)), label: "The chart")
        stop.focus = ShotFrame(center: Vec2(0.75, 0.6), size: Vec2(0.3, 0.5))
        let other = Shot(time: 8, frame: ShotFrame(center: Vec2(0.3, 0.15), size: Vec2(0.2, 0.2)), label: "Headline")
        var t = take([other, stop])
        let view = ShotFrame.whole().visible(slideAspect: A, canvasAspect: C)
        let (shot, index) = t.target(at: Vec2(0.7, 0.55), details: [headline, figure], view: view)
        XCTAssertEqual(shot.label, "The chart")
        // The route goes by time: the chart first, then the headline.
        XCTAssertEqual(index, 0)
        XCTAssertTrue(t.look(shot, stop: index, at: 4))
        XCTAssertEqual(t.cursor, 0)
        t.step(.next, at: 9)
        XCTAssertEqual(t.visits.last?.label, "Headline")
    }

    func testAClickOnADetailFramesItToBeRead() {
        var t = take([])
        let view = ShotFrame.whole().visible(slideAspect: A, canvasAspect: C)
        let (shot, index) = t.target(at: Vec2(0.25, 0.16), details: [headline, figure], view: view)
        XCTAssertNil(index)
        XCTAssertEqual(shot.cue, headline.text)
        XCTAssertLessThan(shot.frame.size.y, view.size.y * 0.7)
        XCTAssertTrue(t.look(shot, at: 4))
        XCTAssertEqual(t.visits.last?.cue, headline.text)
    }

    func testAClickOnNothingReadLooksCloser() {
        let t = take([])
        let view = ShotFrame(center: Vec2(0.5, 0.5), size: Vec2(0.5, 0.6))
        let (shot, _) = t.target(at: Vec2(0.1, 0.9), details: [headline], view: view, minViewHeight: 0.2)
        XCTAssertEqual(shot.frame.size.y, 0.3, accuracy: 1e-4)
        // Kept on the slide.
        XCTAssertGreaterThanOrEqual(shot.frame.minU, -1e-4)
        XCTAssertLessThanOrEqual(shot.frame.maxV, 1 + 1e-4)
        let closest = t.target(at: Vec2(0.5, 0.5), details: [], view: ShotFrame(center: Vec2(0.5, 0.5), size: Vec2(0.1, 0.12)),
                               minViewHeight: 0.15).shot
        XCTAssertEqual(closest.frame.size.y, 0.15, accuracy: 1e-4)
    }

    /// The ending sets off once you have finished talking, not before.
    func testTheEndingWaitsForYouToFinish() {
        for ending in Ending.allCases {
            var t = take([Shot(time: 5, frame: ShotFrame(center: Vec2(0.3, 0.3), size: Vec2(0.2, 0.25)), label: "One")], ending: ending)
            t.step(.next, at: 4)
            for end in [9.0, 4.6, 4.1] {
                let (shots, _) = t.finished(at: end)
                var i = t.base
                i.shots = shots
                let d = LiveTake.length(i, end: end)
                i.duration = d
                let c = Choreography(i)
                XCTAssertGreaterThanOrEqual(d, end + 1.2, "\(ending)")
                if let pull = c.beats.first(where: { $0.role == .pullBack }) {
                    XCTAssertGreaterThanOrEqual(pull.depart, end + 0.1, "\(ending) at \(end)")
                    XCTAssertLessThanOrEqual(pull.land, d - 1.0, "\(ending) at \(end)")
                    XCTAssertGreaterThanOrEqual(pull.travel, pull.wanted - 1e-3, "the pull back isn't hurried, \(ending) at \(end)")
                }
                XCTAssertEqual(c.endingProgress(at: end + 0.3), 0, "\(ending)")
            }
        }
    }

    func testTurningHomeWaitsForYouToFinish() {
        let second = UUID()
        var shots = [Shot(time: 5, frame: ShotFrame(center: Vec2(0.3, 0.3), size: Vec2(0.2, 0.25)), label: "One")]
        var two = shots[0]
        two.id = UUID()
        two.time = 15
        two.page = second
        shots.append(two)
        var input = ChoreographyInput(overview: .overview(slideAspect: A, canvasAspect: C), shots: shots, arrive: Arrive(),
                                      ending: .hold, duration: 30, slideAspect: A, canvasAspect: C, style: MotionStyle(), safe: .reel,
                                      pages: [PageTiming(id: second, aspect: A, change: .turn)])
        input.home = HomeTiming()
        var t = LiveTake(input)
        for at in [4.0, 9.0, 14.0] { t.step(.next, at: at) }
        XCTAssertEqual(t.page, 1)
        let end = 20.0
        let (kept, changes) = t.finished(at: end)
        var i = t.base
        i.shots = kept
        for k in i.pages.indices { i.pages[k].at = changes[k] }
        i.duration = LiveTake.length(i, end: end)
        let c = Choreography(i)
        let back = c.changes.first { $0.back }
        XCTAssertNotNil(back)
        XCTAssertGreaterThan(back?.start ?? 0, end)
        XCTAssertEqual(c.beats.last?.role, .home)
        XCTAssertLessThanOrEqual((c.beats.last?.land ?? 0) + Choreography.coverRest, i.duration + 1e-3)
    }
}
