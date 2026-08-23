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

    // Deterministic scripted scene tuned to showcase content: hold fire for most of
    // the run so enemies advance to visible mid-tunnel depths instead of being
    // cleared at the far end while still buried in fog, then fire a short burst
    // right before the snapshot so shots are in flight and an explosion may land.
    // The player sweeps across lanes so effects land at varied positions.
    renderer.game.start()
    let dt: Float = 1.0 / 60
    let total = max(frames, 1)
    let firingStart = max(0, total - 48)
    for i in 0..<total {
        if i >= firingStart, i % 12 == 0 { renderer.game.fire() }
        if i % 11 == 0 { renderer.game.move(i % 22 == 0 ? 1 : -1) }
        renderer.game.update(deltaTime: dt)
    }

    let bgra = renderer.renderSnapshot(width: width, height: height, time: Float(total) * dt)
    guard bgra.count == width * height * 4 else { return false }
    return writePNG(bgra: bgra, width: width, height: height, path: path)
}

/// Wrap a BGRA readback as a CGImage without reordering bytes.
func makeCGImage(bgra: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

private func writePNG(bgra: [UInt8], width: Int, height: Int, path: String) -> Bool {
    guard let image = makeCGImage(bgra: bgra, width: width, height: height) else { return false }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}
