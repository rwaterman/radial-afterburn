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
    private let additiveTexturedPipeline: MTLRenderPipelineState
    private let panelTexture: MTLTexture
    private let glowTexture: MTLTexture
    private let ringTexture: MTLTexture
    private let playerTexture: MTLTexture
    private var enemyTextures: [EnemyKind: MTLTexture] = [:]
    private let library: MTLLibrary
    private var lastFrameTime = CACurrentMediaTime()
    private var startTime = CACurrentMediaTime()
    private var depthTexture: MTLTexture?
    private let depthWriteState: MTLDepthStencilState
    private let depthTestState: MTLDepthStencilState
    private var sceneHDR: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private let brightPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private static let hdrFormat: MTLPixelFormat = .rgba16Float

    var game = GameState()
    var onHUDUpdate: ((GameState) -> Void)?

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        guard let queue = device.makeCommandQueue() else { throw RendererError.metalUnavailable }
        self.device = device
        self.commandQueue = queue
        self.colorPixelFormat = colorPixelFormat
        self.library = try device.makeLibrary(source: metalShaderSource, options: nil)
        let writeDesc = MTLDepthStencilDescriptor()
        writeDesc.depthCompareFunction = .less
        writeDesc.isDepthWriteEnabled = true
        self.depthWriteState = device.makeDepthStencilState(descriptor: writeDesc)!
        let testDesc = MTLDepthStencilDescriptor()
        testDesc.depthCompareFunction = .lessEqual
        testDesc.isDepthWriteEnabled = false
        self.depthTestState = device.makeDepthStencilState(descriptor: testDesc)!
        self.linePipeline = try Renderer.makeLinePipeline(device: device, library: library, format: Renderer.hdrFormat)
        self.texturedPipeline = try Renderer.makeTexturedPipeline(device: device, library: library, format: Renderer.hdrFormat, additive: false)
        self.additiveTexturedPipeline = try Renderer.makeTexturedPipeline(device: device, library: library, format: Renderer.hdrFormat, additive: true)
        self.brightPipeline = try Renderer.makePostPipeline(device: device, library: library, fragment: "brightPassFragment", format: Renderer.hdrFormat)
        self.blurPipeline = try Renderer.makePostPipeline(device: device, library: library, fragment: "blurFragment", format: Renderer.hdrFormat)
        self.compositePipeline = try Renderer.makePostPipeline(device: device, library: library, fragment: "compositeFragment", format: colorPixelFormat)
        self.panelTexture = TextureFactory.neonPanel(device: device)
        self.glowTexture = TextureFactory.glowDot(device: device)
        self.ringTexture = TextureFactory.ringGlow(device: device)
        self.playerTexture = TextureFactory.playerSprite(device: device)
        self.enemyTextures = [
            .spike: TextureFactory.sprite(device: device, kind: .spike),
            .flipper: TextureFactory.sprite(device: device, kind: .flipper),
            .tanker: TextureFactory.sprite(device: device, kind: .tanker),
        ]
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
        d.depthAttachmentPixelFormat = .depth32Float
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
        d.depthAttachmentPixelFormat = .depth32Float
        return try device.makeRenderPipelineState(descriptor: d)
    }

    private static func makePostPipeline(device: MTLDevice, library: MTLLibrary, fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: d)
    }

    private func uniforms(size: SIMD2<Float>, time: Float) -> FrameUniforms {
        let aspect = size.x / max(size.y, 1)
        let proj = perspectiveMatrix(fovyRadians: 55 * .pi / 180, aspect: aspect, near: 0.5, far: 60)
        // Camera jitter driven by screenShake (hits / breaches / wave clears) — translate
        // eye and target together so the whole view shakes without changing aim.
        let shake = game.screenShake * 0.04
        let jx = (sin(time * 79) + sin(time * 41) * 0.5) * shake
        let jy = (cos(time * 83) + sin(time * 57) * 0.5) * shake
        let view = lookAtMatrix(eye: SIMD3(jx, jy, 0), center: SIMD3(jx, jy, -1), up: SIMD3(0, 1, 0))
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

        guard let drawable = view.currentDrawable, let size = optionalSize(view.drawableSize) else { return }
        if let cb = encodeFrame(finalTarget: drawable.texture, finalLoad: .dontCare, size: size, time: Float(now - startTime)) {
            cb.present(drawable)
            cb.commit()
        }
        onHUDUpdate?(game)
    }

    // MARK: - Snapshot path (renders current state, no dt advance)

    /// `time` drives the cosmetic warp/scroll/flicker; pass a fixed value (e.g. the
    /// scripted scene's elapsed sim time) for a fully reproducible screenshot.
    func renderSnapshot(width: Int, height: Int, time: Float) -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { return [] }

        let cb = encodeFrame(finalTarget: target, finalLoad: .clear, size: SIMD2(Float(width), Float(height)), time: time)
        cb?.commit()
        cb?.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    // MARK: - Shared encode

    private func depthAttachment(width: Int, height: Int) -> MTLTexture {
        if let t = depthTexture, t.width == width, t.height == height { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        let t = device.makeTexture(descriptor: desc)!
        depthTexture = t
        return t
    }

    private func hdrTextures(width: Int, height: Int) -> (scene: MTLTexture, a: MTLTexture, b: MTLTexture) {
        func make(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.hdrFormat, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        if let s = sceneHDR, s.width == width, s.height == height, let a = bloomA, let b = bloomB {
            return (s, a, b)
        }
        let s = make(width, height); let a = make(width / 2, height / 2); let b = make(width / 2, height / 2)
        sceneHDR = s; bloomA = a; bloomB = b
        return (s, a, b)
    }

    @discardableResult
    private func encodeFrame(finalTarget: MTLTexture, finalLoad: MTLLoadAction, size: SIMD2<Float>, time: Float) -> MTLCommandBuffer? {
        let width = Int(size.x), height = Int(size.y)
        let (scene, a, b) = hdrTextures(width: width, height: height)
        guard let cb = commandQueue.makeCommandBuffer() else { return nil }

        // Scene pass -> HDR (with depth)
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = scene
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = clearColor()
        let depth = depthAttachment(width: width, height: height)
        scenePass.depthAttachment.texture = depth
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.clearDepth = 1.0
        scenePass.depthAttachment.storeAction = .dontCare
        if let enc = cb.makeRenderCommandEncoder(descriptor: scenePass) {
            encodeScene(encoder: enc, size: size, time: time)
            enc.endEncoding()
        }

        // Bright pass: scene -> a
        postPass(cb: cb, pipeline: brightPipeline, target: a, source0: scene) { _ in }
        // Blur horizontal a -> b, vertical b -> a
        postPass(cb: cb, pipeline: blurPipeline, target: b, source0: a) { enc in
            var dir = SIMD2<Float>(1, 0); enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        postPass(cb: cb, pipeline: blurPipeline, target: a, source0: b) { enc in
            var dir = SIMD2<Float>(0, 1); enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        // Composite scene + bloom(a) -> final
        let comp = MTLRenderPassDescriptor()
        comp.colorAttachments[0].texture = finalTarget
        comp.colorAttachments[0].loadAction = finalLoad
        comp.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: comp) {
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentTexture(scene, index: 0)
            enc.setFragmentTexture(a, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        return cb
    }

    private func postPass(cb: MTLCommandBuffer, pipeline: MTLRenderPipelineState, target: MTLTexture, source0: MTLTexture, configure: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source0, index: 0)
        configure(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Scene contents. Extended by Tasks 5-9.
    func encodeScene(encoder: MTLRenderCommandEncoder, size: SIMD2<Float>, time: Float) {
        var u = uniforms(size: size, time: time)

        // Pass A: textured wall panels (write depth)
        let panels = TunnelMesh.wallPanels(rings: 24, time: time, kick: game.tunnelKick, wave: game.wave)
        if let buf = device.makeBuffer(bytes: panels, length: MemoryLayout<TexVertex>.stride * panels.count) {
            encoder.setRenderPipelineState(texturedPipeline)
            encoder.setDepthStencilState(depthWriteState)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentTexture(panelTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: panels.count)
        }

        // Pass B: neon edges (test depth, no write)
        let edges = TunnelMesh.edges(rings: 24, time: time, kick: game.tunnelKick, wave: game.wave)
        if let buf = device.makeBuffer(bytes: edges, length: MemoryLayout<LineVertex>.stride * edges.count) {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(depthTestState)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edges.count)
        }

        // Pass C: player + enemies (additive billboards, depth-tested)
        let t = time
        let playerCenter = TunnelGeometry.worldPoint(lane: game.playerLane, depth: 0.04, time: t, wave: game.wave, kick: game.tunnelKick)
        let pulse = 0.85 + sin(t * 9) * 0.15
        drawSprites(SpriteBatch.billboard(center: playerCenter, size: 0.16, color: SIMD4(0.1, 1, 0.95, pulse)),
                    texture: playerTexture, uniforms: &u, encoder: encoder)

        for kind in EnemyKind.allCases {
            guard let tex = enemyTextures[kind] else { continue }
            var verts: [TexVertex] = []
            for enemy in game.enemies where enemy.kind == kind {
                let center = TunnelGeometry.worldPoint(lane: enemy.lane, depth: enemy.depth, time: t, wave: game.wave, kick: game.tunnelKick)
                let flicker = 0.78 + sin(t * 18 + enemy.phase * 9) * 0.2
                verts += SpriteBatch.billboard(center: center, size: 0.22, color: enemyColor(kind) * SIMD4(1.7, 1.7, 1.7, flicker))
            }
            drawSprites(verts, texture: tex, uniforms: &u, encoder: encoder)
        }

        // Pass C (cont): shots as bright glow billboards
        var shotVerts: [TexVertex] = []
        for shot in game.shots {
            let center = TunnelGeometry.worldPoint(lane: shot.lane, depth: shot.depth, time: t, wave: game.wave, kick: game.tunnelKick)
            shotVerts += SpriteBatch.billboard(center: center, size: 0.25, color: SIMD4(1, 0.95, 0.25, 1))
        }
        drawSprites(shotVerts, texture: glowTexture, uniforms: &u, encoder: encoder)

        // Muzzle flashes at the firing lane near the rim
        var muzzleVerts: [TexVertex] = []
        for flash in game.muzzleFlashes {
            let amount = max(0, min(1, flash.life / flash.initialLife))
            let center = TunnelGeometry.worldPoint(lane: flash.lane, depth: 0.05, time: t, wave: game.wave, kick: game.tunnelKick)
            muzzleVerts += SpriteBatch.billboard(center: center, size: 0.08 + 0.1 * (1 - amount), color: SIMD4(1, 0.9, 0.3, amount))
        }
        drawSprites(muzzleVerts, texture: glowTexture, uniforms: &u, encoder: encoder)

        // Pass D: sparks (additive glow billboards in 3D)
        var sparkVerts: [TexVertex] = []
        for spark in game.sparks {
            let alpha = max(0, min(1, spark.life / spark.initialLife))
            sparkVerts += SpriteBatch.billboard(center: spark.position, size: 0.05 * spark.scale, color: spark.color * SIMD4(1, 1, 1, alpha))
        }
        drawSprites(sparkVerts, texture: glowTexture, uniforms: &u, encoder: encoder)

        // Shockwaves: expanding ring billboards
        var ringVerts: [TexVertex] = []
        for wave in game.shockwaves {
            let alpha = max(0, min(1, wave.life / wave.initialLife))
            ringVerts += SpriteBatch.billboard(center: wave.position, size: wave.radius, color: wave.color * SIMD4(1, 1, 1, alpha * 0.85))
        }
        drawSprites(ringVerts, texture: ringTexture, uniforms: &u, encoder: encoder)
    }

    private func drawSprites(_ verts: [TexVertex], texture: MTLTexture, uniforms u: inout FrameUniforms, encoder: MTLRenderCommandEncoder) {
        guard !verts.isEmpty,
              let buf = device.makeBuffer(bytes: verts, length: MemoryLayout<TexVertex>.stride * verts.count) else { return }
        encoder.setRenderPipelineState(additiveTexturedPipeline)
        encoder.setDepthStencilState(depthTestState)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }

    private func enemyColor(_ kind: EnemyKind) -> SIMD4<Float> {
        switch kind {
        case .spike: SIMD4(1, 0.18, 0.55, 1)
        case .flipper: SIMD4(1, 0.72, 0.05, 1)
        case .tanker: SIMD4(0.2, 0.9, 1, 1)
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
