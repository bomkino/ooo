import Foundation
import OOOMotion
import XCTest
@testable import OOOCore

/// A live take as the project keeps it: you in the room, every file saved,
/// and the video it leaves.
final class LiveCoreTests: XCTestCase {
    func testYouInTheRoomNeedsOOO11() throws {
        var filmed = OOOProject.sample
        filmed.face = FaceClip(file: "you.mov", duration: 20, aspect: 16.0 / 9.0, mirrored: true)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectPackage.encode(filmed)) as? [String: Any])
        XCTAssertEqual(j["minimumReaderVersion"] as? Int, 4)
        XCTAssertEqual(OOOProject.readerVersion, 4)
        XCTAssertEqual(try ProjectPackage.decode(ProjectPackage.encode(filmed)), filmed)
    }

    /// Saving keeps every slide's file, the voiceover's and the camera's: 1.0.1
    /// and 1.0.2 kept only the first slide's.
    func testEveryFileTheVideoUsesIsSaved() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ooo-live-\(UUID().uuidString)", isDirectory: true)
        let media = dir.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let names = ["one.png", "two.png", "three.pdf", "voice.m4a", "you.mov"]
        for n in names { try Data(n.utf8).write(to: media.appendingPathComponent(n)) }
        var p = OOOProject(slide: SlideRef(kind: .image, file: "one.png", aspect: 2576.0 / 1080, name: "One"))
        p.pages = [Page(slide: SlideRef(kind: .image, file: "two.png", aspect: 16.0 / 9.0, name: "Two")),
                   Page(slide: SlideRef(kind: .pdf, file: "three.pdf", aspect: 16.0 / 9.0, name: "Three"))]
        p.voice = Voiceover(file: "voice.m4a", name: "Live take", duration: 20)
        p.face = FaceClip(file: "you.mov", duration: 20, aspect: 16.0 / 9.0)
        XCTAssertEqual(Set(p.mediaFiles), Set(names))
        let package = dir.appendingPathComponent("Take.ooo")
        try ProjectPackage.write(p, media: media, to: package)
        let saved = try fm.contentsOfDirectory(atPath: package.appendingPathComponent(ProjectPackage.mediaFolder).path)
        XCTAssertEqual(Set(saved), Set(names))
    }

    /// The camera's picture fills the room: the middle of a wide one, the
    /// upper middle of a tall one, always the room's own shape.
    func testThePictureFillsTheRoom() {
        let C: Float = 9.0 / 16, room = Lift.defaultRoom
        let band = C / room
        let wide = FaceClip.crop(pictureAspect: 16.0 / 9.0, canvasAspect: C, room: room)
        XCTAssertEqual((wide.z - wide.x) * 16.0 / 9.0 / (wide.w - wide.y), band, accuracy: 1e-4)
        XCTAssertEqual(wide.x + wide.z, 1, accuracy: 1e-5)
        XCTAssertEqual(wide.y, 0)
        let tall = FaceClip.crop(pictureAspect: 0.75, canvasAspect: C, room: room)
        XCTAssertEqual((tall.z - tall.x) * 0.75 / (tall.w - tall.y), band, accuracy: 1e-4)
        XCTAssertLessThan(tall.y, 1 - tall.w, "a tall picture keeps more above the middle, where the face is")
        XCTAssertGreaterThanOrEqual(tall.y, 0)
    }

    /// While you talk: no old voice, no old marks, and the stage up to leave
    /// you the room. Afterwards: the moves at your moments, your voice and
    /// you, the stage settling as you go, and the ending once you've finished.
    func testATakeBecomesTheVideo() throws {
        var before = OOOProject.sample
        before.voice = Voiceover(file: "old.m4a", name: "Old", duration: 12)
        before.marks = [Mark(time: 4, strokes: [[InkPoint(x: 0.2, y: 0.3, t: 0), InkPoint(x: 0.5, y: 0.32, t: 0.6)]])]
        let stage = before.liveStage(filming: true)
        XCTAssertNil(stage.voice)
        XCTAssertNil(stage.marks)
        XCTAssertEqual(stage.lift?.spans.first?.start, 0)
        XCTAssertNil(stage.lift?.spans.first?.end)
        var take = LiveTake(stage.choreographyInput)
        for t in [3.5, 7.0, 10.5] { take.step(.next, at: t) }
        let end = 14.0
        let voice = Voiceover(file: "take.m4a", name: "Live take", duration: end + 0.1)
        let face = FaceClip(file: "you.mov", duration: end + 0.1, aspect: 16.0 / 9.0, mirrored: true)
        let kept = stage.taken(take, end: end, voice: voice, face: face)
        XCTAssertEqual(kept.voice, voice)
        XCTAssertEqual(kept.face, face)
        XCTAssertEqual(kept.neededReader, 4)
        let c = kept.choreography()
        for d in take.departures where d.id != nil {
            XCTAssertEqual(c.beats.first { $0.shot.id == d.id }?.depart ?? -1, d.at, accuracy: 1e-3)
        }
        // Up while you talk, down once you've gone.
        XCTAssertEqual(c.liftAmount(at: end - 1), 1, accuracy: 1e-3)
        XCTAssertEqual(c.liftAmount(at: kept.duration - 0.05), 0, accuracy: 1e-3)
        XCTAssertGreaterThan(kept.duration, end + Lift.rise)
        if let pull = c.beats.first(where: { $0.role == .pullBack }) { XCTAssertGreaterThanOrEqual(pull.depart, end) }
        // A take without the camera leaves no one in the room.
        let voiceOnly = before.liveStage(filming: false).taken(take, end: end, voice: voice, face: nil)
        XCTAssertNil(voiceOnly.face)
        XCTAssertEqual(voiceOnly.lift, before.lift)
    }
}
