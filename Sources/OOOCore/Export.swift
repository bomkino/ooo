import CoreGraphics
import CoreVideo
import Foundation
import Metal
import OOOMotion
import RenderCore
import StageKit

/// How carefully each frame is rendered: the number of moments averaged
/// across the shutter for motion blur.
public enum ExportQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case draft, good, best

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .draft: return "Draft"
        case .good: return "Good"
        case .best: return "Best"
        }
    }
    public var detail: String {
        switch self {
        case .draft: return "Fast, no motion blur. For checking timing."
        case .good: return "Smooth motion blur. Right for most posts."
        case .best: return "The smoothest blur, slowest to render."
        }
    }
    public var samples: Int {
        switch self {
        case .draft: return 1
        case .good: return 10
        case .best: return 24
        }
    }
}

public struct ExportOptions: Sendable {
    public var codec: VideoCodec = .h264
    public var quality: ExportQuality = .good
    /// Multiplies the canvas size (0.5 for a quick preview file).
    public var scale: Double = 1
    public var includeVoice = true
    /// Each frame takes only the shutter samples its motion needs (see
    /// `SlideStage.encode`). Off renders every frame at the quality's full count.
    public var adaptiveBlur = true

    public init(codec: VideoCodec = .h264, quality: ExportQuality = .good, scale: Double = 1, includeVoice: Bool = true,
                adaptiveBlur: Bool = true) {
        self.codec = codec
        self.quality = quality
        self.scale = scale
        self.includeVoice = includeVoice
        self.adaptiveBlur = adaptiveBlur
    }
}

/// Writes an OOO video, frame-exact, with the voiceover under it.
public final class OOOExporter: @unchecked Sendable {
    public let stage: SlideStage

    public init(stage: SlideStage? = nil) throws {
        self.stage = try stage ?? SlideStage()
    }

    public struct Progress: Sendable {
        public var frame: Int
        public var total: Int
        public var fraction: Double { total > 0 ? Double(frame) / Double(total) : 0 }
    }

    /// The size a video is written at: the canvas times `scale`, rounded to even numbers.
    public static func size(_ format: CanvasFormat, scale: Double) -> (Int, Int) {
        let w = max(2, Int((Double(format.width) * scale / 2).rounded()) * 2)
        let h = max(2, Int((Double(format.height) * scale / 2).rounded()) * 2)
        return (w, h)
    }

    public func export(_ scene: SlideScene, voice: AudioTrack?, options: ExportOptions, to url: URL,
                       isCancelled: @escaping @Sendable () -> Bool = { false },
                       progress: @escaping @Sendable (Progress) -> Void = { _ in },
                       preview: (@Sendable (CGImage) -> Void)? = nil) async throws {
        let project = scene.project
        let (w, h) = Self.size(project.format, scale: options.scale)
        let fps = max(project.fps, 1)
        let duration = scene.duration
        let total = max(1, Int((duration * Double(fps)).rounded()))
        var audio: AudioTrack?
        if options.includeVoice, let voice, let v = project.voice {
            audio = VoiceLoader.placed(voice, offset: v.offset, gain: v.gain, duration: Double(total) / Double(fps))
        }
        let writer = try VideoWriter(url: url, width: w, height: h, fps: fps, codec: options.codec, audio: audio)
        let target = PixelBufferTarget(width: w, height: h)
        let gpu = GPU.shared
        // Two frames in flight: while the GPU draws one, the next is planned
        // and encoded, and the close-ups half a second ahead are drawn on
        // another core.
        let ahead = max(1, fps / 2)
        var flying: (cb: MTLCommandBuffer, buffer: CVPixelBuffer, cvTex: CVMetalTexture, index: Int)?
        func land(_ f: (cb: MTLCommandBuffer, buffer: CVPixelBuffer, cvTex: CVMetalTexture, index: Int)) throws {
            f.cb.waitUntilCompleted()
            if let e = f.cb.error { throw RenderError.io("GPU error: \(e.localizedDescription)") }
            _ = f.cvTex
            try writer.append(f.buffer)
            if let preview, f.index % 15 == 0, let img = ImageOutput.cgImage(pixelBuffer: f.buffer, keepAlpha: false) { preview(img) }
            progress(Progress(frame: f.index + 1, total: total))
        }
        do {
            for i in 0..<total {
                if isCancelled() { throw RenderError.cancelled }
                let t = Double(i) / Double(fps)
                if i == 0 {
                    for k in stride(from: 0, through: ahead, by: max(1, ahead / 3)) {
                        stage.drawAhead(scene, at: Double(k) / Double(fps), width: w, height: h)
                    }
                }
                stage.drawAhead(scene, at: Double(i + ahead) / Double(fps), width: w, height: h)
                let (buffer, texture, cvTex) = try target.next()
                guard let cb = gpu.queue.makeCommandBuffer() else { throw RenderError.io("GPU unavailable.") }
                try stage.encode(cb, scene: scene, at: t, output: texture, samples: options.quality.samples,
                                 frameIndex: UInt32(i), waitForDetail: true, adaptive: options.adaptiveBlur)
                cb.commit()
                if let f = flying { try land(f) }
                flying = (cb, buffer, cvTex, i)
            }
            if let f = flying {
                flying = nil
                try land(f)
            }
            try await writer.finish()
        } catch {
            flying?.cb.waitUntilCompleted()
            writer.cancel()
            throw error
        }
    }
}
