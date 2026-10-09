import AppKit
import OOOCore
import OOOMotion
import SwiftUI

/// What the mouse does, everywhere in the window: shape the tour, draw on the
/// slide, or lead it live while the Mac records you. Always in view in the
/// toolbar, so you always know which one you are in.
public enum EditorMode: String, CaseIterable, Identifiable {
    case frame, draw, live

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .frame: return "Frame"
        case .draw: return "Draw"
        case .live: return "Live"
        }
    }

    public var symbol: String {
        switch self {
        case .frame: return "viewfinder"
        case .draw: return "pencil.tip"
        case .live: return "record.circle"
        }
    }

    /// Its key, with ⌘.
    public var key: Character {
        switch self {
        case .frame: return "1"
        case .draw: return "2"
        case .live: return "3"
        }
    }

    public var summary: String {
        switch self {
        case .frame: return "Shape the tour: what the camera looks at, and for how long"
        case .draw: return "Draw on the slide: circle a number, underline a word"
        case .live: return "Talk it through and lead the camera yourself while your Mac records you"
        }
    }
}

extension OOOSession {
    /// Whether the window can go into `m` now. A take holds you in Live
    /// until it is kept or given up.
    public func canEnter(_ m: EditorMode) -> Bool {
        guard take == nil else { return m == mode }
        switch m {
        case .frame: return true
        case .draw: return hasSlide
        case .live: return hasSlide && !recorder.isActive
        }
    }

    /// Goes into mode `m`: Draw takes the pen out where the card lies still,
    /// Live opens the room, and Frame puts everything else away.
    public func enter(_ m: EditorMode) {
        guard m != mode, canEnter(m) else { return }
        switch mode {
        case .draw: finishDrawing(replay: m == .frame)
        case .live: leaveLive()
        case .frame: break
        }
        mode = m
        switch m {
        case .draw: startDrawing()
        case .live: openRoom()
        case .frame: break
        }
    }

    // MARK: Draw

    /// Takes the pen out. On a moving frame the playhead goes to the nearest
    /// place the card lies still, so there is always something to draw on.
    func startDrawing() {
        settleEdits()
        pen.on = true
        if !penCanDraw, let t = stillPoint(nearest: clock.time) { glide(to: t) }
    }

    /// The moments the pen can draw: a little after each landing, with the
    /// card at rest.
    var stillPoints: [Double] {
        guard let scene else { return [] }
        let C = project.canvasAspect, d = clock.duration
        return choreography.beats.compactMap { b in
            let t = min(b.land + min(0.35, max(b.leave - b.land, 0) * 0.3), d)
            return scene.touch(0, 0, at: t, canvasAspect: C) != nil ? t : nil
        }
    }

    func stillPoint(nearest t: Double) -> Double? {
        stillPoints.min { abs($0 - t) < abs($1 - t) }
    }

    /// The next place the pen can draw (1), or the one before (−1).
    public func stepStill(_ direction: Int) {
        let t = clock.time, points = stillPoints
        let target = direction < 0 ? points.last { $0 < t - 0.05 } : points.first { $0 > t + 0.05 }
        guard let target else { return }
        unpinMarks()
        glide(to: target)
    }

    /// Takes the playhead to `t`: played there when it is a moment ahead, so
    /// the camera flies as it will in the video; otherwise straight there.
    func glide(to t: Double) {
        let from = clock.time
        if t > from, t - from < 3, !PlaybackClock.reduceMotion {
            previewUntil = max(t, from + 0.01)
            clock.playing = true
        } else {
            previewUntil = nil
            clock.playing = false
            clock.time = t
            touch()
        }
    }

    // MARK: Frame

    /// A new framing a third of the slide high, of the video's shape, around `uv`
    /// (or the camera's view at the playhead).
    public func addShot(around uv: Vec2?, page k: Int) {
        guard let uv else {
            addShot(page: k)
            return
        }
        let A = project.slide(k).aspect, C = project.canvasAspect
        let h: Float = 0.34
        addShot(frame: ShotFrame(center: uv, size: Vec2(h * C / A, h)), page: k)
    }

