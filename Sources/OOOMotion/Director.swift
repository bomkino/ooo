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

    public var center: Vec2 { Vec2((bounds.x + bounds.z) / 2, (bounds.y + bounds.w) / 2) }
    public var size: Vec2 { Vec2(bounds.z - bounds.x, bounds.w - bounds.y) }
}

/// Everything the director needs to plan a tour of the slide.
public struct DirectorInput: Sendable {
    public var details: [SlideDetail]
    /// The voiceover's words, times from the video's start. With them, each
    /// shot lands just before the words that name what it frames.
    public var words: [SpokenWord]?
    public var slideAspect: Float
    public var canvasAspect: Float
    /// When the first shot may land (after the slide has arrived).
    public var start: Double
    /// Seconds between shots when there is no voice to follow.
    public var spacing: Double
    public var maxShots: Int

    public init(details: [SlideDetail], words: [SpokenWord]? = nil, slideAspect: Float, canvasAspect: Float,
                start: Double, spacing: Double = 2.9, maxShots: Int = 5) {
        self.details = details
        self.words = words
        self.slideAspect = slideAspect
        self.canvasAspect = canvasAspect
        self.start = start
        self.spacing = spacing
        self.maxShots = maxShots
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
        // is numbers; the smallest type, if it is really small, is small print.
        let texts = out.indices.filter { out[$0].role == .text }
        if let top = texts.max(by: { out[$0].lineHeight < out[$1].lineHeight }), out[top].lineHeight > 0.035 {
            out[top].role = .headline
        }
        let median = texts.map { out[$0].lineHeight }.sorted().dropFirst(texts.count / 2).first ?? 0
        for i in texts where out[i].role == .text {
            let digits = out[i].text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            if digits > 0 && out[i].lineHeight >= median * 1.15 && out[i].text.count < 60 {
                out[i].role = .numbers
            }
        }
        if let tiny = texts.min(by: { out[$0].lineHeight < out[$1].lineHeight }),
           out[tiny].lineHeight < 0.014, out[tiny].role == .text, texts.count > 2 {
            out[tiny].role = .smallPrint
        }
        return out
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

    /// The blocks worth a shot, in the order the camera visits them.
    public static func tour(_ blocks: [DetailBlock], maxShots: Int) -> [DetailBlock] {
        func score(_ b: DetailBlock) -> Float {
            switch b.role {
            case .headline: return 10
            case .numbers: return 6 + b.lineHeight * 20
            case .figure: return 5 + (b.size.x * b.size.y) * 8
            case .smallPrint: return 4.5
            case .text: return 2 + b.lineHeight * 30 + min(Float(b.lines), 4) * 0.3
            }
        }
        let limit = max(1, maxShots)
        // The smallest print, when there is some, always gets the last shot:
        // it is the detail nobody else would have noticed.
        let small = Array(blocks.filter { $0.role == .smallPrint }.prefix(limit > 1 ? 1 : 0))
        var chosen = Array(blocks.filter { $0.role != .smallPrint }.sorted { score($0) > score($1) }
            .prefix(limit - small.count))
        // Reading order: rows top to bottom, then left to right; small print last.
        chosen.sort { a, b in
            let rowA = (a.center.y * 4).rounded(.down), rowB = (b.center.y * 4).rounded(.down)
            if a.role == .headline { return b.role != .headline || a.center.y < b.center.y }
            if b.role == .headline { return false }
            if rowA != rowB { return rowA < rowB }
            return a.center.x < b.center.x
        }
        return chosen + small
    }

    // MARK: Framing

    /// A framing that shows the whole block with room around it.
    public static func frame(for b: DetailBlock, slideAspect A: Float, canvasAspect C: Float) -> ShotFrame {
        let line = b.lineHeight > 0 ? b.lineHeight : 0.04
        let padV = 0.7 * line + 0.02 + 0.08 * b.size.y
        let padU = padV / A + 0.04 * b.size.x
        var size = Vec2(b.size.x + 2 * padU, b.size.y + 2 * padV)
        // Never closer than the slide can hold well, never wider than the slide.
        size = pointwiseMax(size, Vec2(0.03, 0.03 * C / A))
        size = pointwiseMin(size, Vec2(1.1, 1.1))
        return ShotFrame(center: b.center, size: size)
    }

    // MARK: Planning

    /// Plans the shots for a slide.
    public static func shots(_ input: DirectorInput) -> [Shot] {
        let picked = tour(blocks(input.details), maxShots: input.maxShots)
        guard !picked.isEmpty else { return [] }
        let A = input.slideAspect, C = input.canvasAspect
        let times = timing(picked, words: input.words, start: input.start, spacing: input.spacing)

        var shots: [Shot] = []
        var previous: CameraPose? = CameraPose(shot: .overview(), slideAspect: A, canvasAspect: C)
        for (i, item) in zip(picked, times).enumerated() {
            guard let time = item.1 else { continue }
            let b = item.0
            let frame = frame(for: b, slideAspect: A, canvasAspect: C)
            let alternate: Float = i % 2 == 0 ? 1 : -1
            // Seen from the side away from the rest of the slide, so the rest
            // recedes; a little alternation keeps consecutive shots apart.
            let yaw = clamp((b.center.x - 0.5) * 26 + alternate * 3, -15, 15)
            let pitch = clamp((0.5 - b.center.y) * 14 + alternate * 1.5, -8, 9)
            var shot = Shot(time: time, frame: frame, yaw: yaw, pitch: pitch, roll: 0, lens: 28, aperture: 0.45,
                            move: .glide, ease: .glide, breathe: 0.55, emphasis: .none, label: label(for: b),
                            cue: b.role == .figure ? nil : b.text)
            let pose = CameraPose(shot: shot, slideAspect: A, canvasAspect: C)
            if let prev = previous {
                let w = C.squareRoot()
                let path = ZoomPath(from: prev.target, w0: prev.height * w, to: pose.target, w1: pose.height * w, rho: 1.5)
                let apart = (pose.target - prev.target).length / max(min(prev.height, pose.height), 1e-3)
                if i > 0 && apart < 0.6 {
                    shot.move = .push
                    shot.ease = .swift
                } else if i > 0 && i % 2 == 1 && path.length > 1.2 {
                    shot.move = .arc
                    shot.ease = .breathe
                }
            }
            switch b.role {
            case .numbers:
                shot.emphasis = .lift
            case .figure:
                shot.emphasis = .spotlight
                shot.aperture = 0.55
            case .smallPrint:
                shot.ease = .linger
                shot.lens = 24
                shot.aperture = 0.75
                shot.breathe = 0.7
                shot.yaw = clamp(shot.yaw * 1.3, -16, 16)
            case .headline, .text:
                break
            }
            shots.append(shot)
            previous = pose
        }
        return shots
    }

    /// When each block is landed on: just before the voice names it, or at an
    /// even pace when there is no voice. Blocks the voice never names are
    /// fitted into the gaps it leaves, or skipped when there is no room.
    public static func timing(_ blocks: [DetailBlock], words: [SpokenWord]?, start: Double, spacing: Double) -> [Double?] {
        let first = start + 1.4
        guard let words, !words.isEmpty else {
            return blocks.indices.map { first + Double($0) * spacing }
        }
        let tokens = blocks.map { Set(Self.tokens($0.text)) }
        var counts: [String: Int] = [:]
        for set in tokens { for t in set { counts[t, default: 0] += 1 } }
        let spoken = words.map { (Self.tokens($0.text).first ?? "", $0.start) }
        var times = [Double?](repeating: nil, count: blocks.count)
        var cursor = 0
        for (i, set) in tokens.enumerated() where !set.isEmpty {
            // Prefer a word only this block has; any of its words will do.
            let distinct = set.filter { counts[$0] == 1 }
            var found: Int?
            for pass in [distinct, set] where found == nil && !pass.isEmpty {
                found = spoken[cursor...].firstIndex { pass.contains($0.0) }
            }
            if let j = found {
                times[i] = max(spoken[j].1 - 0.15, start + 0.6)
                cursor = j + 1
            }
        }
        // Keep them in order and apart; fit the unnamed ones between.
        var last = start + 0.6 - 1.3
        for i in times.indices {
            if let t = times[i] {
                if t - last < 1.3 { times[i] = nil } else { last = t }
            }
        }
        for i in times.indices where times[i] == nil {
            let before = times[..<i].compactMap { $0 }.last ?? start
            let after = times[(i + 1)...].compactMap { $0 }.first ?? (words.last!.end + 1.2)
            if after - before >= 2 * 1.3 + 0.4 { times[i] = (before + after) / 2 }
        }
        return times
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
        var times = timing(blocks, words: words, start: start, spacing: spacing)
        // Unnamed shots that found no room go halfway between their neighbours.
        for i in times.indices where times[i] == nil {
            let before = times[..<i].compactMap { $0 }.last ?? start
            let after = times[(i + 1)...].compactMap { $0 }.first
            times[i] = after.map { (before + $0) / 2 } ?? before + spacing
        }
        let gap = 0.9
        var last = -Double.infinity
        for i in out.indices {
            let t = max(times[i] ?? out[i].time, last + gap)
            out[i].time = t
            last = t
        }
        return out
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "you", "your", "are", "was", "were", "our", "from", "have", "has",
        "had", "but", "not", "all", "any", "can", "into", "its", "it's", "they", "them", "then", "than", "what", "when",
        "who", "why", "how", "out", "one", "now", "just", "very", "here", "there", "will", "would", "about", "over",
    ]

    /// Comparable words: lowercased, without accents or punctuation, numbers
    /// without their symbols, short and common words left out.
    public static func tokens(_ s: String) -> [String] {
        let folded = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var out: [String] = []
        var current = ""
        func flush() {
            let isNumber = !current.isEmpty && current.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
            if isNumber || (current.count >= 3 && !stopWords.contains(current)) { out.append(current) }
            current = ""
        }
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { current.unicodeScalars.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    /// A short name for the shot, from what it frames.
    static func label(for b: DetailBlock) -> String {
        switch b.role {
        case .figure: return "The figure"
        case .smallPrint: return "The small print"
        default:
            let words = b.text.split(separator: " ").prefix(5).joined(separator: " ")
            return words.isEmpty ? "A detail" : (b.text.split(separator: " ").count > 5 ? words + "…" : words)
        }
    }
}
