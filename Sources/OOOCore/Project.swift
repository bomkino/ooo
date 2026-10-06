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

/// One OOO document: a slide, the moves over it, and how it all looks.
public struct OOOProject: Codable, Hashable, Sendable {
    public var version: Int = 1
    /// The oldest OOO file reader that understands everything in this file.
    /// A build whose `readerVersion` is lower refuses the file rather than
    /// quietly exporting it without the settings it can't read.
    public var minimumReaderVersion: Int? = OOOProject.readerVersion
    /// The newest files this build reads in full. Raise it, and write it as
    /// `minimumReaderVersion`, when a setting older builds would drop arrives.
    public static let readerVersion = 1
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
    /// once the title has been read. Moves nothing when there is already room.
    public mutating func makeRoomForTitle() {
        guard voice == nil, !(title?.isEmpty ?? true), !shots.isEmpty else { return }
        // The first move takes longer once it has more room, so this settles
        // in a step or two.
        for _ in 0..<3 {
            let beats = choreography().beats
            guard beats.count > 1 else { return }
            let shift = tourStart - beats[1].depart
            guard shift > 0.05 else { return }
            for i in shots.indices { shots[i].time += shift }
        }
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
        var d = Choreography.naturalDuration(shots: shots, arrive: arrive, ending: ending)
        if let voice { d = max(d, voice.end + 1.2) }
        return d
    }

    public var choreographyInput: ChoreographyInput {
        ChoreographyInput(overview: overview, shots: shots, arrive: arrive, ending: ending, duration: duration,
                          slideAspect: slideAspect, canvasAspect: canvasAspect, style: style, seed: seed, safe: format.safeArea)
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
        return try enc.encode(project)
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
        for file in [project.slide.file, project.voice?.file].compactMap({ $0 }) {
            let src = media.appendingPathComponent(file), dst = url.appendingPathComponent(mediaFolder).appendingPathComponent(file)
            if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) { try fm.copyItem(at: src, to: dst) }
        }
    }
}
