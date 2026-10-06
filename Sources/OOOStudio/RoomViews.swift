import AppKit
import OOOCore
import OOOMotion
import SwiftUI

// MARK: - Inspector

/// Room for you: the stage rises into the top of the frame and leaves the
/// bottom clear, for you on camera.
struct RoomSection: View {
    @Bindable var session: OOOSession

    var body: some View {
        let lift = session.project.lift
        let on = !(lift?.isEmpty ?? true)
        InspectorSection("Room for you") {
            Text("Lifts the slide and its moves into the top of the frame and leaves the bottom clear for you, to lay your green-screen video over later. Add it where you talk; the stage rises and settles smoothly.")
                .textStyle(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Button("Whole Video") { session.addRoom(whole: true) }
                    .help("The stage stays up from the first frame to the last")
                Button("From the Playhead") { session.addRoom() }
                    .help("A stretch of about six seconds from the playhead. Drag its ends on the timeline.")
                Spacer(minLength: 0)
            }
            .buttonStyle(QuietButtonStyle())
            if on {
                Dial(session: session, label: "Room", value: session.roomBinding, range: Lift.roomRange, defaultValue: Lift.defaultRoom,
                     format: { "\(percent($0))% of the frame" }, undo: "Room for You")
                Toggle("Show where you'll be", isOn: $session.showRoom)
                    .toggleStyle(.checkbox)
                    .textStyle(.bodyCompact)
                ForEach(lift?.spans.sorted { $0.start < $1.start } ?? []) { span in
                    HStack {
                        Text(spanLabel(span)).textStyle(.data).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { session.removeRoom(span.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .help("Remove this stretch")
                    }
                }
            }
        }
    }

    private func spanLabel(_ s: LiftSpan) -> String {
        let from = s.start <= 0.05 ? "From the start" : "From \(secondsLabel(s.start))"
        return from + (s.end.map { " to \(secondsLabel($0))" } ?? " to the end")
    }
}

// MARK: - Timeline

/// Where the stage rises to leave room for you: a stretch per span, its
/// ends shaded where the stage is rising and settling.
struct RoomLane: View {
    @Bindable var session: OOOSession
    let scale: TimeScale

    var body: some View {
        let spans = session.project.lift?.spans ?? []
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { v in
                    session.addRoom(at: scale.t(v.location.x))
                })
            if spans.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.rectangle").font(.system(size: 10))
                    Text("Room for you: double-click to lift the stage here").textStyle(.caption).lineLimit(1)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, TimeScale.pad + 6)
                .frame(height: TimelineView.room)
                .allowsHitTesting(false)
            }
            ForEach(spans) { span in
                RoomBar(session: session, span: span, scale: scale)
            }
        }
        .frame(height: TimelineView.room)
    }
}

struct RoomBar: View {
    @Bindable var session: OOOSession
    let span: LiftSpan
    let scale: TimeScale
    @State private var drag: (start: Double, end: Double?)?
    @State private var hover = false

