import Foundation

/// One point of a pen stroke on the slide.
public struct InkPoint: Codable, Hashable, Sendable {
    /// Across the slide, 0…1 from the left.
    public var x: Float
    /// Down the slide, 0…1 from the top.
    public var y: Float
    /// Seconds from when the mark starts drawing.
    public var t: Float

    public init(x: Float, y: Float, t: Float) {
        self.x = x
        self.y = y
        self.t = t
    }

    // Saved as [x, y, t]: a mark has a few hundred of them.
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Float.self)
        y = try c.decode(Float.self)
        t = try c.decode(Float.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode((x * 10000).rounded() / 10000)
        try c.encode((y * 10000).rounded() / 10000)
        try c.encode((t * 1000).rounded() / 1000)
    }
}

/// The pen's colours: a few, chosen to read on any slide.
public enum InkColor: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A warm marker red, for circling what matters.
    case red
    /// A highlighter yellow.
    case yellow
    /// A felt-tip green.
    case green
    /// A ballpoint blue.
    case blue
    /// Chalk white, for dark slides.
    case white
    /// Ink black.
    case black

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .white: return "White"
        case .black: return "Black"
        }
    }

    /// The colour in sRGB, 0…1.
    public var srgb: (r: Float, g: Float, b: Float) {
        switch self {
        case .red: return (0.89, 0.19, 0.16)
        case .yellow: return (1.0, 0.82, 0.12)
        case .green: return (0.16, 0.68, 0.34)
        case .blue: return (0.15, 0.42, 0.93)
        case .white: return (0.97, 0.96, 0.93)
        case .black: return (0.08, 0.08, 0.09)
        }
    }

    /// The colours OOO 1.0.1 to 1.2.0 can draw.
    public var isOriginal: Bool { self == .red || self == .yellow || self == .white || self == .black }
}

/// A shape drawn for you, as a hand would: an arrow, a box or a circle.
public enum InkShape: String, Codable, CaseIterable, Sendable {
    case arrow
    case box
    case circle
}

