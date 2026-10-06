import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Metal
import Observation
import OOOCore
import OOOMotion
import QuartzCore
import RenderCore
import StageKit
import SwiftUI
import UniformTypeIdentifiers

/// Playback position. The transport and the slide map observe it every frame.
@Observable
public final class PlaybackClock {
    public var time: Double = 0
    public var playing = true
    public var duration: Double = 10
    /// True while the person types in a text field; single-key shortcuts stand down.
    public var typing = false
    public init() {
        playing = !Self.reduceMotion
    }

    /// With Reduce Motion on, the editor never starts playing by itself; the
    /// film it exports moves as it always does.
    static var reduceMotion: Bool { MainActor.assumeIsolated { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }

    /// Plays from here, unless Reduce Motion asks the editor to keep still.
    public func autoplay() {
        playing = !Self.reduceMotion
    }
}

/// What the inspector is showing.
public enum Selection: Hashable {
    /// The arrival, the establishing framing and the ending.
    case overview
    case shot(UUID)
}

public enum InspectorTab: String, CaseIterable, Identifiable {
    case shot, look, voice
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .shot: return "Camera"
        case .look: return "Look"
        case .voice: return "Voice"
        }
    }
}

/// One GPU renderer for every window.
public enum OOOShared {
    public static let stage: SlideStage? = try? SlideStage()
}

/// The slide on the GPU, with everything drawn from it.
final class SlideBase: @unchecked Sendable {
    let ref: SlideRef
    let source: SlideSource
    let texture: MTLTexture
    let density: Float
    let details: DetailCache
    let preview: CGImage?

    init(ref: SlideRef, media: URL?) throws {
        self.ref = ref
        source = try SlideSource(ref: ref, media: media)
        guard let whole = source.renderWhole() else { throw RenderError.io("Could not draw the slide.") }
        texture = try MediaLoader.texture(from: whole).texture
        density = Float(whole.height)
        details = DetailCache(source: source, baseDensity: density)
        preview = SlideBase.downscaled(whole, side: 1400)
    }

