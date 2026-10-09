import AppKit
import OOOCore
import OOOMotion
import SwiftUI
import simd

/// The pen: one fine marker in a few colours.
public struct PenState: Equatable {
    public var on = false
    public var color: InkColor = .red
    /// Marks fade a moment after they are drawn; otherwise they stay until the slide changes.
    public var fades = false

    public init() {}
}

/// Where the pen was, on the canvas (−1…1, y up), and when (seconds).
public struct PenPoint: Sendable {
    public var x: Float
    public var y: Float
    public var at: Double

    public init(x: Float, y: Float, at: Double) {
        self.x = x
        self.y = y
        self.at = at
    }
}

extension InkColor {
    var swatch: Color {
        let c = srgb
        return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b))
    }

    /// The ink as an outline that shows on the editor's surround: black ink
    /// rings in a soft white in the dark, and white ink in a soft black in the light.
    func ring(_ scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.black, .dark): return Color.white.opacity(0.55)
        case (.white, .light): return Color.black.opacity(0.4)
        default: return swatch
        }
    }
}

/// The pen's pointer over the card: a dot of its ink, as wide as the line it
/// draws there, ringed so it shows on any slide.
@MainActor
enum InkCursor {
    private static var made: [String: NSCursor] = [:]

    static func cursor(_ ink: InkColor, width: CGFloat) -> NSCursor {
        let d = min(max(width, 5), 44).rounded()
        let key = "\(ink.rawValue) \(Int(d))"
        if let c = made[key] { return c }
        let c = ink.srgb
        let side = d + 6
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let dot = rect.insetBy(dx: 3, dy: 3)
            // Small, it is a dot of ink; wider, a ring, so you see what you're about to cover.
            NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: d > 12 ? 0.35 : 0.95).setFill()
            NSBezierPath(ovalIn: dot).fill()
            let edge = NSBezierPath(ovalIn: dot)
            edge.lineWidth = 1.5
            NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1).setStroke()
            edge.stroke()
            let halo = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            halo.lineWidth = 1
            NSColor(white: ink == .black ? 1 : 0, alpha: 0.55).setStroke()
            halo.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        made[key] = cursor
        return cursor
    }
}

/// Drawing on the card: circle a number, underline a word. In the video the
/// mark draws on just as your hand drew it.
extension OOOSession {
    /// Strokes this close together (seconds) make one mark.
    static let penJoin = 1.2

    /// Takes the pen out, pausing where you are, or puts it away.
    public func togglePen() {
        if pen.on { finishDrawing() } else { pen.on = true }
    }

    /// Whether the card lies still at the playhead, so the pen can draw on it.
    public var penCanDraw: Bool {
        scene?.touch(0, 0, at: clock.time, canvasAspect: project.canvasAspect) != nil
    }

    /// One stroke of the pen. Strokes in quick succession make one mark, the
    /// pauses between them kept short; a stroke after a rest starts a new
    /// mark, drawn on after the last. A stroke that runs off the card breaks there.
    public func penStroke(_ points: [PenPoint]) {
        guard let scene, let start = points.first?.at, let end = points.last?.at else { return }
        let t = clock.time, C = project.canvasAspect
        // During a live take the camera may move as you draw: each point lands
        // where the card was under it then, and the mark starts when you began.
        let inTake = take != nil
        var page: Int?
        var pieces: [[InkPoint]] = [[]]
        for p in points {
            guard let hit = scene.touch(p.x, p.y, at: inTake ? t - (end - p.at) : t, canvasAspect: C), page == nil || hit.page == page,
                  (0...1).contains(hit.x), (0...1).contains(hit.y) else {
                if pieces.last?.isEmpty == false { pieces.append([]) }
                continue
            }
            page = hit.page
            pieces[pieces.count - 1].append(InkPoint(x: hit.x, y: hit.y, t: Float(p.at - start)))
        }
        pieces.removeAll { $0.isEmpty }
        guard let k = page, let t0 = pieces.first?.first?.t else { return }
        let id = project.pageID(k)
        var marks = project.marks ?? []
        if let last = penLast, start - last.ended < Self.penJoin, let i = marks.firstIndex(where: { $0.id == last.id }),
           marks[i].page == id, marks[i].color == pen.color, marks[i].fades == pen.fades {
            // The same mark carries on after a short pause, however long the hand rested.
            let offset = (marks[i].strokes.last?.last?.t ?? 0) + Float(min(start - last.ended, 0.3)) - t0
            marks[i].strokes += pieces.map { $0.map { InkPoint(x: $0.x, y: $0.y, t: $0.t + offset) } }
            penLast = (marks[i].id, end)
        } else {
            // A new mark, drawn on after the ones drawn before it.
            let after = marks.filter { penMarks.contains($0.id) }.map { $0.drawn + 0.35 }.max() ?? t
            let strokes = pieces.map { $0.map { InkPoint(x: $0.x, y: $0.y, t: $0.t - t0) } }
            let mark = Mark(page: id, time: inTake ? max(t - (end - start), 0) : max(t, after), strokes: strokes, color: pen.color,
                            fades: pen.fades)
            marks.append(mark)
            penMarks.append(mark.id)
            penLast = (mark.id, end)
        }
        // A take is one undo step, kept when it ends.
        if inTake { live { $0.marks = marks } } else { update("Draw") { $0.marks = marks } }
    }

