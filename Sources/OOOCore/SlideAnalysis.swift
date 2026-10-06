import CoreGraphics
import Foundation
import OOOMotion
import RenderCore
import Vision

/// Reads a slide the way a viewer would: its text, line by line, and the
/// parts that draw the eye. Runs on this Mac.
public enum SlideAnalysis {
    /// Reads the whole slide, then reads its small print again in close-ups
    /// drawn just around it: the 4-point footnote is often the detail most
    /// worth a look, and at the whole slide's scale it is found but misread.
    /// Only the small print is drawn again, not every quarter of the slide,
    /// so a wide slide reads in a third of the time (`ooo-lab readcheck`
    /// compares the two). Figures come from the slide's ink.
    public static func read(_ source: SlideSource, side: Int = 3200) throws -> [SlideDetail] {
        guard let whole = source.renderWhole(side: side) else { throw RenderError.io("Could not draw the slide.") }
        var found = try lines(in: whole)
        let seen = found
        let regions = smallPrint(seen)
        var closeUps = [[SlideDetail]](repeating: [], count: regions.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: regions.count) { i in
            let r = regions[i]
            // The line a good 40 pixels tall, the close-up no more than 3200 across.
            let small = seen.filter { $0.kind == .text && contains(r, $0.frame.bounds) }.map(\.frame.size.y).min() ?? 0.01
            var perHeight = max(40 / max(small, 1e-3), Float(side) / max(source.aspect, 1))
            perHeight = min(perHeight, 3200 / max((r.z - r.x) * source.aspect, 1e-3), 3200 / max(r.w - r.y, 1e-3))
            let w = max(1, Int(((r.z - r.x) * source.aspect * perHeight).rounded()))
            let h = max(1, Int(((r.w - r.y) * perHeight).rounded()))
            guard let image = source.render(region: r, width: w, height: h), let read = try? lines(in: image) else { return }
            let mapped = read.map { d -> SlideDetail in
                var d = d
                d.frame = ShotFrame(center: Vec2(r.x + d.frame.center.x * (r.z - r.x), r.y + d.frame.center.y * (r.w - r.y)),
                                    size: Vec2(d.frame.size.x * (r.z - r.x), d.frame.size.y * (r.w - r.y)))
                return d
            }
            lock.lock(); closeUps[i] = mapped; lock.unlock()
        }
        // A close-up's reading of a line replaces the whole slide's.
        for (r, read) in zip(regions, closeUps) where !read.isEmpty {
            found.removeAll { d in
                d.kind == .text && d.frame.size.y < smallLine && contains(r, d.frame.bounds)
                    && read.contains { overlap($0.frame.bounds, d.frame.bounds) > 0 }
            }
        }
        found = Director.merge(found, closeUps: closeUps.flatMap { $0 }, smallerThan: smallLine)
        return found + figures(in: whole, text: found.map(\.frame.bounds))
    }

    /// Lines shorter than this (a share of the slide's height) are small print.
    static let smallLine: Float = 0.022

    /// Where the small print is: each small line with room around it, run
    /// together where they meet, as (u0, v0, u1, v1).
    static func smallPrint(_ found: [SlideDetail]) -> [SIMD4<Float>] {
        var regions: [SIMD4<Float>] = found.filter { $0.kind == .text && $0.frame.size.y < smallLine }.map { d in
            let b = d.frame.bounds, mx = 0.02 + 0.1 * d.frame.size.x, my = 1.5 * d.frame.size.y
            return SIMD4(max(b.x - mx, 0), max(b.y - my, 0), min(b.z + mx, 1), min(b.w + my, 1))
        }
        var merged = true
        while merged {
            merged = false
            outer: for i in regions.indices {
                for j in regions.indices where j > i && overlap(regions[i], regions[j]) > 0 {
                    let a = regions[i], b = regions[j]
                    regions[i] = SIMD4(min(a.x, b.x), min(a.y, b.y), max(a.z, b.z), max(a.w, b.w))
                    regions.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return regions
    }

    static func overlap(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        max(0, min(a.z, b.z) - max(a.x, b.x)) * max(0, min(a.w, b.w) - max(a.y, b.y))
    }

    static func contains(_ r: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        b.x >= r.x - 1e-4 && b.y >= r.y - 1e-4 && b.z <= r.z + 1e-4 && b.w <= r.w + 1e-4
    }

    /// The lines of text in an image, in its own space (v down).
    public static func lines(in image: CGImage) throws -> [SlideDetail] {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        // Small print counts: it is often the detail most worth a look.
        text.minimumTextHeight = 0.003
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([text])
        return (text.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return SlideDetail(frame: frame(observation.boundingBox), text: candidate.string, kind: .text,
                               confidence: candidate.confidence)
        }
    }

    /// The figures in an image: its ink that is not text, gathered into regions.
    public static func figures(in image: CGImage, text: [SIMD4<Float>]) -> [SlideDetail] {
        let w = 640, h = max(1, Int((Double(w) * Double(image.height) / Double(max(image.width, 1))).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The bitmap's first row is the top of the image.
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        let luma = (0..<(w * h)).map { Float(bytes[$0]) / 255 }
        return FigureFinder.figures(luma: luma, width: w, height: h, text: text).map { b in
            SlideDetail(frame: ShotFrame(center: Vec2((b.x + b.z) / 2, (b.y + b.w) / 2), size: Vec2(b.z - b.x, b.w - b.y)),
                        kind: .figure)
        }
    }

    /// Vision's normalised box (origin bottom left) as a slide frame (v down).
    static func frame(_ b: CGRect) -> ShotFrame {
        ShotFrame(center: Vec2(Float(b.midX), Float(1 - b.midY)), size: Vec2(Float(b.width), Float(b.height)))
    }
}
