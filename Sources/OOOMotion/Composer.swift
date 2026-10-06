import Foundation

/// The part of the canvas a framing should sit in: insets from each edge as
/// fractions of the canvas. On a Reel, the profile and header cover the top,
/// and the caption and buttons cover the bottom.
public struct SafeArea: Codable, Hashable, Sendable {
    public var top: Float
    public var bottom: Float
    public var left: Float
    public var right: Float

    public init(top: Float = 0, bottom: Float = 0, left: Float = 0, right: Float = 0) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public static let none = SafeArea()
    /// Instagram Reels, TikTok and Shorts.
    public static let reel = SafeArea(top: 0.10, bottom: 0.20, left: 0.05, right: 0.05)
    /// A 4:5 post in a feed.
    public static let feed = SafeArea(top: 0.04, bottom: 0.06, left: 0.03, right: 0.03)

    /// The clear part of the canvas, in −1…1 canvas coordinates (y up): min x, min y, max x, max y.
    public var rect: SIMD4<Float> {
        SIMD4(-1 + 2 * left, -1 + 2 * bottom, 1 - 2 * right, 1 - 2 * top)
    }

    /// Width and height of the clear part, as fractions of the canvas.
    public var size: Vec2 { Vec2(max(1 - left - right, 0.05), max(1 - top - bottom, 0.05)) }
}

/// Fits a framing to the canvas the way a camera operator would: whatever the
/// angle and lens, the whole region shows, as large as it can, centred in the
/// part of the canvas no app interface covers.
///
/// A region seen at an angle is not the rectangle a flat view assumes: its
/// near side looms and its far side shrinks. So the camera's distance and aim
/// are solved against the region's real outline on the canvas.
public enum Composer {
    /// The aim (on the slide plane) and view height that fit `frame` into the
    /// safe part of the canvas, seen from `yaw`, `pitch` and `roll` (radians)
    /// through a lens of `fov` degrees.
    public static func fit(_ frame: ShotFrame, yaw: Float, pitch: Float, roll: Float, fov: Float,
                           slideAspect A: Float, canvasAspect C: Float, safe: SafeArea = .none) -> (target: Vec2, height: Float) {
        let flat = CameraPose.framing(frame, slideAspect: A, canvasAspect: C)
        let s = safe.size, r = safe.rect
        // A flat view fills the safe part at this height.
        var pose = CameraPose(target: flat.target, height: max(frame.size.y / s.y, frame.size.x * A / (C * s.x), 0.002),
                              yaw: yaw, pitch: pitch, roll: roll, fov: fov)
        let corners = [Vec2(frame.minU, frame.minV), Vec2(frame.maxU, frame.minV),
                       Vec2(frame.minU, frame.maxV), Vec2(frame.maxU, frame.maxV)].map {
            Vec3(($0.x - 0.5) * A, 0.5 - $0.y, 0)
        }
        let centre = Vec2((r.x + r.z) / 2, (r.y + r.w) / 2)
        let room = Vec2(r.z - r.x, r.w - r.y)
        let flatOn = abs(yaw) < 1e-5 && abs(pitch) < 1e-5 && abs(roll) < 1e-5
        for _ in 0..<(flatOn ? 2 : 10) {
            guard let box = pose.bounds(of: corners, canvasAspect: C) else { break }
            // Distance: projected size goes as one over it.
            let k = max((box.z - box.x) / room.x, (box.w - box.y) / room.y)
            pose.height = max(pose.height * k, 0.002)
            // Aim: slide the camera along the plane so the outline's middle
            // lands in the middle of the safe part.
            guard let box2 = pose.bounds(of: corners, canvasAspect: C),
                  let from = pose.hit(centre.x, centre.y, canvasAspect: C),
                  let to = pose.hit((box2.x + box2.z) / 2, (box2.y + box2.w) / 2, canvasAspect: C) else { break }
            pose.target += Vec2(to.x - from.x, to.y - from.y)
        }
        return (pose.target, pose.height)
    }
}

extension CameraPose {
    /// Where a world point lands on the canvas, in −1…1 (y up), or nil if it is behind the camera.
    public func project(_ p: Vec3, canvasAspect C: Float) -> Vec2? {
        let (f, s, u) = basis
        let d = p - eye
        let z = d.x * f.x + d.y * f.y + d.z * f.z
        guard z > 1e-5 else { return nil }
        let k = tanf(radians(fov) / 2)
        let x = (d.x * s.x + d.y * s.y + d.z * s.z) / z / (k * C)
        let y = (d.x * u.x + d.y * u.y + d.z * u.z) / z / k
        return Vec2(x, y)
    }

    /// The canvas box (min x, min y, max x, max y, in −1…1) around some world points.
    public func bounds(of points: [Vec3], canvasAspect C: Float) -> SIMD4<Float>? {
        var lo = Vec2(.greatestFiniteMagnitude, .greatestFiniteMagnitude), hi = -lo
        for p in points {
            guard let q = project(p, canvasAspect: C) else { return nil }
            lo = pointwiseMin(lo, q)
            hi = pointwiseMax(hi, q)
        }
        return SIMD4(lo.x, lo.y, hi.x, hi.y)
    }
}