    /// Puts the pen away and plays what it drew, from a moment before.
    public func finishDrawing(replay: Bool = true) {
        let first = (project.marks ?? []).filter { penMarks.contains($0.id) }.map(\.time).min()
        pen.on = false
        guard replay, take == nil, let first else { return }
        clock.time = max(first - 0.8, 0)
        clock.playing = true
    }

    /// Moves a mark in time, during a drag.
    public func liveMark(_ id: UUID, to t: Double) {
        live { p in
            guard let i = p.marks?.firstIndex(where: { $0.id == id }) else { return }
            p.marks?[i].time = max(t, 0)
        }
    }

    public func editMark(_ id: UUID, _ name: String, _ change: (inout Mark) -> Void) {
        update(name) { p in
            guard var marks = p.marks, let i = marks.firstIndex(where: { $0.id == id }) else { return }
            change(&marks[i])
            p.marks = marks
        }
    }

    public func deleteMark(_ id: UUID) {
        update("Delete Mark") { p in
            p.marks?.removeAll { $0.id == id }
            if p.marks?.isEmpty == true { p.marks = nil }
        }
    }
}

// MARK: - Stage

/// The pen over the stage: the stroke under your hand as you draw it, laid
/// on the card as ink the moment you lift it.
struct PenOverlay: View {
    @Bindable var session: OOOSession
    @Bindable var clock: PlaybackClock
    @State private var stroke: [CGPoint] = []
    @State private var points: [PenPoint] = []
    @State private var width: CGFloat = 3

    var body: some View {
        GeometryReader { g in
            let size = g.size
            Canvas { ctx, _ in
                guard let first = stroke.first else { return }
                var path = Path()
                if stroke.count == 1 {
                    path.addEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
                    ctx.fill(path, with: .color(session.pen.color.swatch))
                } else {
                    path.addLines(stroke)
                    ctx.stroke(path, with: .color(session.pen.color.swatch),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if stroke.isEmpty { width = penWidth(at: v.location, in: size) }
                    stroke.append(v.location)
                    points.append(PenPoint(x: Float(v.location.x / max(size.width, 1)) * 2 - 1,
                                           y: 1 - Float(v.location.y / max(size.height, 1)) * 2,
                                           at: v.time.timeIntervalSinceReferenceDate))
                }
                .onEnded { _ in
                    session.penStroke(points)
                    stroke = []
                    points = []
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): pointer(at: p, in: size).set()
                case .ended: NSCursor.arrow.set()
                }
            }
        }
        .onDisappear { NSCursor.arrow.set() }
        .onChange(of: clock.playing) { _, playing in
            if playing { session.finishDrawing(replay: false) }
        }
    }

    /// The pointer: the pen's ink where it would draw, a crosshair off the
    /// card, and a no-entry sign while the card is moving.
    private func pointer(at p: CGPoint, in size: CGSize) -> NSCursor {
        let x = Float(p.x / max(size.width, 1)) * 2 - 1, y = 1 - Float(p.y / max(size.height, 1)) * 2
        guard let scene = session.scene, let hit = scene.touch(x, y, at: clock.time, canvasAspect: session.project.canvasAspect)
        else { return NSCursor.operationNotAllowed }
        guard (0...1).contains(hit.x), (0...1).contains(hit.y) else { return NSCursor.crosshair }
        return InkCursor.cursor(session.pen.color, width: penWidth(at: p, in: size))
    }

    /// The pen's width on screen where it touches the card.
    private func penWidth(at p: CGPoint, in size: CGSize) -> CGFloat {
        let x = Float(p.x / max(size.width, 1)) * 2 - 1, y = 1 - Float(p.y / max(size.height, 1)) * 2
        let C = session.project.canvasAspect, t = clock.time
        guard let scene = session.scene, let hit = scene.touch(x, y, at: t, canvasAspect: C),
              let a = scene.canvasPoint(hit.x, hit.y, page: hit.page, at: t, canvasAspect: C),
              let b = scene.canvasPoint(hit.x, hit.y + 0.1, page: hit.page, at: t, canvasAspect: C) else { return 3 }
        let slideHeight = CGFloat(simd_length(b - a) / 0.1) * size.height / 2
        return max(CGFloat(Mark.penWidth) * slideHeight, 1.5)
    }
}

