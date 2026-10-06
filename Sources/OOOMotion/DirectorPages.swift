import Foundation

/// One slide for Direct for Me, in a video over several.
public struct PageReading: Sendable {
    /// The slide's id; nil for the first.
    public var id: UUID?
    public var details: [SlideDetail]
    /// Width / height.
    public var aspect: Float
    /// How the card changes to this slide (the first's is never used).
    public var change: PageChange
    /// When the card changes to it, if set by hand.
    public var at: Double?
    /// The least view height at which this slide stays sharp; nil for vectors.
    public var minViewHeight: Float?

    public init(id: UUID?, details: [SlideDetail], aspect: Float, change: PageChange = .turn, at: Double? = nil,
                minViewHeight: Float? = nil) {
        self.id = id
        self.details = details
        self.aspect = aspect
        self.change = change
        self.at = at
        self.minViewHeight = minViewHeight
    }
}

extension Director {
    /// A tour over several slides: each slide's own tour in turn, each
    /// setting off once the card has changed to it. With a voice, each slide
    /// takes the stretch of it that talks about it. Before a melt, the tour
    /// ends on a detail the next slide repeats and the next slide's tour
    /// starts on it, framed the same, so it holds still while everything
    /// around it changes.
    public static func shots(_ input: DirectorInput, pages: [PageReading], arrive: Arrive) -> [Shot] {
        guard let firstPage = pages.first else { return shots(input) }
        let C = input.canvasAspect
        let base = input.overview ?? .overview(slideAspect: firstPage.aspect, canvasAspect: C)
        func directed(_ k: Int, start: Double, words: [SpokenWord]?) -> DirectorInput {
            let page = pages[k]
            var d = input
            d.details = page.details
            d.slideAspect = page.aspect
            d.minViewHeight = page.minViewHeight
            d.overview = Shot.overview(like: base, baseAspect: firstPage.aspect, slideAspect: page.aspect, canvasAspect: C)
            d.maxShots = pages.count > 1 ? max(3, input.maxShots - (pages.count - 1)) : input.maxShots
            d.start = start
            d.words = words
            return d
        }
        guard pages.count > 1 else { return shots(directed(0, start: input.start, words: input.words)) }

        let ids: [UUID?] = pages.indices.map { $0 == 0 ? nil : pages[$0].id ?? UUID() }
        let timings = pages.indices.dropFirst().map {
            PageTiming(id: ids[$0]!, aspect: pages[$0].aspect, change: pages[$0].change, at: pages[$0].at)
        }
        let voice = input.words ?? []
        let shares = voice.isEmpty ? nil : Self.share(voice, among: pages)
        /// When the card changes to slide `k`, after the shots so far.
        func changeStart(_ k: Int, after all: [Shot]) -> Double {
            let probe = ChoreographyInput(overview: base, shots: all, arrive: arrive, ending: .hold, duration: 0,
                                          slideAspect: firstPage.aspect, canvasAspect: C, style: input.style, safe: input.safe,
                                          pages: Array(timings.prefix(k)))
            var start = Choreography.layout(probe, duration: nil).changes[k - 1].start
            // With a voice, not before the stretch of it about the next slide.
            if pages[k].at == nil, let first = shares?[k].first {
                let lead = pages[k].change == .turn ? PageChange.turn.length + Choreography.turnSettle : 0
                start = max(start, first.start - 0.15 - lead)
            }
            return start
        }

        var all = shots(directed(0, start: input.start, words: shares?[0])).map { s -> Shot in var s = s; s.page = nil; return s }
        for k in 1..<pages.count {
            let page = pages[k]
            var held: Shot?
            if page.change == .melt, let (b, b2) = sharedDetail(pages[k - 1].details, page.details) {
                // The last shot here frames the detail the next slide repeats.
                let previous = all.last { $0.page == ids[k - 1] }
                var last: Shot
                if let previous, let focus = previous.focus, sameBlock(focus, b) {
                    last = previous
                } else {
                    last = shot(on: b, input: directed(k - 1, start: 0, words: nil))
                    last.page = ids[k - 1]
                    last.time = (previous?.time ?? input.start) + max(input.spacing, firstLanding + 1.0)
                    all.append(last)
                }
                // And the next slide's first frames it again where it is there,
                // the same size in the frame and from the same angle.
                let scale = (max(area(b2.bounds), 1e-8) / max(area(b.bounds), 1e-8)).squareRoot()
                func moved(_ f: ShotFrame) -> ShotFrame { ShotFrame(center: b2.center + (f.center - b.center) * scale, size: f.size * scale) }
                var same = last
                same.id = UUID()
                same.page = ids[k]
                same.frame = moved(last.frame)
                same.focus = last.focus.map(moved)
                same.sweep = last.sweep.map { $0 * scale }
                same.label = label(for: b2)
                same.cue = b2.role == .figure ? nil : b2.text
                same.time = changeStart(k, after: all)
                same.move = .cut
                same.emphasis = .none
                same.planned = true
                held = same
            }
            let c = changeStart(k, after: all)
            let start = c + page.change.length + (page.change == .turn ? Choreography.turnSettle : 0)
            var tour = shots(directed(k, start: start, words: shares?[k])).map { s -> Shot in var s = s; s.page = ids[k]; return s }
            if let held {
                // The detail held still through the melt gets no second shot.
                tour.removeAll { s in s.focus.map { f in held.focus.map { sameFrame(f, $0) } ?? false } ?? false }
                all.append(held)
            }
            all += tour
        }
        return all
    }

