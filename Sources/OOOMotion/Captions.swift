import Foundation

/// Captions: the voiceover's words set on the video, a short phrase at a
/// time, with the word being said lit in colour. Only the colour changes:
/// the type never grows, jumps or changes weight, so the line reads as one.
public struct CaptionStyle: Codable, Hashable, Sendable {
    /// How the words sit over the picture.
    public enum Look: String, Codable, CaseIterable, Sendable, Identifiable {
        /// White words over a soft shadow, straight on the picture.
        case clean
        /// White words on a dark card.
        case card
        /// Ink on a paper card, like the slide's own type.
        case ink

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .clean: return "Clean"
            case .card: return "Card"
            case .ink: return "Ink"
            }
        }
        public var summary: String {
            switch self {
            case .clean: return "White words with a soft shadow, straight on the picture."
            case .card: return "White words on a dark card, clear over anything."
            case .ink: return "Ink on a paper card, like type on the slide."
            }
        }
    }

    /// Whether the video shows them.
    public var on: Bool
    public var look: Look

    public init(on: Bool = true, look: Look = .card) {
        self.on = on
        self.look = look
    }

    enum CodingKeys: String, CodingKey { case on, look }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        look = try c.decodeIfPresent(Look.self, forKey: .look) ?? .card
    }
}

/// One caption: a run of words shown together.
public struct CaptionPhrase: Hashable, Sendable {
    /// Which of the voice's words it holds.
    public var range: Range<Int>
    /// The words as shown.
    public var words: [String]
    /// When each word is said, in seconds from the start of the video.
    public var starts: [Double]
    public var ends: [Double]
    /// When the phrase comes up and when it goes.
    public var shown: Double
    public var gone: Double
    /// Whether it comes up straight after the one before (no fade between).
    public var follows: Bool
    /// Whether the next one comes up straight after it.
    public var followed: Bool

    public var text: String { words.joined(separator: " ") }
}

/// What a caption looks like at one moment.
public struct CaptionMoment: Equatable, Sendable {
    public var phrase: Int
    /// 0…1.
    public var alpha: Float
    /// How far below its place it sits, as a share of the frame height,
    /// while it comes up.
    public var drop: Float
    /// How lit each word is, 0…1.
    public var lit: [Float]
}

public enum Captions {
    /// Longest phrase, in letters and spaces: two short lines on a phone.
    public static let maxCharacters = 32
    public static let maxWords = 7
    public static let maxSeconds = 3.2
    /// A pause this long ends a phrase.
    public static let pause = 0.55
    /// A phrase comes up this long before its first word, so the eye is there.
    public static let lead = 0.12
    /// …and stays this long after its last, unless the next one is due.
    public static let linger = 0.8
    static let fadeIn = 0.14
    static let fadeOut = 0.2

