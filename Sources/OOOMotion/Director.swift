import Foundation

/// Something on the slide worth a look, as found by reading the slide: a line
/// of text or a figure.
public struct SlideDetail: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text
        case figure
    }

    public var frame: ShotFrame
    public var text: String
    public var kind: Kind
    public var confidence: Float

    public init(frame: ShotFrame, text: String = "", kind: Kind = .text, confidence: Float = 1) {
        self.frame = frame
        self.text = text
        self.kind = kind
        self.confidence = confidence
    }
}

/// A group of details read as one thing: a paragraph, a headline over two
/// lines, a figure.
public struct DetailBlock: Hashable, Sendable {
    public enum Role: String, Sendable {
        case headline, numbers, figure, text, smallPrint
    }

    public var bounds: SIMD4<Float>
    public var text: String
    /// Mean line height, in slide heights; 0 for figures.
    public var lineHeight: Float
    public var lines: Int
    public var role: Role
    /// How many separate things it holds side by side (a row of numbers is
    /// several, read along as one shot).
    public var items: Int = 1

    public var center: Vec2 { Vec2((bounds.x + bounds.z) / 2, (bounds.y + bounds.w) / 2) }
    public var size: Vec2 { Vec2(bounds.z - bounds.x, bounds.w - bounds.y) }
}

/// Everything the director needs to plan a tour of the slide.
public struct DirectorInput: Sendable {
    public var details: [SlideDetail]
    /// The voiceover's words, times from the video's start. With them, each
    /// shot lands just before the words that name what it frames, in the
    /// order they are said.
    public var words: [SpokenWord]?
    public var slideAspect: Float
    public var canvasAspect: Float
    /// When the first shot may land (after the slide has arrived).
    public var start: Double
    /// Seconds between shots when there is no voice to follow.
    public var spacing: Double
    public var maxShots: Int
    /// The part of the canvas the framings sit in.
    public var safe: SafeArea
    /// The least view height, in slide heights, at which the slide stays
    /// sharp on this canvas (a picture's pixels run out closer than that);
    /// nil for vectors, which stay sharp at any distance.
    public var minViewHeight: Float?
    /// The opening framing the tour starts from.
    public var overview: Shot?

    public init(details: [SlideDetail], words: [SpokenWord]? = nil, slideAspect: Float, canvasAspect: Float,
                start: Double, spacing: Double = 2.9, maxShots: Int = 6, safe: SafeArea = .none,
                minViewHeight: Float? = nil, overview: Shot? = nil) {
        self.details = details
        self.words = words
        self.slideAspect = slideAspect
        self.canvasAspect = canvasAspect
        self.start = start
        self.spacing = spacing
        self.maxShots = maxShots
        self.safe = safe
        self.minViewHeight = minViewHeight
        self.overview = overview
    }
}

/// Plans a tour of a slide the way a careful presenter would: the headline
/// first, then the moments worth stopping on in reading order, with the
/// smallest print saved for last, each framed with room to breathe and seen
/// from the side that lets the rest of the slide fall away into focus.
public enum Director {
    // MARK: Reading the slide

