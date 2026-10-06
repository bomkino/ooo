import Foundation
import XCTest
@testable import OOOMotion

/// The card changing from slide to slide (turning over, melting, turning
/// back to the first), and the stage rising to leave room for a talking
/// head below it.
final class PagesLiftTests: XCTestCase {
    let A: Float = 2576.0 / 1080
    let C: Float = 9.0 / 16
    let second = UUID()
    let third = UUID()

    var shots: [Shot] {
        [Shot(time: 6, frame: ShotFrame(center: Vec2(0.2, 0.3), size: Vec2(0.18, 0.3)), breathe: 0.5),
         Shot(time: 9, frame: ShotFrame(center: Vec2(0.7, 0.55), size: Vec2(0.12, 0.2)), move: .arc),
         Shot(time: 12, frame: ShotFrame(center: Vec2(0.45, 0.8), size: Vec2(0.2, 0.25)))]
    }

    /// The tour on the slide after a first that has no shots of its own: the
    /// first slide is a cover.
    func tour(cover: Bool = false, home: Bool = true, lift: Lift? = nil, ending: Ending = .hold, titleRoom: Float = 0) -> Choreography {
        let pages = cover ? [PageTiming(id: second, aspect: A)] : []
        // As the app does, the tour on the slide after the cover sets off once
        // the card has turned over to it.
        let delay = cover ? Choreography.coverRest + PageChange.turn.length + Choreography.turnSettle : 0
        let shots = self.shots.map { s -> Shot in var s = s; if cover { s.page = second; s.time += delay }; return s }
        return choreography(shots, pages: pages, home: cover && home ? HomeTiming() : nil, lift: lift, ending: ending,
                            titleRoom: titleRoom)
    }

    func choreography(_ shots: [Shot], pages: [PageTiming], home: HomeTiming? = nil, lift: Lift? = nil, ending: Ending = .hold,
                      titleRoom: Float = 0, duration: Double? = nil) -> Choreography {
        var input = ChoreographyInput(overview: .overview(slideAspect: A, canvasAspect: C), shots: shots, arrive: Arrive(),
                                      ending: ending, duration: 0, slideAspect: A, canvasAspect: C, style: MotionStyle(),
                                      safe: .reel, pages: pages, home: home, lift: lift, titleRoom: titleRoom)
        input.duration = duration ?? Choreography.naturalDuration(input)
        return Choreography(input)
    }

    // MARK: Turning the card

    func testSettleStartsAndEndsAtRest() {
        XCTAssertEqual(Curves.settle(0), 0)
        XCTAssertEqual(Curves.settle(1), 1, accuracy: 1e-5)
        var last: Float = 0
        for i in 1...200 {
            let v = Curves.settle(Float(i) / 200)
            XCTAssertGreaterThanOrEqual(v, last - 1e-6)
            last = v
        }
        // No speed at either end.
        XCTAssertLessThan(Curves.settle(0.01) / 0.01, 0.01)
        XCTAssertLessThan((1 - Curves.settle(0.99)) / 0.01, 0.01)
    }

    func testTheCardTurnsOverAndLandsWithAlittleGive() {
        XCTAssertEqual(CardTurn.angle(0), 0, accuracy: 1e-6)
        XCTAssertEqual(CardTurn.angle(1), .pi, accuracy: 1e-4)
        let samples = (0...400).map { CardTurn.angle(Float($0) / 400) }
        // Pressed back a touch first, then past flat a touch, never more than a few degrees either way.
        XCTAssertLessThan(samples.min()!, -radians(1))
        XCTAssertGreaterThan(samples.min()!, -radians(4))
        XCTAssertGreaterThan(samples.max()!, .pi + radians(1))
        XCTAssertLessThan(samples.max()!, .pi + radians(8))
        // Smooth all the way: no step bigger than a couple of degrees at 400 samples.
        for i in 1..<samples.count { XCTAssertLessThan(abs(samples[i] - samples[i - 1]), radians(2.5), "step at \(i)") }
        // At rest at both ends, turned exactly over at the end.
        let start = CardTurn.pose(0, back: false, direction: 1), end = CardTurn.pose(1, back: false, direction: 1)
        XCTAssertEqual(start.rotation.y, 0, accuracy: 1e-6)
        XCTAssertEqual(end.rotation.y, .pi, accuracy: 1e-4)
        XCTAssertEqual(end.offset.length, 0, accuracy: 1e-5)
        XCTAssertEqual(end.curl, 0, accuracy: 1e-5)
        XCTAssertEqual(CardTurn.pose(1, back: true, direction: -1).rotation.y, 0, accuracy: 1e-4)
        XCTAssertEqual(CardTurn.activity(0), 0)
        XCTAssertEqual(CardTurn.activity(1), 0)
        XCTAssertGreaterThan(CardTurn.activity(0.5), 0.99)
    }

