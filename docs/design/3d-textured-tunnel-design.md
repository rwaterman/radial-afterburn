# Radial Afterburn — 3D Textured Tunnel + Bloom

**Date:** 2026-06-25
**Status:** Approved design, pending implementation plan

## Goal

Replace the flat 2D vector renderer with a **real 3D perspective tunnel**:
texture-mapped wall panels, camera-facing textured sprites for ships and
particles, distance fog for depth, and a **bloom post-process pass** for the
neon glow. All textures are **generated procedurally in code** — no bundled art,
preserving the project's stated identity.

The bet that makes this affordable: gameplay is already expressed in abstract
`lane` / `depth` coordinates, not screen space. So this is a **renderer rewrite
plus one contained `GameState` change**. Collisions, scoring, waves, spawning,
and input are untouched.

## Constraints

- macOS 14+ target (`Package.swift`). CI runs `swift build` + `swift test` on a
  runner with **no guaranteed GPU** — tests must never construct a Metal device,
  a pipeline, or the `Renderer`. The README already promises "tests cover the
  game-state logic separately from Metal rendering"; keep that wall.
- The new 3D math (`(lane,depth)` → world point, perspective / lookAt matrices)
  must live in **pure `simd`-only files** so it is unit-tested headless and is
  the single source of truth shared by `GameState` and the renderer.
- **No bundled binary assets.** All textures are filled in code at startup.
- Swift 6 strict concurrency (swift-tools 6.2). `Renderer` and Metal types stay
  `@MainActor`, as today. `GameState` imports only `Foundation` / `simd`.
- The existing `GameStateTests` must stay green. They assert `sparks` /
  `shockwaves` only for emptiness, never their internals — so widening particle
  positions to 3D is safe.

## Verification — the primary risk

This is a from-scratch render system whose entire purpose is visual, judged on a
runner with no GPU and from a compile that proves nothing. The verification path
is therefore part of the design, not an afterthought.

- **Empirically established:** `screencapture` of the live window works on the
  dev machine (Screen Recording granted), but it grabs the whole desktop.
- **Primary dev-loop check:** an **offscreen screenshot mode** —
  `RadialAfterburn --screenshot <path> [--frames N] [--width W --height H]
  [--seed S]`. It builds a Metal device with **no window**, runs a deterministic
  scripted game sequence (seeded RNG already exists), renders the final frame
  into an offscreen `bgra8Unorm` texture, reads it back, and writes a PNG via
  ImageIO. Permission-free, deterministic, exact framebuffer, CI-skippable.
  Decoupling `Renderer` from `MTKView` (see Architecture) is what enables this.
- **Staged checkpoints.** Each milestone produces a screenshot reviewed before
  the next is built — a black screen 2000 lines in is the failure mode to avoid:
  1. Textured 3D tunnel alone: wall panels + neon edges + perspective + depth.
  2. + player and enemy sprites (correct lane / depth / perspective scale).
  3. + shots, particles, shockwaves in 3D.
  4. + bloom post pass.
- **Secondary check:** live `screencapture` of the running window for a real-
  window sanity pass at the end of a milestone.

## Architecture

```
GameState (lane/depth, pure)
   │  worldPoint(lane,depth) via ──┐
   ▼                               │
TunnelGeometry (pure simd) ◀───────┤ single source of truth
Matrix (pure simd)                 │
   │                               │
   ▼                               ▼
TextureFactory → MTLTextures   TunnelMesh / SpriteBatch (build vertex buffers)
                       \           /
                        ▼         ▼
                       Renderer (@MainActor, MTKView-decoupled)
                        │  scene pass → sceneHDR(rgba16F)+depth
                        │  bloom passes → drawable(bgra8)
                        ▼
              MTKView drawable  ──or──  offscreen texture → PNG
```

### New files

- `Sources/RadialAfterburn/Matrix.swift` — pure `simd`. `perspective(fovyRadians:
  aspect:near:far:)`, `lookAt(eye:center:up:)`, `translation`, `scale`, and a
  small camera-shake jitter. Just those helpers (Apple's `simd` ships no
  `perspective`/`lookAt`). Unit-tested.
