import Metal
import MetalKit
import simd

struct VectorVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

@MainActor
final class Renderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var lastFrameTime = CACurrentMediaTime()
    private var lineVertices: [VectorVertex] = []
    private var triangleVertices: [VectorVertex] = []
    private var horizontalScale: Float = 1

    var game = GameState()
    var onHUDUpdate: ((GameState) -> Void)?

    init(view: MTKView) throws {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue() else {
            throw RendererError.metalUnavailable
        }
        self.device = device
        self.commandQueue = commandQueue

        let library = try device.makeLibrary(source: metalShaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vectorVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "vectorFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let deltaTime = Float(now - lastFrameTime)
        lastFrameTime = now
        game.update(deltaTime: deltaTime)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(game.flash) * 0.055,
            green: Double(game.flash) * 0.018,
            blue: Double(game.flash) * 0.08,
            alpha: 1
        )
        horizontalScale = Float(view.drawableSize.height / max(view.drawableSize.width, 1))

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }

        buildGeometry(time: Float(now))
        encoder.setRenderPipelineState(pipeline)
        draw(vertices: lineVertices, primitive: .line, encoder: encoder)
        draw(vertices: triangleVertices, primitive: .triangle, encoder: encoder)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        onHUDUpdate?(game)
    }

    private func draw(vertices: [VectorVertex], primitive: MTLPrimitiveType, encoder: MTLRenderCommandEncoder) {
        guard !vertices.isEmpty,
              let buffer = device.makeBuffer(
                bytes: vertices,
                length: MemoryLayout<VectorVertex>.stride * vertices.count
              ) else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: vertices.count)
    }

    private func buildGeometry(time: Float) {
        lineVertices.removeAll(keepingCapacity: true)
        triangleVertices.removeAll(keepingCapacity: true)

        let pulse = 0.72 + sin(time * 2.5) * 0.16
        let gridColor = SIMD4<Float>(0.02, 0.55, 0.94, pulse)
        let rimColor = SIMD4<Float>(0.08, 0.95, 1, 0.95)

        for lane in 0..<GameState.laneCount {
            addLine(
                game.tunnelPoint(lane: lane, depth: 0),
                game.tunnelPoint(lane: lane, depth: 1),
                color: gridColor
            )
        }

        for ring in 0...8 {
            let depth = Float(ring) / 8
            let color = mix(rimColor, SIMD4<Float>(0.65, 0.03, 0.86, 0.35), depth)
            for lane in 0..<GameState.laneCount {
                addLine(
                    game.tunnelPoint(lane: lane, depth: depth),
                    game.tunnelPoint(lane: (lane + 1) % GameState.laneCount, depth: depth),
                    color: color
                )
            }
        }

        drawPlayer(time: time)

        for shot in game.shots {
            let point = game.tunnelPoint(lane: shot.lane, depth: shot.depth)
            let next = game.tunnelPoint(lane: shot.lane, depth: min(1, shot.depth + 0.055))
            addGlowLine(point, next, color: SIMD4(1, 0.95, 0.2, 1))
        }

        for enemy in game.enemies {
            drawEnemy(enemy, time: time)
        }

        for spark in game.sparks {
            let alpha = max(0, min(1, spark.life * 2))
            addLine(
                spark.position,
                spark.position - spark.velocity * 0.08,
                color: spark.color * SIMD4(1, 1, 1, alpha)
            )
        }
    }

    private func drawPlayer(time: Float) {
        let center = game.tunnelPoint(lane: game.playerLane, depth: 0)
        let left = game.tunnelPoint(lane: (game.playerLane - 1 + GameState.laneCount) % GameState.laneCount, depth: 0)
        let right = game.tunnelPoint(lane: (game.playerLane + 1) % GameState.laneCount, depth: 0)
        let inward = game.tunnelPoint(lane: game.playerLane, depth: 0.085)
        let side = normalize(right - left)
        let pulse = 0.85 + sin(time * 9) * 0.15
        let cyan = SIMD4<Float>(0.1, 1, 0.95, pulse)

        addTriangle(inward, center + side * 0.052, center - side * 0.052, color: cyan)
        addGlowLine(center + side * 0.075, inward, color: SIMD4(0.2, 0.8, 1, 0.8))
        addGlowLine(center - side * 0.075, inward, color: SIMD4(0.2, 0.8, 1, 0.8))
    }

    private func drawEnemy(_ enemy: Enemy, time: Float) {
        let center = game.tunnelPoint(lane: enemy.lane, depth: enemy.depth)
        let scale = 0.018 + (1 - enemy.depth) * 0.048
        let angle = Float(enemy.lane) / Float(GameState.laneCount) * .pi * 2 - .pi / 2
        let radial = SIMD2<Float>(cos(angle), sin(angle))
        let tangent = SIMD2<Float>(-radial.y, radial.x)

        switch enemy.kind {
        case .spike:
            let color = SIMD4<Float>(1, 0.08, 0.5, 0.95)
            addTriangle(
                center + radial * scale * 1.7,
                center - radial * scale + tangent * scale,
                center - radial * scale - tangent * scale,
                color: color
            )
            addGlowLine(center - tangent * scale, center + tangent * scale, color: color)

        case .flipper:
            let color = SIMD4<Float>(1, 0.62, 0.03, 0.95)
            let flap = sin(time * 9 + enemy.phase * 5) * scale * 0.55
            addTriangle(
                center + radial * scale,
                center - radial * scale + tangent * (scale + flap),
                center - radial * scale - tangent * (scale - flap),
                color: color
            )
            addGlowLine(center - tangent * scale * 1.5, center + tangent * scale * 1.5, color: color)

        case .tanker:
            let color = SIMD4<Float>(0.08, 0.8, 1, 0.95)
            let corners = [
                center + radial * scale + tangent * scale,
                center + radial * scale - tangent * scale,
                center - radial * scale - tangent * scale,
                center - radial * scale + tangent * scale
            ]
            addTriangle(corners[0], corners[1], corners[2], color: color * SIMD4(0.45, 0.45, 0.45, 0.55))
            addTriangle(corners[0], corners[2], corners[3], color: color * SIMD4(0.45, 0.45, 0.45, 0.55))
            for index in 0..<4 {
                addGlowLine(corners[index], corners[(index + 1) % 4], color: color)
            }
        }
    }

    private func addGlowLine(_ a: SIMD2<Float>, _ b: SIMD2<Float>, color: SIMD4<Float>) {
        addLine(a, b, color: color * SIMD4(0.25, 0.25, 0.25, 0.22))
        addLine(a, b, color: color)
    }

    private func addLine(_ a: SIMD2<Float>, _ b: SIMD2<Float>, color: SIMD4<Float>) {
        lineVertices.append(VectorVertex(position: screenPoint(a), color: color))
        lineVertices.append(VectorVertex(position: screenPoint(b), color: color))
    }

    private func addTriangle(
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        _ c: SIMD2<Float>,
        color: SIMD4<Float>
    ) {
        triangleVertices.append(VectorVertex(position: screenPoint(a), color: color))
        triangleVertices.append(VectorVertex(position: screenPoint(b), color: color))
        triangleVertices.append(VectorVertex(position: screenPoint(c), color: color))
    }

    private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ amount: Float) -> SIMD4<Float> {
        a * (1 - amount) + b * amount
    }

    private func screenPoint(_ point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(point.x * horizontalScale, point.y)
    }
}

enum RendererError: Error {
    case metalUnavailable
}
