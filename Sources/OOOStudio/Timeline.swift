import AppKit
import OOOCore
import OOOMotion
import RenderCore
import SwiftUI

/// Seconds to points and back across the timeline's width.
struct TimeScale {
    let width: CGFloat
    let duration: Double
    static let pad: CGFloat = 16

    var span: CGFloat { max(width - 2 * Self.pad, 1) }
    var pointsPerSecond: CGFloat { span / CGFloat(max(duration, 0.1)) }
    func x(_ t: Double) -> CGFloat { Self.pad + CGFloat(t) * pointsPerSecond }
    func t(_ x: CGFloat) -> Double { Double((x - Self.pad) / pointsPerSecond) }
}

/// The video laid out in time: the arrival, each framing the camera lands on
/// with the move that carries it there, and the voiceover with its words.
/// Drag a framing to move its landing; it snaps to the words. Drag the voice
/// to slide it under the picture.
struct TimelineView: View {
    @Bindable var session: OOOSession

    static let ruler: CGFloat = 22
    static let camera: CGFloat = 62
    static let voice: CGFloat = 50
    static let height: CGFloat = ruler + camera + voice + 18

    var body: some View {
        GeometryReader { geo in
            let scale = TimeScale(width: geo.size.width, duration: session.timelineLength)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    RulerView(session: session, scale: scale)
                        .frame(height: Self.ruler)
                    CameraLane(session: session, scale: scale)
                        .frame(height: Self.camera)
                        .padding(.top, 4)
                    VoiceLane(session: session, scale: scale)
                        .frame(height: Self.voice)
                        .padding(.top, 6)
                    Spacer(minLength: 0)
                }
                Playhead(clock: session.clock, scale: scale)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: Self.height)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Ruler

struct RulerView: View {
    let session: OOOSession
    let scale: TimeScale
    @State private var wasPlaying: Bool?

    var body: some View {
        Canvas { ctx, size in
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60]
            let label = steps.first { CGFloat($0) * scale.pointsPerSecond >= 46 } ?? 60
            let minor = steps.last { $0 < label && CGFloat($0) * scale.pointsPerSecond >= 8 } ?? label
            var t = 0.0
            while t <= scale.duration + 1e-6 {
                let x = scale.x(t)
                let major = abs((t / label).rounded() * label - t) < 1e-6
                let h: CGFloat = major ? 7 : 4
                ctx.fill(Path(CGRect(x: x - 0.5, y: size.height - h, width: 1, height: h)),
                         with: .color(Color.secondary.opacity(major ? 0.7 : 0.35)))
                if major {
                    let text = ctx.resolve(Text(rulerLabel(t)).font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary))
                    ctx.draw(text, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
                t += minor
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if wasPlaying == nil { wasPlaying = session.clock.playing; session.clock.playing = false }
                session.clock.time = min(max(scale.t(g.location.x), 0), session.clock.duration)
            }
            .onEnded { _ in
                session.clock.playing = wasPlaying ?? false
                wasPlaying = nil
            })
        .help("Drag to scrub")
    }

    private func rulerLabel(_ t: Double) -> String {
        let s = Int(t.rounded())
        return t < 60 ? (t == t.rounded() ? "\(s)s" : String(format: "%.1fs", t)) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct Playhead: View {
    @Bindable var clock: PlaybackClock
    let scale: TimeScale

    var body: some View {
        let x = scale.x(min(clock.time, clock.duration))
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.camera).frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .offset(x: x - 0.75)
            Path { p in
                p.move(to: CGPoint(x: x - 5, y: 0))
                p.addLine(to: CGPoint(x: x + 5, y: 0))
                p.addLine(to: CGPoint(x: x, y: 7))
                p.closeSubpath()
            }
            .fill(Theme.camera)
        }
    }
}

// MARK: - Camera lane

struct CameraLane: View {
    @Bindable var session: OOOSession
    let scale: TimeScale

    var body: some View {
        let beats = session.choreography.beats
        let arrive = session.project.arrive
        ZStack(alignment: .topLeading) {
            // Empty track: double-click to add a framing there.
            Rectangle().fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { v in
                    session.addShot(at: scale.t(v.location.x))
                })
                .simultaneousGesture(SpatialTapGesture().onEnded { v in
                    session.clock.playing = false
                    session.clock.time = min(max(scale.t(v.location.x), 0), session.clock.duration)
                })
            if arrive.kind != .none {
                ArriveBlock(session: session, width: max(scale.x(arrive.end) - scale.x(0) - 2, 8))
                    .offset(x: scale.x(0))
            }
            ForEach(Array(beats.enumerated()), id: \.offset) { i, beat in
                let x0 = scale.x(beat.depart), x1 = scale.x(beat.land), x2 = scale.x(beat.leave)
                if beat.shot.move != .cut && x1 - x0 > 2 && i > 0 {
                    TravelRamp(selected: isSelected(beat))
                        .frame(width: x1 - x0, height: TimelineView.camera - 16)
                        .offset(x: x0, y: 8)
                        .allowsHitTesting(false)
                }
                BeatBlock(session: session, beat: beat, number: number(beat), scale: scale, selected: isSelected(beat))
                    .frame(width: max(x2 - x1 - 2, 6), height: TimelineView.camera)
                    .offset(x: x1)
            }
        }
    }

