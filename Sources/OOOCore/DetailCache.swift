import CoreGraphics
import Foundation
import Metal
import OOOMotion
import RenderCore
import StageKit

/// Keeps the slide sharp however close the camera goes.
///
/// The whole slide lives in one texture. When the camera needs more detail
/// than that holds, the part it sees is drawn again at the resolution the
/// frame needs (from the slide's vectors where it has them) and laid over the
/// slide exactly. Regions and resolutions are snapped to a ladder of steps a
/// half-octave apart, so neighbouring frames share a detail and a cache of a
/// few is enough for a whole video.
public final class DetailCache: @unchecked Sendable {
    public struct Patch: @unchecked Sendable {
        public let region: SIMD4<Float>
        public let texture: MTLTexture
        /// Texels per slide height.
        public let density: Float
        let key: Key
    }

    struct Key: Hashable {
        var lu: Int, lv: Int, iu: Int, iv: Int, d: Int
    }

    struct Plan {
        var key: Key
        var region: SIMD4<Float>
        var width: Int
        var height: Int
        var density: Float
    }

    public let source: SlideSource
    /// Texels per slide height in the whole-slide texture.
    public let baseDensity: Float
    /// Called on the main queue when a detail drawn in the background is ready.
    public var onReady: (() -> Void)?

    private let lock = NSLock()
    private var patches: [Key: Patch] = [:]
    private var order: [Key] = []
    private var pending: Set<Key> = []
    private let queue = DispatchQueue(label: "dog.pitch.ooo.detail", qos: .userInitiated)
    private let capacity = 6
    private static let maxSide = 4096

    public init(source: SlideSource, baseDensity: Float) {
        self.source = source
        self.baseDensity = baseDensity
    }

    /// The detail for a frame that sees `footprint`, if the whole-slide texture
    /// is not sharp enough. With `wait`, draws it now (export); otherwise
    /// returns the best detail already drawn and draws the right one in the
    /// background (preview).
    public func patch(for footprint: ViewFootprint, wait: Bool) -> Patch? {
        guard let plan = plan(for: footprint) else { return nil }
        lock.lock()
        if let hit = patches[plan.key] {
            touch(plan.key)
            lock.unlock()
            return hit
        }
        let drawing = pending.contains(plan.key)
        lock.unlock()
        if wait {
            // Already being drawn ahead: wait for that rather than draw it twice.
            if drawing {
                queue.sync {}
                lock.lock()
                let hit = patches[plan.key]
                lock.unlock()
                if let hit { return hit }
            }
            return draw(plan)
        }
        lock.lock()
        let fallback = patches.values
            .filter { contains($0.region, footprint.region) && $0.density > baseDensity * 1.15 }
            .max { $0.density < $1.density }
        let start = !pending.contains(plan.key)
        if start { pending.insert(plan.key) }
        lock.unlock()
        if start {
            queue.async { [weak self] in
                guard let self else { return }
                _ = self.draw(plan)
                self.lock.lock()
                self.pending.remove(plan.key)
                self.lock.unlock()
                DispatchQueue.main.async { self.onReady?() }
            }
        }
        return fallback
    }

    /// Starts drawing, in the background, the detail a frame that sees
    /// `footprint` will need, unless it is drawn or on its way.
    public func prepare(for footprint: ViewFootprint) {
        guard let plan = plan(for: footprint) else { return }
        lock.lock()
        let start = patches[plan.key] == nil && !pending.contains(plan.key)
        if start { pending.insert(plan.key) }
        lock.unlock()
        guard start else { return }
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.draw(plan)
            self.lock.lock()
            self.pending.remove(plan.key)
            self.lock.unlock()
        }
    }

    /// Whether `patch` is all the detail a frame that sees `footprint` needs.
    public func isSharp(_ patch: Patch?, for footprint: ViewFootprint) -> Bool {
        guard let plan = plan(for: footprint) else { return true }
        return patch?.key == plan.key
    }

    /// Forgets every detail (the slide changed).
    public func clear() {
        lock.lock()
        patches.removeAll()
        order.removeAll()
        lock.unlock()
    }

    // MARK: Planning

    func plan(for fp: ViewFootprint) -> Plan? {
        let A = source.aspect
        var needed = fp.pixelsPerUnit * 1.1
        if let limit = source.densityLimit { needed = min(needed, limit) }
        guard needed > baseDensity * 1.08 else { return nil }
        let r = fp.region
        let eu = max((r.z - r.x) * 1.35, 0.004), ev = max((r.w - r.y) * 1.35, 0.004)
        // Half-octave ladder: extent = 2^(−L/2), the smallest step that covers.
        let lu = max(0, Int(floorf(-2 * log2f(min(eu, 1))))), lv = max(0, Int(floorf(-2 * log2f(min(ev, 1)))))
        let su = powf(2, -Float(lu) / 2), sv = powf(2, -Float(lv) / 2)
        let cu = (r.x + r.z) / 2, cv = (r.y + r.w) / 2
        let stepU = su / 4, stepV = sv / 4
        let iu = Int((cu / stepU).rounded()), iv = Int((cv / stepV).rounded())
        var u0 = Float(iu) * stepU - su / 2, v0 = Float(iv) * stepV - sv / 2
        u0 = min(max(u0, 0), max(1 - su, 0))
        v0 = min(max(v0, 0), max(1 - sv, 0))
        var region = SIMD4(u0, v0, min(u0 + su, 1), min(v0 + sv, 1))
        region = source.snapped(region)
        let d = Int(ceilf(2 * log2f(needed)))
        var density = powf(2, Float(d) / 2)
        if let limit = source.densityLimit { density = min(density, limit) }
        var h = density * (region.w - region.y)
        var w = h * (region.z - region.x) * A / max(region.w - region.y, 1e-6)
        let longest = max(w, h)
        if longest > Float(Self.maxSide) {
            let k = Float(Self.maxSide) / longest
            w *= k
            h *= k
            density *= k
        }
        guard density > baseDensity * 1.08 else { return nil }
        return Plan(key: Key(lu: lu, lv: lv, iu: iu, iv: iv, d: d), region: region,
                    width: max(64, Int(w.rounded())), height: max(64, Int(h.rounded())), density: density)
    }

    private func contains(_ outer: SIMD4<Float>, _ inner: SIMD4<Float>) -> Bool {
        outer.x <= inner.x + 1e-4 && outer.y <= inner.y + 1e-4 && outer.z >= inner.z - 1e-4 && outer.w >= inner.w - 1e-4
    }

    // MARK: Drawing

    private func draw(_ plan: Plan) -> Patch? {
        guard let image = source.render(region: plan.region, width: plan.width, height: plan.height),
              let media = try? MediaLoader.texture(from: image) else { return nil }
        let patch = Patch(region: plan.region, texture: media.texture,
                          density: Float(image.height) / max(plan.region.w - plan.region.y, 1e-6), key: plan.key)
        lock.lock()
        patches[plan.key] = patch
        touch(plan.key)
        while order.count > capacity {
            let old = order.removeFirst()
            patches[old] = nil
        }
        lock.unlock()
        return patch
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
