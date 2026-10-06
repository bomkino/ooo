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
    /// Chalk white, for dark slides.
    case white
    /// Ink black.
    case black

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .white: return "White"
        case .black: return "Black"
        }
    }

    /// The colour in sRGB, 0…1.
    public var srgb: (r: Float, g: Float, b: Float) {
        switch self {
        case .red: return (0.89, 0.19, 0.16)
        case .yellow: return (1.0, 0.82, 0.12)
        case .white: return (0.97, 0.96, 0.93)
        case .black: return (0.08, 0.08, 0.09)
        }
    }
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
    /// The pen's width, as a share of the slide's height.
    public var width: Float
    /// Fades a moment after it is drawn; otherwise it stays until the slide changes.
    public var fades: Bool

    public init(id: UUID = UUID(), page: UUID? = nil, time: Double, strokes: [[InkPoint]], color: InkColor = .red,
                width: Float = Mark.penWidth, fades: Bool = false) {
        self.id = id
        self.page = page
        self.time = time
        self.strokes = strokes
        self.color = color
        self.width = width
        self.fades = fades
    }

    /// One pen: a fine marker.
    public static let penWidth: Float = 0.0075

    /// How long it takes to draw, as it was drawn.
    public var drawLength: Double { max(Double(strokes.last?.last?.t ?? 0), 0.12) }
    /// When it is all drawn.
    public var drawn: Double { time + drawLength }
    /// How long a mark that fades stays once drawn, and how long it takes to go.
    public static let lingers = 1.4
    public static let fadeLength = 0.6
    /// The last moment it shows when it fades.
    public var gone: Double { drawn + Mark.lingers + Mark.fadeLength }

    /// How far it has drawn on at `t`, 0…1 of its own time (nil before it starts).
    public func head(at t: Double) -> Float? {
        guard t >= time else { return nil }
        return Float(min((t - time) / drawLength, 1))
    }

    /// How much of it shows at `t` (its strokes still to come aside), 0…1:
    /// all of it once it starts, then, if it fades, gone a moment after it is
    /// drawn; if it stays, gone just before `until` (the card turning to
    /// another slide).
    public func presence(at t: Double, until: Double?) -> Float {
        guard t >= time else { return 0 }
        var p: Float = 1
        if fades { p *= 1 - smoothstep(Float((t - drawn - Mark.lingers) / Mark.fadeLength)) }
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

/// A mark drawn into pixels: for each pixel, how much ink covers it and
/// when (0…1 through the mark) the pen first got there.
public struct InkRaster: Sendable {
    public let width: Int
    public let height: Int
    /// The part of the slide it covers, as (u0, v0, u1, v1).
    public let region: (u0: Float, v0: Float, u1: Float, v1: Float)
    /// Coverage, 0…1, row by row from the top.
    public var cover: [Float]
    /// When the pen got there, 0…1 through the mark.
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
        cover = Array(repeating: 0, count: width * height)
        when = Array(repeating: 1, count: width * height)
        let total = Float(mark.drawLength)
        let half = 0.5 * mark.width * scale
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
            for i in 0..<n {
                let a = max(i - 1, 0), c = min(i + 1, n - 1)
                let dt = max(stroke[c].t - stroke[a].t, 1e-3)
                let speed = (along[c] - along[a]) / scale / dt
                // Slide heights a second: a slow hand lets the ink pool a little.
                let pool: Float = 1.12 - 0.24 * smoothstep(speed / 1.2)
                let end = min(along[i], length - along[i])
                let taper: Float = 0.55 + 0.45 * smoothstep(end / max(3 * half, 1))
                radius[i] = half * pool * (n > 1 ? taper : 1)
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
                let t0 = stroke[i].t / max(total, 1e-3), t1 = stroke[j].t / max(total, 1e-3)
                let reach = max(r0, r1) + 1.5
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
                        let c = clamp01(r + 0.5 - d)
                        guard c > 0 else { continue }
                        let k = y * width + x
                        if c > cover[k] { cover[k] = c }
                        let at = t0 + (t1 - t0) * s
                        if at < when[k] { when[k] = at }
                    }
                }
            }
        }
    }
}
