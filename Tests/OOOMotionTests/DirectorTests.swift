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
            line("+38%", 0.744, 0.202, 0.797, 0.238),
            line("1 slide", 0.075, 0.73, 0.16, 0.8),
            line("118 hours", 0.23, 0.73, 0.33, 0.8),
            line("pitch.dog Obsess Over One 04 / 12", 0.075, 0.93, 0.25, 0.95),
            line("you looked closer than anyone.", 0.886, 0.93, 0.925, 0.936),
            // The chart, as the slide's ink shows it.
            SlideDetail(frame: ShotFrame(center: Vec2(0.7435, 0.367), size: Vec2(0.363, 0.378)), kind: .figure),
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

    func testSlideSizedAndRepeatedFiguresAreIgnored() {
        var found = details
        found.append(SlideDetail(frame: ShotFrame(center: Vec2(0.455, 0.45), size: Vec2(0.91, 0.86)), kind: .figure))
        found.append(SlideDetail(frame: ShotFrame(center: Vec2(0.76, 0.36), size: Vec2(0.34, 0.40)), kind: .figure))
        let figures = Director.blocks(found).filter { $0.role == .figure }
        XCTAssertEqual(figures.count, 1, "\(figures.map(\.bounds))")
        XCTAssertLessThan(Director.area(figures[0].bounds), 0.2, "the tightest figure wins")
    }

    func testCloseUpsAddSmallPrintAndMendCutLines() {
        func line(_ text: String, _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float) -> SlideDetail {
            SlideDetail(frame: ShotFrame(center: Vec2((u0 + u1) / 2, (v0 + v1) / 2), size: Vec2(u1 - u0, v1 - v0)), text: text)
        }
        let whole = [line("Every pixel,", 0.07, 0.21, 0.37, 0.29), line("pitch.dog", 0.075, 0.93, 0.115, 0.948)]
        let closeUps = [
            line("pitch.dog", 0.0752, 0.9302, 0.1149, 0.9478),            // read again
            line("If you can read this,", 0.80, 0.912, 0.86, 0.917),     // new small print
            line("you looked clo", 0.80, 0.918, 0.84, 0.923),            // cut where close-ups meet
            line("ooked closer than anyone.", 0.82, 0.918, 0.88, 0.923),
            line("Every pixel,", 0.07, 0.21, 0.37, 0.29),                  // big type: the whole read has it
        ]
        let merged = Director.merge(whole, closeUps: closeUps)
        XCTAssertEqual(merged.count, 4, "\(merged.map(\.text))")
        let mended = merged.first { $0.text.contains("closer than anyone") }
        XCTAssertEqual(mended?.frame.minU ?? 0, 0.80, accuracy: 1e-4)
        XCTAssertEqual(mended?.frame.maxU ?? 0, 0.88, accuracy: 1e-4)
        let roles = Director.blocks(merged + details.filter { $0.kind == .figure })
        XCTAssertTrue(roles.contains { $0.role == .smallPrint && $0.text.contains("read this") })
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

    func testTheChartComesBeforeTheNumberInIt() {
        let picked = Director.tour(Director.blocks(details), maxShots: 6)
        let labels = picked.map { $0.role == .figure ? "figure" : $0.text }
        XCTAssertEqual(picked.first?.role, .headline, "\(labels)")
        XCTAssertEqual(picked.last?.role, .smallPrint, "\(labels)")
        let figure = picked.firstIndex { $0.role == .figure }
        let number = picked.firstIndex { $0.text.contains("38") }
        XCTAssertNotNil(figure, "\(labels)")
        XCTAssertNotNil(number, "\(labels)")
        if let figure, let number { XCTAssertEqual(number, figure + 1, "\(labels)") }
    }

    func testVoiceTimesTheShots() {
        let words = ["So", "every", "pixel", "here", "matters", "look", "at", "that", "thirty-eight", "percent", "jump",
                     "it", "took", "118", "hours", "and", "if", "you", "looked", "closer"]
            .enumerated().map { SpokenWord(text: $0.element, start: 3 + Double($0.offset) * 0.6, end: 3.4 + Double($0.offset) * 0.6) }
        let shots = Director.shots(DirectorInput(details: details, words: words, slideAspect: A, canvasAspect: C, start: 2.1))
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

final class FigureFinderTests: XCTestCase {
    /// A cream slide with a headline, a paragraph and a chart on the right.
    func testFindsTheChartAndNotTheText() {
        let w = 640, h = 360
        var luma = [Float](repeating: 0.95, count: w * h)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ v: Float) {
            for y in y0..<y1 { for x in x0..<x1 { luma[y * w + x] = v } }
        }
        // Text: speckled strokes inside its line boxes.
        var text: [SIMD4<Float>] = []
        for (row, (x0, x1, y0, y1)) in [(40, 260, 60, 90), (40, 280, 150, 158), (40, 270, 162, 170)].enumerated() {
            for x in stride(from: x0, to: x1, by: 3 + row % 2) { fill(x, y0, x + 1, y1, 0.2) }
            text.append(SIMD4(Float(x0) / Float(w), Float(y0) / Float(h), Float(x1) / Float(w), Float(y1) / Float(h)))
        }
        // The chart: an axis, grid lines and a rising curve.
        fill(380, 220, 600, 222, 0.5)
        for y in [80, 120, 160, 200] { fill(380, y, 600, y + 1, 0.8) }
        for x in 380..<600 {
            let y = 200 - Int(pow(Float(x - 380) / 220, 2.5) * 120)
            fill(x, y, x + 1, y + 3, 0.55)
        }
        // A speck and a hairline rule are not figures.
        fill(300, 70, 304, 74, 0.3)
        fill(40, 330, 600, 331, 0.7)

        let found = FigureFinder.figures(luma: luma, width: w, height: h, text: text)
        XCTAssertEqual(found.count, 1, "\(found)")
        let b = found[0]
        XCTAssertEqual(b.x, 380 / 640, accuracy: 0.03)
        XCTAssertEqual(b.z, 600 / 640, accuracy: 0.03)
        XCTAssertEqual(b.y, 80 / 360, accuracy: 0.04)
        XCTAssertEqual(b.w, 222 / 360, accuracy: 0.04)
    }
}
