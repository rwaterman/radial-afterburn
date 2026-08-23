import Testing
import simd
@testable import RadialAfterburn

@Suite("Matrix")
struct MatrixTests {
    private func approx(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool { abs(a - b) <= tol }

    @Test("Perspective foreshortens: same world X projects smaller when farther")
    func perspectiveForeshortens() {
        let p = perspectiveMatrix(fovyRadians: .pi / 3, aspect: 1, near: 0.1, far: 100)
        let near = p * SIMD4<Float>(1, 0, -2, 1)
        let far = p * SIMD4<Float>(1, 0, -10, 1)
        let nearX = near.x / near.w
        let farX = far.x / far.w
        #expect(abs(farX) < abs(nearX))
    }

    @Test("Perspective keeps the axis point centered")
    func perspectiveCentered() {
        let p = perspectiveMatrix(fovyRadians: .pi / 3, aspect: 1.6, near: 0.1, far: 100)
        let c = p * SIMD4<Float>(0, 0, -5, 1)
        #expect(approx(c.x / c.w, 0))
        #expect(approx(c.y / c.w, 0))
    }

    @Test("Perspective clips z to [0,1] — Metal convention")
    func perspectiveZConvention() {
        let p = perspectiveMatrix(fovyRadians: .pi / 3, aspect: 1, near: 0.1, far: 100)
        let nearClip = p * SIMD4<Float>(0, 0, -0.1, 1)
        let farClip  = p * SIMD4<Float>(0, 0, -100, 1)
        #expect(approx(nearClip.z / nearClip.w, 0))
        #expect(approx(farClip.z / farClip.w, 1))
    }

    @Test("lookAt produces an orthonormal basis")
    func lookAtOrthonormal() {
        let v = lookAtMatrix(eye: SIMD3(0, 0, 0), center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        let right = SIMD3(v.columns.0.x, v.columns.1.x, v.columns.2.x)
        let upv = SIMD3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
        let fwd = SIMD3(v.columns.0.z, v.columns.1.z, v.columns.2.z)
        #expect(approx(length(right), 1))
        #expect(approx(length(upv), 1))
        #expect(approx(length(fwd), 1))
        #expect(approx(dot(right, upv), 0))
        #expect(approx(dot(right, fwd), 0))
        #expect(approx(dot(upv, fwd), 0))
    }

    @Test("lookAt at origin looking -Z is identity-like for forward points")
    func lookAtForward() {
        let v = lookAtMatrix(eye: SIMD3(0, 0, 0), center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        let p = v * SIMD4<Float>(0, 0, -5, 1)
        #expect(approx(p.z, -5))
    }
}