    static func endsSentence(_ w: String) -> Bool {
        guard let c = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]")).last else { return false }
        return ".?!…".contains(c)
    }

    static func endsClause(_ w: String) -> Bool {
        guard let c = w.last else { return false }
        return ",;:–—".contains(c)
    }

    /// Words a phrase reads badly ending on: it leaves you waiting for the next.
    static let leaning: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "with", "by", "from", "into", "onto", "as", "and", "or", "but",
        "nor", "so", "if", "than", "that", "this", "these", "those", "my", "our", "your", "his", "her", "its", "their", "is",
        "are", "was", "were", "be", "been", "i", "we", "you", "they", "it's", "i'm", "we're", "you're", "very", "just", "not",
        "after", "before", "about", "over", "under", "through", "between", "per", "who", "which", "will", "can", "has", "have",
        "had", "do", "does", "did", "more", "less", "most", "how", "what", "when", "where", "why", "every", "each", "all",
    ]

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
        "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "point", "percent", "and",
    ]

    static func numberish(_ w: String) -> Bool {
        numberWords.contains(w) || (w.first?.isNumber ?? false)
    }

    /// The voice's words set as captions: short phrases that each read at a
    /// glance. A sentence that fits is one phrase; a longer one is shared
    /// into even phrases, broken where you'd take a breath: after a comma or
    /// a pause, never after "the" or "of", never one word left alone. A
    /// sentence's end, or a long pause, always ends a phrase.
    public static func phrases(_ spoken: [SpokenWord]) -> [CaptionPhrase] {
        let words = spoken.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kept = words.indices.filter { !words[$0].isEmpty }
        // Sentences: runs ended by a full stop or a long pause.
        var sentences: [[Int]] = []
        var run: [Int] = []
        for i in kept {
            if let last = run.last, spoken[i].start - spoken[last].end > pause {
                sentences.append(run)
                run = []
            }
            run.append(i)
            if endsSentence(words[i]) {
                sentences.append(run)
                run = []
            }
        }
        if !run.isEmpty { sentences.append(run) }
        var merged: [Range<Int>] = []
        for sentence in sentences {
            for part in split(sentence, words: words, spoken: spoken) {
                merged.append(part.first!..<(part.last! + 1))
            }
        }
        var out: [CaptionPhrase] = merged.map { r in
            let kept = r.filter { !words[$0].isEmpty }
            return CaptionPhrase(range: r, words: kept.map { words[$0] }, starts: kept.map { spoken[$0].start },
                                 ends: kept.map { max(spoken[$0].end, spoken[$0].start) }, shown: 0, gone: 0, follows: false, followed: false)
        }
        out.removeAll { $0.words.isEmpty }
        for k in out.indices {
            let first = out[k].starts[0], last = out[k].ends[out[k].ends.count - 1]
            out[k].shown = max(0, first - lead)
            out[k].gone = last + linger
            if k > 0 {
                // Never two at once: the one before goes as this one comes.
                let before = out[k - 1].gone
                if before > out[k].shown - 0.05 {
                    out[k - 1].gone = max(out[k].shown, out[k - 1].ends.last! + 0.05)
                    out[k].shown = out[k - 1].gone
                    out[k].follows = true
                    out[k - 1].followed = true
                }
            }
        }
        return out
    }

    /// What shows at `t`: the phrase, how far it has come up, and how lit
    /// each of its words is. Nil between phrases.
    public static func moment(_ phrases: [CaptionPhrase], at t: Double) -> CaptionMoment? {
        guard let k = index(phrases, at: t) else { return nil }
        let p = phrases[k]
        let inT = p.follows ? 1 : smooth((t - p.shown) / fadeIn)
        let outT = p.followed ? 1 : 1 - smooth((t - (p.gone - fadeOut)) / fadeOut)
        let alpha = Float(min(inT, outT))
        let settle = 1 - inT
        var lit = [Float](repeating: 0, count: p.words.count)
        for i in p.words.indices {
            // A word is lit from when it is said until the next one is, or a
            // moment after it ends when the next one is a while coming.
            let on = p.starts[i]
            let next = i + 1 < p.words.count ? p.starts[i + 1] : p.gone
            let off = min(next, p.ends[i] + 0.35)
            let up = smooth((t - on + 0.03) / 0.07)
            let down = 1 - smooth((t - off) / 0.12)
            lit[i] = Float(max(0, min(up, down)))
        }
        return CaptionMoment(phrase: k, alpha: alpha, drop: Float(0.006 * settle * settle), lit: lit)
    }

    /// The phrase on screen at `t`, if any.
    public static func index(_ phrases: [CaptionPhrase], at t: Double) -> Int? {
        var lo = 0, hi = phrases.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if phrases[mid].shown <= t { lo = mid + 1 } else { hi = mid }
        }
        let k = lo - 1
        guard k >= 0, t < phrases[k].gone else { return nil }
        return k
    }

    /// One sentence shared into phrases at the breaks that cost least: each
    /// phrase near the same length and within the limits, broken where a
    /// reader would pause.
    static func split(_ s: [Int], words: [String], spoken: [SpokenWord]) -> [[Int]] {
        let n = s.count
        guard n > 1 else { return [s] }
        func length(_ a: Int, _ b: Int) -> Int { (a..<b).map { words[s[$0]].count }.reduce(0, +) + (b - a - 1) }
        let total = length(0, n)
        if total <= maxCharacters, spoken[s[n - 1]].end - spoken[s[0]].start <= maxSeconds, n <= maxWords { return [s] }
        let pieces = max(2, Int((Double(total) / Double(maxCharacters)).rounded(.up)))
        let ideal = Double(total) / Double(pieces)
        // How much a phrase ending after the word at `j` costs as a break.
        func breakCost(_ j: Int) -> Double {
            guard j < n - 1 else { return 0 }
            let w = words[s[j]]
            var c = 0.0
            if endsClause(w) { c -= 6 }
            let bare = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if leaning.contains(bare) && !endsClause(w) { c += 8 }
            // Never through the middle of a number said in words.
            let next = words[s[j + 1]].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if numberish(bare) && numberish(next) { c += 9 }
            let breath = spoken[s[j + 1]].start - spoken[s[j]].end
            if breath > 0.22 { c -= min(5, 18 * breath) }
            return c
        }
        func cost(_ a: Int, _ b: Int) -> Double {
            let len = length(a, b)
            let count = b - a
            if count > 1 && (len > maxCharacters + 2 || count > maxWords + 1) { return .infinity }
            var c = 3 + 10 * pow((Double(len) - ideal) / ideal, 2)
            if count == 1 { c += 12 }
            // A comma inside a phrase is a breath the reader skips.
            c += 5 * Double((a..<(b - 1)).filter { endsClause(words[s[$0]]) }.count)
            if spoken[s[b - 1]].end - spoken[s[a]].start > maxSeconds { c += 20 }
            return c + breakCost(b - 1)
        }
        var best = [Double](repeating: .infinity, count: n + 1)
        var from = [Int](repeating: 0, count: n + 1)
        best[0] = 0
        for b in 1...n {
            for a in 0..<b where best[a] < .infinity {
                let c = best[a] + cost(a, b)
                if c < best[b] {
                    best[b] = c
                    from[b] = a
                }
            }
        }
        var cuts: [Int] = []
        var b = n
        while b > 0 {
            cuts.append(b)
            b = from[b]
        }
        var out: [[Int]] = []
        var a = 0
        for e in cuts.reversed() {
            out.append(Array(s[a..<e]))
            a = e
        }
        return out
    }

    static func smooth(_ x: Double) -> Double {
        let u = max(0, min(1, x))
        return u * u * (3 - 2 * u)
    }

    /// The voice's words with phrase `p` replaced by what was typed. Where the
    /// count of words is unchanged each keeps its own time; otherwise the
    /// phrase's time is shared out by length. Typing nothing takes its words out.
    public static func corrected(_ spoken: [SpokenWord], phrase p: CaptionPhrase, to typed: String) -> [SpokenWord] {
        guard p.range.lowerBound >= 0, p.range.upperBound <= spoken.count, !p.range.isEmpty else { return spoken }
        let tokens = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        let old = Array(spoken[p.range])
        var fresh: [SpokenWord] = []
        if tokens.count == old.count {
            fresh = zip(old, tokens).map { SpokenWord(text: $1, start: $0.start, end: $0.end, confidence: $0.text == $1 ? $0.confidence : 1) }
        } else if !tokens.isEmpty {
            let start = old.first!.start, end = max(old.last!.end, start + 0.05 * Double(tokens.count))
            let weights = tokens.map { Double($0.count) + 1 }
            let total = weights.reduce(0, +)
            var at = start
            for (tok, w) in zip(tokens, weights) {
                let d = (end - start) * w / total
                fresh.append(SpokenWord(text: tok, start: at, end: at + d * 0.92, confidence: 1))
                at += d
            }
        }
        var out = spoken
        out.replaceSubrange(p.range, with: fresh)
        return out
    }

    // MARK: Where they sit

    /// The type's size as a share of the frame height: the same size in
    /// pixels on a 1080-wide Reel and a 1080-tall landscape video.
    public static func size(canvasAspect C: Float) -> Float {
        0.052 * min(C, 1)
    }

    /// The band the captions sit in, as shares of the frame height measured
    /// from the bottom: just above what the platform's interface covers, tall
    /// enough for two lines on a card.
    public static func band(canvasAspect C: Float, safe: SafeArea) -> (bottom: Float, height: Float) {
        let s = size(canvasAspect: C)
        let bottom = safe.bottom > 0 ? safe.bottom + 0.012 : 0.06
        return (bottom, 3.3 * s)
    }

    /// `safe` with room kept at the bottom for captions, so framings are
    /// composed above them and nothing the camera shows is ever covered.
    public static func reserving(_ safe: SafeArea, canvasAspect C: Float) -> SafeArea {
        let b = band(canvasAspect: C, safe: safe)
        var s = safe
        s.bottom = b.bottom + b.height + 0.4 * size(canvasAspect: C)
        return s
    }

    /// What captions need above the room while the stage is up for you: a
    /// gap over your head, their band, and a gap under the framings.
    public static func roomAbove(canvasAspect C: Float) -> Float {
        let s = size(canvasAspect: C)
        return 0.5 * s + band(canvasAspect: C, safe: .none).height + 0.4 * s
    }

    /// How far the captions have risen, as a share of the frame height, with
    /// the stage `w` of the way up into a room `room` tall: up there they sit
    /// just over your head, never across your face.
    public static func rise(_ w: Float, room: Float, canvasAspect C: Float, safe: SafeArea) -> Float {
        let up = room + 0.5 * size(canvasAspect: C)
        return min(max(w, 0), 1) * max(0, up - band(canvasAspect: C, safe: safe).bottom)
    }
}
