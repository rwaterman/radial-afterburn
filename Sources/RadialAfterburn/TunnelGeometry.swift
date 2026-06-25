import simd

/// Pure model of the tube in world space. No Metal, no Foundation — unit-tested headless.
/// A ring of `laneCount` vertices at constant world `radius`, extruded along -Z from the
/// near rim (`depth 0`, z = nearZ) to the far vanishing point (`depth 1`, z = farZ).
/// Perspective foreshortening — not a per-depth radius shrink — makes far rings small.
enum TunnelGeometry {
    static let laneCount: Int = 16
    static let nearZ: Float = -1.6
    static let farZ: Float = -16
    static let radius: Float = 0.95

    static func depthZ(_ depth: Float) -> Float {
        nearZ + (farZ - nearZ) * depth
    }

    static func angle(lane: Int) -> Float {
        Float(lane) / Float(laneCount) * .pi * 2 - .pi / 2
    }

    /// World-space point for a lane/depth, optionally perturbed by the time warp + per-wave drift.
    static func worldPoint(lane: Int, depth: Float, time: Float = 0, wave: Int = 0, kick: Float = 0) -> SIMD3<Float> {
        let a = angle(lane: lane)
        let nearField = 1 - depth
        let warp = sin(time * 7.5 + depth * 18 + Float(lane) * 0.7) * (0.05 * kick * nearField)
        let r = radius + warp
        let drift = SIMD2<Float>(sin(Float(wave) * 0.31) * 0.05, cos(Float(wave) * 0.23) * 0.04) * depth
        return SIMD3<Float>(cos(a) * r + drift.x, sin(a) * r + drift.y, depthZ(depth))
    }
}
