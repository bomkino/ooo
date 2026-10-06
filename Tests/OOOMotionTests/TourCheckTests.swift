import Foundation
import XCTest
@testable import OOOMotion

/// Whole tours as Direct for Me plans them, measured the way a viewer feels
/// them (see `MotionCheck`).
extension DirectorTests {
    /// The camera's path for a planned tour, built the way the app builds it.
    func plannedTour(_ details: [SlideDetail], A: Float, C: Float = 9.0 / 16, words: [SpokenWord]? = nil,
                     minViewHeight: Float? = nil) -> Choreography {
        let overview = Shot.overview(slideAspect: A, canvasAspect: C)
        let arrive = Arrive()
        let shots = Director.shots(DirectorInput(details: details, words: words, slideAspect: A, canvasAspect: C,
                                                 start: arrive.end, safe: .reel, minViewHeight: minViewHeight, overview: overview))
        var d = Choreography.naturalDuration(shots: shots, arrive: arrive, ending: .pullBack)
        if let last = words?.last { d = max(d, last.end + 1.2) }
        return Choreography(ChoreographyInput(overview: overview, shots: shots, arrive: arrive, ending: .pullBack, duration: d,
                                              slideAspect: A, canvasAspect: C, style: MotionStyle(), safe: .reel))
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

    var tours: [(String, Choreography)] {
        let wideA: Float = 2576.0 / 1080, sharp: Float = 1920.0 / 2160
        return [
            ("sample", plannedTour(details, A: A)),
            ("wide", plannedTour(wide, A: wideA, minViewHeight: sharp)),
            ("standard", plannedTour(standard, A: 16.0 / 9, minViewHeight: sharp)),
            ("wide, quick voice", plannedTour(wide, A: wideA, words: quickWideVoice, minViewHeight: sharp)),
        ]
    }

    func testPlannedToursNeverJump() {
        for (name, c) in tours {
            let check = MotionCheck(c)
            print("== \(name)\n\(check.summary)")
            XCTAssertTrue(check.pops.isEmpty, "\(name): \(check.problems)")
        }
    }
}
