import BackdropKit
import Foundation
import OOOMotion
import RenderCore
import StageKit

/// Output canvas presets, named for where the video goes. Reel is the default:
/// OOO is made for talking about one slide on a phone screen.
public struct CanvasFormat: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var width: Int
    public var height: Int

    public init(id: String, name: String, detail: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.detail = detail
        self.width = width
        self.height = height
    }

    public var aspect: Float { Float(width) / Float(max(height, 1)) }
    public var ratioLabel: String {
        switch id {
        case "reel": return "9:16"
        case "portrait": return "4:5"
        case "square": return "1:1"
        case "landscape", "uhd": return "16:9"
        default: return String(format: "%.2f:1", aspect)
        }
    }

    public static let reel = CanvasFormat(id: "reel", name: "Reel", detail: "Instagram, TikTok, Shorts", width: 1080, height: 1920)
    public static let portrait = CanvasFormat(id: "portrait", name: "Portrait", detail: "Instagram and LinkedIn feeds", width: 1080, height: 1350)
    public static let square = CanvasFormat(id: "square", name: "Square", detail: "Feeds and carousels", width: 1080, height: 1080)
    public static let landscape = CanvasFormat(id: "landscape", name: "Landscape", detail: "YouTube, web, decks", width: 1920, height: 1080)
    public static let uhd = CanvasFormat(id: "uhd", name: "4K", detail: "Big screens", width: 3840, height: 2160)

    public static let presets: [CanvasFormat] = [.reel, .portrait, .square, .landscape, .uhd]

    /// The part of the frame the platform's interface leaves clear, which
    /// framings sit in: on a Reel the profile covers the top tenth and the
    /// caption and buttons the bottom fifth.
    public var safeArea: SafeArea {
        switch id {
        case "reel": return .reel
        case "portrait": return .feed
        default: return .none
        }
    }
}

/// Where the slide comes from.
public enum SlideKind: String, Codable, Sendable {
    /// The built-in sample, drawn as vectors at any zoom.
    case sample
    /// A PNG, JPEG, HEIC or other picture.
    case image
    /// One page of a PDF, redrawn from its vectors at any zoom.
    case pdf
}

public struct SlideRef: Codable, Hashable, Sendable {
    public var kind: SlideKind
    /// File name inside the document's Media folder; nil for the sample.
    public var file: String?
    public var page: Int
    /// Width / height.
    public var aspect: Float
    public var name: String
    /// Pixel size of a picture, which limits how far the camera can go in sharply.
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(kind: SlideKind, file: String? = nil, page: Int = 0, aspect: Float, name: String,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.kind = kind
        self.file = file
        self.page = page
        self.aspect = aspect
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public static let sample = SlideRef(kind: .sample, aspect: 16.0 / 9.0, name: "Sample slide")

    /// How far past its own pixels a picture is drawn (sharpened; see `SlideSource`).
    public static let pictureUpscale: Float = 2

    /// The least view height, in slide heights, at which a picture stays
    /// sharp on a canvas `canvasHeight` pixels tall; nil for vectors, which
    /// stay sharp at any distance.
    public func sharpViewHeight(canvasHeight: Int) -> Float? {
        guard kind == .image, let h = pixelHeight, h > 0 else { return nil }
        return Float(canvasHeight) / (Float(h) * SlideRef.pictureUpscale)
    }
}

/// The voiceover the moves are cut to.
public struct Voiceover: Codable, Hashable, Sendable {
    /// File name inside the document's Media folder.
    public var file: String
    public var name: String
    /// Seconds into the video where the recording starts.
    public var offset: Double
    /// Linear gain.
    public var gain: Float
    /// Length of the recording in seconds.
    public var duration: Double
    /// Recognised words, times relative to the video (offset included).
    public var words: [SpokenWord]?
    /// BCP-47 language used for recognition.
    public var language: String?

    public init(file: String, name: String, offset: Double = 0, gain: Float = 1, duration: Double,
                words: [SpokenWord]? = nil, language: String? = nil) {
        self.file = file
        self.name = name
        self.offset = offset
        self.gain = gain
        self.duration = duration
        self.words = words
        self.language = language
    }

    public var end: Double { offset + duration }
}

/// What the slide stands on.
public enum FloorKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Nothing: the slide floats in front of the backdrop.
    case none
    /// A soft, blurred reflection that fades within a short distance.
    case soft
    /// A glossy mirror floor.
    case mirror

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None"
        case .soft: return "Soft"
        case .mirror: return "Mirror"
        }
    }
}

