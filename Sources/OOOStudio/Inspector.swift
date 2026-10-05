import AppKit
import BackdropKit
import OOOCore
import OOOMotion
import RenderCore
import StageKit
import SwiftUI

/// The right-hand panel: the slide map on top, then the camera, the look and
/// the voice.
struct InspectorPanel: View {
    @Bindable var session: OOOSession

    var body: some View {
        VStack(spacing: 0) {
            SlideMap(session: session)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            Text("Drag a framing to move it, a corner to go closer, ⌥-drag to turn. Draw on the slide to add one.")
                .textStyle(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 8)
            ChoiceRow(InspectorTab.allCases.map { ($0, $0.title) }, selection: $session.tab)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch session.tab {
                    case .shot:
                        if let shot = session.selectedShot {
                            ShotInspector(session: session, shot: shot)
                        } else {
                            OverviewInspector(session: session)
                        }
                    case .look:
                        LookInspector(session: session)
                    case .voice:
                        VoiceInspector(session: session)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .background(Theme.chrome)
    }
}

// MARK: - Shared helpers

func percent(_ v: Float) -> String { String(Int((v * 100).rounded())) }
func degreesLabel(_ v: Float) -> String { String(format: "%.0f°", v) }
func secondsValue(_ v: Float) -> String { String(format: "%.1f s", v) }
func signedPercent(_ v: Float) -> String { String(format: "%+.0f", v * 100) }

extension OOOSession {
    /// A live binding into the project; slider gestures wrap it in one undo step.
    func bind<T: Equatable>(_ key: WritableKeyPath<OOOProject, T>) -> Binding<T> {
        Binding(get: { self.project[keyPath: key] }, set: { v in self.live { $0[keyPath: key] = v } })
    }

    /// A binding whose every change is its own undo step (for choices).
    func choice<T: Equatable>(_ key: WritableKeyPath<OOOProject, T>, _ name: String) -> Binding<T> {
        Binding(get: { self.project[keyPath: key] }, set: { v in self.update(name) { $0[keyPath: key] = v } })
    }

    func bindShot<T>(_ id: UUID, _ key: WritableKeyPath<Shot, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.shots.first { $0.id == id }?[keyPath: key] ?? fallback },
                set: { v in self.liveShot(id) { $0[keyPath: key] = v } })
    }

    func choiceShot<T>(_ id: UUID, _ key: WritableKeyPath<Shot, T>, fallback: T, _ name: String) -> Binding<T> {
        Binding(get: { self.project.shots.first { $0.id == id }?[keyPath: key] ?? fallback },
                set: { v in self.updateShot(id, name) { $0[keyPath: key] = v } })
    }
}

/// A slider whose drag is one undo step.
struct Dial: View {
    let session: OOOSession
    let label: String
    let value: Binding<Float>
    var range: ClosedRange<Float> = 0...1
    var defaultValue: Float?
    var format: (Float) -> String = percent
    var undo: String?

    var body: some View {
        let name = undo ?? label
        ValueSlider(label, value: value, range: range, defaultValue: defaultValue, format: format,
                    onBegin: { session.beginEdit(name) }, onCommit: { session.commitEdit(name) })
    }
}

/// A text field that edits the project live and undoes as one step, and keeps
/// single-key shortcuts quiet while it has focus.
struct LiveField: View {
    let session: OOOSession
    let placeholder: String
    let text: Binding<String>
    let undo: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.well.opacity(0.7)))
            .focused($focused)
            .onChange(of: focused) { _, on in
                session.clock.typing = on
                if on { session.beginEdit(undo) } else { session.commitEdit(undo) }
            }
            .onSubmit { focused = false }
    }
}

// MARK: - Shot

struct ShotInspector: View {
    let session: OOOSession
    let shot: Shot

