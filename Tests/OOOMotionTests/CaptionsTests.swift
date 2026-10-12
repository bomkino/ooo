import XCTest
@testable import OOOMotion

final class CaptionsTests: XCTestCase {
    /// Words said one after another, `gap` apart, each `length` long.
    func said(_ text: String, from: Double = 1, length: Double = 0.28, gap: Double = 0.06) -> [SpokenWord] {
        var t = from
        return text.split(separator: " ").map { w in
            defer { t += length + gap }
            return SpokenWord(text: String(w), start: t, end: t + length)
        }
    }

    func testPhrasesAreShortAndBreakAtSentences() {
        let words = said("Revenue grew three times this year. Most of it came from teams who started small and stayed.")
        let p = Captions.phrases(words)
        XCTAssertGreaterThan(p.count, 2)
        for phrase in p {
            XCTAssertLessThanOrEqual(phrase.text.count, Captions.maxCharacters + 8, phrase.text)
            XCTAssertLessThanOrEqual(phrase.words.count, Captions.maxWords + 1, phrase.text)
        }
        // The first sentence ends its phrase.
        XCTAssertTrue(p.contains { $0.text.hasSuffix("year.") }, p.map(\.text).description)
        // Every word is shown once, in order.
        XCTAssertEqual(p.flatMap(\.words), words.map(\.text))
    }

    func testAPauseEndsAPhrase() {
        var words = said("This is the part")
        words += said("that matters", from: words.last!.end + 1.2)
        let p = Captions.phrases(words)
        XCTAssertEqual(p.map(\.text), ["This is the part", "that matters"])
        XCTAssertFalse(p[1].follows)
        // Between them, after the first has lingered, nothing shows.
        let between = words[3].end + Captions.linger + 0.1
        XCTAssertLessThan(between, p[1].shown)
        XCTAssertNil(Captions.moment(p, at: between))
    }

    func testNoWordIsLeftAlone() {
        let p = Captions.phrases(said("We redrew the curve eleven times before it was right"))
        XCTAssertTrue(p.allSatisfy { $0.words.count > 1 }, p.map(\.text).description)
    }

    func testNeverTwoAtOnceAndTheWordBeingSaidIsLit() {
        let words = said("One slide, one camera, all the love. Every slide, every detail.")
        let p = Captions.phrases(words)
        for k in 1..<p.count { XCTAssertGreaterThanOrEqual(p[k].shown, p[k - 1].gone - 1e-9) }
        let w = words[2]
        let m = Captions.moment(p, at: (w.start + w.end) / 2)!
        let phrase = p[m.phrase]
        let i = phrase.starts.firstIndex(of: w.start)!
        XCTAssertEqual(m.lit[i], 1, accuracy: 0.001)
        for j in m.lit.indices where j != i { XCTAssertEqual(m.lit[j], 0, accuracy: 0.001) }
        XCTAssertEqual(m.alpha, 1, accuracy: 0.001)
    }

    func testAPhraseComesUpJustBeforeItsFirstWord() {
        let words = said("Hello there")
        let p = Captions.phrases(words)
        XCTAssertEqual(p[0].shown, words[0].start - Captions.lead, accuracy: 1e-9)
        XCTAssertNil(Captions.moment(p, at: p[0].shown - 0.01))
        let rising = Captions.moment(p, at: p[0].shown + 0.03)!
        XCTAssertGreaterThan(rising.alpha, 0)
        XCTAssertLessThan(rising.alpha, 1)
        XCTAssertGreaterThan(rising.drop, 0)
    }

    func testCorrectingAWordKeepsItsTime() {
        let words = said("the cost fell by forty percent")
        let p = Captions.phrases(words)[0]
        let fixed = Captions.corrected(words, phrase: p, to: "the cost fell by 40 percent")
        XCTAssertEqual(fixed.map(\.text), ["the", "cost", "fell", "by", "40", "percent"])
        XCTAssertEqual(fixed.map(\.start), words.map(\.start))
    }

    func testCorrectingToMoreWordsSharesThePhrasesTime() {
        let words = said("gonna ship it")
        let p = Captions.phrases(words)[0]
        let fixed = Captions.corrected(words, phrase: p, to: "going to ship it")
        XCTAssertEqual(fixed.count, 4)
        XCTAssertEqual(fixed.first!.start, words.first!.start, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(fixed.last!.end, words.last!.end + 1e-9)
        for k in 1..<fixed.count { XCTAssertGreaterThanOrEqual(fixed[k].start, fixed[k - 1].end) }
        XCTAssertTrue(Captions.corrected(words, phrase: p, to: "  ").isEmpty)
    }

    func testCaptionsLeaveRoomAboveThemForFramings() {
        let reel = SafeArea.reel
        let C: Float = 1080.0 / 1920.0
        let band = Captions.band(canvasAspect: C, safe: reel)
        XCTAssertGreaterThan(band.bottom, reel.bottom)
        let kept = Captions.reserving(reel, canvasAspect: C)
        XCTAssertGreaterThan(kept.bottom, band.bottom + band.height)
        XCTAssertEqual(kept.top, reel.top)
        // The type is the same size in pixels on a Reel and a landscape video.
        XCTAssertEqual(Captions.size(canvasAspect: C) * 1920, Captions.size(canvasAspect: 16.0 / 9.0) * 1080, accuracy: 0.01)
    }
}
