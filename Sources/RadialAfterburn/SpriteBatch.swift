import simd

enum SpriteBatch {
    /// A camera-facing quad (two triangles) at `center`, half-extent `size` in world units,
    /// in the world XY plane (camera looks down -Z, so screen-aligned).
    static func billboard(center: SIMD3<Float>, size: Float, color: SIMD4<Float>) -> [TexVertex] {
        let r = SIMD3<Float>(size, 0, 0)
        let up = SIMD3<Float>(0, size, 0)
        let a = TexVertex(position: center - r - up, uv: SIMD2(0, 1), color: color)
        let b = TexVertex(position: center + r - up, uv: SIMD2(1, 1), color: color)
        let c = TexVertex(position: center - r + up, uv: SIMD2(0, 0), color: color)
        let d = TexVertex(position: center + r + up, uv: SIMD2(1, 0), color: color)
        return [a, b, c, b, d, c]
    }
}
