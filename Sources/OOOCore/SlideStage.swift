import BackdropKit
import CoreGraphics
import Foundation
import Metal
import OOOMotion
import RenderCore
import StageKit
import simd

/// Everything one frame of an OOO video depends on: the project, the camera's
/// path through it, and the slide on the GPU.
public struct SlideScene: @unchecked Sendable {
    public let project: OOOProject
    public let choreography: Choreography
    /// The whole slide.
    public let base: MTLTexture
    /// Sharper copies of the parts the camera goes close to.
    public let details: DetailCache?

    /// The words over the opening, when there are some.
    public private(set) var title: TitleOverlay?

    public init(project: OOOProject, base: MTLTexture, details: DetailCache?, choreography: Choreography? = nil) {
        self.project = project
        self.base = base
        self.details = details
        let c = choreography ?? project.choreography()
        self.choreography = c
        title = nil
        if let words = project.title, !words.isEmpty, let first = c.beats.first {
            let opening = first.pose
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
            title = TitleOverlay(key: h.finalize(), timing: .opening, scrim: 0) { w, hgt in
                let C = Float(w) / Float(max(hgt, 1))
                let band = OpeningTitleArt.band(opening: opening, slideAspect: A, canvasAspect: C, safe: safe)
                return OpeningTitleArt.draw(words, width: w, height: hgt, band: band, lightInk: light)
            }
        }
    }