    var body: some View {
        let d = session.choreography.duration
        let x0 = scale.x(span.start), x1 = scale.x(span.end ?? d)
        let w = max(x1 - x0, 8)
        let ramp = min(CGFloat(Lift.rise) * scale.pointsPerSecond, w / 2)
        let rises = span.start > 0.05, settles = span.end != nil
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(stops: [
                    .init(color: Theme.voice.opacity(rises ? 0.06 : 0.32), location: 0),
                    .init(color: Theme.voice.opacity(0.32), location: rises ? ramp / w : 0),
                    .init(color: Theme.voice.opacity(0.32), location: settles ? 1 - ramp / w : 1),
                    .init(color: Theme.voice.opacity(settles ? 0.06 : 0.32), location: 1),
                ], startPoint: .leading, endPoint: .trailing))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Theme.voice.opacity(hover || drag != nil ? 0.9 : 0.5), lineWidth: 1)
            if w > 110 {
                Text("Room for you").textStyle(.caption).foregroundStyle(Theme.voice).lineLimit(1)
                    .padding(.leading, max(ramp, 6))
                    .allowsHitTesting(false)
            }
            // Ends: drag to change when the stage rises and settles.
            HStack(spacing: 0) {
                handle(edge: .leading)
                Spacer(minLength: 0)
                handle(edge: .trailing)
            }
        }
        .frame(width: w, height: TimelineView.room - 4)
        .offset(x: x0, y: 2)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(move)
        .contextMenu {
            Button("Rise from the First Frame") { session.update("Room for You") { p in p.liftSpan(span.id) { s in s.start = 0 } } }
            Button("Stay Up to the End") { session.update("Room for You") { p in p.liftSpan(span.id) { s in s.end = nil } } }
            Divider()
            Button("Remove") { session.removeRoom(span.id) }
        }
        .help("Room for you. Drag to move it, its ends to change when the stage rises and settles.")
    }

    private func handle(edge: HorizontalEdge) -> some View {
        Rectangle().fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let drag = begin()
                    let dt = Double(g.translation.width / scale.pointsPerSecond)
                    let d = session.choreography.duration
                    session.liveRoom(span.id) { s in
                        if edge == .leading {
                            let end = drag.end ?? d
                            s.start = min(max(drag.start + dt, 0), end - Lift.shortest)
                            if s.start < 0.1 { s.start = 0 }
                        } else {
                            let end = max((drag.end ?? d) + dt, drag.start + Lift.shortest)
                            s.end = end >= d - 0.1 ? nil : end
                        }
                    }
                }
                .onEnded { _ in end() })
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let drag = begin()
                let d = session.choreography.duration
                let length = (drag.end ?? d) - drag.start
                let dt = Double(g.translation.width / scale.pointsPerSecond)
                session.liveRoom(span.id) { s in
                    s.start = max(drag.start + dt, 0)
                    if drag.end != nil { s.end = s.start + length }
                }
            }
            .onEnded { _ in end() }
    }

    /// Where the stretch was when the drag began.
    private func begin() -> (start: Double, end: Double?) {
        if let drag { return drag }
        let origin = (start: span.start, end: span.end)
        drag = origin
        session.holdTimeline(true)
        session.beginEdit("Move Room for You")
        return origin
    }

    private func end() {
        guard drag != nil else { return }
        drag = nil
        session.commitEdit("Move Room for You")
        session.holdTimeline(false)
    }
}

extension OOOProject {
    /// Changes one of the stretches that leave room for you.
    mutating func liftSpan(_ id: UUID, _ change: (inout LiftSpan) -> Void) {
        guard var lift, let i = lift.spans.firstIndex(where: { $0.id == id }) else { return }
        change(&lift.spans[i])
        self.lift = lift
    }
}

// MARK: - Stage

/// Where you will be: the room left clear at the bottom of the frame, with
/// a quiet outline of a head and shoulders in it, showing as the stage
/// rises. On the stage only; never exported.
struct RoomGuide: View {
    let session: OOOSession
    @Bindable var clock: PlaybackClock

    var body: some View {
        GeometryReader { g in
            let room = CGFloat(session.project.lift?.room ?? Lift.defaultRoom)
            let up = CGFloat(session.choreography.liftAmount(at: clock.time))
            let w = g.size.width, h = g.size.height
            let top = h * (1 - room)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(LinearGradient(colors: [Theme.voice.opacity(0), Theme.voice.opacity(0.22)], startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: h - top)
                    .offset(y: top)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: top))
                    p.addLine(to: CGPoint(x: w, y: top))
                }
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Silhouette()
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 3]))
                    .frame(width: min(w * 0.7, (h - top) * 1.1), height: (h - top) * 0.86)
                    .offset(x: (w - min(w * 0.7, (h - top) * 1.1)) / 2, y: h - (h - top) * 0.86)
                Text("You").textStyle(.caption).foregroundStyle(.white.opacity(0.8))
                    .offset(x: 10, y: top + 6)
            }
            .opacity(Double(up))
        }
        .allowsHitTesting(false)
    }
}

/// A head and shoulders, the way a person sits in front of a camera.
struct Silhouette: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let cx = r.midX, w = r.width, h = r.height
        let headR = min(w, h) * 0.2
        let headY = r.minY + headR * 1.05
        p.addEllipse(in: CGRect(x: cx - headR * 0.86, y: headY - headR, width: headR * 1.72, height: headR * 2.05))
        let neck = headY + headR * 1.15
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addCurve(to: CGPoint(x: cx - headR * 0.55, y: neck),
                   control1: CGPoint(x: r.minX + w * 0.05, y: neck + h * 0.12),
                   control2: CGPoint(x: cx - w * 0.22, y: neck + h * 0.02))
        p.addLine(to: CGPoint(x: cx + headR * 0.55, y: neck))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY),
                   control1: CGPoint(x: cx + w * 0.22, y: neck + h * 0.02),
                   control2: CGPoint(x: r.maxX - w * 0.05, y: neck + h * 0.12))
        return p
    }
}
