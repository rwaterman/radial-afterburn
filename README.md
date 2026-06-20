# Neon Vortex

A fast, original tube-shooter inspired by the vector arcade games of the early
1990s. It is written in Swift and rendered directly with Metal.

No third-party game engine, textures, models, or copyrighted game assets are
used. Every visual is generated procedurally.

## Requirements

- macOS 14 or later
- Xcode 16 or later with the Command Line Tools
- Apple Silicon or Intel Mac with Metal support

## Run

```sh
swift run NeonVortex
```

Or open `Package.swift` in Xcode and run the `NeonVortex` scheme.

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

Move around the rim, fire down the lanes, and destroy enemies before they
reach the edge. Clear each wave to increase the speed and enemy variety. You
begin with three lives and gain a bonus life every 25,000 points.

## Architecture

- `GameState.swift` contains deterministic game rules independent of graphics.
- `Renderer.swift` translates the game state into procedural vector geometry.
- `MetalGameView.swift` owns keyboard input and the Metal frame loop.
- `Shaders.swift` contains the small runtime-compiled Metal shader library.

## License

MIT. “Neon Vortex” is an original project and is not affiliated with or
endorsed by Atari or the creators and rights holders of Tempest 2000.
