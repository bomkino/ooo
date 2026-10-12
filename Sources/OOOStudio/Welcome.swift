import AppKit
import OOOCore
import OOOMotion
import SwiftUI
import UniformTypeIdentifiers

/// The first time OOO opens: what it is, in a breath, and the one thing to
/// do, while the sample shows it off. Once you bring a slide in, or say
/// you'd rather watch first, it never comes back.
struct Welcome: View {
    let session: OOOSession
    let dismiss: () -> Void
    @State private var shown = false
    @State private var canPaste = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Over the first window of the first launch, on the sample (and in a
    /// snapshot run that asks for it).
    @MainActor
    static func shows(welcomed: Bool, session: OOOSession) -> Bool {
        let asked = OOOSnapshot.isRequested ? OOOSnapshot.flag("--welcome") : !welcomed
        return asked && session.project.slide.kind == .sample && session.mode == .frame && !session.isTaking
    }

    var body: some View {
        GeometryReader { geo in
            let beside = session.mapBeside
            // Over the slide map where it has its own pane; under the video otherwise.
            let width = min(400, geo.size.width - 40)
            let x = beside ? max(width / 2 + 20, geo.size.width * 0.27) : geo.size.width / 2
            let y = beside ? geo.size.height * 0.5 : geo.size.height - 150
            card
                .frame(width: width)
                .position(x: x, y: y)
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 14)
        }
        .onAppear {
            canPaste = OOOSession.clipboardHasSlide
            // Once the sample has landed: the first thing anyone sees is OOO at work.
            let wait = OOOSnapshot.isRequested ? 0 : 2.4
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.86)) { shown = true }
            }
        }
        .onChange(of: session.project.slide.kind) { _, kind in if kind != .sample { dismiss() } }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Obsess Over One").foregroundStyle(Theme.camera)
                    Text("Every slide. Every detail.").foregroundStyle(.secondary)
                }
                .textStyle(.badge)
                Text("Your slide, made into a film.").textStyle(.display).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Drop in a slide and OOO films it: it arrives, the camera visits every detail worth seeing, and you post the video. This one's a sample.")
                    .textStyle(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                step(1, "doc.badge.plus", "Drop your slide")
                step(2, "waveform", "Talk over it")
                step(3, "square.and.arrow.up", "Export the \(session.project.format.name)")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Use Your Slide…") { OOOCommands.chooseSlide(session) }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .help("A PDF or a picture (⌘I)")
                    if canPaste {
                        Button("Paste Slide") { session.pasteSlide() }
                            .buttonStyle(QuietButtonStyle())
                            .help("The slide you copied (⇧⌘V)")
                    }
                    Spacer(minLength: 0)
                    Button("Watch the Sample First") { withAnimation(Theme.settle) { dismiss() } }
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                Text("Or drop a PDF or picture anywhere in this window.").textStyle(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
    }

    private func step(_ n: Int, _ symbol: String, _ words: String) -> some View {
        HStack(spacing: 6) {
            Text("\(n)").textStyle(.data).foregroundStyle(Theme.onAccent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent))
            Text(words).textStyle(.caption).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well.opacity(0.6)))
        .help(symbol.isEmpty ? "" : words)
    }
}

extension OOOSession {
    /// Whether the clipboard holds something Paste Slide can take.
    static var clipboardHasSlide: Bool {
        let pb = NSPasteboard.general
        if pb.availableType(from: [.pdf, .png, .tiff]) != nil { return true }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { u in
            let type = UTType(filenameExtension: u.pathExtension)
            return slideTypes.contains { type?.conforms(to: $0) ?? false }
        }
    }

    /// What you wrote to say over the `k`th slide, for the prompter.
    func notes(onPage k: Int) -> String? {
        project.notes(k)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Over the empty room while the first tour is planned: it is working.
struct ReadingCard: View {
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            Text("Reading your slide…").textStyle(.title).foregroundStyle(.white)
            Text("The camera's tour starts in a moment.").textStyle(.caption).foregroundStyle(.white.opacity(0.75))
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.camera)
                            .frame(width: g.size.width * 0.32)
                            .offset(x: sweep ? g.size.width * 0.68 : 0)
                    }
                    .clipShape(Capsule())
            }
            .frame(width: 160, height: 3)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.5)))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Your notes for the slide face up, at the top of the stage, under the
/// Mac's camera, so your eyes stay near it while you talk. Never in the video.
struct Prompter: View {
    let session: OOOSession
    @Bindable var clock: PlaybackClock
    @AppStorage("live.prompter") private var on = true

    var body: some View {
        if on, let notes = session.notes(onPage: clock.page), !notes.isEmpty {
            Text(notes)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .lineSpacing(2)
                .lineLimit(5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(Theme.settle, value: notes)
                .accessibilityLabel("Your notes")
        }
    }
}
