import CoreGraphics
import Foundation
import OOOMotion
import RenderCore
import Vision

/// Reads a slide the way a viewer would: its text, line by line, and the
/// parts that draw the eye. Runs on this Mac.
public enum SlideAnalysis {
    /// Reads the whole slide in one pass, drawn tall enough that its small
    /// print (often the detail most worth a look) is several pixels high:
    /// `height` pixels, or as many as a picture has to give (twice its own,
    /// sharpened). One large pass finds what close-ups of each quarter did,
    /// in a third of the pixels (`ooo-lab readcheck` compares the two).
    /// Figures come from the slide's ink.
    public static func read(_ source: SlideSource, height: Int = 2160) throws -> [SlideDetail] {
        let side = source.aspect >= 1 ? Int((Float(height) * source.aspect).rounded()) : height
        guard let whole = source.renderWhole(side: side) else { throw RenderError.io("Could not draw the slide.") }
        let found = try lines(in: whole)
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
