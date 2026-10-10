import BackdropKit
import CoreGraphics
import Foundation
import Metal
import OOOMotion
import RenderCore
import StageKit
import simd

/// Everything one frame of an OOO video depends on: the project, the camera's
/// path through it, and its slides on the GPU.
public struct SlideScene: @unchecked Sendable {
    public let project: OOOProject
    public let choreography: Choreography
    /// Every slide, the first first.
    public let bases: [MTLTexture]
    /// Sharper copies of the parts the camera goes close to, slide by slide.
    public let details: [DetailCache?]
    /// The marks drawn on the card, in the project's order; nil for one not drawn yet.
    public let inks: [MTLTexture?]
    /// How much body each mark's ink has, 0…1: on a light slide it is a
    /// glaze the slide shows through, on a dark one it still shows.
    let inkBodies: [Float]
    /// Draws marks with 1.0.1's flat ink instead, for comparing the two.
    public var flatInk = false
    /// Marks shown whole whenever their slide lies face up, whatever the
    /// time: the ones the pen is drawing now, so you see what you drew.
    public var pinned: Set<UUID> = []
    /// Where the camera recording is (see `OOOProject.face`); without it
    /// the room stays empty.
    public var faceURL: URL?

    /// The words over the opening, when there are some.
    public private(set) var title: TitleOverlay?
    /// Whether the words were set for the stage risen above a Lift's room.
    let titleLifted: Bool

    public init(project: OOOProject, bases: [MTLTexture], details: [DetailCache?], inks: [MTLTexture?] = [],
                choreography: Choreography? = nil) {
        precondition(!bases.isEmpty, "a scene needs its first slide")
        self.project = project
        // A slide still being drawn shows the first in its place for now.
        self.bases = (0..<project.slideCount).map { $0 < bases.count ? bases[$0] : bases[0] }
        let shownDetails = (0..<project.slideCount).map { $0 < details.count && $0 < bases.count ? details[$0] : nil }
        self.details = shownDetails
        self.inks = (project.marks ?? []).indices.map { $0 < inks.count ? inks[$0] : nil }
        let sources = shownDetails.map { $0?.source }
        self.inkBodies = (project.marks ?? []).map { m in
            let p = project.pageIndex(m.page)
            let ground = p < sources.count ? sources[p].flatMap { InkCache.shared.ground(under: m, on: $0) } : nil
            return InkCache.body(of: m.color, onGround: ground)
        }
        let c = choreography ?? project.choreography()
        self.choreography = c
        title = nil
        titleLifted = Self.liftedWhileTitled(c)
        if let words = project.title, !words.isEmpty, let first = c.beats.first {
            let opening = titleLifted ? c.lifted?.first?.pose ?? first.pose : first.pose
            let A = project.slideAspect, safe = project.format.safeArea, C = project.canvasAspect
            // The ink that stands out most from the backdrop behind the words,
            // as it shows while they are read.
            let shown = first.land + 0.6
            let band = OpeningTitleArt.band(opening: opening, slideAspect: A, canvasAspect: C, safe: safe)
            let ground = TitleGround.luminance(project.backdrop, phase: backdropPhase(at: shown),
                                               uv: backdropUV(at: shown, canvasAspect: C), canvasAspect: C, band: band)
            let light = ground.map(TitleGround.lightInk(onLuminance:)) ?? (project.backdrop.palette.meanLightness < 0.55)
            var h = Hasher()
            h.combine(words)
            h.combine(light)
            h.combine(project.overview.yaw)
            h.combine(project.overview.pitch)
            h.combine(project.overview.frame.size.y)
            h.combine(A)
            h.combine(titleLifted)
            title = TitleOverlay(key: h.finalize(), timing: .opening, scrim: 0) { w, hgt in
                let C = Float(w) / Float(max(hgt, 1))
                let band = OpeningTitleArt.band(opening: opening, slideAspect: A, canvasAspect: C, safe: safe)
                return OpeningTitleArt.draw(words, width: w, height: hgt, band: band, lightInk: light)
            }
        }
    }

    /// A scene of the first slide alone (any others show it in their place).
    public init(project: OOOProject, base: MTLTexture, details: DetailCache?, choreography: Choreography? = nil) {
        self.init(project: project, bases: [base], details: [details], choreography: choreography)
    }

    /// The first slide.
    public var base: MTLTexture { bases[0] }

    public var duration: Double { choreography.duration }

    /// Whether the stage is mostly up while the opening title shows, so the
    /// words are set in the band left above it then.
    static func liftedWhileTitled(_ c: Choreography) -> Bool {
        guard c.lift != nil, let first = c.beats.first else { return false }
        let until = c.beats.count > 1 ? c.beats[1].depart : c.duration
        let samples = stride(from: max(first.land - 0.45, 0), through: max(until, first.land), by: 0.25)
        return samples.contains { c.liftAmount(at: $0) > 0.5 }
    }

    /// How far below where they were set the title's words sit at `t`, as a
    /// share of the frame height: they keep their place over the slide as
    /// the stage rises or settles.
    func titleShift(at t: Double, canvasAspect C: Float) -> Float {
        guard let lifted = choreography.lifted?.first?.pose, let flat = choreography.beats.first?.pose else { return 0 }
        let w = choreography.liftAmount(at: t)
        let set = titleLifted ? lifted : flat
        let now = CameraPose.blend(flat, lifted, w)
        return slideTop(now, canvasAspect: C) - slideTop(set, canvasAspect: C)
    }

