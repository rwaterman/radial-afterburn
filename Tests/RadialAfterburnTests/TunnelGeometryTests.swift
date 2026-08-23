import Testing
import simd
@testable import RadialAfterburn

@Suite("Tunnel geometry")
struct TunnelGeometryTests {
    @Test("Greater depth maps farther into the screen (more negative Z)")
    func depthGoesIntoScreen() {
        #expect(TunnelGeometry.worldPoint(lane: 0, depth: 1).z < TunnelGeometry.worldPoint(lane: 0, depth: 0).z)
        #expect(TunnelGeometry.depthZ(0) == TunnelGeometry.nearZ)
        #expect(TunnelGeometry.depthZ(1) == TunnelGeometry.farZ)
    }

    @Test("World ring radius is constant from the ring center (perspective does the shrinking)")
    func radiusConstant() {
        for wave in [0, 1, 5] {
            for depth in [Float(0), 0.5, 1] {
                let center = SIMD2<Float>(sin(Float(wave) * 0.31) * 0.05, cos(Float(wave) * 0.23) * 0.04) * depth
                for lane in 0..<TunnelGeometry.laneCount {
                    let p = TunnelGeometry.worldPoint(lane: lane, depth: depth, wave: wave)
                    let r = length(SIMD2(p.x, p.y) - center)
                    #expect(abs(r - TunnelGeometry.radius) < 1e-4)
                }
            }
        }
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