- `Sources/RadialAfterburn/TunnelGeometry.swift` — pure `simd`. The tunnel model:
  `worldPoint(lane:depth:time:wave:kick:combo:) -> SIMD3<Float>` (ring of
  `laneCount` vertices at constant world radius, extruded along −Z from the near
  rim at `depth 0` to the far vanishing point at `depth 1`; folds in the existing
  time warp and per-wave center drift), ring radius, and the billboard basis
  vectors. Shared by `GameState` (spark origins) and the renderer. Unit-tested.
- `Sources/RadialAfterburn/TextureFactory.swift` — `@MainActor`. Builds mipmapped
  `MTLTexture`s by filling `UInt8` RGBA buffers in code: an emissive neon panel
  tile (glowing grid seams + value noise), a radial-glow dot (particles / shots /
  muzzle), an annular ring glow (shockwaves), and one SDF-ish sprite per entity
  (spike, flipper, tanker, player).
- `Sources/RadialAfterburn/TunnelMesh.swift` — builds the tunnel wall-panel vertex
  buffer (textured quad strips) and the neon-edge line buffer from
  `TunnelGeometry`.
- `Sources/RadialAfterburn/SpriteBatch.swift` — builds camera-facing billboard quads
  (`float3 pos / float2 uv / float4 color`) for player, enemies, shots, sparks,
  shockwaves, and muzzle flashes, positioned in 3D and perspective-scaled.
- `Sources/RadialAfterburn/Screenshot.swift` — the offscreen `--screenshot` batch
  path (no `NSApplication`): device, `Renderer`, scripted sim, readback, PNG.

### Edited files

- `Sources/RadialAfterburn/Renderer.swift` — slimmed to an orchestrator, **decoupled
  from `MTKView`**: owns device, pipelines, depth-stencil states, textures, and
  the offscreen targets; renders a scene into `sceneHDR` + depth, then runs the
  bloom chain into a supplied final color target (the view's drawable, or an
  offscreen texture for screenshots). Recreates size-dependent targets on resize.
- `Sources/RadialAfterburn/Shaders.swift` — grows from one trivial pass-through to:
  `texturedLit` (vertex/fragment, samples bound texture × color + fog),
  `neonLine` (vertex/fragment, MVP + fog), and the bloom trio (`brightPass`,
  separable `blur`, `composite`) drawn as a fullscreen triangle. Plus a shared
  `Uniforms` struct (`viewProjection`, `time`, fog params).
- `Sources/RadialAfterburn/GameState.swift` — `Spark.position` / `Spark.velocity` and
  `Shockwave.position` become `SIMD3<Float>`; `emitExplosion` / wave-clear
  compute 3D origins via `TunnelGeometry`. No rule changes.
- `Sources/RadialAfterburn/MetalGameView.swift` — minimal change. `Renderer` owns the
  scene and depth targets, not the view, so the view needs no depth attachment
  and `framebufferOnly` stays `true` (the drawable is only the composite pass's
  render target; readback for screenshots comes from a separate offscreen
  texture). It continues to hand `Renderer` the drawable size and the drawable's
  render pass for the final composite.
- `Sources/RadialAfterburn/main.swift` — parse `--screenshot` and friends before
  `app.run()`; route to the batch path when present. HUD unchanged.

## Coordinate model & projection

`TunnelGeometry` defines the tube in world space: a ring of `laneCount` vertices
at angle `lane/laneCount · 2π − π/2`, **constant** world radius `R0`, extruded
along −Z so `depth 0` sits at the near rim (`zNear`, in front of the camera) and
`depth 1` at the far end (`zFar`). Radius is constant on purpose — perspective
foreshortening, not a hand-tuned `radius·(1−depth)` shrink, makes far rings
smaller. This is the whole point of going 3D and it deletes today's
`horizontalScale` / `screenPoint` hack.

The camera sits at the origin via `lookAt` down −Z; `perspective(fovy≈60°,
aspect = width/height, near, far)` handles aspect and foreshortening. The
per-wave center drift becomes a small depth-scaled XY offset; `screenShake`
becomes camera jitter applied to the view matrix. The existing radial/twist time
warp perturbs ring vertices in model space so panels and edges warp together.

Billboards: because the camera looks down −Z, screen-aligned sprites use world
right `(1,0,0)` and up `(0,1,0)`. A sprite at world point `P` with world size `s`
spans `P ± right·s ± up·s`; perspective shrinks distant ones, so enemies grow as
they approach — matching the gameplay.

## Pipelines, passes & exact depth/blend order

