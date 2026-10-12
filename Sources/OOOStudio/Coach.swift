import AppKit
import AVFoundation
import OOOCore
import OOOMotion
import SwiftUI

/// The next step, as the line above the video says it: what OOO is doing,
/// or what to do now. The first that holds wins.
enum NextStep: Equatable {
    case recording
    case comparing
    case reading
    case listening
    case working(String)
    case sample
    case noShots
    case shot(UUID)
    case exported([URL])
    case tourReady
    case notHeard
    case timed
    case ready
}

extension OOOSession {
    /// Where you are on the way from a slide to a posted video.
    var nextStep: NextStep {
        if recorder.isActive { return .recording }
        if comparing { return .comparing }
        if let busy {
            switch busy {
            case "Drawing the slide", "Drawing the slides":
                return project.slide.kind == .sample ? .working("Setting out the sample") : .reading
            case "Reading the slide", "Reading the slides", "Reading the new slide": return .reading
            case "Reading the recording", "Listening to the voiceover": return .listening
            default: return .working(busy)
            }
        }
        if project.slide.kind == .sample { return .sample }
        if hasSlide && project.shots.isEmpty { return .noShots }
        if let id = selectedShot?.id { return .shot(id) }
        if let last = lastExport, last.project == project, !last.urls.isEmpty { return .exported(last.urls) }
        if project.voice == nil && project.face == nil { return .tourReady }
        if let voice = project.voice, voice.words?.isEmpty ?? true { return .notHeard }
        if justTimed { return .timed }
        return .ready
    }

    /// Ready to post and not yet exported as it is: Export glows.
    var readyToPost: Bool {
        switch nextStep {
        case .timed, .ready: return mode == .frame
        default: return false
        }
    }

    /// Before the Mac first asks for the microphone (and camera), whether it
    /// still has to: the room says why first.
    static func captureUnasked(filming: Bool) -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            || (filming && AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined)
    }

    /// Whether the microphone, or the camera wanted, has been refused.
    static func captureRefused(filming: Bool) -> Bool {
        let refused: [AVAuthorizationStatus] = [.denied, .restricted]
        return refused.contains(AVCaptureDevice.authorizationStatus(for: .audio))
            || (filming && refused.contains(AVCaptureDevice.authorizationStatus(for: .video)))
    }

    /// Opens System Settings where the microphone (or camera) is allowed.
    static func openPrivacySettings(camera: Bool = false) {
        let pane = camera ? "Privacy_Camera" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Export, from a take just kept: back to Frame, the take is the video.
    public func exportKept() {
        liveDone()
        showExport = true
    }
}

// MARK: - The line

/// One step, said: a mark, a title, a hint, and up to two buttons, the first
/// the one to press.
struct Coach {
    enum Mark { case none, dot, recording, spinner, done, pen(Color) }
    enum Action {
        case run(() -> Void)
        case share([URL])
        case voice
    }
    struct Button {
        var title: String
        var help: String?
        var action: Action
    }
    var mark: Mark = .none
    var title: String
    var hint: String?
    var primary: Button?
    var secondary: Button?
}

/// Lays a step out to fit the width above the video, never cut off: the hint
/// wraps to a second line, then gives way, then the second button does.
struct CoachLine: View {
    let coach: Coach
    let session: OOOSession
    let width: CGFloat
    @State private var choosingVoice = false

