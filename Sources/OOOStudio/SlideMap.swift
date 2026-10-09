import AppKit
import OOOCore
import OOOMotion
import SwiftUI

/// Maps between slide space (u across, v down) and the map's points.
struct MapLayout {
    let slide: CGRect

    /// Margin around the slide, in slide heights, so framings that reach past
    /// its edges stay in view.
    static let margin: CGFloat = 0.09

    static func aspect(slideAspect a: CGFloat) -> CGFloat { (a + 2 * margin) / (1 + 2 * margin) }

    init(size: CGSize, slideAspect a: CGFloat) {
        let unit = size.height / (1 + 2 * Self.margin)
        let w = unit * a
        slide = CGRect(x: (size.width - w) / 2, y: unit * Self.margin, width: w, height: unit)
    }

    func point(_ u: Float, _ v: Float) -> CGPoint {
        CGPoint(x: slide.minX + CGFloat(u) * slide.width, y: slide.minY + CGFloat(v) * slide.height)
    }

    func uv(_ p: CGPoint) -> Vec2 {
        Vec2(Float((p.x - slide.minX) / slide.width), Float((p.y - slide.minY) / slide.height))
    }

    func rect(_ f: ShotFrame) -> CGRect {
        let a = point(f.minU, f.minV), b = point(f.maxU, f.maxV)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// How much larger the numbers and handles draw on a big map, so they
    /// keep in proportion with the slide and stay easy to grab.
    var mark: CGFloat { min(max(slide.width / 300, 1), 1.45) }
}

/// The slide map for the slide the editor is about: the selected shot's, or
/// the one face up at the playhead.
struct MapHost: View {
    let session: OOOSession
    @Bindable var clock: PlaybackClock

    var body: some View {
        SlideMap(session: session, page: session.mapPage(at: clock.time))
    }
}

/// The slide seen from above, with each framing drawn as a flat box of what
/// the video shows there. Drag on the slide to draw a new framing, anywhere,
/// even over others; click a framing to pick it. The picked one has handles:
/// drag inside it to move it, a corner to go closer or wider, ⌥-drag to turn
/// the camera. A framing's number tab moves it without picking it first.
struct SlideMap: View {
    @Bindable var session: OOOSession
    /// The slide shown (0 is the first).
    let page: Int
    @State private var gesture: MapGesture?
    @State private var drawing: CGRect?
    @State private var hovered: UUID?
    /// Where the pointer was last, on the slide, for the menu. Not watched: it changes with every move.
    @State private var last = MapPoint()

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }

