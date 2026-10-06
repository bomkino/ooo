import Foundation
import XCTest
@testable import OOOMotion

/// Whole tours as Direct for Me plans them, measured the way a viewer feels
/// them (see `MotionCheck`).
extension DirectorTests {
    /// The camera's path for a planned tour, built the way the app builds it.
    func plannedTour(_ details: [SlideDetail], A: Float, C: Float = 9.0 / 16, words: [SpokenWord]? = nil,
                     minViewHeight: Float? = nil, style: MotionStyle = MotionStyle(), ending: Ending = .pullBack) -> Choreography {
        let overview = Shot.overview(slideAspect: A, canvasAspect: C)
        let arrive = Arrive()
        let shots = Director.shots(DirectorInput(details: details, words: words, slideAspect: A, canvasAspect: C, start: arrive.end,
                                                 safe: .reel, minViewHeight: minViewHeight, overview: overview, style: style))
        var d = Choreography.naturalDuration(shots: shots, arrive: arrive, ending: ending)
        if let last = words?.last { d = max(d, last.end + 1.2) }
        return Choreography(ChoreographyInput(overview: overview, shots: shots, arrive: arrive, ending: ending, duration: d,
                                              slideAspect: A, canvasAspect: C, style: style, safe: .reel))
    }

    /// Words said evenly, `gap` seconds apart, from `start`.
    func spoken(_ text: String, start: Double = 2.4, gap: Double) -> [SpokenWord] {
        text.split(separator: " ").enumerated().map {
            SpokenWord(text: String($0.element), start: start + Double($0.offset) * gap, end: start + Double($0.offset) * gap + gap * 0.8)
        }
    }

    /// The wide traction slide, talked through quickly (about three words a second).
    var quickWideVoice: [SpokenWord] {
        spoken("Revenue grew three point one times this year. Sixty-two new customers and ninety-four percent net revenue "
            + "retention. By September we hit four hundred twelve k. Source: billing export, unaudited.", gap: 0.32)
    }

    /// The standard slide, talked through in a hurry (about four and a half words a second).
    var hurriedStandardVoice: [SpokenWord] {
        spoken("A four point two billion dollar market nobody designs for. Design spend in the US and EU is four point two "
            + "billion. Estimates are ours.", start: 2.2, gap: 0.22)
    }

    var tours: [(String, Choreography)] {
        let wideA: Float = 2576.0 / 1080, sharp: Float = 1920.0 / 2160
        return [
            ("sample", plannedTour(details, A: A)),
            ("wide", plannedTour(wide, A: wideA, minViewHeight: sharp)),
            ("standard", plannedTour(standard, A: 16.0 / 9, minViewHeight: sharp)),
            ("wide, quick voice", plannedTour(wide, A: wideA, words: quickWideVoice, minViewHeight: sharp)),
            ("standard, hurried voice", plannedTour(standard, A: 16.0 / 9, words: hurriedStandardVoice, minViewHeight: sharp)),
            ("wide, brisk", plannedTour(wide, A: wideA, minViewHeight: sharp, style: MotionStyle(flight: 1, pace: 1))),
            ("sample, unhurried, leaving", plannedTour(details, A: A, style: MotionStyle(flight: 0, pace: 0), ending: .leave)),
        ]
    }

    /// No move Direct for Me plans flies or turns past the limits, no emphasis
    /// is cut short, and the picture never jumps outside a cut.
    func testPlannedToursStayWithinTheLimits() {
        for (name, c) in tours {
            let check = MotionCheck(c)
            print("== \(name)\n\(check.summary)")
            XCTAssertTrue(check.problems.isEmpty, "\(name): \(check.problems)")
        }
    }

    /// When the voice leaves no time to fly, the camera cuts on the word.
    func testAVoiceInAHurryCutsRatherThanRushes() {
        let c = plannedTour(wide, A: 2576.0 / 1080, words: quickWideVoice, minViewHeight: 1920.0 / 2160)
        let first = c.beats[1]
        XCTAssertEqual(first.shot.move, .cut, "the first landing comes \(first.land - c.beats[0].land) s after the slide")
        XCTAssertEqual(first.shot.label, "Revenue grew 3.1× this year.")
    }

    /// The headline lands on "Revenue grew", the row of numbers on "Sixty-two":
    /// a word both share does not pull the numbers in early.
    func testABlockIsNamedByItsOwnWords() {
        let shots = Director.shots(DirectorInput(details: wide, words: quickWideVoice, slideAspect: 2576.0 / 1080, canvasAspect: C,
                                                 start: Arrive().end, safe: .reel, minViewHeight: 1920.0 / 2160))
        let said = { (word: String) in self.quickWideVoice.first { $0.text.hasPrefix(word) }!.start }
        let headline = shots.first { $0.label == "Revenue grew 3.1× this year." }
        let numbers = shots.first { $0.label == "The numbers" }
        XCTAssertNotNil(headline)
        XCTAssertEqual(numbers?.time ?? 0, said("Sixty-two") - 0.15, accuracy: 0.01)
    }

    /// Without a voice, the slide's point holds longest and a paragraph
    /// holds for its reading; every move still gets its natural length.
    func testHoldsFollowWhatThereIsToRead() {
        let A: Float = 16.0 / 9
        let shots = Director.shots(DirectorInput(details: standard, slideAspect: A, canvasAspect: C, start: Arrive().end,
                                                 safe: .reel, minViewHeight: 1920.0 / 2160))
        let gaps = zip(shots, shots.dropFirst()).map { ($0.label ?? "", $1.time - $0.time) }
        let point = gaps.first { $0.0.hasPrefix("$4.2B") }
        XCTAssertNotNil(point, "\(gaps)")
        for (label, gap) in gaps where label != point?.0 {
            XCTAssertGreaterThanOrEqual(point?.1 ?? 0, gap - 0.5, "\(label) holds longer than the point: \(gaps)")
        }
        let c = plannedTour(standard, A: A, minViewHeight: 1920.0 / 2160)
        for (i, beat) in c.beats.enumerated() where i > 0 && beat.shot.move != .cut {
            let natural = Choreography.autoTravel(from: c.beats[i - 1].sweepTo ?? c.beats[i - 1].pose, to: beat.pose, ease: beat.shot.ease,
                                                  move: beat.shot.move, style: MotionStyle(), canvasAspect: C)
            XCTAssertGreaterThanOrEqual(beat.travel, natural - 1e-6, "\(beat.shot.label ?? "") is squeezed")
        }
    }

    /// One emphasis peaks per tour, and any second one comes two shots or more away.
    func testOneEmphasisPeaksPerTour() {
        for (name, c) in tours {
            let emphasised = c.beats.indices.filter { c.beats[$0].shot.emphasis != .none && !c.beats[$0].isOverview }
            XCTAssertLessThanOrEqual(emphasised.count, 2, name)
            if emphasised.count == 2 { XCTAssertGreaterThanOrEqual(emphasised[1] - emphasised[0], 2, name) }
        }
    }
}