    /// Groups lines of text into blocks and keeps figures the text does not cover.
    public static func blocks(_ details: [SlideDetail]) -> [DetailBlock] {
        let lines = details.filter { $0.kind == .text && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.frame.minV < $1.frame.minV }
        var blocks: [(bounds: SIMD4<Float>, texts: [String], heights: [Float])] = []
        for line in lines {
            let b = line.frame.bounds
            let h = line.frame.size.y
            var merged = false
            for i in blocks.indices.reversed() {
                let blk = blocks[i]
                let meanH = blk.heights.reduce(0, +) / Float(blk.heights.count)
                let gap = b.y - blk.bounds.w
                let overlapU = min(b.z, blk.bounds.z) - max(b.x, blk.bounds.x)
                let alignedLeft = abs(b.x - blk.bounds.x) < max(meanH, 0.012) * 1.5
                let similar = max(h, meanH) / max(min(h, meanH), 1e-4) < 1.6
                if gap < meanH * 0.95 && gap > -meanH * 0.5 && similar && (overlapU > 0 || alignedLeft) {
                    blocks[i].bounds = SIMD4(min(blk.bounds.x, b.x), min(blk.bounds.y, b.y), max(blk.bounds.z, b.z), max(blk.bounds.w, b.w))
                    blocks[i].texts.append(line.text)
                    blocks[i].heights.append(h)
                    merged = true
                    break
                }
            }
            if !merged { blocks.append((b, [line.text], [h])) }
        }
        var out: [DetailBlock] = blocks.map { blk in
            let mean = blk.heights.reduce(0, +) / Float(blk.heights.count)
            return DetailBlock(bounds: blk.bounds, text: blk.texts.joined(separator: " "), lineHeight: mean,
                               lines: blk.texts.count, role: .text)
        }
        // Figures the text does not already account for. A "figure" that
        // fills most of the slide is the slide itself, which the overview
        // already shows; of overlapping figures the tightest wins.
        var figures: [SIMD4<Float>] = []
        let candidates = details.filter { $0.kind == .figure }.map(\.frame.bounds)
            .sorted { area($0) < area($1) }
        for f in candidates {
            let a = max(area(f), 1e-6)
            guard a > 0.004, a < 0.35 else { continue }
            let covered = out.reduce(Float(0)) { acc, blk in acc + overlap(f, blk.bounds) } / a
            let repeated = figures.contains { overlap(f, $0) > 0.5 * min(a, area($0)) }
            if covered < 0.5 && !repeated {
                figures.append(f)
                out.append(DetailBlock(bounds: f, text: "", lineHeight: 0, lines: 0, role: .figure))
            }
        }
        // Roles: the largest type is the headline; big type with figures in it
        // is numbers; the smallest running text, if it is really small, is
        // small print.
        let texts = out.indices.filter { out[$0].role == .text }
        if let top = texts.max(by: { out[$0].lineHeight < out[$1].lineHeight }), out[top].lineHeight > 0.035 {
            out[top].role = .headline
        }
        // Type size is judged against the body of the slide; a chart's axis
        // labels would make every number in it look big. They sit just
        // outside the plot's ink, so a figure counts with a margin around it.
        let figs = out.filter { $0.role == .figure }.map { f -> SIMD4<Float> in
            let m = 0.12 * f.size
            return SIMD4(f.bounds.x - m.x, f.bounds.y - m.y, f.bounds.z + m.x, f.bounds.w + m.y)
        }
        let body = texts.filter { i in
            let c = out[i].center
            return !figs.contains { c.x > $0.x && c.x < $0.z && c.y > $0.y && c.y < $0.w }
        }
        let sizes = (body.isEmpty ? texts : body).map { out[$0].lineHeight }.sorted()
        let median = sizes.dropFirst(sizes.count / 2).first ?? 0
        for i in texts where out[i].role == .text {
            let digits = out[i].text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            // A figure's own labels count when they are set at least as large
            // as the slide's running text (a total, a ring's value), not when
            // they are axis ticks.
            let c = out[i].center
            let inFigure = figs.contains { c.x > $0.x && c.x < $0.z && c.y > $0.y && c.y < $0.w }
            let big = out[i].lineHeight >= median * 1.15 || (inFigure && out[i].lineHeight >= median * 0.95)
            if digits > 0 && big && out[i].text.count < 60 {
                out[i].role = .numbers
            }
        }
        out = rowsOfNumbers(captioned(out))
        // Small print is a sentence, not a label: a kicker in small capitals,
        // a page number or a chart's caption is small but not the thing to
        // linger on. Of similar sizes, the longer note wins.
        let sentences = out.indices.filter { i in
            let c = out[i].center
            return out[i].role == .text && out[i].text.split(separator: " ").count >= 4
                && !figs.contains { c.x > $0.x && c.x < $0.z && c.y > $0.y && c.y < $0.w }
        }
        func smallness(_ i: Int) -> Float {
            out[i].lineHeight * (1 - 0.15 * min(Float(out[i].text.split(separator: " ").count) / 12, 1))
        }
        if let tiny = sentences.min(by: { smallness($0) < smallness($1) }),
           out[tiny].lineHeight < 0.02, out[tiny].lineHeight < median * 0.72 || out[tiny].lineHeight < 0.012, texts.count > 2 {
            out[tiny].role = .smallPrint
        }
        return out
    }