        /// Where it sits on a box, 0…1 across and down.
        var at: CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: 0, y: 0)
            case .top: return CGPoint(x: 0.5, y: 0)
            case .topRight: return CGPoint(x: 1, y: 0)
            case .right: return CGPoint(x: 1, y: 0.5)
            case .bottomRight: return CGPoint(x: 1, y: 1)
            case .bottom: return CGPoint(x: 0.5, y: 1)
            case .bottomLeft: return CGPoint(x: 0, y: 1)
            case .left: return CGPoint(x: 0, y: 0.5)
            }
        }

        func point(on r: CGRect) -> CGPoint { CGPoint(x: r.minX + at.x * r.width, y: r.minY + at.y * r.height) }

        /// The point across the box from it, which stays put as it is dragged.
        func anchor(on r: CGRect) -> CGPoint { CGPoint(x: r.minX + (1 - at.x) * r.width, y: r.minY + (1 - at.y) * r.height) }
    }

    enum MapGesture {
        case move(UUID, ShotFrame)
        case resize(UUID, ShotFrame, Handle, CGRect)
        case tilt(UUID, Float, Float)
        /// A press on the slide: a drag draws a new framing; a click picks the framing under it, if any.
        case create(CGPoint)
        /// In Draw and Live, where the map only picks.
        case pick
    }

    var body: some View {
        let A = CGFloat(session.project.slide(page).aspect)
        GeometryReader { geo in
            let layout = MapLayout(size: geo.size, slideAspect: A)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surround)
                if let img = session.preview(page) {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layout.slide.width, height: layout.slide.height)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        .offset(x: layout.slide.minX, y: layout.slide.minY)
                }
                Canvas { ctx, _ in
                    drawFramings(ctx, layout: layout)
                    if let r = drawing {
                        let path = Path(roundedRect: r, cornerRadius: 2)
                        ctx.fill(path, with: .color(Theme.cameraSoft))
                        ctx.stroke(path, with: .color(Theme.camera), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        readout(ctx, closer(r, layout: layout), in: r, k: layout.mark)
                    }
                }
                CameraFootprint(session: session, clock: session.clock, layout: layout, page: page)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(dragGesture(layout))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    last.uv = layout.uv(p)
                    let hit = framing(at: p, layout: layout)
                    if hit != hovered { hovered = hit }
                    if gesture == nil {
                        pointer(at: p, layout: layout).set()
                        let hint = hint(at: p, layout: layout)
                        if session.mapHint != hint { session.mapHint = hint }
                    }
                case .ended:
                    hovered = nil
                    if gesture == nil { NSCursor.arrow.set() }
                    if session.mapHint != nil { session.mapHint = nil }
                }
            }
            .contextMenu { MapMenu(session: session, page: page, shot: hovered, at: last) }
        }
        .aspectRatio(MapLayout.aspect(slideAspect: A), contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Slide map")
        .accessibilityValue("\(boxes(nil).count) framings")
    }

    // MARK: Boxes

    /// A framing as the map draws it: what the video shows, flat, with its number on a tab.
    struct Box {
        let shot: Shot
        let number: Int
        let rect: CGRect
        let tab: CGRect
        var turned: Bool { abs(shot.yaw) > 0.5 || abs(shot.pitch) > 0.5 || abs(shot.roll) > 0.5 }
        var area: CGFloat { rect.width * rect.height }
    }

    private var frameMode: Bool { session.mode == .frame }

    private func boxes(_ layout: MapLayout?) -> [Box] {
        let p = session.project
        let A = p.slide(page).aspect, C = p.canvasAspect
        let live = session.mode == .live
        return session.orderedShots.enumerated().compactMap { i, s in
            guard p.pageIndex(s.page) == page else { return nil }
            let number = live ? (session.positionNumber(s.id) ?? i + 1) : i + 1
            guard let layout else { return Box(shot: s, number: number, rect: .zero, tab: .zero) }
            let r = layout.rect(s.frame.visible(slideAspect: A, canvasAspect: C))
            let k = layout.mark
            let w = (CGFloat(String(number).count) * 6 + 9) * k, h = 13 * k
            // Above its top-left corner, or just inside when that would leave the map.
            let y = r.minY - h - 2 * k >= 1 ? r.minY - h - 2 * k : r.minY + 2 * k
            return Box(shot: s, number: number, rect: r, tab: CGRect(x: max(r.minX, 1), y: y, width: w, height: h))
        }
    }

    /// The shot the editor or the take is about.
    private var selectedID: UUID? {
        if session.mode == .live {
            _ = session.version
            guard let route = session.liveRoute, let j = route.current, route.script.indices.contains(j) else { return nil }
            return route.script[j].id
        }
        if case .shot(let id) = session.selection { return id }
        return nil
    }

    private func drawFramings(_ ctx: GraphicsContext, layout: MapLayout) {
        let p = session.project
        let all = boxes(layout)
        let picked = selectedID
        let k = layout.mark
        // The route the camera takes, from framing to framing.
        let route = (page == 0 ? [p.overview.frame.center] : []) + all.map(\.shot.frame.center)
        if route.count > 1 {
            var path = Path()
            path.move(to: layout.point(route[0].x, route[0].y))
            for c in route.dropFirst() { path.addLine(to: layout.point(c.x, c.y)) }
            ctx.stroke(path, with: .color(Color.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4]))
        }
        // The picked one last, on top.
        for b in all.sorted(by: { ($0.shot.id == picked ? 1 : 0, -$0.area) < ($1.shot.id == picked ? 1 : 0, -$1.area) }) {
            let selected = b.shot.id == picked
            let hot = b.shot.id == hovered
            let box = Path(roundedRect: b.rect, cornerRadius: 2)
            if selected {
                ctx.fill(box, with: .color(Theme.cameraSoft))
                ctx.stroke(box, with: .color(Theme.camera), style: StrokeStyle(lineWidth: 1.6))
                if frameMode {
                    let side = 7 * k
                    for h in Handle.allCases {
                        let c = h.point(on: b.rect)
                        let r = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(.white))
                        ctx.stroke(Path(roundedRect: r, cornerRadius: 1.5), with: .color(Theme.camera), lineWidth: 1)
                    }
                }
                if case .resize? = gesture { readout(ctx, closer(b.rect, layout: layout), in: b.rect, k: k) }
            } else {
                ctx.stroke(box, with: .color(Color.white.opacity(hot ? 0.9 : 0.45)), style: StrokeStyle(lineWidth: hot ? 1.3 : 1))
            }
            // Its number, on a tab.
            let label = ctx.resolve(Text("\(b.number)").font(.system(size: 9 * k, weight: .bold)).foregroundColor(selected ? .white : .black))
            ctx.fill(Path(roundedRect: b.tab, cornerRadius: 3), with: .color(selected ? Theme.camera : Color.white.opacity(hot ? 0.95 : 0.75)))
            ctx.draw(label, at: CGPoint(x: b.tab.midX, y: b.tab.midY), anchor: .center)
            // A turned camera, said on a tag rather than drawn askew.
            if b.turned {
                let angle = max(abs(b.shot.yaw), abs(b.shot.pitch), abs(b.shot.roll))
                let tag = ctx.resolve(Text("\(Image(systemName: "rotate.3d")) \(Int(angle.rounded()))°")
                    .font(.system(size: 8.5 * k, weight: .semibold)).foregroundColor(selected ? .white : .black))
                let size = tag.measure(in: CGSize(width: 80, height: 30))
                let r = CGRect(x: b.tab.maxX + 3 * k, y: b.tab.minY, width: size.width + 7 * k, height: b.tab.height)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(selected ? Theme.camera.opacity(0.85) : Color.white.opacity(0.6)))
                ctx.draw(tag, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
            }
        }
    }

    /// How close a box of the video's shape takes the camera, against the whole slide.
    private func closer(_ r: CGRect, layout: MapLayout) -> Float {
        let p = session.project
        let f = ShotFrame(center: layout.uv(CGPoint(x: r.midX, y: r.midY)),
                          size: Vec2(Float(r.width / layout.slide.width), Float(r.height / layout.slide.height)))
        return f.magnification(slideAspect: p.slide(page).aspect, canvasAspect: p.canvasAspect)
    }

    private func readout(_ ctx: GraphicsContext, _ zoom: Float, in r: CGRect, k: CGFloat) {
        let text = ctx.resolve(Text(String(format: "%.1f×", zoom)).font(.system(size: 10 * k, weight: .semibold).monospacedDigit())
            .foregroundColor(.white))
        let size = text.measure(in: CGSize(width: 80, height: 30))
        let pill = CGRect(x: r.maxX - size.width - 10 * k, y: r.maxY - size.height - 7 * k, width: size.width + 6 * k, height: size.height + 2 * k)
        guard r.width > pill.width + 8, r.height > pill.height + 8 else { return }
        ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Color.black.opacity(0.55)))
        ctx.draw(text, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
    }

    // MARK: Hit testing

    private func handle(at p: CGPoint, layout: MapLayout) -> (id: UUID, handle: Handle, rect: CGRect)? {
        guard frameMode, let id = selectedID, let b = boxes(layout).first(where: { $0.shot.id == id }) else { return nil }
        let reach = 7 * layout.mark
        let near = Handle.allCases.min { a, c in
            let pa = a.point(on: b.rect), pc = c.point(on: b.rect)
            return hypot(pa.x - p.x, pa.y - p.y) < hypot(pc.x - p.x, pc.y - p.y)
        }
        guard let h = near else { return nil }
        let c = h.point(on: b.rect)
        return hypot(c.x - p.x, c.y - p.y) <= reach ? (id, h, b.rect) : nil
    }

    private func tab(at p: CGPoint, layout: MapLayout) -> UUID? {
        boxes(layout).last { $0.tab.insetBy(dx: -2, dy: -2).contains(p) }?.shot.id
    }

    private func insideSelected(_ p: CGPoint, layout: MapLayout) -> UUID? {
        guard let id = selectedID, let b = boxes(layout).first(where: { $0.shot.id == id }),
              b.rect.insetBy(dx: -3, dy: -3).contains(p) else { return nil }
        return id
    }

    /// The framing under `p`: its tab, the picked one, then the smallest around it.
    private func framing(at p: CGPoint, layout: MapLayout) -> UUID? {
        if let id = tab(at: p, layout: layout) ?? insideSelected(p, layout: layout) { return id }
        return boxes(layout).filter { $0.rect.contains(p) }.min { $0.area < $1.area }?.shot.id
    }

    private func pointer(at p: CGPoint, layout: MapLayout) -> NSCursor {
        guard frameMode else { return framing(at: p, layout: layout) != nil ? .pointingHand : .arrow }
        if let h = handle(at: p, layout: layout)?.handle {
            if h.isCorner { return .crosshair }
            return h == .left || h == .right ? .resizeLeftRight : .resizeUpDown
        }
        if tab(at: p, layout: layout) != nil || insideSelected(p, layout: layout) != nil { return .openHand }
        return .crosshair
    }

    /// What a press here would do, for the line under the map.
    private func hint(at p: CGPoint, layout: MapLayout) -> String {
        let number = { (id: UUID) -> Int in boxes(layout).first { $0.shot.id == id }?.number ?? 0 }
        switch session.mode {
        case .draw:
            return framing(at: p, layout: layout).map { "Click to draw on framing \(number($0))." } ?? "Click a framing to draw on it."
        case .live:
            if session.isTaking { return framing(at: p, layout: layout).map { "Click to go to \(number($0)) now." } ?? "Click a position to go there now." }
            return framing(at: p, layout: layout).map { "Click to see position \(number($0))." } ?? "Click a position to see it."
        case .frame:
            break
        }
        if let h = handle(at: p, layout: layout)?.handle {
            return h.isCorner ? "Drag to go closer or wider. ⌥ keeps the middle still." : "Drag to go closer or wider from this side."
        }
        if let id = tab(at: p, layout: layout), id != selectedID { return "Drag to move framing \(number(id))." }
        if insideSelected(p, layout: layout) != nil { return "Drag to move it, ⌥-drag to turn the camera. Double-click to watch it." }
        if let id = framing(at: p, layout: layout) { return "Click to pick framing \(number(id)), or drag to draw a new one." }
        return "Drag to draw a new framing."
    }

    // MARK: Gestures

    private func dragGesture(_ layout: MapLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if gesture == nil { begin(g.startLocation, layout: layout) }
                change(g, layout: layout)
            }
            .onEnded { g in end(g, layout: layout) }
    }

    private func begin(_ p: CGPoint, layout: MapLayout) {
        guard frameMode else {
            gesture = .pick
            return
        }
        let shots = session.project.shots
        if let hit = handle(at: p, layout: layout), let shot = shots.first(where: { $0.id == hit.id }) {
            session.beginEdit("Frame Shot")
            gesture = .resize(hit.id, shot.frame, hit.handle, hit.rect)
        } else if let id = tab(at: p, layout: layout) ?? insideSelected(p, layout: layout), let shot = shots.first(where: { $0.id == id }) {
            if session.selection != .shot(id) { session.select(.shot(id), show: false) }
            if NSEvent.modifierFlags.contains(.option) {
                session.beginEdit("Turn Camera")
                gesture = .tilt(id, shot.yaw, shot.pitch)
            } else {
                session.beginEdit("Move Framing")
                gesture = .move(id, shot.frame)
                NSCursor.closedHand.set()
            }
        } else {
            gesture = .create(p)
        }
    }

    private func change(_ g: DragGesture.Value, layout: MapLayout) {
        guard let gesture else { return }
        let du = Float(g.translation.width / layout.slide.width)
        let dv = Float(g.translation.height / layout.slide.height)
        switch gesture {
        case .move(let id, let start):
            session.liveShot(id) { s in
                s.frame.center = Vec2(min(max(start.center.x + du, -0.05), 1.05), min(max(start.center.y + dv, -0.05), 1.05))
            }
        case .resize(let id, let start, let h, let r):
            // Scaled about the point across from the handle (or the middle, with ⌥): the box keeps the video's shape.
            let fromMiddle = NSEvent.modifierFlags.contains(.option)
            let P = fromMiddle ? CGPoint(x: r.midX, y: r.midY) : h.anchor(on: r)
            let G = h.point(on: r), U = g.location
            var k: CGFloat
            if h.isCorner {
                let d = CGPoint(x: G.x - P.x, y: G.y - P.y)
                k = ((U.x - P.x) * d.x + (U.y - P.y) * d.y) / max(d.x * d.x + d.y * d.y, 1)
            } else if h == .left || h == .right {
                k = (U.x - P.x) / (abs(G.x - P.x) > 1 ? G.x - P.x : 1)
            } else {
                k = (U.y - P.y) / (abs(G.y - P.y) > 1 ? G.y - P.y : 1)
            }
            let big = CGFloat(max(start.size.x, start.size.y)), small = CGFloat(min(start.size.x, start.size.y))
            k = min(max(k, 0.012 / max(small, 1e-4)), 1.4 / max(big, 1e-4))
            let a = layout.uv(P)
            let kk = Float(k)
            session.liveShot(id) { s in
                s.frame.center = a + (start.center - a) * kk
                s.frame.size = start.size * kk
            }
        case .tilt(let id, let yaw, let pitch):
            session.liveShot(id) { s in
                s.yaw = clamp(yaw + Float(g.translation.width) * 0.3, -25, 25)
                s.pitch = clamp(pitch - Float(g.translation.height) * 0.3, -20, 20)
            }
        case .create(let start):
            // A box of the video's shape, from where the press began (or around it, with ⌥).
            let C = CGFloat(session.project.canvasAspect)
            let dx = g.location.x - start.x, dy = g.location.y - start.y
            let w = max(abs(dx), abs(dy) * C), h = w / C
            let r: CGRect
            if NSEvent.modifierFlags.contains(.option) {
                r = CGRect(x: start.x - w, y: start.y - h, width: 2 * w, height: 2 * h)
            } else {
                r = CGRect(x: dx < 0 ? start.x - w : start.x, y: dy < 0 ? start.y - h : start.y, width: w, height: h)
            }
            drawing = hypot(dx, dy) > 4 ? r : nil
        case .pick:
            break
        }
    }

    private func end(_ g: DragGesture.Value, layout: MapLayout) {
        defer {
            gesture = nil
            drawing = nil
        }
        guard let gesture else { return }
        let moved = hypot(g.translation.width, g.translation.height) > 3
        let twice = (NSApp.currentEvent?.clickCount ?? 1) >= 2
        switch gesture {
        case .move(let id, _):
            session.commitEdit("Move Framing")
            NSCursor.openHand.set()
            if !moved { click(id, twice: twice) }
        case .resize:
            session.commitEdit("Frame Shot")
        case .tilt(let id, _, _):
            session.commitEdit("Turn Camera")
            if !moved { click(id, twice: twice) }
        case .create(let p):
            if let r = drawing, r.width > 10, r.height > 6 {
                let a = layout.uv(CGPoint(x: r.minX, y: r.minY)), b = layout.uv(CGPoint(x: r.maxX, y: r.maxY))
                session.addShot(frame: ShotFrame(center: (a + b) / 2, size: b - a), page: page)
            } else if !moved {
                if let id = framing(at: p, layout: layout) { click(id, twice: twice) } else { session.select(.overview, show: false) }
            }
        case .pick:
            guard !moved, let id = framing(at: g.startLocation, layout: layout) else { return }
            switch session.mode {
            case .draw:
                session.select(.shot(id))
            case .live:
                if session.isTaking {
                    session.liveGo(shot: id)
                } else if let j = session.liveRoute?.script.firstIndex(where: { $0.id == id }) {
                    session.previewPosition(j)
                }
            case .frame:
                break
            }
        }
    }

    /// A click on a framing shows it resting on the stage; a double-click plays its move.
    private func click(_ id: UUID, twice: Bool) {
        if twice, let k = session.clipIndex(of: id) {
            session.watchClip(k)
        } else {
            session.select(.shot(id))
        }
    }
}

