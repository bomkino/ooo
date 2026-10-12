import AppKit
import OOOCore
import OOOMotion
import RenderCore
import SwiftUI
import UniformTypeIdentifiers

// Adapted from pitch.dog Studio (StudioKit/ExportSheet.swift in
// bomkino/pitchdog-drift), AGPL-3.0. See NOTICES.md.

@Observable
@MainActor
final class ExportModel {
    enum Phase { case settings, running, done([URL]), failed(String) }
    var phase: Phase = .settings
    /// Of the whole export, every size together.
    var progress: Double = 0
    var frame = 0
    var total = 0
    /// Which size is being written, of how many, and its name.
    var part = 0
    var parts = 1
    var partName = ""
    var preview: CGImage?
    /// The video's opening, small: on the sheet, and on the done card.
    var poster: CGImage?
    var started = Date()
    @ObservationIgnored var cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    var remaining: String {
        guard progress > 0.02 else { return "Estimating…" }
        let elapsed = Date().timeIntervalSince(started)
        let left = elapsed / progress - elapsed
        if left < 60 { return "About \(max(1, Int(left))) s left" }
        return "About \(Int(left / 60)) min left"
    }

    /// Seconds per megapixel of frame, as this Mac last exported at `quality`.
    nonisolated static func rate(_ quality: ExportQuality) -> Double {
        UserDefaults.standard.double(forKey: "export.rate.\(quality.rawValue)")
    }

    nonisolated static func remember(rate: Double, _ quality: ExportQuality) {
        guard rate.isFinite, rate > 0 else { return }
        let old = Self.rate(quality)
        // Settles over a few exports, so one odd one doesn't swing it.
        UserDefaults.standard.set(old > 0 ? old * 0.5 + rate * 0.5 : rate, forKey: "export.rate.\(quality.rawValue)")
    }
}

/// Writes the video: frame-exact, with motion blur, sharp detail at every
/// zoom, and the voiceover under it. In one size or several at once, each
/// framed again for its shape.
struct ExportSheet: View {
    let session: OOOSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.codec") private var codec: VideoCodec = .h264
    @AppStorage("export.scale") private var scale: Double = 1
    @AppStorage("export.quality") private var quality: ExportQuality = .good
    @AppStorage("export.voice") private var includeVoice = true
    /// You on camera from a live take: in the room, or as your own file beside the video.
    @AppStorage("export.face") private var faceInRoom = true
    /// The sizes to write, by format id; the video's own is always first.
    @State private var sizes: Set<String> = []
    @State private var model = ExportModel()

    private var project: OOOProject { session.project }

    /// The shapes on offer: the video's own, then the usual posts.
    private var sizeOptions: [CanvasFormat] {
        var list: [CanvasFormat] = [.reel, .portrait, .square, .landscape]
        if !list.contains(where: { $0.id == project.format.id }) { list.insert(project.format, at: 0) }
        return list
    }

    /// What will be written, the video's own size first.
    private var chosen: [CanvasFormat] {
        let picked = sizeOptions.filter { sizes.contains($0.id) && $0.id != project.format.id }
        return [project.format] + picked
    }

    private var summary: String {
        let (w, h) = OOOExporter.size(project.format, scale: scale)
        var s = chosen.count > 1 ? "\(chosen.count) sizes" : "\(w) × \(h)"
        s += " · \(project.fps) fps · \(secondsLabel(session.choreography.duration))"
        if project.voice != nil { s += includeVoice ? " · with your voice" : " · silent" }
        if project.face != nil { s += faceInRoom ? " · you in the room" : " · you as your own file" }
        if project.showsCaptions { s += " · captions" }
        return s
    }

    /// How long it should take, from how fast this Mac exported before.
    private var estimate: String? {
        let rate = ExportModel.rate(quality)
        guard rate > 0 else { return nil }
        let frames = session.choreography.duration * Double(project.fps)
        let megapixels = chosen.reduce(0.0) { sum, f in
            let (w, h) = OOOExporter.size(f, scale: scale)
            return sum + Double(w * h) / 1e6
        }
        let t = rate * frames * megapixels
        if t < 60 { return "about \(max(5, Int((t / 5).rounded()) * 5)) s" }
        return "about \(Int((t / 60).rounded())) min"
    }