    /// A new framing of exactly what the camera sees at the playhead.
    public func addShotFromView() {
        let k = choreography.page(at: clock.time)
        let f = choreography.pose(at: clock.time).frame(slideAspect: project.slide(k).aspect, canvasAspect: project.canvasAspect)
        addShot(frame: f, page: k)
    }
}

// MARK: - The switch

/// Frame, Draw and Live in the middle of the toolbar, each named, like a
/// design tool's tools. ⌘1, ⌘2 and ⌘3 switch; Esc goes back to Frame.
struct ModeSwitch: View {
    @Bindable var session: OOOSession

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorMode.allCases) { m in
                ModeButton(mode: m, on: session.mode == m, enabled: session.canEnter(m)) { session.enter(m) }
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.well.opacity(0.7)))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }
}

struct ModeButton: View {
    let mode: EditorMode
    let on: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let ink: Color = on ? .primary : .secondary
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode == .live && on ? "record.circle.fill" : mode.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(mode == .live && on ? Theme.camera : ink)
                Text(mode.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ink)
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Capsule().fill(on ? Theme.segmentOn : Color.primary.opacity(hover && enabled ? 0.07 : 0)))
            .shadow(color: .black.opacity(on ? 0.16 : 0), radius: 1, y: 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled || on ? 1 : 0.4)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
        .help("\(mode.summary) (⌘\(String(mode.key)))")
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Right-click on the stage

/// The stage's menu: what you would do to the video right here, in each mode.
struct StageMenu: View {
    @Bindable var session: OOOSession
    @AppStorage("showSafeAreas") private var showSafeAreas = false
    @AppStorage("live.camera") private var filmMe = true

    var body: some View {
        switch session.mode {
        case .frame:
            Button(session.clock.playing ? "Pause" : "Play") {
                session.clock.playing.toggle()
                session.touch()
            }
            Divider()
            Button("New Framing From This View") { session.addShotFromView() }
            Button("Draw Here") { session.enter(.draw) }
            Button("Go Live") { session.enter(.live) }
                .disabled(!session.canEnter(.live))
            Divider()
            Button("Save This Frame…") { OOOCommands.saveCoverFrame(session) }
            Toggle("Show Safe Areas", isOn: $showSafeAreas)
        case .draw:
            Picker("Ink", selection: $session.pen.color) {
                ForEach(InkColor.allCases) { Text($0.title).tag($0) }
            }
            Picker("Marks", selection: $session.pen.fades) {
                Text("Stay Until the Slide Changes").tag(false)
                Text("Fade After They Are Drawn").tag(true)
            }
            Divider()
            Button("Previous Still Point") { session.stepStill(-1) }
            Button("Next Still Point") { session.stepStill(1) }
            Divider()
            Button("Undo Last Mark") { session.deleteLastMark() }
                .disabled(session.project.marks?.isEmpty ?? true)
            Button("Clear Marks Here") { session.clearMarksHere() }
                .disabled(session.project.marks?.isEmpty ?? true)
            Divider()
            Button("Done Drawing") { session.finishDrawing() }
        case .live:
            switch session.liveStep {
            case .room:
                Button("Start") { session.startTake() }
                    .disabled(session.liveCapture.phase != .ready)
                Toggle("Film Me", isOn: Binding(get: { filmMe }, set: { session.setFilmMe($0) }))
                Divider()
                Button("Preview the Opening") { session.previewOpening() }
                Button("Preview the Closing") { session.previewClosing() }
                Divider()
                Button("Back to Frame") { session.enter(.frame) }
            case .kept:
                Button("Play") { session.playKept() }
                Button("Retake") { session.retake() }
                Button("Done") { session.liveDone() }
            default:
                EmptyView()
            }
        }
    }
}
