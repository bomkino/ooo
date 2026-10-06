import Foundation
import Metal
import OOOMotion
import RenderCore
import StageKit
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
        // Mid-move into the first landing, and well into its hold.
        let move = try samples(at: (beats[1].depart + beats[1].land) / 2)
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
}
