import Foundation
import XCTest
@testable import OOOMotion

/// Direct for Me over several slides.
final class DirectorPagesTests: XCTestCase {
    let A: Float = 16.0 / 9.0
    let C: Float = 9.0 / 16.0

    func line(_ text: String, _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float) -> SlideDetail {
        SlideDetail(frame: ShotFrame(center: Vec2((u0 + u1) / 2, (v0 + v1) / 2), size: Vec2(u1 - u0, v1 - v0)), text: text)
    }

    /// Two slides of one deck: the chart stays put while its story moves on.
    var first: [SlideDetail] {
        [line("Revenue grew", 0.07, 0.12, 0.45, 0.22),
         line("A year of steady months, then one that turned.", 0.07, 0.3, 0.45, 0.34),
         line("$412k", 0.1, 0.62, 0.22, 0.72),
         SlideDetail(frame: ShotFrame(center: Vec2(0.72, 0.5), size: Vec2(0.4, 0.5)), kind: .figure)]
    }

    var second: [SlideDetail] {
        [line("And then it kept going", 0.07, 0.12, 0.5, 0.22),
         line("Every month since has beaten the one before it.", 0.07, 0.3, 0.45, 0.34),
         line("$1.2M", 0.1, 0.62, 0.22, 0.72),
         SlideDetail(frame: ShotFrame(center: Vec2(0.72, 0.5), size: Vec2(0.4, 0.5)), kind: .figure)]
    }

    func pages(_ change: PageChange) -> [PageReading] {
        [PageReading(id: nil, details: first, aspect: A), PageReading(id: UUID(), details: second, aspect: A, change: change)]
    }

    func input(words: [SpokenWord]? = nil) -> DirectorInput {
        DirectorInput(details: first, words: words, slideAspect: A, canvasAspect: C, start: Arrive().end, safe: .reel)
    }

    func choreography(_ shots: [Shot], _ pages: [PageReading]) -> Choreography {
        var c = ChoreographyInput(overview: .overview(slideAspect: A, canvasAspect: C), shots: shots, arrive: Arrive(), ending: .pullBack,
                                  duration: 0, slideAspect: A, canvasAspect: C, style: MotionStyle(), safe: .reel,
                                  pages: pages.dropFirst().map { PageTiming(id: $0.id!, aspect: $0.aspect, change: $0.change) })
        c.duration = Choreography.naturalDuration(c)
        return Choreography(c)
    }

    func testEachSlideGetsItsOwnTourInTurn() {
        let pages = pages(.turn)
        let shots = Director.shots(input(), pages: pages, arrive: Arrive())
        let one = shots.filter { $0.page == nil }, two = shots.filter { $0.page == pages[1].id }
        XCTAssertGreaterThanOrEqual(one.count, 2)
        XCTAssertGreaterThanOrEqual(two.count, 2)
        XCTAssertLessThan(one.map(\.time).max() ?? 0, two.map(\.time).min() ?? 0)
        let c = choreography(shots, pages)
        // Nothing waits on the card: every shot lands on the moment it was given.
        for b in c.beats where b.role == .shot {
            XCTAssertEqual(b.land, b.shot.time, accuracy: 1e-9, "\(b.shot.label ?? "")")
        }
        let check = MotionCheck(c)
        print(check.summary)
        XCTAssertTrue(check.problems.isEmpty, "\(check.problems)")
    }

    func testAMeltHoldsStillOnWhatBothSlidesShare() {
        let pair = Director.sharedDetail(first, second)
        XCTAssertEqual(pair?.0.role, .figure, "the chart that stays where it is")
        let pages = pages(.melt)
        let shots = Director.shots(input(), pages: pages, arrive: Arrive())
        let c = choreography(shots, pages)
        guard let i = c.beats.firstIndex(where: { $0.melts }) else { return XCTFail("no melt") }
        let before = c.beats[i - 1], after = c.beats[i]
        XCTAssertEqual(before.page, 0)
        XCTAssertEqual(after.page, 1)
        // The same detail, framed the same, on both sides of the melt.
        XCTAssertEqual(before.shot.focus?.center.x ?? 0, after.shot.focus?.center.x ?? 1, accuracy: 1e-4)
        XCTAssertEqual(before.pose.target.x, after.pose.target.x, accuracy: 1e-3)
        XCTAssertEqual(before.pose.height, after.pose.height, accuracy: 1e-3)
        // And the next slide's tour doesn't go back to it.
        let again = c.beats[(i + 1)...].filter { $0.role == .shot && $0.shot.focus == after.shot.focus }
        XCTAssertTrue(again.isEmpty)
        let check = MotionCheck(c)
        print(check.summary)
        XCTAssertTrue(check.problems.isEmpty, "\(check.problems)")
    }

    func testARunningFooterIsNotShared() {
        let a = [line("pitch.dog Series A 2026", 0.07, 0.93, 0.3, 0.95), line("Revenue grew", 0.07, 0.12, 0.45, 0.22)]
        let b = [line("pitch.dog Series A 2026", 0.07, 0.93, 0.3, 0.95), line("Hiring next", 0.07, 0.12, 0.45, 0.22)]
        XCTAssertNil(Director.sharedDetail(a, b))
    }

    func testTheVoiceIsSharedWhereItMovesOn() {
        func say(_ text: String, from t: Double) -> [SpokenWord] {
            text.split(separator: " ").enumerated().map { SpokenWord(text: String($1), start: t + Double($0) * 0.35, end: t + Double($0) * 0.35 + 0.3) }
        }
        let words = say("revenue grew all year steady months then one turned four hundred twelve thousand", from: 3)
            + say("and then it kept going every month since has beaten the one before", from: 9)
        let shares = Director.share(words, among: pages(.turn))
        XCTAssertEqual(shares.count, 2)
        // The second slide's stretch starts where the voice first names what is on it.
        XCTAssertTrue(shares[0].contains { $0.text == "thousand" })
        XCTAssertEqual(shares[1].first?.text, "kept")
        let shots = Director.shots(input(words: words), pages: pages(.turn), arrive: Arrive())
        XCTAssertTrue(shots.contains { $0.page != nil })
    }
}
