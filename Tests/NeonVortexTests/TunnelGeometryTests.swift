import Testing
import simd
@testable import NeonVortex

@Suite("Tunnel geometry")
struct TunnelGeometryTests {
    @Test("Greater depth maps farther into the screen (more negative Z)")
    func depthGoesIntoScreen() {
        #expect(TunnelGeometry.worldPoint(lane: 0, depth: 1).z < TunnelGeometry.worldPoint(lane: 0, depth: 0).z)
        #expect(TunnelGeometry.depthZ(0) == TunnelGeometry.nearZ)
        #expect(TunnelGeometry.depthZ(1) == TunnelGeometry.farZ)
    }

    @Test("World ring radius is constant across depth (perspective does the shrinking)")
    func radiusConstant() {
        let near = TunnelGeometry.worldPoint(lane: 3, depth: 0)
        let far = TunnelGeometry.worldPoint(lane: 3, depth: 1)
        let rNear = length(SIMD2(near.x, near.y))
        let rFar = length(SIMD2(far.x, far.y))
        #expect(abs(rNear - rFar) < 0.02)
        #expect(abs(rNear - TunnelGeometry.radius) < 0.02)
    }

    @Test("Lane index wraps: laneCount == lane 0")
    func laneWraps() {
        let a = TunnelGeometry.worldPoint(lane: 0, depth: 0)
        let b = TunnelGeometry.worldPoint(lane: TunnelGeometry.laneCount, depth: 0)
        #expect(abs(a.x - b.x) < 1e-4)
        #expect(abs(a.y - b.y) < 1e-4)
    }

    @Test("GameState reuses the same lane count")
    func laneCountShared() {
        #expect(GameState.laneCount == TunnelGeometry.laneCount)
    }
}