    private func isSelected(_ beat: Choreography.Beat) -> Bool {
        switch session.selection {
        case .overview: return beat.isOverview
        case .shot(let id): return !beat.isOverview && beat.shot.id == id
        }
    }

    private func number(_ beat: Choreography.Beat) -> Int? {
        guard !beat.isOverview else { return nil }
        return session.index(of: beat.shot.id).map { $0 + 1 }
    }
}

/// The move into a framing: a ramp that swells as the camera gathers speed and lands.
struct TravelRamp: View {
    let selected: Bool

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Path { p in
                p.move(to: CGPoint(x: 0, y: h / 2 - 1))
                p.addCurve(to: CGPoint(x: w, y: 0), control1: CGPoint(x: w * 0.45, y: h / 2 - 1), control2: CGPoint(x: w * 0.7, y: 0))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addCurve(to: CGPoint(x: 0, y: h / 2 + 1), control1: CGPoint(x: w * 0.7, y: h), control2: CGPoint(x: w * 0.45, y: h / 2 + 1))
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [Theme.camera.opacity(0), Theme.camera.opacity(selected ? 0.42 : 0.24)],
                                 startPoint: .leading, endPoint: .trailing))
        }
    }
}

struct ArriveBlock: View {
    @Bindable var session: OOOSession
    let width: CGFloat
    @State private var hover = false

    var body: some View {
        let selected = session.selection == .overview
        HStack(spacing: 5) {
            Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
            if width > 54 {
                Text(session.project.arrive.kind.title).textStyle(.label).lineLimit(1)
            }
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .frame(width: width, height: TimelineView.camera - 20)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well.opacity(hover ? 1 : 0.75)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(selected ? Theme.camera.opacity(0.8) : Color.clear, lineWidth: 1.2))
        .offset(y: 10)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            session.select(.overview, show: false)
            session.clock.playing = false
            session.clock.time = 0
            session.clock.playing = true
        }
        .help("The arrival: \(session.project.arrive.kind.summary) Click to watch it again.")
    }
}

/// A framing on the timeline: what the camera sees, in miniature, for as long
/// as it holds there.
struct BeatBlock: View {
    @Bindable var session: OOOSession
    let beat: Choreography.Beat
    let number: Int?
    let scale: TimeScale
    let selected: Bool
    @State private var hover = false
    @State private var dragStart: Double?
    @State private var snappedTo: Double?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let thumbH = TimelineView.camera - 14
            let thumbW = min(thumbH * CGFloat(session.project.canvasAspect), max(w - 6, 0))
            HStack(spacing: 7) {
                if thumbW > 8, let img = session.thumbnail(beat.isOverview ? session.project.overview.frame : beat.shot.frame) {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbW, height: thumbH)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                }
                if w - thumbW > 56 {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if let number { Text("\(number)").textStyle(.badge).foregroundStyle(selected ? Theme.camera : .secondary) }
                            Text(title).textStyle(.label).foregroundStyle(.primary).lineLimit(1)
                        }
                        Text(detail).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(width: w, height: g.size.height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.cameraSoft : (hover ? Theme.raised : Theme.raised.opacity(0.7))))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Theme.camera : Theme.hairline, lineWidth: selected ? 1.5 : 1))
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(drag)
        .simultaneousGesture(TapGesture().onEnded {
            session.select(beat.isOverview ? .overview : .shot(beat.shot.id))
        })
        .help(beat.isOverview ? "The whole slide" : "\(title). Drag to move when the camera lands; it snaps to the words.")
    }

    private var title: String {
        if beat.isOverview { return "Whole slide" }
        return Director.spokenLabel(beat.shot.label) ?? "Shot \(number ?? 0)"
    }

    private var detail: String {
        if beat.isOverview { return session.project.ending == .pullBack && beat.land > 1 ? "Pull back" : "Overview" }
        var parts = [beat.shot.move.title]
        if beat.shot.emphasis != .none { parts.append(beat.shot.emphasis.title) }
        if let cue = beat.shot.cue, !cue.isEmpty { parts.append("“\(cue.split(separator: " ").prefix(3).joined(separator: " "))”") }
        return parts.joined(separator: " · ")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { g in
                guard !beat.isOverview else { return }
                let id = beat.shot.id
                if dragStart == nil {
                    dragStart = beat.shot.time
                    session.holdTimeline(true)
                    session.beginEdit("Move Shot")
                    if session.selection != .shot(id) { session.select(.shot(id), show: false) }
                }
                guard let start = dragStart else { return }
                var t = start + Double(g.translation.width / scale.pointsPerSecond)
                t = max(t, session.project.arrive.end + 0.3)
                // Landings are magnetic: just before a word, or on the playhead.
                // Option moves freely.
                var snap: Double?
                if !NSEvent.modifierFlags.contains(.option) {
                    var targets = (session.project.voice?.words ?? []).map { $0.start - 0.15 }
                    targets.append(session.clock.time)
                    let near = targets.min { abs($0 - t) < abs($1 - t) }
                    if let near, abs(CGFloat(near - t) * scale.pointsPerSecond) <= 6 { snap = near }
                }
                if snap != snappedTo {
                    if snap != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    snappedTo = snap
                }
                let final = snap ?? t
                session.liveShot(id) { $0.time = final }
            }
            .onEnded { _ in
                guard dragStart != nil else { return }
                dragStart = nil
                snappedTo = nil
                session.commitEdit("Move Shot")
                session.holdTimeline(false)
            }
    }
}

