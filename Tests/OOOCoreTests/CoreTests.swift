import CoreGraphics
import Foundation
import Metal
import OOOMotion
import RenderCore
import StageKit
import simd
import XCTest
@testable import OOOCore

/// Checks that need the Mac: documents, the engine's motion measure, and
/// rendering on the GPU.
final class CoreTests: XCTestCase {
    func testOlderDocumentsStandOnTheSoftFloor() throws {
        let data = try ProjectPackage.encode(.sample)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "floor")
        let old = try ProjectPackage.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.floor)
        XCTAssertEqual(old.floorKind, .soft)
        var chosen = old
        chosen.floor = FloorKind.none
        XCTAssertEqual(try ProjectPackage.decode(ProjectPackage.encode(chosen)).floorKind, FloorKind.none)
    }

    func testAFileFromANewerOOOIsRefusedNotMisread() throws {
        let data = try ProjectPackage.encode(.sample)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["minimumReaderVersion"] as? Int, 1, "a file 0.2 can draw still opens there")
        // One that uses what 0.2 can't draw says so, and 0.2 refuses it with a message.
        var woven = OOOProject.sample
        woven.arrive = Arrive(kind: .weave)
        var typed = OOOProject.sample
        typed.title = OpeningTitle(text: "One slide", kicker: "pitch.dog", kickerCaps: false)
        for p in [woven, typed] {
            let j = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectPackage.encode(p)) as? [String: Any])
            XCTAssertEqual(j["minimumReaderVersion"] as? Int, 2)
            XCTAssertEqual(try ProjectPackage.decode(ProjectPackage.encode(p)), p)
        }
        json["minimumReaderVersion"] = OOOProject.readerVersion + 1
        json["arrive"] = ["kind": "somethingNew"]
        XCTAssertThrowsError(try ProjectPackage.decode(JSONSerialization.data(withJSONObject: json))) { error in
            XCTAssertNotNil(error as? ProjectPackage.PackageError)
        }
        // Files from before the guard still open.
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "minimumReaderVersion")
        XCTAssertNoThrow(try ProjectPackage.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testACoverOrRoomForYouNeedsOOO101() throws {
        var covered = OOOProject.sample
        covered.cover = Cover(slide: .sample, turn: covered.defaultCoverTurn)
        var lifted = OOOProject.sample
        lifted.lift = Lift(spans: [LiftSpan(start: 3, end: 9)])
        for p in [covered, lifted] {
            let j = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectPackage.encode(p)) as? [String: Any])
            XCTAssertEqual(j["minimumReaderVersion"] as? Int, 3)
            XCTAssertEqual(try ProjectPackage.decode(ProjectPackage.encode(p)), p)
        }
        // Room for you with no stretches left asks nothing of an older OOO.
        lifted.lift?.spans = []
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectPackage.encode(lifted)) as? [String: Any])
        XCTAssertEqual(j["minimumReaderVersion"] as? Int, 1)
    }

    /// The cover is up until it turns, the slide after, and the cover again
    /// once it has turned back; the faces swap only as the card passes
    /// edge-on to the eye, so neither ever shows its back, and the card
    /// lands exactly where the slide rests.
    func testTheCoverTurnsOverEdgeOn() throws {
        var p = OOOProject.sample
        p.cover = Cover(slide: .sample, turn: p.defaultCoverTurn)
        p.makeRoomForOpening()
        let scene = try SlideLoader.scene(for: p, media: nil)
        XCTAssertNotNil(scene.cover)
        let c = scene.choreography
        XCTAssertEqual(c.turns.count, 2)
        XCTAssertGreaterThanOrEqual(c.beats[1].depart, c.turns[0].end, "the tour waits for the turn")
        let C = p.canvasAspect
        func card(_ t: Double) -> CardPose { scene.stageFrame(at: t, canvasAspect: C, outputWidth: 1080, patch: nil).cards[0] }
        XCTAssertEqual(card(c.turns[0].start - 0.1).media, 2, "the cover is up before it turns")
        XCTAssertEqual(card(c.turns[0].end + 0.5).media, 0, "the slide is up after")
        XCTAssertEqual(card(c.turns[1].end + 0.2).media, 2, "and the cover again once it has turned back")
        XCTAssertEqual(scene.slideShown(at: c.turns[0].start), 0)
        XCTAssertEqual(scene.slideShown(at: c.turns[0].end + 0.5), 1, accuracy: 1e-4)
        for turn in c.turns {
            var last = card(turn.start + 1e-3).media
            var swaps = 0
            for t in stride(from: turn.start + 1e-3, to: turn.end, by: 1.0 / 480) {
                let k = card(t)
                if k.media != last {
                    swaps += 1
                    let n = Matrix.rotationEuler(k.rotation) * SIMD4<Float>(0, 0, 1, 0)
                    let eye = c.pose(at: t).eye
                    let to = simd_normalize(SIMD3(eye.x, eye.y, eye.z) - k.position)
                    XCTAssertLessThan(abs(simd_dot(SIMD3(n.x, n.y, n.z), to)), 0.06, "faces swapped away from edge-on at \(t)")
                }
                last = k.media
            }
            XCTAssertEqual(swaps, 1, "one swap a turn")
            // It lands where it rests: no step as the turn ends.
            let a = card(turn.end - 1e-3), b = card(turn.end + 1e-3)
            XCTAssertEqual(simd_length(a.position - b.position), 0, accuracy: 2e-3)
            XCTAssertEqual(a.rotation.y, b.rotation.y, accuracy: 2e-3)
            XCTAssertEqual(a.size.x, b.size.x, accuracy: 1e-4)
        }
    }

    func testTheSurfaceStepsBackWhileTheSlideIsRead() throws {
        let scene = try SlideLoader.scene(for: .sample, media: nil)
        let c = scene.choreography
        guard c.beats.count > 2 else { return XCTFail() }
        let b = c.beats[1]
        XCTAssertEqual(scene.surfaceAmount(at: b.land + min(0.6, b.hold / 2)), SlideScene.surfaceAtRest, accuracy: 0.05)
        XCTAssertEqual(scene.surfaceAmount(at: (b.depart + b.land) / 2), 1, accuracy: 1e-4)
    }

    func testTheBackdropLoopsInWholeCycles() throws {
        let scene = try SlideLoader.scene(for: .sample, media: nil)
        let fps = Double(scene.project.fps)
        let n = Int((scene.duration * fps).rounded())
        let end = scene.backdropPhase(at: Double(n) / fps)
        XCTAssertEqual(end, end.rounded(), accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(end, 1)
    }

    func testAPictureIsSharpToTwiceItsPixels() {
        let ref = SlideRef(kind: .image, aspect: 2576.0 / 1080, name: "wide", pixelWidth: 2576, pixelHeight: 1080)
        // 1080 px drawn at 2160 fills a 1920 px canvas when the view is 0.89 slide heights tall.
        XCTAssertEqual(ref.sharpViewHeight(canvasHeight: 1920) ?? 0, 1920.0 / 2160, accuracy: 1e-4)
        XCTAssertNil(SlideRef.sample.sharpViewHeight(canvasHeight: 1920))
    }

    func testTheOpeningFollowsTheCanvasUnlessSetByHand() {
        var p = OOOProject(slide: SlideRef(kind: .image, aspect: 2576.0 / 1080, name: "wide", pixelWidth: 2576, pixelHeight: 1080))
        let tall = p.overview.yaw
        let (A, C) = (p.slideAspect, p.canvasAspect)
        p.format = .landscape
        p.adaptOverview(fromSlideAspect: A, canvasAspect: C)
        XCTAssertNotEqual(p.overview.yaw, tall, "a wide slide in a wide frame turns less")
        p.overview.yaw = -5
        let (A2, C2) = (p.slideAspect, p.canvasAspect)
        p.format = .reel
        p.adaptOverview(fromSlideAspect: A2, canvasAspect: C2)
        XCTAssertEqual(p.overview.yaw, -5, "an opening set by hand stays")
    }

    func testReplacingTheSlideKeepsTheTourOnItsWords() {
        let wide = SlideRef(kind: .image, aspect: 2576.0 / 1080, name: "wide", pixelWidth: 2576, pixelHeight: 1080)
        var p = OOOProject(slide: wide)
        let headline = SlideDetail(frame: ShotFrame(center: Vec2(0.3, 0.22), size: Vec2(0.4, 0.08)), text: "Revenue grew 3.1× this year.")
        let footnote = SlideDetail(frame: ShotFrame(center: Vec2(0.8, 0.93), size: Vec2(0.3, 0.02)), text: "Source: billing export. Unaudited.")
        let close = Shot(time: 3, frame: ShotFrame(center: Vec2(0.3, 0.22), size: Vec2(0.5, 0.3)), label: "Revenue grew 3.1× this year.",
                         focus: headline.frame)
        let mine = Shot(time: 6, frame: ShotFrame(center: Vec2(0.6, 0.6), size: Vec2(0.3, 0.3)), label: "Mine")
        p.shots = [close, mine]
        p.reading = [headline, footnote]
        var moved = headline
        moved.text = "Revenue grew 3.4× this year."
        moved.frame.center.y += 0.1
        let fixed = SlideRef(kind: .image, aspect: 2576.0 / 1080, name: "wide v2", pixelWidth: 2576, pixelHeight: 1080)
        p.replaceSlide(with: fixed, reading: [moved, footnote], from: [headline, footnote])
        XCTAssertEqual(p.slide, fixed)
        XCTAssertEqual(p.reading, [moved, footnote])
        XCTAssertEqual(p.shots.map(\.id), [close.id, mine.id])
        XCTAssertEqual(p.shots.map(\.time), [3, 6])
        XCTAssertEqual(p.shots[0].frame.center.y, 0.32, accuracy: 1e-4, "the close-up follows its headline")
        XCTAssertEqual(p.shots[0].label, "Revenue grew 3.4× this year.", "a label that was the headline's words takes the new ones")
        XCTAssertEqual(p.shots[1], mine, "a framing about no one detail stays")
    }

    func testTheOpeningTitleClearsForTheTourAndReturnsForThePullBack() throws {
        var p = OOOProject.sample
        p.ending = .pullBack
        p.title = OpeningTitle(text: "One slide, obsessed over.")
        let first = try XCTUnwrap(p.shots.map(\.time).min())
        p.makeRoomForOpening()
        // The tour sets off once the title has been read, and waits only once.
        XCTAssertEqual(p.choreography().beats[1].depart, p.tourStart, accuracy: 0.05)
        XCTAssertEqual(p.titleHold, 0.7 + 0.26 * 4, accuracy: 1e-9, "four words take a little under two seconds")
        XCTAssertGreaterThan(p.shots.map(\.time).min() ?? 0, first)
        let moved = p.shots
        p.makeRoomForOpening()
        XCTAssertEqual(p.shots, moved)
        let c = p.choreography()
        let beats = c.beats
        XCTAssertGreaterThan(beats.count, 2)
        XCTAssertEqual(OpeningTitleArt.presence(c, at: 0).alpha, 0)
        // Fully there from just after the slide lands until the tour sets off.
        XCTAssertEqual(OpeningTitleArt.presence(c, at: beats[0].land + 0.4).alpha, 1, accuracy: 1e-3)
        XCTAssertEqual(OpeningTitleArt.presence(c, at: beats[1].depart).alpha, 1, accuracy: 1e-3)
        XCTAssertEqual(OpeningTitleArt.presence(c, at: beats[1].depart + 0.6).alpha, 0, accuracy: 1e-3)
        XCTAssertEqual(OpeningTitleArt.presence(c, at: (beats[1].land + beats[1].leave) / 2).alpha, 0, accuracy: 1e-3)
        XCTAssertEqual(OpeningTitleArt.presence(c, at: c.duration).alpha, 1, accuracy: 1e-3)
        // In a Reel it sits in the clear band above the slide, below the profile.
        let opening = try XCTUnwrap(beats.first?.pose)
        let band = OpeningTitleArt.band(opening: opening, slideAspect: p.slideAspect, canvasAspect: p.canvasAspect, safe: .reel)
        XCTAssertGreaterThanOrEqual(band.top, SafeArea.reel.top)
        XCTAssertGreaterThan(band.bottom - band.top, 0.07)
        XCTAssertLessThan(band.bottom, 0.45)
        XCTAssertNotNil(OpeningTitleArt.draw(p.title!, width: 540, height: 960, band: band, lightInk: true))
    }

    /// The sample every window opens on moves within the limits Direct for Me keeps to.
    func testTheSampleNeverRushes() {
        let check = MotionCheck(OOOProject.sample.choreography())
        XCTAssertTrue(check.problems.isEmpty, check.summary)
    }

    func testTravelMeasuresWhatMovesOnTheCanvas() {
        var a = StageFrame()
        a.cards = [CardPose(media: 0, occurrence: 0, position: .zero, rotation: .zero, size: SIMD2(16.0 / 9, 1))]
        XCTAssertEqual(a.travel(to: a, width: 1080, height: 1920), 0, accuracy: 1e-4)
        // The camera slides along by a hundredth of the view's height.
        var b = a
        b.camera.offset.x += 0.01
        b.camera.target.x += 0.01
        let visibleHeight = 2 * tanf(a.camera.fov * .pi / 360) * StageCamera.distance(fov: a.camera.fov)
        XCTAssertEqual(b.travel(to: a, width: 1080, height: 1920), 0.01 / visibleHeight * 1920, accuracy: 0.5)
        // Cards that bend between the two can't be compared by their outline.
        var c = a
        c.cards[0].curl = 0.3
        XCTAssertEqual(c.travel(to: a, width: 1080, height: 1920), .infinity)
    }

    func testMotionBlurTakesOneSampleWhileTheCameraHolds() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No GPU") }
        let project = OOOProject.sample
        let scene = try SlideLoader.scene(for: project, media: nil)
        let stage = try SlideStage()
        let out = GPU.shared.makeTexture(width: 270, height: 480, format: .bgra8Unorm)
        func samples(at t: Double) throws -> Int {
            let cb = try XCTUnwrap(GPU.shared.queue.makeCommandBuffer())
            let n = try stage.encode(cb, scene: scene, at: t, output: out, samples: 10, frameIndex: 0, waitForDetail: true)
            cb.commit()
            cb.waitUntilCompleted()
            return n
        }
        let beats = scene.choreography.beats
        XCTAssertGreaterThan(beats.count, 2)
        // The fastest part of the move into the first landing, and well into its hold.
        let move = try (1...5).map { try samples(at: beats[1].depart + Double($0) / 6 * (beats[1].land - beats[1].depart)) }.max() ?? 0
        let hold = try samples(at: beats[1].land + 0.7 * (beats[1].leave - beats[1].land))
        XCTAssertGreaterThan(move, 4)
        XCTAssertLessThanOrEqual(hold, 2)
        // Off, every frame takes the most it may.
        let cb = try XCTUnwrap(GPU.shared.queue.makeCommandBuffer())
        let full = try stage.encode(cb, scene: scene, at: beats[1].land + 0.7 * (beats[1].leave - beats[1].land), output: out,
                                    samples: 10, frameIndex: 0, waitForDetail: true, adaptive: false)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(full, 10)
    }

    /// A Weave's threads come from the project's seed: every export of a
    /// frame is the same, and another seed weaves another way.
    func testAWeaveIsTheSameEveryTime() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No GPU") }
        var project = OOOProject.sample
        project.arrive = Arrive(kind: .weave)
        let scene = try SlideLoader.scene(for: project, media: nil)
        let stage = try SlideStage()
        let t = project.arrive.duration * 0.45
        func bytes(_ image: CGImage) -> [UInt8] { [UInt8]((image.dataProvider?.data as Data?) ?? Data()) }
        // The first frame a new stage draws sets up its targets; the frames after it are what an export is made of.
        let first = try bytes(stage.still(scene, at: t, width: 270, height: 480))
        let a = try bytes(stage.still(scene, at: t, width: 270, height: 480))
        let b = try bytes(stage.still(scene, at: t, width: 270, height: 480))
        let changed = zip(first, a).filter { $0 != $1 }.count, most = zip(first, a).map { abs(Int($0) - Int($1)) }.max() ?? 0
        print("weave replay: the first frame differs from the next in \(changed) of \(a.count) bytes, by up to \(most)")
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b, "the same frame drawn twice")
        let threads = scene.stageFrame(at: t, canvasAspect: project.canvasAspect, outputWidth: 270, patch: nil).cards
        XCTAssertGreaterThan(threads.count, 2, "mid-weave, the slide is threads")
        XCTAssertEqual(scene.stageFrame(at: project.arrive.duration, canvasAspect: project.canvasAspect, outputWidth: 270, patch: nil).cards.count, 1,
                       "once woven, it is one slide again")
        project.seed = 7
        let other = try SlideLoader.scene(for: project, media: nil)
        XCTAssertNotEqual(other.stageFrame(at: t, canvasAspect: project.canvasAspect, outputWidth: 270, patch: nil).cards.map(\.position),
                          threads.map(\.position))
    }
}
