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
}

/// The slide seen from above, with every framing the camera lands on drawn
/// over it as the outline of what the video shows there. Drag a framing to
/// move it, a corner to go closer or further, Option-drag to turn the camera; draw on
/// the slide to add a framing at the playhead.
/// The slide map for the slide the inspector is about: the selected
/// shot's, or the one face up at the playhead.
struct MapHost: View {
    let session: OOOSession
    @Bindable var clock: PlaybackClock

    var body: some View {
        SlideMap(session: session, page: session.mapPage(at: clock.time))
    }
}

struct SlideMap: View {
    @Bindable var session: OOOSession
    /// The slide shown (0 is the first).
    let page: Int
    @State private var gesture: MapGesture?
    @State private var drawing: CGRect?
    @State private var hovered: UUID?

    enum MapGesture {
        case move(UUID, ShotFrame, CGPoint)
        case resize(UUID, ShotFrame, CGPoint)
        case tilt(UUID, Float, Float, CGPoint)
        case create(CGPoint)
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
                    let hit = hitShot(p, layout: layout)
                    if hit != hovered { hovered = hit }
                    if hitHandle(p, layout: layout) != nil {
                        NSCursor.crosshair.set()
                    } else if hit != nil {
                        NSCursor.openHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                case .ended:
                    hovered = nil
                    NSCursor.arrow.set()
                }
            }
        }
        .aspectRatio(MapLayout.aspect(slideAspect: A), contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Slide map")
        .accessibilityValue("\(session.project.shots.count) framings")
    }

    // MARK: Drawing

    /// What the camera shows once it lands on a shot: the canvas's outline on
    /// the slide (a trapezoid when the shot is turned), and the framing it
    /// keeps in the canvas's clear part.
    struct Finder {
        let shot: Shot
        let index: Int
        let outline: [CGPoint]
        let framing: CGRect
        var bounds: CGRect {
            let xs = outline.map(\.x), ys = outline.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
    }

    private func finder(_ shot: Shot, index: Int, layout: MapLayout) -> Finder {
        let p = session.project
        let A = p.slide(page).aspect, C = p.canvasAspect
        let pose = CameraPose(shot: shot, slideAspect: A, canvasAspect: C, safe: p.format.safeArea)
        var outline: [CGPoint] = []
        for (x, y) in [(Float(-1), Float(1)), (1, 1), (1, -1), (-1, -1)] {
            guard let w = pose.hit(x, y, canvasAspect: C) else { outline = []; break }
            outline.append(layout.point(w.x / A + 0.5, 0.5 - w.y))
        }
        if outline.isEmpty {
            let r = layout.rect(shot.frame.visible(slideAspect: A, canvasAspect: C))
            outline = corners(r)
        }
        return Finder(shot: shot, index: index, outline: outline, framing: layout.rect(shot.frame))
    }

    private func finders(_ layout: MapLayout) -> [Finder] {
        session.orderedShots.enumerated().compactMap { i, s in
            session.project.pageIndex(s.page) == page ? finder(s, index: i, layout: layout) : nil
        }
    }

    private func path(_ outline: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(outline)
        path.closeSubpath()
        return path
    }

    private func drawFramings(_ ctx: GraphicsContext, layout: MapLayout) {
        let p = session.project
        let selectedID: UUID? = {
            if case .shot(let id) = session.selection { return id }
            return nil
        }()
        if session.selection == .overview && page == 0 {
            let f = finder(p.overview, index: 0, layout: layout)
            ctx.stroke(path(f.outline), with: .color(Theme.camera.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round, dash: [5, 4]))
        }
        // The route the camera takes, from framing to framing.
        let mine = session.orderedShots.filter { p.pageIndex($0.page) == page }.map(\.frame.center)
        let route = (page == 0 ? [p.overview.frame.center] : []) + mine
        if route.count > 1 {
            var path = Path()
            path.move(to: layout.point(route[0].x, route[0].y))
            for c in route.dropFirst() { path.addLine(to: layout.point(c.x, c.y)) }
            ctx.stroke(path, with: .color(Color.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4]))
        }
        for f in finders(layout) {
            let selected = f.shot.id == selectedID
            let hot = f.shot.id == hovered
            let outline = path(f.outline)
            if selected {
                ctx.fill(outline, with: .color(Theme.cameraSoft))
                ctx.stroke(outline, with: .color(Theme.camera), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                // The part kept clear of a phone's interface.
                ctx.stroke(Path(roundedRect: f.framing, cornerRadius: 2), with: .color(Theme.camera.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                for corner in f.outline {
                    let h = CGRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7)
                    ctx.fill(Path(roundedRect: h, cornerRadius: 1.5), with: .color(.white))
                    ctx.stroke(Path(roundedRect: h, cornerRadius: 1.5), with: .color(Theme.camera), lineWidth: 1)
                }
            } else {
                ctx.stroke(outline, with: .color(Color.white.opacity(hot ? 0.9 : 0.5)), style: StrokeStyle(lineWidth: hot ? 1.3 : 1, lineJoin: .round))
            }
            // The shot's number, in a small tab on its top-left corner.
            let top = f.outline.min { $0.x + $0.y < $1.x + $1.y } ?? f.bounds.origin
            let label = ctx.resolve(Text("\(f.index + 1)").font(.system(size: 9, weight: .bold)).foregroundColor(selected ? .white : .black))
            let size = label.measure(in: CGSize(width: 40, height: 20))
            let tab = CGRect(x: top.x, y: top.y - size.height - 3, width: size.width + 8, height: size.height + 3)
            ctx.fill(Path(roundedRect: tab, cornerRadius: 3), with: .color(selected ? Theme.camera : Color.white.opacity(hot ? 0.95 : 0.75)))
            ctx.draw(label, at: CGPoint(x: tab.midX, y: tab.midY), anchor: .center)
        }
    }

    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    // MARK: Hit testing

    private func hitHandle(_ p: CGPoint, layout: MapLayout) -> UUID? {
        guard let shot = session.selectedShot else { return nil }
        for c in finder(shot, index: 0, layout: layout).outline where hypot(c.x - p.x, c.y - p.y) <= 8 { return shot.id }
        return nil
    }

    /// The framing under the pointer: the selected one first, then the smallest.
    private func hitShot(_ p: CGPoint, layout: MapLayout) -> UUID? {
        let all = finders(layout)
        // Inside the outline, or within a few points of its edge.
        func contains(_ f: Finder) -> Bool {
            let outline = path(f.outline)
            return outline.contains(p) || outline.strokedPath(StrokeStyle(lineWidth: 6)).contains(p)
        }
        if let s = session.selectedShot, let f = all.first(where: { $0.shot.id == s.id }), contains(f) { return s.id }
        return all.filter(contains).min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }?.shot.id
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
        if let id = hitHandle(p, layout: layout), let shot = session.selectedShot {
            session.beginEdit("Frame Shot")
            gesture = .resize(id, shot.frame, p)
        } else if let id = hitShot(p, layout: layout), let shot = session.project.shots.first(where: { $0.id == id }) {
            if session.selection != .shot(id) { session.select(.shot(id), show: false) }
            if NSEvent.modifierFlags.contains(.option) {
                session.beginEdit("Turn Camera")
                gesture = .tilt(id, shot.yaw, shot.pitch, p)
            } else {
                session.beginEdit("Move Framing")
                gesture = .move(id, shot.frame, p)
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
        case .move(let id, let start, _):
            session.liveShot(id) { s in
                s.frame.center = Vec2(min(max(start.center.x + du, -0.05), 1.05), min(max(start.center.y + dv, -0.05), 1.05))
            }
        case .resize(let id, let start, let origin):
            let c = layout.point(start.center.x, start.center.y)
            let d0 = max(hypot(origin.x - c.x, origin.y - c.y), 4)
            let d1 = hypot(g.location.x - c.x, g.location.y - c.y)
            let k = Float(max(d1 / d0, 0.05))
            session.liveShot(id) { s in
                let size = start.size * k
                let biggest = max(size.x, size.y)
                let shrink: Float = biggest > 1.4 ? 1.4 / biggest : 1
                s.frame.size = Vec2(max(size.x * shrink, 0.012), max(size.y * shrink, 0.012))
            }
        case .tilt(let id, let yaw, let pitch, _):
            session.liveShot(id) { s in
                s.yaw = clamp(yaw + Float(g.translation.width) * 0.3, -25, 25)
                s.pitch = clamp(pitch - Float(g.translation.height) * 0.3, -20, 20)
            }
        case .create(let start):
            let r = CGRect(x: min(start.x, g.location.x), y: min(start.y, g.location.y),
                           width: abs(g.location.x - start.x), height: abs(g.location.y - start.y))
            drawing = r.width > 3 || r.height > 3 ? r : nil
        }
    }

    private func end(_ g: DragGesture.Value, layout: MapLayout) {
        defer {
            gesture = nil
            drawing = nil
        }
        guard let gesture else { return }
        let moved = hypot(g.translation.width, g.translation.height) > 3
        switch gesture {
        case .move(let id, _, _):
            session.commitEdit("Move Framing")
            NSCursor.openHand.set()
            if !moved { session.select(.shot(id)) }
        case .resize:
            session.commitEdit("Frame Shot")
        case .tilt(let id, _, _, _):
            session.commitEdit("Turn Camera")
            if !moved { session.select(.shot(id)) }
        case .create:
            if let r = drawing, r.width > 10, r.height > 10 {
                let a = layout.uv(CGPoint(x: r.minX, y: r.minY)), b = layout.uv(CGPoint(x: r.maxX, y: r.maxY))
                session.addShot(frame: ShotFrame(center: (a + b) / 2, size: b - a), page: page)
            } else if !moved {
                session.select(.overview, show: false)
            }
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
            // Only while this slide is the one face up.
            guard session.choreography.page(at: clock.time) == page else { return }
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
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(Theme.camera))
        }
    }
}
