import AppKit
import OOOCore
import OOOMotion
import SwiftUI
import simd

/// The pen: a marker in a few colours or one of your own, four widths, and
/// shapes it draws for you.
public struct PenState: Equatable {
    public var on = false
    public var tool: PenTool = .pen
    public var color: InkColor = .red
    /// A colour of your own in place of `color`, sRGB (r, g, b).
    public var custom: [Float]?
    /// The line's width, as a share of the slide's height.
    public var width: Float = Mark.penWidth
    /// Marks fade a moment after they are drawn; otherwise they stay until the slide changes.
    public var fades = false
    /// Seconds a mark that fades stays once drawn.
    public var linger: Double = 1.5

    public init() {}

    /// The ink it draws with.
    var tone: InkTone {
        if let c = custom, c.count == 3 { return InkTone((r: c[0], g: c[1], b: c[2])) }
        return InkTone(color.srgb)
    }

    /// A mark as the pen would draw it now.
    func mark(page: UUID?, time: Double, strokes: [[InkPoint]]) -> Mark {
        Mark(page: page, time: time, strokes: strokes, color: color, custom: custom, width: width, fades: fades,
             linger: fades ? linger : nil)
    }
}

/// What the pen draws: your own line, or a shape drawn for you between
/// where you press and where you let go.
public enum PenTool: String, CaseIterable, Identifiable, Sendable {
    case pen, arrow, box, circle

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pen: return "Pen"
        case .arrow: return "Arrow"
        case .box: return "Box"
        case .circle: return "Circle"
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "scribble"
        case .arrow: return "arrow.up.right"
        case .box: return "square"
        case .circle: return "circle"
        }
    }
    var shape: InkShape? {
        switch self {
        case .pen: return nil
        case .arrow: return .arrow
        case .box: return .box
        case .circle: return .circle
        }
    }
    var help: String {
        switch self {
        case .pen: return "Draw freehand"
        case .arrow: return "Drag from where the arrow starts to what it points at (⇧ keeps it straight)"
        case .box: return "Drag across what to box (⇧ for a square)"
        case .circle: return "Drag across what to circle (⇧ for a round one)"
        }
    }
}

/// The pen's widths, finest first, by name.
enum PenWidth {
    static let names = ["Fine", "Pen", "Marker", "Bold"]
    static func name(_ w: Float) -> String {
        let i = Mark.widths.enumerated().min { abs($0.element - w) < abs($1.element - w) }?.offset ?? 1
        return names[i]
    }
}

/// How long a mark that fades can stay, to choose from.
enum PenStay {
    static let choices: [Double] = [0.5, 1, 1.5, 2, 3, 5, 8]
    static func label(_ s: Double) -> String { secondsLabel(s) }
}

/// An ink as the editor shows it: a pen's colour or one of your own.
struct InkTone: Hashable {
    var r: Float, g: Float, b: Float

    init(_ c: (r: Float, g: Float, b: Float)) {
        r = c.r
        g = c.g
        b = c.b
    }

    var swatch: Color { Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b)) }
    var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var key: String { String(format: "%.3f %.3f %.3f", r, g, b) }

    /// The ink as an outline that shows on the editor's surround: dark ink
    /// rings in a soft white in the dark, and pale ink in a soft black in the light.
    func ring(_ scheme: ColorScheme) -> Color {
        if scheme == .dark, luminance < 0.12 { return Color.white.opacity(0.55) }
        if scheme == .light, luminance > 0.85 { return Color.black.opacity(0.4) }
        return swatch
    }
}

extension Mark {
    var tone: InkTone { InkTone(ink) }
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
    var swatch: Color { InkTone(srgb).swatch }
}

/// The pen's pointer over the card: a dot of its ink, as wide as the line it
/// draws there, ringed so it shows on any slide.
@MainActor
enum InkCursor {
    private static var made: [String: NSCursor] = [:]

