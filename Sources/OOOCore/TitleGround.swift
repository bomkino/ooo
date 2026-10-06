import BackdropKit
import Foundation
import Metal
import RenderCore

/// What lies behind the opening title: the backdrop itself, drawn small and
/// read across the title's band, so the ink is chosen against the pixels it
/// sits on rather than the palette's average (Studio, for one, paints the top
/// of the frame with a palette's darkest colour).
enum TitleGround {
    private static let lock = NSLock()
    private static let renderer = try? BackdropRenderer()
    private static var cache: [Int: Float] = [:]

    /// The backdrop's mean luminance (linear) across the band, with the part of
    /// the backdrop the stage shows through `uv` (see `SlideScene.backdropUV`),
    /// or nil when the GPU can't say.
    static func luminance(_ settings: BackdropSettings, phase: Double, uv: SIMD4<Float>, canvasAspect C: Float,
                          band: (top: Float, bottom: Float)) -> Float? {
        var h = Hasher()
        h.combine(settings)
        h.combine(Int((phase * 1000).rounded()))
        h.combine(uv)
        h.combine(C)
        h.combine(band.top)
        h.combine(band.bottom)
        let key = h.finalize()
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[key] { return known }
        guard let renderer else { return nil }
        let rows = 96, cols = max(8, Int((Float(rows) * C).rounded()))
        let gpu = GPU.shared
        let tex = gpu.makeTexture(width: cols, height: rows, format: BackdropRenderer.format, storage: .shared, label: "title ground")
        guard let cb = gpu.queue.makeCommandBuffer() else { return nil }
        do { try renderer.encode(cb, target: tex, settings: settings, phase: phase) } catch { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.error == nil else { return nil }
        var px = [Float16](repeating: 0, count: cols * rows * 4)
        tex.getBytes(&px, bytesPerRow: cols * 4 * MemoryLayout<Float16>.stride,
                     from: MTLRegionMake2D(0, 0, cols, rows), mipmapLevel: 0)
        var sum: Float = 0, n: Float = 0
        let top = max(Int(band.top * Float(rows)), 0), bottom = min(Int((band.bottom * Float(rows)).rounded(.up)), rows)
        // Across the middle of the frame, where the words are set.
        for y in top..<max(bottom, top + 1) {
            for x in Int(0.12 * Float(cols))..<Int(0.88 * Float(cols)) {
                let u = (Float(x) + 0.5) / Float(cols), v = (Float(y) + 0.5) / Float(rows)
                let su = (u - 0.5) * uv.x + 0.5 + uv.z, sv = (v - 0.5) * uv.y + 0.5 + uv.w
                let ix = min(max(Int(su * Float(cols)), 0), cols - 1), iy = min(max(Int(sv * Float(rows)), 0), rows - 1)
                let i = (iy * cols + ix) * 4
                sum += 0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2])
                n += 1
            }
        }
        guard n > 0, sum.isFinite else { return nil }
        let mean = max(sum / n, 0)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = mean
        return mean
    }

    /// Whether light ink reads better than dark on a ground of luminance `y`:
    /// whichever gives the larger contrast ratio.
    static func lightInk(onLuminance y: Float) -> Bool {
        let light: Float = 0.91, dark: Float = 0.007
        return (light + 0.05) / (y + 0.05) >= (y + 0.05) / (dark + 0.05)
    }
}