    /// Numbers set side by side at one size ("3.1×", "62", "94%" across the
    /// foot of a slide) are one row, read along in one shot as they are said.
    static func rowsOfNumbers(_ blocks: [DetailBlock]) -> [DetailBlock] {
        var out = blocks
        var taken = Set<Int>()
        let numbers = out.indices.filter { out[$0].role == .numbers }.sorted { out[$0].bounds.x < out[$1].bounds.x }
        for a in numbers where !taken.contains(a) {
            var row = out[a]
            for b in numbers where b != a && !taken.contains(b) && out[b].bounds.x > row.bounds.x {
                let n = out[b]
                let shared = min(row.bounds.w, n.bounds.w) - max(row.bounds.y, n.bounds.y)
                let ratio = max(n.lineHeight, row.lineHeight) / max(min(n.lineHeight, row.lineHeight), 1e-4)
                // The gap in slide widths against line heights: loose on a wide slide, which is fine.
                let gap = n.bounds.x - row.bounds.z
                guard shared > 0.6 * min(row.size.y, n.size.y), ratio < 1.3, gap > 0, gap < 4 * row.lineHeight else { continue }
                row.bounds = SIMD4(row.bounds.x, min(row.bounds.y, n.bounds.y), n.bounds.z, max(row.bounds.w, n.bounds.w))
                row.text += " " + n.text
                row.items += 1
                taken.insert(b)
            }
            out[a] = row
        }
        return out.indices.filter { !taken.contains($0) }.map { out[$0] }
    }

    /// A number with its caption under it ("62" over "new customers") is one
    /// thing to look at and one thing said: the caption joins the number.
    static func captioned(_ blocks: [DetailBlock]) -> [DetailBlock] {
        var out = blocks
        var taken = Set<Int>()
        for n in out.indices where out[n].role == .numbers {
            let nb = out[n].bounds, h = out[n].lineHeight
            let caption = out.indices.filter { c in
                guard c != n, !taken.contains(c), out[c].role == .text || out[c].role == .smallPrint else { return false }
                let cb = out[c].bounds
                let gap = cb.y - nb.w
                let aligned = abs(cb.x - nb.x) < h * 0.8 || (out[c].center.x > nb.x && out[c].center.x < nb.z)
                return gap > -h * 0.3 && gap < h * 0.9 && aligned && out[c].lineHeight < h * 0.8 && out[c].lines <= 2
                    && out[c].text.count < 48
            }.min { out[$0].bounds.y < out[$1].bounds.y }
            guard let c = caption else { continue }
            let cb = out[c].bounds
            out[n].bounds = SIMD4(min(nb.x, cb.x), min(nb.y, cb.y), max(nb.z, cb.z), max(nb.w, cb.w))
            out[n].text += " " + out[c].text
            taken.insert(c)
        }
        return out.indices.filter { !taken.contains($0) }.map { out[$0] }
    }