/// A mark drawn on the card by hand: a circle round a number, a line under
/// a word, an arrow. It draws on at the speed it was drawn, lies on the card
/// as the camera moves, and either stays until the slide changes or fades a
/// moment after it is finished.
public struct Mark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The slide it is drawn on: one of the slides after the first, or nil for the first.
    public var page: UUID?
    /// Seconds from the start when it starts drawing.
    public var time: Double
    /// The pen's strokes, in the order they were drawn.
    public var strokes: [[InkPoint]]
    public var color: InkColor
    /// A colour of your own, sRGB 0…1 (r, g, b), in place of `color`.
    public var custom: [Float]?
    /// The pen's width, as a share of the slide's height.
    public var width: Float
    /// Fades a moment after it is drawn; otherwise it stays until the slide changes.
    public var fades: Bool
    /// Seconds a mark that fades stays once drawn; nil is `lingers`.
    public var linger: Double?

    public init(id: UUID = UUID(), page: UUID? = nil, time: Double, strokes: [[InkPoint]], color: InkColor = .red,
                custom: [Float]? = nil, width: Float = Mark.penWidth, fades: Bool = false, linger: Double? = nil) {
        self.id = id
        self.page = page
        self.time = time
        self.strokes = strokes
        self.color = color
        self.custom = custom
        self.width = width
        self.fades = fades
        self.linger = linger
    }

    /// The pen as it came: a fine marker.
    public static let penWidth: Float = 0.0075
    /// The pens to choose from, finest first, as shares of the slide's height.
    public static let widths: [Float] = [0.0045, 0.0075, 0.013, 0.022]
    /// How long a mark that fades can stay, in seconds.
    public static let lingerRange: ClosedRange<Double> = 0.2...30

    /// Its ink in sRGB, 0…1: your own colour, or the pen's.
    public var ink: (r: Float, g: Float, b: Float) {
        if let c = custom, c.count == 3 { return (c[0], c[1], c[2]) }
        return color.srgb
    }

    /// Seconds it stays once drawn, when it fades.
    public var stay: Double { linger ?? Mark.lingers }

    /// Uses what OOO 1.2.1 added: a colour, a width or a stay of its own.
    public var needsOOO121: Bool { custom != nil || linger != nil || !color.isOriginal || width != Mark.penWidth }

    /// How long it takes to draw, as it was drawn.
    public var drawLength: Double { max(Double(strokes.last?.last?.t ?? 0), 0.12) }
    /// When it is all drawn.
    public var drawn: Double { time + drawLength }
    /// How long a mark that fades stays once drawn, and how long it takes to go.
    public static let lingers = 1.4
    public static let fadeLength = 0.6
    /// The last moment it shows when it fades.
    public var gone: Double { drawn + stay + Mark.fadeLength }

    /// How far it has drawn on at `t`, 0…1 of its own time (nil before it starts).
    public func head(at t: Double) -> Float? {
        guard t >= time else { return nil }
        return Float(min((t - time) / drawLength, 1))
    }

    /// How long fresh ink takes to creep out to the edge of its fringe once
    /// the pen has passed, in seconds.
    public static let featherTime = 0.4
    /// How long its ink takes to lie as it will stay: the drawing, then its
    /// last stretch of fringe.
    public var inkLength: Double { drawLength + Mark.featherTime }
    /// How far its ink has come at `t`, 0…1 of `inkLength` (nil before it starts).
    public func inkHead(at t: Double) -> Float? {
        guard t >= time else { return nil }
        return Float(min((t - time) / inkLength, 1))
    }

    /// How much of it shows at `t` (its strokes still to come aside), 0…1:
    /// all of it once it starts, then, if it fades, gone a moment after it is
    /// drawn; if it stays, gone just before `until` (the card turning to
    /// another slide).
    public func presence(at t: Double, until: Double?) -> Float {
        guard t >= time else { return 0 }
        var p: Float = 1
        if fades { p *= 1 - smoothstep(Float((t - drawn - stay) / Mark.fadeLength)) }
        if let until { p *= 1 - smoothstep(Float((t - (until - 0.3)) / 0.3)) }
        return p
    }

    /// A loop round `f` as a hand draws one, for demonstrations and checks:
    /// a little more than once round, never quite an ellipse, unhurried as
    /// the pen sets off and quick round the far side.
    public static func loop(around f: ShotFrame, slideAspect A: Float, seed: Int = 0) -> [InkPoint] {
        let n = 72
        let rx = f.size.x * 0.62 + 0.012 / max(A, 0.01), ry = f.size.y * 0.75 + 0.012
        let start = -2.4 + 0.3 * Float(seed)
        return (0...n).map { i in
            let u = Float(i) / Float(n)
            let a = start + u * 2 * .pi * 1.12
            let wobble = 1 + 0.05 * sinf(3 * a + Float(seed)) + 0.03 * sinf(5 * a + 1.3)
            let x = f.center.x + rx * cosf(a) * wobble + 0.004 * u
            let y = f.center.y + ry * sinf(a) * wobble - 0.01 * u
            let t = 0.95 * (u - 0.08 * sinf(2 * .pi * u) / (2 * .pi))
            return InkPoint(x: x, y: y, t: t)
        }
    }

    /// A shape as a hand draws one, from `a` to `b` on a slide `A` wide
    /// (points across and down it, 0…1): an arrow from `a` pointing at `b`,
    /// or a box or a circle filling the rectangle between them. Never quite
    /// ruled, drawn on at a hand's pace, slowing at corners; its strokes stay
    /// on the slide.
    public static func shape(_ kind: InkShape, from a: (x: Float, y: Float), to b: (x: Float, y: Float),
                             slideAspect A: Float, seed: Int = 0) -> [[InkPoint]] {
        // Worked out across the slide's own proportions, so a circle is round.
        let A = max(A, 0.01)
        let p0 = SIMD2<Float>(a.x * A, a.y), p1 = SIMD2<Float>(b.x * A, b.y)
        let s = Float(seed)
        var strokes: [[SIMD3<Float>]] = []
        switch kind {
        case .circle:
            let c = (p0 + p1) / 2
            let r = SIMD2<Float>(max(abs(p1.x - p0.x) / 2, 0.012), max(abs(p1.y - p0.y) / 2, 0.012))
            let length = 2 * Float.pi * (r.x + r.y) / 2 * 1.08
            let d = min(max(length / 1.3, 0.45), 1.1)
            let n = max(Int(length / 0.004), 40)
            let start: Float = -2.3 + 0.2 * sinf(s)
            strokes.append((0...n).map { i in
                let u = Float(i) / Float(n)
                let angle = start + u * 2 * .pi * 1.08
                let wobble = 1 + 0.022 * sinf(3 * angle + s) + 0.012 * sinf(5 * angle + 1.3)
                // A loop drifts a little as it closes, as a hand's does.
                let x = c.x + r.x * cosf(angle) * wobble + 0.15 * r.x * 0.04 * u
                let y = c.y + r.y * sinf(angle) * wobble - 0.15 * r.y * 0.06 * u
                return SIMD3(x, y, d * (u - 0.08 * sinf(2 * .pi * u) / (2 * .pi)))
            })
        case .box:
            let lo = SIMD2<Float>(min(p0.x, p1.x), min(p0.y, p1.y)), hi = SIMD2<Float>(max(p0.x, p1.x), max(p0.y, p1.y))
            let w = max(hi.x - lo.x, 0.012), h = max(hi.y - lo.y, 0.012)
            let corners = [SIMD2(lo.x, lo.y), SIMD2(lo.x + w, lo.y), SIMD2(lo.x + w, lo.y + h), SIMD2(lo.x, lo.y + h), SIMD2(lo.x, lo.y)]
            var points: [SIMD3<Float>] = []
            var t: Float = 0
            for k in 0..<4 {
                var from = corners[k], to = corners[k + 1]
                let side = (to - from).length, dir = (to - from) / max(side, 1e-6)
                // Each side runs a touch past its corner, the last one most.
                from -= dir * min(side * 0.02, 0.006)
                to += dir * min(side * (k == 3 ? 0.06 : 0.025), 0.012)
                let normal = SIMD2(-dir.y, dir.x)
                let bow = min(side * 0.012, 0.004) * (k % 2 == 0 ? 1 : -1) * (1 + 0.3 * sinf(s + Float(k)))
                let n = max(Int((to - from).length / 0.004), 8)
                let d = min(max(side / 1.6, 0.12), 0.4)
                for i in 0...n {
                    let u = Float(i) / Float(n)
                    let q = from + (to - from) * u + normal * bow * sinf(.pi * u)
                    points.append(SIMD3(q.x, q.y, t + d * (u - 0.1 * sinf(2 * .pi * u) / (2 * .pi))))
                }
                // The hand turns the corner.
                t += d + 0.05
            }
            strokes.append(points)
        case .arrow:
            var along = p1 - p0
            if along.length < 0.02 { along = SIMD2(0.02, 0) }
            let tip = p0 + along
            let length = along.length, dir = along / length, normal = SIMD2(-dir.y, dir.x)
            let bow = length * 0.03 * (sinf(s) >= 0 ? 1 : -1)
            let n = max(Int(length / 0.004), 10)
            let d = min(max(length / 1.5, 0.2), 0.7)
            strokes.append((0...n).map { i in
                let u = Float(i) / Float(n)
                let q = p0 + along * u + normal * bow * sinf(.pi * u)
                return SIMD3(q.x, q.y, d * (u - 0.1 * sinf(2 * .pi * u) / (2 * .pi)))
            })
            // The head: one stroke, in to the tip and back out, a moment later.
            let wing = min(max(length * 0.22, 0.025), 0.09)
            // The shaft arrives at the tip a little turned by its bow.
            let bent = dir - normal * bow * .pi / length, arriving = bent / max(bent.length, 1e-6)
            func turned(_ v: SIMD2<Float>, _ angle: Float) -> SIMD2<Float> {
                SIMD2(v.x * cosf(angle) - v.y * sinf(angle), v.x * sinf(angle) + v.y * cosf(angle))
            }
            let left = tip - turned(arriving, 0.48) * wing, right = tip - turned(arriving, -0.44) * wing * 0.95
            let m = max(Int(wing / 0.003), 8)
            let start = d + 0.12, half: Float = 0.12
            var head: [SIMD3<Float>] = []
            for i in 0...m {
                let u = Float(i) / Float(m)
                let q = left + (tip - left) * u
                head.append(SIMD3(q.x, q.y, start + half * u))
            }
            for i in 1...m {
                let u = Float(i) / Float(m)
                let q = tip + (right - tip) * u
                head.append(SIMD3(q.x, q.y, start + half + 0.02 + half * u))
            }
            strokes.append(head)
        }
        return strokes.map { stroke in
            stroke.map { InkPoint(x: min(max($0.x / A, 0), 1), y: min(max($0.y, 0), 1), t: $0.z) }
        }
    }

    /// The part of the slide it covers, padded by its pen, as (u0, v0, u1, v1).
    public func bounds(slideAspect A: Float) -> (u0: Float, v0: Float, u1: Float, v1: Float)? {
        let all = strokes.flatMap { $0 }
        guard let first = all.first else { return nil }
        var lo = (first.x, first.y), hi = (first.x, first.y)
        for p in all {
            lo = (min(lo.0, p.x), min(lo.1, p.y))
            hi = (max(hi.0, p.x), max(hi.1, p.y))
        }
        let pad = width * 1.2
        return (lo.0 - pad / max(A, 0.01), lo.1 - pad, hi.0 + pad / max(A, 0.01), hi.1 + pad)
    }
}

