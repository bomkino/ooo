import Foundation

/// Where the camera is and what it sees, in slide terms.
public struct CameraPose: Hashable, Sendable {
    /// The point looked at, on the slide plane (world units, slide centred, y up).
    public var target: Vec2
    /// The height of the view through the target, in world units (the slide is 1 tall).
    public var height: Float
    /// Radians. Yaw swings the camera round the slide's vertical axis (positive
    /// from the right), pitch over its horizontal axis (positive from above).
    public var yaw: Float
    public var pitch: Float
    /// Radians, turning the picture.
    public var roll: Float
    /// Vertical field of view, degrees.
    public var fov: Float
    /// 0…1 depth of field.
    public var aperture: Float

    public init(target: Vec2, height: Float, yaw: Float = 0, pitch: Float = 0, roll: Float = 0, fov: Float = 28, aperture: Float = 0.3) {
        self.target = target
        self.height = height
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.fov = fov
        self.aperture = aperture
    }

    /// Distance from the eye to the target that shows `height` at this field of view.
    public var distance: Float { height / (2 * tanf(radians(fov) / 2)) }

    /// Unit vector from the target towards the eye.
    public var direction: Vec3 {
        Vec3(sinf(yaw) * cosf(pitch), sinf(pitch), cosf(yaw) * cosf(pitch))
    }

    public var target3: Vec3 { Vec3(target.x, target.y, 0) }
    public var eye: Vec3 { target3 + direction * distance }

    /// The pose framing `frame` on a slide of `slideAspect` seen on a canvas of `canvasAspect`.
    public static func framing(_ frame: ShotFrame, slideAspect: Float, canvasAspect: Float) -> (target: Vec2, height: Float) {
        let target = Vec2((frame.center.x - 0.5) * slideAspect, 0.5 - frame.center.y)
        let height = max(frame.size.y, frame.size.x * slideAspect / max(canvasAspect, 0.01))
        return (target, max(height, 0.002))
    }

    /// The camera on a shot: its region fitted into the safe part of the
    /// canvas as seen from the shot's angle (see `Composer`).
    public init(shot: Shot, slideAspect: Float, canvasAspect: Float, safe: SafeArea = .none) {
        let yaw = radians(shot.yaw), pitch = radians(shot.pitch), roll = radians(shot.roll)
        let f = Composer.fit(shot.frame, yaw: yaw, pitch: pitch, roll: roll, fov: shot.lens,
                             slideAspect: slideAspect, canvasAspect: canvasAspect, safe: safe)
        self.init(target: f.target, height: f.height, yaw: yaw, pitch: pitch, roll: roll, fov: shot.lens, aperture: shot.aperture)
    }

    /// The camera where a shot's glide along its line ends.
    public init(sweepEndOf shot: Shot, slideAspect: Float, canvasAspect: Float, safe: SafeArea = .none) {
        var end = shot
        end.frame.center += shot.sweep ?? .zero
        self.init(shot: end, slideAspect: slideAspect, canvasAspect: canvasAspect, safe: safe)
    }

    /// The frame this pose shows square-on (its angles ignored), for capturing
    /// the current view as a shot.
    public func frame(slideAspect: Float, canvasAspect: Float) -> ShotFrame {
        let center = Vec2(target.x / slideAspect + 0.5, 0.5 - target.y)
        return ShotFrame(center: center, size: Vec2(height * canvasAspect / slideAspect, height))
    }
}

/// The optimal path between two views of a plane (van Wijk & Nuij, "Smooth and
/// efficient zooming and panning", 2003), as in d3-interpolate's `interpolateZoom`.
/// Far-apart views are joined by pulling out just enough to see both, gliding,
/// then pushing in; neighbours are joined by a near-straight pan. The path is
/// parameterised by its length, so even progress along it reads as even speed.
public struct ZoomPath: Sendable {
    public let start: Vec2
    public let end: Vec2
    /// View sizes (the geometric mean of width and height, world units).
    public let w0: Double
    public let w1: Double
    public let rho: Double
    /// Path length in the paper's metric (≈ screen-widths travelled).
    public let length: Double
    private let r0: Double
    private let d: Double
    private let zoomOnly: Bool
    private let logRatio: Double