    static func downscaled(_ img: CGImage, side: Int) -> CGImage? {
        let k = min(1, CGFloat(side) / CGFloat(max(img.width, img.height)))
        let w = max(1, Int(CGFloat(img.width) * k)), h = max(1, Int(CGFloat(img.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Editor state for one window.
@Observable
@MainActor
public final class OOOSession {
    @ObservationIgnored public let document: OOODocument
    @ObservationIgnored public weak var undoManager: UndoManager?

    public private(set) var project: OOOProject
    public private(set) var choreography: Choreography
    /// Increments whenever anything visible changes; the stage redraws on change.
    public private(set) var version = 0
    public let clock = PlaybackClock()
    public var selection: Selection = .overview
    public var tab: InspectorTab = .shot
    public var showExport = false {
        didSet { if showExport { clock.playing = false } }
    }
    public var message: String?
    /// What OOO is busy with, in words: the latest job still running.
    public var busy: String? { jobs.last?.label }
    private var jobs: [(id: Int, label: String)] = []
    private var lastJob = 0
    /// The slide drawn small, for the map and the timeline.
    public private(set) var slidePreview: CGImage?
    /// Every slide after the first drawn small, by its id, for the inspector and the timeline.
    public private(set) var pagePreviews: [UUID: CGImage] = [:]
    /// Shows on the stage where you will be while the stage is up for you.
    public var showRoom = true
    /// The slide's main colours, for a room in them.
    private var slideColours: Palette?

    /// The room's palette in the slide's colours, at the room's own lightness.
    public var slidePalette: Palette? { slideColours?.atLightness(of: project.backdrop.palette) }
    /// The voiceover's peaks, recording time.
    public private(set) var waveform: Waveform?
    /// Pages in the slide's PDF, when it has more than one.
    public private(set) var pageCount = 1
    /// The timeline's length while something on it is dragged (see `timelineLength`).
    public private(set) var heldTimelineLength: Double?
    /// True while \ is held: the stage shows the slide in the Original look,
    /// exactly as supplied, to compare.
    public private(set) var comparing = false {
        didSet {
            guard comparing != oldValue else { return }
            sceneCache = nil
            version += 1
        }
    }

    @ObservationIgnored private var slideBase: SlideBase?
    @ObservationIgnored private var slideToken = 0
    /// The slides after the first on the GPU, by id, and those being drawn.
    @ObservationIgnored private var pageBases: [UUID: SlideBase] = [:]
    @ObservationIgnored private var pagesDrawing: Set<UUID> = []
    @ObservationIgnored private var sceneCache: SlideScene?
    /// A dropped slide whose tour is still being planned: the drop and its
    /// tour become one undo step when the plan lands.
    @ObservationIgnored private var pendingDrop: (before: OOOProject, name: String)?
    @ObservationIgnored private var voiceTrack: AudioTrack?
    @ObservationIgnored private var voiceFile: String?
    @ObservationIgnored private var placedCache: (key: VoiceKey, track: AudioTrack)?
    @ObservationIgnored private var pendingVoice: (key: VoiceKey, since: Double)?
    @ObservationIgnored private let player = VoicePlayer()
    @ObservationIgnored private var lastSoundTime: Double?
    @ObservationIgnored private var thumbs: [ThumbKey: CGImage] = [:]
    @ObservationIgnored private var pendingEditStart: OOOProject?
    @ObservationIgnored private var pendingEditName: String?
    /// Set when Esc cancels a gesture: the rest of it changes nothing, until
    /// it ends (or anything else is edited).
    @ObservationIgnored private var editCancelled = false
    /// Closes a run of key nudges as one undo step once the keys rest.
    @ObservationIgnored private var nudgeRest: DispatchWorkItem?

    public init(document: OOODocument) {
        self.document = document
        project = document.project
        choreography = document.project.choreography()
        clock.duration = choreography.duration
    }

    /// Loads the slide and voiceover when the window appears (SwiftUI may build
    /// and discard sessions whenever it rebuilds the view).
    public func start() {
        loadSlide()
        loadPages()
        loadVoice()
    }

    // MARK: Editing with undo

    /// Applies a change as one undoable step. A gesture still open is closed first.
    public func update(_ actionName: String, _ change: (inout OOOProject) -> Void) {
        finishDrop()
        editCancelled = false
        let openGesture = pendingEditStart != nil ? pendingEditName : nil
        let wasOpen = pendingEditStart != nil
        if wasOpen { commitEdit(pendingEditName ?? "Edit") }
        defer {
            if wasOpen {
                pendingEditStart = project
                pendingEditName = openGesture
            }
        }
        let before = project
        var after = project
        change(&after)
        guard after != before else { return }
        set(after)
        registerUndo(from: before, name: actionName)
    }

    /// Call at the start of a continuous gesture (a slider drag, a drag on the map).
    public func beginEdit(_ name: String? = nil) {
        finishDrop()
        editCancelled = false
        if pendingEditStart != nil, pendingEditName != name { commitEdit(pendingEditName ?? "Edit") }
        if pendingEditStart == nil {
            pendingEditStart = project
            pendingEditName = name
        }
    }

    /// A change during a gesture: no undo step until it commits.
    public func live(_ change: (inout OOOProject) -> Void) {
        guard !editCancelled else { return }
        var p = project
        change(&p)
        guard p != project else { return }
        set(p)
    }

    /// Closes the gesture `actionName` began. A late close for a gesture
    /// already closed (a run of nudges resting) leaves the next one open.
    public func commitEdit(_ actionName: String) {
        editCancelled = false
        guard let start = pendingEditStart, pendingEditName == nil || pendingEditName == actionName else { return }
        nudgeRest?.cancel()
        nudgeRest = nil
        pendingEditStart = nil
        pendingEditName = nil
        if start != project { registerUndo(from: start, name: actionName) }
    }

    /// Esc during a drag: everything goes back to how it was when the drag
    /// began, and the rest of the drag changes nothing. False when nothing
    /// was being dragged.
    @discardableResult
    public func cancelEdit() -> Bool {
        guard let start = pendingEditStart, !clock.typing else { return false }
        nudgeRest?.cancel()
        nudgeRest = nil
        pendingEditStart = nil
        pendingEditName = nil
        editCancelled = true
        if start != project { set(start) }
        return true
    }

    /// One press of a nudge key. A run of presses is one undo step, closed
    /// once the keys have rested for a moment.
    public func nudge(_ name: String, _ change: (inout OOOProject) -> Void) {
        beginEdit(name)
        live(change)
        nudgeRest?.cancel()
        let rest = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingEditName == name else { return }
                self.commitEdit(name)
            }
        }
        nudgeRest = rest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: rest)
    }

    /// Keys no menu can carry. Returns true when the key was used: Esc
    /// cancels a drag, and holding \ shows the Original look.
    public func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 { return cancelEdit() }
        guard event.charactersIgnoringModifiers == "\\",
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        if event.type == .keyUp {
            guard comparing else { return false }
            comparing = false
            return true
        }
        guard !clock.typing else { return false }
        if !event.isARepeat { comparing = true }
        return true
    }

    /// Closes a drop as one undo step: the slide, and its tour if it has one by now.
    private func finishDrop() {
        guard let drop = pendingDrop else { return }
        pendingDrop = nil
        if drop.before != project { registerUndo(from: drop.before, name: drop.name) }
    }

    /// A new slide (or page) and its tour, undone together.
    func drop(_ name: String, _ change: (inout OOOProject) -> Void) {
        if pendingEditStart != nil { commitEdit(pendingEditName ?? "Edit") }
        finishDrop()
        let before = project
        var after = project
        change(&after)
        guard after != before else { return }
        set(after)
        pendingDrop = (before, name)
    }

    private func set(_ p: OOOProject) {
        let slideChanged = p.slide != project.slide
        let voiceChanged = p.voice?.file != project.voice?.file
        let pagesChanged = p.morePages.map(\.id) != project.morePages.map(\.id) || p.morePages.map(\.slide) != project.morePages.map(\.slide)
        if slideChanged || pagesChanged || p.format != project.format { thumbs = [:] }
        project = p
        document.project = p
        choreography = p.choreography()
        sceneCache = nil
        version += 1
        let d = choreography.duration
        if abs(clock.duration - d) > 1e-6 {
            clock.duration = d
            if clock.time > d { clock.time = d }
        }
        if case .shot(let id) = selection, !p.shots.contains(where: { $0.id == id }) { selection = .overview }
        if slideChanged { loadSlide() }
        if voiceChanged { loadVoice() }
        if pagesChanged { loadPages() }
    }

    private func registerUndo(from old: OOOProject, name: String) {
        guard let um = undoManager else { return }
        let current = project
        um.registerUndo(withTarget: document) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Undoing past a drop still being planned drops its plan too.
                self.pendingDrop = nil
                self.set(old)
                if self.pendingEditStart != nil { self.pendingEditStart = old }
                self.registerUndo(from: current, name: name)
            }
        }
        um.setActionName(name)
    }

    public func touch() { version += 1 }

    // MARK: The slide

    public static let slideTypes: [UTType] = [.pdf, .png, .jpeg, .heic, .tiff, .image]

    /// The frame source for the stage, or nil while the slide is still being drawn.
    public var scene: SlideScene? {
        if let s = sceneCache { return s }
        guard let b = slideBase else { return nil }
        var shown = project
        if comparing { shown.look.surface = .original }
        // A slide still being drawn shows the first in its place for a moment.
        let pages = project.morePages.map { page in pageBases[page.id].flatMap { $0.ref == page.slide ? $0 : nil } }
        let s = SlideScene(project: shown, bases: [b.texture] + pages.map { $0?.texture ?? b.texture },
                           details: [b.details] + pages.map { $0?.details }, inks: InkCache.shared.textures(for: project),
                           choreography: choreography)
        sceneCache = s
        return s
    }

    /// A scene with its own detail caches, so an export never fights the
    /// live stage; nil until every slide is drawn.
    public func exportScene() -> SlideScene? {
        guard let b = slideBase, pagesReady else { return nil }
        let pages = project.morePages.compactMap { pageBases[$0.id] }
        return SlideScene(project: project, bases: [b.texture] + pages.map(\.texture),
                          details: ([b] + pages).map { DetailCache(source: $0.source, baseDensity: $0.density) },
                          inks: InkCache.shared.textures(for: project), choreography: choreography)
    }

    /// Whether every slide after the first is drawn and ready.
    public var pagesReady: Bool { project.morePages.allSatisfy { pageBases[$0.id]?.ref == $0.slide } }

    public var hasSlide: Bool { slideBase != nil }

    /// Shows `label` until the job it names ends; jobs can overlap.
    private func begin(_ label: String) -> Int {
        lastJob += 1
        jobs.append((lastJob, label))
        return lastJob
    }

    private func end(_ job: Int) {
        jobs.removeAll { $0.id == job }
    }

    /// A job run from a menu command, shown the same way.
    public func beginJob(_ label: String) -> Int { begin(label) }
    public func endJob(_ job: Int) { end(job) }

    func loadSlide() {
        let ref = project.slide
        if let b = slideBase, b.ref == ref { return }
        let media = document.media.directory
        slideToken += 1
        let token = slideToken
        let job = begin("Drawing the slide")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SlideBase(ref: ref, media: media) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.end(job)
                    guard token == self.slideToken else { return }
                    switch result {
                    case .success(let base): self.install(base)
                    case .failure(let error): self.message = "Couldn't draw the slide: \(readable(error))"
                    }
                }
            }
        }
    }

    /// Draws every slide after the first not drawn yet, and forgets those gone.
    func loadPages() {
        let wanted = project.morePages
        for (id, base) in pageBases where wanted.first(where: { $0.id == id })?.slide != base.ref {
            pageBases[id] = nil
            pagePreviews[id] = nil
        }
        let media = document.media.directory
        for page in wanted where pageBases[page.id] == nil && !pagesDrawing.contains(page.id) {
            let id = page.id, ref = page.slide
            pagesDrawing.insert(id)
            let job = begin("Drawing the slides")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try SlideBase(ref: ref, media: media) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.end(job)
                        self.pagesDrawing.remove(id)
                        switch result {
                        case .success(let base):
                            guard self.project.morePages.first(where: { $0.id == id })?.slide == ref else {
                                // Changed while it was drawn: draw what is there now.
                                self.loadPages()
                                return
                            }
                            base.details.onReady = { [weak self] in
                                MainActor.assumeIsolated { self?.touch() }
                            }
                            self.pageBases[id] = base
                            self.pagePreviews[id] = base.preview
                            self.thumbs = [:]
                            self.sceneCache = nil
                            self.version += 1
                        case .failure(let error):
                            self.message = "Couldn't draw \(ref.name): \(readable(error))"
                        }
                    }
                }
            }
        }
    }

    private func install(_ base: SlideBase) {
        slideBase = base
        base.details.onReady = { [weak self] in
            MainActor.assumeIsolated { self?.touch() }
        }
        slidePreview = base.preview
        slideColours = base.preview.flatMap { Palette.extract(from: [$0], id: "slide", name: "Slide") }
        thumbs = [:]
        sceneCache = nil
        if base.ref.kind == .pdf, let file = base.ref.file {
            pageCount = SlideSource.pageCount(document.media.url(for: file))
        } else {
            pageCount = 1
        }
        version += 1
    }

    /// Takes a picture or the first page of a PDF as the slide, and plans a tour of it.
    public func importSlide(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard var ref = SlideSource.inspect(url) else {
            message = "OOO can't read that file as a slide. Use a PDF or a picture: PNG, JPEG, HEIC or TIFF."
            return
        }
        do {
            ref.file = try document.media.importFile(url)
        } catch {
            message = "Couldn't copy the slide: \(error.localizedDescription)"
            return
        }
        drop("Change Slide") { p in
            let (A, C) = (p.slideAspect, p.canvasAspect)
            p.slide = ref
            p.shots = []
            p.reading = nil
            p.adaptOverview(fromSlideAspect: A, canvasAspect: C)
        }
        selection = .overview
        // The arrival plays once, when the slide has been read and its tour is
        // planned; until then the stage holds on the room.
        clock.time = 0
        clock.playing = false
        autoDirect()
    }

    /// A corrected version of slide `k`: its tour stays, and each framing
    /// follows its words to where they are now. With no tour yet, the first
    /// is a new slide.
    public func replaceSlide(_ url: URL, page k: Int = 0) {
        guard k > 0 || (hasSlide && !project.shots.isEmpty) else { importSlide(url); return }
        guard k < project.slideCount else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard var ref = SlideSource.inspect(url) else {
            message = "OOO can't read that file as a slide. Use a PDF or a picture: PNG, JPEG, HEIC or TIFF."
            return
        }
        do {
            ref.file = try document.media.importFile(url)
        } catch {
            message = "Couldn't copy the slide: \(error.localizedDescription)"
            return
        }
        let was = project.slide(k), known = project.reading(k), now = ref, id = project.pageID(k)
        let media = document.media.directory
        let job = begin("Reading the new slide")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> (old: [SlideDetail], new: [SlideDetail]) in
                let old = try known ?? SlideAnalysis.read(SlideSource(ref: was, media: media))
                return (old, try SlideAnalysis.read(SlideSource(ref: now, media: media)))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.end(job)
                    // Another slide was dropped meanwhile: that one wins.
                    guard self.project.pageIndex(id) == k, self.project.slide(k) == was else { return }
                    switch result {
                    case .success(let reading):
                        self.update("Replace Slide") { p in
                            if let id {
                                p.replacePage(id, with: now, reading: reading.new, from: reading.old)
                            } else {
                                p.replaceSlide(with: now, reading: reading.new, from: reading.old)
                            }
                        }
                    case .failure(let error):
                        self.message = "Couldn't read the new slide: \(readable(error))"
                    }
                }
            }
        }
    }

    /// Takes the slide on the clipboard: a PDF or picture copied in Finder,
    /// or a slide copied straight from Keynote, Figma or Preview (vectors
    /// first, when the app put a PDF of it there).
    public func pasteSlide() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { u in
               let type = UTType(filenameExtension: u.pathExtension)
               return Self.slideTypes.contains { type?.conforms(to: $0) ?? false }
           }) {
            importSlide(url)
            return
        }
        let kinds: [(NSPasteboard.PasteboardType, String)] = [(.pdf, "pdf"), (.png, "png"), (.tiff, "tiff")]
        for (type, ext) in kinds {
            guard let data = pb.data(forType: type) else { continue }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = folder.appendingPathComponent("Pasted slide.\(ext)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url)
            } catch {
                message = "Couldn't paste the slide: \(error.localizedDescription)"
                return
            }
            importSlide(url)
            try? FileManager.default.removeItem(at: folder)
            return
        }
        message = "There's no slide on the clipboard. Copy a slide in Keynote, Figma or Preview, or a PDF or picture in Finder, then paste it here."
    }

    /// Shows another page of the slide's PDF.
    public func showPage(_ page: Int) {
        guard project.slide.kind == .pdf, let file = project.slide.file else { return }
        let n = max(0, min(page, pageCount - 1))
        guard n != project.slide.page, var ref = SlideSource.inspect(document.media.url(for: file), page: n) else { return }
        ref.file = file
        ref.name = project.slide.name
        drop("Change Page") { p in
            let (A, C) = (p.slideAspect, p.canvasAspect)
            p.slide = ref
            p.shots = []
            p.reading = nil
            p.adaptOverview(fromSlideAspect: A, canvasAspect: C)
        }
        selection = .overview
        clock.time = 0
        autoDirect()
    }

    struct ThumbKey: Hashable {
        var frame: ShotFrame
        var page: Int
    }

    /// The `k`th slide drawn small (0 is the first).
    public func preview(_ k: Int) -> CGImage? {
        guard let id = project.pageID(k) else { return slidePreview }
        return pagePreviews[id]
    }

    /// The part of slide `page` a framing shows, cut from its preview, for the timeline.
    public func thumbnail(_ frame: ShotFrame, page: Int = 0) -> CGImage? {
        let key = ThumbKey(frame: frame, page: page)
        if let t = thumbs[key] { return t }
        guard let img = preview(page) else { return nil }
        let v = frame.visible(slideAspect: project.slide(page).aspect, canvasAspect: project.canvasAspect)
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let rect = CGRect(x: CGFloat(v.minU) * W, y: CGFloat(v.minV) * H, width: CGFloat(v.size.x) * W, height: CGFloat(v.size.y) * H)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let crop = img.cropping(to: rect) else { return nil }
        if thumbs.count > 240 { thumbs.removeAll() }
        thumbs[key] = crop
        return crop
    }

    // MARK: Directing

    /// Reads the slides and plans a tour of them: on each, the headline, the
    /// details worth stopping on in reading order, the small print last, cut
    /// to the voice if there is one. With `adding`, only those new slides
    /// get a tour, after the one there already, unless every framing so far
    /// was planned anyway.
    public func autoDirect(adding: Set<UUID>? = nil) {
        let refs = project.allSlides
        let media = document.media.directory
        // A slide already read isn't read again; a new slide or page has no reading yet.
        let cached = (0..<project.slideCount).map { project.reading($0) }
        let job = begin(refs.count > 1 ? "Reading the slides" : "Reading the slide")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> [[SlideDetail]] in
                try refs.indices.map { k in
                    if let c = cached[k] { return c }
                    return try SlideAnalysis.read(SlideSource(ref: refs[k], media: media))
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.end(job)
                    guard self.project.allSlides == refs else { return }
                    // A new slide waits for its tour to arrive; it arrives now either way.
                    let fresh = self.pendingDrop != nil
                    switch result {
                    case .success(let found):
                        let store: (inout OOOProject) -> Void = { p in
                            p.reading = found.first
                            if var pages = p.pages {
                                for j in pages.indices where j + 1 < found.count { pages[j].reading = found[j + 1] }
                                p.pages = pages
                            }
                        }
                        var planned = self.project.plannedShots(found)
                        if let adding, self.project.shots.contains(where: { !$0.isPlanned }) {
                            // Framings you set stay as they are; the new slides' tours follow them.
                            let before = planned.filter { !adding.contains($0.page ?? UUID()) }.map(\.time).max() ?? 0
                            let have = self.project.shots.map(\.time).max() ?? before
                            planned = self.project.shots + planned.filter { adding.contains($0.page ?? UUID()) }.map {
                                var s = $0
                                s.time += have - before
                                return s
                            }
                        }
                        let shots = planned
                        guard !shots.isEmpty else {
                            var p = self.project
                            store(&p)
                            if p != self.project { self.set(p) }
                            self.finishDrop()
                            if fresh {
                                self.selection = .overview
                                self.clock.time = 0
                                self.clock.autoplay()
                            }
                            self.message = "OOO found nothing to read on this slide. Draw framings on the slide map to choose what the camera visits."
                            return
                        }
                        if self.pendingDrop != nil {
                            var p = self.project
                            p.shots = shots
                            store(&p)
                            self.set(p)
                            self.finishDrop()
                        } else {
                            self.update("Direct") { p in
                                p.shots = shots
                                store(&p)
                            }
                        }
                        if adding == nil {
                            self.selection = .overview
                            self.clock.time = 0
                            self.clock.autoplay()
                        }
                    case .failure(let error):
                        self.finishDrop()
                        if fresh {
                            self.selection = .overview
                            self.clock.time = 0
                            self.clock.autoplay()
                        }
                        self.message = "Couldn't read the slide: \(readable(error))"
                    }
                }
            }
        }
    }

    /// Keeps every framing and lands each one just before the voice says its words.
    public func cutToVoice() {
        guard let words = project.voice?.words, !words.isEmpty else { return }
        update("Cut to Voice") { p in
            p.shots = p.retimed(to: words)
        }
    }

    // MARK: Shots

    public var selectedShot: Shot? {
        guard case .shot(let id) = selection else { return nil }
        return project.shots.first { $0.id == id }
    }

    /// Shots in the order the camera visits them.
    public var orderedShots: [Shot] { project.shots.sorted { $0.time < $1.time } }

    public func index(of id: UUID) -> Int? { orderedShots.firstIndex { $0.id == id } }

    public func updateShot(_ id: UUID, _ name: String, _ change: (inout Shot) -> Void) {
        update(name) { p in
            if let i = p.shots.firstIndex(where: { $0.id == id }) { Self.edit(&p.shots[i], change) }
        }
    }

    /// A change made by hand. Once its framing is yours, it stays where you put it.
    static func edit(_ shot: inout Shot, _ change: (inout Shot) -> Void) {
        let before = shot
        change(&shot)
        if shot.framesDifferently(from: before) { shot.planned = nil }
    }

    /// The selected framing (a shot, or the opening), changed by a nudge key.
    private func nudgeSelected(_ name: String, _ change: @escaping (inout Shot) -> Void) {
        switch selection {
        case .shot(let id):
            nudge(name) { p in
                if let i = p.shots.firstIndex(where: { $0.id == id }) { Self.edit(&p.shots[i], change) }
            }
        case .overview:
            nudge(name) { p in change(&p.overview) }
        }
    }

    /// Moves the selected framing a twentieth of its size: -1 or 1 across, -1 (up) or 1 (down).
    public func nudgeFraming(_ dx: Float, _ dy: Float) {
        nudgeSelected("Move Framing") { s in
            let f = s.frame
            s.frame.center = Vec2(min(max(f.center.x + dx * 0.05 * f.size.x, 0), 1),
                                  min(max(f.center.y + dy * 0.05 * f.size.y, 0), 1))
        }
    }

    /// Takes the selected framing closer (`closer`) or wider by a step.
    public func nudgeZoom(closer: Bool) {
        nudgeSelected("Frame Shot") { s in
            s.frame.size = s.frame.size * (closer ? 0.95 : 1 / 0.95)
        }
    }

    /// Lands the selected shot a tenth of a second earlier (-1) or later (1).
    public func nudgeTime(_ direction: Double) {
        guard case .shot(let id) = selection else { return }
        nudge("Move Shot") { p in
            let start = p.tourStart + 0.3
            if let i = p.shots.firstIndex(where: { $0.id == id }) { p.shots[i].time = max(start, p.shots[i].time + 0.1 * direction) }
        }
        select(.shot(id))
    }

    /// The length the timeline lays out. While a framing or the voice is
    /// dragged it stays put under the pointer, growing only in steps if the
    /// video outgrows it, and it follows the video again on release.
    public var timelineLength: Double {
        let d = clock.duration
        guard let held = heldTimelineLength, held > 0 else { return d }
        guard d > held else { return held }
        return held * pow(1.25, ceil(log(d / held) / log(1.25)))
    }

    /// Holds the timeline's scale for a drag, or lets it go.
    public func holdTimeline(_ on: Bool) {
        heldTimelineLength = on ? clock.duration : nil
    }

    public func liveShot(_ id: UUID, _ change: (inout Shot) -> Void) {
        live { p in
            if let i = p.shots.firstIndex(where: { $0.id == id }) { Self.edit(&p.shots[i], change) }
        }
    }

    /// Selects a shot and shows it resting on the stage.
    public func select(_ s: Selection, show: Bool = true) {
        selection = s
        if tab == .voice { tab = .shot }
        guard show else { return }
        switch s {
        case .shot(let id):
            if let beat = choreography.beats.first(where: { !$0.isOverview && $0.shot.id == id }) {
                clock.playing = false
                clock.time = min(beat.land + min(0.4, beat.hold * 0.3), clock.duration)
                touch()
            }
        case .overview:
            break
        }
    }

    /// The slide the slide map shows: the selected shot's, or the one face up at `t`.
    public func mapPage(at t: Double) -> Int {
        if let s = selectedShot { return project.pageIndex(s.page) }
        return choreography.page(at: t)
    }

    /// A new framing at the playhead, or after the last shot: by default a
    /// closer look at the middle of what the camera sees now. Drawn on
    /// another slide's map (`page`), it goes after that slide's last shot.
    public func addShot(frame: ShotFrame? = nil, at time: Double? = nil, page: Int? = nil) {
        let p = project
        var t = time ?? clock.time
        let start = p.tourStart + 0.6
        // On the slide face up at the playhead, unless drawn on another.
        let k = page ?? choreography.page(at: time ?? clock.time)
        if k != choreography.page(at: t) {
            let mine = p.shots.filter { p.pageIndex($0.page) == k }.map(\.time)
            let arrives = choreography.changes.first { $0.to == k && !$0.back }.map { $0.end + 1.0 } ?? start
            t = (mine.max().map { $0 + 2.6 }) ?? arrives
        }
        let taken = p.shots.contains { abs($0.time - t) < 0.9 }
        if t < start || taken { t = max(start, (p.shots.map(\.time).max() ?? start - 2.6) + 2.6) }
        var f: ShotFrame
        if let frame {
            f = frame
        } else {
            f = choreography.pose(at: clock.time).frame(slideAspect: p.slide(k).aspect, canvasAspect: p.canvasAspect)
            f.size *= 0.5
        }
        f.center = Vec2(min(max(f.center.x, 0), 1), min(max(f.center.y, 0), 1))
        let yaw = clamp((f.center.x - 0.5) * 22, -12, 12)
        let pitch = clamp((0.5 - f.center.y) * 12, -7, 7)
        var shot = Shot(time: t, frame: f, yaw: yaw, pitch: pitch, lens: 28, aperture: 0.45, label: nil)
        shot.page = p.pageID(k)
        update("Add Shot") { $0.shots.append(shot) }
        select(.shot(shot.id))
    }

    public func deleteSelectedShot() {
        guard case .shot(let id) = selection else { return }
        let after = selectedShot?.time ?? 0
        let next = orderedShots.first(where: { $0.time > after && $0.id != id })
        update("Delete Shot") { $0.shots.removeAll { $0.id == id } }
        selection = next.map { .shot($0.id) } ?? .overview
    }

    public func duplicateSelectedShot() {
        guard var shot = selectedShot else { return }
        shot.id = UUID()
        shot.time += 2
        shot.frame.size *= 0.7
        let s = shot
        update("Duplicate Shot") { $0.shots.append(s) }
        select(.shot(s.id))
    }

    /// Moves the playhead to the previous or next landing.
    public func jump(_ direction: Int) {
        let lands = choreography.beats.map(\.land).sorted()
        let t = clock.time
        let target = direction < 0 ? lands.last(where: { $0 < t - 0.05 }) : lands.first(where: { $0 > t + 0.05 })
        clock.playing = false
        clock.time = target ?? (direction < 0 ? 0 : clock.duration)
        if let beat = choreography.beats.first(where: { abs($0.land - clock.time) < 1e-6 }) {
            selection = beat.isOverview ? .overview : .shot(beat.shot.id)
        }
        touch()
    }

    /// A new canvas. The framings Direct for Me planned are framed again
    /// for it; the ones you set stay as they are.
    public func setFormat(_ f: CanvasFormat) {
        update("Canvas") { p in
            let (A, C) = (p.slideAspect, p.canvasAspect)
            p.format = f
            p.adaptOverview(fromSlideAspect: A, canvasAspect: C)
            p.reframePlanned()
        }
    }

    // MARK: Voiceover

    public static let voiceTypes: [UTType] = VoiceLoader.types

    public var voiceRecording: AudioTrack? { voiceTrack }

    public func importVoice(_ url: URL) {
        let store = document.media
        let job = begin("Reading the recording")
        let name = url.deletingPathExtension().lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        let file: String
        do {
            file = try store.importFile(url)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            end(job)
            message = "Couldn't copy the recording: \(error.localizedDescription)"
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try VoiceLoader.decode(store.url(for: file)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.end(job)
                    switch result {
                    case .success(let track):
                        self.voiceTrack = track
                        self.voiceFile = file
                        self.waveform = Waveform(track)
                        self.update("Add Voiceover") { p in
                            p.voice = Voiceover(file: file, name: name, offset: 0.5, duration: track.duration)
                        }
                        self.tab = .voice
                        self.transcribe()
                    case .failure(let error):
                        self.message = "Couldn't read the recording: \(readable(error))"
                    }
                }
            }
        }
    }

    func loadVoice() {
        guard let v = project.voice else {
            voiceTrack = nil
            voiceFile = nil
            waveform = nil
            player.stop()
            return
        }
        guard voiceFile != v.file else { return }
        let url = document.media.url(for: v.file)
        let file = v.file
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let track = try? VoiceLoader.decode(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.project.voice?.file == file, let track else { return }
                    self.voiceTrack = track
                    self.voiceFile = file
                    self.waveform = Waveform(track)
                    self.touch()
                }
            }
        }
    }

    public func removeVoice() {
        update("Remove Voiceover") { $0.voice = nil }
    }

    /// Listens to the voiceover for its words, on this Mac, then cuts the moves to them.
    public func transcribe() {
        guard let v = project.voice else { return }
        let url = document.media.url(for: v.file)
        let file = v.file
        let job = begin("Listening to the voiceover")
        Task { [weak self] in
            do {
                let words = try await Transcriber.words(in: url)
                guard let self else { return }
                self.end(job)
                guard let current = self.project.voice, current.file == file else { return }
                let offset = current.offset
                self.update("Transcribe") { p in
                    p.voice?.words = words.map {
                        SpokenWord(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence)
                    }
                    p.voice?.language = Locale.current.identifier
                }
                self.cutToVoice()
            } catch {
                self?.end(job)
                self?.message = readable(error)
            }
        }
    }

    /// Moves the recording along the video; its words move with it.
    public func setVoiceOffset(_ offset: Double, live isLive: Bool) {
        let change: (inout OOOProject) -> Void = { p in
            guard var voice = p.voice else { return }
            let d = offset - voice.offset
            voice.offset = offset
            voice.words = voice.words?.map {
                SpokenWord(text: $0.text, start: $0.start + d, end: $0.end + d, confidence: $0.confidence)
            }
            p.voice = voice
        }
        if isLive { live(change) } else { update("Move Voiceover", change) }
    }

    struct VoiceKey: Hashable {
        var file: String
        var offset: Double
        var gain: Float
        var duration: Double
    }

    private var voiceKey: VoiceKey? {
        guard let v = project.voice else { return nil }
        return VoiceKey(file: v.file, offset: v.offset, gain: v.gain, duration: choreography.duration)
    }

    /// The voice as it sits under the video.
    private func placedVoice(_ key: VoiceKey) -> AudioTrack? {
        if let c = placedCache, c.key == key { return c.track }
        guard let raw = voiceTrack, voiceFile == key.file else { return nil }
        let track = VoiceLoader.placed(raw, offset: key.offset, gain: key.gain, duration: key.duration)
        placedCache = (key, track)
        return track
    }

    /// Keeps the voice in step with playback. While it plays, its position is
    /// the clock, so the picture follows the voice and the two never drift.
    public func soundClock(playing: Bool, time: Double) -> Double? {
        guard playing, !showExport, var key = voiceKey, voiceTrack != nil else {
            if player.isPlaying { player.stop() }
            lastSoundTime = nil
            return nil
        }
        // While a slider moves, keep playing what is there; re-place the voice
        // once the change has held still for a moment.
        if let cached = placedCache, cached.key != key, player.isPlaying {
            let now = CACurrentMediaTime()
            if pendingVoice?.key != key { pendingVoice = (key, now) }
            if now - (pendingVoice?.since ?? now) < 0.25 { key = cached.key }
        }
        guard let track = placedVoice(key) else { return nil }
        let moved = lastSoundTime.map { abs(time - $0) > 0.06 } ?? true
        if !player.isPlaying || player.signature != key.hashValue || moved {
            player.play(track, signature: key.hashValue, from: time)
        }
        var t = player.position() ?? time
        if t >= clock.duration - 1e-3 {
            t = 0
            player.stop()
        }
        lastSoundTime = t
        return t
    }
}