    /// Where the top of the slide is in the frame, as a share of its height from the top.
    func slideTop(_ pose: CameraPose, canvasAspect C: Float) -> Float {
        let A = project.slideAspect
        let corners = [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 1)].map { Vec3(($0.x - 0.5) * A, 0.5 - $0.y, 0) }
        guard let box = pose.bounds(of: corners, canvasAspect: C) else { return 0 }
        return (1 - box.w) / 2
    }

    // MARK: Slides

    /// Where each texture sits in the list the renderer draws from: the
    /// close-up of the slide face up, the close-up of the one melting away,
    /// every slide, then every mark. A card's media index is its place there.
    static let patchMedia = 0
    static let oldPatchMedia = 1
    func baseMedia(_ k: Int) -> Int { 2 + min(max(k, 0), bases.count - 1) }
    func inkMedia(_ i: Int) -> Int { 2 + bases.count + i }

    /// Every texture the frame at `t` may draw, in the order the media indices name.
    func textures(patch: DetailCache.Patch?, oldPatch: DetailCache.Patch?, at t: Double) -> [MTLTexture] {
        let k = page(at: t)
        return [patch?.texture ?? bases[k], oldPatch?.texture ?? bases[0]] + bases + inks.map { $0 ?? bases[0] }
    }

    /// The `k`th slide's width / height.
    public func aspect(_ k: Int) -> Float { project.slide(k).aspect }

    /// The slide face up at `t` (0 is the first): the one the card is
    /// changing to, once it has started to.
    public func page(at t: Double) -> Int { min(choreography.page(at: t), bases.count - 1) }

    /// How much of the slide's dressing at rest (a sharp close-up, an
    /// emphasis, a mark) may show at `t`: none while the card turns over,
    /// going just before and coming back just after.
    public func slideShown(at t: Double) -> Float {
        var shown: Float = 1
        for c in choreography.changes where c.kind == .turn {
            if t <= c.start {
                shown = min(shown, 1 - smoothstep(Float((t - (c.start - 0.3)) / 0.3)))
            } else if t >= c.end {
                shown = min(shown, smoothstep(Float((t - c.end) / 0.3)))
            } else {
                shown = 0
            }
        }
        return shown
    }

    /// The card at `t` while it turns over: whichever slide's face the
    /// camera sees, at its own size, swapped as the card passes edge-on to
    /// the eye so neither ever shows its back.
    func dressTurn(_ card: inout CardPose, at t: Double, eye: Vec3) {
        guard let now = choreography.change(at: t), now.change.kind == .turn else { return }
        let c = now.change
        // The face up as the turn starts (turning back, as it ends).
        let up = c.back ? c.to : c.from, down = c.back ? c.from : c.to
        let front = SIMD2<Float>(aspect(up), 1), back = SIMD2<Float>(aspect(down), 1)
        let tp = CardTurn.pose(now.progress, back: c.back, direction: choreography.turnSign)
        let rotation = card.rotation + SIMD3(tp.rotation.x, tp.rotation.y, tp.rotation.z)
        let center = card.position + SIMD3(tp.offset.x, tp.offset.y, tp.offset.z)
        let n4 = Matrix.rotationEuler(rotation) * SIMD4<Float>(0, 0, 1, 0)
        let frontNormal = SIMD3(n4.x, n4.y, n4.z)
        let toEye = simd_normalize(SIMD3(eye.x, eye.y, eye.z) - center)
        let facing = simd_dot(frontNormal, toEye)
        // The card changes shape only while it is all but edge-on.
        let w = smoothstep((0.35 - facing) / 0.7)
        let size = front + (back - front) * w
        card.curl += tp.curl
        if facing >= 0 {
            card.media = baseMedia(up)
            card.mediaAspect = aspect(up)
            card.rotation = rotation
        } else {
            // The same card seen from behind: turned half over about its own upright.
            card.media = baseMedia(down)
            card.mediaAspect = aspect(down)
            card.rotation = SIMD3(-rotation.x, rotation.y - choreography.turnSign * .pi, -rotation.z)
            card.curl = -card.curl
        }
        card.size = size
        // It turns about the middle of its thickness, so its edge never jumps
        // as the faces swap, and it lands where it started.
        let shown = facing >= 0 ? frontNormal : -frontNormal
        let thickness = 0.012 * min(size.x, size.y) * project.look.edge
        card.position = center + (shown - SIMD3(0, 0, 1)) * (thickness / 2)
    }

    /// A melt under way: the slide melting away is kept exactly where the
    /// eye had it, moved and scaled with the camera's unseen cut, and the
    /// next washes in through it from where the camera looks.
    struct MeltState {
        /// The slides it melts from and to.
        var from: Int
        var to: Int
        var progress: Float
        /// Where it spreads from, on the plane of the card.
        var focus: SIMD2<Float>
        var radius: Float
        var front: Float
        /// The old slide is drawn at `shift + scale · x`.
        var scale: Float
        var shift: SIMD2<Float>
        /// The camera on the old slide, as it rested there.
        var before: CameraPose
    }

    func melting(at t: Double) -> MeltState? {
        guard let now = choreography.change(at: t), now.change.kind == .melt else { return nil }
        let c = now.change
        let (a, b) = choreography.meltHandoff(c)
        let k = b.height / max(a.height, 1e-5)
        let shift = SIMD2(b.target.x, b.target.y) - k * SIMD2(a.target.x, a.target.y)
        let focus = SIMD2(b.target.x, b.target.y)
        let view = b.height
        // Far enough to take in the farthest corner of either card.
        let An = aspect(c.to), Ao = aspect(c.from)
        var far: Float = 0
        for (sx, sy) in [(Float(-1), Float(-1)), (1, -1), (-1, 1), (1, 1)] {
            let new = SIMD2(sx * An / 2, sy * 0.5)
            let old = shift + k * SIMD2(sx * Ao / 2, sy * 0.5)
            far = max(far, simd_length(new - focus), simd_length(old - focus))
        }
        let r = Melt.radius(now.progress, start: 0.03 * view, reach: Melt.reach(farthest: far, view: view))
        return MeltState(from: c.from, to: c.to, progress: now.progress, focus: focus, radius: r,
                         front: Melt.front(r, view: view), scale: k, shift: shift, before: a)
    }

    /// Where the canvas point (x, y), in −1…1 with y up, touches the card at
    /// `t`: the slide face up and the place on it (0…1 from the top left).
    /// Nil while the card arrives, leaves, turns or melts: a pen draws only
    /// on a card at rest.
    public func touch(_ x: Float, _ y: Float, at t: Double, canvasAspect C: Float) -> (page: Int, x: Float, y: Float)? {
        guard slidePose(at: t, canvasAspect: C) == .rest, slideShown(at: t) > 0.99, choreography.change(at: t) == nil,
              let p = choreography.pose(at: t).hit(x, y, canvasAspect: C) else { return nil }
        let k = page(at: t)
        return (k, p.x / aspect(k) + 0.5, 0.5 - p.y)
    }

    /// Where the place (x, y) on slide `k` (0…1 from the top left) shows on
    /// the canvas at `t`, in −1…1 with y up, with the card at rest.
    public func canvasPoint(_ x: Float, _ y: Float, page k: Int, at t: Double, canvasAspect C: Float) -> SIMD2<Float>? {
        choreography.pose(at: t).project(SIMD3((x - 0.5) * aspect(k), 0.5 - y, 0), canvasAspect: C)
    }

    /// The slide's own pose at `t`: arriving, resting, or leaving.
    public func slidePose(at t: Double, canvasAspect: Float) -> SlidePose {
        if project.ending == .leave {
            let p = choreography.endingProgress(at: t)
            if p > 0 { return Arrival.leaving(p) }
        }
        return Arrival.slide(at: t, arrive: project.arrive, canvasAspect: canvasAspect)
    }

    /// How far a spotlight has come in at `t` (0…1): the room dims with it.
    public func spotlight(at t: Double) -> Float {
        guard let e = choreography.emphasis(at: t), choreography.beats[e.beat].shot.emphasis == .spotlight else { return 0 }
        return e.amount
    }

    /// How much of the at-rest dressing (the sharp close-up) is laid over the
    /// slide in pose `sp`: all of it at rest, none while it arrives, and over a
    /// Leave's first moments it fades as the slide sets off, so nothing pops.
    func restHold(at t: Double, pose sp: SlidePose) -> Float {
        let shown = slideShown(at: t)
        if sp == .rest { return shown }
        guard project.ending == .leave else { return 0 }
        let p = choreography.endingProgress(at: t)
        return p > 0 ? (1 - smootherstep(p / 0.2)) * shown : 0
    }

    /// How much of the surface's light shows at `t`: all of it while the slide
    /// arrives and the camera travels, a trace while the camera holds and the
    /// slide is read, so black type stays black.
    public func surfaceAmount(at t: Double) -> Float {
        var reading = choreography.settled(at: t) * (1 - choreography.endingProgress(at: t))
        // A turning card catches the light.
        if let now = choreography.change(at: t), now.change.kind == .turn { reading *= 1 - CardTurn.activity(now.progress) }
        return 1 - (1 - Self.surfaceAtRest) * reading
    }

    /// The share of the surface's light left while the slide is read.
    public static let surfaceAtRest: Float = 0.12

    /// How much of the picture is left as a fade ending closes (1 = all).
    public func presence(at t: Double) -> Float {
        project.ending == .fade ? 1 - choreography.endingProgress(at: t) : 1
    }

    /// The finishing look at `t`: depth of field follows the shot's aperture
    /// and deepens as the camera goes in, so a close-up becomes a macro shot;
    /// the slide bends like paper while it unrolls or falls.
    public func look(at t: Double, canvasAspect: Float) -> StageLook {
        var l = project.look
        let cam = choreography.pose(at: t)
        let overview = choreography.beats.first?.pose ?? cam
        let closer = max(log2f(overview.height / max(cam.height, 1e-4)), 0)
        l.depthOfField = clamp01(project.look.depthOfField * (0.3 + 1.4 * cam.aperture) * (1 + 0.3 * min(closer, 4)))
        l.bend = slidePose(at: t, canvasAspect: canvasAspect).paper ? .paper : .card
        l.bendAmount = 1
        return l
    }

    /// The camera for the renderer, which places its eye relative to the
    /// position that frames a canvas one unit tall.
    public static func stageCamera(_ cam: CameraPose) -> StageCamera {
        var c = StageCamera()
        c.fov = cam.fov
        c.target = SIMD3(cam.target.x, cam.target.y, 0)
        let eye = cam.eye
        c.offset = SIMD3(eye.x, eye.y, eye.z - StageCamera.distance(fov: cam.fov))
        c.roll = cam.roll
        return c
    }

    /// Where the backdrop is in its loop at `t`: it runs whole cycles of about
    /// twelve seconds over the video's length in frames, so the last frame
    /// leads back into the first when a platform plays the video on repeat.
    public func backdropPhase(at t: Double) -> Double {
        let fps = Double(max(project.fps, 1))
        let length = Double(max(1, Int((duration * fps).rounded()))) / fps
        let cycles = max(1, (length / 12).rounded())
        return t * cycles / length
    }

    /// The background's answer to the camera: a distant plane, it shifts a
    /// little as the camera turns and pans and comes a touch closer as it goes
    /// in. As a Leave ending empties the frame, it drifts back to where it
    /// was on the first frame, so the video loops without a jump.
    public func backdropUV(at t: Double, canvasAspect C: Float) -> SIMD4<Float> {
        let here = cameraBackdropUV(at: t, canvasAspect: C)
        guard project.ending == .leave else { return here }
        let back = choreography.endingProgress(at: t)
        return back > 0 ? simd_mix(here, cameraBackdropUV(at: 0, canvasAspect: C), SIMD4(repeating: back)) : here
    }

    func cameraBackdropUV(at t: Double, canvasAspect C: Float) -> SIMD4<Float> {
        let cam = choreography.pose(at: t)
        let fovV = radians(cam.fov)
        let fovH = 2 * atanf(tanf(fovV / 2) * C)
        let overview = choreography.beats.first?.pose ?? cam
        let closer = clamp01(logf(overview.height / max(cam.height, 1e-4)) / logf(12))
        let s: Float = 0.86 * (1 - 0.05 * closer)
        let room = (1 - s) / 2
        let ox = -cam.yaw / max(fovH, 0.1) * 0.3 + 0.02 * cam.target.x
        let oy = cam.pitch / max(fovV, 0.1) * 0.3 - 0.02 * cam.target.y
        return SIMD4(s, s, clamp(ox, -room, room), clamp(oy, -room, room))
    }

    /// The stage at `t` on a canvas of `canvasAspect`, with an optional sharper
    /// detail laid over the slide face up (and, while one slide melts into the
    /// next, over the one melting away).
    public func stageFrame(at t: Double, canvasAspect C: Float, outputWidth: Int, patch: DetailCache.Patch?,
                           oldPatch: DetailCache.Patch? = nil) -> StageFrame {
        let k = page(at: t)
        let A = aspect(k)
        let cam = choreography.pose(at: t)
        let melt = melting(at: t)
        var frame = StageFrame()
        frame.camera = Self.stageCamera(cam)
        // Two cards in one place while one melts into the other: neither's
        // shadow may fall on the other.
        frame.shadowsOnCards = melt == nil
        if project.arrive.kind.onTable {
            // Dropped onto a table: the slide lies on it and its shadow stays tucked under.
            frame.fixedGround = true
            frame.groundZ = -0.004
        }

        let sp = slidePose(at: t, canvasAspect: C)
        let shown = self.presence(at: t)
        // The floor the slide stands on: a tall frame's empty lower half
        // holds its reflection instead of plain backdrop.
        let px = Float(outputWidth) / 1080
        frame.floorY = -0.506
        switch project.floorKind {
        case .none:
            break
        case .soft:
            frame.reflection = 0.2 * shown
            frame.reflectionFade = 4.2
            frame.reflectionBlur = 7 * px
        case .mirror:
            frame.reflection = 0.34 * shown
            frame.reflectionFade = 2.4
            frame.reflectionBlur = 1.2 * px
        }
        var slide = CardPose(media: baseMedia(k), occurrence: 0, position: sp.offset, rotation: sp.rotation, size: SIMD2(A, 1))
        slide.curl = sp.curl
        slide.fold = sp.fold
        slide.foldPhase = sp.foldPhase
        slide.opacity = sp.opacity
        slide.blur = sp.blur * Float(outputWidth) / 1080
        slide.glow = sp.glow
        slide.develop = sp.develop
        let light = sp.exposure * shown
        slide.color = SIMD4(light, light, light, 1)
        slide.corner = 0.028
        slide.fit = .fill
        slide.mediaAspect = A
        slide.shadow = shown
        slide.surfaceAmount = surfaceAmount(at: t)
        if let melt {
            slide.melt = SIMD4(melt.focus.x, melt.focus.y, melt.radius, melt.front)
            slide.shadow = shown * smoothstep(melt.progress)
        }
        let slideAtRest = slide
        dressTurn(&slide, at: t, eye: cam.eye)

        let atRest = sp == .rest && slideShown(at: t) > 0.001 && melt == nil
        var cards: [CardPose] = []
        var lifted: CardPose?

        if atRest, let emphasis = choreography.emphasis(at: t) {
            let amount = emphasis.amount
            let shot = choreography.beats[emphasis.beat].shot
            let focus = shot.focus ?? shot.frame
            // Softness in slide heights; the engine measures it against the slide's shorter side.
            let side = min((focus.size.x) * A, focus.size.y)
            let unit = min(A, 1)
            switch shot.emphasis {
            case .spotlight:
                // A soft pool of light on the detail, not a box: the rest of
                // the slide falls away gently, and the room dims with it.
                slide.spot = Self.padded(focus.bounds, by: 0.08)
                slide.spotDim = 0.42 * amount
                slide.spotFeather = max(0.45 * side, 0.03) / unit
            case .lift:
                // The piece that rises carries a wide margin it fades out
                // across, and the slide only dims beyond that margin, so its
                // edge never shows as a step in brightness.
                let m = max(min(focus.size.x, focus.size.y), 0.02)
                let r = Self.padded(focus.bounds, by: 0.7)
                slide.spot = Self.padded(focus.bounds, by: 1.15)
                slide.spotDim = 0.2 * amount
                slide.spotFeather = max(0.9 * m, 0.02) / unit
                lifted = Self.cutOut(r, slideAspect: A, amount: amount, patch: patch, light: light, fade: 0.45 * m,
                                     surface: slide.surfaceAmount, base: baseMedia(k))
            case .none:
                break
            }
        }
        if let weave = sp.weave {
            // A Weave: the slide's threads are drawn instead of it, and it only
            // casts their shadow, deepening as they come together. It goes
            // first, so its shadow falls under them.
            let n = Arrival.threads
            let turn = Matrix.rotationEuler(slide.rotation)
            for i in 0..<n {
                let th = Arrival.thread(i, of: n, at: weave, seed: project.seed, slideAspect: A, intensity: project.arrive.intensity)
                guard th.opacity > 0.001 else { continue }
                var thread = slide
                thread.occurrence = 10 + i
                thread.crop = SIMD4(0, Float(i) / Float(n), 1, Float(i + 1) / Float(n))
                thread.size = SIMD2(slide.size.x, slide.size.y / Float(n))
                let local = SIMD3<Float>(0, slide.size.y * (0.5 - (Float(i) + 0.5) / Float(n)), 0) + th.offset
                let moved = turn * SIMD4(local, 0)
                thread.position = slide.position + SIMD3(moved.x, moved.y, moved.z)
                thread.rotation = slide.rotation + SIMD3(0, 0, th.roll)
                thread.opacity = slide.opacity * th.opacity
                thread.band = SIMD4(0.6, th.loose, 0.5, 0.05)
                thread.shadow = 0
                thread.edgeScale = 0
                cards.append(thread)
            }
            slide.reveal = -0.01
            slide.layer = -1
            slide.shadow = shown * smoothstep((weave - 0.15) / 0.8)
        }
        cards.insert(slide, at: 0)

        // The slide melting away, kept where the eye had it, over the next.
        var old: CardPose?
        if let melt {
            var o = slideAtRest
            o.media = baseMedia(melt.from)
            o.mediaAspect = aspect(melt.from)
            o.occurrence = 3
            o.size = SIMD2(aspect(melt.from), 1) * melt.scale
            o.position = SIMD3(melt.shift.x + melt.scale * slideAtRest.position.x, melt.shift.y + melt.scale * slideAtRest.position.y,
                               melt.scale * slideAtRest.position.z)
            o.melt = SIMD4(melt.focus.x, melt.focus.y, melt.radius, -melt.front)
            o.shadow = shown * (1 - smoothstep(melt.progress))
            o.layer = 0.5
            cards.append(o)
            old = o
        }

        let hold = restHold(at: t, pose: sp)
        if hold > 0.001, let patch {
            var detail = Self.overlay(patch.region, on: slideAtRest)
            detail.media = Self.patchMedia
            detail.occurrence = 1
            detail.opacity = slideAtRest.opacity * hold
            detail.layer = 0.25
            cards.append(detail)
        }
        if let old, let oldPatch {
            var detail = Self.overlay(oldPatch.region, on: old)
            detail.media = Self.oldPatchMedia
            detail.occurrence = 4
            detail.opacity = old.opacity * hold
            detail.layer = 0.75
            cards.append(detail)
        }
        cards += inkCards(at: t, page: k, slide: slideAtRest, old: old, melt: melt, hold: hold, light: light)
        if let lifted { cards.append(lifted) }
        frame.cards = cards
        return frame
    }

    /// The marks drawn on the card at `t`: drawing on, lying on the slide
    /// face up, gone before it turns over, melting away with it.
    func inkCards(at t: Double, page k: Int, slide: CardPose, old: CardPose?, melt: MeltState?, hold: Float, light: Float) -> [CardPose] {
        guard hold > 0.001, let marks = project.marks else { return [] }
        var out: [CardPose] = []
        for (i, m) in marks.enumerated() where i < inks.count && inks[i] != nil {
            let pin = pinned.contains(m.id)
            guard let head = pin ? 1 : m.inkHead(at: t) else { continue }
            let p = project.pageIndex(m.page)
            let host: CardPose
            let layer: Float
            if p == k {
                host = slide
                layer = 0.3
            } else if let melt, let old, p == melt.from {
                host = old
                layer = 0.8
            } else {
                continue
            }
            // It stays until its slide changes: gone before the card turns
            // over, or melted away with it.
            let leaves = choreography.changes.first { $0.from == p && $0.end > m.time }
            if !pin, let leaves, t >= leaves.end { continue }
            let presence = pin ? 1 : m.presence(at: t, until: leaves?.kind == .turn ? leaves?.start : nil)
            guard presence > 0.001, let r = m.bounds(slideAspect: aspect(p)) else { continue }
            var ink = Self.overlay(SIMD4(r.u0, r.v0, r.u1, r.v1), on: host)
            ink.media = inkMedia(i)
            ink.occurrence = 100 + i
            ink.layer = layer
            ink.opacity = host.opacity * presence * hold
            // The pen's head: soft over a few hundredths of a second. The ink
            // is a glaze with some body, or 1.0.1's flat ink.
            let soft = Float(min(max(0.05 / m.inkLength, 0.01), 0.2))
            let body = i < inkBodies.count ? inkBodies[i] : 0.5
            ink.ink = SIMD4<Float>(head * (1 + soft), soft, 1 + body, flatInk ? 0 : 1)
            let c = m.ink
            let linear = RGB(c.r, c.g, c.b).linear
            ink.color = SIMD4(linear.x, linear.y, linear.z, light)
            ink.surfaceAmount = 0
            ink.spotDim = 0
            out.append(ink)
        }
        return out
    }

    /// A card laid exactly over part `r` (u0, v0, u1, v1; v down) of `card`,
    /// wherever the card is: a sharper close-up, or ink.
    static func overlay(_ r: SIMD4<Float>, on card: CardPose) -> CardPose {
        var d = card
        d.crop = r
        d.window = r
        d.size = SIMD2(card.size.x * (r.z - r.x), card.size.y * (r.w - r.y))
        let local = SIMD3<Float>(((r.x + r.z) / 2 - 0.5) * card.size.x, (0.5 - (r.y + r.w) / 2) * card.size.y, 0)
        let turned = Matrix.rotationEuler(card.rotation) * SIMD4(local, 0)
        d.position = card.position + SIMD3(turned.x, turned.y, turned.z)
        d.curl = 0
        d.fold = 0
        d.edgeScale = 0
        d.shadow = 0
        d.reflects = false
        return d
    }

    static func padded(_ r: SIMD4<Float>, by k: Float) -> SIMD4<Float> {
        let w = r.z - r.x, h = r.w - r.y
        let p = k * max(min(w, h), 0.02)
        return SIMD4(max(r.x - p, 0), max(r.y - p, 0), min(r.z + p, 1), min(r.w + p, 1))
    }

    /// A detail lifted off the slide as a die-cut piece, its shadow falling on
    /// the slide below. It shows its region of whichever texture holds it best.
    static func cutOut(_ r: SIMD4<Float>, slideAspect A: Float, amount: Float, patch: DetailCache.Patch?, light: Float,
                       fade: Float, surface: Float = 1, base: Int = 2) -> CardPose {
        let ru = max(r.z - r.x, 1e-4), rv = max(r.w - r.y, 1e-4)
        // Low and barely larger: what shows through its fading margin then
        // lines up with the slide beneath, rather than doubling the lines
        // that cross it.
        let lift = amount * (0.006 + 0.08 * rv)
        let grow = 1 + 0.01 * amount
        let center = SIMD3(((r.x + r.z) / 2 - 0.5) * A, 0.5 - (r.y + r.w) / 2, lift)
        var c = CardPose(media: base, occurrence: 2, position: center, rotation: .zero, size: SIMD2(A * ru, rv) * grow)
        // The texture holding region P shows region r when its window is the
        // inverse map: (P − r.xy) / r.size.
        var holder = SIMD4<Float>(0, 0, 1, 1)
        if let patch, patch.region.x <= r.x, patch.region.y <= r.y, patch.region.z >= r.z, patch.region.w >= r.w {
            holder = patch.region
            c.media = patchMedia
        }
        let size = SIMD2(ru, rv)
        let lo = (SIMD2(holder.x, holder.y) - SIMD2(r.x, r.y)) / size
        let hi = lo + SIMD2(holder.z - holder.x, holder.w - holder.y) / size
        c.window = SIMD4(lo.x, lo.y, hi.x, hi.y)
        c.mediaAspect = A * ru / rv
        c.fit = .fill
        // It fades into the slide at its edges, so what rises is the detail,
        // not a rectangle cut through whatever surrounds it.
        c.corner = 0.25
        c.softEdge = fade * grow
        c.edgeScale = 0
        c.reflects = false
        c.shadow = amount * 0.4
        c.shadowGround = 0
        c.layer = 2
        c.opacity = smoothstep(amount / 0.25)
        c.color = SIMD4(light, light, light, 1)
        c.surfaceAmount = surface
        return c
    }
}

