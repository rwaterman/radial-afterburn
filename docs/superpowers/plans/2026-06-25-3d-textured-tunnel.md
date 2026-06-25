# 3D Textured Tunnel + Bloom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Radial Afterburn's flat 2D vector renderer with a 3D perspective tunnel — procedural texture-mapped walls, billboard sprites, distance fog, and a bloom post-process pass.

**Architecture:** Gameplay stays in abstract `lane`/`depth`; a pure `simd`-only `TunnelGeometry` + `Matrix` core (unit-tested, CI-safe) projects those into a 3D world rendered with a real perspective camera. The renderer is decoupled from `MTKView` so a headless `--screenshot` mode can render frames to PNG for permission-free visual verification at each staged checkpoint. Bloom is the final pass: scene → `rgba16Float` HDR target → bright-pass → separable blur → composite.

**Tech Stack:** Swift 6.2, Metal / MetalKit, AppKit, `simd`, Swift Testing, ImageIO (PNG writeback).

## Global Constraints

- macOS 14+ target; `swift-tools-version: 6.2`; Swift 6 strict concurrency. Metal types stay `@MainActor`.
- CI runs `swift build` + `swift test` on a runner with **no guaranteed GPU**: tests MUST NOT construct an `MTLDevice`, a pipeline, or `Renderer`. Only pure `simd`/`Foundation` code is unit-tested.
- `GameState.swift` imports only `Foundation` / `simd` — never Metal/MetalKit.
- No bundled binary assets. All textures are filled in code at startup.
- `laneCount` has a single source of truth: `TunnelGeometry.laneCount` (= 16). `GameState.laneCount` aliases it.
- Existing `GameStateTests` stay green; they assert `sparks`/`shockwaves` only for emptiness.
- Branch: `feat/3d-textured-tunnel` (already created; spec committed there).
- Metal tasks are gated by `--screenshot` PNG review, not unit tests. Each ends by writing a PNG to `/tmp/nv-*.png` and confirming it visually before commit.

---

### Task 1: Pure projection math — `Matrix.swift`