    /// A shot of one block, framed and angled the way Direct for Me frames it.
    static func shot(on b: DetailBlock, input: DirectorInput) -> Shot {
        let A = input.slideAspect, C = input.canvasAspect
        let overview = input.overview ?? .overview(slideAspect: A, canvasAspect: C)
        let opening = CameraPose(shot: overview, slideAspect: A, canvasAspect: C, safe: input.safe)
        let f = framing(for: b, slideAspect: A, canvasAspect: C, safe: input.safe, minViewHeight: input.minViewHeight,
                        overviewHeight: opening.height)
        let reads = b.role == .headline || b.role == .text || b.role == .smallPrint
        let yaw = reads ? clamp((b.center.x - 0.5) * 10, -6, 6) : clamp((b.center.x - 0.5) * 26, -15, 15)
        let pitch = reads ? clamp((0.5 - b.center.y) * 8, -5, 6) : clamp((0.5 - b.center.y) * 14, -8, 9)
        var s = Shot(time: 0, frame: f.frame, yaw: yaw, pitch: pitch, roll: 0, lens: 28, aperture: 0.45, move: .glide, ease: .glide,
                     breathe: 0.4, emphasis: .none, label: label(for: b), cue: b.role == .figure ? nil : b.text,
                     focus: ShotFrame(center: b.center, size: b.size))
        s.planned = true
        return s
    }

    /// The detail two slides in a row share, for a melt to hold still on: the
    /// most prominent one the second repeats word for word (or nearly), or a
    /// figure that stays where it was. Nil when they share nothing worth
    /// holding on (a running footer is not).
    public static func sharedDetail(_ a: [SlideDetail], _ b: [SlideDetail]) -> (DetailBlock, DetailBlock)? {
        let before = blocks(a), after = blocks(b)
        func weight(_ x: DetailBlock) -> Float {
            switch x.role {
            case .headline: return 3
            case .numbers: return 2
            case .figure: return 1.5
            case .text: return 1
            case .smallPrint: return 0
            }
        }
        var best: (DetailBlock, DetailBlock, Float)?
        for x in before where weight(x) > 0 && area(x.bounds) >= 0.004 {
            // A line at the very top or bottom that every slide repeats is the deck's furniture.
            let edge = (x.center.y < 0.1 || x.center.y > 0.9) && x.lines == 1
            guard !edge else { continue }
            var match: (DetailBlock, Float)?
            if x.role == .figure {
                for y in after where y.role == .figure {
                    let near = (y.center - x.center).length
                    let alike = min(area(x.bounds), area(y.bounds)) / max(area(x.bounds), area(y.bounds), 1e-8)
                    if near < 0.08, alike > 0.6 { match = (y, alike * (1 - near / 0.08)) }
                }
            } else {
                let mine = Set(tokens(x.text))
                guard mine.count >= 1 else { continue }
                for y in after where y.role != .figure {
                    let theirs = Set(tokens(y.text))
                    let score = Float(mine.intersection(theirs).count) / Float(max(mine.union(theirs).count, 1))
                    if score >= 0.6, score > (match?.1 ?? 0) { match = (y, score) }
                }
            }
            guard let (y, similarity) = match else { continue }
            let score = weight(x) * area(x.bounds).squareRoot() * similarity
            if score > (best?.2 ?? 0) { best = (x, y, score) }
        }
        return best.map { ($0.0, $0.1) }
    }

