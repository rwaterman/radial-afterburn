import simd

enum TunnelMesh {
    /// Textured wall panels: for each lane segment and depth band, two triangles.
    /// UV.x spans lane fraction, UV.y spans depth (scrolled by the shader-independent caller via time).
    static func wallPanels(rings: Int, time: Float, kick: Float, wave: Int) -> [TexVertex] {
        var out: [TexVertex] = []
        out.reserveCapacity(rings * TunnelGeometry.laneCount * 6)
        let scroll = time * 0.15
        for ring in 0..<rings {
            let d0 = Float(ring) / Float(rings)
            let d1 = Float(ring + 1) / Float(rings)
            let v0 = d0 * 4 + scroll
            let v1 = d1 * 4 + scroll
            // brightness fades with depth; tinted cyan/violet
            let c0 = panelColor(depth: d0)
            let c1 = panelColor(depth: d1)
            for lane in 0..<TunnelGeometry.laneCount {
                let next = (lane + 1) % TunnelGeometry.laneCount
                let uL = Float(lane) / Float(TunnelGeometry.laneCount) * Float(TunnelGeometry.laneCount)
                let uR = uL + 1
                let p00 = TunnelGeometry.worldPoint(lane: lane, depth: d0, time: time, wave: wave, kick: kick)
                let p10 = TunnelGeometry.worldPoint(lane: next, depth: d0, time: time, wave: wave, kick: kick)
                let p01 = TunnelGeometry.worldPoint(lane: lane, depth: d1, time: time, wave: wave, kick: kick)
                let p11 = TunnelGeometry.worldPoint(lane: next, depth: d1, time: time, wave: wave, kick: kick)
                let a = TexVertex(position: p00, uv: SIMD2(uL, v0), color: c0)
                let b = TexVertex(position: p10, uv: SIMD2(uR, v0), color: c0)
                let c = TexVertex(position: p01, uv: SIMD2(uL, v1), color: c1)
                let dd = TexVertex(position: p11, uv: SIMD2(uR, v1), color: c1)
                out += [a, b, c, b, dd, c]
            }
        }
        return out
    }

    static func panelColor(depth: Float) -> SIMD4<Float> {
        let near = SIMD4<Float>(0.5, 0.95, 1.0, 1.0)
        let far = SIMD4<Float>(0.4, 0.2, 0.7, 1.0)
        return near * (1 - depth) + far * depth
    }
}