    func testACoverTurnsOverBeforeTheTourAndBackAtTheEnd() {
        let c = tour(cover: true)
        XCTAssertEqual(c.turns.count, 2)
        let over = c.turns[0], back = c.turns[1]
        XCTAssertFalse(over.back)
        XCTAssertTrue(back.back)
        XCTAssertEqual(over.from, 0)
        XCTAssertEqual(over.to, 1)
        XCTAssertEqual(back.to, 0)
        // The cover rests at least a moment after it has arrived, then turns
        // in time for the first shot on the slide behind it to land on its moment.
        XCTAssertGreaterThanOrEqual(over.start, Arrive().end + Choreography.coverRest - 1e-9)
        XCTAssertEqual(c.beats[2].land, shots[0].time + Choreography.coverRest + PageChange.turn.length + Choreography.turnSettle,
                       accuracy: 1e-9)
        // While it turns, the camera reframes for the slide on its back, and
        // nothing else sets off before that slide has settled.
        XCTAssertEqual(c.beats[1].role, .turned)
        XCTAssertEqual(c.beats[1].depart, over.start, accuracy: 1e-9)
        XCTAssertEqual(c.beats[1].land, over.end, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(c.beats[2].depart, over.end + Choreography.turnSettle - 1e-9)
        XCTAssertEqual(c.page(at: over.start - 0.01), 0)
        XCTAssertEqual(c.page(at: over.end), 1)
        // The camera is back on the whole slide, settled, before the card turns
        // back, and the first slide rests a moment before the end.
        let whole = c.beats[c.beats.count - 2], last = c.beats[c.beats.count - 1]
        XCTAssertEqual(whole.role, .whole)
        XCTAssertEqual(last.role, .home)
        XCTAssertEqual(last.page, 0)
        XCTAssertEqual(back.start, whole.land + Choreography.backLead, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(back.end + Choreography.coverRest, c.duration + 1e-6)
        XCTAssertGreaterThan(back.start, c.beats[c.beats.count - 3].land + 1)
        XCTAssertEqual(c.page(at: c.duration), 0)
        // The same slide on both sides: while a turn runs the camera does not
        // travel, at most it breathes.
        for turn in c.turns {
            let a = c.basePose(at: turn.start), b = c.basePose(at: turn.end)
            XCTAssertEqual(a.target.x, b.target.x, accuracy: a.height * 0.01)
            XCTAssertEqual(a.height, b.height, accuracy: a.height * 0.05)
        }
        let check = MotionCheck(c)
        XCTAssertTrue(check.problems.isEmpty, "\(check.problems)")
    }

    func testTheTurnBackLandsWhereItIsAsked() {
        let pages = [PageTiming(id: second, aspect: A)]
        let shots = self.shots.map { s -> Shot in var s = s; s.page = second; return s }
        let c = choreography(shots, pages: pages, home: HomeTiming(at: 24), duration: 30)
        XCTAssertEqual(c.turns.last?.start ?? 0, 24, accuracy: 1e-9)
        // Without a turn back the tour ends as it would have, with the slide showing.
        let plain = tour(cover: true, home: false, ending: .pullBack)
        XCTAssertEqual(plain.turns.count, 1)
        XCTAssertEqual(plain.beats.last?.role, .pullBack)
        XCTAssertEqual(plain.beats.last?.page, 1)
    }

    func testAnEarlyShotWaitsForTheTurn() {
        var early = shots.map { s -> Shot in var s = s; s.page = second; return s }
        early[0].time = 3
        early[1].time = 11
        early[2].time = 14
        let c = choreography(early, pages: [PageTiming(id: second, aspect: A, at: 4)], duration: 24)
        let turn = c.turns[0]
        XCTAssertEqual(turn.start, 4, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(c.beats[2].land, turn.end + Choreography.turnSettle + 0.6 - 1e-9)
        XCTAssertGreaterThanOrEqual(c.beats[2].travel, c.beats[2].wanted - 1e-9, "the first move is not rushed")
        XCTAssertGreaterThanOrEqual(c.beats[2].depart, turn.end + Choreography.turnSettle - 1e-9)
        XCTAssertTrue(MotionCheck(c).problems.isEmpty, "\(MotionCheck(c).problems)")
    }

    // MARK: Several slides

    /// Three slides, each with its own shots: a turn to the second (a
    /// squarer slide), a melt to the third.
    func threeSlides(home: Bool = false, lift: Lift? = nil) -> Choreography {
        let square: Float = 1920.0 / 1080
        var all: [Shot] = []
        all.append(Shot(time: 4.6, frame: ShotFrame(center: Vec2(0.25, 0.3), size: Vec2(0.2, 0.25)), cue: "Revenue grew"))
        all.append(Shot(time: 7.6, frame: ShotFrame(center: Vec2(0.7, 0.6), size: Vec2(0.15, 0.2))))
        var b1 = Shot(time: 15, frame: ShotFrame(center: Vec2(0.3, 0.4), size: Vec2(0.3, 0.3)))
        b1.page = second
        var b2 = Shot(time: 18, frame: ShotFrame(center: Vec2(0.6, 0.35), size: Vec2(0.12, 0.15)), yaw: 6, pitch: -3, sweep: Vec2(0.1, 0))
        b2.page = second
        var c1 = Shot(time: 22, frame: ShotFrame(center: Vec2(0.62, 0.36), size: Vec2(0.12, 0.15)), yaw: -10, pitch: 4, lens: 24)
        c1.page = third
        var c2 = Shot(time: 25.5, frame: ShotFrame(center: Vec2(0.2, 0.7), size: Vec2(0.2, 0.2)))
        c2.page = third
        all += [b1, b2, c1, c2].reversed()
        return choreography(all, pages: [PageTiming(id: second, aspect: square), PageTiming(id: third, aspect: square, change: .melt)],
                            home: home ? HomeTiming() : nil, lift: lift)
    }

    func testEachSlideTakesItsTurn() {
        let c = threeSlides()
        XCTAssertEqual(c.changes.map(\.kind), [.turn, .melt])
        XCTAssertEqual(c.aspects.count, 3)
        let turn = c.changes[0], melt = c.changes[1]
        // Every shot frames its own slide, after the card has changed to it.
        for b in c.beats where b.role == .shot {
            switch b.page {
            case 0: XCTAssertLessThan(b.land, turn.start)
            case 1: XCTAssertGreaterThan(b.land, turn.end); XCTAssertLessThan(b.land, melt.start)
            default: XCTAssertGreaterThanOrEqual(b.land, melt.start - 1e-9)
            }
        }
        XCTAssertEqual(c.beats.filter { $0.page == 2 }.count, 2)
        // Before the turn the camera is back on the whole first slide; while
        // it turns it reframes for the second, which is a different shape.
        let whole = c.beats.first { $0.role == .whole }
        let turned = c.beats.first { $0.role == .turned }
        XCTAssertEqual(whole?.page, 0)
        XCTAssertEqual(turned?.page, 1)
        XCTAssertEqual(turned?.land ?? 0, turn.end, accuracy: 1e-9)
        XCTAssertNotEqual(whole?.pose.height ?? 0, turned?.pose.height ?? 0, accuracy: 1e-3)
        XCTAssertEqual(c.page(at: turn.end + 0.1), 1)
        XCTAssertEqual(c.page(at: melt.start + 0.1), 2)
        let check = MotionCheck(c)
        print(check.summary)
        XCTAssertTrue(check.problems.isEmpty, "\(check.problems)")
    }

    func testAMeltCutsUnseenAndKeepsTheView() {
        for lift in [nil, Lift(spans: [LiftSpan(start: 10, end: nil)])] {
            let c = threeSlides(lift: lift)
            let melt = c.changes[1]
            guard let i = c.beats.firstIndex(where: { $0.melts }) else { return XCTFail("no melt") }
            let beat = c.beats[i]
            XCTAssertEqual(beat.land, melt.start, accuracy: 1e-9)
            XCTAssertEqual(beat.shot.move, .cut)
            XCTAssertEqual(beat.page, 2)
            // The cut is a cut: no motion blur reaches across it.
            XCTAssertEqual(c.cut(between: melt.start - 0.01, and: melt.start + 0.01) ?? -1, melt.start, accuracy: 1e-9)
            // The camera had settled on the second slide, and looks on the third
            // from the same angle, with the same lens.
            let (a, b) = c.meltHandoff(melt)
            XCTAssertEqual(a.yaw, b.yaw, accuracy: 1e-5)
            XCTAssertEqual(a.pitch, b.pitch, accuracy: 1e-5)
            XCTAssertEqual(a.roll, b.roll, accuracy: 1e-5)
            XCTAssertEqual(a.fov, b.fov, accuracy: 1e-5)
            XCTAssertEqual(c.settled(at: melt.start - 0.05), 1, accuracy: 0.05)
            // The move after it waits for the melt to finish.
            XCTAssertGreaterThanOrEqual(c.beats[i + 1].depart, melt.end - 1e-9)
            let check = MotionCheck(c)
            XCTAssertTrue(check.problems.isEmpty, "\(check.problems)")
        }
    }

    func testAChangeWaitsForItsSlideToBeSeen() {
        // Asked to turn before the first slide's last shot has been seen, the
        // card waits for it, and for the flight back to the whole slide;
        // asked later, it turns when asked.
        var shots = self.shots
        var later = Shot(time: 24, frame: ShotFrame(center: Vec2(0.5, 0.5), size: Vec2(0.3, 0.3)))
        later.page = second
        shots.append(later)
        let early = choreography(shots, pages: [PageTiming(id: second, aspect: A, at: 5)])
        XCTAssertGreaterThan(early.turns[0].start, 12 + 1.5)
        let asked = choreography(shots, pages: [PageTiming(id: second, aspect: A, at: 20)])
        XCTAssertEqual(asked.turns[0].start, 20, accuracy: 1e-9)
        // On its own, the turn comes as late as the next slide's first shot
        // allows, so the last shot here holds while it is talked about, and
        // that first shot still lands on its moment.
        let auto = choreography(shots, pages: [PageTiming(id: second, aspect: A)])
        XCTAssertGreaterThan(auto.turns[0].start, 16)
        XCTAssertEqual(auto.beats.first { $0.page == 1 && $0.role == .shot }?.land ?? 0, 24, accuracy: 1e-9)
        // A melt lands the next slide's first shot as it starts.
        let melt = choreography(shots, pages: [PageTiming(id: second, aspect: A, change: .melt)])
        XCTAssertEqual(melt.changes[0].start, 24, accuracy: 1e-9)
        for c in [early, asked, auto, melt] { XCTAssertTrue(MotionCheck(c).problems.isEmpty, "\(MotionCheck(c).problems)") }
    }

    func testTheMeltSpreadsEvenlyToTheCorners() {
        let view: Float = 0.2, farthest: Float = 1.4
        let reach = Melt.reach(farthest: farthest, view: view)
        XCTAssertEqual(Melt.radius(0, start: 0.04 * view, reach: reach), 0)
        XCTAssertEqual(Melt.radius(1, start: 0.04 * view, reach: reach), reach, accuracy: 1e-4)
        var last: Float = 0
        for i in 1...200 {
            let r = Melt.radius(Float(i) / 200, start: 0.04 * view, reach: reach)
            XCTAssertGreaterThanOrEqual(r, last)
            last = r
        }
        // Done, nothing of the old slide is left: the front's inner edge is past the farthest corner.
        XCTAssertGreaterThanOrEqual(reach - Melt.front(reach, view: view), farthest)
        // It has covered the view, but not the card, by the middle.
        let half = Melt.radius(0.55, start: 0.04 * view, reach: reach)
        XCTAssertGreaterThan(half, view * 0.6)
        XCTAssertLessThan(half, farthest)
    }

    func testTheOpeningFollowsEachSlidesShape() {
        let square: Float = 1920.0 / 1080
        let base = Shot.overview(slideAspect: A, canvasAspect: C)
        let other = Shot.overview(like: base, baseAspect: A, slideAspect: square, canvasAspect: C)
        XCTAssertTrue(other.isDefaultOverview(slideAspect: square, canvasAspect: C))
        XCTAssertNotEqual(other.yaw, base.yaw)
        var mine = base
        mine.yaw = -3
        XCTAssertEqual(Shot.overview(like: mine, baseAspect: A, slideAspect: square, canvasAspect: C).yaw, -3)
    }

    func testTurnsSwingAwayFromTheCamera() {
        XCTAssertEqual(turnDirection(overviewYaw: -20), 1)
        XCTAssertEqual(turnDirection(overviewYaw: 20), -1)
    }

    // MARK: Room for you

    func testTheStageRisesAndSettlesSmoothly() {
        let lift = Lift(spans: [LiftSpan(start: 2, end: 8)])
        XCTAssertEqual(lift.amount(at: 1.9, duration: 20), 0)
        XCTAssertEqual(lift.amount(at: 2 + Lift.rise, duration: 20), 1, accuracy: 1e-5)
        XCTAssertEqual(lift.amount(at: 5, duration: 20), 1)
        XCTAssertEqual(lift.amount(at: 8, duration: 20), 0, accuracy: 1e-5)
        XCTAssertEqual(lift.amount(at: 9, duration: 20), 0)
        var last: Float = 0
        for t in stride(from: 0.0, to: 20, by: 1.0 / 240) {
            let v = lift.amount(at: t, duration: 20)
            XCTAssertLessThan(abs(v - last), 0.01, "jump at \(t)")
            last = v
        }
        XCTAssertEqual(lift.moves(duration: 20).count, 2)
    }

    func testSpansThatNearlyTouchRiseAsOne() {
        let lift = Lift(spans: [LiftSpan(start: 8, end: 12), LiftSpan(start: 2, end: 7.8)])
        XCTAssertEqual(lift.stretches(duration: 20).count, 1)
        XCTAssertEqual(lift.amount(at: 7.9, duration: 20), 1)
        // From the first frame it is already up; to the end it stays up.
        let whole = Lift(spans: [LiftSpan(start: 0, end: nil)])
        XCTAssertEqual(whole.amount(at: 0, duration: 20), 1)
        XCTAssertEqual(whole.amount(at: 20, duration: 20), 1)
        XCTAssertTrue(whole.moves(duration: 20).isEmpty)
        // A span ending on the last moment counts as to the end.
        XCTAssertEqual(Lift(spans: [LiftSpan(start: 3, end: 20)]).amount(at: 20, duration: 20), 1)
    }

    func testLiftedFramingsSitAboveTheRoom() {
        let lift = Lift(spans: [LiftSpan(start: 0, end: nil)])
        let c = tour(lift: lift)
        guard let lifted = c.lifted else { return XCTFail("no lifted framings") }
        let room = lift.safe(.reel).rect
        let frame = ShotFrame.whole(margin: 0)
        let corners = [Vec2(frame.minU, frame.minV), Vec2(frame.maxU, frame.minV), Vec2(frame.minU, frame.maxV), Vec2(frame.maxU, frame.maxV)]
            .map { Vec3(($0.x - 0.5) * A, 0.5 - $0.y, 0) }
        // The whole slide, at the opening, sits in the part above the room.
        guard let box = lifted[0].pose.bounds(of: corners, canvasAspect: C) else { return XCTFail() }
        XCTAssertLessThanOrEqual(box.w, room.w + 0.02)
        XCTAssertGreaterThanOrEqual(box.y, room.y - 0.02)
        // And the camera is on those framings throughout.
        let t = c.beats[2].land + 0.5
        XCTAssertEqual(c.basePose(at: t).target.y, c.lifted?[2].pose.target.y ?? 0, accuracy: c.beats[2].pose.height * 0.05)
        XCTAssertNotEqual(c.beats[2].pose.target.y, lifted[2].pose.target.y, accuracy: 1e-4)
    }

    func testRisingMidTourHasNoJumps() {
        let lift = Lift(spans: [LiftSpan(start: 4.5, end: 10.2), LiftSpan(start: 13, end: nil)])
        for cover in [false, true] {
            let c = tour(cover: cover, lift: lift, titleRoom: 0.12)
            let check = MotionCheck(c)
            print(check.summary)
            XCTAssertTrue(check.problems.isEmpty, "\(check.problems)")
            XCTAssertFalse(check.lifts.isEmpty)
            // Halfway up, the camera is between the two framings.
            let mid = c.basePose(at: 4.5 + Lift.rise / 2)
            XCTAssertGreaterThan(c.liftAmount(at: 4.5 + Lift.rise / 2), 0.2)
            XCTAssertLessThan(c.liftAmount(at: 4.5 + Lift.rise / 2), 0.9)
            XCTAssertTrue(mid.target.y.isFinite)
        }
        let three = threeSlides(home: true, lift: lift)
        XCTAssertTrue(MotionCheck(three).problems.isEmpty, "\(MotionCheck(three).problems)")
    }

    func testChangesAddTimeForThemselves() {
        let plain = tour().duration
        let turned = tour(cover: true).duration
        XCTAssertGreaterThan(turned, plain + PageChange.turn.length + Choreography.coverRest)
        let none = choreography([], pages: [PageTiming(id: second, aspect: A)]).duration
        XCTAssertGreaterThan(none, Arrive().end + 1.6 + PageChange.turn.length + 2)
    }
}