/// Renders OOO frames for the live stage and for export.
public final class SlideStage: @unchecked Sendable {
    public let renderer: StageRenderer
    private let titles: TitleCompositor
    private let faces: FaceCompositor

    public init(renderer: StageRenderer? = nil) throws {
        self.renderer = try renderer ?? StageRenderer()
        titles = try TitleCompositor()
        faces = try FaceCompositor()
    }

    /// Lets go of the camera recordings `gone` picks, which the stage no longer shows.
    public func releaseFaces(where gone: (URL) -> Bool) {
        faces.release(gone)
    }

    /// Most pixels between neighbouring shutter samples: closer than this,
    /// a blur's steps can't be told from a continuous smear.
    public static let blurStep: Float = 0.75

    /// Encodes the frame at `t` into `output` and returns how many shutter
    /// samples it took. With `waitForDetail`, close-ups are drawn at full
    /// sharpness before the frame (export); otherwise the best detail at hand
    /// is used and a sharper one is drawn in the background.
    ///
    /// `samples` is the most the frame may take. With `adaptive`, it takes
    /// only as many as the motion across its shutter needs: one while the
    /// camera holds, the most in a fast move.
    @discardableResult
    public func encode(_ cb: MTLCommandBuffer, scene: SlideScene, at t: Double, output: MTLTexture, samples: Int,
                       frameIndex: UInt32, waitForDetail: Bool, backdropScale: Float = 1, transparent: Bool = false,
                       adaptive: Bool = true) throws -> Int {
        let C = Float(output.width) / Float(max(output.height, 1))
        var patch: DetailCache.Patch?, oldPatch: DetailCache.Patch?
        if let details = scene.details[scene.page(at: t)], let fp = footprint(scene, at: t, width: output.width, height: output.height) {
            patch = details.patch(for: fp, wait: waitForDetail)
        }
        if let melt = scene.melting(at: t), let details = scene.details[melt.from] {
            // The slide melting away keeps the close-up it had as the camera rested on it.
            let fp = melt.before.footprint(slideAspect: scene.aspect(melt.from), canvasAspect: C, canvasHeight: output.height)
            oldPatch = details.patch(for: fp, wait: waitForDetail)
        }
        let textures = scene.textures(patch: patch, oldPatch: oldPatch, at: t)

        let look = scene.look(at: t, canvasAspect: C)
        let fps = max(scene.project.fps, 1)
        let shutter = Double(look.shutter) / Double(fps)
        var backdrop = scene.project.backdrop
        backdrop.brightness *= scene.presence(at: t) * (1 - 0.3 * scene.spotlight(at: t))
        var request = StageRenderer.Request(
            width: output.width, height: output.height, backdrop: backdrop, backdropPhase: scene.backdropPhase(at: t), look: look,
            samples: look.shutter > 0.01 ? max(samples, 1) : 1, frameIndex: frameIndex, keepAlpha: transparent,
            drawBackdrop: !transparent)
        request.backdropScale = backdropScale
        request.backdropUV = scene.backdropUV(at: t, canvasAspect: C)
        // Motion blur never reaches across a cut: each sample stays on its side.
        let cut = scene.choreography.cut(between: t - shutter / 2, and: t + shutter / 2)
        let width = output.width, height = output.height
        let frameAt = { (offset: Float) -> StageFrame in
            var ts = t + Double(offset) * shutter
            if let c = cut { ts = t < c ? min(ts, c - 1e-4) : max(ts, c) }
            return scene.stageFrame(at: ts, canvasAspect: C, outputWidth: width, patch: patch, oldPatch: oldPatch)
        }
        if adaptive, request.samples > 1 {
            // The path across the shutter, open to middle to close: an upper
            // bound on how far anything in view moves while it is open.
            let (open, middle, close) = (frameAt(-0.5), frameAt(0), frameAt(0.5))
            let travel = open.travel(to: middle, width: width, height: height) + middle.travel(to: close, width: width, height: height)
            if travel.isFinite {
                request.samples = min(request.samples, max(1, Int((travel / Self.blurStep).rounded(.up))))
            }
        }
        try renderer.encode(cb, output: output, request: request, textures: textures, frameAt: frameAt)
        if let title = scene.title {
            let p = OpeningTitleArt.presence(scene.choreography, at: t)
            try titles.encode(cb, title, alpha: p.alpha * scene.presence(at: t), drop: p.drop + scene.titleShift(at: t, canvasAspect: C),
                              output: output)
        }
        if !transparent, let face = scene.project.face, let url = scene.faceURL, let shown = scene.faceShown(at: t) {
            try faces.encode(cb, url: url, at: t - face.offset, mirrored: face.isMirrored, greenScreen: face.isGreenScreen,
                             room: scene.faceRoom, rise: shown.rise,
                             alpha: shown.alpha, grain: 0.035 * look.finish.grain / 0.14, frameIndex: frameIndex, output: output,
                             wait: waitForDetail)
        }
        return request.samples
    }

