import Foundation
import XCTest
@testable import OOOMotion

/// The cover turning over to the slide (and back), and the stage rising to
/// leave room for a talking head below it.
final class CoverLiftTests: XCTestCase {
    let A: Float = 2576.0 / 1080
    let C: Float = 9.0 / 16

    var shots: [Shot] {
        [Shot(time: 6, frame: ShotFrame(center: Vec2(0.2, 0.3), size: Vec2(0.18, 0.3)), breathe: 0.5),
         Shot(time: 9, frame: ShotFrame(center: Vec2(0.7, 0.55), size: Vec2(0.12, 0.2)), move: .arc),
         Shot(time: 12, frame: ShotFrame(center: Vec2(0.45, 0.8), size: Vec2(0.2, 0.25)))]
    }

    func tour(cover: CoverTiming? = nil, lift: Lift? = nil, ending: Ending = .hold, titleRoom: Float = 0) -> Choreography {
        let overview = Shot.overview(slideAspect: A, canvasAspect: C)
        let arrive = Arrive()
        // As the app does, the tour sets off once the cover has turned.
        let delay = Choreography.coverDelay(cover, arrive: arrive)
        let shots = self.shots.map { var s = $0; s.time += delay; return s }
        let d = Choreography.naturalDuration(shots: shots, arrive: arrive, ending: ending, cover: cover)
        return Choreography(ChoreographyInput(overview: overview, shots: shots, arrive: arrive, ending: ending, duration: d,
                                              slideAspect: A, canvasAspect: C, style: MotionStyle(), safe: .reel,
                                              cover: cover, lift: lift, titleRoom: titleRoom))
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

    func testTheCoverTurnsBeforeTheTourAndBackAtTheEnd() {
        let c = tour(cover: CoverTiming(turn: 1.6))
        XCTAssertEqual(c.turns.count, 2)
        let over = c.turns[0], back = c.turns[1]
        XCTAssertFalse(over.back)
        XCTAssertTrue(back.back)
        XCTAssertGreaterThanOrEqual(over.start, Arrive().end)
        // Nothing sets off before the slide has settled on its side.
        XCTAssertGreaterThanOrEqual(c.beats[1].depart, over.end + Choreography.turnSettle - 1e-9)
        // The camera is back on the whole slide, settled, before the card turns back,
        // and the cover rests a moment before the end.
        guard let last = c.beats.last else { return XCTFail() }
        XCTAssertEqual(last.shot.id, Choreography.backToCover)
        XCTAssertTrue(last.isOverview)
        XCTAssertEqual(back.start, last.land + Choreography.backLead, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(back.end + Choreography.coverRest, c.duration + 1e-6)
        XCTAssertGreaterThan(back.start, c.beats[c.beats.count - 2].land + 1)
        // While a turn runs, the camera does not travel: at most it breathes.
        for turn in c.turns {
            let a = c.basePose(at: turn.start), b = c.basePose(at: turn.end)
            XCTAssertEqual(a.target.x, b.target.x, accuracy: a.height * 0.01)
            XCTAssertEqual(a.height, b.height, accuracy: a.height * (turn.back ? 0.005 : 0.05))
        }
        let check = MotionCheck(c)
        XCTAssertTrue(check.problems.isEmpty, "\(check.problems)")
    }

    func testTheTurnBackLandsWhereItIsAsked() {
        let c = tour(cover: CoverTiming(turn: 2, backAt: 18))
        XCTAssertEqual(c.turns.last?.start ?? 0, 18, accuracy: 1e-9)
        // Without a turn back the tour ends as it would have, with the slide showing.
        let plain = tour(cover: CoverTiming(turn: 2, turnBack: false), ending: .pullBack)
        XCTAssertEqual(plain.turns.count, 1)
        XCTAssertNotEqual(plain.beats.last?.shot.id, Choreography.backToCover)
        XCTAssertTrue(plain.beats.last?.isOverview ?? false)
    }

    func testAnEarlyShotWaitsForTheTurn() {
        let cover = CoverTiming(turn: 4)
        var early = shots
        early[0].time = 3
        early[1].time = 11
        early[2].time = 14
        let c = Choreography(ChoreographyInput(overview: .overview(slideAspect: A, canvasAspect: C), shots: early, arrive: Arrive(),
                                               ending: .hold, duration: 24, slideAspect: A, canvasAspect: C, style: MotionStyle(),
                                               safe: .reel, cover: cover))
        XCTAssertGreaterThanOrEqual(c.beats[1].land, c.turns[0].end + Choreography.turnSettle + 0.6 - 1e-9)
        XCTAssertGreaterThanOrEqual(c.beats[1].travel, c.beats[1].wanted - 1e-9, "the first move is not rushed")
        XCTAssertGreaterThanOrEqual(c.beats[1].depart, c.turns[0].end + Choreography.turnSettle - 1e-9)
        XCTAssertTrue(MotionCheck(c).problems.isEmpty, "\(MotionCheck(c).problems)")
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
        for cover in [nil, CoverTiming(turn: 1.6)] {
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
    }

    func testCoverAddsTimeForTheTurns() {
        let arrive = Arrive()
        let plain = Choreography.naturalDuration(shots: shots, arrive: arrive, ending: .hold)
        let turned = Choreography.naturalDuration(shots: shots, arrive: arrive, ending: .hold, cover: CoverTiming(turn: 1.6))
        XCTAssertGreaterThan(turned, plain + Turn.length + Choreography.coverRest)
        let none = Choreography.naturalDuration(shots: [], arrive: arrive, ending: .hold, cover: CoverTiming(turn: 1.6, turnBack: false))
        XCTAssertGreaterThan(none, 1.6 + Turn.length + 2)
    }
}
