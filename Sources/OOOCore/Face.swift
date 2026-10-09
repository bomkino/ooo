import AVFoundation
import CoreVideo
import Foundation
import Metal
import OOOMotion
import RenderCore

/// You on camera, recorded during a live take. While the stage is up, you
/// stand in the room below it: the picture fills the room edge to edge,
/// rises in with the stage and settles away with it, and its top edge melts
/// into the backdrop, so the slide and you share one frame.
public struct FaceClip: Codable, Hashable, Sendable {
    /// File name inside the document's Media folder: a movie (its own sound
    /// is not used; the voiceover is).
    public var file: String
    /// Seconds into the video where the recording starts.
    public var offset: Double
    /// Length of the recording in seconds.
    public var duration: Double
    /// Width / height of the picture as it plays.
    public var aspect: Float
    /// Shows the picture as a mirror does, the way you saw yourself while recording.
    public var mirrored: Bool?

    public init(file: String, offset: Double = 0, duration: Double, aspect: Float, mirrored: Bool? = nil) {
        self.file = file
        self.offset = offset
        self.duration = duration
        self.aspect = aspect
        self.mirrored = mirrored
    }

    public var end: Double { offset + duration }
    public var isMirrored: Bool { mirrored ?? false }

    /// Seconds you take to come in at the start of the recording and to go at its end.
    public static let fadeIn = 0.3
    public static let fadeOut = 0.35

    /// The part of the picture that fills a room `room` of a canvas
    /// `canvasAspect` wide, as (u0, v0, u1, v1): the middle of a picture
    /// wider than the room, the upper middle of a taller one, where a face is.
    public static func crop(pictureAspect T: Float, canvasAspect C: Float, room: Float) -> SIMD4<Float> {
        let band = C / max(room, 0.05)
        if T > band {
            let w = band / T
            return SIMD4(0.5 - w / 2, 0, 0.5 + w / 2, 1)
        }
        let h = T / band
        let top = min(max(0.42 - h / 2, 0), 1 - h)
        return SIMD4(0, top, 1, top + h)
    }
}

extension SlideScene {
    /// How you show in the room at `t`: how far the stage has risen (0…1)
    /// and how much of you shows; nil while you don't.
    public func faceShown(at t: Double) -> (rise: Float, alpha: Float)? {
        guard let clip = project.face, faceURL != nil else { return nil }
        let u = t - clip.offset
        guard u > 0, u < clip.duration else { return nil }
        let rise = choreography.liftAmount(at: t)
        guard rise > 0.001 else { return nil }
        let ends = smoothstep(Float(u / FaceClip.fadeIn)) * (1 - smoothstep(Float((u - (clip.duration - FaceClip.fadeOut)) / FaceClip.fadeOut)))
        let alpha = ends * presence(at: t) * smoothstep(rise / 0.6)
        return alpha > 0.002 ? (rise, alpha) : nil
    }

    /// The share of the frame you stand in while the stage is up.
    public var faceRoom: Float {
        let room = project.lift?.room ?? Lift.defaultRoom
        return min(max(room, Lift.roomRange.lowerBound), Lift.roomRange.upperBound)
    }
}

/// Reads a camera recording frame by frame, forward in time, restarting on a
/// seek. Frames come oriented, as sRGB-encoded BGRA the way OOO's frames are
/// stored, and each is kept alive until the GPU has drawn with it.
final class FaceReader {
    let url: URL
    private let asset: AVURLAsset
    private var reader: AVAssetReader?
    private var output: AVAssetReaderVideoCompositionOutput?
    private var cache: CVMetalTextureCache?
    private let composition: AVVideoComposition?
    let duration: Double

    struct Frame {
        var time: Double
        var texture: MTLTexture
        var hold: CVMetalTexture
    }

    private var current: Frame?
    private var pending: Frame?

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
        duration = max(asset.duration.seconds.isFinite ? asset.duration.seconds : 0, 0)
        composition = asset.tracks(withMediaType: .video).isEmpty ? nil : AVVideoComposition(propertiesOf: asset)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, GPU.shared.device, nil, &cache)
    }

    private func start(at time: Double) {
        reader?.cancelReading()
        current = nil
        pending = nil
        reader = nil
        output = nil
        guard let track = asset.tracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: asset) else { return }
        r.timeRange = CMTimeRange(start: CMTime(seconds: max(0, time - 0.1), preferredTimescale: 6000), duration: .positiveInfinity)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        out.videoComposition = composition
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return }
        r.add(out)
        guard r.startReading() else { return }
        reader = r
        output = out
    }

    private func read() -> Frame? {
        guard let output, let cache, let sb = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cv: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &cv)
        guard let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return Frame(time: CMSampleBufferGetPresentationTimeStamp(sb).seconds, texture: tex, hold: cv)
    }

    /// The frame showing `t` seconds into the recording (held at either end).
    func frame(at t: Double) -> Frame? {
        let target = min(max(t, 0), max(duration - 0.001, 0))
        if reader == nil || current == nil || target + 0.0005 < (current?.time ?? 0) || target > (current?.time ?? 0) + 1.0 {
            start(at: target)
        }
        var guardCount = 0
        while guardCount < 240 {
            guardCount += 1
            if pending == nil { pending = read() }
            guard let p = pending else { break }
            if p.time <= target + 0.0005 || current == nil {
                current = p
                pending = nil
            } else {
                break
            }
        }
        return current
    }
}

