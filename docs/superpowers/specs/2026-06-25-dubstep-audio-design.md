# Neon Vortex — Synthesized Dubstep Audio

**Date:** 2026-06-25
**Status:** Approved design, pending implementation plan

## Goal

Add dubstep music and sound effects to Neon Vortex. All audio is **synthesized in
code** at runtime — no binary assets, no licensing risk, deterministic, CI-safe,
and matching the neon/vector aesthetic. Music **ramps intensity with waves**.
Players get separate music/SFX toggles, master volume, and a master mute.

## Constraints

- macOS 14+ target (`Package.swift`). CI runs `swift build` + `swift test` on a
  `macos-15` runner that has **no guaranteed audio device** — tests must never
  start `AVAudioEngine`.
- Audio is **strictly non-fatal**: if the engine fails to start, the game runs
  identically in silence. Nothing in `Renderer` / `MetalGameView` init may depend
  on audio succeeding.
- Swift 6 strict concurrency (swift-tools 6.2). The audio render callback runs on
  a real-time thread, not `MainActor`, and must touch zero `MainActor` state.
- **No AVFoundation import in `GameState`** — keeps the simulation and its tests
  hardware-free.

## Architecture

Three new files plus targeted edits. The design keeps a hard wall between
gameplay (pure, testable, deterministic) and audio (best-effort, real-time).

```
GameState ──(GameAudioEvent values)──▶ Renderer.draw ──▶ AudioEngine (@MainActor)
                                                              │  OSAllocatedUnfairLock
                                                              ▼  (single event queue)
                                                            Synth (RT thread) ──▶ AVAudioSourceNode ──▶ mainMixerNode
```

### New files

- `Sources/NeonVortex/GameAudioEvent.swift` — pure enum, no AVFoundation import.
- `Sources/NeonVortex/Synth.swift` — real-time DSP core. `final class`,
  `@unchecked Sendable`. Owns all oscillator / voice / filter state as scalars and
  **preallocated** fixed buffers. Its `render(into:)` is the only method the audio
  thread touches; it allocates nothing and triggers no ARC inside the sample loop.
- `Sources/NeonVortex/AudioEngine.swift` — `@MainActor` facade owning
  `AVAudioEngine` + one `AVAudioSourceNode` connected to `mainMixerNode`. Bridges
  main thread → `Synth` through a single `OSAllocatedUnfairLock`-guarded queue.

### Edited files

- `Package.swift` — add `.linkedFramework("AVFoundation")` to the executable target.
- `GameState.swift` — add the event buffer + drain (below).
- `Renderer.swift` — own an `AudioEngine`, forward drained events + intensity each frame.
- `MetalGameView.swift` — handle audio control keys.
- `main.swift` — extend the help bar to two lines for the new controls.

## The event seam

`GameState` accumulates events during the frame and the renderer drains them:

```swift
private(set) var audioEvents: [GameAudioEvent] = []
mutating func drainAudioEvents() -> [GameAudioEvent] { defer { audioEvents.removeAll(keepingCapacity: true) }; return audioEvents }
```

Events are appended at their natural sites:

- `fire()` → `.fire`
- `resolveCollisions()` → `.explosion(kind)` per kill; `.bonusLife` when score
  crosses a 25k threshold
- `resolveBreaches()` → `.breach`; `.gameOver` when `lives <= 0`
- wave-clear branch in `update()` → `.waveClear`
- `start()` → resets the buffer, appends `.start`

```swift
enum GameAudioEvent: Equatable {
    case start
    case fire
    case explosion(EnemyKind)
    case breach
    case waveClear
    case gameOver
    case bonusLife
}
```

`start()` must clear `audioEvents` alongside the other transient resets so a fresh
game doesn't replay stale events.

## Thread boundary

Both discrete events **and** the continuous intensity parameter travel through the
**same** lock-guarded queue — no separate shared mutable floats (those would be a
Swift 6 data race and buy nothing, since per-buffer intensity updates are
inaudibly different from per-sample).

- `AudioEngine` exposes `@MainActor` methods: `post(_ events:)`,
  `setIntensity(wave:combo:comboPulse:phase:)`, `toggleMusic()`, `toggleSFX()`,
  `nudgeVolume(_:)`, `toggleMute()`.
