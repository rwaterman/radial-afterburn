import Metal

enum TextureFactory {
    /// Emissive neon panel: glowing grid seams over subtle value noise. Repeat-tiled.
    static func neonPanel(device: MTLDevice, size: Int = 256) -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let u = Float(x) / Float(size)
                let v = Float(y) / Float(size)
                // grid seams near tile edges and a center cross
                let gx = min(u, 1 - u)
                let gy = min(v, 1 - v)
                let seam = max(smoothLine(gx, 0.04), smoothLine(gy, 0.04))
                let noise = 0.12 * valueNoise(u * 8, v * 8)
                let base: Float = 0.05 + noise
                let glow = seam
                let r = base * 0.1 + glow * 0.15
                let g = base * 0.5 + glow * 0.95
                let b = base * 0.9 + glow * 1.0
                let i = (y * size + x) * 4
                pixels[i] = toByte(b)      // B
                pixels[i + 1] = toByte(g)  // G
                pixels[i + 2] = toByte(r)  // R
                pixels[i + 3] = 255
            }
        }
        return upload(device: device, pixels: pixels, size: size)
    }

    /// Soft radial glow (particles, shots, muzzle).
    static func glowDot(device: MTLDevice, size: Int = 128) -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let c = Float(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Float(x) - c) / c
                let dy = (Float(y) - c) / c
                let d = sqrt(dx * dx + dy * dy)
                let a = max(0, 1 - d)
                let glow = a * a
                let i = (y * size + x) * 4
                pixels[i] = toByte(glow); pixels[i + 1] = toByte(glow); pixels[i + 2] = toByte(glow); pixels[i + 3] = toByte(glow)
            }
        }
        return upload(device: device, pixels: pixels, size: size)
    }

    /// Luminance/shape mask per enemy kind. Color is applied via the vertex color.
    static func sprite(device: MTLDevice, kind: EnemyKind, size: Int = 128) -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let c = Float(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let px = (Float(x) - c) / c
                let py = (Float(y) - c) / c
                let mask: Float
                switch kind {
                case .spike:   mask = shapeDiamond(px, py, sharp: 1.6)
                case .flipper: mask = shapeWings(px, py)
                case .tanker:  mask = shapeHex(px, py)
                }
                let edge = max(0, 1 - sqrt(px * px + py * py))
                let v = max(mask, mask * 0.5 + edge * 0.25)
                let i = (y * size + x) * 4
                pixels[i] = toByte(v); pixels[i + 1] = toByte(v); pixels[i + 2] = toByte(v); pixels[i + 3] = toByte(v)
            }
        }
        return upload(device: device, pixels: pixels, size: size)
    }

    static func playerSprite(device: MTLDevice, size: Int = 128) -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let c = Float(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let px = (Float(x) - c) / c
                let py = (Float(y) - c) / c
                let v = shapeArrow(px, py)
                let i = (y * size + x) * 4
                pixels[i] = toByte(v); pixels[i + 1] = toByte(v); pixels[i + 2] = toByte(v); pixels[i + 3] = toByte(v)
            }
        }
        return upload(device: device, pixels: pixels, size: size)
    }

    private static func shapeDiamond(_ x: Float, _ y: Float, sharp: Float) -> Float { max(0, 1 - (abs(x) + abs(y)) * sharp) }
    private static func shapeHex(_ x: Float, _ y: Float) -> Float {
        let q = max(abs(x) * 0.866 + abs(y) * 0.5, abs(y))
        return q < 0.8 ? 1 : 0
    }
    private static func shapeWings(_ x: Float, _ y: Float) -> Float {
        let body = max(0, 1 - (abs(x) * 0.6 + abs(y) * 1.4))
        let wing = (abs(y) < 0.18 && abs(x) < 0.9) ? 1 : 0
        return max(body, Float(wing))
    }
    private static func shapeArrow(_ x: Float, _ y: Float) -> Float {
        let inside = (y > -0.7 && y < 0.6 && abs(x) < max(0, 0.6 - y * 0.5))
        return inside ? 1 : 0
    }

    private static func smoothLine(_ d: Float, _ width: Float) -> Float {
        max(0, 1 - d / width)
    }

    private static func valueNoise(_ x: Float, _ y: Float) -> Float {
        let n = sin(x * 12.9898 + y * 78.233) * 43758.5453
        return n - floor(n)
    }

    private static func toByte(_ v: Float) -> UInt8 {
        UInt8(max(0, min(1, v)) * 255)
    }

    private static func upload(device: MTLDevice, pixels: [UInt8], size: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: true)
        desc.usage = [.shaderRead]
        let tex = device.makeTexture(descriptor: desc)!
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: size * 4)
        }
        guard let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            fatalError("TextureFactory: failed to create command queue/buffer for mipmap generation")
        }
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return tex
    }
}
