import CoreGraphics
import Foundation
import OOOMotion
import RenderCore
import Vision

/// Reads a slide the way a viewer would: its text, line by line, and the
/// parts that draw the eye. Runs on this Mac.
public enum SlideAnalysis {
    /// Reads the whole slide, then reads it again in close-ups for the small
    /// print the whole slide is too coarse to show: the 4-point footnote is
    /// often the detail most worth a look. Figures come from the slide's ink.
    public static func read(_ source: SlideSource, side: Int = 3200) throws -> [SlideDetail] {
        guard let whole = source.renderWhole(side: side) else { throw RenderError.io("Could not draw the slide.") }
        var found = try lines(in: whole)
        // A picture has no more detail to give than its pixels.
        if source.nativeHeight.map({ $0 > whole.height + whole.height / 4 }) ?? true {
            let tiles: [SIMD4<Float>] = [(0, 0), (1, 0), (0, 1), (1, 1)].map { c, r in
                let u0: Float = c == 0 ? 0 : 0.44, v0: Float = r == 0 ? 0 : 0.44
                return SIMD4(u0, v0, u0 + 0.56, v0 + 0.56)
            }
            var closeUps = [[SlideDetail]](repeating: [], count: tiles.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
                let r = tiles[i]
                let h = max(1, Int((Float(side) * (r.w - r.y) / ((r.z - r.x) * source.aspect)).rounded()))
                guard let image = source.render(region: r, width: side, height: h),
                      let read = try? lines(in: image) else { return }
                let mapped = read.map { d -> SlideDetail in
                    var d = d
                    d.frame = ShotFrame(center: Vec2(r.x + d.frame.center.x * (r.z - r.x), r.y + d.frame.center.y * (r.w - r.y)),
                                        size: Vec2(d.frame.size.x * (r.z - r.x), d.frame.size.y * (r.w - r.y)))
                    return d
                }
                lock.lock(); closeUps[i] = mapped; lock.unlock()
            }
            found = Director.merge(found, closeUps: closeUps.flatMap { $0 })
        }
        return found + figures(in: whole, text: found.map(\.frame.bounds))
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