    static func cursor(_ ink: InkTone, width: CGFloat) -> NSCursor {
        let d = min(max(width, 5), 44).rounded()
        let key = "\(ink.key) \(Int(d))"
        if let c = made[key] { return c }
        let c = ink
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
            NSColor(white: ink.luminance < 0.2 ? 1 : 0, alpha: 0.55).setStroke()
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

    /// Draw, or back to Frame; during a take, the pen out or away.
    public func togglePen() {
        if take != nil {
            if liveStep == .recording { pen.on.toggle() }
            return
        }
        if mode == .draw { finishDrawing() } else { enter(.draw) }
    }

    /// The marks drawn since the pen came out show as they will in the video again.
    func unpinMarks() {
        penMarks = []
        penLast = nil
    }

    /// The mark drawn last, gone.
    public func deleteLastMark() {
        // One already taken back with Undo is passed over.
        let there = Set(project.marks?.map(\.id) ?? [])
        guard let id = penMarks.last(where: { there.contains($0) }) ?? project.marks?.last?.id else { return }
        penMarks.removeAll { $0 == id }
        if penLast?.id == id { penLast = nil }
        deleteMark(id)
    }

    /// The marks showing on the slide face up at the playhead, gone.
    public func clearMarksHere() {
        let t = clock.time
        let id = project.pageID(choreography.page(at: t))
        update("Clear Marks") { p in
            p.marks?.removeAll { $0.page == id && $0.time <= t + 0.05 && (!$0.fades || $0.gone > t) }
            if p.marks?.isEmpty == true { p.marks = nil }
        }
        unpinMarks()
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
           marks[i].page == id, marks[i].color == pen.color, marks[i].custom == pen.custom, marks[i].width == pen.width,
           marks[i].fades == pen.fades, marks[i].linger == (pen.fades ? pen.linger : nil) {
            // The same mark carries on after a short pause, however long the hand rested.
            let offset = (marks[i].strokes.last?.last?.t ?? 0) + Float(min(start - last.ended, 0.3)) - t0
            marks[i].strokes += pieces.map { $0.map { InkPoint(x: $0.x, y: $0.y, t: $0.t + offset) } }
            penLast = (marks[i].id, end)
        } else {
            // A new mark, drawn on after the ones drawn before it.
            let after = marks.filter { penMarks.contains($0.id) }.map { $0.drawn + 0.35 }.max() ?? t
            let strokes = pieces.map { $0.map { InkPoint(x: $0.x, y: $0.y, t: $0.t - t0) } }
            let mark = pen.mark(page: id, time: inTake ? max(t - (end - start), 0) : max(t, after), strokes: strokes)
            marks.append(mark)
            penMarks.append(mark.id)
            penLast = (mark.id, end)
        }
        // A take is one undo step, kept when it ends.
        if inTake { live { $0.marks = marks } } else { update("Draw") { $0.marks = marks } }
    }

    /// The shape the pen would draw from `a` to `b` (canvas points) on the
    /// card as it lies now: its slide, and its strokes there. Nil off the card.
    func shapeStrokes(_ kind: InkShape, from a: PenPoint, to b: PenPoint) -> (page: Int, strokes: [[InkPoint]])? {
        guard let scene else { return nil }
        let t = clock.time, C = project.canvasAspect
        guard let start = scene.touch(a.x, a.y, at: t, canvasAspect: C), (0...1).contains(start.x), (0...1).contains(start.y)
        else { return nil }
        var end = (x: start.x, y: start.y)
        if let hit = scene.touch(b.x, b.y, at: t, canvasAspect: C), hit.page == start.page {
            end = (min(max(hit.x, 0), 1), min(max(hit.y, 0), 1))
        }
        let A = scene.aspect(start.page)
        // Too small to mean anything: a click.
        guard abs(end.x - start.x) * A > 0.012 || abs(end.y - start.y) > 0.012 else { return nil }
        return (start.page, Mark.shape(kind, from: (start.x, start.y), to: end, slideAspect: A, seed: shapeSeed))
    }

    /// Where `strokes` on slide `page` lie on the canvas now (−1…1, y up), for drawing them as you drag.
    func canvasStrokes(_ strokes: [[InkPoint]], page: Int) -> [[SIMD2<Float>]] {
        guard let scene else { return [] }
        let t = clock.time, C = project.canvasAspect
        return strokes.map { $0.compactMap { scene.canvasPoint($0.x, $0.y, page: page, at: t, canvasAspect: C) } }
    }

    /// Draws a shape for you, from where you pressed to where you let go, as
    /// one mark that draws on as a hand would; during a take, from now.
    public func penShape(_ kind: InkShape, from a: PenPoint, to b: PenPoint) {
        guard let shape = shapeStrokes(kind, from: a, to: b) else { return }
        shapeSeed += 1
        let t = clock.time
        let inTake = take != nil
        var marks = project.marks ?? []
        let after = marks.filter { penMarks.contains($0.id) }.map { $0.drawn + 0.35 }.max() ?? t
        let mark = pen.mark(page: project.pageID(shape.page), time: inTake ? t : max(t, after), strokes: shape.strokes)
        marks.append(mark)
        penMarks.append(mark.id)
        // What the pen draws next is a mark of its own.
        penLast = nil
        if inTake {
            live { $0.marks = marks }
        } else {
            update("Draw \(PenTool(rawValue: kind.rawValue)?.title ?? "Shape")") { $0.marks = marks }
        }
    }

    /// How long a mark stays once drawn, during a drag of its end on the timeline.
    public func liveMarkStay(_ id: UUID, _ seconds: Double) {
        live { p in
            guard let i = p.marks?.firstIndex(where: { $0.id == id }) else { return }
            p.marks?[i].linger = min(max(seconds, Mark.lingerRange.lowerBound), Mark.lingerRange.upperBound)
        }
    }

    /// Puts the pen away, back to Frame, and plays what it drew from a moment before.
    public func finishDrawing(replay: Bool = true) {
        let first = (project.marks ?? []).filter { penMarks.contains($0.id) }.map(\.time).min()
        pen.on = false
        if take == nil, mode == .draw { mode = .frame }
        guard replay, take == nil, let first else { return }
        previewUntil = nil
        clock.time = max(first - 0.8, 0)
        clock.playing = true
    }

    /// Moves a mark in time, during a drag.
    public func liveMark(_ id: UUID, to t: Double) {
        live { p in
            guard let i = p.marks?.firstIndex(where: { $0.id == id }) else { return }
            // A video of a set length keeps its marks inside it, where they play.
            p.marks?[i].time = min(max(t, 0), p.length.map { max($0 - 0.1, 0) } ?? .greatestFiniteMagnitude)
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
/// on the card as ink the moment you lift it; or, with a shape, the shape
/// as it will lie on the card, from where you pressed to where you are.
struct PenOverlay: View {
    @Bindable var session: OOOSession
    @Bindable var clock: PlaybackClock
    @State private var stroke: [CGPoint] = []
    @State private var points: [PenPoint] = []
    @State private var width: CGFloat = 3
    /// A shape being dragged out: where it started, and its strokes on screen.
    @State private var shapeFrom: PenPoint?
    @State private var shapeTo: PenPoint?
    @State private var shown: [[CGPoint]] = []

    var body: some View {
        GeometryReader { g in
            let size = g.size
            let ink = session.pen.tone.swatch
            Canvas { ctx, _ in
                let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                for line in shown where line.count > 1 {
                    var path = Path()
                    path.addLines(line)
                    ctx.stroke(path, with: .color(ink), style: style)
                }
                guard let first = stroke.first else { return }
                var path = Path()
                if stroke.count == 1 {
                    path.addEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
                    ctx.fill(path, with: .color(ink))
                } else {
                    path.addLines(stroke)
                    ctx.stroke(path, with: .color(ink), style: style)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    // While it plays (gliding to a still point), the pen waits.
                    guard !clock.playing || session.isTaking else { return }
                    let p = penPoint(v.location, in: size, at: v.time.timeIntervalSinceReferenceDate)
                    if stroke.isEmpty && shapeFrom == nil { width = penWidth(at: v.location, in: size) }
                    if let shape = session.pen.tool.shape {
                        if shapeFrom == nil { shapeFrom = p }
                        guard let from = shapeFrom else { return }
                        let to = constrained(shape, from: from, to: p, in: size)
                        shapeTo = to
                        shown = preview(shape, from: from, to: to, in: size)
                        return
                    }
                    stroke.append(v.location)
                    points.append(p)
                }
                .onEnded { _ in
                    if let shape = session.pen.tool.shape, let from = shapeFrom, let to = shapeTo {
                        session.penShape(shape, from: from, to: to)
                    } else if !points.isEmpty {
                        session.penStroke(points)
                    }
                    stroke = []
                    points = []
                    shapeFrom = nil
                    shapeTo = nil
                    shown = []
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): pointer(at: p, in: size).set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .contextMenu { PenMenu(session: session) }
        }
        .onDisappear { NSCursor.arrow.set() }
        .onChange(of: clock.playing) { _, playing in
            // Played on, what was drawn shows as it will in the video.
            if playing && !session.isTaking { session.unpinMarks() }
        }
    }

    private func penPoint(_ p: CGPoint, in size: CGSize, at time: Double) -> PenPoint {
        PenPoint(x: Float(p.x / max(size.width, 1)) * 2 - 1, y: 1 - Float(p.y / max(size.height, 1)) * 2, at: time)
    }

    /// With ⇧: a square box, a round circle, an arrow at a multiple of 45°.
    private func constrained(_ shape: InkShape, from a: PenPoint, to b: PenPoint, in size: CGSize) -> PenPoint {
        guard NSEvent.modifierFlags.contains(.shift) else { return b }
        // On screen, where square and round are what you see.
        let w = Float(size.width) / 2, h = Float(size.height) / 2
        var dx = (b.x - a.x) * w, dy = (b.y - a.y) * h
        switch shape {
        case .box, .circle:
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        case .arrow:
            let length = (dx * dx + dy * dy).squareRoot()
            let angle = (atan2f(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            dx = cosf(angle) * length
            dy = sinf(angle) * length
        }
        return PenPoint(x: a.x + dx / max(w, 1), y: a.y + dy / max(h, 1), at: b.at)
    }

    /// The shape as it will lie on the card, on screen.
    private func preview(_ shape: InkShape, from a: PenPoint, to b: PenPoint, in size: CGSize) -> [[CGPoint]] {
        guard let made = session.shapeStrokes(shape, from: a, to: b) else { return [] }
        return session.canvasStrokes(made.strokes, page: made.page).map { line in
            line.map { CGPoint(x: CGFloat($0.x + 1) / 2 * size.width, y: CGFloat(1 - $0.y) / 2 * size.height) }
        }
    }

    /// The pointer: the pen's ink where it would draw, a crosshair off the
    /// card or for a shape, and a no-entry sign while the card is moving.
    private func pointer(at p: CGPoint, in size: CGSize) -> NSCursor {
        if clock.playing && !session.isTaking { return NSCursor.arrow }
        let x = Float(p.x / max(size.width, 1)) * 2 - 1, y = 1 - Float(p.y / max(size.height, 1)) * 2
        guard let scene = session.scene, let hit = scene.touch(x, y, at: clock.time, canvasAspect: session.project.canvasAspect)
        else { return NSCursor.operationNotAllowed }
        guard (0...1).contains(hit.x), (0...1).contains(hit.y), session.pen.tool == .pen else { return NSCursor.crosshair }
        return InkCursor.cursor(session.pen.tone, width: penWidth(at: p, in: size))
    }

    /// The pen's width on screen where it touches the card.
    private func penWidth(at p: CGPoint, in size: CGSize) -> CGFloat {
        let x = Float(p.x / max(size.width, 1)) * 2 - 1, y = 1 - Float(p.y / max(size.height, 1)) * 2
        let C = session.project.canvasAspect, t = clock.time
        guard let scene = session.scene, let hit = scene.touch(x, y, at: t, canvasAspect: C),
              let a = scene.canvasPoint(hit.x, hit.y, page: hit.page, at: t, canvasAspect: C),
              let b = scene.canvasPoint(hit.x, hit.y + 0.1, page: hit.page, at: t, canvasAspect: C) else { return 3 }
        let slideHeight = CGFloat(simd_length(b - a) / 0.1) * size.height / 2
        return max(CGFloat(session.pen.width) * slideHeight, 1.5)
    }
}

/// The pen's choices as menu items: for the stage's right-click menu.
struct PenMenu: View {
    @Bindable var session: OOOSession

    var body: some View {
        Picker("Draw", selection: $session.pen.tool) {
            ForEach(PenTool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        Picker("Ink", selection: Binding(get: { session.pen.custom == nil ? session.pen.color : nil },
                                         set: { if let c = $0 { session.pen.color = c; session.pen.custom = nil } })) {
            ForEach(InkColor.allCases) { Text($0.title).tag(Optional($0)) }
        }
        Picker("Width", selection: $session.pen.width) {
            ForEach(Array(Mark.widths.enumerated()), id: \.offset) { i, w in Text(PenWidth.names[i]).tag(w) }
        }
        Picker("Marks", selection: Binding(get: { session.pen.fades ? session.pen.linger : 0 }, set: { s in
            session.pen.fades = s > 0
            if s > 0 { session.pen.linger = s }
        })) {
            Text("Stay Until the Slide Changes").tag(0.0)
            ForEach(PenStay.choices, id: \.self) { Text("Fade After \(PenStay.label($0))").tag($0) }
        }
        if !session.isTaking {
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
        }
    }
}

/// The pen's tray, in place of the transport while you draw: what it draws
/// and how wide, its colours, how long its marks stay, the still points
/// either side, and Done. Ringed in the ink, like the stage. During a take,
/// one row (what, colour, width, as room allows) and no keys of its own:
/// the take's keys stay yours.
struct PenTray: View {
    @Bindable var session: OOOSession
    /// Under a narrow video: icons in place of words.
    var compact = false
    var inTake = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tone = session.pen.tone
        if inTake {
            ViewThatFits(in: .horizontal) {
                takeRow { tools; bar; colours; bar; widths(tone); bar; stay }
                takeRow { tools; bar; colours; bar; widths(tone) }
                takeRow { toolMenu; bar; colours; bar; widths(tone) }
                takeRow { toolMenu; bar; colours }
                takeRow { colours }
            }
        } else {
            tray(tone)
        }
    }

    /// What the pen draws, as one button that opens the four, where the
    /// four side by side won't fit.
    private var toolMenu: some View {
        Menu {
            Picker("Draw", selection: $session.pen.tool) {
                ForEach(PenTool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: session.pen.tool.symbol)
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pen, arrow, box or circle")
        .accessibilityLabel("Draw: \(session.pen.tool.title)")
    }

    private var bar: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
    }

    private func takeRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let tone = session.pen.tone
        return HStack(spacing: 6) { content() }
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tone.ring(scheme).opacity(0.9), lineWidth: 1.5))
            .contextMenu { PenMenu(session: session) }
    }

    private func tray(_ tone: InkTone) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: compact ? 6 : 10) {
                tools
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
                widths(tone)
                Spacer(minLength: 0)
                Button("Done") { session.finishDrawing() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .help("Put the pen away and watch what you drew (Return)")
            }
            HStack(spacing: compact ? 5 : 8) {
                colours
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
                stay
                Spacer(minLength: 0)
                // Under a narrow video the arrows give way; ← and → still step.
                stills.opacity(compact ? 0 : 1).frame(width: compact ? 0 : nil).allowsHitTesting(!compact)
            }
        }
        .fixedSize()
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tone.ring(scheme).opacity(0.9), lineWidth: 1.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.1), radius: 8, y: 2)
        .contextMenu { PenMenu(session: session) }
    }

    /// The still points either side.
    private var stills: some View {
        HStack(spacing: 0) {
            IconButton("chevron.left", label: "Previous Still Point (←)", size: 11) { session.stepStill(-1) }
                .keyboardShortcut(session.clock.typing ? nil : KeyboardShortcut(.leftArrow, modifiers: []))
            IconButton("chevron.right", label: "Next Still Point (→)", size: 11) { session.stepStill(1) }
                .keyboardShortcut(session.clock.typing ? nil : KeyboardShortcut(.rightArrow, modifiers: []))
        }
    }

    /// Pen, Arrow, Box, Circle.
    private var tools: some View {
        Picker("Draw", selection: $session.pen.tool) {
            ForEach(PenTool.allCases) { tool in
                Group {
                    if compact {
                        Image(systemName: tool.symbol)
                    } else {
                        Label(tool.title, systemImage: tool.symbol).labelStyle(.titleAndIcon)
                    }
                }
                .help(tool.help)
                .tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// The widths' dots, as they read side by side.
    private static let dots: [CGFloat] = [4, 6.5, 10, 14]

    /// Four widths, each a dot as wide as its line.
    private func widths(_ tone: InkTone) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(Mark.widths.enumerated()), id: \.offset) { i, w in
                let selected = session.pen.width == w
                Button { session.pen.width = w } label: {
                    Circle().fill(tone.swatch)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5))
                        .frame(width: Self.dots[i], height: Self.dots[i])
                        .frame(width: compact ? 18 : 22, height: 22)
                        .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.9) : .clear, lineWidth: 2).padding(1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(PenWidth.names[i])
                .accessibilityLabel(PenWidth.names[i])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    /// The six inks, and a well for one of your own.
    private var colours: some View {
        HStack(spacing: 1) {
            ForEach(InkColor.allCases) { c in
                Swatch(ink: c, selected: session.pen.custom == nil && session.pen.color == c, small: compact) {
                    session.pen.color = c
                    session.pen.custom = nil
                }
            }
            OwnInk(custom: session.pen.custom, small: compact) { c in session.pen.custom = c }
        }
    }

    /// Stays until the slide changes, or fades after a while you choose.
    @ViewBuilder
    private var stay: some View {
        if compact {
            Button { session.pen.fades.toggle() } label: {
                Image(systemName: session.pen.fades ? "hourglass.bottomhalf.filled" : "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.pen.fades ? "Marks fade a moment after they are drawn. Click to keep them until the slide changes."
                : "Marks stay until the slide changes. Click to let them fade.")
        } else {
            Picker("Marks", selection: $session.pen.fades) {
                Text("Stays").tag(false)
                Text("Fades").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Stays until the slide changes, or fades a while after it is drawn")
        }
        if session.pen.fades {
            Menu {
                Picker("Fades After", selection: $session.pen.linger) {
                    ForEach(PenStay.choices, id: \.self) { Text(PenStay.label($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(compact ? PenStay.label(session.pen.linger) : "after \(PenStay.label(session.pen.linger))").textStyle(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("How long a mark stays once drawn, before it fades")
        }
    }

    /// Your own ink: a ring of every colour until you choose one, then that
    /// colour; a click opens the colour picker.
    struct OwnInk: View {
        let custom: [Float]?
        var small = false
        let chose: ([Float]) -> Void
        @State private var hover = false

        var body: some View {
            let d: CGFloat = small ? 14 : 18
            Button {
                let start = custom.map { NSColor(srgbRed: CGFloat($0[0]), green: CGFloat($0[1]), blue: CGFloat($0[2]), alpha: 1) } ?? .systemPurple
                InkPanel.shared.open(start) { c in
                    guard let s = c.usingColorSpace(.sRGB) else { return }
                    chose([Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent)])
                }
            } label: {
                Group {
                    if let c = custom, c.count == 3 {
                        Circle().fill(Color(.sRGB, red: Double(c[0]), green: Double(c[1]), blue: Double(c[2])))
                    } else {
                        Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    }
                }
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5))
                .frame(width: d, height: d)
                .scaleEffect(hover && custom == nil ? 1.1 : 1)
                .padding(3)
                .overlay(Circle().strokeBorder(custom != nil ? Color.primary.opacity(0.9) : .clear, lineWidth: 2))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(Theme.quick, value: hover)
            .help("A colour of your own")
            .accessibilityLabel("Your own colour")
        }
    }

    /// One ink to choose, a little larger under the pointer.
    struct Swatch: View {
        let ink: InkColor
        let selected: Bool
        var small = false
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                Circle().fill(ink.swatch)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5))
                    .frame(width: small ? 14 : 18, height: small ? 14 : 18)
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

/// The Mac's colour picker, for a pen's own ink.
@MainActor
final class InkPanel: NSObject {
    static let shared = InkPanel()
    private var chose: ((NSColor) -> Void)?

    func open(_ color: NSColor, _ chose: @escaping (NSColor) -> Void) {
        self.chose = chose
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        chose?(panel.color)
    }
}

// MARK: - Timeline

/// A mark on the camera lane, in its ink, as long as it takes to draw, and,
/// if it fades, a tail as long as it stays: drag it to time it, its tail's
/// end to keep it longer, click to watch it, right-click to change it.
struct MarkPin: View {
    @Bindable var session: OOOSession
    let mark: Mark
    let scale: TimeScale
    @State private var dragStart: Double?
    @State private var stayStart: Double?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            pin
            if mark.fades { tail }
        }
    }

    private var pin: some View {
        let w = max(CGFloat(mark.drawLength) * scale.pointsPerSecond, 14)
        let swatch = mark.tone.swatch
        return Capsule()
            .fill(swatch)
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
            .overlay(alignment: .leading) {
                Image(systemName: "pencil.tip").font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.6))
                    .padding(.leading, 3).opacity(w > 16 ? 1 : 0)
            }
            .frame(width: w, height: hover || dragStart != nil ? 13 : 11)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
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
            .contextMenu { menu }
            .help("A mark drawn on slide \(session.project.pageIndex(mark.page) + 1). Drag to time it; click to watch; right-click to change it.")
    }

    /// How long it stays once drawn, then fades: drag its end to change it.
    private var tail: some View {
        let stay = CGFloat(mark.stay) * scale.pointsPerSecond, fade = CGFloat(Mark.fadeLength) * scale.pointsPerSecond
        let swatch = mark.tone.swatch
        return ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Rectangle().fill(swatch.opacity(0.4)).frame(width: stay)
                LinearGradient(colors: [swatch.opacity(0.4), swatch.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fade)
            }
            .frame(height: 5)
            if stay > 28 {
                Text(secondsLabel(mark.stay)).font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .offset(y: 8)
            }
        }
        .allowsHitTesting(false)
        .overlay(alignment: .trailing) {
            // The end of its stay, to drag.
            Capsule().fill(swatch)
                .frame(width: 3, height: hover || stayStart != nil ? 13 : 9)
                .frame(width: 9, height: 15)
                .contentShape(Rectangle())
                .offset(x: -fade + 4.5)
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if stayStart == nil {
                            stayStart = mark.stay
                            session.holdTimeline(true)
                            session.beginEdit("Mark Stays")
                        }
                        session.liveMarkStay(mark.id, (stayStart ?? mark.stay) + Double(g.translation.width / scale.pointsPerSecond))
                    }
                    .onEnded { _ in
                        stayStart = nil
                        session.commitEdit("Mark Stays")
                        session.holdTimeline(false)
                    })
                .help("Stays \(secondsLabel(mark.stay)) once drawn, then fades. Drag to keep it longer or shorter.")
        }
    }

    @ViewBuilder
    private var menu: some View {
        Picker("Colour", selection: Binding(get: { mark.custom == nil ? mark.color : nil }, set: { c in
            guard let c else { return }
            session.editMark(mark.id, "Ink Colour") { $0.color = c; $0.custom = nil }
        })) {
            ForEach(InkColor.allCases) { Text($0.title).tag(Optional($0)) }
        }
        Picker("Width", selection: Binding(get: { mark.width }, set: { w in session.editMark(mark.id, "Ink Width") { $0.width = w } })) {
            ForEach(Array(Mark.widths.enumerated()), id: \.offset) { i, w in Text(PenWidth.names[i]).tag(w) }
            if !Mark.widths.contains(mark.width) { Text("Its Own").tag(mark.width) }
        }
        Picker("After It Is Drawn", selection: Binding(get: { mark.fades ? mark.stay : 0 }, set: { s in
            session.editMark(mark.id, s > 0 ? "Fade Mark" : "Keep Mark") {
                $0.fades = s > 0
                if s > 0 { $0.linger = s }
            }
        })) {
            Text("Stays Until the Slide Changes").tag(0.0)
            ForEach(PenStay.choices, id: \.self) { Text("Fades After \(PenStay.label($0))").tag($0) }
            if mark.fades, !PenStay.choices.contains(mark.stay) { Text("Fades After \(PenStay.label(mark.stay))").tag(mark.stay) }
        }
        Divider()
        Button("Delete Mark", role: .destructive) { session.deleteMark(mark.id) }
    }
}
