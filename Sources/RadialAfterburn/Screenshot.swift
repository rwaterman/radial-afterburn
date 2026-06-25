import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

@MainActor
func runScreenshot(path: String, frames: Int, width: Int, height: Int) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else {
        FileHandle.standardError.write(Data("screenshot: no Metal device\n".utf8))
        return false
    }
    let renderer: Renderer
    do {
        renderer = try Renderer(device: device, colorPixelFormat: .bgra8Unorm)
    } catch {
        FileHandle.standardError.write(Data("screenshot: \(error)\n".utf8))
        return false
    }

    // Deterministic scripted scene tuned to showcase content: fire sparingly so
    // enemies survive and advance to visible mid-tunnel depths (instead of being
    // killed at the far end while still buried in fog), keep a couple of shots in
    // flight, and sweep the player across lanes so explosions land at varied depths.
    renderer.game.start()
    let dt: Float = 1.0 / 60
    let total = max(frames, 1)
    // Hold fire for most of the run so the slow enemies advance to visible
    // mid-tunnel depths instead of being cleared at the far end. Fire only a short
    // burst right before the snapshot so a couple of shots are still in flight (and
    // a fresh explosion may be landing) without emptying the field.
    let firingStart = max(0, total - 48)
    for i in 0..<total {
        if i >= firingStart, i % 12 == 0 { renderer.game.fire() }
        if i % 11 == 0 { renderer.game.move(i % 22 == 0 ? 1 : -1) }
        renderer.game.update(deltaTime: dt)
    }

    let bgra = renderer.renderSnapshot(width: width, height: height)
    guard bgra.count == width * height * 4 else { return false }
    return writePNG(bgra: bgra, width: width, height: height, path: path)
}

private func writePNG(bgra: [UInt8], width: Int, height: Int, path: String) -> Bool {
    // Convert BGRA -> RGBA for CGImage.
    var rgba = [UInt8](repeating: 0, count: bgra.count)
    for p in stride(from: 0, to: bgra.count, by: 4) {
        rgba[p] = bgra[p + 2]; rgba[p + 1] = bgra[p + 1]; rgba[p + 2] = bgra[p]; rgba[p + 3] = bgra[p + 3]
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: cs,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return false }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}