// MARK: - Voice lane

struct VoiceLane: View {
    @Bindable var session: OOOSession
    let scale: TimeScale
    @State private var dragStart: Double?
    @State private var targeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let voice = session.project.voice {
                let x0 = scale.x(voice.offset)
                let w = CGFloat(voice.duration) * scale.pointsPerSecond
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.voice.opacity(0.1))
                    if let wave = session.waveform {
                        WaveformShape(waveform: wave)
                            .fill(Theme.voice.opacity(0.75))
                            .padding(.top, 16)
                            .padding(.bottom, 3)
                    } else {
                        Text("Reading…").textStyle(.caption).foregroundStyle(.secondary).padding(6)
                    }
                    WordsView(words: voice.words ?? [], offset: voice.offset, landings: session.choreography.landings, scale: scale)
                        .frame(width: scale.width, height: 14)
                        .offset(x: -x0)
                }
                .frame(width: max(w, 4), height: TimelineView.voice)
                .offset(x: x0)
                .contentShape(Rectangle())
                .gesture(drag)
                .help("\(voice.name). Drag to slide the voice under the picture.")
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    Text("Record your voiceover first, then drop it here. Each move will land just before you say its words.")
                        .textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose Voiceover…") { OOOCommands.chooseVoice(session) }
                        .buttonStyle(QuietButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: TimelineView.voice)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(targeted ? Theme.camera : Color.secondary.opacity(0.35)))
                .padding(.horizontal, TimeScale.pad)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadDropped(providers) { urls in
                if let url = urls.first { session.importVoice(url) }
            }
            return true
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard let voice = session.project.voice else { return }
                if dragStart == nil {
                    dragStart = voice.offset
                    session.holdTimeline(true)
                    session.beginEdit("Move Voiceover")
                }
                let o = (dragStart ?? 0) + Double(g.translation.width / scale.pointsPerSecond)
                session.setVoiceOffset(min(max(o, -voice.duration + 0.5), 30), live: true)
            }
            .onEnded { _ in
                dragStart = nil
                session.commitEdit("Move Voiceover")
                session.holdTimeline(false)
            }
    }
}

/// The voice's peaks, mirrored about the middle.
struct WaveformShape: Shape {
    let waveform: Waveform

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let peaks = waveform.peaks
        guard !peaks.isEmpty, rect.width > 1 else { return p }
        let columns = max(Int(rect.width / 2), 1)
        let mid = rect.midY
        for c in 0..<columns {
            let a = Double(c) / Double(columns) * waveform.duration
            let b = Double(c + 1) / Double(columns) * waveform.duration
            let h = max(CGFloat(waveform.peak(from: a, to: b)) * rect.height / 2, 0.5)
            p.addRoundedRect(in: CGRect(x: rect.minX + CGFloat(c) * 2, y: mid - h, width: 1.2, height: 2 * h),
                             cornerSize: CGSize(width: 0.6, height: 0.6))
        }
        return p
    }
}

/// The recognised words, where they are said. Words the camera lands on are
/// marked in its colour.
struct WordsView: View {
    let words: [SpokenWord]
    let offset: Double
    let landings: [Double]
    let scale: TimeScale

    var body: some View {
        Canvas { ctx, size in
            var lastEnd: CGFloat = -.greatestFiniteMagnitude
            var landing = landings.sorted().makeIterator()
            var next = landing.next()
            for w in words {
                while let n = next, n < w.start - 0.6 { next = landing.next() }
                let cued = next.map { w.start - $0 >= -0.05 && w.start - $0 <= 0.6 } ?? false
                let x = scale.x(w.start)
                guard x > lastEnd + 3 || cued else { continue }
                let text = ctx.resolve(Text(w.text).font(.system(size: 9.5, weight: cued ? .semibold : .regular))
                    .foregroundColor(cued ? Theme.camera : .secondary))
                let m = text.measure(in: CGSize(width: 200, height: size.height))
                ctx.draw(text, at: CGPoint(x: x + 1, y: 1), anchor: .topLeading)
                lastEnd = x + m.width
                if cued { next = landing.next() }
            }
        }
        .allowsHitTesting(false)
    }
}
