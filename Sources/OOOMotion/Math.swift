import Foundation

// OOOMotion is plain Swift (no Apple frameworks), so its maths can be
// tested anywhere. Vectors are the standard library's SIMD types.

public typealias Vec2 = SIMD2<Float>
public typealias Vec3 = SIMD3<Float>

extension SIMD2 where Scalar == Float {
    @inlinable public var length: Float { (x * x + y * y).squareRoot() }
}

extension SIMD3 where Scalar == Float {
    @inlinable public var length: Float { (x * x + y * y + z * z).squareRoot() }
}

@inlinable public func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inlinable public func lerp(_ a: Vec2, _ b: Vec2, _ t: Float) -> Vec2 { a + (b - a) * t }
@inlinable public func lerp(_ a: Vec3, _ b: Vec3, _ t: Float) -> Vec3 { a + (b - a) * t }
@inlinable public func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
@inlinable public func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }
@inlinable public func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
@inlinable public func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }
@inlinable public func degrees(_ radians: Float) -> Float { radians * 180 / .pi }

/// Hermite smoothstep, 0…1.
@inlinable public func smoothstep(_ x: Float) -> Float { let t = clamp01(x); return t * t * (3 - 2 * t) }
/// Quintic smootherstep: zero velocity and acceleration at both ends.
@inlinable public func smootherstep(_ x: Float) -> Float { let t = clamp01(x); return t * t * t * (t * (t * 6 - 15) + 10) }
@inlinable public func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float { smoothstep((x - a) / (b - a)) }

/// Deterministic per-index randomness, −1…1.
@inlinable public func hashSigned(_ i: Int, _ salt: UInt32 = 0) -> Float {
    var x = UInt32(truncatingIfNeeded: i) &* 747796405 &+ 2891336453 &+ salt &* 2654435761
    x = ((x >> ((x >> 28) &+ 4)) ^ x) &* 277803737
    x = (x >> 22) ^ x
    return Float(x) / Float(UInt32.max) * 2 - 1
}
