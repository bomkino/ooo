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
    /// Filmed against a green screen: the green goes, and you stand in front
    /// of the backdrop itself.
    public var greenScreen: Bool?

    public init(file: String, offset: Double = 0, duration: Double, aspect: Float, mirrored: Bool? = nil, greenScreen: Bool? = nil) {
        self.file = file
        self.offset = offset
        self.duration = duration
        self.aspect = aspect
        self.mirrored = mirrored
        self.greenScreen = greenScreen
    }

    public var end: Double { offset + duration }
    public var isMirrored: Bool { mirrored ?? false }
    public var isGreenScreen: Bool { greenScreen ?? false }

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

/// Takes a green screen out from behind you. The same sum runs in the face
/// shader and in the live preview, so the room shows what the video will.
public enum GreenScreen {
    /// How much of a colour (sRGB-encoded, 0…1) is the screen, 0 (you) to 1
    /// (screen), and the colour with the screen's green spill taken out.
    public static func key(_ r: Float, _ g: Float, _ b: Float) -> (screen: Float, r: Float, g: Float, b: Float) {
        let rb = max(r, b)
        let spill = g - rb
        // Greener than anything else, for its brightness, so the screen in
        // shadow goes too; and by enough, so the dark of hair and clothes stays.
        let k = spill / max(g, 0.05)
        let screen = smoothstep((k - 0.12) / 0.2) * smoothstep((spill - 0.03) / 0.06)
        return (screen, r, min(g, rb), b)
    }

    /// The same sum, in Metal: `float4 green_screen(float3 c)` returns the
    /// colour despilled and, in w, how much of it is you.
    static let metal = """
    float4 green_screen(float3 c) {
        float rb = max(c.r, c.b);
        float spill = c.g - rb;
        float k = spill / max(c.g, 0.05);
        float screen = smoothstep(0.0, 1.0, (k - 0.12) / 0.2) * smoothstep(0.0, 1.0, (spill - 0.03) / 0.06);
        return float4(c.r, min(c.g, rb), c.b, 1.0 - screen);
    }

    """