/// A point on the slide the map remembers without redrawing for it.
final class MapPoint {
    var uv: Vec2?
}

/// The map's right-click menu: for the framing under the pointer, or the slide.
struct MapMenu: View {
    let session: OOOSession
    let page: Int
    let shot: UUID?
    let at: MapPoint

    var body: some View {
        if session.mode == .frame {
            if let id = shot, let s = session.project.shots.first(where: { $0.id == id }) {
                Button("Show It") { session.select(.shot(id)) }
                Button("Watch It") { if let k = session.clipIndex(of: id) { session.watchClip(k) } }
                Divider()
                Button("Closer") {
                    session.select(.shot(id), show: false)
                    session.nudgeZoom(closer: true)
                }
                Button("Wider") {
                    session.select(.shot(id), show: false)
                    session.nudgeZoom(closer: false)
                }
                Button("Straighten") {
                    session.updateShot(id, "Straighten") { $0.yaw = 0; $0.pitch = 0; $0.roll = 0 }
                }
                .disabled(abs(s.yaw) < 0.01 && abs(s.pitch) < 0.01 && abs(s.roll) < 0.01)
                Picker("Move", selection: session.choiceShot(id, \.move, fallback: .glide, "Move")) {
                    ForEach(MoveKind.allCases) { Text($0.title).tag($0) }
                }
                Picker("While It Holds", selection: session.choiceShot(id, \.emphasis, fallback: .none, "Emphasis")) {
                    ForEach(Emphasis.allCases) { Text($0.title).tag($0) }
                }
                if let k = session.clipIndex(of: id) {
                    Menu("Hold For") {
                        ForEach([1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) { t in
                            Button(secondsLabel(t)) { session.holdFor(clip: k, seconds: t) }
                        }
                    }
                }
                Divider()
                Button("Duplicate") {
                    session.select(.shot(id), show: false)
                    session.duplicateSelectedShot()
                }
                Button("Delete", role: .destructive) {
                    session.select(.shot(id), show: false)
                    session.deleteSelectedShot()
                }
            } else {
                Button("New Framing Here") { session.addShot(around: at.uv, page: page) }
                    .disabled(!session.hasSlide)
                Button("Direct for Me") { session.autoDirect() }
                    .disabled(session.busy != nil || !session.hasSlide)
                Divider()
                Button("Replace Slide…") { OOOCommands.chooseSlide(session, replacing: true, page: page) }
            }
        } else if let id = shot, session.mode == .draw {
            Button("Draw Here") { session.select(.shot(id)) }
        }
    }
}

/// Where the camera is looking right now, drawn on the map as the outline of
/// what it sees: a trapezoid when it is turned, shrinking as it goes in.
struct CameraFootprint: View {
    let session: OOOSession
    @Bindable var clock: PlaybackClock
    let layout: MapLayout
    let page: Int