    private static func measure(_ s: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    private func buttonWidth(_ b: Coach.Button, primary: Bool) -> CGFloat {
        Self.measure(b.title, size: 13, weight: primary ? .semibold : .medium) + (primary ? 28 : 20)
    }

    /// What fits: the hint on one line, on two, or not at all; and whether the second button does.
    private var layout: (hint: Int, secondary: Bool) {
        let gap: CGFloat = 8
        let mark: CGFloat = { if case .none = coach.mark { return 0 } else { return 14 + gap } }()
        let title = Self.measure(coach.title, size: 12, weight: .semibold)
        let first = coach.primary.map { buttonWidth($0, primary: true) + gap } ?? 0
        let second = coach.secondary.map { buttonWidth($0, primary: false) + gap } ?? 0
        let hint = coach.hint.map { Self.measure($0, size: 11.5, weight: .regular) + gap } ?? 0
        let room = width - 24
        let base = mark + title + first
        for keepSecond in [true, false] where keepSecond || coach.secondary != nil {
            let used = base + (keepSecond ? second : 0)
            if hint == 0 { if used <= room { return (0, keepSecond) } else { continue } }
            if used + hint <= room { return (1, keepSecond) }
            // Two lines, each no wider than the room left.
            if used + hint / 2 + 24 <= room { return (2, keepSecond) }
        }
        return (0, base + second <= room)
    }

    var body: some View {
        let fit = layout
        HStack(spacing: 8) {
            markView
            Text(coach.title).textStyle(.label).foregroundStyle(.primary).lineLimit(1).fixedSize()
            if fit.hint > 0, let hint = coach.hint {
                Text(hint).textStyle(.caption).foregroundStyle(.secondary)
                    .lineLimit(fit.hint)
                    .fixedSize(horizontal: fit.hint == 1, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            if let p = coach.primary { button(p, primary: true) }
            if fit.secondary, let s = coach.secondary { button(s, primary: false) }
        }
        .help(fit.hint == 0 ? (coach.hint ?? "") : "")
    }

    @ViewBuilder
    private var markView: some View {
        switch coach.mark {
        case .none: EmptyView()
        case .dot: Circle().fill(Theme.camera).frame(width: 7, height: 7)
        case .recording: RecordingDot()
        case .spinner: ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.camera)
        case .pen(let tone):
            Image(systemName: "pencil.tip").font(.system(size: 11, weight: .semibold)).foregroundStyle(tone)
        }
    }

    @ViewBuilder
    private func button(_ b: Coach.Button, primary: Bool) -> some View {
        switch b.action {
        case .run(let run):
            if primary {
                SwiftUI.Button(b.title, action: run).buttonStyle(PrimaryButtonStyle()).fixedSize().help(b.help ?? "")
            } else {
                SwiftUI.Button(b.title, action: run).buttonStyle(QuietButtonStyle()).fixedSize().help(b.help ?? "")
            }
        case .share(let urls):
            if primary {
                ShareLink(items: urls) { Text(b.title) }.buttonStyle(PrimaryButtonStyle()).fixedSize().help(b.help ?? "")
            } else {
                ShareLink(items: urls) { Text(b.title) }.buttonStyle(QuietButtonStyle()).fixedSize().help(b.help ?? "")
            }
        case .voice:
            SwiftUI.Button(b.title) { choosingVoice = true }
                .buttonStyle(PrimaryButtonStyle())
                .fixedSize()
                .help(b.help ?? "")
                .popover(isPresented: $choosingVoice, arrowEdge: .bottom) {
                    VoiceChoices(session: session) { choosingVoice = false }
                }
        }
    }
}

/// The three ways to give the video your voice, side by side, so the choice
/// is plain: talk over it here, go live, or bring a recording.
struct VoiceChoices: View {
    let session: OOOSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add your voice").textStyle(.title).padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
            row("record.circle", "Record over it", "Talk as the video plays. Each move lands on your words.", "⌥⌘R") {
                session.startRecording()
            }
            row("person.crop.square", "Go Live", "It films you too, and you lead the camera as you talk.", "⌥⌘L") {
                session.enter(.live)
            }
            .disabled(!session.canEnter(.live))
            row("waveform.badge.plus", "Use a recording…", "A voiceover from any app: M4A, MP3, WAV or AIFF.", "⌥⌘I") {
                OOOCommands.chooseVoice(session)
            }
        }
        .padding(10)
        .frame(width: 340)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, _ keys: String, _ action: @escaping () -> Void) -> some View {
        ChoiceCard(symbol: symbol, title: title, detail: detail, keys: keys) {
            close()
            action()
        }
    }
}

/// One choice, with an icon, a title, a line saying what it does, and its keys.
struct ChoiceCard: View {
    let symbol: String
    let title: String
    let detail: String
    var keys: String?
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.camera)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title).textStyle(.label).foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        if let keys { Text(keys).textStyle(.data).foregroundStyle(.tertiary) }
                    }
                    Text(detail).textStyle(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hover && enabled ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
    }
}

// MARK: - Each mode's steps

