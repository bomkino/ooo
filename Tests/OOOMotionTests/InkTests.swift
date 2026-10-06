import Foundation
import XCTest
@testable import OOOMotion

final class InkTests: XCTestCase {
    /// A circle drawn round a number over a second: it draws on at the speed
    /// it was drawn, and where the pen came back round, the ink keeps the
    /// moment it first got there.
    func testACircleDrawsOnAsItWasDrawn() throws {
        let n = 60
        let points = (0...n).map { i -> InkPoint in
            let a = Float(i) / Float(n) * 2 * .pi * 1.05
            return InkPoint(x: 0.5 + 0.06 * cosf(a) / (16.0 / 9.0), y: 0.5 + 0.06 * sinf(a), t: Float(i) / Float(n))
        }
        let mark = Mark(time: 4, strokes: [points])
        XCTAssertEqual(mark.drawLength, 1, accuracy: 1e-6)
        XCTAssertNil(mark.head(at: 3.9))
        XCTAssertEqual(mark.head(at: 4.5) ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(mark.head(at: 9) ?? -1, 1)

        let raster = try XCTUnwrap(InkRaster(mark, slideAspect: 16.0 / 9.0, pixelsPerHeight: 600))
        XCTAssertGreaterThan(raster.width, 20)
        XCTAssertGreaterThan(raster.height, 20)
        XCTAssertLessThan(raster.region.u0, 0.5 - 0.06 / (16.0 / 9.0))
        // The pen started at the right of the circle, on its middle line, and
        // came back round past it at the end.
        let mid = raster.height / 2
        let row = (0..<raster.width).map { mid * raster.width + $0 }
        let inked = row.filter { raster.cover[$0] > 0.9 }
        let right = inked.filter { $0 % raster.width > raster.width / 2 }
        let left = inked.filter { $0 % raster.width < raster.width / 2 }
        XCTAssertFalse(right.isEmpty)
        XCTAssertFalse(left.isEmpty)
        XCTAssertLessThan(right.map { raster.when[$0] }.min() ?? 1, 0.05, "where it closed, the ink was first laid at the start")
        // The left of the circle was drawn halfway round (`when` runs through the ink's own length).
        XCTAssertEqual(mark.inkLength, 1 + Mark.featherTime, accuracy: 1e-6)
        XCTAssertEqual((left.map { raster.when[$0] }.min() ?? 0) * Float(mark.inkLength), 0.47, accuracy: 0.04)
        // Nothing in the middle.
        XCTAssertEqual(raster.cover[mid * raster.width + raster.width / 2], 0)
    }

    /// Ink lies as watercolour does: deepest along the line's edges, a faint
    /// fringe just past them that creeps out a moment after the pen passed,
    /// and none of it further out.
    func testInkPoolsAtItsEdgesAndFeathersAfterThePen() throws {
        let stroke = (0...40).map { i in InkPoint(x: 0.3 + 0.4 * Float(i) / 40, y: 0.5, t: 0.6 * Float(i) / 40) }
        let mark = Mark(time: 0, strokes: [stroke])
        let raster = try XCTUnwrap(InkRaster(mark, slideAspect: 1, pixelsPerHeight: 1400))
        let w = raster.width, mid = raster.height / 2
        let half = 0.5 * mark.width * 1400
        // Down the middle of the line, away from where the pen touched down and lifted.
        let columns = Array((w * 2 / 5)..<(w * 3 / 5))
        func mean(_ values: [Float]) -> Float { values.reduce(0, +) / Float(max(values.count, 1)) }
        let middle = mean(columns.map { raster.depth[mid * w + $0] })
        let edgeRow = mid - Int(half * 0.85)
        let edges = mean(columns.map { raster.depth[edgeRow * w + $0] })
        XCTAssertGreaterThan(edges, middle + 0.08, "ink lies deepest along the line's edges")
        // Just past the edge: no pen ink, a little fringe, laid after the pen passed.
        let outRow = mid - Int((half * 1.3).rounded(.up))
        let fringe = columns.map { outRow * w + $0 }
        XCTAssertTrue(fringe.allSatisfy { raster.cover[$0] == 0 })
        XCTAssertGreaterThan(mean(fringe.map { raster.halo[$0] }), 0.02)
        XCTAssertLessThan(fringe.map { raster.halo[$0] }.max() ?? 1, 0.5)
        for k in fringe.prefix(5) {
            let laid = raster.when[mid * w + k % w], wet = raster.when[k]
            XCTAssertGreaterThan(wet, laid, "the fringe comes after the pen")
            XCTAssertLessThan((wet - laid) * Float(mark.inkLength), Float(Mark.featherTime) + 0.05)
        }
        // Well away from the line, nothing.
        XCTAssertEqual(raster.halo[0], 0)
        XCTAssertEqual(raster.cover[0], 0)
        // The ink's last fringe arrives by the end of its length.
        XCTAssertLessThanOrEqual(raster.when.max() ?? 2, 1)
        XCTAssertEqual(mark.inkHead(at: mark.time + mark.inkLength) ?? 0, 1)
    }

    /// A mark that fades goes a moment after it is drawn; one that stays
    /// lasts until the slide changes.
    func testAMarkStaysOrFades() {
        let stroke = [InkPoint(x: 0.2, y: 0.5, t: 0), InkPoint(x: 0.6, y: 0.5, t: 0.8)]
        let fades = Mark(time: 2, strokes: [stroke], fades: true)
        XCTAssertEqual(fades.presence(at: 1.9, until: nil), 0)
        XCTAssertEqual(fades.presence(at: 3.5, until: nil), 1)
        XCTAssertEqual(fades.presence(at: fades.gone + 0.01, until: nil), 0)
        XCTAssertEqual(fades.gone, 2 + 0.8 + Mark.lingers + Mark.fadeLength, accuracy: 1e-6)

        let stays = Mark(time: 2, strokes: [stroke])
        XCTAssertEqual(stays.presence(at: 20, until: nil), 1)
        XCTAssertEqual(stays.presence(at: 8.6, until: 9), 1)
        XCTAssertEqual(stays.presence(at: 9, until: 9), 0)
    }

    /// Strokes are saved as short triples, and come back the same.
    func testMarksSaveCompactly() throws {
        let mark = Mark(time: 1.5, strokes: [[InkPoint(x: 0.1234, y: 0.5, t: 0), InkPoint(x: 0.2, y: 0.25, t: 0.333)]], color: .yellow)
        let data = try JSONEncoder().encode(mark)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("[[[0.1234,0.5,0],[0.2,0.25,0.333]]]"), json)
        let back = try JSONDecoder().decode(Mark.self, from: data)
        XCTAssertEqual(back.strokes[0][1].t, 0.333, accuracy: 1e-6)
        XCTAssertEqual(back.color, .yellow)
    }
}
