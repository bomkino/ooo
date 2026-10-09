import AppKit
import OOOCore
import RenderCore
import SwiftUI
import UniformTypeIdentifiers

// Adapted from pitch.dog Studio (StudioKit/ExportSheet.swift in
// bomkino/pitchdog-drift), AGPL-3.0. See NOTICES.md.

@Observable
@MainActor
final class ExportModel {
    enum Phase { case settings, running, done(URL), failed(String) }
    var phase: Phase = .settings
    var progress: Double = 0
    var frame = 0
    var total = 0
    var preview: CGImage?
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
}

/// Writes the video: frame-exact, with motion blur, sharp detail at every
/// zoom, and the voiceover under it.
struct ExportSheet: View {
    let session: OOOSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.codec") private var codec: VideoCodec = .h264
    @AppStorage("export.scale") private var scale: Double = 1
    @AppStorage("export.quality") private var quality: ExportQuality = .good
    @AppStorage("export.voice") private var includeVoice = true
    /// You on camera from a live take: in the room, or as your own file beside the video.
    @AppStorage("export.face") private var faceInRoom = true
    @State private var model = ExportModel()

    private var summary: String {
        let p = session.project
        let (w, h) = OOOExporter.size(p.format, scale: scale)
        var s = "\(w) × \(h) · \(p.fps) fps · \(secondsLabel(session.choreography.duration))"
        if p.voice != nil { s += includeVoice ? " · with voiceover" : " · silent" }
        if p.face != nil { s += faceInRoom ? " · you in the room" : " · you as your own file" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .settings: settings
            case .running: running
            case .done(let url): done(url)
            case .failed(let message): failed(message)
            }
        }
        .frame(width: 520)
        .background(Theme.chrome)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Video").textStyle(.title)
                Text(summary).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("File").textStyle(.bodyCompact).foregroundStyle(.secondary)
                    ChoiceRow([(VideoCodec.h264, "MP4"), (.hevc, "HEVC"), (.prores422, "ProRes")], selection: $codec)
                }
                GridRow {
                    Text("Size").textStyle(.bodyCompact).foregroundStyle(.secondary)
                    ChoiceRow([(0.5, "Half"), (1.0, "Full"), (2.0, "Double")], selection: $scale)
                }
                GridRow {
                    Text("Frame rate").textStyle(.bodyCompact).foregroundStyle(.secondary)
                    ChoiceRow([(24, "24"), (30, "30"), (60, "60")], selection: session.choice(\.fps, "Frame Rate"))
                }
                GridRow {
                    Text("Motion").textStyle(.bodyCompact).foregroundStyle(.secondary)
                    ChoiceRow(ExportQuality.allCases.map { ($0, $0.title) }, selection: $quality)
                }
                if session.project.voice != nil {
                    GridRow {
                        Text("Sound").textStyle(.bodyCompact).foregroundStyle(.secondary)
                        ChoiceRow([(true, "Voiceover"), (false, "Silent")], selection: $includeVoice)
                    }
                }
                if session.project.face != nil {
                    GridRow {
                        Text("You").textStyle(.bodyCompact).foregroundStyle(.secondary)
                        ChoiceRow([(true, "In the Room"), (false, "Own File")], selection: $faceInRoom)
                            .help("Own File leaves the room empty and saves the camera recording beside the video, for an editor such as Premiere or Edits")
                    }
                }
            }
            Text("\(codec.detail). \(quality.detail)").textStyle(.caption).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Export…") { chooseDestination() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!session.hasSlide)
            }
        }
        .padding(20)
    }

    // MARK: Running

    private var running: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exporting").textStyle(.title)
            ZStack {
                Theme.surround
                if let img = model.preview {
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

    private func done(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill").foregroundStyle(Theme.camera).font(.system(size: 16))
                Text("Exported").textStyle(.title)
            }
            Text(url.lastPathComponent).textStyle(.mono).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(QuietButtonStyle())
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
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

    private func chooseDestination() {
        let panel = NSSavePanel()
        let name = session.project.slide.kind == .sample ? "OOO" : "OOO " + session.project.slide.name
        panel.nameFieldStringValue = name + "." + codec.fileExtension
        panel.allowedContentTypes = [codec.fileExtension == "mov" ? .quickTimeMovie : .mpeg4Movie]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { run(to: url) }
        }
    }

    private func run(to url: URL) {
        guard var shown = session.exportScene() else { return }
        // As your own file: the room stays empty, and the recording goes beside the video.
        let face = !faceInRoom ? session.project.face.map { session.document.media.url(for: $0.file) } : nil
        if face != nil { shown.faceURL = nil }
        let scene = shown
        let voice = includeVoice ? session.voiceRecording : nil
        let options = ExportOptions(codec: codec, quality: quality, scale: scale, includeVoice: includeVoice)
        model.cancelFlag = ExportModel.CancelFlag()
        model.progress = 0
        model.frame = 0
        model.total = max(1, Int((scene.duration * Double(scene.project.fps)).rounded()))
        model.started = Date()
        model.phase = .running
        let flag = model.cancelFlag
        let model = self.model
        Task.detached(priority: .userInitiated) {
            do {
                // Its own renderer, so the export never shares scratch space with the live stage.
                let exporter = try OOOExporter()
                try await exporter.export(scene, voice: voice, options: options, to: url, isCancelled: { flag.isSet },
                                          progress: { p in
                                              Task { @MainActor in
                                                  model.frame = p.frame
                                                  model.total = p.total
                                                  model.progress = p.fraction
                                              }
                                          },
                                          preview: { img in
                                              Task { @MainActor in model.preview = img }
                                          })
                if let face {
                    let name = url.deletingPathExtension().lastPathComponent + " – you"
                    let you = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(face.pathExtension)
                    try? FileManager.default.removeItem(at: you)
                    try FileManager.default.copyItem(at: face, to: you)
                }
                await MainActor.run { model.phase = .done(url) }
            } catch RenderError.cancelled {
                // The file that was there is untouched: nothing replaces it until a video is whole.
                await MainActor.run { model.phase = .settings }
            } catch {
                await MainActor.run { model.phase = .failed(readable(error)) }
            }
        }
    }
}