    /// What the camera sees of the slide at `t`, when the slide is at rest
    /// (only then does a close-up lie exactly over it).
    func footprint(_ scene: SlideScene, at t: Double, width: Int, height: Int) -> ViewFootprint? {
        let C = Float(width) / Float(max(height, 1))
        guard scene.restHold(at: t, pose: scene.slidePose(at: t, canvasAspect: C)) > 0.001 else { return nil }
        return scene.choreography.pose(at: t).footprint(slideAspect: scene.aspect(scene.page(at: t)), canvasAspect: C, canvasHeight: height)
    }

    /// Starts drawing, in the background, the close-up the frame at `t` will
    /// need, so it is ready when the frame comes.
    public func drawAhead(_ scene: SlideScene, at t: Double, width: Int, height: Int) {
        guard t <= scene.duration, let details = scene.details[scene.page(at: t)],
              let fp = footprint(scene, at: t, width: width, height: height) else { return }
        details.prepare(for: fp)
    }

    /// One frame as a picture: the video's frame nearest `t`, exactly as the
    /// export draws it.
    public func still(_ scene: SlideScene, at t: Double, width: Int, height: Int, samples: Int = 8, adaptive: Bool = true) throws -> CGImage {
        let gpu = GPU.shared
        let out = gpu.makeTexture(width: width, height: height, format: .bgra8Unorm, usage: [.renderTarget, .shaderRead])
        guard let cb = gpu.queue.makeCommandBuffer() else { throw RenderError.io("GPU unavailable.") }
        let fps = Double(max(scene.project.fps, 1))
        let index = max(0, (t * fps).rounded())
        try encode(cb, scene: scene, at: index / fps, output: out, samples: samples, frameIndex: UInt32(index),
                   waitForDetail: true, adaptive: adaptive)
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw RenderError.io("GPU error: \(e.localizedDescription)") }
        guard let img = ImageOutput.cgImage(from: out, premultipliedAlpha: false) else { throw RenderError.io("Could not read the frame.") }
        return img
    }
}

