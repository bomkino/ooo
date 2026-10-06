import Foundation

/// Keeping a tour when the canvas or the slide changes.
extension Director {
    /// The tour on another canvas: each shot Direct for Me planned takes the
    /// framing its detail gets in `fresh` (a new plan of the same reading for
    /// that canvas), matched by the detail it is about. Times, moves and
    /// everything else stay as they were, and framings you set never move.
    public static func reframe(_ shots: [Shot], from fresh: [Shot]) -> [Shot] {
        var unused = fresh
        return shots.map { s in
            guard s.isPlanned, let focus = s.focus,
                  let k = unused.firstIndex(where: { f in f.focus.map { same($0, focus) } ?? false }) else { return s }
            let f = unused.remove(at: k)
            var out = s
            out.frame = f.frame
            out.yaw = f.yaw
            out.pitch = f.pitch
            out.roll = f.roll
            out.lens = f.lens
            out.sweep = f.sweep
            if f.sweep == nil { out.sweepTime = nil } else if s.sweep == nil { out.sweepTime = f.sweepTime }
            return out
        }
    }

    /// The tour moved onto a corrected slide: each shot about a detail (its
    /// focus, or else what it frames) follows that detail to where it is on
    /// the new slide, matched by its words, and keeps its size around it.
    /// A shot whose detail is gone, or that frames no one detail, stays put.
    /// A label or cue that was the detail's words takes its new words.
    public static func follow(_ shots: [Shot], from old: [SlideDetail], to new: [SlideDetail]) -> [Shot] {
        let before = blocks(old), after = blocks(new)
        var taken = Set<Int>()
        return shots.map { s in
            let anchor = s.focus ?? s.frame
            guard let o = anchored(anchor, in: before) else { return s }
            guard let n = counterpart(of: before[o], in: after, excluding: taken) else { return s }
            taken.insert(n)
            let from = before[o], to = after[n]
            // How much bigger the detail is now, kept even so framings keep their shape.
            let k = (max(to.size.x * to.size.y, 1e-8) / max(from.size.x * from.size.y, 1e-8)).squareRoot()
            func moved(_ f: ShotFrame) -> ShotFrame {
                ShotFrame(center: to.center + (f.center - from.center) * k, size: f.size * k)
            }
            var out = s
            if from.bounds != to.bounds {
                out.frame = moved(s.frame)
                out.focus = s.focus.map(moved)
                out.sweep = s.sweep.map { $0 * k }
            }
            if from.text != to.text {
                if s.label == textLabel(from.text) { out.label = textLabel(to.text) }
                if s.cue == from.text { out.cue = to.text }
            }
            return out
        }
    }

    /// The block a framing is about: the one that most nearly covers the
    /// same ground (a shot's focus is its block's own bounds; a framing drawn
    /// by hand has to fit one block closely).
    static func anchored(_ f: ShotFrame, in blocks: [DetailBlock]) -> Int? {
        var best: (i: Int, score: Float)?
        for (i, b) in blocks.enumerated() {
            let shared = overlap(f.bounds, b.bounds)
            let union = area(f.bounds) + area(b.bounds) - shared
            let score = shared / max(union, 1e-8)
            if score > 0.25, score > (best?.score ?? 0) { best = (i, score) }
        }
        return best?.i
    }

    /// The same detail on the new slide: the same words (or, for a figure,
    /// the nearest figure), else the most alike text, if it is alike enough.
    static func counterpart(of b: DetailBlock, in blocks: [DetailBlock], excluding taken: Set<Int>) -> Int? {
        let open = blocks.indices.filter { !taken.contains($0) }
        if b.role == .figure {
            return open.filter { blocks[$0].role == .figure }
                .min { (blocks[$0].center - b.center).length < (blocks[$1].center - b.center).length }
        }
        let words = tokens(b.text)
        guard !words.isEmpty else { return nil }
        if let exact = open.first(where: { tokens(blocks[$0].text) == words }) { return exact }
        let mine = Set(words)
        var best: (i: Int, score: Float)?
        for i in open where blocks[i].role != .figure {
            let theirs = Set(tokens(blocks[i].text))
            let score = Float(mine.intersection(theirs).count) / Float(max(mine.union(theirs).count, 1))
            if score >= 0.5, score > (best?.score ?? 0) { best = (i, score) }
        }
        return best?.i
    }

    static func same(_ a: ShotFrame, _ b: ShotFrame) -> Bool {
        (a.center - b.center).length < 1e-4 && (a.size - b.size).length < 1e-4
    }
}
