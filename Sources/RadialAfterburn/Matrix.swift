import simd

/// Right-handed perspective projection, camera looking down -Z, clip-space z in [0, 1] (Metal).
func perspectiveMatrix(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
    let y = 1 / tan(fovyRadians * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return matrix_float4x4(columns: (
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * near, 0)
    ))
}

/// Right-handed view matrix.
func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return matrix_float4x4(columns: (
        SIMD4<Float>(s.x, u.x, -f.x, 0),
        SIMD4<Float>(s.y, u.y, -f.y, 0),
        SIMD4<Float>(s.z, u.z, -f.z, 0),
        // -f is the view-space Z basis, so translation z = dot(-f, -eye) = dot(f, eye)
        SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
    ))
}
