import CoreGraphics
import Foundation
import OOOMotion
import Vision

/// Reads a slide the way a viewer would: its text, line by line, and the
/// parts that draw the eye. Runs on this Mac.
public enum SlideAnalysis {
    /// The slide's details, in slide space (v down).
    public static func details(of image: CGImage) throws -> [SlideDetail] {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        // Small print counts: it is often the detail most worth a look.
        text.minimumTextHeight = 0.003
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([text, saliency])

        var out: [SlideDetail] = []
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let b = observation.boundingBox
            out.append(SlideDetail(frame: frame(b), text: candidate.string, kind: .text, confidence: candidate.confidence))
        }
        if let result = saliency.results?.first {
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
