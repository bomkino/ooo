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

    public init(project: OOOProject, base: MTLTexture, details: DetailCache?, choreography: Choreography? = nil) {
        self.project = project
        self.base = base
        self.details = details
        self.choreography = choreography ?? project.choreography()
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
        let overview = CameraPose(shot: project.overview, slideAspect: project.slideAspect, canvasAspect: canvasAspect)
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

    /// The background's answer to the camera: a distant plane, it shifts a
    /// little as the camera turns and pans and comes a touch closer as it goes in.
    public func backdropUV(at t: Double, canvasAspect C: Float) -> SIMD4<Float> {
        let cam = choreography.pose(at: t)
        let fovV = radians(cam.fov)
        let fovH = 2 * atanf(tanf(fovV / 2) * C)
        let overview = CameraPose(shot: project.overview, slideAspect: project.slideAspect, canvasAspect: C)
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

        let atRest = sp == .rest
        var cards: [CardPose] = []
        var lifted: CardPose?

        if atRest, let emphasis = choreography.emphasis(at: t) {
            let amount = emphasis.amount
            let shot = choreography.beats[emphasis.beat].shot
            let r = Self.padded(shot.frame.bounds, by: 0.04)
            switch shot.emphasis {
            case .spotlight:
                slide.spot = r
                slide.spotDim = 0.62 * amount
                slide.spotFeather = 0.035
            case .lift:
                slide.spot = r
                slide.spotDim = 0.22 * amount
                slide.spotFeather = 0.05
                lifted = Self.cutOut(r, slideAspect: A, amount: amount, patch: patch, light: light)
            case .none:
                break
            }
        }
        cards.append(slide)

        if atRest, let patch {
            let r = patch.region
            var detail = slide
            detail.media = 1
            detail.occurrence = 1
            detail.crop = r
            detail.window = r
            detail.size = SIMD2(A * (r.z - r.x), r.w - r.y)
            detail.position = SIMD3(((r.x + r.z) / 2 - 0.5) * A, 0.5 - (r.y + r.w) / 2, 0)
            detail.edgeScale = 0
            detail.shadow = 0
            detail.layer = 1
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
    static func cutOut(_ r: SIMD4<Float>, slideAspect A: Float, amount: Float, patch: DetailCache.Patch?, light: Float) -> CardPose {
        let ru = max(r.z - r.x, 1e-4), rv = max(r.w - r.y, 1e-4)
        let lift = amount * (0.012 + 0.16 * rv)
        let grow = 1 + 0.018 * amount
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
        c.corner = 0.06
        c.edgeScale = 0.5
        c.shadow = amount
        c.shadowGround = 0
        c.layer = 2
        c.opacity = smoothstep(amount / 0.25)
        c.color = SIMD4(light, light, light, 1)
        return c
    }
}

/// Renders OOO frames for the live stage and for export.
public final class SlideStage: @unchecked Sendable {
    public let renderer: StageRenderer

    public init(renderer: StageRenderer? = nil) throws {
        self.renderer = try renderer ?? StageRenderer()
    }

    /// Encodes the frame at `t` into `output`. With `waitForDetail`, close-ups
    /// are drawn at full sharpness before the frame (export); otherwise the
    /// best detail at hand is used and a sharper one is drawn in the background.
    public func encode(_ cb: MTLCommandBuffer, scene: SlideScene, at t: Double, output: MTLTexture, samples: Int,
                       frameIndex: UInt32, waitForDetail: Bool, backdropScale: Float = 1, transparent: Bool = false) throws {
        let C = Float(output.width) / Float(max(output.height, 1))
        let A = scene.project.slideAspect
        var patch: DetailCache.Patch?
        if let details = scene.details, scene.slidePose(at: t, canvasAspect: C) == .rest {
            let fp = scene.choreography.pose(at: t).footprint(slideAspect: A, canvasAspect: C, canvasHeight: output.height)
            patch = details.patch(for: fp, wait: waitForDetail)
        }
        var textures: [MTLTexture] = [scene.base]
        if let patch { textures.append(patch.texture) }

        let look = scene.look(at: t, canvasAspect: C)
        let fps = max(scene.project.fps, 1)
        let shutter = Double(look.shutter) / Double(fps)
        var backdrop = scene.project.backdrop
        backdrop.brightness *= scene.presence(at: t)
        var request = StageRenderer.Request(
            width: output.width, height: output.height, backdrop: backdrop, backdropPhase: t / 12, look: look,
            samples: look.shutter > 0.01 ? max(samples, 1) : 1, frameIndex: frameIndex, keepAlpha: transparent,
            drawBackdrop: !transparent)
        request.backdropScale = backdropScale
        request.backdropUV = scene.backdropUV(at: t, canvasAspect: C)
        // Motion blur never reaches across a cut: each sample stays on its side.
        let cut = scene.choreography.cut(between: t - shutter / 2, and: t + shutter / 2)
        let width = output.width
        try renderer.encode(cb, output: output, request: request, textures: textures) { offset in
            var ts = t + Double(offset) * shutter
            if let c = cut { ts = t < c ? min(ts, c - 1e-4) : max(ts, c) }
            return scene.stageFrame(at: ts, canvasAspect: C, outputWidth: width, patch: patch)
        }
    }

    /// One frame as a picture.
    public func still(_ scene: SlideScene, at t: Double, width: Int, height: Int, samples: Int = 8) throws -> CGImage {
        let gpu = GPU.shared
        let out = gpu.makeTexture(width: width, height: height, format: .bgra8Unorm, usage: [.renderTarget, .shaderRead])
        guard let cb = gpu.queue.makeCommandBuffer() else { throw RenderError.io("GPU unavailable.") }
        try encode(cb, scene: scene, at: t, output: out, samples: samples, frameIndex: UInt32(max(0, t * Double(scene.project.fps))),
                   waitForDetail: true)
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
