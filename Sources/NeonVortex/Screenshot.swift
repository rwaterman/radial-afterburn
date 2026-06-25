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

    // Deterministic scripted scene: start, then advance with periodic fire + drift.
    renderer.game.start()
    let dt: Float = 1.0 / 60
    for i in 0..<max(frames, 1) {
        if i % 9 == 0 { renderer.game.fire() }
        if i % 24 == 12 { renderer.game.move(1) }
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