    public init(from start: Vec2, w0: Float, to end: Vec2, w1: Float, rho: Float) {
        self.start = start
        self.end = end
        self.w0 = Double(max(w0, 1e-5))
        self.w1 = Double(max(w1, 1e-5))
        self.rho = Double(rho)
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let d2 = dx * dx + dy * dy
        let rho2 = self.rho * self.rho, rho4 = rho2 * rho2
        logRatio = log(self.w1 / self.w0)
        // Small pans relative to the view behave as pure zooms (numerically safer).
        if d2 < 1e-10 * max(self.w0 * self.w0, 1e-6) {
            zoomOnly = true
            d = sqrt(d2)
            r0 = 0
            length = abs(logRatio) / self.rho
        } else {
            zoomOnly = false
            let d1 = sqrt(d2)
            d = d1
            let b0 = (self.w1 * self.w1 - self.w0 * self.w0 + rho4 * d2) / (2 * self.w0 * rho2 * d1)
            let b1 = (self.w1 * self.w1 - self.w0 * self.w0 - rho4 * d2) / (2 * self.w1 * rho2 * d1)
            let r0 = log(sqrt(b0 * b0 + 1) - b0)
            let r1 = log(sqrt(b1 * b1 + 1) - b1)
            self.r0 = r0
            length = (r1 - r0) / self.rho
        }
    }

    /// The view at fraction `t` (0…1) of the way along.
    public func at(_ t: Float) -> (center: Vec2, w: Float) {
        let tt = Double(t)
        if zoomOnly {
            let w = w0 * exp(logRatio * tt)
            return (lerp(start, end, t), Float(w))
        }
        let s = tt * length
        let coshr0 = cosh(r0)
        let u = w0 / (rho * rho * d) * (coshr0 * tanh(rho * s + r0) - sinh(r0))
        let w = w0 * coshr0 / cosh(rho * s + r0)
        return (start + (end - start) * Float(u), Float(w))
    }
}

/// What part of the slide a camera sees, and how finely.
public struct ViewFootprint: Hashable, Sendable {
    /// The visible part of the slide, (u0, v0, u1, v1) in slide space (v down),
    /// clamped to the slide.
    public var region: SIMD4<Float>
    /// Canvas pixels per world unit (per slide height) at the nearest visible
    /// point: how much detail the frame can show.
    public var pixelsPerUnit: Float
}

extension CameraPose {
    /// Unit vectors of the view: forward, right and up, with roll applied the
    /// way the renderer applies it.
    public var basis: (forward: Vec3, right: Vec3, up: Vec3) {
        let f = -direction
        var up0 = Vec3(sinf(roll), cosf(roll), 0)
        if abs(f.x * up0.x + f.y * up0.y + f.z * up0.z) > 0.98 { up0 = Vec3(0, 0, -1) }
        let s = normalize(cross(f, up0))
        let u = cross(s, f)
        return (f, s, u)
    }

    /// Where the canvas point (x, y) in −1…1 (y up) lands on the slide plane,
    /// in world units, or nil if that ray never reaches it.
    public func hit(_ x: Float, _ y: Float, canvasAspect: Float) -> Vec3? {
        let (f, s, u) = basis
        let k = tanf(radians(fov) / 2)
        let d = f + s * (x * k * canvasAspect) + u * (y * k)
        let e = eye
        guard d.z < -1e-5 else { return nil }
        let t = -e.z / d.z
        return e + d * t
    }

    /// The part of the slide this camera sees and the detail it needs there.
    public func footprint(slideAspect A: Float, canvasAspect C: Float, canvasHeight: Int) -> ViewFootprint {
        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (-1, 1), (1, 1), (0, 0)]
        var lo = Vec2(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var hi = -lo
        var nearest = Float.greatestFiniteMagnitude
        var missed = false
        let e = eye
        for (x, y) in corners {
            guard let p = hit(x, y, canvasAspect: C) else { missed = true; continue }
            let uv = Vec2(p.x / A + 0.5, 0.5 - p.y)
            lo = pointwiseMin(lo, uv)
            hi = pointwiseMax(hi, uv)
            nearest = min(nearest, (p - e).length)
        }
        if missed || nearest == .greatestFiniteMagnitude {
            lo = Vec2(0, 0)
            hi = Vec2(1, 1)
            nearest = min(nearest, distance)
        }
        let region = SIMD4(clamp01(lo.x), clamp01(lo.y), clamp01(hi.x), clamp01(hi.y))
        let ppu = Float(canvasHeight) / (2 * tanf(radians(fov) / 2) * max(nearest, 1e-4))
        return ViewFootprint(region: region, pixelsPerUnit: ppu)
    }
}

func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

func normalize(_ v: Vec3) -> Vec3 { v / max(v.length, 1e-12) }
