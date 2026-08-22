# Radial Afterburn

Radial Afterburn is a small macOS tube shooter written in Swift and Metal. It
renders a 3D perspective tunnel with texture-mapped walls, billboard sprites,
distance fog, a glowing core, a streaming starfield, per-wave color palettes,
and a bloom post-process pass — all generated procedurally in code, with no
game engine or bundled art. The textures, geometry, ships, particles, HUD, and
even the sound effects all come from code. Player and enemy lane changes slide
rather than snap, the camera leans and lunges with the action, and heavy hits
briefly freeze the world for impact.

The game is built around a 16-lane tunnel. Move around the rim, shoot down the
lanes, and clear each wave before enemies break through to the edge.

## Requirements

- macOS 14 or later
- Xcode 16 or later, including the command line tools
- Apple Silicon or Intel Mac with Metal support

## Build and Run

```sh
swift build
swift run RadialAfterburn
```

Or open `Package.swift` in Xcode and run the `RadialAfterburn` scheme.

### Headless screenshot

Render a single frame to a PNG without opening a window (no Screen Recording
permission required — it renders into an offscreen texture):

```sh
swift run RadialAfterburn --screenshot out.png --frames 500 --width 1100 --height 760
```

The scene is deterministic (seeded), so a given frame count always renders the
same image.

## Test

```sh
swift test
```

Tests cover the game-state logic separately from Metal rendering.

## Controls

| Key | Action |
| --- | --- |
| Left / A | Move counter-clockwise |
| Right / D | Move clockwise |
| Space | Fire |
| P | Pause |
| Return | Start or restart |
| Escape | Quit |

## Gameplay

You start with three lives. Destroy enemies to score points and build a combo
multiplier; letting one reach the rim costs a life and resets the combo. Clearing
a wave advances the game and increases the pace. Every 25,000 points earns a
bonus life.

Enemy types:

- `Spike`: basic fast target.
- `Flipper`: changes lanes as it approaches.
- `Tanker`: slower target that splits into spikes when destroyed.

## Project Layout

- `GameState.swift`: rules, waves, scoring, collisions, smooth-motion state, hit-stop, and per-frame audio events
- `GameAudio.swift`: procedurally synthesized SFX and ambient drone (AVFoundation, no audio files)
- `Palette.swift`: per-wave neon color palettes (HSV rotation, wave 1 anchored to cyan/violet)
- `TunnelGeometry.swift` / `Matrix.swift`: pure projection math (unit-tested, no Metal)
- `Renderer.swift`: orchestrates the 3D render passes (textured tunnel, sprites, particles, bloom); decoupled from `MTKView`
- `TextureFactory.swift`: procedural textures generated in code
- `TunnelMesh.swift` / `SpriteBatch.swift`: tunnel wall/edge and billboard geometry
- `Shaders.swift`: runtime-compiled Metal shaders (textured-lit, neon line, bloom)
- `Screenshot.swift`: headless `--screenshot` PNG renderer
- `MetalGameView.swift`: input and frame timing
- `main.swift`: AppKit window, HUD, and application setup
- `Tests/RadialAfterburnTests`: simulation and projection-math tests

CI runs `swift build` and `swift test` on macOS.

## License

MIT. Radial Afterburn is an original project and is not affiliated with or endorsed
by Atari or the creators and rights holders of Tempest 2000.
