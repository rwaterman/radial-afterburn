import Metal
import MetalKit
import simd

struct LineVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

struct TexVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
}

struct FrameUniforms {
    var viewProjection: matrix_float4x4
    var time: Float
    var fogStart: Float
    var fogEnd: Float
    var pad: Float
}

@MainActor
final class Renderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let colorPixelFormat: MTLPixelFormat
    private let linePipeline: MTLRenderPipelineState
    private let texturedPipeline: MTLRenderPipelineState
    private let panelTexture: MTLTexture
    private let library: MTLLibrary
    private var lastFrameTime = CACurrentMediaTime()
    private var startTime = CACurrentMediaTime()

    var game = GameState()
    var onHUDUpdate: ((GameState) -> Void)?

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        guard let queue = device.makeCommandQueue() else { throw RendererError.metalUnavailable }
        self.device = device
        self.commandQueue = queue
        self.colorPixelFormat = colorPixelFormat
        self.library = try device.makeLibrary(source: metalShaderSource, options: nil)
        self.linePipeline = try Renderer.makeLinePipeline(device: device, library: library, format: colorPixelFormat)
        self.texturedPipeline = try Renderer.makeTexturedPipeline(device: device, library: library, format: colorPixelFormat, additive: false)
        self.panelTexture = TextureFactory.neonPanel(device: device)
    }

    private static func makeLinePipeline(device: MTLDevice, library: MTLLibrary, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "neonLineVertex")
        d.fragmentFunction = library.makeFunction(name: "neonLineFragment")
        d.colorAttachments[0].pixelFormat = format
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .one
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: d)
    }

    private static func makeTexturedPipeline(device: MTLDevice, library: MTLLibrary, format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "texturedVertex")
        d.fragmentFunction = library.makeFunction(name: "texturedFragment")
        d.colorAttachments[0].pixelFormat = format
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: d)
    }

    private func uniforms(size: SIMD2<Float>, time: Float) -> FrameUniforms {
        let aspect = size.x / max(size.y, 1)
        let proj = perspectiveMatrix(fovyRadians: 55 * .pi / 180, aspect: aspect, near: 0.5, far: 60)
        let view = lookAtMatrix(eye: SIMD3(0, 0, 0), center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        return FrameUniforms(
            viewProjection: proj * view,
            time: time,
            fogStart: 6,
            fogEnd: 16,
            pad: 0
        )
    }

    // MARK: - Live path (advances simulation by real dt)

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastFrameTime)
        lastFrameTime = now
        game.update(deltaTime: dt)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let size = optionalSize(view.drawableSize) else { return }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor()

        if let cb = encode(pass: pass, size: size, time: Float(now - startTime)) {
            cb.present(drawable)
            cb.commit()
        }
        onHUDUpdate?(game)
    }

    // MARK: - Snapshot path (renders current state, no dt advance)

    func renderSnapshot(width: Int, height: Int) -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { return [] }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor()

        let cb = encode(pass: pass, size: SIMD2(Float(width), Float(height)), time: Float(CACurrentMediaTime() - startTime))
        cb?.commit()
        cb?.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    // MARK: - Shared encode

    private func encode(pass: MTLRenderPassDescriptor, size: SIMD2<Float>, time: Float) -> MTLCommandBuffer? {
        guard let cb = commandQueue.makeCommandBuffer(),
              let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encodeScene(encoder: encoder, size: size, time: time)
        encoder.endEncoding()
        return cb
    }

    /// Scene contents. Extended by Tasks 5-9.
    func encodeScene(encoder: MTLRenderCommandEncoder, size: SIMD2<Float>, time: Float) {
        var u = uniforms(size: size, time: time)
        let panels = TunnelMesh.wallPanels(rings: 24, time: time, kick: game.tunnelKick, wave: game.wave)
        if let buf = device.makeBuffer(bytes: panels, length: MemoryLayout<TexVertex>.stride * panels.count) {
            encoder.setRenderPipelineState(texturedPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentTexture(panelTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: panels.count)
        }
    }

    private func clearColor() -> MTLClearColor {
        MTLClearColor(red: Double(game.flash) * 0.055, green: Double(game.flash) * 0.018,
                      blue: 0.01 + Double(game.flash) * 0.08, alpha: 1)
    }

    private func optionalSize(_ s: CGSize) -> SIMD2<Float>? {
        guard s.width > 0, s.height > 0 else { return nil }
        return SIMD2(Float(s.width), Float(s.height))
    }
}

enum RendererError: Error {
    case metalUnavailable
}
