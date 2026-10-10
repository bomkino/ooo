import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import OOOCore
import RenderCore

/// Whether your voice and your lips stay together through a live take, as
/// far as a machine without a camera can tell: the soak test's stand-in
/// recording claps now and then (the picture flashes white for a frame and
/// the sound clicks, at the same moment). Once its take is kept, each clap
/// is found in the voice OOO kept from the recording, then in a video
/// exported from the take: in the picture of you in the room, and in the
/// sound. Each should land on its clap, and the sound on the picture.
enum SyncCheck {
    /// Clap times in a recording `length` seconds long, from start to end:
    /// whole frames at 30 fps, uneven gaps (so none is mistaken for its
    /// neighbour), clear of your coming in and going.
    static func claps(within length: Double) -> [Double] {
        let gaps = [7, 6.5, 8.5, 7, 7.5]
        var t = 4.0, times: [Double] = []
        while t < length - 1.5 {
            times.append(t)
            t += gaps[(times.count - 1) % gaps.count]
        }
        return times
    }

    /// How far off its clap anything may land, beyond a frame of the video.
    static let slack = 0.005

    @MainActor
    static func run(_ session: OOOSession, claps: [Double]) async -> (ok: Bool, lines: [String]) {
        guard !claps.isEmpty, let voice = session.project.voice, session.project.face != nil,
              let scene = session.exportScene() else {
            return (false, ["sync: FAILED, the kept take has no voice, no picture or no slide to export"])
        }
        let voiceURL = session.document.media.url(for: voice.file)
        let offset = voice.offset
        let fps = Double(max(scene.project.fps, 1))
        let room = scene.faceRoom
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("OOO sync \(UUID().uuidString).mp4")
        return await Task.detached(priority: .userInitiated) { () -> (ok: Bool, lines: [String]) in
            defer { try? FileManager.default.removeItem(at: out) }
            do {
                let track = try VoiceLoader.decode(voiceURL)
                // Draft, small and without motion blur: a flash stays in its own frame.
                let options = ExportOptions(codec: .h264, quality: .draft, scale: 0.25, includeVoice: true, adaptiveBlur: false)
                try await OOOExporter().export(scene, voice: track, options: options, to: out)
                let sound = try readSound(out)
                let pictures = try readRoom(out, room: room)
                return verdict(claps: claps, fps: fps,
                               kept: claps.map { onset(track.samples, start: offset, near: $0) },
                               picture: claps.map { flash(pictures, near: $0) },
                               sound: claps.map { onset(sound.samples, start: sound.start, near: $0) })
            } catch {
                return (false, ["sync: FAILED, couldn't export the take: \(error.localizedDescription)"])
            }
        }.value
    }

    static func verdict(claps: [Double], fps: Double, kept: [Double?], picture: [Double?], sound: [Double?]) -> (ok: Bool, lines: [String]) {
        func ms(_ s: Double?) -> String { s.map { String(format: "%+.1f ms", $0 * 1000) } ?? "not found" }
        let limit = 1 / fps + slack
        var lines: [String] = []
        var worst = 0.0, apart = 0.0, found = 0
        for (i, clap) in claps.enumerated() {
            let k = kept[i].map { $0 - clap }, p = picture[i].map { $0 - clap }, s = sound[i].map { $0 - clap }
            var line = String(format: "sync: clap at %.2f s: the kept voice clicks at %@; in the video the picture flashes at %@ and the sound clicks at %@",
                              clap, ms(k), ms(p), ms(s))
            if let p, let s {
                found += 1
                apart = max(apart, abs(s - p))
                line += String(format: ", the sound %.1f ms %@ the picture", abs(s - p) * 1000, s >= p ? "after" : "before")
            }
            for d in [k, p, s].compactMap({ $0 }) { worst = max(worst, abs(d)) }
            lines.append(line)
        }
        // Every clap must be found, in the kept voice and in the video's picture and sound alike.
        let heard = kept.compactMap({ $0 }).count
        let ok = found == claps.count && heard == claps.count && worst <= limit && apart <= limit
        lines.append(String(format: "sync: %@ (%d of %d claps found in the video, %d in the kept voice; sound and picture at most %.1f ms apart, anything at most %.1f ms off its clap; limit a frame and %.0f ms, %.1f ms)",
                            ok ? "passed" : "FAILED", found, claps.count, heard, apart * 1000, worst * 1000, slack * 1000, limit * 1000))
        return (ok, lines)
    }

    /// When the click nearest `clap` starts in interleaved stereo `samples`
    /// whose first plays at `start` seconds: the first moment it reaches half
    /// its loudest. Nil when nothing clicks there.
    static func onset(_ samples: [Float], start: Double, near clap: Double) -> Double? {
        let rate = Double(AudioTrack.sampleRate)
        let frames = samples.count / 2
        let a = max(0, Int(((clap - 0.25) - start) * rate)), b = min(frames, Int(((clap + 0.25) - start) * rate))
        guard b > a else { return nil }
        var peak: Float = 0
        for i in a..<b { peak = max(peak, abs(samples[2 * i]), abs(samples[2 * i + 1])) }
        guard peak > 0.2 else { return nil }
        for i in a..<b where max(abs(samples[2 * i]), abs(samples[2 * i + 1])) >= peak / 2 {
            return start + Double(i) / rate
        }
        return nil
    }

    /// When the room first lights up near `clap`: the first frame halfway
    /// from the room's usual brightness there to its brightest. Nil when it
    /// doesn't light up.
    static func flash(_ frames: [(t: Double, level: Double)], near clap: Double) -> Double? {
        let near = frames.filter { abs($0.t - clap) <= 0.3 }
        guard let top = near.map(\.level).max() else { return nil }
        let usual = near.map(\.level).sorted()[near.count / 2]
        guard top - usual > 0.15 else { return nil }
        return near.first { $0.level >= usual + (top - usual) / 2 }?.t
    }

    /// The video's sound, as interleaved stereo at 48 kHz, and when it starts.
    static func readSound(_ url: URL) throws -> (samples: [Float], start: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return ([], 0) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioTrack.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var samples: [Float] = []
        var start: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if start == nil { start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: bytes / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            samples += chunk
        }
        return (samples, start ?? 0)
    }

    /// How bright the room under the stage is in each of the video's frames (0…1).
    static func readRoom(_ url: URL, room: Float) throws -> [(t: Double, level: Double)] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var levels: [(t: Double, level: Double)] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(buffer) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { continue }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            // Rows run from the top: the room is the last of them.
            var sum = 0, count = 0
            for y in Int(Float(h) * (1 - room))..<h {
                for x in stride(from: 0, to: w, by: 2) {
                    let p = pixels + y * row + x * 4
                    sum += Int(p[0]) + Int(p[1]) + Int(p[2])
                    count += 3
                }
            }
            levels.append((CMSampleBufferGetPresentationTimeStamp(buffer).seconds, count > 0 ? Double(sum) / Double(count) / 255 : 0))
        }
        return levels
    }
}