    /// Adds the small lines that close-up reads of the slide found to what the
    /// whole-slide read found. Close-ups see small print the whole slide is
    /// too coarse for; a line read twice, or cut in two where close-ups meet,
    /// becomes one line with the longer reading.
    public static func merge(_ whole: [SlideDetail], closeUps: [SlideDetail], smallerThan maxHeight: Float = 0.022) -> [SlideDetail] {
        var out = whole
        for c in closeUps where c.kind == .text && c.frame.size.y < maxHeight
            && !c.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let cb = c.frame.bounds
            let same = out.indices.first { i in
                let k = out[i]
                guard k.kind == .text else { return false }
                let kb = k.frame.bounds
                let ratio = c.frame.size.y / max(k.frame.size.y, 1e-6)
                let vertical = max(0, min(cb.w, kb.w) - max(cb.y, kb.y))
                let horizontal = min(cb.z, kb.z) - max(cb.x, kb.x)
                let sameLine = ratio > 0.6 && ratio < 1.6 && horizontal > 0
                    && vertical > 0.5 * min(c.frame.size.y, k.frame.size.y)
                // Short words and single letters get looser boxes each read.
                return sameLine || overlap(cb, kb) > 0.3 * min(area(cb), area(kb))
            }
            if let i = same {
                let kb = out[i].frame.bounds
                let u = SIMD4(min(cb.x, kb.x), min(cb.y, kb.y), max(cb.z, kb.z), max(cb.w, kb.w))
                out[i].frame = ShotFrame(center: Vec2((u.x + u.z) / 2, (u.y + u.w) / 2), size: Vec2(u.z - u.x, u.w - u.y))
                if c.text.count > out[i].text.count { out[i].text = c.text }
                out[i].confidence = max(out[i].confidence, c.confidence)
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func overlap(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        max(0, min(a.z, b.z) - max(a.x, b.x)) * max(0, min(a.w, b.w) - max(a.y, b.y))
    }

    static func area(_ b: SIMD4<Float>) -> Float {
        max(0, b.z - b.x) * max(0, b.w - b.y)
    }

    // MARK: Choosing and ordering

    /// The blocks worth a shot, in the order the camera visits them. Blocks
    /// `keep` turns down are never chosen.
    public static func tour(_ found: [DetailBlock], maxShots: Int, keep: (DetailBlock) -> Bool = { _ in true }) -> [DetailBlock] {
        let figures = found.filter { $0.role == .figure }
        /// The figure a block sits in or labels (a total just above the last
        /// bar, a caption under the axis), if any.
        func host(_ b: DetailBlock) -> DetailBlock? {
            guard b.role != .figure else { return nil }
            return figures.first { f in
                let m = 0.12 * f.size
                let across = b.center.x > f.bounds.x - m.x && b.center.x < f.bounds.z + m.x
                let within = across && b.center.y > f.bounds.y - m.y && b.center.y < f.bounds.w + m.y
                // A chart's title sits a little above its plot: it is read with the chart.
                let title = across && b.role == .text && b.lines <= 2
                    && b.bounds.w <= f.bounds.y + 0.01 && b.bounds.w > f.bounds.y - 0.15 * f.size.y
                return within || title
            }
        }
        func score(_ b: DetailBlock) -> Float {
            switch b.role {
            case .headline: return 10
            // A number in a chart is usually the point of the chart.
            case .numbers: return 6 + b.lineHeight * 20 + (host(b) == nil ? 0 : 1)
            // A large figure is often what the slide is about.
            case .figure: return 6 + (b.size.x * b.size.y) * 12
            case .smallPrint: return 4.5
            case .text: return 2 + b.lineHeight * 30 + min(Float(b.lines), 4) * 0.3
            }
        }
        // Running text earns a shot when it says something: a lone word (a
        // logo, a page number) or a figure's own title is seen with its figure,
        // and a running header or footer ("Series A update • Confidential")
        // is the deck's furniture, not this slide's point.
        func furniture(_ b: DetailBlock) -> Bool {
            (b.center.y < 0.14 || b.center.y > 0.86) && b.lines == 1 && b.text.split(separator: " ").count < 8
        }
        let blocks = found.filter { b in
            keep(b) && (b.role != .text || (b.text.split(separator: " ").count >= 3 && host(b) == nil && !furniture(b)))
        }
        let limit = max(1, maxShots)
        // The smallest print, when there is some, always gets the last shot:
        // it is the detail nobody else would have noticed.
        let small = Array(blocks.filter { $0.role == .smallPrint }.prefix(limit > 1 ? 1 : 0))
        let chosen = Array(blocks.filter { $0.role != .smallPrint }.sorted { score($0) > score($1) }
            .prefix(limit - small.count))
        return readingOrder(chosen, host: host) + small
    }

    /// The order a reader takes: the headline, then the slide cut the way a
    /// layout is read (XY-cut): into bands across the slide wherever a clear
    /// gap runs all the way across, and bands into columns wherever one runs
    /// all the way down, top to bottom and left to right. A detail in a
    /// figure comes straight after the figure, so the camera shows the whole
    /// before going closer.
    static func readingOrder(_ chosen: [DetailBlock], host: (DetailBlock) -> DetailBlock?) -> [DetailBlock] {
        let headline = chosen.filter { $0.role == .headline }
        let rest = chosen.filter { $0.role != .headline }
        let shown = rest.filter { $0.role == .figure }.map(\.bounds)
        // Each block reads at its figure's place, when its figure is shown.
        let spans = rest.map { b in host(b).flatMap { f in shown.contains(f.bounds) ? f.bounds : nil } ?? b.bounds }
        func cut(_ idx: [Int]) -> [Int] {
            guard idx.count > 1 else { return idx }
            for axis in [1, 0] {
                let lo = { (i: Int) in axis == 1 ? spans[i].y : spans[i].x }
                let hi = { (i: Int) in axis == 1 ? spans[i].w : spans[i].z }
                let sorted = idx.sorted { lo($0) < lo($1) }
                var reach = hi(sorted[0])
                var best: (at: Int, gap: Float)?
                for k in 1..<sorted.count {
                    let gap = lo(sorted[k]) - reach
                    if gap > 0.004, gap > (best?.gap ?? 0) { best = (k, gap) }
                    reach = max(reach, hi(sorted[k]))
                }
                if let b = best {
                    return cut(Array(sorted[..<b.at])) + cut(Array(sorted[b.at...]))
                }
            }
            // Nothing separates them: a figure and its details, or blocks that overlap.
            return idx.sorted { i, j in
                if spans[i] != spans[j] { return spans[i].y < spans[j].y }
                if (rest[i].role == .figure) != (rest[j].role == .figure) { return rest[i].role == .figure }
                return rest[i].center.y < rest[j].center.y
            }
        }
        return headline + cut(Array(rest.indices)).map { rest[$0] }
    }

    // MARK: Framing

    /// How tall a line of each kind of text stands in the frame when the
    /// camera reads it, as a share of the canvas's height: a headline about
    /// 6%, running text about 3.6% (both read easily on a phone), small print
    /// 3%. A number is framed whole with its caption, up to 15%.
    static func readingSize(_ role: DetailBlock.Role) -> Float {
        switch role {
        case .headline: return 0.062
        case .text: return 0.036
        case .smallPrint: return 0.03
        case .numbers: return 0.15
        case .figure: return 1
        }
    }

    /// A framing that reads the block on the canvas: its text at a size that
    /// reads, with room around it. A single line too long to show whole at
    /// that size is read along: the framing starts on the line's beginning
    /// and glides to its end (`sweep`, in slide space). Never closer than the
    /// slide stays sharp, never as far out as the opening.
    public static func framing(for b: DetailBlock, slideAspect A: Float, canvasAspect C: Float, safe: SafeArea = .none,
                               minViewHeight: Float? = nil, overviewHeight: Float? = nil) -> (frame: ShotFrame, sweep: Vec2?) {
        let room = safe.size
        let line = b.lineHeight > 0 ? b.lineHeight : 0.04
        let figure = b.role == .figure
        let padV: Float = figure ? 0.06 * b.size.y + 0.02 : 0.6 * line + 0.012
        let padU: Float = figure ? 0.06 * b.size.x + 0.02 / A : padV / A + 0.008
        let tall = b.size.y + 2 * padV                // slide heights
        let wide = (b.size.x + 2 * padU) * A          // world units
        /// The view height (slide heights, through the target) that shows a width of `w` world units.
        func height(across w: Float) -> Float { w / (C * room.x) }
        let whole = max(tall / room.y, height(across: wide))
        var H: Float
        switch b.role {
        case .figure: H = whole
        // A single number shows whole with its caption; a row is read along.
        case .numbers: H = max(b.items > 1 ? tall / room.y : whole, line / readingSize(.numbers))
        default: H = line / readingSize(b.role)
        }
        if let over = overviewHeight { H = min(H, over / 1.35) }
        H = max(H, tall / room.y, minViewHeight ?? 0)
        var center = b.center
        var sweep: Vec2?
        if wide > H * C * room.x * 1.02 {
            if b.lines == 1 && !figure && (b.role != .numbers || b.items > 1) {
                // Read along, but never so far that the glide becomes a crawl
                // across many screens.
                H = max(H, height(across: wide / 4.5))
                let half = H * C * room.x / 2 / A
                let from = b.bounds.x - padU + half, to = b.bounds.z + padU - half
                if to > from + 0.004 {
                    center.x = from
                    sweep = Vec2(to - from, 0)
                }
            } else {
                H = max(H, height(across: wide))
            }
        }
        // Keep the view on the slide where it fits: a detail by an edge sits
        // off centre rather than leave a stretch of empty backdrop in the frame.
        let size = Vec2(H * C * room.x / A, H * room.y)
        func onSlide(_ c: Float, _ s: Float) -> Float { s >= 1 ? 0.5 : min(max(c, s / 2), 1 - s / 2) }
        let start = Vec2(onSlide(center.x, size.x), onSlide(center.y, size.y))
        if let s = sweep {
            let end = onSlide(center.x + s.x, size.x)
            sweep = end - start.x > 0.004 ? Vec2(end - start.x, 0) : nil
        }
        return (ShotFrame(center: start, size: size), sweep)
    }

    // MARK: Planning

    /// Plans the shots for a slide.
    public static func shots(_ input: DirectorInput) -> [Shot] {
        let A = input.slideAspect, C = input.canvasAspect
        let overview = input.overview ?? .overview(slideAspect: A, canvasAspect: C)
        let opening = CameraPose(shot: overview, slideAspect: A, canvasAspect: C, safe: input.safe)
        func frame(_ b: DetailBlock) -> (frame: ShotFrame, sweep: Vec2?) {
            framing(for: b, slideAspect: A, canvasAspect: C, safe: input.safe, minViewHeight: input.minViewHeight,
                    overviewHeight: opening.height)
        }
        // Running text is only worth a shot if it can be read: a paragraph
        // that has to be shown whole in a narrow frame comes out too small.
        let picked = tour(blocks(input.details), maxShots: input.maxShots) { b in
            guard b.role == .text else { return true }
            let f = frame(b)
            return b.lineHeight / (f.frame.size.y / input.safe.size.y) >= 0.022
        }
        guard !picked.isEmpty else { return [] }
        let framings = picked.map(frame)
        // A glide along a line goes at an easy reading pace when no voice sets it.
        let reading: [Double] = zip(picked, framings).map { b, f in
            f.sweep == nil ? 0 : min(max(Double(b.text.split(separator: " ").count) * 0.32, 1.3), 3.4)
        }
        let slots = schedule(picked, words: input.words, start: input.start, spacing: input.spacing, dwell: reading)
        let visits = picked.indices.compactMap { i in slots[i].map { (i, $0) } }.sorted { $0.1.time < $1.1.time }

        var shots: [Shot] = []
        var previous = opening
        for (n, (i, slot)) in visits.enumerated() {
            let b = picked[i]
            let (frame, sweep) = framings[i]
            let alternate: Float = n % 2 == 0 ? 1 : -1
            let reads = b.role == .headline || b.role == .text || b.role == .smallPrint
            // Seen from the side away from the rest of the slide, so the rest
            // recedes; a little alternation keeps consecutive shots apart.
            // Lines being read stay nearly square-on.
            var yaw = clamp((b.center.x - 0.5) * 26 + alternate * 3, -15, 15)
            var pitch = clamp((0.5 - b.center.y) * 14 + alternate * 1.5, -8, 9)
            if reads {
                yaw = clamp((b.center.x - 0.5) * 10, -6, 6) + alternate * 1.5
                pitch = clamp((0.5 - b.center.y) * 8, -5, 6)
            }
            var sweepTime: Double?
            if sweep != nil {
                sweepTime = slot.until.map { max($0 - slot.time, 0.9) } ?? reading[i]
            }
            var shot = Shot(time: slot.time, frame: frame, yaw: yaw, pitch: pitch, roll: 0, lens: 28, aperture: 0.45,
                            move: .glide, ease: .glide, breathe: sweep == nil ? 0.55 : 0.25, emphasis: .none, label: label(for: b),
                            cue: b.role == .figure ? nil : b.text, sweep: sweep, sweepTime: sweepTime,
                            focus: ShotFrame(center: b.center, size: b.size))
            let pose = CameraPose(shot: shot, slideAspect: A, canvasAspect: C, safe: input.safe)
            let w = C.squareRoot()
            let path = ZoomPath(from: previous.target, w0: previous.height * w, to: pose.target, w1: pose.height * w, rho: 1.5)
            let apart = (pose.target - previous.target).length / max(min(previous.height, pose.height), 1e-3)
            if n > 0 && apart < 0.6 {
                shot.move = .push
                shot.ease = .swift
            } else if n > 0 && n % 2 == 1 && path.length > 1.2 && sweep == nil {
                shot.move = .arc
                shot.ease = .breathe
            }
            switch b.role {
            case .numbers:
                // One lift at a time: a second in a row reads as a tic.
                shot.emphasis = sweep == nil && shots.last?.emphasis != .lift ? .lift : .none
            case .figure:
                shot.emphasis = .spotlight
                shot.aperture = 0.55
            case .smallPrint:
                shot.ease = .linger
                shot.lens = 24
                shot.aperture = 0.75
                shot.breathe = sweep == nil ? 0.7 : 0.3
                if sweep == nil { shot.yaw = clamp(shot.yaw * 1.3, -16, 16) }
            case .headline, .text:
                break
            }
            shots.append(shot)
            previous = sweep == nil ? pose : CameraPose(sweepEndOf: shot, slideAspect: A, canvasAspect: C, safe: input.safe)
        }
        return shots
    }

    // MARK: Timing

    /// When the camera lands on a block, and (with a voice) when the voice
    /// has finished naming it.
    struct Slot {
        var time: Double
        var until: Double?
    }

    /// When each block is landed on: just before the voice names it, or at an
    /// even pace when there is no voice. Blocks the voice never names are
    /// fitted into the gaps it leaves, or skipped when there is no room.
    public static func timing(_ blocks: [DetailBlock], words: [SpokenWord]?, start: Double, spacing: Double) -> [Double?] {
        schedule(blocks, words: words, start: start, spacing: spacing, dwell: []).map { $0?.time }
    }

    /// The shortest time between two landings the voice sets.
    static let minGap = 1.3

    /// How long after the tour may start its first shot lands, without a voice.
    public static let firstLanding = 1.4

    /// Times for the blocks. With a voice, each block takes its strongest
    /// mention wherever it falls, so the tour follows the order things are
    /// said in, not the order they sit on the slide. Without one, blocks come
    /// `spacing` apart, plus `dwell` for any that read along a line.
    static func schedule(_ blocks: [DetailBlock], words: [SpokenWord]?, start: Double, spacing: Double, dwell: [Double]) -> [Slot?] {
        let first = start + firstLanding
        guard let words, !words.isEmpty else {
            var t = first
            return blocks.indices.map { i in
                defer { t += spacing + (i < dwell.count ? dwell[i] * 0.8 : 0) }
                return Slot(time: t, until: nil)
            }
        }
        let names = blocks.map { Array(Set(tokens($0.text))) }
        var counts: [String: Int] = [:]
        for set in names { for t in set { counts[t, default: 0] += 1 } }
        let spoken = tokenStream(words.enumerated().flatMap { i, w in rawWords(w.text).map { ($0, i) } })

        // Every place each block is named, scored by how much of it is said
        // there: words only it has count most, numbers and long words a little more.
        struct Mention { var block: Int; var at: Int; var end: Int; var score: Float }
        var mentions: [Mention] = []
        for (b, set) in names.enumerated() where !set.isEmpty {
            var weight: [String: Float] = [:]
            for t in set {
                let isNumber = t.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
                weight[t] = (counts[t] == 1 ? 1 : 0.35) + (isNumber ? 0.3 : 0) + (t.count >= 6 ? 0.15 : 0)
            }
            let window = min(max(set.count + 3, 4), 14)
            for j in spoken.indices where weight[spoken[j].token] != nil {
                var seen = Set<String>(), score: Float = 0, end = j
                for k in j..<min(j + window, spoken.count) {
                    let t = spoken[k].token
                    if let w = weight[t], !seen.contains(t) {
                        seen.insert(t)
                        score += w
                        end = k
                    }
                }
                if score >= 0.6 { mentions.append(Mention(block: b, at: j, end: end, score: score)) }
            }
        }
        // Strongest mentions first; each block once, never two landings too close.
        mentions.sort { $0.score != $1.score ? $0.score > $1.score : $0.at < $1.at }
        var slots = [Slot?](repeating: nil, count: blocks.count)
        for m in mentions where slots[m.block] == nil {
            let t = max(words[spoken[m.at].first].start - 0.15, start + 0.6)
            guard !slots.contains(where: { $0.map { abs($0.time - t) < minGap } ?? false }) else { continue }
            slots[m.block] = Slot(time: t, until: words[spoken[m.end].last].end + 0.2)
        }
        // Fit the unnamed ones in where they belong: just before the next
        // named block they lead into, or after the last one before them.
        let end = words.last!.end + 1.2
        for i in slots.indices where slots[i] == nil {
            let taken = slots.compactMap { $0?.time }
            let next = slots[(i + 1)...].compactMap { $0?.time }.first
            let prev = slots[..<i].compactMap { $0?.time }.last
            let lo: Double, hi: Double
            if let next {
                lo = taken.filter { $0 < next }.max() ?? start
                hi = next
            } else if let prev {
                lo = prev
                hi = taken.filter { $0 > prev }.min() ?? end
            } else {
                lo = start
                hi = end
            }
            if hi - lo >= 2 * minGap + 0.4 { slots[i] = Slot(time: (lo + hi) / 2, until: nil) }
        }
        return slots
    }

    /// The shots someone framed, cut to the voice: each lands just before the
    /// words of its cue (or its label) are said. Shots the voice never names
    /// keep their order and are fitted between the ones it does.
    public static func retime(_ shots: [Shot], words: [SpokenWord], start: Double, spacing: Double = 2.9) -> [Shot] {
        guard !shots.isEmpty, !words.isEmpty else { return shots }
        var out = shots.sorted { $0.time < $1.time }
        let blocks = out.map { s in
            DetailBlock(bounds: s.frame.bounds, text: s.cue ?? s.label ?? "", lineHeight: 0, lines: 1, role: .text)
        }
        let slots = schedule(blocks, words: words, start: start, spacing: spacing, dwell: [])
        var times = slots.map { $0?.time }
        // Unnamed shots that found no room go halfway between their neighbours.
        for i in times.indices where times[i] == nil {
            let before = times[..<i].compactMap { $0 }.last ?? start
            let after = times[(i + 1)...].compactMap { $0 }.first
            times[i] = after.map { (before + $0) / 2 } ?? before + spacing
        }
        // The order the voice names them in.
        let order = out.indices.sorted { (times[$0] ?? 0) < (times[$1] ?? 0) }
        let gap = 0.9
        var last = -Double.infinity
        var result: [Shot] = []
        for i in order {
            var s = out[i]
            let t = max(times[i] ?? s.time, last + gap)
            s.time = t
            if s.sweep != nil { s.sweepTime = slots[i]?.until.map { max($0 - t, 0.9) } }
            last = t
            result.append(s)
        }
        out = result
        return out
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "you", "your", "are", "was", "were", "our", "from", "have", "has",
        "had", "but", "not", "all", "any", "can", "into", "its", "it's", "they", "them", "then", "than", "what", "when",
        "who", "why", "how", "out", "now", "just", "very", "here", "there", "will", "would", "about", "over",
    ]

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Comparable words: lowercased, without accents or punctuation, numbers
    /// as digits without their symbols or leading zeros ("thirty-eight" and
    /// "+38%" both read 38), short and common words left out.
    public static func tokens(_ s: String) -> [String] {
        tokenStream(rawWords(s).map { ($0, 0) }).map(\.token)
    }

    /// Lowercased runs of letters or of digits.
    static func rawWords(_ s: String) -> [String] {
        let folded = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var out: [String] = []
        var current = ""
        var digits = false
        for ch in folded.unicodeScalars {
            let isDigit = CharacterSet.decimalDigits.contains(ch)
            if CharacterSet.alphanumerics.contains(ch) || ch == "'" {
                if !current.isEmpty && isDigit != digits { out.append(current); current = "" }
                current.unicodeScalars.append(ch)
                digits = isDigit
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Tokens from raw words, each with the first and last source it came
    /// from: number words become digits ("one hundred and eighteen" → 118),
    /// scale words stay words ("four hundred twelve thousand" → 412,
    /// thousand, as "$412k" reads 412).
    static func tokenStream(_ raw: [(String, Int)]) -> [(token: String, first: Int, last: Int)] {
        var out: [(token: String, first: Int, last: Int)] = []
        var i = 0
        func isNumberWord(_ k: Int) -> Bool {
            guard k < raw.count else { return false }
            let w = raw[k].0
            return units[w] != nil || tens[w] != nil || (w == "a" && k + 1 < raw.count && raw[k + 1].0 == "hundred")
        }
        while i < raw.count {
            let w = raw[i].0
            if isNumberWord(i) {
                var value = 0, current = 0
                let first = raw[i].1
                var last = first
                var k = i
                while k < raw.count {
                    let x = raw[k].0
                    // "twenty five" is 25, but "five twenty" is two numbers.
                    if let u = units[x], current % 100 == 0 || (current % 100 >= 20 && current % 10 == 0 && u < 10) { current += u }
                    else if let t = tens[x], current % 100 == 0 { current += t }
                    else if x == "a" && k + 1 < raw.count && raw[k + 1].0 == "hundred" { current += 1 }
                    else if x == "hundred" && k > i { current = max(current, 1) * 100 }
                    else if x == "and" && current >= 100 && isNumberWord(k + 1) { }
                    else { break }
                    last = raw[k].1
                    k += 1
                }
                value += current
                out.append((String(value), first, last))
                i = k
                continue
            }
            if w.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                let trimmed = w.drop { $0 == "0" }
                out.append((trimmed.isEmpty ? "0" : String(trimmed), raw[i].1, raw[i].1))
            } else if w.count >= 3 && !stopWords.contains(w) {
                out.append((w, raw[i].1, raw[i].1))
            }
            i += 1
        }
        return out
    }

    /// A short name for the shot, from what it frames.
    static func label(for b: DetailBlock) -> String {
        switch b.role {
        case .figure: return "The figure"
        case .smallPrint: return "The small print"
        case .numbers where b.items > 1:
            return "The numbers"
        default:
            let words = b.text.split(separator: " ").prefix(5).joined(separator: " ")
            return words.isEmpty ? "A detail" : (b.text.split(separator: " ").count > 5 ? words + "…" : words)
        }
    }
}
