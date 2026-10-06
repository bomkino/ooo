import Foundation
import XCTest
@testable import OOOMotion

final class EaseTests: XCTestCase {
    func testEasesStartAndEndAndNeverGoBack() {
        for kind in EaseKind.allCases {
            let c = kind.curve
            XCTAssertEqual(c.value(0), 0, accuracy: 1e-6, "\(kind)")
            XCTAssertEqual(c.value(1), 1, accuracy: 1e-6, "\(kind)")
            var last: Float = -1
            for i in 0...400 {
                let v = c.value(Float(i) / 400)
                XCTAssertGreaterThanOrEqual(v, last - 1e-6, "\(kind) goes backwards at \(i)")
                last = v
            }
            // Lifts off from rest, lands still moving but slowly.
            XCTAssertEqual(c.slope(0), 0, accuracy: 1e-6)
            XCTAssertGreaterThan(c.landingSpeed, 0)
            XCTAssertLessThan(c.landingSpeed, 0.6, "\(kind) lands too fast")
        }
    }

    func testSlopeMatchesValue() {
        let c = EaseKind.glide.curve
        for u in stride(from: Float(0.05), to: 0.95, by: 0.1) {
            let h: Float = 1e-3
            let numeric = (c.value(u + h) - c.value(u - h)) / (2 * h)
            XCTAssertEqual(numeric, c.slope(u), accuracy: 0.02)
        }
    }

    func testSpringsLandExactly() {
        XCTAssertEqual(Curves.spring(1), 1, accuracy: 1e-6)
        XCTAssertEqual(Curves.spring(0), 0, accuracy: 1e-4)
        XCTAssertEqual(Curves.approach(1), 1, accuracy: 1e-6)
        XCTAssertEqual(Curves.approach(0), 0, accuracy: 1e-6)
        // A spring with some bounce overshoots a little, never a lot.
        let peak = (0...200).map { Curves.spring(Float($0) / 200, bounce: 0.3) }.max()!
        XCTAssertGreaterThan(peak, 1.0)
        XCTAssertLessThan(peak, 1.25)
    }
}

final class ZoomPathTests: XCTestCase {
    func testEndpoints() {
        let p = ZoomPath(from: Vec2(-0.6, 0.2), w0: 2.4, to: Vec2(0.5, -0.3), w1: 0.3, rho: 1.4)
        let a = p.at(0), b = p.at(1)
        XCTAssertEqual(a.center.x, -0.6, accuracy: 1e-4)
        XCTAssertEqual(a.w, 2.4, accuracy: 1e-4)
        XCTAssertEqual(b.center.x, 0.5, accuracy: 1e-3)
        XCTAssertEqual(b.center.y, -0.3, accuracy: 1e-3)
        XCTAssertEqual(b.w, 0.3, accuracy: 1e-3)
        XCTAssertGreaterThan(p.length, 0)
    }

    func testDistantDetailsPullOutBetween() {
        // Two close-ups far apart: the path rises above both.
        let p = ZoomPath(from: Vec2(-0.7, 0), w0: 0.2, to: Vec2(0.7, 0), w1: 0.2, rho: 1.4)
        let mid = p.at(0.5)
        XCTAssertGreaterThan(mid.w, 0.6)
    }

    func testPureZoom() {
        let p = ZoomPath(from: Vec2(0.1, 0.1), w0: 2, to: Vec2(0.1, 0.1), w1: 0.25, rho: 1.4)
        XCTAssertEqual(p.at(1).w, 0.25, accuracy: 1e-4)
        XCTAssertEqual(p.at(0.5).w, (2 * 0.25 as Float).squareRoot(), accuracy: 1e-3)
    }
}

final class ChoreographyTests: XCTestCase {
    let A: Float = 16.0 / 9.0
    let C: Float = 9.0 / 16.0

