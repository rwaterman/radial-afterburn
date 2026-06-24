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
    private var frameShakeOffset = SIMD2<Float>(0, 0)

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
        frameShakeOffset = shakeOffset(time: time)

        let pulse = 0.72 + sin(time * 2.5) * 0.16 + game.comboPulse * 0.2
        let gridColor = SIMD4<Float>(0.02, 0.55 + game.tunnelKick * 0.25, 0.94, pulse)
        let rimColor = SIMD4<Float>(0.08 + game.comboPulse * 0.2, 0.95, 1, 0.95)

        for lane in 0..<GameState.laneCount {
            addLine(
                tunnelPoint(lane: lane, depth: 0, time: time),
                tunnelPoint(lane: lane, depth: 1, time: time),
                color: gridColor
            )
        }

        for ring in 0...10 {
            let depth = Float(ring) / 10
            let ringPulse = sin(time * 5.2 - depth * 10) * 0.08 * (1 - depth)
            let color = mix(
                rimColor,
                SIMD4<Float>(0.65, 0.03 + game.tunnelKick * 0.22, 0.86, 0.35),
                depth
            ) + SIMD4<Float>(ringPulse, ringPulse * 0.5, ringPulse, 0)
            for lane in 0..<GameState.laneCount {
                addLine(
                    tunnelPoint(lane: lane, depth: depth, time: time),
                    tunnelPoint(lane: (lane + 1) % GameState.laneCount, depth: depth, time: time),
                    color: color
                )
            }
        }

        for shockwave in game.shockwaves {
            drawShockwave(shockwave, time: time)
        }

        drawPlayer(time: time)

        for muzzleFlash in game.muzzleFlashes {
            drawMuzzleFlash(muzzleFlash, time: time)
        }

        for shot in game.shots {
            drawShot(shot, time: time)
        }

        for enemy in game.enemies {
            drawEnemy(enemy, time: time)
        }

        for spark in game.sparks {
            drawSpark(spark)
        }
    }

    private func drawPlayer(time: Float) {
        let center = tunnelPoint(lane: game.playerLane, depth: 0, time: time)
        let left = tunnelPoint(lane: (game.playerLane - 1 + GameState.laneCount) % GameState.laneCount, depth: 0, time: time)
        let right = tunnelPoint(lane: (game.playerLane + 1) % GameState.laneCount, depth: 0, time: time)
        let inward = tunnelPoint(lane: game.playerLane, depth: 0.085, time: time)
        let side = normalize(right - left)
        let pulse = 0.85 + sin(time * 9) * 0.15
        let cyan = SIMD4<Float>(0.1, 1, 0.95, pulse)
        let angle = Float(game.playerLane) / Float(GameState.laneCount) * .pi * 2 - .pi / 2
        let outward = SIMD2<Float>(cos(angle), sin(angle))
        let thrust = center + outward * (0.035 + sin(time * 24) * 0.012)

        addTriangle(inward, center + side * 0.052, center - side * 0.052, color: cyan)
        addGlowLine(center + side * 0.075, inward, color: SIMD4(0.2, 0.8, 1, 0.8))
        addGlowLine(center - side * 0.075, inward, color: SIMD4(0.2, 0.8, 1, 0.8))
        addGlowLine(thrust + side * 0.025, center, color: SIMD4(0.3, 0.45, 1, 0.55))
        addGlowLine(thrust - side * 0.025, center, color: SIMD4(0.9, 0.1, 1, 0.5))
    }

    private func drawEnemy(_ enemy: Enemy, time: Float) {
        let center = tunnelPoint(lane: enemy.lane, depth: enemy.depth, time: time)
        let scale = 0.018 + (1 - enemy.depth) * 0.048
        let angle = Float(enemy.lane) / Float(GameState.laneCount) * .pi * 2 - .pi / 2
        let radial = SIMD2<Float>(cos(angle), sin(angle))
        let tangent = SIMD2<Float>(-radial.y, radial.x)
        let flicker = 0.76 + sin(time * 18 + enemy.phase * 9) * 0.18

        switch enemy.kind {
        case .spike:
            let color = SIMD4<Float>(1, 0.08, 0.5, 0.75 + flicker * 0.22)
            addTriangle(
                center + radial * scale * 1.7,
                center - radial * scale + tangent * scale,
                center - radial * scale - tangent * scale,
                color: color
            )
            addGlowLine(center - tangent * scale, center + tangent * scale, color: color)
            addGlowLine(center - radial * scale * 1.2, center + radial * scale * 1.95, color: color * SIMD4(1, 1, 1, 0.7))

        case .flipper:
            let color = SIMD4<Float>(1, 0.62, 0.03, 0.78 + flicker * 0.2)
            let flap = sin(time * 9 + enemy.phase * 5) * scale * 0.55
            addTriangle(
                center + radial * scale,
                center - radial * scale + tangent * (scale + flap),
                center - radial * scale - tangent * (scale - flap),
                color: color
            )
            addGlowLine(center - tangent * scale * 1.5, center + tangent * scale * 1.5, color: color)
            addGlowLine(center - radial * scale * 1.4, center + tangent * scale * 1.7, color: color * SIMD4(1, 1, 1, 0.55))
            addGlowLine(center - radial * scale * 1.4, center - tangent * scale * 1.7, color: color * SIMD4(1, 1, 1, 0.55))

        case .tanker:
            let color = SIMD4<Float>(0.08, 0.8, 1, 0.8 + flicker * 0.16)
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
            addRing(center: center, radius: scale * (1.45 + sin(time * 7 + enemy.phase) * 0.14), segments: 16, color: color * SIMD4(1, 1, 1, 0.45))
        }
    }

    private func drawShot(_ shot: Shot, time: Float) {
        let point = tunnelPoint(lane: shot.lane, depth: shot.depth, time: time)
        let next = tunnelPoint(lane: shot.lane, depth: min(1, shot.depth + 0.065), time: time)
        let tail = tunnelPoint(lane: shot.lane, depth: max(0, shot.depth - 0.06), time: time)
        let color = SIMD4<Float>(1, 0.95, 0.2, 1)
        addGlowLine(tail, next, color: color * SIMD4(1, 0.8, 0.5, 0.45))
        addGlowLine(point, next, color: color)
    }

    private func drawMuzzleFlash(_ muzzleFlash: MuzzleFlash, time: Float) {
        let amount = max(0, min(1, muzzleFlash.life / muzzleFlash.initialLife))
        let center = tunnelPoint(lane: muzzleFlash.lane, depth: 0.035, time: time)
        let left = tunnelPoint(lane: (muzzleFlash.lane - 1 + GameState.laneCount) % GameState.laneCount, depth: 0.02, time: time)
        let right = tunnelPoint(lane: (muzzleFlash.lane + 1) % GameState.laneCount, depth: 0.02, time: time)
        let side = normalize(right - left)
        let inner = tunnelPoint(lane: muzzleFlash.lane, depth: 0.12, time: time)
        let color = SIMD4<Float>(1, 0.95, 0.25, amount)
        addGlowLine(center - side * 0.08 * amount, inner, color: color)
        addGlowLine(center + side * 0.08 * amount, inner, color: color)
        addRing(center: center, radius: 0.035 + 0.06 * (1 - amount), segments: 12, color: color * SIMD4(1, 0.7, 0.4, 0.55))
    }

    private func drawSpark(_ spark: Spark) {
        let age = 1 - max(0, min(1, spark.life / spark.initialLife))
        let alpha = max(0, min(1, spark.life / spark.initialLife))
        let trail = spark.velocity * (0.06 + spark.scale * 0.035)
        let color = spark.color * SIMD4(1, 1, 1, alpha)
        addGlowLine(
            spark.position,
            spark.position - trail,
            color: color * SIMD4(1, 1, 1, 0.75)
        )
        if spark.scale > 1.25 {
            addLine(
                spark.position + SIMD2<Float>(-trail.y, trail.x) * 0.08 * (1 - age),
                spark.position + SIMD2<Float>(trail.y, -trail.x) * 0.08 * (1 - age),
                color: color * SIMD4(1, 1, 1, 0.42)
            )
        }
    }

    private func drawShockwave(_ shockwave: Shockwave, time: Float) {
        let alpha = max(0, min(1, shockwave.life / shockwave.initialLife))
        let wobble = 1 + sin(time * 13 + shockwave.radius * 11) * 0.04
        let color = shockwave.color * SIMD4(1, 1, 1, alpha * 0.82)
        addRing(center: shockwave.position, radius: shockwave.radius * wobble, segments: 32, color: color)
        addRing(center: shockwave.position, radius: shockwave.radius * (1.12 + (1 - alpha) * 0.18), segments: 32, color: color * SIMD4(1, 1, 1, 0.35))
    }

    private func addRing(center: SIMD2<Float>, radius: Float, segments: Int, color: SIMD4<Float>) {
        guard segments > 2 else { return }
        for index in 0..<segments {
            let startAngle = Float(index) / Float(segments) * .pi * 2
            let endAngle = Float(index + 1) / Float(segments) * .pi * 2
            let start = center + SIMD2<Float>(cos(startAngle), sin(startAngle)) * radius
            let end = center + SIMD2<Float>(cos(endAngle), sin(endAngle)) * radius
            addGlowLine(start, end, color: color)
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

    private func tunnelPoint(lane: Int, depth: Float, time: Float) -> SIMD2<Float> {
        let base = game.tunnelPoint(lane: lane, depth: depth)
        let angle = Float(lane) / Float(GameState.laneCount) * .pi * 2 - .pi / 2
        let radial = SIMD2<Float>(cos(angle), sin(angle))
        let tangent = SIMD2<Float>(-radial.y, radial.x)
        let nearField = 1 - depth
        let kick = game.tunnelKick * nearField
        let combo = game.comboPulse * nearField
        let radialWarp = sin(time * 7.5 + depth * 18 + Float(lane) * 0.7) * (0.018 * kick + 0.006 * combo)
        let twist = sin(time * 4.2 + depth * 11 + Float(game.wave)) * (0.014 * kick)
        return base + radial * radialWarp + tangent * twist
    }

    private func shakeOffset(time: Float) -> SIMD2<Float> {
        let amount = game.screenShake * 0.026
        guard amount > 0 else { return SIMD2(0, 0) }
        return SIMD2(
            sin(time * 79.0) * amount + sin(time * 41.0) * amount * 0.42,
            cos(time * 83.0) * amount + sin(time * 57.0) * amount * 0.36
        )
    }

    private func screenPoint(_ point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(point.x * horizontalScale, point.y) + frameShakeOffset
    }
}

enum RendererError: Error {
    case metalUnavailable
}