- Each pushes a command onto an `OSAllocatedUnfairLock`-protected ring/array.
- The `AVAudioSourceNode` render closure is `nonisolated`, captures `Synth` once,
  locks **only** at the top to drain commands into `Synth` state, unlocks, then
  runs the sample loop. Lock hold time is nanoseconds; SPSC contention is
  negligible (≈120 Hz producer, one consumer).
- The sample loop writes directly into the `AudioBufferList` channels via
  `UnsafeMutableAudioBufferListPointer`. Use
  `AVAudioFormat(standardFormatWithSampleRate:channels:)` (deinterleaved float32),
  and **read channel count from the buffer list** rather than assuming stereo.

## Music — intensity ramp

Sample-clocked step sequencer, ~140 BPM, half-time dubstep feel. A global sample
counter drives musical time; pattern arrays gate the layers.

Layers:

- **Sub kick** — sine with a fast downward pitch envelope + click.
- **Snare** — noise burst + tone on the backbeat.
- **Wobble bass** — saw oscillator through a resonant lowpass whose cutoff is
  modulated by a beat-synced LFO (the signature dubstep wobble).
- **Hats / lead arp** — gate in only at higher intensity.

A smoothed `intensity ∈ [0,1]`, derived from `wave` (primary) and `combo`
(secondary), drives LFO rate, filter resonance, layer gating, and music gain.
Title / pause / game-over duck `intensity` toward a sparse idle loop. Music is
silenced (gain 0) when the music toggle is off or master mute is on, but the
sequencer keeps running so toggling back on stays in time.

## SFX

Synthesized one-shots from a fixed voice pool (≈16 voices) so clustered hits stay
polyphonic:

- `fire` — short, **quiet** bright zap (rapid fire must not fatigue).
- `explosion(kind)` — size scales by kind: spike small, flipper mid,
  **tanker = big sub boom**. **Pitch rises as combo climbs**, folding combo
  feedback into the kill sound (no separate combo SFX).
- `breach` — downward detuned sweep + noise.
- `waveClear` — rising riser / chord.
- `bonusLife` — bright ascending blip.
- `gameOver` — low detuned fall.
- `start` — short UI blip.

SFX are silenced when the SFX toggle is off or master mute is on.

## Controls

Resolving the `M` double-booking explicitly:

| Key | Action |
|-----|--------|
| `M` | Music on/off |
| `N` | SFX on/off |
| `[` | Master volume down |
| `]` | Master volume up |
| `\` | Master mute (panic toggle) |

The help bar in `main.swift` becomes two lines to fit movement/fire/pause plus the
audio controls. Audio control keys are handled in `MetalGameView.keyDown` and call
through `renderer?.audio`; they do **not** route through `GameState`.

## Failure handling

`AudioEngine` construction and `engine.start()` are wrapped in `do/catch`. On
failure it logs once and the facade becomes a no-op (all `post`/`toggle`/`nudge`
calls return harmlessly). `Renderer` holds the `AudioEngine` but never depends on
its success; the game loop, rendering, and input are unaffected.

## Testing

All tests run headless on CI — none constructs `AVAudioEngine`.

**`GameStateAudioEventsTests`** (Swift Testing; reuses the existing
`destroyFirstEnemy` / `movePlayer` helper pattern from `GameStateTests`):

- `fire()` emits `.fire`.
- Destroying each `EnemyKind` emits the matching `.explosion(kind)`.
- A breach emits `.breach`; at `lives == 0` it also emits `.gameOver`.
- Crossing the 25k score threshold emits `.bonusLife`.
- `start()` emits `.start` and clears any prior events.
- `drainAudioEvents()` empties the buffer (second drain is empty).

**`SynthTests`** — calls `Synth.render` directly on a plain Swift float buffer (no
`AVAudioEngine`, no device):

- Rendering N frames produces only finite samples (no NaN/Inf).
- With master mute set, all output samples are exactly 0.
- Output stays within `[-1, 1]` (no hard clipping past full scale).

## Out of scope (YAGNI)

- Loadable / user-supplied audio files.
- Persisted audio settings between launches.
- Spatialization / per-lane panning of SFX.
- On-screen volume UI (keyboard only).
```

