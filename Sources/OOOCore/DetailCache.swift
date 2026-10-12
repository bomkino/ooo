import CoreGraphics
import Foundation
import Metal
import QuartzCore
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
    /// Its place in the budget every slide's details share.
    private let serial = DetailLedger.shared.serial()

    public init(source: SlideSource, baseDensity: Float) {
        self.source = source
        self.baseDensity = baseDensity
    }

    deinit { DetailLedger.shared.forget(serial) }

    /// What every slide's details hold on the GPU together, in bytes.
    public static var bytesHeld: Int { DetailLedger.shared.bytesHeld }

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
            DetailLedger.shared.touch(serial, plan.key)
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
        DetailLedger.shared.forget(serial)
    }

    /// Lets one detail go, for the shared budget.
    fileprivate func evict(_ key: Key) {
        lock.lock()
        patches[key] = nil
        order.removeAll { $0 == key }
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
        var dropped: [Key] = []
        while order.count > capacity {
            let old = order.removeFirst()
            patches[old] = nil
            dropped.append(old)
        }
        lock.unlock()
        // Outside this cache's lock: the budget may ask any cache, this one too, to let go.
        let ledger = DetailLedger.shared
        for old in dropped { ledger.drop(serial, old) }
        ledger.hold(serial, plan.key, bytes: media.texture.allocatedSize, owner: self)
        return patch
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// One memory budget for every slide's close-ups, in every window and every
/// export: about 256 MB on an 8 GB Mac. Over it, the detail seen longest ago
/// goes first, anywhere, but never one a frame has used in the last moment.
/// Under memory pressure the budget halves, then empties to what is on screen.
final class DetailLedger: @unchecked Sendable {
    static let shared = DetailLedger()

    private struct Held {
        let bytes: Int
        var used: CFTimeInterval
        weak var owner: DetailCache?
    }
    private struct ID: Hashable {
        let cache: UInt64
        let key: DetailCache.Key
    }

    let limit: Int
    private var target: Int
    private let lock = NSLock()
    private var held: [ID: Held] = [:]
    private var total = 0
    private var serials: UInt64 = 0
    private var pressure: DispatchSourceMemoryPressure?
    /// What a frame used just now stays, whatever the budget.
    private static let inUse: CFTimeInterval = 0.25

    init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let mb = 1 << 20
        limit = min(max(Int(physicalMemory / 32), 160 * mb), 768 * mb)
        target = limit
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            self.lock.lock()
            self.target = event.contains(.critical) ? 0 : event.contains(.warning) ? self.limit / 2 : self.limit
            self.lock.unlock()
            self.trim(keeping: nil)
        }
        source.activate()
        pressure = source
    }

    /// The bytes held now, for the soak's line.
    var bytesHeld: Int { lock.lock(); defer { lock.unlock() }; return total }

    func serial() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        serials += 1
        return serials
    }

    func hold(_ cache: UInt64, _ key: DetailCache.Key, bytes: Int, owner: DetailCache) {
        let id = ID(cache: cache, key: key)
        lock.lock()
        if let old = held[id] { total -= old.bytes }
        held[id] = Held(bytes: bytes, used: CACurrentMediaTime(), owner: owner)
        total += bytes
        lock.unlock()
        trim(keeping: id)
    }

    func touch(_ cache: UInt64, _ key: DetailCache.Key) {
        let now = CACurrentMediaTime()
        lock.lock()
        held[ID(cache: cache, key: key)]?.used = now
        lock.unlock()
    }

    func drop(_ cache: UInt64, _ key: DetailCache.Key) {
        lock.lock()
        if let old = held.removeValue(forKey: ID(cache: cache, key: key)) { total -= old.bytes }
        lock.unlock()
    }

    func forget(_ cache: UInt64) {
        lock.lock()
        for id in held.keys where id.cache == cache {
            if let old = held.removeValue(forKey: id) { total -= old.bytes }
        }
        lock.unlock()
    }

    /// Lets the details seen longest ago go until the budget holds. Each cache
    /// is asked once the ledger's lock is let go, so no two locks are ever held.
    private func trim(keeping: ID?) {
        let now = CACurrentMediaTime()
        var victims: [(DetailCache, DetailCache.Key)] = []
        lock.lock()
        if total > target {
            let oldest = held.filter { $0.key != keeping && now - $0.value.used > Self.inUse }
                .sorted { $0.value.used < $1.value.used }
            for (id, h) in oldest where total > target {
                held[id] = nil
                total -= h.bytes
                if let owner = h.owner { victims.append((owner, id.key)) }
            }
        }
        lock.unlock()
        for (cache, key) in victims { cache.evict(key) }
    }
}