    public var duration: Double { choreography.duration }

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
        if sp == .rest { return 1 }
        guard project.ending == .leave else { return 0 }
        let p = choreography.endingProgress(at: t)
        return p > 0 ? 1 - smootherstep(p / 0.2) : 0
    }

    /// How much of the surface's light shows at `t`: all of it while the slide
    /// arrives and the camera travels, a trace while the camera holds and the
    /// slide is read, so black type stays black.
    public func surfaceAmount(at t: Double) -> Float {
        let reading = choreography.settled(at: t) * (1 - choreography.endingProgress(at: t))
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
    /// detail laid over the slide.
    public func stageFrame(at t: Double, canvasAspect C: Float, outputWidth: Int, patch: DetailCache.Patch?) -> StageFrame {
        let A = project.slideAspect
        let cam = choreography.pose(at: t)
        var frame = StageFrame()
        frame.camera = Self.stageCamera(cam)
        frame.shadowsOnCards = true
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
        var slide = CardPose(media: 0, occurrence: 0, position: sp.offset, rotation: sp.rotation, size: SIMD2(A, 1))
        slide.curl = sp.curl
        slide.fold = sp.fold
        slide.foldPhase = sp.foldPhase
        slide.opacity = sp.opacity
        slide.blur = sp.blur * Float(outputWidth) / 1080
        slide.glow = sp.glow
        let light = sp.exposure * shown
        slide.color = SIMD4(light, light, light, 1)
        slide.corner = 0.028
        slide.fit = .fill
        slide.mediaAspect = A
        slide.shadow = shown
        slide.surfaceAmount = surfaceAmount(at: t)

        let atRest = sp == .rest
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
                let r = Self.padded(focus.bounds, by: 0.5)
                slide.spot = Self.padded(focus.bounds, by: 1.15)
                slide.spotDim = 0.2 * amount
                slide.spotFeather = max(0.9 * m, 0.02) / unit
                lifted = Self.cutOut(r, slideAspect: A, amount: amount, patch: patch, light: light, fade: 0.45 * m,
                                     surface: slide.surfaceAmount)
            case .none:
                break
            }
        }
        cards.append(slide)

        let hold = restHold(at: t, pose: sp)
        if hold > 0.001, let patch {
            let r = patch.region
            var detail = slide
            detail.media = 1
            detail.occurrence = 1
            detail.crop = r
            detail.window = r
            detail.size = SIMD2(A * (r.z - r.x), r.w - r.y)
            // Laid over its part of the slide wherever the slide is, so it sets
            // off with a Leave while it fades.
            let local = SIMD3<Float>(((r.x + r.z) / 2 - 0.5) * A, 0.5 - (r.y + r.w) / 2, 0)
            let turned = Matrix.rotationEuler(slide.rotation) * SIMD4(local, 0)
            detail.position = slide.position + SIMD3(turned.x, turned.y, turned.z)
            detail.curl = 0
            detail.fold = 0
            detail.opacity = slide.opacity * hold
            detail.edgeScale = 0
            detail.shadow = 0
            detail.layer = 1
            detail.reflects = false
            cards.append(detail)
        }
        if let lifted { cards.append(lifted) }
        frame.cards = cards
        return frame
    }

    static func padded(_ r: SIMD4<Float>, by k: Float) -> SIMD4<Float> {
        let w = r.z - r.x, h = r.w - r.y
        let p = k * max(min(w, h), 0.02)
        return SIMD4(max(r.x - p, 0), max(r.y - p, 0), min(r.z + p, 1), min(r.w + p, 1))
    }

    /// A detail lifted off the slide as a die-cut piece, its shadow falling on
    /// the slide below. It shows its region of whichever texture holds it best.
    static func cutOut(_ r: SIMD4<Float>, slideAspect A: Float, amount: Float, patch: DetailCache.Patch?, light: Float,
                       fade: Float, surface: Float = 1) -> CardPose {
        let ru = max(r.z - r.x, 1e-4), rv = max(r.w - r.y, 1e-4)
        // Low and barely larger: what shows through its fading margin then
        // lines up with the slide beneath, rather than doubling the lines
        // that cross it.
        let lift = amount * (0.006 + 0.08 * rv)
        let grow = 1 + 0.01 * amount
        let center = SIMD3(((r.x + r.z) / 2 - 0.5) * A, 0.5 - (r.y + r.w) / 2, lift)
        var c = CardPose(media: 0, occurrence: 2, position: center, rotation: .zero, size: SIMD2(A * ru, rv) * grow)
        // The texture holding region P shows region r when its window is the
        // inverse map: (P − r.xy) / r.size.
        var holder = SIMD4<Float>(0, 0, 1, 1)
        if let patch, patch.region.x <= r.x, patch.region.y <= r.y, patch.region.z >= r.z, patch.region.w >= r.w {
            holder = patch.region
            c.media = 1
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

    public init(renderer: StageRenderer? = nil) throws {
        self.renderer = try renderer ?? StageRenderer()
        titles = try TitleCompositor()
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
        var patch: DetailCache.Patch?
        if let details = scene.details, let fp = footprint(scene, at: t, width: output.width, height: output.height) {
            patch = details.patch(for: fp, wait: waitForDetail)
        }
        var textures: [MTLTexture] = [scene.base]
        if let patch { textures.append(patch.texture) }

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
            return scene.stageFrame(at: ts, canvasAspect: C, outputWidth: width, patch: patch)
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
            try titles.encode(cb, title, alpha: p.alpha * scene.presence(at: t), drop: p.drop, output: output)
        }
        return request.samples
    }

    /// What the camera sees of the slide at `t`, when the slide is at rest
    /// (only then does a close-up lie exactly over it).
    func footprint(_ scene: SlideScene, at t: Double, width: Int, height: Int) -> ViewFootprint? {
        let C = Float(width) / Float(max(height, 1))
        guard scene.restHold(at: t, pose: scene.slidePose(at: t, canvasAspect: C)) > 0.001 else { return nil }
        return scene.choreography.pose(at: t).footprint(slideAspect: scene.project.slideAspect, canvasAspect: C, canvasHeight: height)
    }

    /// Starts drawing, in the background, the close-up the frame at `t` will
    /// need, so it is ready when the frame comes.
    public func drawAhead(_ scene: SlideScene, at t: Double, width: Int, height: Int) {
        guard t <= scene.duration, let details = scene.details, let fp = footprint(scene, at: t, width: width, height: height) else { return }
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

/// Loads a project's slide onto the GPU.
public enum SlideLoader {
    public static func scene(for project: OOOProject, media: URL?, choreography: Choreography? = nil) throws -> SlideScene {
        let source = try SlideSource(ref: project.slide, media: media)
        guard let whole = source.renderWhole() else { throw RenderError.io("Could not draw the slide.") }
        let tex = try MediaLoader.texture(from: whole)
        let details = DetailCache(source: source, baseDensity: Float(whole.height))
        return SlideScene(project: project, base: tex.texture, details: details, choreography: choreography)
    }
}