**Files:**
- Create: `Sources/RadialAfterburn/Matrix.swift`
- Test: `Tests/RadialAfterburnTests/MatrixTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `func perspectiveMatrix(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4` — right-handed, looking down −Z, clip z in [0,1] (Metal convention).
  - `func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4` — right-handed view matrix.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/RadialAfterburnTests/MatrixTests.swift
import Testing
import simd
@testable import RadialAfterburn

@Suite("Matrix")
struct MatrixTests {
    private func approx(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool { abs(a - b) <= tol }

    @Test("Perspective foreshortens: same world X projects smaller when farther")
    func perspectiveForeshortens() {
        let p = perspectiveMatrix(fovyRadians: .pi / 3, aspect: 1, near: 0.1, far: 100)
        let near = p * SIMD4<Float>(1, 0, -2, 1)
        let far = p * SIMD4<Float>(1, 0, -10, 1)
        let nearX = near.x / near.w
        let farX = far.x / far.w
        #expect(abs(farX) < abs(nearX))
    }

    @Test("Perspective keeps the axis point centered")
    func perspectiveCentered() {
        let p = perspectiveMatrix(fovyRadians: .pi / 3, aspect: 1.6, near: 0.1, far: 100)
        let c = p * SIMD4<Float>(0, 0, -5, 1)
        #expect(approx(c.x / c.w, 0))
        #expect(approx(c.y / c.w, 0))
    }

    @Test("lookAt produces an orthonormal basis")
    func lookAtOrthonormal() {
        let v = lookAtMatrix(eye: SIMD3(0, 0, 0), center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        let right = SIMD3(v.columns.0.x, v.columns.1.x, v.columns.2.x)
        let upv = SIMD3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
        let fwd = SIMD3(v.columns.0.z, v.columns.1.z, v.columns.2.z)
        #expect(approx(length(right), 1))
        #expect(approx(length(upv), 1))
        #expect(approx(length(fwd), 1))
        #expect(approx(dot(right, upv), 0))
    }

    @Test("lookAt at origin looking -Z is identity-like for forward points")
    func lookAtForward() {
        let v = lookAtMatrix(eye: SIMD3(0, 0, 0), center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        let p = v * SIMD4<Float>(0, 0, -5, 1)
        #expect(approx(p.z, -5))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MatrixTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'perspectiveMatrix' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/RadialAfterburn/Matrix.swift
import simd

/// Right-handed perspective projection, camera looking down -Z, clip-space z in [0, 1] (Metal).
func perspectiveMatrix(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
    let y = 1 / tan(fovyRadians * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return matrix_float4x4(columns: (
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * near, 0)
    ))
}

/// Right-handed view matrix.
func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return matrix_float4x4(columns: (
        SIMD4<Float>(s.x, u.x, -f.x, 0),
        SIMD4<Float>(s.y, u.y, -f.y, 0),
        SIMD4<Float>(s.z, u.z, -f.z, 0),
        SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
    ))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MatrixTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/RadialAfterburn/Matrix.swift Tests/RadialAfterburnTests/MatrixTests.swift
git commit -m "feat: pure perspective/lookAt matrix helpers"
```

---

### Task 2: Pure tunnel model — `TunnelGeometry.swift`

**Files:**
- Create: `Sources/RadialAfterburn/TunnelGeometry.swift`
- Test: `Tests/RadialAfterburnTests/TunnelGeometryTests.swift`

**Interfaces:**
- Consumes: nothing (pure `simd`).
- Produces:
  - `enum TunnelGeometry` with `static let laneCount: Int = 16`, `static let nearZ: Float = -1.6`, `static let farZ: Float = -16`, `static let radius: Float = 0.95`.
  - `static func depthZ(_ depth: Float) -> Float`
  - `static func angle(lane: Int) -> Float`
  - `static func worldPoint(lane: Int, depth: Float, time: Float = 0, wave: Int = 0, kick: Float = 0) -> SIMD3<Float>`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/RadialAfterburnTests/TunnelGeometryTests.swift
import Testing
import simd
@testable import RadialAfterburn

@Suite("Tunnel geometry")
struct TunnelGeometryTests {
    @Test("Greater depth maps farther into the screen (more negative Z)")
    func depthGoesIntoScreen() {
        #expect(TunnelGeometry.worldPoint(lane: 0, depth: 1).z < TunnelGeometry.worldPoint(lane: 0, depth: 0).z)
        #expect(TunnelGeometry.depthZ(0) == TunnelGeometry.nearZ)
        #expect(TunnelGeometry.depthZ(1) == TunnelGeometry.farZ)
    }

    @Test("World ring radius is constant across depth (perspective does the shrinking)")
    func radiusConstant() {
        let near = TunnelGeometry.worldPoint(lane: 3, depth: 0)
        let far = TunnelGeometry.worldPoint(lane: 3, depth: 1)
        let rNear = length(SIMD2(near.x, near.y))
        let rFar = length(SIMD2(far.x, far.y))
        #expect(abs(rNear - rFar) < 0.02)
        #expect(abs(rNear - TunnelGeometry.radius) < 0.02)
    }

    @Test("Lane index wraps: laneCount == lane 0")
    func laneWraps() {
        let a = TunnelGeometry.worldPoint(lane: 0, depth: 0)
        let b = TunnelGeometry.worldPoint(lane: TunnelGeometry.laneCount, depth: 0)
        #expect(abs(a.x - b.x) < 1e-4)
        #expect(abs(a.y - b.y) < 1e-4)
    }

    @Test("GameState reuses the same lane count")
    func laneCountShared() {
        #expect(GameState.laneCount == TunnelGeometry.laneCount)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TunnelGeometryTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'TunnelGeometry' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/RadialAfterburn/TunnelGeometry.swift
import simd

/// Pure model of the tube in world space. No Metal, no Foundation — unit-tested headless.
/// A ring of `laneCount` vertices at constant world `radius`, extruded along -Z from the
/// near rim (`depth 0`, z = nearZ) to the far vanishing point (`depth 1`, z = farZ).
/// Perspective foreshortening — not a per-depth radius shrink — makes far rings small.
enum TunnelGeometry {
    static let laneCount = 16
    static let nearZ: Float = -1.6
    static let farZ: Float = -16
    static let radius: Float = 0.95

    static func depthZ(_ depth: Float) -> Float {
        nearZ + (farZ - nearZ) * depth
    }

    static func angle(lane: Int) -> Float {
        Float(lane) / Float(laneCount) * .pi * 2 - .pi / 2
    }

    /// World-space point for a lane/depth, optionally perturbed by the time warp + per-wave drift.
    static func worldPoint(lane: Int, depth: Float, time: Float = 0, wave: Int = 0, kick: Float = 0) -> SIMD3<Float> {
        let a = angle(lane: lane)
        let nearField = 1 - depth
        let warp = sin(time * 7.5 + depth * 18 + Float(lane) * 0.7) * (0.05 * kick * nearField)
        let r = radius + warp
        let drift = SIMD2<Float>(sin(Float(wave) * 0.31) * 0.05, cos(Float(wave) * 0.23) * 0.04) * depth
        return SIMD3<Float>(cos(a) * r + drift.x, sin(a) * r + drift.y, depthZ(depth))
    }
}
```

- [ ] **Step 4: Update `GameState.laneCount` to alias the shared constant**

In `Sources/RadialAfterburn/GameState.swift`, change the line `static let laneCount = 16` to:

```swift
    static let laneCount = TunnelGeometry.laneCount
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TunnelGeometryTests 2>&1 | tail -20`
Expected: PASS (4 tests). Then `swift test 2>&1 | tail -5` — all suites still green.

- [ ] **Step 6: Commit**

```bash
git add Sources/RadialAfterburn/TunnelGeometry.swift Tests/RadialAfterburnTests/TunnelGeometryTests.swift Sources/RadialAfterburn/GameState.swift
git commit -m "feat: pure 3D tunnel geometry model"
```

---

### Task 3: Widen particles to 3D — `GameState.swift`

**Files:**
- Modify: `Sources/RadialAfterburn/GameState.swift` (`Spark`, `Shockwave`, `update`, `emitExplosion`, `emitShockwave`, wave-clear branch)
- Test: `Tests/RadialAfterburnTests/GameStateTests.swift` (add one test; existing stay green)

**Interfaces:**
- Consumes: `TunnelGeometry.worldPoint`.
- Produces: `Spark.position: SIMD3<Float>`, `Spark.velocity: SIMD3<Float>`, `Shockwave.position: SIMD3<Float>` consumed by `SpriteBatch` in Task 9.

- [ ] **Step 1: Write the failing test**

```swift
// Add to Tests/RadialAfterburnTests/GameStateTests.swift inside the GameStateTests suite
    @Test("Explosion sparks originate inside the tunnel's Z range")
    func sparksAreInTunnelSpace() {
        var game = GameState()
        destroyFirstEnemy(in: &game)

        #expect(!game.sparks.isEmpty)
        for spark in game.sparks {
            #expect(spark.position.z <= TunnelGeometry.nearZ + 0.01)
            #expect(spark.position.z >= TunnelGeometry.farZ - 0.01)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter sparksAreInTunnelSpace 2>&1 | tail -20`
Expected: FAIL — `value of type 'SIMD2<Float>' has no member` / type mismatch on `.z` (sparks are still 2D).

- [ ] **Step 3: Change the structs to 3D**

In `Sources/RadialAfterburn/GameState.swift`, change `Spark` and `Shockwave`:

```swift
struct Spark: Identifiable {
    let id: UUID
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var life: Float
    var initialLife: Float
    var scale: Float
    var color: SIMD4<Float>
}

struct Shockwave: Identifiable {
    let id: UUID
    var position: SIMD3<Float>
    var radius: Float
    var speed: Float
    var life: Float
    var initialLife: Float
    var color: SIMD4<Float>
}
```

- [ ] **Step 4: Update the emit + update sites to 3D**

In `update(deltaTime:)` the spark integration already reads `position += velocity * deltaTime`; with 3D vectors it compiles unchanged. Update `emitShockwave`'s signature and the two emit sites:

```swift
    private mutating func emitShockwave(
        position: SIMD3<Float>,
        radius: Float,
        speed: Float,
        life: Float,
        color: SIMD4<Float>
    ) {
        shockwaves.append(
            Shockwave(
                id: UUID(),
                position: position,
                radius: radius,
                speed: speed,
                life: life,
                initialLife: life,
                color: color
            )
        )
    }
```

In `emitExplosion(lane:depth:kind:)` change the origin and the spark velocities:

```swift
        let origin = TunnelGeometry.worldPoint(lane: lane, depth: depth, wave: wave)
```

and the spark loop body:

```swift
        for index in 0..<sparkCount {
            let angle = random.nextFloat() * .pi * 2
            let speed = 0.18 + random.nextFloat() * (kind == .tanker ? 0.9 : 0.62)
            let life = 0.28 + random.nextFloat() * (kind == .tanker ? 0.72 : 0.52)
            let scale = 0.7 + random.nextFloat() * (index % 3 == 0 ? 1.9 : 1.1)
            let zKick = (random.nextFloat() - 0.5) * speed * 0.6
            sparks.append(
                Spark(
                    id: UUID(),
                    position: origin,
                    velocity: SIMD3(cos(angle) * speed, sin(angle) * speed, zKick),
                    life: life,
                    initialLife: life,
                    scale: scale,
                    color: color
                )
            )
        }
```

In the wave-clear branch inside `update(deltaTime:)`, change the shockwave origin:

```swift
            emitShockwave(
                position: SIMD3<Float>(0, 0, TunnelGeometry.depthZ(0.5)),
                radius: 0.12,
                speed: 2.4,
                life: 0.8,
                color: SIMD4(0.2, 1, 0.95, 1)
            )
```

- [ ] **Step 5: Run the whole suite to verify green**

Run: `swift test 2>&1 | tail -10`
Expected: PASS — the new `sparksAreInTunnelSpace` test plus all existing `GameStateTests` (emptiness assertions are unaffected by the dimensionality change).

- [ ] **Step 6: Commit**

```bash
git add Sources/RadialAfterburn/GameState.swift Tests/RadialAfterburnTests/GameStateTests.swift
git commit -m "feat: emit explosion particles in 3D tunnel space"
```

---

### Task 4: Rendering spine — decoupled `Renderer`, `Shaders`, `Screenshot`, arg parsing

This stands up the new rendering structure with a minimal scene (clear + one full-screen-projected neon triangle) so the offscreen screenshot path, PNG writeback, MTKView decoupling, and pipeline creation are all proven before any tunnel geometry exists. The old 2D drawing is removed; the game window temporarily shows the placeholder scene.

**Files:**
- Rewrite: `Sources/RadialAfterburn/Shaders.swift`
- Rewrite: `Sources/RadialAfterburn/Renderer.swift`
- Create: `Sources/RadialAfterburn/Screenshot.swift`
- Modify: `Sources/RadialAfterburn/MetalGameView.swift` (init signature)
- Modify: `Sources/RadialAfterburn/main.swift` (arg dispatch before `app.run()`)

**Interfaces:**
- Produces:
  - Shared MSL `Uniforms` struct mirrored in Swift as `struct FrameUniforms { var viewProjection: matrix_float4x4; var time: Float; var fogStart: Float; var fogEnd: Float; var pad: Float }`.
  - `final class Renderer { init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws; func draw(in view: MTKView); func renderSnapshot(width: Int, height: Int) -> [UInt8] }`
  - `Renderer` internal `func encodeScene(encoder: MTLRenderCommandEncoder, size: SIMD2<Float>, time: Float)` — extended by Tasks 5–9.
  - `func runScreenshot(path: String, frames: Int, width: Int, height: Int) -> Bool` in `Screenshot.swift`.

- [ ] **Step 1: Write `Shaders.swift`** (replace entire file)

```swift
let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
    float time;
    float fogStart;
    float fogEnd;
    float pad;
};

struct LineVertex {
    float3 position;
    float4 color;
};

struct LineRaster {
    float4 position [[position]];
    float4 color;
};

static float fogFactor(float viewZ, float fogStart, float fogEnd) {
    // viewZ is negative going into the screen; use distance = -viewZ.
    float d = -viewZ;
    return clamp((d - fogStart) / max(fogEnd - fogStart, 0.0001), 0.0, 1.0);
}

vertex LineRaster neonLineVertex(
    uint vertexID [[vertex_id]],
    const device LineVertex *vertices [[buffer(0)]],
    constant Uniforms &u [[buffer(1)]]
) {
    LineRaster out;
    float4 world = float4(vertices[vertexID].position, 1.0);
    out.position = u.viewProjection * world;
    float fog = fogFactor(world.z, u.fogStart, u.fogEnd);
    out.color = vertices[vertexID].color * float4(1.0, 1.0, 1.0, 1.0 - fog);
    return out;
}

fragment float4 neonLineFragment(LineRaster in [[stage_in]]) {
    return in.color;
}
"""
```

- [ ] **Step 2: Write `Renderer.swift`** (replace entire file)

```swift
import Metal
import MetalKit
import simd

struct LineVertex {
    var position: SIMD3<Float>
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
    }

    static func makeLinePipeline(device: MTLDevice, library: MTLLibrary, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
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

        encode(pass: pass, size: size, time: Float(now - startTime))?.present(drawable).commit()
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

    @discardableResult
    private func encode(pass: MTLRenderPassDescriptor, size: SIMD2<Float>, time: Float) -> MTLCommandBuffer? {
        guard let cb = commandQueue.makeCommandBuffer(),
              let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encodeScene(encoder: encoder, size: size, time: time)
        encoder.endEncoding()
        return cb
    }

    /// Scene contents. Extended by Tasks 5-9. Task 4 draws one neon test triangle.
    func encodeScene(encoder: MTLRenderCommandEncoder, size: SIMD2<Float>, time: Float) {
        var u = uniforms(size: size, time: time)
        let verts: [LineVertex] = [
            LineVertex(position: SIMD3(-0.6, -0.4, -3), color: SIMD4(0.1, 1, 0.95, 1)),
            LineVertex(position: SIMD3(0.6, -0.4, -3), color: SIMD4(1, 0.1, 0.6, 1)),
            LineVertex(position: SIMD3(0, 0.6, -3), color: SIMD4(0.2, 0.6, 1, 1)),
        ]
        guard let buf = device.makeBuffer(bytes: verts, length: MemoryLayout<LineVertex>.stride * verts.count) else { return }
        encoder.setRenderPipelineState(linePipeline)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: verts.count)
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

private extension MTLCommandBuffer {
    @discardableResult func present(_ drawable: MTLDrawable) -> MTLCommandBuffer { self.present(drawable); return self }
}

enum RendererError: Error {
    case metalUnavailable
}
```

Note: the `present` helper above conflicts with the built-in `present(_:)`. Replace the live-path present/commit line with the explicit two calls instead of the helper:

```swift
        if let cb = encode(pass: pass, size: size, time: Float(now - startTime)) {
            cb.present(drawable)
            cb.commit()
        }
```

and delete the `private extension MTLCommandBuffer` block.

- [ ] **Step 3: Update `MetalGameView.swift` init**

Change the `Renderer` construction in `convenience init(gameFrame:)` from `Renderer(view: self)` to:

```swift
        renderer = try Renderer(device: device, colorPixelFormat: colorPixelFormat)
```

Keep `framebufferOnly = true`. No depth format on the view (the Renderer owns depth from Task 6 on, in its own pass). The rest of `MetalGameView` is unchanged.

- [ ] **Step 4: Write `Screenshot.swift`**

```swift
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
```

- [ ] **Step 5: Dispatch `--screenshot` in `main.swift`**

Insert before `let app = NSApplication.shared` near the bottom of `main.swift`:

```swift
let arguments = CommandLine.arguments
if let idx = arguments.firstIndex(of: "--screenshot") {
    let path = idx + 1 < arguments.count ? arguments[idx + 1] : "/tmp/nv.png"
    func intArg(_ name: String, _ def: Int) -> Int {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count, let v = Int(arguments[i + 1]) else { return def }
        return v
    }
    let frames = intArg("--frames", 90)
    let width = intArg("--width", 1100)
    let height = intArg("--height", 760)
    let ok = MainActor.assumeIsolated { runScreenshot(path: path, frames: frames, width: width, height: height) }
    exit(ok ? 0 : 1)
}
```

- [ ] **Step 6: Build, then render a screenshot and verify it visually**

```bash
swift build 2>&1 | tail -5
.build/debug/RadialAfterburn --screenshot /tmp/nv-task4.png --frames 1 --width 800 --height 600
```
Expected: build succeeds; `/tmp/nv-task4.png` exists. **Open/Read `/tmp/nv-task4.png`** and confirm a dark frame with a single cyan→magenta→blue neon triangle outline near center. (This proves device init, pipeline, offscreen render, readback, PNG writeback, and arg parsing — with no GPU dependency on a window.)

- [ ] **Step 7: Confirm the live window still runs**

```bash
swift build 2>&1 | tail -3
```
Expected: clean build. (Reviewer may run `.build/debug/RadialAfterburn` to see the same placeholder triangle in-window; not required for the gate.)

- [ ] **Step 8: Commit**

```bash
git add Sources/RadialAfterburn/Shaders.swift Sources/RadialAfterburn/Renderer.swift Sources/RadialAfterburn/Screenshot.swift Sources/RadialAfterburn/MetalGameView.swift Sources/RadialAfterburn/main.swift
git commit -m "feat: decoupled renderer spine + offscreen screenshot mode"
```

---

### Task 5: Textured tunnel wall panels (Checkpoint A, part 1)

**Files:**
- Create: `Sources/RadialAfterburn/TextureFactory.swift`
- Create: `Sources/RadialAfterburn/TunnelMesh.swift`
- Modify: `Sources/RadialAfterburn/Shaders.swift` (add `texturedLit` functions + `TexVertex`)
- Modify: `Sources/RadialAfterburn/Renderer.swift` (textured pipeline, panel texture, draw panels in `encodeScene`)

**Interfaces:**
- Consumes: `TunnelGeometry.worldPoint`, `FrameUniforms`.
- Produces:
  - `struct TexVertex { var position: SIMD3<Float>; var uv: SIMD2<Float>; var color: SIMD4<Float> }` (Swift + matching MSL).
  - `enum TextureFactory { static func neonPanel(device:) -> MTLTexture }`
  - `enum TunnelMesh { static func wallPanels(rings: Int, time: Float, kick: Float, wave: Int) -> [TexVertex] }`

- [ ] **Step 1: Add `texturedLit` shaders to `Shaders.swift`**

Insert these into the MSL string (before the closing `"""`):

```c
struct TexVertex {
    float3 position;
    float2 uv;
    float4 color;
};

struct TexRaster {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float viewZ;
};

vertex TexRaster texturedVertex(
    uint vertexID [[vertex_id]],
    const device TexVertex *vertices [[buffer(0)]],
    constant Uniforms &u [[buffer(1)]]
) {
    TexRaster out;
    float4 world = float4(vertices[vertexID].position, 1.0);
    out.position = u.viewProjection * world;
    out.uv = vertices[vertexID].uv;
    out.color = vertices[vertexID].color;
    out.viewZ = world.z;
    return out;
}

fragment float4 texturedFragment(
    TexRaster in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant Uniforms &u [[buffer(1)]]
) {
    constexpr sampler s(address::repeat, filter::linear, mip_filter::linear);
    float4 sampled = tex.sample(s, in.uv);
    float4 lit = sampled * in.color;
    float fog = fogFactor(in.viewZ, u.fogStart, u.fogEnd);
    lit.rgb *= (1.0 - fog);
    lit.a *= (1.0 - fog);
    return lit;
}
```

- [ ] **Step 2: Write `TextureFactory.swift`**

```swift
import Metal
import simd

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

    static func smoothLine(_ d: Float, _ width: Float) -> Float {
        max(0, 1 - d / width)
    }

    static func valueNoise(_ x: Float, _ y: Float) -> Float {
        let n = sin(x * 12.9898 + y * 78.233) * 43758.5453
        return n - floor(n)
    }

    static func toByte(_ v: Float) -> UInt8 {
        UInt8(max(0, min(1, v)) * 255)
    }

    static func upload(device: MTLDevice, pixels: [UInt8], size: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: true)
        desc.usage = [.shaderRead]
        let tex = device.makeTexture(descriptor: desc)!
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: size * 4)
        }
        if let queue = device.makeCommandQueue(), let cb = queue.makeCommandBuffer(),
           let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return tex
    }
}
```

- [ ] **Step 3: Write `TunnelMesh.swift`** (panels only this task)

```swift
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
```

- [ ] **Step 4: Wire panels into `Renderer`**

Add stored properties and pipeline. In `Renderer`:

```swift
    private let texturedPipeline: MTLRenderPipelineState
    private let panelTexture: MTLTexture
```

In `init`, after `linePipeline`:

```swift
        self.texturedPipeline = try Renderer.makeTexturedPipeline(device: device, library: library, format: colorPixelFormat, additive: false)
        self.panelTexture = TextureFactory.neonPanel(device: device)
```

Add the pipeline factory:

```swift
    static func makeTexturedPipeline(device: MTLDevice, library: MTLLibrary, format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
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
```

Replace the placeholder body of `encodeScene` with the panel draw:

```swift
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
```

Add `struct TexVertex` to `Renderer.swift` near `LineVertex`:

```swift
struct TexVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
}
```

- [ ] **Step 5: Build + screenshot + verify**

```bash
swift build 2>&1 | tail -5
.build/debug/RadialAfterburn --screenshot /tmp/nv-task5.png --frames 1 --width 1000 --height 700
```
Expected: build clean; **Read `/tmp/nv-task5.png`** and confirm a textured tube receding to a vanishing point — glowing cyan grid seams on the near rings fading to violet down the throat. There is no occlusion yet (no depth buffer) and no bright edges; those come in Task 6.

- [ ] **Step 6: Commit**

```bash
git add Sources/RadialAfterburn/TextureFactory.swift Sources/RadialAfterburn/TunnelMesh.swift Sources/RadialAfterburn/Shaders.swift Sources/RadialAfterburn/Renderer.swift
git commit -m "feat: textured 3D tunnel wall panels"
```

---

### Task 6: Neon edges + depth buffer + fog (Checkpoint A complete)

**Files:**
- Modify: `Sources/RadialAfterburn/TunnelMesh.swift` (add `edges`)
- Modify: `Sources/RadialAfterburn/Renderer.swift` (depth texture + depth-stencil states, edge draw, pass order)

**Interfaces:**
- Produces: `static func TunnelMesh.edges(rings: Int, time: Float, kick: Float, wave: Int) -> [LineVertex]`; `Renderer` now owns a `Depth32Float` texture + two `MTLDepthStencilState`s (`depthWriteState`, `depthTestState`).

- [ ] **Step 1: Add `edges` to `TunnelMesh.swift`**

```swift
    /// Bright neon wireframe: depth rings + radial lane lines, as line-list vertices.
    static func edges(rings: Int, time: Float, kick: Float, wave: Int) -> [LineVertex] {
        var out: [LineVertex] = []
        let rim = SIMD4<Float>(0.1, 1.0, 1.0, 0.95)
        for ring in 0...rings {
            let d = Float(ring) / Float(rings)
            let color = rim * SIMD4<Float>(1, 1, 1, 1 - d * 0.5)
            for lane in 0..<TunnelGeometry.laneCount {
                let next = (lane + 1) % TunnelGeometry.laneCount
                out.append(LineVertex(position: TunnelGeometry.worldPoint(lane: lane, depth: d, time: time, wave: wave, kick: kick), color: color))
                out.append(LineVertex(position: TunnelGeometry.worldPoint(lane: next, depth: d, time: time, wave: wave, kick: kick), color: color))
            }
        }
        for lane in 0..<TunnelGeometry.laneCount {
            let color = SIMD4<Float>(0.02, 0.6 + kick * 0.25, 0.94, 0.8)
            out.append(LineVertex(position: TunnelGeometry.worldPoint(lane: lane, depth: 0, time: time, wave: wave, kick: kick), color: color))
            out.append(LineVertex(position: TunnelGeometry.worldPoint(lane: lane, depth: 1, time: time, wave: wave, kick: kick), color: color))
        }
        return out
    }
```

- [ ] **Step 2: Add depth state to `Renderer`**

Add properties:

```swift
    private var depthTexture: MTLTexture?
    private let depthWriteState: MTLDepthStencilState
    private let depthTestState: MTLDepthStencilState
```

In `init`, before the pipelines, build the states:

```swift
        let writeDesc = MTLDepthStencilDescriptor()
        writeDesc.depthCompareFunction = .less
        writeDesc.isDepthWriteEnabled = true
        self.depthWriteState = device.makeDepthStencilState(descriptor: writeDesc)!
        let testDesc = MTLDepthStencilDescriptor()
        testDesc.depthCompareFunction = .lessEqual
        testDesc.isDepthWriteEnabled = false
        self.depthTestState = device.makeDepthStencilState(descriptor: testDesc)!
```

Both pipelines need a depth attachment format. In `makeLinePipeline` and `makeTexturedPipeline`, add before `return`:

```swift
        d.depthAttachmentPixelFormat = .depth32Float
```

- [ ] **Step 3: Attach depth in both render paths and order the passes**

Add a helper that ensures a depth texture of the right size:

```swift
    private func depthAttachment(width: Int, height: Int) -> MTLTexture {
        if let t = depthTexture, t.width == width, t.height == height { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        let t = device.makeTexture(descriptor: desc)!
        depthTexture = t
        return t
    }
```

In `encode(pass:size:time:)`, set the depth attachment on the pass before creating the encoder:

```swift
        let depth = depthAttachment(width: Int(size.x), height: Int(size.y))
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare
```

Update `encodeScene` to draw panels with depth-write, then edges with depth-test:

```swift
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
    }
```

`renderSnapshot`'s texture descriptor is color-only; the depth attachment is added inside `encode`, so no change there.

- [ ] **Step 4: Build + screenshot + verify (Checkpoint A)**

```bash
swift build 2>&1 | tail -5
.build/debug/RadialAfterburn --screenshot /tmp/nv-task6.png --frames 1 --width 1100 --height 760
```
Expected: **Read `/tmp/nv-task6.png`** — a glowing cyan wireframe tube (depth rings + radial lane lines) over the textured panels, receding to a vanishing point with violet fog at the far end. This is Checkpoint A: the 3D textured tunnel. Compare against the old flat look in the spec — it should clearly read as 3D depth, not concentric 2D polygons.

- [ ] **Step 5: Commit**

```bash
git add Sources/RadialAfterburn/TunnelMesh.swift Sources/RadialAfterburn/Renderer.swift
git commit -m "feat: neon tunnel edges with depth buffer and fog"
```

---

### Task 7: Sprite textures + billboards — player and enemies (Checkpoint B, part 1)

**Files:**
- Modify: `Sources/RadialAfterburn/TextureFactory.swift` (glow dot + per-entity sprites)
- Create: `Sources/RadialAfterburn/SpriteBatch.swift`
- Modify: `Sources/RadialAfterburn/Renderer.swift` (sprite textures, additive textured pipeline, draw player + enemies)

**Interfaces:**
- Consumes: `game.playerLane`, `game.enemies`, `TunnelGeometry`, additive `texturedPipeline`.
- Produces:
  - `TextureFactory.glowDot(device:)`, `TextureFactory.sprite(device:kind:)` returning `MTLTexture`; `TextureFactory.playerSprite(device:)`.
  - `enum SpriteBatch { static func billboard(center: SIMD3<Float>, size: Float, color: SIMD4<Float>) -> [TexVertex] }`
  - `Renderer.spriteVertices(...)` building per-entity quads.

- [ ] **Step 1: Add sprite textures to `TextureFactory.swift`**

```swift
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
                // upward arrow / claw
                let v = shapeArrow(px, py)
                let i = (y * size + x) * 4
                pixels[i] = toByte(v); pixels[i + 1] = toByte(v); pixels[i + 2] = toByte(v); pixels[i + 3] = toByte(v)
            }
        }
        return upload(device: device, pixels: pixels, size: size)
    }

    static func shapeDiamond(_ x: Float, _ y: Float, sharp: Float) -> Float { max(0, 1 - (abs(x) + abs(y)) * sharp) }
    static func shapeHex(_ x: Float, _ y: Float) -> Float {
        let q = max(abs(x) * 0.866 + abs(y) * 0.5, abs(y))
        return q < 0.8 ? 1 : 0
    }
    static func shapeWings(_ x: Float, _ y: Float) -> Float {
        let body = max(0, 1 - (abs(x) * 0.6 + abs(y) * 1.4))
        let wing = (abs(y) < 0.18 && abs(x) < 0.9) ? 1 : 0
        return max(body, Float(wing))
    }
    static func shapeArrow(_ x: Float, _ y: Float) -> Float {
        // triangle pointing up: inside if y in [-0.7,0.6] and |x| < (0.6 - y*0.5)
        let inside = (y > -0.7 && y < 0.6 && abs(x) < max(0, 0.6 - y * 0.5))
        return inside ? 1 : 0
    }
```

- [ ] **Step 2: Write `SpriteBatch.swift`**

```swift
import simd

enum SpriteBatch {
    /// A camera-facing quad (two triangles) at `center`, half-extent `size` in world units,
    /// in the world XY plane (camera looks down -Z, so screen-aligned).
    static func billboard(center: SIMD3<Float>, size: Float, color: SIMD4<Float>) -> [TexVertex] {
        let r = SIMD3<Float>(size, 0, 0)
        let up = SIMD3<Float>(0, size, 0)
        let a = TexVertex(position: center - r - up, uv: SIMD2(0, 1), color: color)
        let b = TexVertex(position: center + r - up, uv: SIMD2(1, 1), color: color)
        let c = TexVertex(position: center - r + up, uv: SIMD2(0, 0), color: color)
        let d = TexVertex(position: center + r + up, uv: SIMD2(1, 0), color: color)
        return [a, b, c, b, d, c]
    }
}
```

- [ ] **Step 3: Wire sprites into `Renderer`**

Add properties:

```swift
    private let additiveTexturedPipeline: MTLRenderPipelineState
    private let glowTexture: MTLTexture
    private let playerTexture: MTLTexture
    private var enemyTextures: [EnemyKind: MTLTexture] = [:]
```

In `init` after `panelTexture`:

```swift
        self.additiveTexturedPipeline = try Renderer.makeTexturedPipeline(device: device, library: library, format: colorPixelFormat, additive: true)
        self.glowTexture = TextureFactory.glowDot(device: device)
        self.playerTexture = TextureFactory.playerSprite(device: device)
        self.enemyTextures = [
            .spike: TextureFactory.sprite(device: device, kind: .spike),
            .flipper: TextureFactory.sprite(device: device, kind: .flipper),
            .tanker: TextureFactory.sprite(device: device, kind: .tanker),
        ]
```

Add a sprite-draw helper and call it at the end of `encodeScene` (after edges):

```swift
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
```

Append to `encodeScene` after the edges block:

```swift
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
                verts += SpriteBatch.billboard(center: center, size: 0.12, color: enemyColor(kind) * SIMD4(1, 1, 1, flicker))
            }
            drawSprites(verts, texture: tex, uniforms: &u, encoder: encoder)
        }
```

Add the color helper:

```swift
    private func enemyColor(_ kind: EnemyKind) -> SIMD4<Float> {
        switch kind {
        case .spike: SIMD4(1, 0.18, 0.55, 1)
        case .flipper: SIMD4(1, 0.72, 0.05, 1)
        case .tanker: SIMD4(0.2, 0.9, 1, 1)
        }
    }
```

- [ ] **Step 4: Build + screenshot + verify**

```bash
swift build 2>&1 | tail -5
.build/debug/RadialAfterburn --screenshot /tmp/nv-task7.png --frames 60 --width 1100 --height 760
```
Expected: **Read `/tmp/nv-task7.png`** — the textured tube plus a glowing cyan player ship at the near rim and several enemy sprites (pink diamonds / orange wings / blue hexes) at various depths, smaller the farther they are. Enemies behind the near wall geometry are correctly occluded.

- [ ] **Step 5: Commit**

```bash
git add Sources/RadialAfterburn/TextureFactory.swift Sources/RadialAfterburn/SpriteBatch.swift Sources/RadialAfterburn/Renderer.swift
git commit -m "feat: billboard sprites for player and enemies"
```

---

### Task 8: Shots + muzzle flashes (Checkpoint B complete)

**Files:**
- Modify: `Sources/RadialAfterburn/Renderer.swift` (draw shots + muzzle flashes as glow billboards in `encodeScene`)

**Interfaces:**
- Consumes: `game.shots`, `game.muzzleFlashes`, `glowTexture`, `additiveTexturedPipeline`.

- [ ] **Step 1: Append shot + muzzle drawing to `encodeScene`**

After the enemy loop in `encodeScene`:

```swift
        // Pass C (cont): shots as bright glow billboards
        var shotVerts: [TexVertex] = []
        for shot in game.shots {
            let center = TunnelGeometry.worldPoint(lane: shot.lane, depth: shot.depth, time: t, wave: game.wave, kick: game.tunnelKick)
            shotVerts += SpriteBatch.billboard(center: center, size: 0.05, color: SIMD4(1, 0.95, 0.25, 1))
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
```

- [ ] **Step 2: Build + screenshot + verify**

```bash
swift build 2>&1 | tail -5
.build/debug/RadialAfterburn --screenshot /tmp/nv-task8.png --frames 30 --width 1100 --height 760
```
Expected: **Read `/tmp/nv-task8.png`** — yellow shot glows traveling down the lanes from the player and a bright muzzle flash at the firing lane. (The scripted scene fires every 9 frames, so shots are in flight.) This completes Checkpoint B.

- [ ] **Step 3: Commit**

```bash
git add Sources/RadialAfterburn/Renderer.swift
git commit -m "feat: shots and muzzle flashes as 3D glow billboards"
```

---

### Task 9: 3D sparks + shockwaves (Checkpoint C)

**Files:**
- Modify: `Sources/RadialAfterburn/TextureFactory.swift` (ring glow)
- Modify: `Sources/RadialAfterburn/Renderer.swift` (draw sparks + shockwaves from the Task 3 3D data)

**Interfaces:**
- Consumes: `game.sparks` (`SIMD3` position), `game.shockwaves` (`SIMD3` position), `glowTexture`, new `ringTexture`.
- Produces: `TextureFactory.ringGlow(device:)`.

- [ ] **Step 1: Add ring glow texture to `TextureFactory.swift`**

```swift
    /// Annular glow for shockwaves.
    static func ringGlow(device: MTLDevice, size: Int = 128) -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let c = Float(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Float(x) - c) / c
                let dy = (Float(y) - c) / c
                let d = sqrt(dx * dx + dy * dy)
                let a = max(0, 1 - abs(d - 0.8) / 0.2)
                let i = (y * size + x) * 4
                pixels[i] = toByte(a); pixels[i + 1] = toByte(a); pixels[i + 2] = toByte(a); pixels[i + 3] = toByte(a)
            }
        }
        return upload(device: device, pixels: pixels, size: size)
    }
```

- [ ] **Step 2: Add the ring texture property + init in `Renderer`**

```swift
    private let ringTexture: MTLTexture
```
In `init` after `glowTexture`:
```swift
        self.ringTexture = TextureFactory.ringGlow(device: device)
```

- [ ] **Step 3: Draw sparks + shockwaves at the end of `encodeScene`**

```swift
        // Pass D: sparks (additive glow billboards in 3D)
        var sparkVerts: [TexVertex] = []
        for spark in game.sparks {
            let alpha = max(0, min(1, spark.life / spark.initialLife))
            sparkVerts += SpriteBatch.billboard(center: spark.position, size: 0.02 * spark.scale, color: spark.color * SIMD4(1, 1, 1, alpha))
        }
        drawSprites(sparkVerts, texture: glowTexture, uniforms: &u, encoder: encoder)

        // Shockwaves: expanding ring billboards
        var ringVerts: [TexVertex] = []
        for wave in game.shockwaves {
            let alpha = max(0, min(1, wave.life / wave.initialLife))
            ringVerts += SpriteBatch.billboard(center: wave.position, size: wave.radius, color: wave.color * SIMD4(1, 1, 1, alpha * 0.85))
        }
        drawSprites(ringVerts, texture: ringTexture, uniforms: &u, encoder: encoder)
```

- [ ] **Step 4: Build + screenshot + verify**

To capture an explosion, the scripted scene must land a hit. Increase frames so a shot connects:

```bash
swift build 2>&1 | tail -5
.build/debug/RadialAfterburn --screenshot /tmp/nv-task9.png --frames 150 --width 1100 --height 760
```
Expected: **Read `/tmp/nv-task9.png`** — at least one explosion: a burst of colored spark glows and an expanding ring at the enemy's depth in the tunnel (not full-screen 2D). If no explosion is visible, re-run with `--frames 220`. This is Checkpoint C.

- [ ] **Step 5: Commit**

```bash
git add Sources/RadialAfterburn/TextureFactory.swift Sources/RadialAfterburn/Renderer.swift
git commit -m "feat: 3D sparks and shockwave rings"
```

---

### Task 10: HDR scene target + bloom (Checkpoint D)

Switches the scene render from drawing directly to the final target to drawing into an `rgba16Float` HDR texture, then runs bright-pass → separable blur → composite into the final `bgra8Unorm` target. Both the live and snapshot paths benefit automatically.

**Files:**
- Modify: `Sources/RadialAfterburn/Shaders.swift` (fullscreen-triangle bloom functions)
- Modify: `Sources/RadialAfterburn/Renderer.swift` (HDR target + half-res bloom textures + post pipelines + new pass orchestration)

**Interfaces:**
- Produces: `Renderer` owns `sceneHDR` (rgba16Float), `bloomA`/`bloomB` (half-res rgba16Float), and pipelines `brightPipeline`, `blurPipeline`, `compositePipeline`.

- [ ] **Step 1: Add bloom shaders to `Shaders.swift`**

Insert into the MSL string (before closing `"""`):

```c
struct FSOut { float4 position [[position]]; float2 uv; };

vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    float2 uv[3]  = { float2(0, 1),  float2(2, 1),  float2(0, -1) };
    FSOut o;
    o.position = float4(pos[vid], 0, 1);
    o.uv = uv[vid];
    return o;
}

fragment float4 brightPassFragment(FSOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 c = scene.sample(s, in.uv);
    float luma = dot(c.rgb, float3(0.299, 0.587, 0.114));
    float t = 0.9;
    return luma > t ? c : float4(0, 0, 0, 1);
}

struct BlurParams { float2 direction; };

fragment float4 blurFragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant BlurParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear);
    float2 texSize = float2(src.get_width(), src.get_height());
    float2 off = p.direction / texSize;
    float w[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float3 sum = src.sample(s, in.uv).rgb * w[0];
    for (int i = 1; i < 5; i++) {
        sum += src.sample(s, in.uv + off * float(i)).rgb * w[i];
        sum += src.sample(s, in.uv - off * float(i)).rgb * w[i];
    }
    return float4(sum, 1);
}

fragment float4 compositeFragment(FSOut in [[stage_in]], texture2d<float> scene [[texture(0)]], texture2d<float> bloom [[texture(1)]]) {
    constexpr sampler s(filter::linear);
    float3 c = scene.sample(s, in.uv).rgb + bloom.sample(s, in.uv).rgb * 1.2;
    c = c / (c + 1.0); // Reinhard tonemap
    return float4(c, 1);
}
```

- [ ] **Step 2: Add HDR + bloom resources to `Renderer`**

Add properties:

```swift
    private var sceneHDR: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private let brightPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private static let hdrFormat: MTLPixelFormat = .rgba16Float
```

In `init` after the textured pipelines, build the post pipelines (a small helper):

```swift
        self.brightPipeline = try Renderer.makePostPipeline(device: device, library: library, fragment: "brightPassFragment", format: Renderer.hdrFormat)
        self.blurPipeline = try Renderer.makePostPipeline(device: device, library: library, fragment: "blurFragment", format: Renderer.hdrFormat)
        self.compositePipeline = try Renderer.makePostPipeline(device: device, library: library, fragment: "compositeFragment", format: colorPixelFormat)
```

```swift
    static func makePostPipeline(device: MTLDevice, library: MTLLibrary, fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: d)
    }
```

The scene pipelines now render into the HDR format. Change `makeLinePipeline` and `makeTexturedPipeline` calls in `init` to pass `Renderer.hdrFormat` instead of `colorPixelFormat`:

```swift
        self.linePipeline = try Renderer.makeLinePipeline(device: device, library: library, format: Renderer.hdrFormat)
        ...
        self.texturedPipeline = try Renderer.makeTexturedPipeline(device: device, library: library, format: Renderer.hdrFormat, additive: false)
        self.additiveTexturedPipeline = try Renderer.makeTexturedPipeline(device: device, library: library, format: Renderer.hdrFormat, additive: true)
```

- [ ] **Step 3: Add size-managed HDR/bloom textures**

```swift
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
```

- [ ] **Step 4: Rework `encode` to render scene → HDR, then bloom → final**

Replace `encode(pass:size:time:)` with an explicit multi-pass pipeline that takes the final color target and writes into it:

```swift
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
```

Update the two call sites:

In `draw(in:)`, replace the `encode(...)`/present block with:

```swift
        guard let drawable = view.currentDrawable, let size = optionalSize(view.drawableSize) else { return }
        if let cb = encodeFrame(finalTarget: drawable.texture, finalLoad: .dontCare, size: size, time: Float(now - startTime)) {
            cb.present(drawable)
            cb.commit()
        }
        onHUDUpdate?(game)
```

(Note `draw` no longer needs `view.currentRenderPassDescriptor`.)

In `renderSnapshot`, replace the pass/encode/commit with:

```swift
        let cb = encodeFrame(finalTarget: target, finalLoad: .clear, size: SIMD2(Float(width), Float(height)), time: Float(CACurrentMediaTime() - startTime))
        cb?.commit()
        cb?.waitUntilCompleted()
```

Delete the now-unused `encode(pass:size:time:)` method.

- [ ] **Step 5: Build + screenshot + verify (Checkpoint D)**

```bash
swift build 2>&1 | tail -5
.build/debug/RadialAfterburn --screenshot /tmp/nv-task10.png --frames 150 --width 1100 --height 760
```
Expected: **Read `/tmp/nv-task10.png`** — the full scene now blooms: neon edges, shots, and explosions have soft glowing halos; bright cores bleed light into surrounding pixels. The tonemap keeps highlights from clipping to flat white. This is Checkpoint D — the finished look.

- [ ] **Step 6: Commit**

```bash
git add Sources/RadialAfterburn/Shaders.swift Sources/RadialAfterburn/Renderer.swift
git commit -m "feat: HDR bloom post-processing pass"
```

---

### Task 11: Final verification, cleanup, and docs

**Files:**
- Modify: `README.md` (describe the 3D renderer + screenshot mode)
- Verify: full build, full test suite, live window sanity capture.

- [ ] **Step 1: Confirm no dead 2D code remains**

Run: `grep -n "horizontalScale\|screenPoint\|VectorVertex\|frameShakeOffset" Sources/RadialAfterburn/*.swift || echo "clean"`
Expected: `clean` (all replaced by the 3D path). If any remain, remove them.

- [ ] **Step 2: Run the full test suite**

Run: `swift test 2>&1 | tail -15`
Expected: PASS — `MatrixTests` (4), `TunnelGeometryTests` (4), `GameStateTests` (existing + `sparksAreInTunnelSpace`). No Metal constructed in tests.

- [ ] **Step 3: Update `README.md`**

In the Project Layout section, update the renderer line and add the screenshot note:

```markdown
- `Renderer.swift`: orchestrates the 3D render passes (textured tunnel, sprites,
  particles, bloom); decoupled from `MTKView`
- `TunnelGeometry.swift` / `Matrix.swift`: pure projection math (unit-tested)
- `TextureFactory.swift`: procedural textures generated in code
- `TunnelMesh.swift` / `SpriteBatch.swift`: tunnel and billboard geometry
- `Screenshot.swift`: headless `--screenshot` PNG renderer
```

And under Build and Run, add:

```markdown
### Headless screenshot

Render a frame to PNG without opening a window:

​```sh
swift run RadialAfterburn --screenshot out.png --frames 150 --width 1100 --height 760
​```
```

Change the opening description from "draws everything procedurally: the tunnel, ships, particles..." to note it is now a **3D perspective tunnel with procedural textures and bloom** — still 100% code-generated, no bundled art.

- [ ] **Step 4: Live-window sanity capture**

```bash
swift build 2>&1 | tail -3
zsh /private/tmp/claude-501/-Users-rick-git-github-rwaterman/165bc904-b7e7-453e-875f-5d57fd5abac3/scratchpad/capture.sh
```
Expected: a live `screencapture` PNG showing the 3D tunnel in the actual game window (confirms the live path matches the offscreen path). **Read the capture** to confirm.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: describe 3D renderer and screenshot mode"
```

- [ ] **Step 6: Finish the branch**

Use the `superpowers:finishing-a-development-branch` skill to decide how to integrate `feat/3d-textured-tunnel` (merge / PR / cleanup).

---

## Self-Review

**Spec coverage:**
- Projection & coordinate model → Tasks 1, 2 (Matrix, TunnelGeometry) ✓
- Pipelines & exact depth/blend order → Tasks 4 (line), 5 (textured), 6 (depth states + order), 7 (additive) ✓
- Geometry (panels, edges, billboards) → Tasks 5, 6, 7 ✓
- Procedural textures → Tasks 5, 7, 9 (panel, glow, sprites, ring) ✓
- GameState 3D particle change → Task 3 ✓
- File split → Tasks 1–4 create the files; Renderer slimmed/decoupled in Task 4 ✓
- Verification (offscreen `--screenshot`, staged checkpoints) → Task 4 builds it; Tasks 5–10 each gate on it ✓
- Bloom → Task 10 ✓
- Testing (pure-only, Metal out of CI) → Tasks 1–3 unit tests; Metal screenshot-gated ✓

**Placeholder scan:** No "TBD"/"add error handling"/"similar to". Each Metal step shows concrete code; each gate names the expected image content.

**Type consistency:** `TexVertex`/`LineVertex`/`FrameUniforms` defined in Task 4–5 and reused verbatim; `Uniforms` MSL struct matches `FrameUniforms` field order/types; `texturedVertex`/`texturedFragment`/`neonLine*`/`fullscreenVertex`/`brightPassFragment`/`blurFragment`/`compositeFragment` names match between `Shaders.swift` and the pipeline factories; `depthWriteState`/`depthTestState` consistent across Tasks 6–9; `Renderer.hdrFormat` switch in Task 10 updates all scene pipelines.

**Known risk to watch during execution:** Task 10 changes the scene pipelines' color format to `rgba16Float`; if any scene pipeline is still created with `colorPixelFormat` the composite will mismatch — Step 2 of Task 10 lists every call site to update.