/// Words over the opening, set in the band a tall frame leaves above the
/// slide. They rise in as the slide lands, clear as the camera goes in, and
/// come back for a Pull Back. Off until someone types them.
public struct OpeningTitle: Codable, Hashable, Sendable {
    public var text: String
    /// A short line above the title, such as a company or a date.
    public var kicker: String
    public var face: ReelTitle.Face
    /// Sets the kicker in capitals (the default), or as typed.
    public var kickerCaps: Bool

    public init(text: String = "", kicker: String = "", face: ReelTitle.Face = .modern, kickerCaps: Bool = true) {
        self.text = text
        self.kicker = kicker
        self.face = face
        self.kickerCaps = kickerCaps
    }

    enum CodingKeys: String, CodingKey { case text, kicker, face, kickerCaps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        kicker = try c.decode(String.self, forKey: .kicker)
        face = try c.decode(ReelTitle.Face.self, forKey: .face)
        // 0.2 documents have no choice saved: their kickers were capitals.
        kickerCaps = try c.decodeIfPresent(Bool.self, forKey: .kickerCaps) ?? true
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && kicker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Another slide in a video over several: after the slide before it, the
/// card turns over to it, or it melts into the card where you are looking.
public struct Page: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var slide: SlideRef
    /// What Direct for Me last read on it; nil until read, and cleared when
    /// the slide changes.
    public var reading: [SlideDetail]?
    /// How the card changes to it.
    public var change: PageChange
    /// Seconds from the start when the card starts to change to it, if set
    /// by hand; nil finds its own moment.
    public var at: Double?

    public init(id: UUID = UUID(), slide: SlideRef, reading: [SlideDetail]? = nil, change: PageChange = .turn, at: Double? = nil) {
        self.id = id
        self.slide = slide
        self.reading = reading
        self.change = change
        self.at = at
    }
}

/// One OOO document: a slide, the moves over it, and how it all looks.
public struct OOOProject: Codable, Hashable, Sendable {
    public var version: Int = 1
    /// The oldest OOO file reader that understands everything in this file.
    /// A build whose `readerVersion` is lower refuses the file rather than
    /// quietly exporting it without the settings it can't read.
    public var minimumReaderVersion: Int? = OOOProject.readerVersion
    /// The newest files this build reads in full. Raise it, and say in
    /// `neededReader` what needs it, when a setting older builds would drop arrives.
    /// 1: OOO 0.2. 2: OOO 1.0 (Weave, a kicker as typed). 3: OOO 1.0.1
    /// (several slides, room for you, marks drawn on the card).
    public static let readerVersion = 3

