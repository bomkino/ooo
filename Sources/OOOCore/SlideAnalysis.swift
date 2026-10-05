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
    /// often the detail most worth a look.
    public static func read(_ source: SlideSource, side: Int = 3200) throws -> [SlideDetail] {
        guard let whole = source.renderWhole(side: side) else { throw RenderError.io("Could not draw the slide.") }
        let found = try details(of: whole)
        // A picture has no more detail to give than its pixels.
        if let native = source.nativeHeight, native <= whole.height + whole.height / 4 { return found }
        let tiles: [SIMD4<Float>] = [(0, 0), (1, 0), (0, 1), (1, 1)].map { c, r in
            let u0: Float = c == 0 ? 0 : 0.44, v0: Float = r == 0 ? 0 : 0.44
            return SIMD4(u0, v0, u0 + 0.56, v0 + 0.56)
        }
        var closeUps = [[SlideDetail]](repeating: [], count: tiles.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
            let r = tiles[i]
            let w = side
            let h = max(1, Int((Float(w) * (r.w - r.y) / ((r.z - r.x) * source.aspect)).rounded()))
            guard let image = source.render(region: r, width: w, height: h),
                  let lines = try? details(of: image, figures: false) else { return }
            let mapped = lines.map { d -> SlideDetail in
                var d = d
                d.frame = ShotFrame(center: Vec2(r.x + d.frame.center.x * (r.z - r.x), r.y + d.frame.center.y * (r.w - r.y)),
                                    size: Vec2(d.frame.size.x * (r.z - r.x), d.frame.size.y * (r.w - r.y)))
                return d
            }
            lock.lock(); closeUps[i] = mapped; lock.unlock()
        }
        return Director.merge(found, closeUps: closeUps.flatMap { $0 })
    }

    /// The details of one image, in its own space (v down): its lines of text
    /// and, unless asked not to, the parts that draw the eye.
    public static func details(of image: CGImage, figures: Bool = true) throws -> [SlideDetail] {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        // Small print counts: it is often the detail most worth a look.
        text.minimumTextHeight = 0.003
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform(figures ? [text, attention, objects] : [text])

        var out: [SlideDetail] = []
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let b = observation.boundingBox
            out.append(SlideDetail(frame: frame(b), text: candidate.string, kind: .text, confidence: candidate.confidence))
        }
        guard figures else { return out }
        // Attention finds where the eye goes; objectness finds the things
        // themselves, usually tighter. The director keeps the tightest.
        for result in (attention.results ?? []) + (objects.results ?? []) {
            for object in result.salientObjects ?? [] {
                out.append(SlideDetail(frame: frame(object.boundingBox), kind: .figure, confidence: object.confidence))
            }
        }
        return out
    }

    /// Vision's normalised box (origin bottom left) as a slide frame (v down).
    static func frame(_ b: CGRect) -> ShotFrame {
        ShotFrame(center: Vec2(Float(b.midX), Float(1 - b.midY)), size: Vec2(Float(b.width), Float(b.height)))
    }
}