/// A mark drawn into pixels, as ink lies on paper: for each pixel, how much
/// the pen laid there, how much crept out past its edge while it was wet, how
/// deep it lies, and when it got there.
public struct InkRaster: Sendable {
    public let width: Int
    public let height: Int
    /// The part of the slide it covers, as (u0, v0, u1, v1).
    public let region: (u0: Float, v0: Float, u1: Float, v1: Float)
    /// The pen's own ink, 0…1, row by row from the top.
    public var cover: [Float]
    /// Ink that crept out past the pen's edge while it was wet, 0…1: a soft,
    /// uneven fringe, none under the pen's own ink.
    public var halo: [Float]
    /// How deep the pen's ink lies, 0…1: deepest along the line's edges,
    /// where ink dries darkest, where the pen touched down and where the hand
    /// slowed, and never quite even.
    public var depth: [Float]
    /// When the ink got there, 0…1 through the mark's `inkLength`: the pen's
    /// own as the pen passed, its fringe a moment after.
    public var when: [Float]

    /// Draws `mark` on a slide `A` wide at `pixelsPerHeight`, no side longer than `maxSide`.
    ///
    /// The stroke is a felt-tip's: a touch fuller where the hand slowed, and
    /// thinner where the pen touches down and lifts off.
    public init?(_ mark: Mark, slideAspect A: Float, pixelsPerHeight: Float = 1400, maxSide: Int = 2560) {
        guard let b = mark.bounds(slideAspect: A) else { return nil }
        let wWorld = (b.u1 - b.u0) * A, hWorld = b.v1 - b.v0
        let scale = min(pixelsPerHeight, Float(maxSide) / max(wWorld, hWorld, 1e-4))
        width = max(Int((wWorld * scale).rounded(.up)), 1)
        height = max(Int((hWorld * scale).rounded(.up)), 1)
        region = b
        let count = width * height
        cover = Array(repeating: 0, count: count)
        halo = Array(repeating: 0, count: count)
        depth = Array(repeating: 0, count: count)
        when = Array(repeating: 1, count: count)
        // Seconds, and how far each pixel lies from the nearest line's middle
        // (1 at its edge), how long the hand lingered there, how much fringe.
        var laidAt = [Float](repeating: .infinity, count: count)
        var fringeAt = [Float](repeating: .infinity, count: count)
        var middle = [Float](repeating: .infinity, count: count)
        var linger = [Float](repeating: 0, count: count)
        var fringe = [Float](repeating: 0, count: count)
        let half = 0.5 * mark.width * scale
        let feather = Float(Mark.featherTime)
        // Into pixels: x across, y down.
        func px(_ p: InkPoint) -> (Float, Float) { ((p.x - b.u0) * A * scale, (p.y - b.v0) * scale) }
        for stroke in mark.strokes where !stroke.isEmpty {
            let pts = stroke.map(px)
            let n = pts.count
            // Arc length along the stroke, for the taper at its ends.
            var along = [Float](repeating: 0, count: n)
            if n > 1 {
                for i in 1..<n { along[i] = along[i - 1] + hypotf(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1) }
            }
            let length = along.last ?? 0
            var radius = [Float](repeating: half, count: n)
            var slow = [Float](repeating: 1, count: n)
            for i in 0..<n {
                let a = max(i - 1, 0), c = min(i + 1, n - 1)
                let dt = max(stroke[c].t - stroke[a].t, 1e-3)
                let speed = (along[c] - along[a]) / scale / dt
                // Slide heights a second: a slow hand lets the ink pool a little.
                let pool: Float = 1.12 - 0.24 * smoothstep(speed / 1.2)
                let end = min(along[i], length - along[i])
                let taper: Float = 0.55 + 0.45 * smoothstep(end / max(3 * half, 1))
                radius[i] = half * pool * (n > 1 ? taper : 1)
                slow[i] = n > 1 ? 1 - smoothstep(speed / 0.5) : 1
            }
            // Evened out, so the width never flickers point to point.
            if n > 2 {
                let raw = radius
                for i in 1..<(n - 1) { radius[i] = 0.25 * raw[i - 1] + 0.5 * raw[i] + 0.25 * raw[i + 1] }
            }
            let segments = n == 1 ? [(0, 0)] : (0..<(n - 1)).map { ($0, $0 + 1) }
            for (i, j) in segments {
                let (x0, y0) = pts[i], (x1, y1) = pts[j]
                let r0 = radius[i], r1 = radius[j]
                let t0 = stroke[i].t, t1 = stroke[j].t
                // Wet ink creeps out a little past the pen's edge.
                let reach = max(r0, r1) * 1.7 + 2
                let minX = max(Int((min(x0, x1) - reach).rounded(.down)), 0)
                let maxX = min(Int((max(x0, x1) + reach).rounded(.up)), width - 1)
                let minY = max(Int((min(y0, y1) - reach).rounded(.down)), 0)
                let maxY = min(Int((max(y0, y1) + reach).rounded(.up)), height - 1)
                guard minX <= maxX, minY <= maxY else { continue }
                let dx = x1 - x0, dy = y1 - y0
                let ll = dx * dx + dy * dy
                for y in minY...maxY {
                    let cy = Float(y) + 0.5
                    for x in minX...maxX {
                        let cx = Float(x) + 0.5
                        let s = ll > 1e-6 ? clamp01(((cx - x0) * dx + (cy - y0) * dy) / ll) : 0
                        let d = hypotf(cx - (x0 + s * dx), cy - (y0 + s * dy))
                        let r = r0 + (r1 - r0) * s
                        let at = t0 + (t1 - t0) * s
                        let k = y * width + x
                        let c = clamp01(r + 0.5 - d)
                        if c > 0 {
                            if c > cover[k] { cover[k] = c }
                            if at < laidAt[k] { laidAt[k] = at }
                            middle[k] = min(middle[k], d / max(r, 0.5))
                            linger[k] = max(linger[k], slow[i] + (slow[j] - slow[i]) * s)
                        }
                        // The fringe: fainter the further out, and later.
                        let spread = 0.65 * r + 1
                        let out = clamp01((d - r) / spread)
                        guard out < 1 else { continue }
                        let f = (1 - out) * (1 - out)
                        if f > fringe[k] { fringe[k] = f }
                        let wet = at + feather * powf(out, 0.8)
                        if wet < fringeAt[k] { fringeAt[k] = wet }
                    }
                }
            }
            // Where the pen touched down, the ink pooled for a moment.
            let (sx, sy) = pts[0], sr = radius[0] * 1.6
            let lo = (max(Int(sx - 2 * sr), 0), max(Int(sy - 2 * sr), 0))
            let hi = (min(Int(sx + 2 * sr), width - 1), min(Int(sy + 2 * sr), height - 1))
            if lo.0 <= hi.0, lo.1 <= hi.1 {
                for y in lo.1...hi.1 {
                    for x in lo.0...hi.0 {
                        let d = hypotf(Float(x) + 0.5 - sx, Float(y) + 0.5 - sy) / sr
                        let k = y * width + x
                        linger[k] = max(linger[k], expf(-d * d))
                    }
                }
            }
        }
        // Never quite even: a slow mottle across the line and a fine grain,
        // the same each time the mark is drawn.
        let seed = mark.strokes.first?.first.map { Int($0.x * 9973) &* 31 &+ Int($0.y * 7919) } ?? 0
        let coarse = InkNoise(seed: seed, period: max(6 * half, 4))
        let fine = InkNoise(seed: seed &+ 1, period: max(1.2 * half, 2))
        let edge = InkNoise(seed: seed &+ 2, period: max(1.5 * half, 2.5))
        let total = Float(mark.inkLength)
        for y in 0..<height {
            for x in 0..<width {
                let k = y * width + x
                let fx = Float(x), fy = Float(y)
                let c = cover[k]
                let rim = middle[k].isFinite ? smoothstep(0.3, 1.0, middle[k]) : 0
                let mottle = 0.16 * (coarse.at(fx, fy) - 0.5) + 0.07 * (fine.at(fx, fy) - 0.5)
                depth[k] = c > 0 ? clamp01(0.42 + 0.36 * rim + 0.28 * linger[k] + mottle) : 0
                let h = (1 - c) * fringe[k] * 0.42 * (0.45 + 1.1 * edge.at(fx, fy))
                halo[k] = h > 0.004 ? clamp01(h) : 0
                let amount = c + halo[k]
                guard amount > 0 else { continue }
                let laid = c > 0 ? laidAt[k] : 0, wet = halo[k] > 0 ? fringeAt[k] : 0
                when[k] = clamp01((laid * c + wet * halo[k]) / amount / total)
            }
        }
    }
}

/// Smooth value noise over pixels, 0…1, for the unevenness of ink.
struct InkNoise {
    let seed: Int
    let period: Float

    func at(_ x: Float, _ y: Float) -> Float {
        let u = x / period, v = y / period
        let i = Int(floorf(u)), j = Int(floorf(v))
        let fu = smoothstep(u - Float(i)), fv = smoothstep(v - Float(j))
        func corner(_ a: Int, _ b: Int) -> Float { 0.5 + 0.5 * hashSigned(a &* 73856093 ^ b &* 19349663, UInt32(truncatingIfNeeded: seed)) }
        let top = lerp(corner(i, j), corner(i + 1, j), fu)
        let bottom = lerp(corner(i, j + 1), corner(i + 1, j + 1), fu)
        return lerp(top, bottom, fv)
    }
}
