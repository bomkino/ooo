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
        let hours = shots.first { $0.cue?.contains("118") ?? false }
        XCTAssertEqual(hours?.time ?? 0, 3 + 13 * 0.6 - 0.15, accuracy: 0.01, "lands just before '118'")
        for (a, b) in zip(shots, shots.dropFirst()) { XCTAssertGreaterThanOrEqual(b.time - a.time, 1.29) }
    }

    func testTokens() {
        XCTAssertEqual(Director.tokens("Every pixel, on purpose."), ["every", "pixel", "purpose"])
        XCTAssertEqual(Director.tokens("+38% Café"), ["38", "cafe"])
    }

    func testSpokenNumbersReadAsDigits() {
        XCTAssertEqual(Director.tokens("thirty-eight percent"), ["38", "percent"])
        XCTAssertEqual(Director.tokens("one hundred and eighteen hours"), ["118", "hours"])
        XCTAssertEqual(Director.tokens("a hundred pitches"), ["100", "pitches"])
        XCTAssertEqual(Director.tokens("four hundred twelve thousand"), ["412", "thousand"])
        XCTAssertEqual(Director.tokens("$412k"), ["412"])
        XCTAssertEqual(Director.tokens("07 TRACTION"), ["7", "traction"])
        XCTAssertEqual(Director.tokens("one slide"), ["1", "slide"])
        XCTAssertEqual(Director.tokens("five twenty"), ["5", "20"], "two numbers, not 25")
    }

    func testTheVoiceSetsTheOrder() {
        // Says the hours first, then the headline, then the percentage.
        let words = ["it", "took", "118", "hours", "and", "every", "pixel", "matters", "so", "much", "that", "thirty-eight",
                     "percent", "followed"]
            .enumerated().map { SpokenWord(text: $0.element, start: 3 + Double($0.offset) * 0.7, end: 3.5 + Double($0.offset) * 0.7) }
        let shots = Director.shots(DirectorInput(details: details, words: words, slideAspect: A, canvasAspect: C, start: 2.1))
        let order = shots.map { $0.cue ?? $0.label ?? "" }
        let hours = order.firstIndex { $0.contains("118") }, headline = order.firstIndex { $0.contains("Every") }
        let percent = order.firstIndex { $0.contains("38") }
        XCTAssertNotNil(hours, "\(order)")
        XCTAssertNotNil(headline, "\(order)")
        XCTAssertNotNil(percent, "\(order)")
        if let hours, let headline, let percent {
            XCTAssertLessThan(hours, headline, "\(order)")
            XCTAssertLessThan(headline, percent, "\(order)")
        }
        XCTAssertEqual(shots.first { $0.cue?.contains("118") ?? false }?.time ?? 0, 3 + 2 * 0.7 - 0.15, accuracy: 0.01)
        for (a, b) in zip(shots, shots.dropFirst()) { XCTAssertGreaterThanOrEqual(b.time - a.time, 1.29) }
    }

    /// The wide traction slide (2576 × 1080) as text recognition reads it.
    var wide: [SlideDetail] {
        func line(_ text: String, _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float) -> SlideDetail {
            SlideDetail(frame: ShotFrame(center: Vec2((u0 + u1) / 2, (v0 + v1) / 2), size: Vec2(u1 - u0, v1 - v0)), text: text)
        }
        return [
            line("07 TRACTION", 0.054, 0.114, 0.128, 0.134),
            line("Revenue grew 3.1× this year.", 0.051, 0.183, 0.517, 0.267),
            line("Teams that send one great slide instead of a deck hear back faster,", 0.054, 0.291, 0.410, 0.322),
            line("and they keep paying. Here is monthly recurring revenue since January.", 0.052, 0.332, 0.436, 0.364),
            line("3.1x", 0.052, 0.640, 0.131, 0.720), line("revenue growth", 0.052, 0.727, 0.129, 0.751),
            line("62", 0.208, 0.633, 0.253, 0.709), line("new customers", 0.209, 0.727, 0.281, 0.750),
            line("94%", 0.363, 0.633, 0.443, 0.709), line("net revenue retention", 0.365, 0.727, 0.467, 0.751),
            line("Monthly recurring revenue, $k", 0.637, 0.180, 0.769, 0.204),
            line("$412k", 0.903, 0.214, 0.955, 0.253),
            line("400", 0.948, 0.269, 0.965, 0.287), line("300", 0.949, 0.388, 0.965, 0.408),
            line("Jan", 0.647, 0.777, 0.661, 0.796), line("Sep", 0.920, 0.775, 0.936, 0.798),
            line("pitch.dog", 0.054, 0.913, 0.093, 0.938), line("Series A update • Confidential", 0.103, 0.917, 0.215, 0.936),
            line("Source: billing export, 1 Jan - 30 Sep 2026. Excludes one-off services. Unaudited.", 0.757, 0.919, 0.945, 0.934),
            SlideDetail(frame: ShotFrame(center: Vec2(0.7875, 0.5225), size: Vec2(0.325, 0.507)), kind: .figure),
        ]
    }

    func testNumbersKeepTheirCaptionsAndARowIsOneShot() {
        let blocks = Director.blocks(wide)
        let row = blocks.first { $0.role == .numbers && $0.items == 3 }
        XCTAssertNotNil(row, "\(blocks.map { ($0.role, $0.text) })")
        XCTAssertTrue(row?.text.contains("new customers") ?? false)
        XCTAssertTrue(blocks.contains { $0.role == .smallPrint && $0.text.hasPrefix("Source") })
        XCTAssertFalse(blocks.contains { $0.text == "revenue growth" }, "the caption joined its number")
    }

    func testTheWideSlideTour() {
        let picked = Director.tour(Director.blocks(wide), maxShots: 6)
        let names = picked.map { $0.role == .figure ? "figure" : $0.text }
        XCTAssertEqual(picked.first?.role, .headline, "\(names)")
        XCTAssertEqual(picked.last?.role, .smallPrint, "\(names)")
        let figure = picked.firstIndex { $0.role == .figure }, total = picked.firstIndex { $0.text == "$412k" }
        let row = picked.firstIndex { $0.items == 3 }
        XCTAssertNotNil(figure, "\(names)")
        if let figure, let total, let row {
            XCTAssertEqual(total, figure + 1, "the total above the last bar follows its chart: \(names)")
            XCTAssertLessThan(row, figure, "left column first: \(names)")
        } else {
            XCTFail("\(names)")
        }
        XCTAssertFalse(names.contains("pitch.dog"), "\(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix("Monthly") }, "the chart's title is seen with the chart: \(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix("Series A") }, "a running footer is the deck's, not the slide's: \(names)")
    }

    /// The standard market slide (1920 × 1080): numbers stacked in rings.
    var standard: [SlideDetail] {
        func line(_ text: String, _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float) -> SlideDetail {
            SlideDetail(frame: ShotFrame(center: Vec2((u0 + u1) / 2, (v0 + v1) / 2), size: Vec2(u1 - u0, v1 - v0)), text: text)
        }
        return [
            line("03 MARKET", 0.062, 0.106, 0.132, 0.122),
            line("A $4.2B market", 0.060, 0.171, 0.378, 0.246), line("nobody designs for.", 0.055, 0.253, 0.395, 0.349),
            line("Every startup pitches. Almost none can afford a designer for", 0.064, 0.380, 0.419, 0.406),
            line("every update. We sell the one-slide update to the 1.1 million", 0.061, 0.413, 0.420, 0.442),
            line("seed and Series A teams who send one every month.", 0.062, 0.446, 0.379, 0.477),
            line("$4.2B", 0.712, 0.235, 0.776, 0.274), line("design spend, US and EU", 0.695, 0.282, 0.794, 0.300),
            line("$860M", 0.711, 0.351, 0.778, 0.382), line("teams that pitch monthly", 0.696, 0.393, 0.792, 0.411),
            line("$95M", 0.719, 0.499, 0.769, 0.527), line("ours in three years", 0.708, 0.537, 0.781, 0.556),
            line("TRUSTED BY", 0.061, 0.747, 0.124, 0.762), line("Northwind", 0.062, 0.790, 0.154, 0.820),
            line("Halcyon", 0.185, 0.793, 0.241, 0.827), line("Brightline", 0.273, 0.793, 0.342, 0.824),
            line("Estimates: pitch.dog analysis of 2025 design-tool spend in the US and EU. TAM is the total addressable market; SAM what we can serve; SOM what we can win in three years.",
                 0.061, 0.925, 0.554, 0.941),
            line("03", 0.926, 0.925, 0.938, 0.938),
            SlideDetail(frame: ShotFrame(center: Vec2(0.7435, 0.522), size: Vec2(0.363, 0.644)), kind: .figure),
        ]
    }

    /// Direct for Me's framings follow the canvas; one set by hand never moves.
    func testPlannedFramingsFollowTheCanvasAndYoursStay() {
        let reel = Director.shots(DirectorInput(details: standard, slideAspect: A, canvasAspect: C, start: 2.1, safe: .reel))
        let wide = Director.shots(DirectorInput(details: standard, slideAspect: A, canvasAspect: 16.0 / 9, start: 2.1))
        XCTAssertTrue(reel.allSatisfy(\.isPlanned))
        XCTAssertGreaterThan(reel.count, 2)
        var mine = reel
        mine[1].frame.size *= 0.8
        mine[1].planned = nil
        mine[2].time += 0.7
        let moved = Director.reframe(mine, from: wide)
        XCTAssertEqual(moved.count, mine.count)
        for (i, s) in moved.enumerated() {
            XCTAssertEqual(s.time, mine[i].time, "times stay")
            XCTAssertEqual(s.id, mine[i].id)
            if i == 1 {
                XCTAssertEqual(s, mine[1], "a framing set by hand stays as it is")
            } else if let match = wide.first(where: { $0.focus == s.focus }) {
                XCTAssertEqual(s.frame, match.frame, "shot \(i) takes the wide canvas's framing")
                XCTAssertEqual(s.yaw, match.yaw)
            }
        }
        XCTAssertNotEqual(moved[0].frame, reel[0].frame, "a tall frame and a wide one frame the headline differently")
    }

    /// Replacing a slide with a corrected one keeps the tour: shots follow
    /// their words to where they moved, and a shot whose detail is gone stays.
    func testShotsFollowTheirWordsOntoACorrectedSlide() {
        let before = Director.shots(DirectorInput(details: standard, slideAspect: A, canvasAspect: C, start: 2.1, safe: .reel))
        // The corrected slide: the headline moved down, the $4.2B ring's
        // figure changed, and the logos are gone.
        let shift: Float = 0.06
        let corrected: [SlideDetail] = standard.compactMap { d in
            var d = d
            if d.text.hasPrefix("A $4.2B") || d.text.hasPrefix("nobody") { d.frame.center.y += shift }
            if d.text == "$4.2B" { d.text = "$4.5B" }
            if ["Northwind", "Halcyon", "Brightline", "TRUSTED BY"].contains(d.text) { return nil }
            return d
        }
        let after = Director.follow(before, from: standard, to: corrected)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.time), before.map(\.time))
        let headline = try? XCTUnwrap(before.firstIndex { $0.label?.hasPrefix("A $4.2B market") ?? false })
        if let h = headline {
            XCTAssertEqual(after[h].frame.center.y, before[h].frame.center.y + shift, accuracy: 1e-4, "the headline's shot moves with it")
            XCTAssertEqual(after[h].frame.size, before[h].frame.size)
        }
        for (b, a) in zip(before, after) where b.focus.map({ $0.center.y > 0.7 }) ?? false {
            XCTAssertEqual(a, b, "a shot of something gone or unmoved stays")
        }
        // Nothing moved: nothing changes.
        XCTAssertEqual(Director.follow(before, from: standard, to: standard), before)
    }

    func testDetailsInOneViewGetOneShot() {
        // A 1080 px picture in a reel: the sharp limit keeps the rings' numbers
        // in nearly the same close-up, so only the first of them gets a shot.
        let A: Float = 16.0 / 9, C: Float = 9.0 / 16
        let shots = Director.shots(DirectorInput(details: standard, slideAspect: A, canvasAspect: C, start: 2.1, safe: .reel,
                                                 minViewHeight: 1920.0 / 2160))
        let names = shots.map { $0.label ?? "" }
        for (i, a) in shots.enumerated() {
            for b in shots[(i + 1)...] where a.sweep == nil && b.sweep == nil {
                XCTAssertLessThan(Director.overlap(a.frame, b.frame), 0.7, "\(names)")
            }
        }
        XCTAssertEqual(shots.filter { $0.label?.hasPrefix("$") ?? false }.count, 1, "\(names)")
        // A vector slide can go close enough to give each its own.
        let close = Director.shots(DirectorInput(details: standard, slideAspect: A, canvasAspect: C, start: 2.1, safe: .reel))
        XCTAssertGreaterThan(close.filter { $0.label?.hasPrefix("$") ?? false }.count, 1, "\(close.map { $0.label ?? "" })")
    }

    func testCloseUpsKeepTheirDetailInTheMiddle() {
        let A: Float = 2576.0 / 1080, C: Float = 9.0 / 16
        let shots = Director.shots(DirectorInput(details: wide, slideAspect: A, canvasAspect: C, start: 2.1, safe: .reel,
                                                 minViewHeight: 1920.0 / 2160))
        XCTAssertFalse(shots.isEmpty)
        for s in shots {
            let f = s.frame
            // Each detail sits in the middle 60% of its framing (read-alongs across it).
            if let focus = s.focus {
                XCTAssertLessThanOrEqual(abs(focus.center.y - f.center.y), 0.2 * f.size.y + 1e-4, s.label ?? "")
                if s.sweep == nil { XCTAssertLessThanOrEqual(abs(focus.center.x - f.center.x), 0.2 * f.size.x + 1e-4, s.label ?? "") }
            }
            // The view stays on the slide unless that would push its detail to the edge:
            // then it shows no more past the slide's edge than it must.
            if f.size.x < 1 {
                XCTAssertGreaterThanOrEqual(f.minU, -0.3 * f.size.x - 1e-4, s.label ?? "")
                XCTAssertLessThanOrEqual(f.maxU + (s.sweep?.x ?? 0), 1 + 0.3 * f.size.x + 1e-4, s.label ?? "")
            }
            if f.size.y < 1 {
                XCTAssertGreaterThanOrEqual(f.minV, -0.3 * f.size.y - 1e-4, s.label ?? "")
                XCTAssertLessThanOrEqual(f.maxV, 1 + 0.3 * f.size.y + 1e-4, s.label ?? "")
            }
        }
        // The small print by the slide's foot no longer lands at the bottom of the frame.
        if let small = shots.first(where: { $0.label == "The small print" }), let focus = small.focus {
            XCTAssertLessThan((focus.center.y - small.frame.minV) / small.frame.size.y, 0.71)
        }
        // One lift at a time.
        for (a, b) in zip(shots, shots.dropFirst()) where a.emphasis == .lift {
            XCTAssertNotEqual(b.emphasis, .lift)
        }
    }

    func testSmallPrintIsASentenceNotALabel() {
        func line(_ text: String, _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float) -> SlideDetail {
            SlideDetail(frame: ShotFrame(center: Vec2((u0 + u1) / 2, (v0 + v1) / 2), size: Vec2(u1 - u0, v1 - v0)), text: text)
        }
        let blocks = Director.blocks([
            line("A $4.2B market", 0.060, 0.170, 0.378, 0.245),
            line("Every startup pitches. Almost none can afford a designer for", 0.064, 0.380, 0.419, 0.403),
            line("TRUSTED BY", 0.061, 0.747, 0.124, 0.760),
            line("Northwind", 0.061, 0.790, 0.154, 0.820),
            line("Estimates: pitch.dog analysis of 2025 design-tool spend in the US and EU.", 0.061, 0.925, 0.554, 0.941),
            line("03", 0.926, 0.922, 0.938, 0.938),
        ])
        let small = blocks.filter { $0.role == .smallPrint }
        XCTAssertEqual(small.count, 1)
        XCTAssertTrue(small.first?.text.hasPrefix("Estimates") ?? false, "\(small.map(\.text))")
    }

    func testReadingAlongInATallFrame() {
        let A: Float = 2576.0 / 1080, C: Float = 9.0 / 16
        let blocks = Director.blocks(wide)
        guard let headline = blocks.first(where: { $0.role == .headline }) else { return XCTFail() }
        let f = Director.framing(for: headline, slideAspect: A, canvasAspect: C, safe: .reel)
        XCTAssertNotNil(f.sweep, "a long headline is read along")
        // The line stands about 6% of the frame tall.
        let share = headline.lineHeight / (f.frame.size.y / SafeArea.reel.size.y)
        XCTAssertEqual(share, 0.062, accuracy: 0.004)
        // The glide starts on the line's first word and ends on its last.
        let half = f.frame.size.x / 2
        XCTAssertLessThan(f.frame.center.x - half, headline.bounds.x)
        XCTAssertGreaterThan(f.frame.center.x + (f.sweep?.x ?? 0) + half, headline.bounds.z)
        // A picture 1080 pixels tall keeps the camera far enough to stay sharp.
        let sharp = Director.framing(for: headline, slideAspect: A, canvasAspect: C, safe: .reel, minViewHeight: 1.6)
        XCTAssertGreaterThanOrEqual(sharp.frame.size.y / SafeArea.reel.size.y, 1.6 - 1e-4)
    }

    func testShotsStayWithinTheSharpLimit() {
        let A: Float = 2576.0 / 1080, C: Float = 9.0 / 16
        let minH: Float = 1920.0 / (1080 * 2)
        let shots = Director.shots(DirectorInput(details: wide, slideAspect: A, canvasAspect: C, start: 2.1, safe: .reel,
                                                 minViewHeight: minH))
        XCTAssertGreaterThanOrEqual(shots.count, 4)
        for s in shots {
            let p = CameraPose(shot: s, slideAspect: A, canvasAspect: C, safe: .reel)
            XCTAssertGreaterThan(p.height, minH * 0.9, "\(s.label ?? "")")
        }
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

    func testANumberedShotIsNotPinnedToASpokenNumber() {
        XCTAssertNil(Director.spokenLabel("Shot 3"))
        XCTAssertEqual(Director.spokenLabel("Revenue"), "Revenue")
        XCTAssertEqual(Director.spokenLabel("Shot of the team"), "Shot of the team")
        let frame = ShotFrame(center: Vec2(0.5, 0.5), size: Vec2(0.2, 0.2))
        let shots = [
            Shot(time: 3, frame: frame, label: "Headline", cue: "Every pixel"),
            Shot(time: 5, frame: frame, label: "Shot 3"),
        ]
        let words = ["three", "things", "and", "then", "every", "pixel"]
            .enumerated().map { SpokenWord(text: $0.element, start: 2 + Double($0.offset) * 0.8, end: 2.5 + Double($0.offset) * 0.8) }
        let out = Director.retime(shots, words: words, start: 1.5)
        // The hand-made shot isn't landed on "three" ahead of the headline.
        XCTAssertEqual(out.first?.label, "Headline")
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