    func sample(_ moves: [MoveKind] = [.glide, .push, .arc, .glide], ending: Ending = .pullBack) -> Choreography {
        let frames = [ShotFrame(center: Vec2(0.2, 0.25), size: Vec2(0.2, 0.3)),
                      ShotFrame(center: Vec2(0.8, 0.7), size: Vec2(0.15, 0.2)),
                      ShotFrame(center: Vec2(0.5, 0.5), size: Vec2(0.5, 0.5)),
                      ShotFrame(center: Vec2(0.9, 0.1), size: Vec2(0.06, 0.08))]
        var shots: [Shot] = []
        for (i, f) in frames.enumerated() {
            shots.append(Shot(time: 3.5 + Double(i) * 2.6, frame: f, yaw: Float(i) * 6 - 8, pitch: 4,
                              move: moves[i % moves.count], ease: EaseKind.allCases[i % 4], breathe: 0.6))
        }
        let input = ChoreographyInput(overview: .overview(), shots: shots, arrive: Arrive(kind: .rise), ending: ending,
                                      duration: 16, slideAspect: A, canvasAspect: C, style: MotionStyle())
        return Choreography(input)
    }

    func testLandsOnEachFraming() {
        let c = sample()
        for beat in c.beats {
            // Once the hold has bled away the last of the move, the camera is on the framing.
            let settled = c.basePose(at: min(beat.land + min(beat.hold * 0.98, 4), c.duration))
            let expect = beat.pose
            let breathed = expect.height * expf(-beat.breathe)
            XCTAssertEqual(settled.target.x, expect.target.x, accuracy: expect.height * 0.02, "beat at \(beat.land)")
            XCTAssertEqual(settled.target.y, expect.target.y, accuracy: expect.height * 0.02)
            XCTAssertLessThanOrEqual(settled.height, expect.height * 1.02)
            XCTAssertGreaterThanOrEqual(settled.height, breathed * 0.98)
            // At the landing itself it is all but there.
            let landed = c.basePose(at: beat.land)
            XCTAssertEqual(landed.target.x, expect.target.x, accuracy: max(expect.height, 0.05) * 0.25)
        }
    }

    func testNoJumpsAnywhere() {
        let c = sample()
        let dt = 1.0 / 240
        var prev = c.pose(at: 0)
        var prevV: Vec3? = nil
        var t = dt
        while t <= c.duration {
            let p = c.pose(at: t)
            // Position change relative to the view: never more than a sliver per step.
            let dx = (p.target - prev.target).length / max(p.height, 1e-3)
            let dz = abs(logf(p.height / prev.height))
            XCTAssertLessThan(dx, 0.06, "jump in pan at \(t)")
            XCTAssertLessThan(dz, 0.06, "jump in zoom at \(t)")
            XCTAssertLessThan(abs(p.yaw - prev.yaw), radians(1.5), "jump in yaw at \(t)")
            // Speed is continuous: no sudden change of velocity between steps.
            let v = Vec3((p.target.x - prev.target.x) / p.height, (p.target.y - prev.target.y) / p.height, logf(p.height / prev.height)) / Float(dt)
            if let pv = prevV {
                XCTAssertLessThan((v - pv).length, 0.6, "velocity kink at \(t)")
            }
            prevV = v
            prev = p
            t += dt
        }
    }

    func testHoldsOnlyEverSlowDown() {
        // Without a breath, the camera never speeds up once it has landed.
        let frames = [ShotFrame(center: Vec2(0.2, 0.3), size: Vec2(0.2, 0.3)),
                      ShotFrame(center: Vec2(0.75, 0.6), size: Vec2(0.1, 0.12)),
                      ShotFrame(center: Vec2(0.5, 0.5), size: Vec2(0.6, 0.6))]
        for ease in EaseKind.allCases {
            let shots = frames.enumerated().map { i, f in
                Shot(time: 3.4 + Double(i) * 1.9, frame: f, move: .glide, ease: ease, breathe: 0)
            }
            var overview = Shot.overview()
            overview.breathe = 0
            let c = Choreography(ChoreographyInput(overview: overview, shots: shots, arrive: Arrive(kind: .rise), ending: .hold,
                                                   duration: 11, slideAspect: A, canvasAspect: C, style: MotionStyle()))
            for beat in c.beats where beat.hold > 0.1 {
                let dt = beat.hold / 200
                func speed(_ t: Double) -> Float {
                    let a = c.basePose(at: t), b = c.basePose(at: t + dt)
                    let pan = (b.target - a.target).length / a.height
                    return (pan * pan + powf(logf(b.height / a.height), 2)).squareRoot() / Float(dt)
                }
                var last = speed(beat.land)
                var t = beat.land + dt
                while t < beat.leave - dt {
                    let v = speed(t)
                    XCTAssertLessThanOrEqual(v, last * 1.001 + 1e-4, "\(ease) speeds up in the hold at \(t)")
                    last = v
                    t += dt
                }
            }
        }
    }