extension OOOSession {
    /// The step in Frame.
    var frameCoach: Coach {
        switch nextStep {
        case .recording:
            return Coach(mark: .recording, title: "Recording", hint: "Talk it through, then click Stop. The video grows to fit you.",
                         primary: .init(title: "Stop", help: "Stop, and time the moves to what you said (⌥⌘R)", action: .run { [weak self] in self?.stopRecording() }))
        case .comparing:
            return Coach(title: "Original", hint: "The slide exactly as supplied. Let go of \\ to see your look.")
        case .reading:
            return Coach(mark: .spinner, title: "Reading your slide…", hint: "The camera's tour starts in a moment.")
        case .listening:
            return Coach(mark: .spinner, title: "Listening to your voice…", hint: "The moves will land on your words.")
        case .working(let what):
            return Coach(mark: .spinner, title: what)
        case .sample:
            return Coach(title: "Sample slide", hint: "Drop your slide anywhere, or",
                         primary: .init(title: "Use Your Slide…", help: "A PDF or a picture (⌘I). Or copy a slide in Keynote, Figma or Preview and paste it (⇧⌘V).",
                                        action: .run { [weak self] in if let self { OOOCommands.chooseSlide(self) } }))
        case .noShots:
            if let notice { return Coach(title: "Nothing to read", hint: notice) }
            return Coach(title: "No framings yet", hint: "Draw a box on the slide map, or",
                         primary: .init(title: "Direct for Me", help: "Read the slide and plan the camera's tour (⇧⌘D)",
                                        action: .run { [weak self] in self?.autoDirect() }))
        case .shot(let id):
            let n = (index(of: id) ?? 0) + 1
            let name = selectedShot.flatMap { Director.spokenLabel($0.label) } ?? "Framing \(n)"
            let clip = clip(of: id)
            return Coach(title: name, hint: clip.map { "Moves in over \(secondsLabel($0.move)), holds \(secondsLabel($0.hold))." },
                         secondary: .init(title: "‹ Whole Video", help: "Back to the whole video (Esc)",
                                          action: .run { [weak self] in self?.select(.overview, show: false) }))
        case .exported(let urls):
            let hint = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) sizes, in \(urls[0].deletingLastPathComponent().lastPathComponent)"
            return Coach(mark: .done, title: "Exported", hint: hint,
                         primary: .init(title: "Share…", help: "AirDrop it to your phone, or send it", action: .share(urls)),
                         secondary: .init(title: "Show in Finder", action: .run { NSWorkspace.shared.activateFileViewerSelecting(urls) }))
        case .tourReady:
            return Coach(title: "Your tour is ready", hint: "Talk over it so each move lands on your words, or export it as it is.",
                         primary: .init(title: "Add Your Voice…", help: "Record over it, go live, or use a recording", action: .voice),
                         secondary: .init(title: "Export…", help: "Export the video (⌘E)", action: .run { [weak self] in self?.showExport = true }))
        case .notHeard:
            return Coach(title: "Your voice is in", hint: "OOO couldn't make out the words, so the moves keep their own timing.",
                         primary: .init(title: "Export…", help: "Export the video (⌘E)", action: .run { [weak self] in self?.showExport = true }),
                         secondary: .init(title: "Listen Again", help: "Listen for the words again, on this Mac",
                                          action: .run { [weak self] in self?.transcribe() }))
        case .timed:
            return Coach(mark: .done, title: "Timed to your voice",
                         hint: project.showsCaptions ? "Each move lands just before you say its words, with captions." : "Each move now lands just before you say its words.",
                         primary: .init(title: "Export…", help: "Export the video (⌘E)", action: .run { [weak self] in self?.showExport = true }))
        case .ready:
            var hint = "\(project.format.name) · \(secondsLabel(choreography.duration))"
            if project.face != nil { hint += " · with you" } else if project.voice != nil { hint += " · with your voice" }
            if project.showsCaptions { hint += " · captions" }
            return Coach(title: "Ready to post", hint: hint,
                         primary: .init(title: "Export…", help: "Export the video (⌘E)", action: .run { [weak self] in self?.showExport = true }))
        }
    }

    /// The step in Draw.
    var drawCoach: Coach {
        let tone = Coach.Mark.pen(pen.tone.swatch)
        if clock.playing { return Coach(mark: tone, title: "Draw", hint: "Going to where the slide lies still.") }
        if penCanDraw {
            if !penMarks.isEmpty, project.marks?.contains(where: { penMarks.contains($0.id) }) == true {
                return Coach(mark: tone, title: "Drawn", hint: "In the video it draws on as your hand did.",
                             primary: .init(title: "Done", help: "Put the pen away (Esc)", action: .run { [weak self] in self?.finishDrawing() }))
            }
            return Coach(mark: tone, title: "Draw", hint: "Circle a number or underline a word.")
        }
        return Coach(mark: tone, title: "Draw", hint: "The slide is moving here.",
                     secondary: .init(title: "Next Framing", help: "Go to where the slide next lies still (→)",
                                      action: .run { [weak self] in self?.stepStill(1) }))
    }

    /// The step in Live.
    var liveCoach: Coach {
        switch liveStep {
        case .room:
            if liveAsking {
                return Coach(mark: .dot, title: "Live", hint: "OOO will ask to use your camera and microphone. Nothing leaves your Mac.",
                             primary: .init(title: "Continue", help: "Ask for the camera and microphone (Return)",
                                            action: .run { [weak self] in self?.allowCapture() }))
            }
            if liveCapture.phase == .preparing { return Coach(mark: .spinner, title: "Live", hint: "Getting your camera ready…") }
            if let note = liveNote { return Coach(mark: .dot, title: "Live", hint: note) }
            return Coach(mark: .dot, title: "Live", hint: "Press Start, then → moves the camera on as you talk.")
        case .counting:
            return Coach(mark: .recording, title: "Get ready", hint: "Recording starts on the beat.")
        case .recording:
            return pen.on ? Coach(mark: .recording, title: "Drawing", hint: "→ and ← still lead · D puts the pen away")
                : Coach(mark: .recording, title: "Recording", hint: "→ next · ← back · D draws · Return closes")
        case .closing:
            return Coach(mark: .recording, title: "Closing", hint: "Still recording your sign-off. It stops by itself.")
        case .keeping:
            return Coach(mark: .spinner, title: "Keeping your take…")
        case .kept:
            return Coach(mark: .done, title: "Kept", hint: "This take is your video now. ⌘Z takes it back.",
                         primary: .init(title: "Export…", help: "Export the video (Return)", action: .run { [weak self] in self?.exportKept() }),
                         secondary: .init(title: "Retake", help: "Back to the room to try again; this take is undone (⌥⌘L)",
                                          action: .run { [weak self] in self?.retake() }))
        }
    }
}