    var body: some View {
        Canvas { ctx, _ in
            let p = session.project
            // Only while this slide is the one face up, and only while the camera
            // moves: at rest it is the framing's own box.
            guard session.choreography.page(at: clock.time) == page else { return }
            let t = clock.time
            guard clock.playing || session.choreography.beats.contains(where: { t > $0.depart + 0.02 && t < $0.land - 0.02 }) else { return }
            let pose = session.choreography.pose(at: clock.time)
            let A = p.slide(page).aspect, C = p.canvasAspect
            let ndc: [(Float, Float)] = [(-1, 1), (1, 1), (1, -1), (-1, -1)]
            var points: [CGPoint] = []
            for (x, y) in ndc {
                guard let w = pose.hit(x, y, canvasAspect: C) else { return }
                points.append(layout.point(w.x / A + 0.5, 0.5 - w.y))
            }
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            ctx.fill(path, with: .color(Theme.camera.opacity(0.08)))
            ctx.stroke(path, with: .color(Theme.camera.opacity(0.95)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            let c = layout.point(pose.target.x / A + 0.5, 0.5 - pose.target.y)
            let r = 2.5 * layout.mark
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Theme.camera))
        }
    }
}

// MARK: - The map's own pane

/// The slide map at full size, on the left of the video: room to place every
/// framing by eye. Its heading lines up with the stage's status line, the map
/// sits in the middle of the height the video has, and its foot lines up
/// with the transport.
struct MapPane: View {
    let session: OOOSession
    @Bindable var clock: PlaybackClock
    /// The height of the stage's status line.
    let top: CGFloat
    /// The height from the stage's foot to the bottom: the gap and the transport.
    let foot: CGFloat