    func testAutoTravelRespectsPeakRate() {
        let a = CameraPose(shot: Shot(time: 0, frame: ShotFrame(center: Vec2(0.5, 0.5), size: Vec2(0.6, 0.6))), slideAspect: A, canvasAspect: C)
        let b = CameraPose(shot: Shot(time: 0, frame: ShotFrame(center: Vec2(0.85, 0.2), size: Vec2(0.03, 0.04))), slideAspect: A, canvasAspect: C)
        let style = MotionStyle()
        for ease in EaseKind.allCases {
            let T = Choreography.autoTravel(from: a, to: b, ease: ease, style: style, canvasAspect: C)
            guard T < 3.999 else { continue }   // the longest move allowed wins over the cap
            let path = ZoomPath(from: a.target, w0: a.height * C.squareRoot(), to: b.target, w1: b.height * C.squareRoot(), rho: style.rho)
            let peak = Double(style.rho) * path.length * Double(ease.curve.peakSlope) / T
            XCTAssertLessThanOrEqual(peak, Choreography.peakRate * 1.01 / Double(style.paceScale), "\(ease)")
        }
    }

    func testCutsJumpOnlyOnTheirMoment() {
        let c = sample([.cut])
        let cutBeat = c.beats.first { $0.shot.move == .cut && !$0.isOverview }!
        XCTAssertEqual(c.cut(between: cutBeat.land - 0.01, and: cutBeat.land + 0.01), cutBeat.land)
        XCTAssertNil(c.cut(between: cutBeat.land + 0.01, and: cutBeat.land + 0.2))
        let after = c.basePose(at: cutBeat.land + 1e-4)
        XCTAssertEqual(after.target.x, cutBeat.pose.target.x, accuracy: 1e-3)
    }

    func testTravelNeverOverlapsTheLastLanding() {
        var shots: [Shot] = []
        for i in 0..<6 {
            shots.append(Shot(time: 2.2 + Double(i) * 0.4, frame: ShotFrame(center: Vec2(Float(i) / 6, 0.5), size: Vec2(0.1, 0.1))))
        }
        let c = Choreography(ChoreographyInput(overview: .overview(), shots: shots, arrive: Arrive(kind: .rise, duration: 2), ending: .hold,
                                               duration: 6, slideAspect: A, canvasAspect: C, style: MotionStyle()))
        for i in 1..<c.beats.count {
            XCTAssertGreaterThanOrEqual(c.beats[i].depart, c.beats[i - 1].land - 1e-9)
            XCTAssertLessThanOrEqual(c.beats[i].depart, c.beats[i].land)
        }
    }

    func testFramingRoundTrips() {
        let f = ShotFrame(center: Vec2(0.3, 0.6), size: Vec2(0.25 * C / A * 2, 0.5))
        let pose = CameraPose(shot: Shot(time: 0, frame: f), slideAspect: A, canvasAspect: C)
        let back = pose.frame(slideAspect: A, canvasAspect: C)
        XCTAssertEqual(back.center.x, 0.3, accuracy: 1e-5)
        XCTAssertEqual(back.center.y, 0.6, accuracy: 1e-5)
        XCTAssertEqual(back.size.y, f.visible(slideAspect: A, canvasAspect: C).size.y, accuracy: 1e-5)
    }

    func testFootprintMatchesFraming() {
        // Square on, the footprint is the framing widened to the canvas.
        let f = ShotFrame(center: Vec2(0.4, 0.55), size: Vec2(0.1, 0.2))
        let pose = CameraPose(shot: Shot(time: 0, frame: f), slideAspect: A, canvasAspect: C)
        let fp = pose.footprint(slideAspect: A, canvasAspect: C, canvasHeight: 1920)
        let vis = f.visible(slideAspect: A, canvasAspect: C)
        XCTAssertEqual(fp.region.x, vis.minU, accuracy: 1e-3)
        XCTAssertEqual(fp.region.y, vis.minV, accuracy: 1e-3)
        XCTAssertEqual(fp.region.z, vis.maxU, accuracy: 1e-3)
        XCTAssertEqual(fp.region.w, vis.maxV, accuracy: 1e-3)
        XCTAssertEqual(fp.pixelsPerUnit, 1920 / pose.height, accuracy: 1920 / pose.height * 0.01)
        // Turned, the near side needs more detail than square on.
        var turned = pose
        turned.yaw = radians(25)
        XCTAssertGreaterThan(turned.footprint(slideAspect: A, canvasAspect: C, canvasHeight: 1920).pixelsPerUnit, fp.pixelsPerUnit)
    }