The likeliest "compiles but looks broken" failure is wrong depth/blend state, so
it is pinned exactly. A `Depth32Float` attachment and depth-stencil states are
added. Two scene pipelines plus the bloom chain.

Scene render (into `sceneHDR` = `rgba16Float`, + depth). HDR float target lets
additive output exceed 1.0 so the bright-pass has something to bloom. Clear color
to the dark background; clear depth to 1.0. Then, in order:

1. **Tunnel wall panels** — `texturedLit`, alpha blend, **depth-write ON**,
   compare `.less`. Establishes the depth buffer.
2. **Neon edges** (lane lines + rings) — `neonLine`, additive
   (`srcAlpha`/`one`), **depth-write OFF**, compare `.lessEqual` (sit on panels
   without being culled by z-fighting).
3. **Sprites** (player, enemies, shots) — `texturedLit` billboards, additive,
   **depth-write OFF**, compare `.less` (occluded by nearer walls). Additive is
   order-independent and these don't write depth, so no sprite sort is needed.
4. **Particles / shockwaves / muzzle flashes** — additive glow billboards,
   **depth-write OFF**, compare `.less` (a spark behind a wall is correctly
   hidden).

Bloom chain (fullscreen triangle via `vertex_id`, no vertex buffer), half-res
working textures:

5. **Bright pass** — sample `sceneHDR`, output `max(0, luma − threshold)` into a
   half-res bright texture.
6. **Blur** — separable Gaussian, horizontal then vertical, 1–2 iterations at
   half-res.
7. **Composite** — `sceneHDR + bloom · strength` (a fixed bloom-strength
   constant) into the final `bgra8Unorm` target (drawable or screenshot
   texture), with a simple clamp/tonemap.

HUD text stays an AppKit overlay on top of the `MTKView`, unchanged.

## Procedural textures

Filled in code into `UInt8` RGBA buffers, uploaded via `replaceRegion`, mipmaps
generated with a blit encoder, sampled with linear + mip filtering:

- **Panel tile** — emissive neon grid: glowing seams over subtle value noise,
  cyan/blue. Repeat addressing; UV.y scrolls with `time` for a speed cue.
- **Glow dot** — radial Gaussian falloff (particles, shots, muzzle).
- **Ring glow** — annular falloff (shockwaves).
- **Entity sprites** — one small SDF-ish texture each: spike (sharp diamond),
  flipper (winged), tanker (armored hex), player (arrow/ship). Colors come from
  the per-vertex `color`, so textures are luminance/shape masks reused by kind.

Distance fog in the fragment shaders (factor from clip-space `w` / view depth)
fades geometry toward the far end and supplies the "lit" depth read. No PBR,
normal maps, or real lights (YAGNI).

## `GameState` change (only gameplay-file edit)

`Spark` gains `SIMD3` `position` / `velocity`; `Shockwave` gains `SIMD3`
`position`. `emitExplosion` derives the 3D origin from
`TunnelGeometry.worldPoint(lane:depth:)`; sparks fly in 3D (random direction in
the billboard plane plus slight depth spread); the wave-clear shockwave spawns at
the tunnel center near mid-depth. Decay/expiry logic is unchanged. Because tests
check these collections only for emptiness, they remain green; the simulation
stays hardware-free (`TunnelGeometry` imports only `simd`).

## Testing

All Metal stays out of `swift test`.

- **`TunnelGeometryTests`** — `worldPoint(depth:1).z < worldPoint(depth:0).z`
  (farther into the screen); world radius constant across depth; lane wrap
  (`lane == laneCount` ≈ `lane == 0`); angular symmetry.
- **`MatrixTests`** — `perspective` foreshortens (same world X projects to a
  smaller clip X at greater depth); `lookAt` yields an orthonormal basis;
  identity and composition sanity.
- **`GameStateTests`** — unchanged, stay green. Optionally add one assertion that
  a kill's spark origin equals the enemy's `worldPoint`.
- **Renderer / Metal** — not unit-tested (no GPU on CI); exercised by the
  `--screenshot` mode locally at each checkpoint.

## Out of scope (YAGNI)

- PBR, normal maps, shadow mapping, real light sources.
- Loadable / user-supplied textures or 3D model assets.
- True 3D ship meshes (billboards suffice).
- MSAA / anti-aliasing beyond what bloom softens.
- Any gameplay, input, scoring, or wave change beyond widening particle
  positions to 3D.
