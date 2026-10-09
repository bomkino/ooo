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

/// The video laid out in time, as clips edge to edge: the opening, each
/// framing the camera goes to (its move, then its hold, each with its
/// length), the slide changes and the ending. Grab a clip's right edge to
/// hold it longer or shorter, the line inside it to change its move, its
/// middle to change when it lands; everything after slides along and keeps
/// its own length. Below, the space for you and the voiceover with its words.
struct TimelineView: View {
    @Bindable var session: OOOSession
    @State private var pinchFrom: Double?

    static let ruler: CGFloat = 22
    static let camera: CGFloat = 62
    static let room: CGFloat = 22
    static let voice: CGFloat = 50
    static let height: CGFloat = ruler + camera + room + voice + 22

    var body: some View {
        GeometryReader { geo in
            let zoom = session.isTaking ? 1 : max(session.timelineZoom, 1)
            let visible = max(geo.size.width, 1)
            let scale = TimeScale(width: visible * CGFloat(zoom), duration: session.timelineLength)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: zoom > 1) {
                    ZStack(alignment: .topLeading) {
                        if zoom > 1 {
                            // Places to scroll to, a quarter of the view apart, so the playhead can be followed.
                            HStack(spacing: 0) {
                                ForEach(0..<Int((scale.width / (visible / 4)).rounded(.up)), id: \.self) { i in
                                    Color.clear.frame(width: visible / 4, height: 1).id(i)
                                }
                            }
                            .allowsHitTesting(false)
                        }
                        VStack(spacing: 0) {
                            RulerView(session: session, scale: scale)
                                .frame(height: Self.ruler)
                            CameraLane(session: session, scale: scale)
                                .frame(height: Self.camera)
                                .padding(.top, 4)
                                .zIndex(1)
                            RoomLane(session: session, scale: scale)
                                .frame(height: Self.room)
                                .padding(.top, 4)
                            VoiceLane(session: session, scale: scale)
                                .frame(height: Self.voice)
                                .padding(.top, 6)
                            Spacer(minLength: 0)
                        }
                        Playhead(clock: session.clock, scale: scale)
                            .allowsHitTesting(false)
                    }
                    .frame(width: scale.width, height: geo.size.height, alignment: .topLeading)
                }
                .scrollDisabled(zoom <= 1)
                .background(PlayheadFollow(clock: session.clock, scale: scale, visible: visible, zoom: zoom, proxy: proxy))
            }
        }
        .frame(height: Self.height)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Hairline() }
        // A take runs on its own clock; nothing on the timeline can be changed under it.
        .allowsHitTesting(!session.isTaking)
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in
                if pinchFrom == nil { pinchFrom = session.timelineZoom }
                session.timelineZoom = min(max((pinchFrom ?? 1) * Double(v.magnification), 1), 40)
            }
            .onEnded { _ in pinchFrom = nil })
    }
}

/// Zoomed in, keeps the playhead in view while the video plays, and finds
/// it again when the zoom changes.
private struct PlayheadFollow: View {
    @Bindable var clock: PlaybackClock
    let scale: TimeScale
    let visible: CGFloat
    let zoom: Double
    let proxy: ScrollViewProxy
    @State private var lead: CGFloat = 0

    var body: some View {
        let x = scale.x(min(clock.time, clock.duration))
        let quarter = visible / 4
        let off = x < lead + 8 || x > lead + visible - 24
        Color.clear
            .onChange(of: off && clock.playing && zoom > 1) { _, follow in
                if follow { show(x, quarter) }
            }
            .onChange(of: zoom) { _, z in
                if z > 1 { show(x, quarter) } else { lead = 0 }
            }
    }

    private func show(_ x: CGFloat, _ quarter: CGFloat) {
        let i = max(Int(x / quarter) - 1, 0)
        lead = CGFloat(i) * quarter
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(i, anchor: .leading) }
    }
}

// MARK: - Ruler

struct RulerView: View {
    let session: OOOSession
    let scale: TimeScale
    @State private var wasPlaying: Bool?