    func testArrivalsStartHiddenAndEndAtRest() {
        for kind in ArriveKind.allCases where kind != .none {
            let arrive = Arrive(kind: kind)
            let first = Arrival.slide(at: 0, arrive: arrive, canvasAspect: C)
            XCTAssertLessThan(first.opacity, 0.05, "\(kind)")
            let near = Arrival.slide(at: arrive.duration * 0.999, arrive: arrive, canvasAspect: C)
            XCTAssertLessThan(near.offset.length, 0.02, "\(kind) offset at the end")
            XCTAssertLessThan(abs(near.rotation.y), radians(1.5), "\(kind) yaw at the end")
            XCTAssertLessThan(abs(near.curl), 0.03, "\(kind) curl at the end")
            XCTAssertEqual(Arrival.slide(at: arrive.duration, arrive: arrive, canvasAspect: C), .rest)
        }
    }

    func testComposerFitsAFramingAtAnAngle() {
        let A: Float = 2576.0 / 1080
        let frame = ShotFrame.whole(margin: 0.06)
        for (yaw, pitch) in [(Float(0), Float(0)), (-34, 9), (20, -6)] {
            let shot = Shot(time: 0, frame: frame, yaw: yaw, pitch: pitch)
            let pose = CameraPose(shot: shot, slideAspect: A, canvasAspect: C, safe: .reel)
            let corners = [Vec2(frame.minU, frame.minV), Vec2(frame.maxU, frame.minV), Vec2(frame.minU, frame.maxV), Vec2(frame.maxU, frame.maxV)]
                .map { Vec3(($0.x - 0.5) * A, 0.5 - $0.y, 0) }
            guard let box = pose.bounds(of: corners, canvasAspect: C) else { return XCTFail() }
            let safe = SafeArea.reel.rect
            // Inside the clear part of a Reel, touching it on one side, and centred in it.
            XCTAssertGreaterThanOrEqual(box.x, safe.x - 1e-3, "yaw \(yaw)")
            XCTAssertLessThanOrEqual(box.z, safe.z + 1e-3, "yaw \(yaw)")
            XCTAssertGreaterThanOrEqual(box.y, safe.y - 1e-3, "yaw \(yaw)")
            XCTAssertLessThanOrEqual(box.w, safe.w + 1e-3, "yaw \(yaw)")
            let fill = max((box.z - box.x) / (safe.z - safe.x), (box.w - box.y) / (safe.w - safe.y))
            XCTAssertEqual(fill, 1, accuracy: 0.01, "yaw \(yaw)")
            XCTAssertEqual((box.x + box.z) / 2, (safe.x + safe.z) / 2, accuracy: 0.01, "yaw \(yaw)")
            XCTAssertEqual((box.y + box.w) / 2, (safe.y + safe.w) / 2, accuracy: 0.01, "yaw \(yaw)")
        }
        // Turned, a wide slide stands taller in a tall frame than seen flat.
        let flat = CameraPose(shot: Shot(time: 0, frame: frame), slideAspect: A, canvasAspect: C, safe: .reel)
        let turned = CameraPose(shot: Shot(time: 0, frame: frame, yaw: -34, pitch: 9), slideAspect: A, canvasAspect: C, safe: .reel)
        XCTAssertLessThan(turned.height, flat.height * 0.9)
    }

    func readingAlong() -> Choreography {
        let shots = [
            Shot(time: 3.5, frame: ShotFrame(center: Vec2(0.15, 0.25), size: Vec2(0.12, 0.4)), sweep: Vec2(0.3, 0), sweepTime: 2.2),
            Shot(time: 8, frame: ShotFrame(center: Vec2(0.7, 0.6), size: Vec2(0.2, 0.5)), breathe: 0.5),
        ]
        return Choreography(ChoreographyInput(overview: .overview(slideAspect: A, canvasAspect: C), shots: shots, arrive: Arrive(kind: .rise),
                                              ending: .pullBack, duration: 13, slideAspect: A, canvasAspect: C, style: MotionStyle(),
                                              safe: .reel))
    }