    var body: some View {
        let id = shot.id
        let p = session.project
        let number = (session.index(of: id) ?? 0) + 1
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection("Shot \(number)", accessory: {
                Text("lands at \(secondsLabel(shot.time))").textStyle(.data).foregroundStyle(.secondary)
            }) {
                LiveField(session: session, placeholder: "Name",
                          text: Binding(get: { session.project.shots.first { $0.id == id }?.label ?? "" },
                                        set: { v in session.liveShot(id) { $0.label = v.isEmpty ? nil : v } }),
                          undo: "Rename Shot")
                LiveField(session: session, placeholder: "Lands on the words…",
                          text: Binding(get: { session.project.shots.first { $0.id == id }?.cue ?? "" },
                                        set: { v in session.liveShot(id) { $0.cue = v.isEmpty ? nil : v } }),
                          undo: "Cue")
                Text(p.voice?.words == nil
                     ? "With a voiceover, the camera lands just before you say these words."
                     : "Cut to Voice lands the camera just before you say these words.")
                    .textStyle(.caption).foregroundStyle(.tertiary)
            }
            Hairline()
            InspectorSection("Move") {
                ChoiceRow(MoveKind.allCases.map { ($0, $0.title) },
                          selection: session.choiceShot(id, \.move, fallback: .glide, "Move"))
                ChoiceRow(EaseKind.allCases.map { ($0, $0.title) },
                          selection: session.choiceShot(id, \.ease, fallback: .glide, "Ease"))
                Text("\(shot.move.summary) \(shot.ease.summary)").textStyle(.caption).foregroundStyle(.secondary)
                Toggle("Choose the travel time for me", isOn: Binding(
                    get: { session.project.shots.first { $0.id == id }?.travel == nil },
                    set: { auto in
                        let natural = session.choreography.beats.first { !$0.isOverview && $0.shot.id == id }?.travel ?? 1.4
                        session.updateShot(id, "Travel") { $0.travel = auto ? nil : max(natural, 0.3) }
                    }))
                    .toggleStyle(.checkbox)
                    .textStyle(.bodyCompact)
                if shot.travel != nil {
                    Dial(session: session, label: "Travel",
                         value: Binding(get: { Float(session.project.shots.first { $0.id == id }?.travel ?? 1.4) },
                                        set: { v in session.liveShot(id) { $0.travel = Double(v) } }),
                         range: 0.3...6, defaultValue: 1.6, format: secondsValue)
                }
            }
            Hairline()
            InspectorSection("Framing") {
                Dial(session: session, label: "Closer", value: zoom(id), range: 0...4.5, defaultValue: 1,
                     format: { String(format: "%.1f×", powf(2, $0)) }, undo: "Frame Shot")
                Dial(session: session, label: "Turn", value: session.bindShot(id, \.yaw, fallback: 0), range: -25...25,
                     defaultValue: 0, format: degreesLabel)
                Dial(session: session, label: "Tilt", value: session.bindShot(id, \.pitch, fallback: 0), range: -20...20,
                     defaultValue: 0, format: degreesLabel)
                Dial(session: session, label: "Roll", value: session.bindShot(id, \.roll, fallback: 0), range: -12...12,
                     defaultValue: 0, format: degreesLabel)
                Dial(session: session, label: "Lens", value: lens(id), range: 28...135, defaultValue: 48,
                     format: { String(format: "%.0f mm", $0) })
                Dial(session: session, label: "Focus falloff", value: session.bindShot(id, \.aperture, fallback: 0.4), defaultValue: 0.45)
                Dial(session: session, label: "Breathe", value: session.bindShot(id, \.breathe, fallback: 0.5), defaultValue: 0.5)
            }
            Hairline()
            InspectorSection("While it holds") {
                ChoiceRow(Emphasis.allCases.map { ($0, $0.title) },
                          selection: session.choiceShot(id, \.emphasis, fallback: .none, "Emphasis"))
                Text(emphasisSummary(shot.emphasis)).textStyle(.caption).foregroundStyle(.secondary)
            }
            Hairline()
            HStack(spacing: 6) {
                Button("Duplicate") { session.duplicateSelectedShot() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button(role: .destructive) { session.deleteSelectedShot() } label: { Text("Delete Shot") }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }

    private func emphasisSummary(_ e: Emphasis) -> String {
        switch e {
        case .none: return "The slide stays as it is."
        case .spotlight: return "The rest of the slide dims, as if a light found the detail."
        case .lift: return "The detail lifts off the slide as a cut-out, throwing a shadow."
        }
    }

    /// How many times closer than the whole slide, as a power of two.
    private func zoom(_ id: UUID) -> Binding<Float> {
        let p = session.project
        return Binding(
            get: {
                guard let s = session.project.shots.first(where: { $0.id == id }) else { return 0 }
                return log2f(max(s.frame.magnification(slideAspect: p.slideAspect, canvasAspect: p.canvasAspect), 0.5))
            },
            set: { z in
                session.liveShot(id) { s in
                    let now = log2f(max(s.frame.magnification(slideAspect: p.slideAspect, canvasAspect: p.canvasAspect), 0.5))
                    s.frame.size *= powf(2, now - z)
                }
            })
    }

    /// Focal length on a full-frame camera, from the vertical field of view.
    private func lens(_ id: UUID) -> Binding<Float> {
        Binding(
            get: {
                let fov = session.project.shots.first { $0.id == id }?.lens ?? 28
                return 12 / tanf(radians(fov) / 2)
            },
            set: { mm in session.liveShot(id) { $0.lens = degrees(2 * atanf(12 / mm)) } })
    }
}

// MARK: - Overview, arrival, ending

extension ArriveKind {
    var symbol: String {
        switch self {
        case .rise: return "arrow.up.forward"
        case .unfold: return "scroll"
        case .drop: return "arrow.down.to.line"
        case .develop: return "camera.aperture"
        case .turn: return "arrow.triangle.2.circlepath"
        case .glide: return "wind"
        case .none: return "circle.slash"
        }
    }
}

struct OverviewInspector: View {
    let session: OOOSession

    var body: some View {
        let p = session.project
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection("Arrival", accessory: {
                Button("Watch") {
                    session.clock.time = 0
                    session.clock.playing = true
                }
                .buttonStyle(QuietButtonStyle())
            }) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(ArriveKind.allCases) { kind in
                        ArriveTile(kind: kind, selected: p.arrive.kind == kind) {
                            session.update("Arrival") { $0.arrive = Arrive(kind: kind, intensity: $0.arrive.intensity) }
                            session.clock.time = 0
                            session.clock.playing = true
                        }
                    }
                }
                Text(p.arrive.kind.summary).textStyle(.caption).foregroundStyle(.secondary)
                if p.arrive.kind != .none {
                    Dial(session: session, label: "Length", value: Binding(
                        get: { Float(session.project.arrive.duration) },
                        set: { v in session.live { $0.arrive.duration = Double(v) } }),
                         range: 0.6...4, defaultValue: Float(p.arrive.kind.defaultDuration), format: secondsValue, undo: "Arrival Length")
                    Dial(session: session, label: "Intensity", value: session.bind(\.arrive.intensity), defaultValue: 0.6)
                }
            }
            Hairline()
            InspectorSection("Opening framing") {
                Dial(session: session, label: "Turn", value: session.bind(\.overview.yaw), range: -25...25, defaultValue: -9, format: degreesLabel)
                Dial(session: session, label: "Tilt", value: session.bind(\.overview.pitch), range: -20...20, defaultValue: 7, format: degreesLabel)
                Dial(session: session, label: "Room", value: overviewRoom, range: 0...0.6, defaultValue: 0.12, format: percent)
                Dial(session: session, label: "Breathe", value: session.bind(\.overview.breathe), defaultValue: 0.45)
            }
            Hairline()
            InspectorSection("Ending") {
                ChoiceRow(Ending.allCases.map { ($0, $0.title) }, selection: session.choice(\.ending, "Ending"))
            }
            Hairline()
            InspectorSection("The camera's temperament") {
                Dial(session: session, label: "Flight", value: session.bind(\.style.flight), defaultValue: 0.5)
                Dial(session: session, label: "Swing", value: session.bind(\.style.swing), defaultValue: 0.5)
                Dial(session: session, label: "Handheld", value: session.bind(\.style.drift), defaultValue: 0.35)
                Dial(session: session, label: "Pace", value: session.bind(\.style.pace), defaultValue: 0.5)
                Text("Flight is how high a glide rises between distant details. Handheld is a slow breath in the camera.")
                    .textStyle(.caption).foregroundStyle(.tertiary)
            }
            Hairline()
            InspectorSection("Length", accessory: {
                Text(secondsLabel(session.choreography.duration)).textStyle(.data).foregroundStyle(.secondary)
            }) {
                Toggle("Fit the moves and the voice", isOn: Binding(
                    get: { session.project.length == nil },
                    set: { fit in session.update("Length") { $0.length = fit ? nil : $0.duration } }))
                    .toggleStyle(.checkbox)
                    .textStyle(.bodyCompact)
                if p.length != nil {
                    Dial(session: session, label: "Seconds", value: Binding(
                        get: { Float(session.project.length ?? 10) },
                        set: { v in session.live { $0.length = Double(v) } }),
                         range: 3...120, format: secondsValue, undo: "Length")
                }
            }
        }
    }

    /// The margin around the whole slide in the opening framing.
    private var overviewRoom: Binding<Float> {
        Binding(get: { session.project.overview.frame.size.y - 1 },
                set: { v in session.live { $0.overview.frame = .whole(margin: v) } })
    }
}