    var body: some View {
        let total = session.clock.duration
        Canvas { ctx, size in
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60]
            let label = steps.first { CGFloat($0) * scale.pointsPerSecond >= 46 } ?? 60
            let minor = steps.last { $0 < label && CGFloat($0) * scale.pointsPerSecond >= 8 } ?? label
            let end = scale.x(total)
            var t = 0.0
            while t <= scale.duration + 1e-6 {
                let x = scale.x(t)
                let major = abs((t / label).rounded() * label - t) < 1e-6
                let h: CGFloat = major ? 7 : 4
                ctx.fill(Path(CGRect(x: x - 0.5, y: size.height - h, width: 1, height: h)),
                         with: .color(Color.secondary.opacity(major ? 0.7 : 0.35)))
                // The video's length has the last word at its end.
                if major, x < end - 52 || x > end + 8 {
                    let text = ctx.resolve(Text(rulerLabel(t)).font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary))
                    ctx.draw(text, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
                t += minor
            }
            if !session.isTaking {
                ctx.fill(Path(CGRect(x: end - 0.75, y: 2, width: 1.5, height: size.height - 2)), with: .color(Color.primary.opacity(0.5)))
                let text = ctx.resolve(Text(secondsLabel(total)).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(.primary))
                ctx.draw(text, at: CGPoint(x: end - 4, y: 2), anchor: .topTrailing)
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
        .help("The video runs \(secondsLabel(total)). Drag to scrub.")
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

/// What a timing drag shows above the lane while the hand is down.
struct TimingBubble: Equatable {
    var x: CGFloat
    var text: String
}

/// Where a clip being put before or after the others would go.
struct ClipDrop: Equatable {
    var x: CGFloat
}

struct CameraLane: View {
    @Bindable var session: OOOSession
    let scale: TimeScale
    @State private var bubble: TimingBubble?
    @State private var drop: ClipDrop?

    var body: some View {
        let clips = session.choreography.clips
        ZStack(alignment: .topLeading) {
            // Past the end: click to scrub.
            Rectangle().fill(Color.clear)
                .contentShape(Rectangle())
                .simultaneousGesture(SpatialTapGesture().onEnded { v in
                    session.clock.playing = false
                    session.clock.time = min(max(scale.t(v.location.x), 0), session.clock.duration)
                })
            // By place, not value: a clip being dragged keeps its view.
            ForEach(Array(clips.enumerated()), id: \.offset) { k, clip in
                ClipView(session: session, clip: clip, index: k, scale: scale, selected: isSelected(clip),
                         bubble: $bubble, drop: $drop)
                    .offset(x: scale.x(clip.start))
            }
            // The card changing slide, over the clip it changes in.
            ForEach(Array(session.choreography.changes.enumerated()), id: \.offset) { _, change in
                ChangeMarker(session: session, change: change, scale: scale)
                    .offset(x: scale.x(change.start), y: TimelineView.camera - 21)
            }
            // Marks drawn on the card, along the top, each as long as it takes to draw.
            ForEach(session.project.marks ?? []) { mark in
                MarkPin(session: session, mark: mark, scale: scale)
                    .offset(x: scale.x(mark.time), y: 3)
            }
            if let drop {
                Capsule().fill(Theme.camera)
                    .frame(width: 3, height: TimelineView.camera + 6)
                    .offset(x: drop.x - 1.5, y: -3)
                    .allowsHitTesting(false)
            }
            if let bubble {
                Text(bubble.text)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Capsule().fill(Theme.accent))
                    .fixedSize()
                    .alignmentGuide(HorizontalAlignment.leading) { d in d.width / 2 }
                    .offset(x: min(max(bubble.x, 60), scale.width - 60), y: -21)
                    .allowsHitTesting(false)
            }
        }
        // In Live the take sets the timing; the lane only shows it.
        .allowsHitTesting(session.mode != .live)
    }

    private func isSelected(_ clip: TimelineClip) -> Bool {
        switch session.selection {
        case .overview: return clip.kind == .opening
        case .shot(let id): return clip.shotID == id
        }
    }
}

/// One clip: the move into a framing, swelling as the camera gathers speed,
/// then the hold, with what the camera sees in miniature. Each part says
/// how long it lasts.
struct ClipView: View {
    @Bindable var session: OOOSession
    let clip: TimelineClip
    let index: Int
    let scale: TimeScale
    let selected: Bool
    @Binding var bubble: TimingBubble?
    @Binding var drop: ClipDrop?
    @State private var hover: Zone?
    @State private var drag: Drag?

    enum Zone { case seam, end, body }

    /// A drag, and the clip as it was when the hand went down.
    struct Drag {
        var zone: Zone
        var name: String
        var start: Double
        var land: Double
        var end: Double
        var lands: Double
        var range: ClosedRange<Double>
        var snapped: Double?
        var reorder: Bool
        var slot: Int?
        var dx: CGFloat = 0
    }

    private var beat: Choreography.Beat? {
        let beats = session.choreography.beats
        guard !beats.isEmpty else { return nil }
        let i = min(max(clip.beats.upperBound - 1, 0), beats.count - 1)
        return beats[i]
    }

    var body: some View {
        let w = max(scale.x(clip.end) - scale.x(clip.start), 4)
        let r = min(max(scale.x(clip.land) - scale.x(clip.start), 0), w)
        ZStack(alignment: .topLeading) {
            if r > 2 { head(width: r) }
            HoldBlock(session: session, clip: clip, beat: beat, number: number, title: title, detail: detail,
                      selected: selected, lifted: drag?.reorder == true)
                .frame(width: max(w - r - 2, 3), height: TimelineView.camera)
                .offset(x: r)
            if canEnd, hover == .end || drag?.zone == .end { grip.offset(x: w - 5) }
            if canSeam, r > 10, hover == .seam || drag?.zone == .seam { grip.offset(x: r - 2) }
        }
        .frame(width: w, height: TimelineView.camera, alignment: .topLeading)
        .contentShape(Rectangle())
        .offset(x: reorderOffset)
        .zIndex(drag?.reorder == true ? 2 : 0)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let z = zone(at: p.x, width: w, ramp: r)
                if hover != z { hover = z }
                if drag == nil { cursor(z).set() }
            case .ended:
                hover = nil
                if drag == nil { NSCursor.arrow.set() }
            }
        }
        .gesture(dragGesture)
        .simultaneousGesture(TapGesture().onEnded {
            // A click rests on it; a double-click plays it.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { session.watchClip(index) } else { session.selectClip(index) }
        })
        .contextMenu { ClipMenu(session: session, clip: clip, index: index) }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityValue("Moves in over \(secondsLabel(clip.move)), holds \(secondsLabel(clip.hold))")
    }

    // MARK: Look

    /// The move into the clip: the slide arriving for the opening, a ramp for the rest.
    @ViewBuilder private func head(width r: CGFloat) -> some View {
        if clip.kind == .opening {
            HStack(spacing: 5) {
                Image(systemName: session.project.arrive.kind.symbol).font(.system(size: 10, weight: .semibold))
                if r > 124 { Text(session.project.arrive.kind.title).textStyle(.label).lineLimit(1) }
                if r > 64 {
                    Text(secondsLabel(clip.move)).textStyle(.data).foregroundStyle(.secondary).fixedSize()
                } else if r > 44 {
                    Text(shortSeconds(clip.move)).textStyle(.data).foregroundStyle(.secondary).fixedSize()
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(width: max(r - 2, 1), height: TimelineView.camera - 20)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well.opacity(hover == .body ? 1 : 0.75)))
            .offset(y: 10)
        } else {
            ZStack {
                TravelRamp(selected: selected)
                    .frame(width: r, height: TimelineView.camera - 16)
                if r > 46 {
                    Text(secondsLabel(clip.move)).textStyle(.data).foregroundStyle(.secondary).fixedSize()
                        .offset(x: r * 0.12, y: -1)
                } else if r > 26 {
                    Text(shortSeconds(clip.move)).textStyle(.data).foregroundStyle(.secondary).fixedSize()
                        .offset(x: r * 0.1, y: -1)
                }
            }
            .frame(width: r, height: TimelineView.camera - 16)
            .offset(y: 8)
        }
    }

    private var grip: some View {
        Capsule().fill(Theme.camera)
            .frame(width: 4, height: 26)
            .offset(y: (TimelineView.camera - 26) / 2)
            .allowsHitTesting(false)
    }

    /// A clip being put elsewhere follows the hand.
    private var reorderOffset: CGFloat { drag?.reorder == true ? drag?.dx ?? 0 : 0 }

    private var several: Bool { session.project.slideCount > 1 }

    private var number: Int? {
        guard let id = clip.shotID else { return nil }
        return session.index(of: id).map { $0 + 1 }
    }

    private var title: String {
        switch clip.kind {
        case .opening: return several ? "Slide 1" : "Whole slide"
        case .shot: return beat.flatMap { Director.spokenLabel($0.shot.label) } ?? "Shot \(number ?? 0)"
        case .change(let to): return "Slide \(to + 1)"
        case .home: return "Slide 1"
        case .ending: return "Ending"
        }
    }

    private var detail: String {
        switch clip.kind {
        case .opening: return "Opening"
        case .change: return beat?.melts == true ? "Melts in" : "Turns over"
        case .home: return "Turns back"
        case .ending: return session.project.ending.title
        case .shot: break
        }
        guard let b = beat else { return "" }
        var parts = [b.melts ? "Melts in" : b.shot.move.title]
        if b.shot.emphasis != .none { parts.append(b.shot.emphasis.title) }
        if let cue = b.shot.cue, !cue.isEmpty { parts.append("“\(cue.split(separator: " ").prefix(3).joined(separator: " "))”") }
        return parts.joined(separator: " · ")
    }

    private var help: String {
        let lasts = clip.move > 0.05
            ? "Moves in over \(secondsLabel(clip.move)), holds \(secondsLabel(clip.hold))."
            : "Holds \(secondsLabel(clip.hold))."
        switch clip.kind {
        case .shot:
            return "\(title). \(lasts) Drag its right edge to hold longer or shorter, the line where it lands to change its move, "
                + "or its middle to change when it lands. ⌘-drag to put it before or after another. Double-click to watch it."
        case .opening:
            return "The opening: the slide arrives over \(secondsLabel(clip.move)), then rests whole for \(secondsLabel(clip.hold)). "
                + "Drag the line where it lands to change the arrival, the right edge to rest longer. Double-click to watch it."
        case .ending:
            return "The ending: \(session.project.ending.title). The video runs \(secondsLabel(clip.end)). Drag the right edge to make it longer or shorter."
        case .change, .home:
            return "\(title), \(detail.lowercased()). \(lasts) Drag the right edge to rest on it longer. Double-click to watch it."
        }
    }

    // MARK: Hands

    private var canEnd: Bool { true }

    private var canSeam: Bool {
        switch clip.kind {
        case .opening: return session.project.arrive.kind != .none
        case .shot: return beat?.shot.move != .cut
        default: return false
        }
    }

    private func zone(at x: CGFloat, width w: CGFloat, ramp r: CGFloat) -> Zone {
        if canEnd, x >= w - 8 { return .end }
        if canSeam, r > 10, abs(x - r) <= 5 { return .seam }
        return .body
    }

    private func cursor(_ z: Zone) -> NSCursor {
        switch z {
        case .end, .seam: return .resizeLeftRight
        case .body: return clip.shotID != nil ? .openHand : .arrow
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { g in
                if drag == nil { begin() }
                guard var d = drag else { return }
                let dt = Double(g.translation.width / scale.pointsPerSecond)
                let free = NSEvent.modifierFlags.contains(.command)
                switch d.zone {
                case .end:
                    var e = d.end + dt
                    var snap: Double?
                    if !free {
                        snap = nearestWord(to: e, offset: 0)
                        e = snap ?? d.land + max(((e - d.land) * 10).rounded() / 10, 0)
                    }
                    feel(snap, &d)
                    let rolling = NSEvent.modifierFlags.contains(.option)
                    let k = index
                    session.timing { Timing.setEnd($0, clip: k, to: e, rolling: rolling) }
                    if let now = current {
                        let text = clip.kind == .ending ? "Video \(secondsLabel(now.end))"
                            : "Holds \(secondsLabel(now.hold))" + (rolling ? " · the next gives way" : "")
                        bubble = TimingBubble(x: scale.x(now.end), text: text)
                    }
                case .seam:
                    var l = d.land + dt
                    if !free { l = d.start + ((l - d.start) * 10).rounded() / 10 }
                    let k = index
                    session.timing { Timing.setLand($0, clip: k, to: l) }
                    if let now = current {
                        let text = clip.kind == .opening ? "Arrives over \(secondsLabel(now.move))" : "Moves in over \(secondsLabel(now.move))"
                        bubble = TimingBubble(x: scale.x(now.land), text: text)
                    }
                case .body where d.reorder:
                    dragOrder(g.translation.width, &d)
                case .body:
                    guard let id = clip.shotID else { break }
                    var t = min(max(d.lands + dt, d.range.lowerBound), d.range.upperBound)
                    var snap: Double?
                    if !free {
                        snap = nearestWord(to: t, offset: -0.15)
                        t = snap ?? t
                    }
                    feel(snap, &d)
                    let at = t
                    session.timing { p in
                        var q = p
                        q.setLanding(id, to: at)
                        return q
                    }
                    let word = snap.flatMap { s in session.project.voice?.words?.first { abs($0.start - 0.15 - s) < 1e-6 }?.text }
                    bubble = TimingBubble(x: scale.x(current?.land ?? at),
                                          text: "Lands at \(secondsLabel(current?.land ?? at))" + (word.map { " · “\($0)”" } ?? ""))
                }
                drag = d
            }
            .onEnded { _ in
                guard let d = drag else { return }
                if d.reorder {
                    finishOrder(d)
                } else if d.zone != .body || clip.shotID != nil {
                    session.endTiming(d.name)
                }
                drag = nil
                bubble = nil
                drop = nil
                cursor(hover ?? .body).set()
            }
    }

    private func begin() {
        let z = hover ?? .body
        let clips = session.choreography.clips
        let reorder = z == .body && clip.shotID != nil && NSEvent.modifierFlags.contains(.command)
        let name: String
        switch z {
        case .end: name = clip.kind == .ending ? "Video Length" : "Hold"
        case .seam: name = clip.kind == .opening ? "Opening Length" : "Move Length"
        case .body: name = "Move Shot"
        }
        // A landing stays between its neighbours' landings.
        let lo = (index > 0 ? clips[index - 1].land : 0) + 0.4
        let next = clips.indices.contains(index + 1) && clips[index + 1].kind != .ending ? clips[index + 1].land - 0.4 : .greatestFiniteMagnitude
        let lands = clip.shotID.flatMap { id in session.project.shots.first { $0.id == id }?.time } ?? clip.land
        drag = Drag(zone: z, name: name, start: clip.start, land: clip.land, end: clip.end, lands: lands,
                    range: lo...max(next, lo), snapped: nil, reorder: reorder, slot: nil)
        if reorder {
            NSCursor.closedHand.set()
            session.selectClip(index)
        } else if z != .body || clip.shotID != nil {
            if let id = clip.shotID, session.selection != .shot(id) { session.select(.shot(id), show: false) }
            if z == .body { NSCursor.closedHand.set() }
            session.beginTiming(name)
        }
    }

    /// The clip as it plays now, mid-drag.
    private var current: TimelineClip? {
        let clips = session.choreography.clips
        return clips.indices.contains(index) ? clips[index] : nil
    }

    /// The word nearest `t` within a few points, as a time `offset` from when it is said.
    private func nearestWord(to t: Double, offset: Double) -> Double? {
        let targets = (session.project.voice?.words ?? []).map { $0.start + offset }
        guard let near = targets.min(by: { abs($0 - t) < abs($1 - t) }),
              abs(CGFloat(near - t) * scale.pointsPerSecond) <= 6 else { return nil }
        return near
    }

    /// A small knock in the trackpad as an edge takes hold of a word.
    private func feel(_ snap: Double?, _ d: inout Drag) {
        if snap != d.snapped, snap != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        d.snapped = snap
    }

    // MARK: Order

    /// The other shots on this clip's slide, by their place on the timeline.
    private func peers(_ clips: [TimelineClip]) -> [Int] {
        clips.indices.filter { $0 != index && clips[$0].shotID != nil && clips[$0].page == clip.page }
    }

    private func dragOrder(_ dx: CGFloat, _ d: inout Drag) {
        let clips = session.choreography.clips
        let others = peers(clips)
        guard !others.isEmpty else { return }
        let mid = { (c: TimelineClip) in (scale.x(c.start) + scale.x(c.end)) / 2 }
        let centre = mid(clip) + dx
        let slot = others.filter { mid(clips[$0]) < centre }.count
        d.slot = slot
        d.dx = dx
        let x = slot < others.count ? scale.x(clips[others[slot]].start) : scale.x(clips[others[others.count - 1]].end)
        drop = ClipDrop(x: x)
        bubble = TimingBubble(x: x, text: slot == 0 ? "First on the slide" : "After \(clipTitle(clips[others[slot - 1]]))")
    }

    private func finishOrder(_ d: Drag) {
        let clips = session.choreography.clips
        guard let id = clip.shotID, let slot = d.slot else { return }
        let others = peers(clips)
        var order = others.compactMap { clips[$0].shotID }
        order.insert(id, at: min(slot, order.count))
        let now = clips.filter { $0.page == clip.page }.compactMap(\.shotID)
        if order != now { session.reorderShots(order) }
    }

    private func clipTitle(_ c: TimelineClip) -> String {
        guard let id = c.shotID else { return "it" }
        let shot = session.project.shots.first { $0.id == id }
        return Director.spokenLabel(shot?.label) ?? "shot \((session.index(of: id) ?? 0) + 1)"
    }
}

/// The part of a clip where the camera holds: what it sees, its name, and how long it stays.
private struct HoldBlock: View {
    let session: OOOSession
    let clip: TimelineClip
    let beat: Choreography.Beat?
    let number: Int?
    let title: String
    let detail: String
    let selected: Bool
    let lifted: Bool

    /// Room for "2.5 s", and for "2.5" alone.
    private static let full: CGFloat = 34
    private static let short: CGFloat = 18

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let inner = w - 9
            let thumbH = TimelineView.camera - 14
            let thumbW = thumbH * CGFloat(session.project.canvasAspect)
            // How long it holds comes first; the picture only where both fit.
            let thumb = inner - thumbW - 6 >= Self.short ? beat.flatMap { session.thumbnail($0.shot.frame, page: $0.page) } : nil
            let room = inner - (thumb != nil ? thumbW + 6 : 0)
            HStack(spacing: 6) {
                if let thumb {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbW, height: thumbH)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                }
                if room >= Self.full + 64 {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            badge
                            Text(title).textStyle(.label).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 4)
                            length(short: false)
                        }
                        Text(detail).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if room >= Self.full + ((number ?? 0) > 9 ? 20 : 14) {
                    HStack(spacing: 4) {
                        badge
                        length(short: false)
                    }
                } else if room >= Self.full {
                    length(short: false)
                } else if room >= Self.short {
                    length(short: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, room < Self.full ? 2 : 4)
            .padding(.trailing, 5)
            .frame(width: w, height: g.size.height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.cameraSoft : Theme.raised.opacity(clip.shotID == nil ? 0.45 : 0.75)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Theme.camera : Theme.hairline, lineWidth: selected ? 1.5 : 1))
            .shadow(color: .black.opacity(lifted ? 0.3 : 0), radius: 6, y: 2)
        }
    }

    /// How long the camera holds here; without the "s" where room is short.
    private func length(short: Bool) -> some View {
        Text(short ? shortSeconds(clip.hold) : secondsLabel(clip.hold))
            .textStyle(.data)
            .foregroundStyle(selected ? Theme.camera : Color.secondary)
            .fixedSize()
    }

    @ViewBuilder private var badge: some View {
        if let number { Text("\(number)").textStyle(.badge).foregroundStyle(selected ? Theme.camera : .secondary).fixedSize() }
    }
}