    /// The oldest reader that draws everything this project uses, written as
    /// `minimumReaderVersion`: a file 0.2 can draw still opens there.
    public var neededReader: Int {
        let typedKicker = title.map { !$0.kickerCaps && !$0.kicker.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        if !(pages?.isEmpty ?? true) || !(lift?.isEmpty ?? true) || !(marks?.isEmpty ?? true) { return 3 }
        return arrive.kind == .weave || typedKicker ? 2 : 1
    }
    /// The slide the video opens on (in a video over several, the first).
    public var slide: SlideRef
    /// The establishing framing the slide arrives into.
    public var overview: Shot
    public var shots: [Shot]
    public var arrive: Arrive
    public var ending: Ending
    public var style: MotionStyle
    public var look: StageLook
    public var backdrop: BackdropSettings
    public var format: CanvasFormat
    public var fps: Int = 30
    /// Seconds; nil fits the moves (and the voiceover, if any).
    public var length: Double?
    public var voice: Voiceover?
    public var seed: UInt32 = 1
    /// What the slide stands on; nil (documents from before floors) is `defaultFloor`.
    public var floor: FloorKind?
    /// Words over the opening; nil or empty for none.
    public var title: OpeningTitle?
    /// What Direct for Me last read on this slide, so it isn't read again
    /// and the tour can follow the canvas or a corrected slide. Nil until
    /// read, and cleared when the slide changes.
    public var reading: [SlideDetail]?
    /// The slides after the first, in order; nil or empty for one slide.
    public var pages: [Page]?
    /// Turning back to the first slide before the end, in a video over
    /// several; nil stays on the last.
    public var home: HomeTiming?
    /// Marks drawn on the card by hand; nil for none.
    public var marks: [Mark]?
    /// Room for you: where the stage rises to leave the bottom of the frame
    /// clear for a talking head; nil or no spans for never.
    public var lift: Lift?

    public init(slide: SlideRef, overview: Shot? = nil, shots: [Shot] = [], arrive: Arrive = Arrive(kind: .rise),
                ending: Ending = .pullBack, style: MotionStyle = MotionStyle(), look: StageLook = OOOProject.defaultLook,
                backdrop: BackdropSettings = OOOProject.defaultBackdrop, format: CanvasFormat = .reel) {
        self.slide = slide
        self.overview = overview ?? .overview(slideAspect: slide.aspect, canvasAspect: format.aspect)
        self.shots = shots
        self.arrive = arrive
        self.ending = ending
        self.style = style
        self.look = look
        self.backdrop = backdrop
        self.format = format
    }

    /// A glossy print under soft studio light, gently defocused around the
    /// detail, with a fine grain that survives compression.
    public static var defaultLook: StageLook {
        var l = StageLook()
        l.surface = .gloss
        l.bend = .card
        l.bendAmount = 1
        l.lightAzimuth = 118
        l.lightElevation = 52
        l.shadow = 0.6
        l.shadowSoftness = 0.6
        l.corners = 0.25
        l.depthOfField = 0.5
        l.shutter = 0.5
        l.edge = 1
        l.finish.bloom = 0.16
        l.finish.vignette = 0.3
        l.finish.grain = 0.14
        l.finish.grainSize = 0.3
        return l
    }

    public static var defaultBackdrop: BackdropSettings {
        var b = BackdropCatalog.style("studio").defaults
        b.palette = Palettes.named("graphite")
        b.motion = 0.25
        return b
    }

    /// The sample project every new window opens on, already moving.
    public static var sample: OOOProject {
        var p = OOOProject(slide: .sample)
        p.shots = SampleSlide.shots
        return p
    }

    public var slideAspect: Float { slide.aspect }
    public var canvasAspect: Float { format.aspect }

    public static let defaultFloor: FloorKind = .soft
    public var floorKind: FloorKind { floor ?? Self.defaultFloor }

    /// The least view height at which the slide stays sharp on this canvas;
    /// nil for vectors.
    public var sharpViewHeight: Float? { slide.sharpViewHeight(canvasHeight: format.height) }

    /// How many times closer than the opening the camera can go on this
    /// slide and canvas and stay sharp; nil when it always can.
    public var sharpZoom: Float? {
        guard let h = sharpViewHeight else { return nil }
        let opening = CameraPose(shot: overview, slideAspect: slideAspect, canvasAspect: canvasAspect, safe: format.safeArea)
        return opening.height / h
    }

    /// What Direct for Me plans from: the slide's reading, the voice, the canvas.
    public func directorInput(_ details: [SlideDetail]) -> DirectorInput {
        DirectorInput(details: details, words: voice?.words, slideAspect: slideAspect, canvasAspect: canvasAspect,
                      start: tourStart, safe: format.safeArea, minViewHeight: sharpViewHeight, overview: overview, style: style)
    }

    // MARK: Slides

    /// The slides after the first.
    public var morePages: [Page] { pages ?? [] }
    /// How many slides the video goes through.
    public var slideCount: Int { 1 + morePages.count }
    /// Every slide, the first first.
    public var allSlides: [SlideRef] { [slide] + morePages.map(\.slide) }

    /// Which slide a page id names (0 is the first); a slide no longer in the
    /// video counts as the first.
    public func pageIndex(_ id: UUID?) -> Int {
        guard let id, let k = morePages.firstIndex(where: { $0.id == id }) else { return 0 }
        return k + 1
    }

    /// The id the `k`th slide goes by on shots and marks: nil for the first.
    public func pageID(_ k: Int) -> UUID? { k > 0 && k <= morePages.count ? morePages[k - 1].id : nil }

    /// The `k`th slide (0 is the first).
    public func slide(_ k: Int) -> SlideRef { k > 0 && k <= morePages.count ? morePages[k - 1].slide : slide }

    /// What Direct for Me last read on the `k`th slide.
    public func reading(_ k: Int) -> [SlideDetail]? { k > 0 && k <= morePages.count ? morePages[k - 1].reading : reading }

    /// What Direct for Me plans from over several slides: each one's reading,
    /// given in order with the first's.
    public func pageReadings(_ found: [[SlideDetail]]) -> [PageReading] {
        allSlides.indices.map { k in
            let ref = slide(k)
            let page = k > 0 ? morePages[k - 1] : nil
            return PageReading(id: page?.id, details: k < found.count ? found[k] : [], aspect: ref.aspect,
                               change: page?.change ?? .turn, at: page?.at,
                               minViewHeight: ref.sharpViewHeight(canvasHeight: format.height))
        }
    }

    /// The tour Direct for Me plans from the slides' readings (the first's first).
    public func plannedShots(_ found: [[SlideDetail]]) -> [Shot] {
        guard let first = found.first else { return [] }
        if morePages.isEmpty { return Director.shots(directorInput(first)) }
        return Director.shots(directorInput(first), pages: pageReadings(found), arrive: arrive)
    }

    /// Every slide's reading, when every one has been read.
    public var readings: [[SlideDetail]]? {
        var all: [[SlideDetail]] = []
        for k in 0..<slideCount {
            guard let r = reading(k) else { return nil }
            all.append(r)
        }
        return all
    }

    /// The slides after the first as the camera's path needs them.
    public var pageTimings: [PageTiming] {
        morePages.map { PageTiming(id: $0.id, aspect: $0.slide.aspect, change: $0.change, at: $0.at) }
    }

    /// Keeps every framing and lands each one just before the voice says its
    /// words; over several slides, each slide's framings to the stretch of
    /// the voice that talks about it.
    public func retimed(to words: [SpokenWord]) -> [Shot] {
        guard !morePages.isEmpty, let found = readings else {
            return Director.retime(shots, words: words, start: tourStart)
        }
        let shares = Director.share(words, among: pageReadings(found))
        var out: [Shot] = []
        var earliest = tourStart
        for k in 0..<slideCount {
            let id = pageID(k)
            let mine = shots.filter { pageIndex($0.page) == k }
            guard !mine.isEmpty else { continue }
            let start = k == 0 ? earliest : max(earliest, (shares[k].first?.start ?? earliest) - 0.2)
            var timed = Director.retime(mine, words: shares[k], start: start)
            if shares[k].isEmpty, let first = mine.map(\.time).min(), first < start {
                // Nothing said about this slide: its framings keep their spacing after the last one's.
                timed = mine.map { var s = $0; s.time += start - first; return s }
            }
            out += timed.map { var s = $0; s.page = id; return s }
            // The next slide comes once this one has been seen and the card has changed.
            let next = k + 1 < slideCount ? morePages[k].change : .turn
            earliest = (timed.map(\.time).max() ?? start) + 2.0 + next.length + Choreography.turnSettle
        }
        return out
    }

    /// Moves slide `from` to `to` (0 is the first), each slide keeping its
    /// own tour: the slides' stretches of the video are laid out again in
    /// the new order, each keeping its own lead-in, and every change finds
    /// its own moment again.
    public mutating func moveSlide(_ from: Int, to: Int) {
        let n = slideCount
        guard from != to, (0..<n).contains(from), (0..<n).contains(to) else { return }
        struct Entry {
            var ref: SlideRef
            var reading: [SlideDetail]?
            var id: UUID
            var change: PageChange
            var shots: [Shot]
            var marks: [Mark]
            var lead: Double
        }
        let firstID = UUID()
        let A = slideAspect, C = canvasAspect
        var entries: [Entry] = (0..<n).map { k in
            Entry(ref: slide(k), reading: reading(k), id: pageID(k) ?? firstID, change: k > 0 ? morePages[k - 1].change : .turn,
                  shots: shots.filter { pageIndex($0.page) == k }, marks: (marks ?? []).filter { pageIndex($0.page) == k }, lead: 0)
        }
        // How long each slide's stretch takes to get going after the one before.
        let ends = entries.map { $0.shots.map(\.time).max() }
        for k in entries.indices {
            let start = entries[k].shots.map(\.time).min()
            if k > 0, let start, let end = ends[k - 1] { entries[k].lead = max(start - end, 3.5) } else { entries[k].lead = 4.5 }
        }
        let opening = entries[0].shots.map(\.time).min() ?? tourStart + 1
        let moved = entries.remove(at: from)
        entries.insert(moved, at: to)
        var cursor: Double?
        var allShots: [Shot] = []
        var allMarks: [Mark] = []
        for (k, e) in entries.enumerated() {
            let start = e.shots.map(\.time).min() ?? (e.marks.map(\.time).min() ?? opening)
            let wanted = cursor.map { $0 + e.lead } ?? opening
            let shift = wanted - start
            let id: UUID? = k == 0 ? nil : e.id
            allShots += e.shots.map { var s = $0; s.time += shift; s.page = id; return s }
            allMarks += e.marks.map { var m = $0; m.time += shift; m.page = id; return m }
            cursor = e.shots.map(\.time).max().map { $0 + shift } ?? wanted
        }
        slide = entries[0].ref
        reading = entries[0].reading
        pages = entries.dropFirst().map { Page(id: $0.id, slide: $0.ref, reading: $0.reading, change: $0.change) }
        shots = allShots
        marks = marks == nil && allMarks.isEmpty ? nil : allMarks
        adaptOverview(fromSlideAspect: A, canvasAspect: C)
    }

    /// Moves the change to slide `id` to `t`; what comes after it moves
    /// with it, so every framing keeps its time on its slide.
    @discardableResult
    public mutating func moveChange(_ id: UUID, to t: Double, from was: Double) -> Double {
        let k = pageIndex(id)
        guard k > 0, var all = pages else { return was }
        let at = max(t, arrive.end + 0.3)
        let d = at - was
        all[k - 1].at = at
        for j in all.indices where j > k - 1 { all[j].at = all[j].at.map { $0 + d } }
        pages = all
        for i in shots.indices where pageIndex(shots[i].page) >= k { shots[i].time += d }
        if var m = marks {
            for i in m.indices where pageIndex(m[i].page) >= k { m[i].time += d }
            marks = m
        }
        return at
    }

    /// How long the whole slide holds under an opening title before the tour
    /// sets off: long enough to read its words, title and kicker together.
    public var titleHold: Double {
        guard let title, !title.isEmpty else { return 0 }
        let words = (title.text + " " + title.kicker).split(whereSeparator: \.isWhitespace).count
        return min(max(0.7 + 0.26 * Double(words), 1.2), 2.6)
    }

    /// When the tour may set off: as the slide lands, or once its title has been read.
    public var tourStart: Double { arrive.end + titleHold }

    /// Gives a new opening title time to be read: without a voice to keep
    /// time with, the whole tour moves later until the first move sets off
    /// once the opening is over. Moves nothing when there is already room.
    public mutating func makeRoomForOpening() {
        guard voice == nil, !(title?.isEmpty ?? true), !shots.isEmpty else { return }
        // The first move takes longer once it has more room, so this settles
        // in a step or two.
        for _ in 0..<3 {
            let beats = choreography().beats
            guard beats.count > 1, let first = shots.map(\.time).min() else { return }
            // Later until the first move sets off once the opening is over, and
            // as far as the camera would have held the first shot back anyway,
            // so the shots after it keep their spacing.
            let shift = max(tourStart - beats[1].depart, beats[1].land - first)
            guard shift > 0.05 else { return }
            for i in shots.indices { shots[i].time += shift }
            if var m = marks {
                for i in m.indices { m[i].time += shift }
                marks = m
            }
            if var all = pages {
                for j in all.indices { all[j].at = all[j].at.map { $0 + shift } }
                pages = all
            }
        }
    }

    /// A corrected version of the slide, keeping the tour: every shot keeps
    /// its time, move and words, and each one about a detail follows that
    /// detail's words to where they are on the new slide. `old` is the
    /// slide's reading before; `new` the replacement's.
    public mutating func replaceSlide(with ref: SlideRef, reading new: [SlideDetail], from old: [SlideDetail]) {
        let (A, C) = (slideAspect, canvasAspect)
        slide = ref
        reading = new
        adaptOverview(fromSlideAspect: A, canvasAspect: C)
        follow(page: 0, from: old, to: new)
    }

    /// A corrected version of one of the slides after the first, keeping its
    /// tour, as `replaceSlide` does for the first.
    public mutating func replacePage(_ id: UUID, with ref: SlideRef, reading new: [SlideDetail], from old: [SlideDetail]) {
        guard var all = pages, let j = all.firstIndex(where: { $0.id == id }) else { return }
        all[j].slide = ref
        all[j].reading = new
        pages = all
        follow(page: j + 1, from: old, to: new)
    }

    /// The shots on slide `k` follow their details to the slide's new version.
    mutating func follow(page k: Int, from old: [SlideDetail], to new: [SlideDetail]) {
        let mine = shots.indices.filter { pageIndex(shots[$0].page) == k }
        let moved = Director.follow(mine.map { shots[$0] }, from: old, to: new)
        for (i, s) in zip(mine, moved) { shots[i] = s }
    }

    /// Framings Direct for Me planned, framed again for a new canvas, slide by slide.
    public mutating func reframePlanned() {
        guard shots.contains(where: \.isPlanned), let found = readings else { return }
        let fresh = plannedShots(found)
        var out = shots
        for k in 0..<slideCount {
            let mine = shots.indices.filter { pageIndex(shots[$0].page) == k }
            let again = Director.reframe(mine.map { shots[$0] }, from: fresh.filter { pageIndex($0.page) == k })
            for (i, s) in zip(mine, again) { out[i] = s }
        }
        shots = out
    }

    /// Follows a new slide or canvas shape with the opening, unless someone
    /// has set the opening themselves.
    public mutating func adaptOverview(fromSlideAspect A: Float, canvasAspect C: Float) {
        guard overview.isDefaultOverview(slideAspect: A, canvasAspect: C) else { return }
        let d = Shot.overview(slideAspect: slideAspect, canvasAspect: canvasAspect)
        overview.frame = d.frame
        overview.yaw = d.yaw
        overview.pitch = d.pitch
    }

    /// The video's length: as set, or long enough for every move and the whole voiceover.
    public var duration: Double {
        if let length { return max(length, 1) }
        var d = Choreography.naturalDuration(choreographyInput(duration: 0))
        // Turning back, the last words go over the turn and the first slide rests after them.
        if let voice { d = max(d, voice.end + (turnsHome ? 2.0 : 1.2)) }
        // Every mark is drawn, and seen.
        for m in marks ?? [] { d = max(d, m.fades ? m.gone + 0.4 : m.drawn + 1.2) }
        return d
    }

    /// The share of the frame an opening title keeps above the slide while the stage is up.
    public static let titleRoom: Float = 0.12

    /// Whether the card turns back to the first slide before the end.
    public var turnsHome: Bool { home != nil && !morePages.isEmpty }

    public var choreographyInput: ChoreographyInput { choreographyInput(duration: duration) }

    func choreographyInput(duration: Double) -> ChoreographyInput {
        ChoreographyInput(overview: overview, shots: shots, arrive: arrive, ending: ending, duration: duration,
                          slideAspect: slideAspect, canvasAspect: canvasAspect, style: style, seed: seed, safe: format.safeArea,
                          pages: pageTimings, home: turnsHome ? home : nil, lift: lift,
                          titleRoom: (title?.isEmpty ?? true) ? 0 : Self.titleRoom)
    }

    public func choreography() -> Choreography { Choreography(choreographyInput) }
}

/// Package layout: `<name>.ooo/project.json` plus `Media/<file>`.
public enum ProjectPackage {
    public static let projectFile = "project.json"
    public static let mediaFolder = "Media"
    public static let fileExtension = "ooo"
    public static let typeIdentifier = "dog.pitch.ooo.project"