    /// Why Export waits, if it does.
    private var waiting: String? {
        if let n = session.notReady { return n }
        if session.listening && includeVoice {
            return "Still listening to your voice. Export opens up once OOO has heard it, so the timing and captions come with it."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .settings: settings
            case .running: running
            case .done(let urls): done(urls)
            case .failed(let message): failed(message)
            }
        }
        .frame(width: 560)
        .background(Theme.chrome)
        .onAppear {
            if sizes.isEmpty { sizes = [project.format.id] }
            drawPoster()
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export Video").textStyle(.title)
                    Text(summary).textStyle(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Poster(image: model.poster, aspect: CGFloat(project.format.aspect), box: 92)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Sizes").textStyle(.bodyCompact).foregroundStyle(.secondary)
                    SizeChips(options: sizeOptions, own: project.format, chosen: $sizes)
                }
                GridRow {
                    Text("File").textStyle(.bodyCompact).foregroundStyle(.secondary)
                    ChoiceRow([(VideoCodec.h264, "MP4"), (.hevc, "Smaller MP4"), (.prores422, "ProRes")], selection: $codec)
                }
                GridRow {
                    Text("Resolution").textStyle(.bodyCompact).foregroundStyle(.secondary)
                    ChoiceRow([0.5, 1.0, 2.0].map { ($0, resolutionLabel($0)) }, selection: $scale)
                }
                GridRow {
                    Text("Frame rate").textStyle(.bodyCompact).foregroundStyle(.secondary)
                    ChoiceRow([(24, "24"), (30, "30"), (60, "60")], selection: session.choice(\.fps, "Frame Rate"))
                }
                GridRow {
                    Text("Motion").textStyle(.bodyCompact).foregroundStyle(.secondary)
                    ChoiceRow(ExportQuality.allCases.map { ($0, $0.title) }, selection: $quality)
                }
                if project.voice != nil {
                    GridRow {
                        Text("Sound").textStyle(.bodyCompact).foregroundStyle(.secondary)
                        ChoiceRow([(true, "Your Voice"), (false, "Silent")], selection: $includeVoice)
                    }
                }
                if !(project.voice?.words?.isEmpty ?? true) {
                    GridRow {
                        Text("Captions").textStyle(.bodyCompact).foregroundStyle(.secondary)
                        ChoiceRow([(true, "On"), (false, "Off")],
                                  selection: Binding(get: { session.project.showsCaptions }, set: { session.setCaptions($0) }))
                            .help("Your words on screen as you say them, for everyone watching without sound")
                    }
                }
                if project.face != nil {
                    GridRow {
                        Text("You").textStyle(.bodyCompact).foregroundStyle(.secondary)
                        ChoiceRow([(true, "In the Room"), (false, "Own File")], selection: $faceInRoom)
                            .help("Own File leaves the room empty and saves the camera recording beside the video, for an editor such as Premiere or Edits")
                    }
                }
            }
            Text(waiting ?? footnote).textStyle(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Export \(chosen.count) Videos…" : "Export…") { chooseDestination() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(waiting != nil)
            }
        }
        .padding(20)
    }

    private var footnote: String {
        var s = chosen.count > 1 ? "Each size is framed again for its shape. " : ""
        s += "\(codec.detail). \(quality.detail)"
        if let estimate { s += " Takes \(estimate) on this Mac." }
        return s
    }

    private func resolutionLabel(_ scale: Double) -> String {
        if chosen.count == 1 {
            let (w, h) = OOOExporter.size(project.format, scale: scale)
            return "\(w) × \(h)"
        }
        switch scale {
        case 0.5: return "Half"
        case 2: return "Double"
        default: return "Full"
        }
    }

    // MARK: Running

    private var running: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Exporting").textStyle(.title)
                if model.parts > 1 {
                    Text("\(model.partName) · \(model.part + 1) of \(model.parts)").textStyle(.data).foregroundStyle(.secondary)
                }
            }
            ZStack {
                Theme.surround
                if let img = model.preview ?? model.poster {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            ProgressView(value: model.progress).tint(Theme.camera)
            HStack {
                Text("Frame \(model.frame) of \(model.total)").textStyle(.data).foregroundStyle(.secondary)
                Spacer()
                Text(model.remaining).textStyle(.data).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelFlag.set() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    private func done(_ urls: [URL]) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Poster(image: model.poster, aspect: CGFloat(project.format.aspect), box: 132)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill").foregroundStyle(Theme.camera).font(.system(size: 16))
                    Text(urls.count > 1 ? "\(urls.count) videos exported" : "Exported").textStyle(.title)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(urls, id: \.self) { url in
                        Text(url.lastPathComponent).textStyle(.mono).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text("AirDrop it to your phone and post it, or send it on.").textStyle(.caption).foregroundStyle(.secondary)
                Button {
                    let t = Self.restingOpening(session.choreography)
                    dismiss()
                    OOOCommands.saveCoverFrame(session, at: t)
                } label: {
                    Label("Save a Cover Picture…", systemImage: "photo")
                }
                .buttonStyle(QuietButtonStyle())
                .help("The opening at rest, full size, for the post's cover")
                Spacer(minLength: 0)
                HStack {
                    ShareLink(items: urls) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }.buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minHeight: 150)
        .padding(20)
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export stopped").textStyle(.title)
            Text(message).textStyle(.body).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Back") { model.phase = .settings }.buttonStyle(QuietButtonStyle())
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20)
    }

    // MARK: Run

    /// The video's opening at rest, small, drawn once as the sheet opens.
    private func drawPoster() {
        guard model.poster == nil, let scene = session.exportScene() else { return }
        let f = project.format
        let fit = 2 * 132 / Double(max(f.width, f.height))
        let w = max(2, Int(Double(f.width) * fit)), h = max(2, Int(Double(f.height) * fit))
        let t = Self.restingOpening(scene.choreography)
        let model = self.model
        Task.detached(priority: .userInitiated) {
            guard let stage = try? SlideStage(), let image = try? stage.still(scene, at: t, width: w, height: h, samples: 4) else { return }
            await MainActor.run { model.poster = image }
        }
    }

    /// The moment the opening has landed: the slide whole, at rest.
    nonisolated static func restingOpening(_ c: Choreography) -> Double {
        guard let first = c.beats.first else { return 0 }
        return min(first.land + 0.2, max(first.leave - 0.05, first.land))
    }

    /// The name a file starts from: the title's words, else the slide's name, else the sample's.
    private var baseName: String {
        let clean: (String) -> String = { s in
            String(s.map { "/:\\".contains($0) ? "-" : $0 }.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let title = project.title.map({ clean($0.text) }), !title.isEmpty { return title }
        let name = clean(project.slide.name)
        return project.slide.kind == .sample || name.isEmpty ? "Obsess Over One" : name
    }

    /// The folder the last export went to, or Movies.
    private static var startFolder: URL? {
        if let path = UserDefaults.standard.string(forKey: "export.folder"),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
    }

    /// `name 9x16.mp4` beside `stem`, or `name 9x16 2.mp4` when that is taken.
    nonisolated static func sizedName(_ folder: URL, _ stem: String, _ f: CanvasFormat, ext: String) -> URL {
        let tag = f.ratioLabel.replacingOccurrences(of: ":", with: "x")
        var url = folder.appendingPathComponent("\(stem) \(tag)").appendingPathExtension(ext)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent("\(stem) \(tag) \(n)").appendingPathExtension(ext)
        }
        return url
    }

    /// Where your own recording goes beside `video`: "Name – you", or, when
    /// that is taken and not being replaced, "Name – you 2" and on.
    nonisolated static func besideName(for video: URL, ext: String, replacing: Bool) -> URL {
        let folder = video.deletingLastPathComponent(), stem = video.deletingPathExtension().lastPathComponent + " – you"
        let first = folder.appendingPathComponent(stem).appendingPathExtension(ext)
        guard !replacing else { return first }
        var n = 1, url = first
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
        }
        return url
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        let several = chosen.count > 1
        panel.nameFieldStringValue = several ? baseName : baseName + "." + codec.fileExtension
        if several {
            let tags = chosen.map { "\(baseName) \($0.ratioLabel.replacingOccurrences(of: ":", with: "x")).\(codec.fileExtension)" }
            panel.message = "One file for each size: " + tags.joined(separator: ", ")
            panel.prompt = "Export"
        } else {
            panel.allowedContentTypes = [codec.fileExtension == "mov" ? .quickTimeMovie : .mpeg4Movie]
        }
        panel.directoryURL = Self.startFolder
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "export.folder")
                if several {
                    let folder = url.deletingLastPathComponent()
                    let stem = url.deletingPathExtension().lastPathComponent
                    run(chosen.map { ($0, Self.sizedName(folder, stem, $0, ext: codec.fileExtension)) })
                } else {
                    run([(project.format, url)])
                }
            }
        }
    }

    private func run(_ files: [(format: CanvasFormat, url: URL)]) {
        let scenes = files.map { session.exportScene(format: $0.format) }
        guard !files.isEmpty, scenes.allSatisfy({ $0 != nil }) else { session.message = session.notReady; return }
        // As your own file: the room stays empty, and the recording goes beside the first video.
        let face = !faceInRoom ? project.face.map { session.document.media.url(for: $0.file) } : nil
        let jobs: [(scene: SlideScene, url: URL, name: String)] = zip(files, scenes).map { file, scene in
            var s = scene!
            if face != nil { s.faceURL = nil }
            return (s, file.url, "\(file.format.ratioLabel) \(file.format.name)")
        }
        let voice = includeVoice ? session.voiceRecording : nil
        // A voiceover still being read (just opened, just kept) is read for the export itself.
        let unread = includeVoice && voice == nil ? project.voice.map { session.document.media.url(for: $0.file) } : nil
        let options = ExportOptions(codec: codec, quality: quality, scale: scale, includeVoice: includeVoice)
        let quality = self.quality, scale = self.scale
        let exported = project
        model.cancelFlag = ExportModel.CancelFlag()
        model.progress = 0
        model.frame = 0
        model.part = 0
        model.parts = jobs.count
        model.partName = jobs[0].name
        model.total = max(1, Int((jobs[0].scene.duration * Double(jobs[0].scene.project.fps)).rounded()))
        model.started = Date()
        model.phase = .running
        let flag = model.cancelFlag
        let model = self.model
        let first = files[0].url
        // Your recording goes beside the video. It replaces one already there
        // only when you chose to replace the video it came with; otherwise it
        // takes a free name, so no file you didn't choose is lost.
        let you = face.map { Self.besideName(for: first, ext: $0.pathExtension, replacing: FileManager.default.fileExists(atPath: first.path)) }
        Task.detached(priority: .userInitiated) {
            var written: [URL] = []
            do {
                // Its own renderer, so the export never shares scratch space with the live stage.
                let exporter = try OOOExporter()
                let heard = try voice ?? unread.map { try VoiceLoader.decode($0) }
                for (k, job) in jobs.enumerated() {
                    let began = Date()
                    let parts = Double(jobs.count)
                    await MainActor.run {
                        model.part = k
                        model.partName = job.name
                        model.preview = nil
                    }
                    try await exporter.export(job.scene, voice: heard, options: options, to: job.url, isCancelled: { flag.isSet },
                                              progress: { p in
                                                  Task { @MainActor in
                                                      model.frame = p.frame
                                                      model.total = p.total
                                                      model.progress = (Double(k) + p.fraction) / parts
                                                  }
                                              },
                                              preview: { img in
                                                  Task { @MainActor in model.preview = img }
                                              })
                    written.append(job.url)
                    let (w, h) = OOOExporter.size(job.scene.project.format, scale: scale)
                    let frames = job.scene.duration * Double(job.scene.project.fps)
                    ExportModel.remember(rate: Date().timeIntervalSince(began) / max(frames * Double(w * h) / 1e6, 1e-6), quality)
                }
                if let face, let you {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: you.path) {
                        // Copied whole beside it first: if the copy fails, the one there stays.
                        let staged = you.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(you.pathExtension)")
                        defer { try? fm.removeItem(at: staged) }
                        try fm.copyItem(at: face, to: staged)
                        _ = try fm.replaceItemAt(you, withItemAt: staged)
                    } else {
                        try fm.copyItem(at: face, to: you)
                    }
                }
                let urls = written
                await MainActor.run {
                    model.phase = .done(urls)
                    session.lastExport = (urls, exported)
                }
            } catch RenderError.cancelled {
                // The file that was there is untouched: nothing replaces it until a video is whole.
                // Sizes already written stay, and are offered to share.
                let urls = written
                await MainActor.run {
                    if urls.isEmpty { model.phase = .settings } else {
                        model.phase = .done(urls)
                        session.lastExport = (urls, exported)
                    }
                }
            } catch {
                await MainActor.run { model.phase = .failed(readable(error)) }
            }
        }
    }
}

