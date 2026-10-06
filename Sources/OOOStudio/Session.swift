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
    public init() {}
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
    /// What OOO is busy with, in words.
    public private(set) var busy: String?
    /// The slide drawn small, for the map and the timeline.
    public private(set) var slidePreview: CGImage?
    /// The voiceover's peaks, recording time.
    public private(set) var waveform: Waveform?
    /// Pages in the slide's PDF, when it has more than one.
    public private(set) var pageCount = 1

    @ObservationIgnored private var slideBase: SlideBase?
    @ObservationIgnored private var slideToken = 0
    @ObservationIgnored private var sceneCache: SlideScene?
    /// The last reading of a slide, and which slide it was.
    @ObservationIgnored private var details: (ref: SlideRef, found: [SlideDetail])?
    /// A dropped slide whose tour is still being planned: the drop and its
    /// tour become one undo step when the plan lands.
    @ObservationIgnored private var pendingDrop: (before: OOOProject, name: String)?
    @ObservationIgnored private var voiceTrack: AudioTrack?
    @ObservationIgnored private var voiceFile: String?
    @ObservationIgnored private var placedCache: (key: VoiceKey, track: AudioTrack)?
    @ObservationIgnored private var pendingVoice: (key: VoiceKey, since: Double)?
    @ObservationIgnored private let player = VoicePlayer()
    @ObservationIgnored private var lastSoundTime: Double?
    @ObservationIgnored private var thumbs: [ShotFrame: CGImage] = [:]
    @ObservationIgnored private var pendingEditStart: OOOProject?
    @ObservationIgnored private var pendingEditName: String?

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
        loadVoice()
    }

    // MARK: Editing with undo

    /// Applies a change as one undoable step. A gesture still open is closed first.
    public func update(_ actionName: String, _ change: (inout OOOProject) -> Void) {
        finishDrop()
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
        if pendingEditStart != nil, pendingEditName != name { commitEdit(pendingEditName ?? "Edit") }
        if pendingEditStart == nil {
            pendingEditStart = project
            pendingEditName = name
        }
    }

    /// A change during a gesture: no undo step until it commits.
    public func live(_ change: (inout OOOProject) -> Void) {
        var p = project
        change(&p)
        guard p != project else { return }
        set(p)
    }

    public func commitEdit(_ actionName: String) {
        guard let start = pendingEditStart else { return }
        pendingEditStart = nil
        pendingEditName = nil
        if start != project { registerUndo(from: start, name: actionName) }
    }

    /// Closes a drop as one undo step: the slide, and its tour if it has one by now.
    private func finishDrop() {
        guard let drop = pendingDrop else { return }
        pendingDrop = nil
        if drop.before != project { registerUndo(from: drop.before, name: drop.name) }
    }

    /// A new slide (or page) and its tour, undone together.
    private func drop(_ name: String, _ change: (inout OOOProject) -> Void) {
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
        if slideChanged || p.format != project.format { thumbs = [:] }
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
        let s = SlideScene(project: project, base: b.texture, details: b.details, choreography: choreography)
        sceneCache = s
        return s
    }

    /// A scene with its own detail cache, so an export never fights the live stage.
    public func exportScene() -> SlideScene? {
        guard let b = slideBase else { return nil }
        return SlideScene(project: project, base: b.texture, details: DetailCache(source: b.source, baseDensity: b.density),
                          choreography: choreography)
    }

    public var hasSlide: Bool { slideBase != nil }

    func loadSlide() {
        let ref = project.slide
        if let b = slideBase, b.ref == ref { return }
        let media = document.media.directory
        slideToken += 1
        let token = slideToken
        busy = "Drawing the slide"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SlideBase(ref: ref, media: media) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.slideToken else { return }
                    self.busy = nil
                    switch result {
                    case .success(let base): self.install(base)
                    case .failure(let error): self.message = "\(error)"
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
            p.adaptOverview(fromSlideAspect: A, canvasAspect: C)
        }
        selection = .overview
        clock.time = 0
        clock.playing = true
        autoDirect()
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
            p.adaptOverview(fromSlideAspect: A, canvasAspect: C)
        }
        selection = .overview
        clock.time = 0
        autoDirect()
    }

    /// The part of the slide a framing shows, cut from the preview, for the timeline.
    public func thumbnail(_ frame: ShotFrame) -> CGImage? {
        if let t = thumbs[frame] { return t }
        guard let img = slidePreview else { return nil }
        let v = frame.visible(slideAspect: project.slideAspect, canvasAspect: project.canvasAspect)
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let rect = CGRect(x: CGFloat(v.minU) * W, y: CGFloat(v.minV) * H, width: CGFloat(v.size.x) * W, height: CGFloat(v.size.y) * H)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let crop = img.cropping(to: rect) else { return nil }
        if thumbs.count > 240 { thumbs.removeAll() }
        thumbs[frame] = crop
        return crop
    }

    // MARK: Directing

    /// Reads the slide and plans a tour of it: the headline, the details worth
    /// stopping on in reading order, the small print last, cut to the voice if
    /// there is one.
    public func autoDirect() {
        let ref = project.slide
        let media = document.media.directory
        // Only this slide's own reading will do: a new slide or page is read afresh.
        let cached = details?.ref == ref ? details?.found : nil
        busy = "Reading the slide"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> [SlideDetail] in
                if let cached { return cached }
                return try SlideAnalysis.read(SlideSource(ref: ref, media: media))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.project.slide == ref else { return }
                    self.busy = nil
                    switch result {
                    case .success(let found):
                        self.details = (ref, found)
                        let shots = Director.shots(self.project.directorInput(found))
                        guard !shots.isEmpty else {
                            self.finishDrop()
                            self.message = "OOO found nothing to read on this slide. Draw framings on the slide map to choose what the camera visits."
                            return
                        }
                        if self.pendingDrop != nil {
                            var p = self.project
                            p.shots = shots
                            self.set(p)
                            self.finishDrop()
                        } else {
                            self.update("Direct") { $0.shots = shots }
                        }
                        self.selection = .overview
                        self.clock.time = 0
                        self.clock.playing = true
                    case .failure(let error):
                        self.finishDrop()
                        self.message = "Couldn't read the slide: \(error)"
                    }
                }
            }
        }
    }

    /// Keeps every framing and lands each one just before the voice says its words.
    public func cutToVoice() {
        guard let words = project.voice?.words, !words.isEmpty else { return }
        update("Cut to Voice") { p in
            p.shots = Director.retime(p.shots, words: words, start: p.arrive.end)
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
            if let i = p.shots.firstIndex(where: { $0.id == id }) { change(&p.shots[i]) }
        }
    }

    public func liveShot(_ id: UUID, _ change: (inout Shot) -> Void) {
        live { p in
            if let i = p.shots.firstIndex(where: { $0.id == id }) { change(&p.shots[i]) }
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

    /// A new framing at the playhead, or after the last shot: by default a
    /// closer look at the middle of what the camera sees now.
    public func addShot(frame: ShotFrame? = nil, at time: Double? = nil) {
        let p = project
        var t = time ?? clock.time
        let start = p.arrive.end + 0.6
        let taken = p.shots.contains { abs($0.time - t) < 0.9 }
        if t < start || taken { t = max(start, (p.shots.map(\.time).max() ?? start - 2.6) + 2.6) }
        var f: ShotFrame
        if let frame {
            f = frame
        } else {
            f = choreography.pose(at: clock.time).frame(slideAspect: p.slideAspect, canvasAspect: p.canvasAspect)
            f.size *= 0.5
        }
        f.center = Vec2(min(max(f.center.x, 0), 1), min(max(f.center.y, 0), 1))
        let yaw = clamp((f.center.x - 0.5) * 22, -12, 12)
        let pitch = clamp((0.5 - f.center.y) * 12, -7, 7)
        let shot = Shot(time: t, frame: f, yaw: yaw, pitch: pitch, lens: 28, aperture: 0.45, label: "Shot \(p.shots.count + 1)")
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

    public func setFormat(_ f: CanvasFormat) {
        update("Canvas") { p in
            let (A, C) = (p.slideAspect, p.canvasAspect)
            p.format = f
            p.adaptOverview(fromSlideAspect: A, canvasAspect: C)
        }
    }

    // MARK: Voiceover

    public static let voiceTypes: [UTType] = VoiceLoader.types

    public var voiceRecording: AudioTrack? { voiceTrack }

    public func importVoice(_ url: URL) {
        let store = document.media
        busy = "Reading the recording"
        let name = url.deletingPathExtension().lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        let file: String
        do {
            file = try store.importFile(url)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            busy = nil
            message = "Couldn't copy the recording: \(error.localizedDescription)"
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try VoiceLoader.decode(store.url(for: file)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = nil
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
                        self.message = "Couldn't read the recording: \(error)"
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
        busy = "Listening to the voiceover"
        Task { [weak self] in
            do {
                let words = try await Transcriber.words(in: url)
                guard let self else { return }
                self.busy = nil
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
                self?.busy = nil
                self?.message = "\(error)"
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