    var body: some View {
        let page = session.mapPage(at: clock.time)
        let a = MapLayout.aspect(slideAspect: CGFloat(session.project.slide(page).aspect))
        VStack(spacing: 0) {
            MapHeading(session: session, page: page)
                .frame(height: top)
            GeometryReader { g in
                let w = max(min(g.size.width, g.size.height * a), 40)
                SlideMap(session: session, page: page)
                    .frame(width: w, height: w / a)
                    .frame(width: g.size.width, height: g.size.height)
            }
            MapHint(session: session)
                .frame(height: foot)
        }
        .padding(.horizontal, 18)
    }
}

/// The line over the map: which slide it shows, and how many framings are on it.
struct MapHeading: View {
    let session: OOOSession
    let page: Int

    var body: some View {
        let p = session.project
        let n = session.orderedShots.filter { p.pageIndex($0.page) == page }.count
        HStack(spacing: 8) {
            Text(p.slideCount > 1 ? "Slide \(page + 1) of \(p.slideCount)" : "Slide map")
                .textStyle(.label).foregroundStyle(.primary)
            Text(n == 1 ? "1 framing" : "\(n) framings")
                .textStyle(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
}

/// How the map works, in a line. With no framings yet, an invitation to make some.
struct MapHint: View {
    let session: OOOSession

    var body: some View {
        Group {
            if session.project.shots.isEmpty && session.hasSlide {
                VStack(spacing: 4) {
                    Text("Draw a box around what matters, or let OOO plan the tour.")
                        .textStyle(.caption).foregroundStyle(.secondary)
                    Button { session.autoDirect() } label: {
                        Label("Direct for Me", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(session.busy != nil)
                }
            } else {
                Text(session.mapHint ?? defaultHint)
                    .textStyle(.caption).foregroundStyle(session.mapHint == nil ? .tertiary : .secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var defaultHint: String {
        switch session.mode {
        case .frame: return "Drag on the slide to draw a framing. Click one to pick it; drag its corners to go closer."
        case .draw: return "Click a framing to draw on it."
        case .live: return session.isTaking ? "Click a position to go there now." : "Click a position to see it."
        }
    }
}

/// The edge between the map and the video. Drag it to give either more room;
/// double-click it to let the video's shape decide again.
struct MapEdge: View {
    /// The map's share of the stage area's width; 0 lets the video's shape decide.
    @Binding var share: Double
    let width: CGFloat
    let map: CGFloat
    @State private var start: CGFloat?
    @State private var hover = false

    var body: some View {
        Rectangle()
            .fill(hover || start != nil ? Theme.camera.opacity(0.6) : Theme.hairline)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hover = inside
                        if inside { NSCursor.resizeLeftRight.set() } else if start == nil { NSCursor.arrow.set() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            if start == nil { start = map }
                            share = Double(((start ?? map) + g.translation.width) / max(width, 1))
                        }
                        .onEnded { _ in
                            start = nil
                            if !hover { NSCursor.arrow.set() }
                        })
                    .onTapGesture(count: 2) { share = 0 }
            }
            .help("Drag to give the map or the video more room. Double-click to let the video's shape decide again.")
            .accessibilityHidden(true)
    }
}

/// How the stage area divides between the slide map and the video. The video
/// keeps the width its shape needs at full height, and the map goes beside it
/// when that leaves the map more room than the inspector would give it: a
/// tall video in most windows, a square one in a wide window. Otherwise the
/// map stays in the inspector. Once the edge between them is dragged, the map
/// keeps its share.
struct StageColumns {
    let map: CGFloat
    let stage: CGFloat
    var shown: Bool { map > 0 }

    /// The narrowest the video's column goes, so the transport and the pen's tray fit under it.
    static let least: CGFloat = 280
    /// The least room worth giving the map beside the video: a little more than the inspector has.
    static let worth: CGFloat = 340

    init(size: CGSize, videoAspect: CGFloat, videoHeight: CGFloat, margin: CGFloat, map wanted: Bool, share: Double) {
        let W = max(size.width - 1, 1)
        let natural = videoHeight * videoAspect + 2 * margin
        guard wanted, share > 0 || W - natural >= Self.worth else {
            map = 0
            stage = size.width
            return
        }
        var s = share > 0 ? W * (1 - CGFloat(min(max(share, 0.2), 0.8))) : natural
        s = max(s, min(Self.least, W * 0.6)).rounded()
        stage = s
        map = W - s
    }
}