/// Draw, under the video: the pen in the ink it will draw with.
struct PenButton: View {
    @Bindable var session: OOOSession
    @State private var hover = false

    var body: some View {
        Button { session.togglePen() } label: {
            HStack(spacing: 6) {
                Image(systemName: "pencil.tip").font(.system(size: 12, weight: .semibold))
                Text("Draw").font(.system(size: 13, weight: .semibold))
                Circle().fill(session.pen.color.swatch)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                    .frame(width: 9, height: 9)
            }
            .fixedSize()
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(Theme.well.opacity(hover ? 1 : 0.7)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(!session.hasSlide)
        .help("Draw on the slide: circle a number, underline a word. In the video it draws on as your hand did (⇧⌘P)")
        .accessibilityLabel("Draw on the Slide")
    }
}

/// The pen's tray, in place of the transport while you draw: its colours,
/// whether its marks stay, and Done. Ringed in the ink, like the stage.
struct PenTray: View {
    @Bindable var session: OOOSession
    /// Under a narrow video: no pen at the start, and a smaller Stays and Fades.
    var compact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = session.pen.color
        HStack(spacing: compact ? 6 : 8) {
            if !compact {
                Image(systemName: "pencil.tip").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink.ring(scheme))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 2) {
                ForEach(InkColor.allCases) { c in
                    Swatch(ink: c, selected: ink == c) { session.pen.color = c }
                }
            }
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
            Picker("Marks", selection: $session.pen.fades) {
                Text("Stays").tag(false)
                Text("Fades").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(compact ? .small : .regular)
            .fixedSize()
            .help("Stays until the slide changes, or fades a moment after it is drawn")
            Button("Done") { session.finishDrawing() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .help("Put the pen away and watch what you drew (Return)")
        }
        .fixedSize()
        .padding(.leading, compact ? 6 : 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.raised))
        .overlay(Capsule().strokeBorder(ink.ring(scheme).opacity(0.9), lineWidth: 1.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.1), radius: 8, y: 2)
    }

    /// One ink to choose, a little larger under the pointer.
    struct Swatch: View {
        let ink: InkColor
        let selected: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                Circle().fill(ink.swatch)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5))
                    .frame(width: 18, height: 18)
                    .scaleEffect(hover && !selected ? 1.1 : 1)
                    .padding(3)
                    .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.9) : .clear, lineWidth: 2))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(Theme.quick, value: hover)
            .help(ink.title)
            .accessibilityLabel(ink.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

// MARK: - Timeline

/// A mark on the camera lane, in its ink, as long as it takes to draw:
/// drag it to time it, click to watch it, right-click to change it.
struct MarkPin: View {
    @Bindable var session: OOOSession
    let mark: Mark
    let scale: TimeScale
    @State private var dragStart: Double?
    @State private var hover = false

    var body: some View {
        let w = max(CGFloat(mark.drawLength) * scale.pointsPerSecond, 14)
        Capsule()
            .fill(mark.color.swatch)
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
            .overlay(alignment: .leading) {
                Image(systemName: "pencil.tip").font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.6))
                    .padding(.leading, 3).opacity(w > 16 ? 1 : 0)
            }
            .frame(width: w, height: hover || dragStart != nil ? 13 : 11)
            .opacity(mark.fades ? 0.75 : 1)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { g in
                    if dragStart == nil {
                        dragStart = mark.time
                        session.holdTimeline(true)
                        session.beginEdit("Move Mark")
                    }
                    session.liveMark(mark.id, to: (dragStart ?? mark.time) + Double(g.translation.width / scale.pointsPerSecond))
                }
                .onEnded { _ in
                    dragStart = nil
                    session.commitEdit("Move Mark")
                    session.holdTimeline(false)
                })
            .simultaneousGesture(TapGesture().onEnded {
                session.clock.playing = false
                session.clock.time = max(mark.time - 0.8, 0)
                session.clock.playing = true
            })
            .contextMenu {
                Picker("Colour", selection: Binding(get: { mark.color }, set: { c in session.editMark(mark.id, "Ink Colour") { $0.color = c } })) {
                    ForEach(InkColor.allCases) { Text($0.title).tag($0) }
                }
                Picker("After It Is Drawn", selection: Binding(get: { mark.fades }, set: { f in
                    session.editMark(mark.id, f ? "Fade Mark" : "Keep Mark") { $0.fades = f }
                })) {
                    Text("Stays Until the Slide Changes").tag(false)
                    Text("Fades").tag(true)
                }
                Divider()
                Button("Delete Mark", role: .destructive) { session.deleteMark(mark.id) }
            }
            .help("A mark drawn on slide \(session.project.pageIndex(mark.page) + 1). Drag to time it; click to watch; right-click to change it.")
    }
}
