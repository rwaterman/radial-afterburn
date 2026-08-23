import simd

/// Neon colors for the tunnel and effects. The base hue rotates per wave so each
/// wave reads as a distinct world; wave 1 is anchored to the original cyan/violet.
struct WavePalette {
    var near: SIMD4<Float>
    var far: SIMD4<Float>
    var rim: SIMD4<Float>
    var accent: SIMD4<Float>
}

enum Palette {
    static func forWave(_ wave: Int) -> WavePalette {
        let base = wrap01(0.5 + Float(wave - 1) * 0.12)
        return WavePalette(
            near: rgba(hsv(base, 0.50, 1.00), 1),
            far: rgba(hsv(wrap01(base + 0.22), 0.72, 0.60), 1),
            rim: rgba(hsv(base, 0.82, 1.00), 0.95),
            accent: rgba(hsv(wrap01(base + 0.50), 0.90, 1.00), 1)
        )
    }

    private static func wrap01(_ x: Float) -> Float { x - floor(x) }
    private static func rgba(_ c: SIMD3<Float>, _ a: Float) -> SIMD4<Float> { SIMD4(c.x, c.y, c.z, a) }

    static func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch (Int(i) % 6 + 6) % 6 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}