/// Plays the voice beside the live stage.
@MainActor
final class VoicePlayer {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private(set) var signature: Int?
    private var startTime: Double = 0

    var isPlaying: Bool { node?.isPlaying ?? false }

    /// Plays `track` (already placed on the video's timeline) from `time`.
    func play(_ track: AudioTrack, signature: Int, from time: Double) {
        if engine == nil {
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(AudioTrack.sampleRate), channels: 2) else { return }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.node = node
            self.format = format
        }
        guard let engine, let node, let format else { return }
        node.stop()
        let start = max(0, min(track.frames, Int((time * Double(AudioTrack.sampleRate)).rounded())))
        let count = track.frames - start
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let left = channels[0], right = channels[1]
        track.samples.withUnsafeBufferPointer { s in
            for i in 0..<count {
                left[i] = s[2 * (start + i)]
                right[i] = s[2 * (start + i) + 1]
            }
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        node.scheduleBuffer(buffer, at: nil, options: [])
        node.play()
        self.signature = signature
        startTime = time
    }

    /// Where on the video's timeline the voice now playing is.
    func position() -> Double? {
        guard let node, node.isPlaying, let last = node.lastRenderTime,
              let t = node.playerTime(forNodeTime: last), t.sampleRate > 0 else { return nil }
        return startTime + Double(t.sampleTime) / t.sampleRate
    }

    func stop() {
        node?.stop()
        signature = nil
    }
}

/// An error as a sentence for people: the renderer's own message or the
/// system's description, never a type name and a code.
func readable(_ error: Error) -> String {
    if let e = error as? RenderError { return e.description }
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return (error as NSError).localizedDescription
}