/// Seconds as a bare number, for where "2.5 s" will not fit: 2.5, or 12 past ten.
func shortSeconds(_ t: Double) -> String {
    t < 9.95 ? String(format: "%.1f", t) : String(format: "%.0f", t)
}

/// A clip's right-click menu: what you would change about it, in its words.
struct ClipMenu: View {
    let session: OOOSession
    let clip: TimelineClip
    let index: Int

    var body: some View {
        switch clip.kind {
        case .shot(let id):
            let shot = session.project.shots.first { $0.id == id }
            Button("Watch It") { session.watchClip(index) }
            Menu("Hold For") {
                ForEach([1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) { s in
                    Button(secondsLabel(s)) { session.holdFor(clip: index, seconds: s) }
                }
            }
            Picker("Move", selection: session.choiceShot(id, \.move, fallback: .glide, "Move")) {
                ForEach(MoveKind.allCases) { Text($0.title).tag($0) }
            }
            Picker("Feel", selection: session.choiceShot(id, \.ease, fallback: .glide, "Feel")) {
                ForEach(EaseKind.allCases) { Text($0.title).tag($0) }
            }
            Picker("While It Holds", selection: session.choiceShot(id, \.emphasis, fallback: .none, "Emphasis")) {
                ForEach(Emphasis.allCases) { Text($0.title).tag($0) }
            }
            Button("Let OOO Time This Move") { session.autoTravel(id) }
                .disabled(shot?.travel == nil)
            Divider()
            Button("Move Earlier") { session.moveShot(id, by: -1) }
                .disabled(!session.canMoveShot(id, by: -1))
            Button("Move Later") { session.moveShot(id, by: 1) }
                .disabled(!session.canMoveShot(id, by: 1))
            Divider()
            Button("New Framing After It") { session.addShot(at: clip.end + 0.6) }
            Button("Duplicate") {
                session.select(.shot(id), show: false)
                session.duplicateSelectedShot()
            }
            Button("Delete", role: .destructive) {
                session.select(.shot(id), show: false)
                session.deleteSelectedShot()
            }
        case .opening:
            Button("Watch It") { session.watchClip(index) }
            Picker("Opening", selection: Binding(
                get: { session.project.arrive.kind },
                set: { kind in session.update("Opening") { $0.arrive = Arrive(kind: kind, intensity: $0.arrive.intensity) } })) {
                ForEach(ArriveKind.allCases) { Text($0.title).tag($0) }
            }
            Menu("Arrives Over") {
                ForEach([0.8, 1.2, 1.6, 2.4, 3.2], id: \.self) { s in
                    Button(secondsLabel(s)) { session.arriveOver(s) }
                }
            }
            .disabled(session.project.arrive.kind == .none)
            Menu("Rests Whole For") {
                ForEach([0.5, 1.0, 2.0, 3.0], id: \.self) { s in
                    Button(secondsLabel(s)) { session.holdFor(clip: index, seconds: s) }
                }
            }
            Divider()
            Button("New Framing Here") { session.addShot(at: clip.end + 0.6) }
        case .ending:
            Button("Watch It") { session.watchClip(index) }
            Picker("Ending", selection: session.choice(\.ending, "Ending")) {
                ForEach(Ending.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Fit the Moves and the Voice") { session.update("Length") { $0.length = nil } }
                .disabled(session.project.length == nil)
        case .change(let to):
            Button("Watch It") { session.watchClip(index) }
            if to > 0, to <= session.project.morePages.count {
                Picker("Change", selection: Binding(
                    get: { session.project.morePages[to - 1].change },
                    set: { session.setChange(to, $0) })) {
                    ForEach(PageChange.allCases) { Text($0.title).tag($0) }
                }
            }
            Menu("Rests Whole For") {
                ForEach([0.5, 1.0, 2.0, 3.0], id: \.self) { s in
                    Button(secondsLabel(s)) { session.holdFor(clip: index, seconds: s) }
                }
            }
            Divider()
            Button("New Framing Here") { session.addShot(at: clip.end + 0.6, page: to) }
        case .home:
            Button("Watch It") { session.watchClip(index) }
            Button("Don't Turn Back") { session.setHome(false) }
        }
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
                .contextMenu {
                    Button("Listen From the Start") {
                        session.clock.time = max(voice.offset - 0.3, 0)
                        session.clock.playing = true
                    }
                    Button("Cut the Moves to the Voice") { session.cutToVoice() }
                        .disabled(voice.words?.isEmpty ?? true)
                    Divider()
                    Button("Record Again…") { session.toggleRecording() }
                        .disabled(session.recorder.isActive)
                    Button("Replace…") { OOOCommands.chooseVoice(session) }
                    Divider()
                    Button("Remove Voiceover", role: .destructive) { session.removeVoice() }
                }
                .help("\(voice.name), \(secondsLabel(voice.duration)). Drag to slide the voice under the picture; right-click for more.")
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        Text("Talk it through as it plays, or drop in a recording. Each move will land just before you say its words.")
                            .fixedSize()
                        Text("Talk it through as it plays, or drop in a recording.").fixedSize()
                        Text("Talk it through as it plays.").lineLimit(1)
                    }
                    .textStyle(.caption).foregroundStyle(.secondary)
                    Button(session.recorder.isActive ? "Stop" : "Record") { session.toggleRecording() }
                        .buttonStyle(QuietButtonStyle())
                        .help("Counts you in, then records you as the video plays from the start (⌥⌘R)")
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
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
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