    /// A colour cube (sRGB in, premultiplied RGBA out) that keys the screen,
    /// for Core Image: `size` steps a side.
    public static func cube(size n: Int = 32) -> Data {
        var data = [Float](repeating: 0, count: n * n * n * 4)
        let step = 1 / Float(n - 1)
        var i = 0
        for z in 0..<n {
            for y in 0..<n {
                for x in 0..<n {
                    let k = key(Float(x) * step, Float(y) * step, Float(z) * step)
                    let a = 1 - k.screen
                    data[i] = k.r * a
                    data[i + 1] = k.g * a
                    data[i + 2] = k.b * a
                    data[i + 3] = a
                    i += 4
                }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// How much reading the camera recording has taken since launch: frames
/// decoded, and readers started over. For the soak test, which watches for
/// a stage that reads far more than it shows.
public final class FaceCounts: @unchecked Sendable {
    public static let shared = FaceCounts()
    private let lock = NSLock()
    private var frames = 0
    private var restarts = 0

    func frame() { lock.withLock { frames += 1 } }
    func restart() { lock.withLock { restarts += 1 } }

    public var now: (frames: Int, restarts: Int) { lock.withLock { (frames, restarts) } }
}

/// Reads a camera recording frame by frame, forward in time, restarting on a
/// seek. Frames come oriented, as sRGB-encoded BGRA the way OOO's frames are
/// stored, and each is kept alive until the GPU has drawn with it. It reads
/// on whatever thread asks: the export's, or a `FaceStream`'s own queue,
/// never the main thread.
final class FaceReader {
    let url: URL
    private let asset: AVURLAsset
    private var reader: AVAssetReader?
    private var output: AVAssetReaderOutput?
    private var cache: CVMetalTextureCache?
    /// Turns the picture upright when the recording says it lies otherwise;
    /// nil when it is upright already, so frames come straight from the decoder.
    private let composition: AVVideoComposition?
    let duration: Double
    /// Seconds from one frame to the next.
    let frameDuration: Double
    /// The widest a frame is decoded, keeping its shape; nil for the
    /// recording's own size.
    private let widest: Int?

    struct Frame {
        var time: Double
        var texture: MTLTexture
        var hold: CVMetalTexture
    }

    private var current: Frame?
    private var pending: Frame?
    /// Where a fresh start found nothing to read (the picture ends early, or
    /// can't be read): later moments aren't tried again until an earlier one is.
    private var barren: Double?

    init(url: URL, widest: Int? = nil) {
        self.url = url
        self.widest = widest
        asset = AVURLAsset(url: url)
        duration = max(asset.duration.seconds.isFinite ? asset.duration.seconds : 0, 0)
        let track = asset.tracks(withMediaType: .video).first
        let upright = track.map { $0.preferredTransform.isIdentity } ?? true
        composition = track == nil || upright ? nil : AVVideoComposition(propertiesOf: asset)
        let fps = Double(track?.nominalFrameRate ?? 0)
        frameDuration = fps > 1 ? 1 / fps : 1.0 / 30
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, GPU.shared.device, nil, &cache)
    }

    deinit {
        reader?.cancelReading()
    }

    private func start(at time: Double) {
        FaceCounts.shared.restart()
        reader?.cancelReading()
        current = nil
        pending = nil
        reader = nil
        output = nil
        guard let track = asset.tracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: asset) else { return }
        r.timeRange = CMTimeRange(start: CMTime(seconds: max(0, time - 0.1), preferredTimescale: 6000), duration: .positiveInfinity)
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let size = track.naturalSize
        if composition == nil, let widest, size.width > CGFloat(widest), size.height > 0 {
            settings[kCVPixelBufferWidthKey as String] = widest
            settings[kCVPixelBufferHeightKey as String] = max(Int((CGFloat(widest) * size.height / size.width / 2).rounded()) * 2, 2)
        }
        let out: AVAssetReaderOutput
        if let composition {
            let c = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
            c.videoComposition = composition
            out = c
        } else {
            out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        }
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
        // Lets go of the textures of frames already drawn and dropped.
        CVMetalTextureCacheFlush(cache, 0)
        guard let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        FaceCounts.shared.frame()
        return Frame(time: CMSampleBufferGetPresentationTimeStamp(sb).seconds, texture: tex, hold: cv)
    }

    /// The frame showing `t` seconds into the recording (held at either end).
    func frame(at t: Double) -> Frame? {
        let target = min(max(t, 0), max(duration - 0.001, 0))
        if current == nil, let b = barren, target + 0.0005 >= b { return nil }
        let restart = reader == nil || current == nil || target + 0.0005 < (current?.time ?? 0) || target > (current?.time ?? 0) + 1.0
        if restart { start(at: target) }
        defer { if restart { barren = current == nil ? target : nil } }
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

/// The camera recording for the live stage, decoded on a queue of its own so
/// the window never waits on it. Asked for the frame at a moment, it answers
/// at once with the latest frame it has for then, and decodes on toward that
/// moment and a few frames past it in the background. However fast the
/// playhead is scrubbed, it starts over for the latest place asked only, one
/// at a time, never for every step; going back, it starts a little earlier
/// still, so the next steps back are already there. A frame that arrives for
/// a stage at rest is announced (`FaceCompositor.frameArrived`) so the stage
/// redraws. Frames come no wider than the stage shows them, and a scrub
/// still moving is followed a few times a second, not at every step: each
/// start over costs the Mac a decoder.
final class FaceStream: @unchecked Sendable {
    let url: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Decoded frames, oldest first, at most `kept` of them.
    private var frames: [FaceReader.Frame] = []
    private var shown: FaceReader.Frame?
    private var wanted = 0.0
    private var working = false
    private var closed = false
    /// When the recording's first frame shows; it stands for every moment before.
    private var opening: Double?
    /// On `queue` only: the reader, and the furthest moment it has read to.
    private var reader: FaceReader?
    private var reached = -Double.infinity
    /// On `queue` only: when it last started over (seconds of uptime).
    private var restarted = -Double.infinity

    /// Frames decoded past the moment asked for.
    static let ahead = 3
    /// Seconds decoded before the moment asked for, after a step back.
    static let back = 0.3
    /// Frames kept at once: those, and the ones between.
    static let kept = 14
    /// The widest a frame is decoded for the stage.
    static let widest = 1280
    /// The least time between two starts over.
    static let gap = 0.3

    init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "dog.pitch.ooo.face", qos: .userInteractive, autoreleaseFrequency: .workItem)
    }

    /// The frame for `t` seconds into the recording, from what is decoded; nil
    /// before the first frame arrives.
    func frame(at t: Double) -> FaceReader.Frame? {
        lock.lock()
        wanted = t
        if let f = due(t) { shown = f }
        let start = !working && !closed
        if start { working = true }
        let frame = shown
        lock.unlock()
        if start { queue.async { self.work() } }
        return frame
    }

    /// The latest decoded frame showing by `t`; under `lock`.
    private func due(_ t: Double) -> FaceReader.Frame? {
        let t = max(t, opening ?? 0)
        return frames.last { $0.time <= t + 0.004 }
    }

    /// Stops decoding and lets go of the recording.
    func close() {
        lock.withLock {
            closed = true
            frames = []
        }
        queue.async { self.reader = nil }
    }

    /// Decodes until it has what was last asked for. Each pass lets go of
    /// what it borrowed on the way, so a long scrub, which keeps it going,
    /// doesn't pile up a fresh decoder's worth of memory at every restart.
    private func work() {
        while autoreleasepool(invoking: { pass() }) {}
    }

    /// One pass toward the moment last asked for; false, and no longer
    /// working, once nothing new has been asked for meanwhile.
    private func pass() -> Bool {
        let (w, first, start, stop) = lock.withLock { (wanted, frames.first?.time, opening, closed) }
        if stop {
            lock.withLock { working = false }
            return false
        }
        let reader = self.reader ?? FaceReader(url: url, widest: Self.widest)
        self.reader = reader
        let step = reader.frameDuration
        // Before the first frame, the first frame.
        let t = max(w, start ?? 0)
        let still = { self.lock.withLock { self.wanted == w && !self.closed } }
        if first == nil || t + 0.0005 < first! || t > reached + 1 {
            // Back before what is decoded, or far ahead of it: start again
            // there (going back, a little before, ready for the next step back),
            // but not again so soon: wait to see where a moving scrub goes.
            let now = ProcessInfo.processInfo.systemUptime
            if now - restarted < Self.gap {
                Thread.sleep(forTimeInterval: Self.gap - (now - restarted))
                return true
            }
            restarted = now
            let backward = first.map { t < $0 } ?? false
            lock.withLock { frames = [] }
            reached = backward ? max(t - Self.back, 0) : t
            read(reader, at: reached)
            while reached < t, still() {
                reached = min(reached + step, t)
                read(reader, at: reached)
            }
        } else if t > reached {
            // Playback has caught up with the decoding: on to now.
            reached = t
            read(reader, at: t)
        }
        // A few frames past now, so each display frame finds its own waiting.
        while reached < t + Double(Self.ahead) * step, still() {
            reached += step
            read(reader, at: reached)
        }
        return lock.withLock {
            guard wanted == w || closed else { return true }
            working = false
            return false
        }
    }

    /// Reads the frame at `t`. One later than asked for, near the start, is
    /// the recording's first: nothing comes before it.
    private func read(_ reader: FaceReader, at t: Double) {
        guard let f = reader.frame(at: t) else { return }
        if t < 0.5, f.time > t + 0.004 { lock.withLock { opening = f.time } }
        add(f)
    }

    /// Adds a decoded frame unless it is one already had, and announces it
    /// when the stage, at rest, would now show it.
    private func add(_ f: FaceReader.Frame) {
        let announce: Bool = lock.withLock {
            guard f.time > frames.last?.time ?? -.infinity else { return false }
            frames.append(f)
            if frames.count > Self.kept { frames.removeFirst(frames.count - Self.kept) }
            return due(wanted).map { $0.time != shown?.time } ?? false
        }
        guard announce else { return }
        let url = self.url
        DispatchQueue.main.async { NotificationCenter.default.post(name: FaceCompositor.frameArrived, object: url) }
    }
}

/// Draws you into the room below the stage, over the finished frame.
public final class FaceCompositor {
    private let library: MTLLibrary
    private let lock = NSLock()
    /// For export: each frame exactly, read on the export's thread.
    private var readers: [(url: URL, reader: FaceReader)] = []
    /// For the live stage: decoded in the background, the most recently used last.
    private var streams: [FaceStream] = []
    /// Recordings kept open at once; a retake's new recording lets go of the oldest.
    private static let kept = 2

    /// Posted on the main queue, with the recording's URL, when a frame the
    /// live stage is waiting for has been decoded.
    public static let frameArrived = Notification.Name("dog.pitch.ooo.face-frame")

    public init() throws {
        library = try GPU.shared.library(named: "face", source: ShaderPrelude.source + GreenScreen.metal + Self.source)
    }

    /// The frame showing `t` seconds into the recording at `url`: exactly
    /// (`wait`, for export), or the latest decoded without waiting (the live stage).
    private func picture(_ url: URL, at t: Double, wait: Bool) -> FaceReader.Frame? {
        lock.lock()
        defer { lock.unlock() }
        if wait {
            let reader: FaceReader
            if let i = readers.firstIndex(where: { $0.url == url }) {
                reader = readers.remove(at: i).reader
            } else {
                reader = FaceReader(url: url)
            }
            readers.append((url: url, reader: reader))
            if readers.count > Self.kept { readers.removeFirst(readers.count - Self.kept) }
            return reader.frame(at: t)
        }
        let stream: FaceStream
        if let i = streams.firstIndex(where: { $0.url == url }) {
            stream = streams.remove(at: i)
        } else {
            stream = FaceStream(url: url)
        }
        streams.append(stream)
        while streams.count > Self.kept { streams.removeFirst().close() }
        return stream.frame(at: t)
    }

    /// Draws the recording's frame at `t` (seconds into it) over `output`:
    /// in a room `room` of the frame tall, risen `rise` of the way in with
    /// the stage, at `alpha`, with grain like the stage's; with `greenScreen`,
    /// the green behind you taken out. With `wait`, the frame is exactly the
    /// one at `t` (export); otherwise the latest one decoded, so the live
    /// stage never waits on the recording.
    func encode(_ cb: MTLCommandBuffer, url: URL, at t: Double, mirrored: Bool, greenScreen: Bool, room: Float, rise: Float,
                alpha: Float, grain: Float, frameIndex: UInt32, output: MTLTexture, wait: Bool) throws {
        guard alpha > 0.002 else { return }
        let frame = picture(url, at: t, wait: wait)
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
        var p = FaceParams(band: SIMD4(room, feather, alpha, greenScreen ? 1 : 0), crop: FaceClip.crop(pictureAspect: T, canvasAspect: C, room: room),
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
    float4 band;   // x: the room's share of the frame, y: the top edge's feather, z: alpha, w: green screen
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
    float you = 1.0;
    if (p.band.w > 0.5) {
        float4 k = green_screen(c);
        c = k.rgb;
        you = k.w;
    }
    // A fine grain, like the stage's, so the slide and you are one picture.
    uint2 px = uint2(in.position.xy);
    float n = float(pcg(px.x + px.y * 4099u + uint(p.misc.w) * 7919u) & 0xffffu) / 65535.0;
    c = saturate(c + (n - 0.5) * p.misc.z);
    float a = p.band.z * smoothstep(0.0, p.band.y, in.uv.y - top) * you;
    return float4(c * a, a);
}
"""#
}