/// Loads a project's slides onto the GPU.
public enum SlideLoader {
    public static func scene(for project: OOOProject, media: URL?, choreography: Choreography? = nil) throws -> SlideScene {
        var bases: [MTLTexture] = []
        var details: [DetailCache?] = []
        for ref in project.allSlides {
            let source = try SlideSource(ref: ref, media: media)
            guard let whole = source.renderWhole() else { throw RenderError.io("Could not draw the slide.") }
            bases.append(try MediaLoader.texture(from: whole).texture)
            details.append(DetailCache(source: source, baseDensity: Float(whole.height)))
        }
        var scene = SlideScene(project: project, bases: bases, details: details, inks: InkCache.shared.textures(for: project),
                               choreography: choreography)
        scene.faceURL = project.face.flatMap { face in media.map { $0.appendingPathComponent(face.file) } }
        return scene
    }
}

/// The marks drawn on the card, drawn into textures: for each texel, when the
/// pen got there and how much ink it left. A mark is drawn once and kept.
public final class InkCache: @unchecked Sendable {
    public static let shared = InkCache()

    private let lock = NSLock()
    /// Each mark's latest drawing and the one before it (so an undo is
    /// instant), by the mark: a mark redrawn at every stroke keeps two
    /// textures, not one for every stroke it ever had.
    private var made: [UUID: [(key: Int, texture: MTLTexture)]] = [:]
    private var grounds: [Int: Float] = [:]