    public static func encode(_ project: OOOProject) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var p = project
        p.minimumReaderVersion = p.neededReader
        return try enc.encode(p)
    }

    public static func decode(_ data: Data) throws -> OOOProject {
        // Read the version first: a newer file may not decode at all here.
        struct Header: Decodable { var minimumReaderVersion: Int? }
        if let needs = (try? JSONDecoder().decode(Header.self, from: data))?.minimumReaderVersion, needs > OOOProject.readerVersion {
            throw PackageError.newer
        }
        var project = try JSONDecoder().decode(OOOProject.self, from: data)
        project.minimumReaderVersion = OOOProject.readerVersion
        return project
    }

    public enum PackageError: LocalizedError {
        /// The file needs a newer OOO.
        case newer

        public var errorDescription: String? {
            switch self {
            case .newer: return "This project was made with a newer OOO. Choose Check for Updates… in the OOO menu, then open it again."
            }
        }
    }

    /// Reads a package from disk, returning the project and its media folder.
    public static func read(_ url: URL) throws -> (OOOProject, URL) {
        let data = try Data(contentsOf: url.appendingPathComponent(projectFile))
        return (try decode(data), url.appendingPathComponent(mediaFolder, isDirectory: true))
    }

    /// Writes a package to disk, copying media from `media`.
    public static func write(_ project: OOOProject, media: URL?, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent(mediaFolder), withIntermediateDirectories: true)
        try encode(project).write(to: url.appendingPathComponent(projectFile), options: .atomic)
        guard let media else { return }
        for file in (project.allSlides.map(\.file) + [project.voice?.file]).compactMap({ $0 }) {
            let src = media.appendingPathComponent(file), dst = url.appendingPathComponent(mediaFolder).appendingPathComponent(file)
            if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) { try fm.copyItem(at: src, to: dst) }
        }
    }
}
