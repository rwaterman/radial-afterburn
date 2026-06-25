# Radial Afterburn

Radial Afterburn is a small macOS tube shooter written in Swift and Metal. It draws
everything procedurally: the tunnel, ships, particles, background, and HUD all
come from code rather than a game engine or bundled art.

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

- `GameState.swift`: rules, waves, scoring, collisions, and effects state
- `Renderer.swift`: procedural geometry and Metal draw calls
- `MetalGameView.swift`: input and frame timing
- `main.swift`: AppKit window, HUD, and application setup
- `Shaders.swift`: small runtime-compiled Metal shader
- `Tests/RadialAfterburnTests`: simulation tests

CI runs `swift build` and `swift test` on macOS.

## License

MIT. Radial Afterburn is an original project and is not affiliated with or endorsed
by Atari or the creators and rights holders of Tempest 2000.
