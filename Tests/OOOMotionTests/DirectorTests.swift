import Foundation
import XCTest
@testable import OOOMotion

final class DirectorTests: XCTestCase {
    let A: Float = 16.0 / 9.0
    let C: Float = 9.0 / 16.0

    /// The sample slide as text recognition reads it.
    var details: [SlideDetail] {
        func line(_ text: String, _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float) -> SlideDetail {
            SlideDetail(frame: ShotFrame(center: Vec2((u0 + u1) / 2, (v0 + v1) / 2), size: Vec2(u1 - u0, v1 - v0)), text: text)
        }
        return [
            line("04 THE DETAIL", 0.075, 0.135, 0.2, 0.152),
            line("Every pixel,", 0.07, 0.21, 0.37, 0.29),
            line("on purpose.", 0.07, 0.32, 0.36, 0.40),
            line("We spent a week on one chart, so the moment it turned would", 0.075, 0.455, 0.47, 0.482),
            line("read in a second. This is what that week looks like up close.", 0.075, 0.488, 0.47, 0.515),
            line("+38%", 0.66, 0.24, 0.72, 0.27),
            line("1 slide", 0.075, 0.73, 0.16, 0.8),
            line("118 hours", 0.23, 0.73, 0.33, 0.8),
            line("pitch.dog Obsess Over One 04 / 12", 0.075, 0.93, 0.25, 0.95),
            line("you looked closer than anyone.", 0.886, 0.93, 0.925, 0.936),
            SlideDetail(frame: ShotFrame(center: Vec2(0.75, 0.35), size: Vec2(0.36, 0.42)), kind: .figure),
        ]
    }

    func testBlocksMergeLinesAndFindRoles() {
        let blocks = Director.blocks(details)
        let headline = blocks.first { $0.role == .headline }
        XCTAssertNotNil(headline)
        XCTAssertEqual(headline?.lines, 2, "the two headline lines are one block")
        XCTAssertTrue(headline?.text.contains("purpose") ?? false)
        XCTAssertTrue(blocks.contains { $0.role == .smallPrint && $0.text.contains("closer") })
        XCTAssertTrue(blocks.contains { $0.role == .figure })
        let paragraph = blocks.first { $0.text.contains("week on one chart") }
        XCTAssertEqual(paragraph?.lines, 2)
    }

    func testTourStartsWithHeadlineAndEndsOnSmallPrint() {
        let shots = Director.shots(DirectorInput(details: details, slideAspect: A, canvasAspect: C, start: 2.1, maxShots: 5))
        XCTAssertGreaterThanOrEqual(shots.count, 3)
        XCTAssertTrue(shots.first?.label?.contains("Every") ?? false, "\(shots.map(\.label))")
        XCTAssertEqual(shots.last?.label, "The small print")
        for (a, b) in zip(shots, shots.dropFirst()) { XCTAssertGreaterThan(b.time, a.time) }
        // Every framing shows its block.
        for s in shots {
            XCTAssertGreaterThan(s.frame.size.x, 0)
            XCTAssertLessThanOrEqual(abs(s.yaw), 16)
        }
    }

    func testVoiceTimesTheShots() {
        let words = ["So", "every", "pixel", "here", "matters", "look", "at", "that", "thirty-eight", "percent", "jump",
                     "it", "took", "118", "hours", "and", "if", "you", "looked", "closer"]
            .enumerated().map { SpokenWord(text: $0.element, start: 3 + Double($0.offset) * 0.6, end: 3.4 + Double($0.offset) * 0.6) }
        let shots = Director.shots(DirectorInput(details: details, words: words, slideAspect: A, canvasAspect: C, start: 2.1, maxShots: 5))
        let headline = shots.first { $0.label?.contains("Every") ?? false }
        XCTAssertEqual(headline?.time ?? 0, 3 + 0.6 - 0.15, accuracy: 0.01, "lands just before 'every'")
        let hours = shots.first { $0.label?.contains("118") ?? false }
        XCTAssertEqual(hours?.time ?? 0, 3 + 13 * 0.6 - 0.15, accuracy: 0.01, "lands just before '118'")
        for (a, b) in zip(shots, shots.dropFirst()) { XCTAssertGreaterThanOrEqual(b.time - a.time, 1.29) }
    }

    func testTokens() {
        XCTAssertEqual(Director.tokens("Every pixel, on purpose."), ["every", "pixel", "purpose"])
        XCTAssertEqual(Director.tokens("+38% Café"), ["38", "cafe"])
    }

    func testRetimeLandsShotsOnTheirCues() {
        let frame = ShotFrame(center: Vec2(0.5, 0.5), size: Vec2(0.2, 0.2))
        let shots = [
            Shot(time: 3, frame: frame, label: "Headline", cue: "Every pixel"),
            Shot(time: 5, frame: frame, label: "Unnamed"),
            Shot(time: 8, frame: frame, label: "Hours", cue: "118 hours"),
        ]
        let words = ["so", "every", "pixel", "matters", "and", "this", "took", "us", "118", "hours"]
            .enumerated().map { SpokenWord(text: $0.element, start: 2 + Double($0.offset) * 0.8, end: 2.5 + Double($0.offset) * 0.8) }
        let out = Director.retime(shots, words: words, start: 1.5)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].time, 2 + 0.8 - 0.15, accuracy: 0.01)
        XCTAssertEqual(out[2].time, 2 + 8 * 0.8 - 0.15, accuracy: 0.01)
        XCTAssertGreaterThan(out[1].time, out[0].time + 0.89)
        XCTAssertLessThan(out[1].time, out[2].time - 0.89)
    }
}