/// Draws you into the room below the stage, over the finished frame.
public final class FaceCompositor {
    private let library: MTLLibrary
    private var readers: [URL: FaceReader] = [:]
    private let lock = NSLock()

    public init() throws {
        library = try GPU.shared.library(named: "face", source: ShaderPrelude.source + Self.source)
    }

    /// Draws the recording's frame at `t` (seconds into it) over `output`:
    /// in a room `room` of the frame tall, risen `rise` of the way in with
    /// the stage, at `alpha`, with grain like the stage's.
    func encode(_ cb: MTLCommandBuffer, url: URL, at t: Double, mirrored: Bool, room: Float, rise: Float, alpha: Float,
                grain: Float, frameIndex: UInt32, output: MTLTexture) throws {
        guard alpha > 0.002 else { return }
        lock.lock()
        let reader: FaceReader
        if let r = readers[url] {
            reader = r
        } else {
            reader = FaceReader(url: url)
            readers[url] = reader
        }
        let frame = reader.frame(at: t)
        lock.unlock()
        guard let frame else { return }
        let gpu = GPU.shared
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "face"
        enc.setRenderPipelineState(try gpu.renderPipeline(.init(library: "face", vertex: "fs_vertex", fragment: "face_fragment",
                                                                color: output.pixelFormat, blend: .over), library: library))
        let C = Float(output.width) / Float(max(output.height, 1))
        let T = Float(frame.texture.width) / Float(max(frame.texture.height, 1))
        // The top edge melts into the backdrop over a short distance.
        let feather = 0.05 * min(room / Lift.defaultRoom, 1.2)
        var p = FaceParams(band: SIMD4(room, feather, alpha, 0), crop: FaceClip.crop(pictureAspect: T, canvasAspect: C, room: room),
                           misc: SIMD4(rise, mirrored ? 1 : 0, grain, Float(frameIndex % 4096)))
        enc.setFragmentBytes(&p, length: MemoryLayout<FaceParams>.stride, index: 0)
        enc.setFragmentTexture(frame.texture, index: 0)
        enc.setFragmentSamplerState(gpu.sampler(.linearClamp), index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        // The decoded frame stays alive until the GPU has drawn with it.
        let hold = frame.hold
        cb.addCompletedHandler { _ in withExtendedLifetime(hold) {} }
    }

    struct FaceParams {
        var band: SIMD4<Float>
        var crop: SIMD4<Float>
        var misc: SIMD4<Float>
    }

    static let source = #"""
struct FaceParams {
    float4 band;   // x: the room's share of the frame, y: the top edge's feather, z: alpha
    float4 crop;   // the picture's part that fills the room: u0, v0, u1, v1
    float4 misc;   // x: how far the stage has risen, y: mirrored, z: grain, w: frame
};

// You in the room: the band rises with the stage from below the frame, the
// picture fills it, and its top edge melts into what is behind.
fragment float4 face_fragment(FSOut in [[stage_in]], texture2d<float> face [[texture(0)]], sampler s [[sampler(0)]],
                              constant FaceParams &p [[buffer(0)]]) {
    float room = p.band.x;
    float top = 1.0 - room * p.misc.x;
    float v = (in.uv.y - top) / room;
    if (v < 0.0) return float4(0.0);
    float u = p.misc.y > 0.5 ? 1.0 - in.uv.x : in.uv.x;
    float2 tuv = float2(mix(p.crop.x, p.crop.z, u), mix(p.crop.y, p.crop.w, v));
    float3 c = face.sample(s, tuv).rgb;
    // A fine grain, like the stage's, so the slide and you are one picture.
    uint2 px = uint2(in.position.xy);
    float n = float(pcg(px.x + px.y * 4099u + uint(p.misc.w) * 7919u) & 0xffffu) / 65535.0;
    c = saturate(c + (n - 0.5) * p.misc.z);
    float a = p.band.z * smoothstep(0.0, p.band.y, in.uv.y - top);
    return float4(c * a, a);
}
"""#
}