struct ArriveTile: View {
    let kind: ArriveKind
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol).font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(kind.title).textStyle(.bodyCompact)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Theme.segmentOn : Theme.well.opacity(hover ? 0.9 : 0.55)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Theme.camera.opacity(0.7) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(kind.summary)
    }
}

// MARK: - Look

struct LookInspector: View {
    let session: OOOSession

    var body: some View {
        let p = session.project
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection("Surface") {
                ChoiceRow(SurfaceKind.allCases.map { ($0, $0.title) }, selection: session.choice(\.look.surface, "Surface"))
                Text(p.look.surface.summary).textStyle(.caption).foregroundStyle(.secondary)
                Dial(session: session, label: "Corners", value: session.bind(\.look.corners), defaultValue: 0.25)
                Dial(session: session, label: "Thickness", value: session.bind(\.look.edge), defaultValue: 1)
            }
            Hairline()
            InspectorSection("Light") {
                Dial(session: session, label: "Direction", value: session.bind(\.look.lightAzimuth), range: 0...360,
                     defaultValue: 118, format: degreesLabel)
                Dial(session: session, label: "Height", value: session.bind(\.look.lightElevation), range: 10...85,
                     defaultValue: 52, format: degreesLabel)
                Dial(session: session, label: "Shadow", value: session.bind(\.look.shadow), defaultValue: 0.6)
                Dial(session: session, label: "Softness", value: session.bind(\.look.shadowSoftness), defaultValue: 0.6)
            }
            Hairline()
            InspectorSection("Lens") {
                Dial(session: session, label: "Depth of field", value: session.bind(\.look.depthOfField), defaultValue: 0.5)
                Dial(session: session, label: "Motion blur", value: session.bind(\.look.shutter), defaultValue: 0.5,
                     format: { String(format: "%.0f°", $0 * 360) })
                Text("Motion blur is a film camera's shutter: 180° is how films are shot.")
                    .textStyle(.caption).foregroundStyle(.tertiary)
            }
            Hairline()
            InspectorSection("Finish") {
                Dial(session: session, label: "Glow", value: session.bind(\.look.finish.bloom), defaultValue: 0.16)
                Dial(session: session, label: "Vignette", value: session.bind(\.look.finish.vignette), defaultValue: 0.3)
                Dial(session: session, label: "Grain", value: session.bind(\.look.finish.grain), defaultValue: 0.14)
                Dial(session: session, label: "Warmth", value: session.bind(\.look.finish.warmth), range: -1...1, defaultValue: 0,
                     format: signedPercent)
                Dial(session: session, label: "Contrast", value: session.bind(\.look.finish.contrast), range: -1...1, defaultValue: 0,
                     format: signedPercent)
            }
            Hairline()
            InspectorSection("Backdrop", accessory: {
                Menu {
                    ForEach(BackdropFamily.allCases) { family in
                        Section(family.title) {
                            ForEach(BackdropCatalog.styles(in: family)) { style in
                                Button(style.name) {
                                    session.update("Backdrop") { proj in
                                        var b = style.defaults
                                        b.palette = proj.backdrop.palette
                                        b.brightness = proj.backdrop.brightness
                                        proj.backdrop = b
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(p.backdrop.styleInfo.name).textStyle(.bodyCompact)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }) {
                Text(p.backdrop.styleInfo.summary).textStyle(.caption).foregroundStyle(.secondary)
                PalettePicker(selected: p.backdrop.palette.id) { pal in
                    session.update("Palette") { $0.backdrop.palette = pal }
                }
                Dial(session: session, label: "Motion", value: session.bind(\.backdrop.motion), defaultValue: 0.25)
                Dial(session: session, label: "Brightness", value: session.bind(\.backdrop.brightness), range: 0.2...1.6,
                     defaultValue: 1)
            }
        }
    }
}

// MARK: - Voice

struct VoiceInspector: View {
    let session: OOOSession
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let voice = session.project.voice {
                InspectorSection(voice.name, accessory: {
                    Text(secondsLabel(voice.duration)).textStyle(.data).foregroundStyle(.secondary)
                }) {
                    Dial(session: session, label: "Starts at", value: Binding(
                        get: { Float(session.project.voice?.offset ?? 0) },
                        set: { v in session.setVoiceOffset(Double(v), live: true) }),
                         range: -5...20, defaultValue: 0.5, format: secondsValue, undo: "Move Voiceover")
                    Dial(session: session, label: "Level", value: Binding(
                        get: { session.project.voice?.gain ?? 1 },
                        set: { v in session.live { $0.voice?.gain = v } }),
                         range: 0...2, defaultValue: 1, format: percent, undo: "Voice Level")
                }
                Hairline()
                InspectorSection("Words", accessory: {
                    if let words = voice.words { Badge("\(words.count) heard") }
                }) {
                    if let words = voice.words, !words.isEmpty {
                        Transcript(words: words, landings: session.choreography.landings)
                        Button {
                            session.cutToVoice()
                        } label: {
                            Label("Cut Moves to Voice", systemImage: "waveform.path")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Keeps every framing and lands each one just before you say its words")
                        Text("Each shot lands just before its cue words, or its name, are said. Shots the voice never names are fitted in between.")
                            .textStyle(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text("OOO listens on this Mac for the words and when you say them. Nothing leaves your computer.")
                            .textStyle(.caption).foregroundStyle(.secondary)
                    }
                    Button(voice.words == nil ? "Listen for Words" : "Listen Again") { session.transcribe() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(session.busy != nil)
                }
                Hairline()
                HStack {
                    Button("Replace…") { OOOCommands.chooseVoice(session) }
                        .buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("Remove Voiceover", role: .destructive) { session.removeVoice() }
                        .buttonStyle(QuietButtonStyle())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .foregroundStyle(targeted ? Theme.camera : Color.secondary.opacity(0.5))
                        Image(systemName: "waveform")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 96)
                    Text("Talk about your slide").textStyle(.title)
                    Text("Record your voiceover first, in any app, then drop it here. OOO hears the words on this Mac and lands each move just before you say them.")
                        .textStyle(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Choose Voiceover…") { OOOCommands.chooseVoice(session) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(Theme.Space.l)
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    loadDropped(providers) { urls in if let url = urls.first { session.importVoice(url) } }
                    return true
                }
            }
        }
    }
}

/// What was said, with the words the camera lands on marked.
struct Transcript: View {
    let words: [SpokenWord]
    let landings: [Double]

    var body: some View {
        let marked = Set(landings.compactMap { t in words.firstIndex { $0.start >= t - 0.05 && $0.start <= t + 0.6 } })
        let text = words.enumerated().reduce(Text("")) { acc, item in
            let (i, w) = item
            let piece = Text((i == 0 ? "" : " ") + w.text)
            return acc + (marked.contains(i) ? piece.foregroundColor(Theme.camera).bold() : piece.foregroundColor(.secondary))
        }
        ScrollView {
            text.font(.system(size: 12)).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 150)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well.opacity(0.5)))
    }
}