/// The sizes to export, any number of them, each with its shape drawn.
struct SizeChips: View {
    let options: [CanvasFormat]
    let own: CanvasFormat
    @Binding var chosen: Set<String>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.id) { f in
                let isOwn = f.id == own.id
                let on = isOwn || chosen.contains(f.id)
                Button {
                    if !isOwn { if on { chosen.remove(f.id) } else { chosen.insert(f.id) } }
                } label: {
                    HStack(spacing: 6) {
                        shape(f, on: on)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(f.ratioLabel).textStyle(.label).foregroundStyle(on ? Color.primary : Color.secondary)
                            Text(f.name).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Theme.segmentOn : Theme.well.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(on ? Theme.camera.opacity(0.7) : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOwn ? "The video's own size, \(f.width) × \(f.height)"
                            : "Also export it \(f.width) × \(f.height), for \(f.detail), framed again for that shape")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func shape(_ f: CanvasFormat, on: Bool) -> some View {
        let a = CGFloat(f.aspect)
        let w = a >= 1 ? 16 : 16 * a, h = a >= 1 ? 16 / a : 16
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .strokeBorder(on ? Theme.camera : Color.secondary, lineWidth: 1.5)
            .frame(width: w, height: h)
            .frame(width: 16, height: 16)
    }
}

/// A small picture of the video, in its shape, inside a square box.
struct Poster: View {
    let image: CGImage?
    let aspect: CGFloat
    let box: CGFloat

    var body: some View {
        let w = aspect >= 1 ? box : box * aspect, h = aspect >= 1 ? box / aspect : box
        ZStack {
            Theme.surround
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill).transition(.opacity) }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .frame(width: box, height: box)
        .animation(Theme.settle, value: image != nil)
        .accessibilityHidden(true)
    }
}