    func testReadingAlongGlidesFromStartToEnd() {
        let c = readingAlong()
        let beat = c.beats[1]
        guard let to = beat.sweepTo else { return XCTFail("no glide") }
        // It rests on the start of the line, then reads it in the time given.
        XCTAssertEqual(beat.sweepStart, beat.land + Choreography.readLead, accuracy: 1e-9)
        XCTAssertEqual(beat.sweepEnd, beat.sweepStart + 2.2, accuracy: 1e-9)
        let start = c.basePose(at: beat.sweepStart), end = c.basePose(at: beat.sweepEnd)
        XCTAssertEqual(start.target.x, beat.pose.target.x, accuracy: beat.pose.height * 0.05)
        XCTAssertEqual(c.basePose(at: beat.land + 0.01).target.x, beat.pose.target.x, accuracy: beat.pose.height * 0.05)
        XCTAssertEqual(end.target.x, to.target.x, accuracy: beat.pose.height * 0.05)
        XCTAssertGreaterThan(to.target.x - beat.pose.target.x, 0.3 * A * 0.9)
        // The next move leaves from where the glide ended.
        let next = c.beats[2]
        XCTAssertEqual(c.basePose(at: next.depart).target.x, to.target.x, accuracy: beat.pose.height * 0.05)
    }

    func testReadingAlongHasNoJumps() {
        let c = readingAlong()
        let dt = 1.0 / 240
        var prev = c.pose(at: 0)
        var prevV: Vec3?
        var t = dt
        while t <= c.duration {
            let p = c.pose(at: t)
            XCTAssertLessThan((p.target - prev.target).length / max(p.height, 1e-3), 0.06, "jump at \(t)")
            let v = Vec3((p.target.x - prev.target.x) / p.height, (p.target.y - prev.target.y) / p.height, logf(p.height / prev.height)) / Float(dt)
            if let pv = prevV { XCTAssertLessThan((v - pv).length, 0.6, "velocity kink at \(t)") }
            prevV = v
            prev = p
            t += dt
        }
    }

    func testPullBackRestsBeforeTheEnd() {
        let c = sample(ending: .pullBack)
        guard let back = c.beats.last, back.isOverview else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(c.duration - back.land, 1.0)
    }

    func testSettledWhileHoldingAndNotWhileTravelling() {
        let c = sample()
        for b in c.beats.dropFirst() where b.hold > 1.2 {
            XCTAssertEqual(c.settled(at: b.land + 0.6), 1, accuracy: 1e-4)
            XCTAssertEqual(c.settled(at: b.land - 0.01), 0, accuracy: 1e-4, "travelling into a beat")
            XCTAssertEqual(c.settled(at: b.leave - 0.001), 0, accuracy: 0.01, "about to leave")
        }
        // No jumps: it eases in and out.
        var prev = c.settled(at: 0)
        for t in stride(from: 0.0, to: c.duration, by: 1.0 / 120) {
            let v = c.settled(at: t)
            XCTAssertLessThan(abs(v - prev), 0.1, "jump at \(t)")
            prev = v
        }
    }

    func testEmphasisFallsBeforeALeaveSetsOff() {
        var shots = sample(ending: .leave).beats.dropFirst().map(\.shot)
        shots[shots.count - 1].emphasis = .spotlight
        let input = ChoreographyInput(overview: .overview(), shots: shots, arrive: Arrive(kind: .rise), ending: .leave,
                                      duration: 16, slideAspect: A, canvasAspect: C, style: MotionStyle())
        let c = Choreography(input)
        let leave = c.duration - Choreography.leaveLength
        XCTAssertGreaterThan(c.emphasis(at: leave - 1.0)?.amount ?? 0, 0.9)
        XCTAssertLessThan(c.emphasis(at: leave)?.amount ?? 0, 0.01)
        // Held to the end, it stays.
        let held = Choreography(ChoreographyInput(overview: .overview(), shots: shots, arrive: Arrive(kind: .rise), ending: .hold,
                                                  duration: 16, slideAspect: A, canvasAspect: C, style: MotionStyle()))
        XCTAssertGreaterThan(held.emphasis(at: held.duration - 0.05)?.amount ?? 0, 0.9)
    }
}
