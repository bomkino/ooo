import AVFoundation
import CoreGraphics
import Foundation
import Metal
import OOOCore
import RenderCore

// ooo-lab bench and colorcheck: how long OOO takes, on what machine, and
// whether a video's colours survive the encoder.

/// The machine a measurement was taken on.
func machineRecord() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &model, &size, nil, 0)
    let info = ProcessInfo.processInfo
    return "\(String(cString: model)), \(GPU.shared.device.name), \(info.activeProcessorCount) cores, "
        + "\(info.physicalMemory >> 30) GB, macOS \(info.operatingSystemVersionString)"
}

/// The value below which `p` of `values` fall.
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

final class Stamps: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    func add() {
        lock.lock()
        times.append(ProcessInfo.processInfo.systemUptime)
        lock.unlock()
    }
    var all: [Double] {
        lock.lock(); defer { lock.unlock() }
        return times
    }
}

/// Exports `scene` to `url` and returns when each frame was written.
func timedExport(_ scene: SlideScene, options: ExportOptions, to url: URL) throws -> [Double] {
    let stamps = Stamps()
    let box = ErrorBox()
    let done = DispatchSemaphore(value: 0)
    let job = Task.detached {
        do {
            let exporter = try OOOExporter()
            try await exporter.export(scene, voice: nil, options: options, to: url, progress: { _ in stamps.add() })
        } catch {
            box.error = error
        }
        done.signal()
    }
    _ = job
    done.wait()
    if let error = box.error { throw error }
    return stamps.all
}

/// An export at Good, full size: in all and frame by frame; then the live
/// stage at a laptop's preview size, playing (four samples, no waiting for
/// close-ups) and paused (eight), in GPU time a frame.
func bench(_ scene: SlideScene) throws {
    print("machine: \(machineRecord())")
    let format = scene.project.format
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ooo-bench-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let started = ProcessInfo.processInfo.systemUptime
    let stamps = try timedExport(scene, options: ExportOptions(quality: .good), to: url)
    let total = (stamps.last ?? started) - started
    let frames = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
    print(String(format: "export, Good, %d × %d: %.1f s of video in %.1f s (%.1f× real time); a frame p50 %.1f ms, p95 %.1f, p99 %.1f, worst %.1f",
                 format.width, format.height, scene.duration, total, scene.duration / max(total, 1e-6),
                 percentile(frames, 0.5), percentile(frames, 0.95), percentile(frames, 0.99), frames.max() ?? 0))

    let stage = try SlideStage()
    let gpu = GPU.shared
    let out = gpu.makeTexture(width: 720, height: 1280, format: .bgra8Unorm, usage: [.renderTarget, .shaderRead])
    let fps = Double(max(scene.project.fps, 1))
    let n = 150
    for (label, samples, wait) in [("playing", 4, false), ("paused", 8, true)] {
        var ms: [Double] = []
        for k in 0..<n {
            let t = scene.duration * Double(k) / Double(n)
            guard let cb = gpu.queue.makeCommandBuffer() else { throw RenderError.io("GPU unavailable.") }
            _ = try stage.encode(cb, scene: scene, at: t, output: out, samples: samples, frameIndex: UInt32(t * fps),
                                 waitForDetail: wait)
            cb.commit()
            cb.waitUntilCompleted()
            if k > 0 { ms.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        let late = Double(ms.filter { $0 > 1000.0 / 60 }.count) / Double(max(ms.count, 1))
        print(String(format: "preview, %@, 720 × 1280, %d samples: GPU p50 %.1f ms, p95 %.1f, p99 %.1f, worst %.1f; %.0f%% over a 60 Hz frame",
                     label, samples, percentile(ms, 0.5), percentile(ms, 0.95), percentile(ms, 0.99), ms.max() ?? 0, late * 100))
    }
    print(String(format: "bench: export %.1f s for %.1f s of video", total, scene.duration))
}

/// The frame as drawn against the same frame decoded from the video: at the
/// opening and every landing, CIE76 ΔE over every fourth pixel, as written
/// (the values a player that ignores colour tags shows) and as macOS shows
/// the file (its BT.709 tags applied).
func colorcheck(_ scene: SlideScene) throws {
    let options = ExportOptions(quality: .good, scale: 0.5)
    let (w, h) = OOOExporter.size(scene.project.format, scale: options.scale)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ooo-colorcheck-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try timedExport(scene, options: options, to: url)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let fps = Int32(max(scene.project.fps, 1))
    let stage = try SlideStage()
    let beats = scene.choreography.beats
    var written: [Double] = [], shown: [Double] = []
    var bias = [Double](repeating: 0, count: 3), shownBias = [Double](repeating: 0, count: 3)
    for (i, beat) in beats.enumerated() where i == 0 || !beat.isOverview {
        let t = min(beat.land + min(0.7, beat.hold * 0.45), scene.duration - 0.05)
        let index = Int((t * Double(fps)).rounded())
        let drawn = try stage.still(scene, at: Double(index) / Double(fps), width: w, height: h, samples: options.quality.samples)
        let decoded = try generator.copyCGImage(at: CMTime(value: CMTimeValue(index), timescale: fps), actualTime: nil)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        // As written: each image's own values, with no conversion.
        let (a, b) = (pixels(drawn, space: drawn.colorSpace ?? sRGB, w, h), pixels(decoded, space: decoded.colorSpace ?? sRGB, w, h))
        // As macOS shows them: both converted to sRGB by their tags.
        let (c, d) = (pixels(drawn, space: sRGB, w, h), pixels(decoded, space: sRGB, w, h))
        compare(a, b, into: &written, bias: &bias)
        compare(c, d, into: &shown, bias: &shownBias)
    }
    func line(_ e: [Double], _ bias: [Double]) -> String {
        let n = Double(max(e.count, 1))
        return String(format: "mean ΔE %.2f, p95 %.2f, worst %.1f; average shift R %+.2f G %+.2f B %+.2f (of 255)",
                      e.reduce(0, +) / n, percentile(e, 0.95), e.max() ?? 0, bias[0] / n, bias[1] / n, bias[2] / n)
    }
    print("as written:      " + line(written, bias))
    print("as macOS shows:  " + line(shown, shownBias))
    print(String(format: "colorcheck: through the encoder, mean ΔE %.2f as written", written.reduce(0, +) / Double(max(written.count, 1))))
}

/// An image's RGBA bytes at `w` × `h`, drawn into `space`.
private func pixels(_ image: CGImage, space: CGColorSpace, _ w: Int, _ h: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: w * h * 4)
    out.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return out
}

/// ΔE between two RGBA images at every fourth pixel, both read as sRGB values.
private func compare(_ a: [UInt8], _ b: [UInt8], into e: inout [Double], bias: inout [Double]) {
    var i = 0
    while i + 3 < min(a.count, b.count) {
        let x = lab(a[i], a[i + 1], a[i + 2]), y = lab(b[i], b[i + 1], b[i + 2])
        e.append(((x.0 - y.0) * (x.0 - y.0) + (x.1 - y.1) * (x.1 - y.1) + (x.2 - y.2) * (x.2 - y.2)).squareRoot())
        for c in 0..<3 { bias[c] += Double(b[i + c]) - Double(a[i + c]) }
        i += 16
    }
}

/// sRGB bytes as CIE L*a*b* (D65).
private func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Double, Double, Double) {
    func linear(_ v: UInt8) -> Double {
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let (R, G, B) = (linear(r), linear(g), linear(b))
    let X = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
    let Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
    let Z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
    return (116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z)))
}