    public init() {}

    /// How much body ink of `color` has on a slide whose luminance under it
    /// is `ground` (linear, 0…1): on a light slide it is mostly a glaze, so
    /// the type it crosses still reads through it; on a dark one, where a
    /// glaze would vanish, it lies thicker and still shows. Chalk is all body.
    static func body(of color: InkColor, onGround ground: Float?) -> Float {
        let body = 0.9 - 0.75 * smoothstep(0.04, 0.3, ground ?? 0.5)
        return color == .white ? max(body, 0.85) : body
    }

    /// The mean linear luminance of the slide under `mark`, drawn small from `source`.
    public func ground(under mark: Mark, on source: SlideSource) -> Float? {
        guard let b = mark.bounds(slideAspect: source.aspect) else { return nil }
        var h = Hasher()
        h.combine(mark.strokes)
        h.combine(mark.width)
        h.combine(source.ref)
        let key = h.finalize()
        lock.lock()
        if let hit = grounds[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let r = SIMD4<Float>(max(b.u0, 0), max(b.v0, 0), min(b.u1, 1), min(b.v1, 1))
        guard r.z > r.x, r.w > r.y else { return nil }
        let w = 32, hgt = max(4, min(64, Int((Float(w) * (r.w - r.y) / ((r.z - r.x) * source.aspect)).rounded())))
        guard let img = source.render(region: r, width: w, height: hgt) else { return nil }
        var px = [UInt8](repeating: 0, count: w * hgt * 4)
        let drawn = px.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: hgt, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: hgt))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: hgt))
            return true
        }
        guard drawn else { return nil }
        func linear(_ v: UInt8) -> Float {
            let c = Float(v) / 255
            return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        var sum: Float = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            sum += 0.2126 * linear(px[i]) + 0.7152 * linear(px[i + 1]) + 0.0722 * linear(px[i + 2])
        }
        let ground = sum / Float(w * hgt)
        lock.lock()
        if grounds.count > 256 { grounds.removeAll() }
        grounds[key] = ground
        lock.unlock()
        return ground
    }

    /// Every mark in the project, in its order.
    public func textures(for project: OOOProject) -> [MTLTexture?] {
        (project.marks ?? []).map { texture(for: $0, slideAspect: project.slide(project.pageIndex($0.page)).aspect) }
    }

    public func texture(for mark: Mark, slideAspect A: Float) -> MTLTexture? {
        var h = Hasher()
        h.combine(mark.strokes)
        h.combine(mark.width)
        h.combine(A)
        let key = h.finalize()
        lock.lock()
        if let hit = made[mark.id]?.first(where: { $0.key == key }) {
            lock.unlock()
            return hit.texture
        }
        lock.unlock()
        guard let raster = InkRaster(mark, slideAspect: A), let texture = Self.upload(raster) else { return nil }
        lock.lock()
        var versions = made[mark.id] ?? []
        versions.removeAll { $0.key == key }
        versions.append((key, texture))
        if versions.count > 2 { versions.removeFirst(versions.count - 2) }
        if made[mark.id] == nil, made.count >= 64 { made.removeAll() }
        made[mark.id] = versions
        lock.unlock()
        return texture
    }

    /// Green: the pen's own ink; blue: the wet fringe past its edge; alpha:
    /// how deep the pen's ink lies, premultiplied by green; red: when the ink
    /// got there, premultiplied by green and blue together. Each smaller level
    /// averages the one above, so a mark seen from far off stays smooth and
    /// draws on at the same moments.
    static func upload(_ r: InkRaster) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: r.width, height: r.height, mipmapped: true)
        d.usage = [.shaderRead]
        guard let texture = GPU.shared.device.makeTexture(descriptor: d) else { return nil }
        var w = r.width, h = r.height
        let amount = zip(r.cover, r.halo).map { $0 + $1 }
        var planes = [zip(r.when, amount).map { $0 * $1 }, r.cover, r.halo, zip(r.depth, r.cover).map { $0 * $1 }]
        for level in 0..<texture.mipmapLevelCount {
            var texels = [UInt16](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                for c in 0..<4 { texels[4 * i + c] = UInt16((min(max(planes[c][i], 0), 1) * 65535).rounded()) }
            }
            texels.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level, withBytes: bytes.baseAddress!, bytesPerRow: w * 8)
            }
            guard level + 1 < texture.mipmapLevelCount else { break }
            let nw = max(w / 2, 1), nh = max(h / 2, 1)
            var next = [[Float]](repeating: [Float](repeating: 0, count: nw * nh), count: 4)
            for y in 0..<nh {
                for x in 0..<nw {
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let i = min(2 * y + dy, h - 1) * w + min(2 * x + dx, w - 1)
                        for c in 0..<4 { next[c][y * nw + x] += planes[c][i] / 4 }
                    }
                }
            }
            planes = next
            w = nw
            h = nh
        }
        return texture
    }
}