    static func sameBlock(_ f: ShotFrame, _ b: DetailBlock) -> Bool {
        abs(f.center.x - b.center.x) < 1e-3 && abs(f.center.y - b.center.y) < 1e-3
            && abs(f.size.x - b.size.x) < 1e-3 && abs(f.size.y - b.size.y) < 1e-3
    }

    static func sameFrame(_ a: ShotFrame, _ b: ShotFrame) -> Bool {
        (a.center - b.center).length < 0.02 && (a.size - b.size).length < 0.03
    }

    /// The voice shared out among the slides, in order: each slide takes the
    /// stretch that names most of what is on it, and a slide whose change is
    /// set by hand starts where it was set. With too few words to tell, the
    /// voice is shared evenly by what each slide has to show.
    public static func share(_ words: [SpokenWord], among pages: [PageReading]) -> [[SpokenWord]] {
        let n = pages.count, W = words.count
        // Words only one slide has: those place the boundaries.
        let sets = pages.map { Set(blocks($0.details).flatMap { tokens($0.text) }) }
        var counts: [String: Int] = [:]
        for s in sets { for t in s { counts[t, default: 0] += 1 } }
        let spoken = words.map { Set(tokens($0.text)) }
        var hits = Array(repeating: Array(repeating: 0, count: W + 1), count: n)
        var total = 0
        for k in 0..<n {
            for j in 0..<W {
                let own = spoken[j].contains { sets[k].contains($0) && counts[$0] == 1 }
                hits[k][j + 1] = hits[k][j] + (own ? 1 : 0)
                if own { total += 1 }
            }
        }
        // Where a change set by hand puts each boundary.
        let fixed: [Int?] = pages.indices.map { k in
            guard k > 0, let at = pages[k].at else { return nil }
            return words.firstIndex { $0.start >= at } ?? W
        }
        var bounds = [Int](repeating: 0, count: n + 1)
        bounds[n] = W
        if total >= 3 {
            // best[k][j]: the most named words with the first k + 1 slides over words[0..<j].
            let none = Int.min / 4
            var best = Array(repeating: Array(repeating: none, count: W + 1), count: n)
            var from = Array(repeating: Array(repeating: 0, count: W + 1), count: n)
            for j in 0...W { best[0][j] = hits[0][j] }
            for k in 1..<n {
                var top = none, at = 0
                for j in 0...W {
                    // Slide k starts at i ≤ j: the best start so far, the latest
                    // of equals, since a speaker keeps to a slide until moving on.
                    let allowed = fixed[k].map { $0 == j } ?? true
                    if allowed, best[k - 1][j] > none, best[k - 1][j] - hits[k][j] >= top {
                        top = best[k - 1][j] - hits[k][j]
                        at = j
                    }
                    if top > none {
                        best[k][j] = hits[k][j] + top
                        from[k][j] = at
                    }
                }
            }
            var j = W
            for k in stride(from: n - 1, to: 0, by: -1) {
                j = from[k][j]
                bounds[k] = j
            }
        } else {
            let weight = pages.map { Float(max(blocks($0.details).count, 1)) }
            let sum = weight.reduce(0, +)
            var acc: Float = 0
            for k in 1..<n {
                acc += weight[k - 1]
                bounds[k] = fixed[k] ?? Int((acc / sum * Float(W)).rounded())
            }
        }
        for k in 1...n { bounds[k] = min(max(bounds[k], bounds[k - 1]), W) }
        return (0..<n).map { Array(words[bounds[$0]..<bounds[$0 + 1]]) }
    }
}
