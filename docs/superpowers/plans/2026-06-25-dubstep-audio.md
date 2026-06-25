# Radial Afterburn Dubstep Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add fully synthesized dubstep music (intensity ramps with waves) and synthesized sound effects to the Radial Afterburn tube shooter, with player controls for music/SFX/volume/mute.

**Architecture:** `GameState` accumulates discrete `GameAudioEvent` values during simulation; `Renderer` drains them each frame and forwards them plus a continuous intensity snapshot to an `@MainActor` `AudioEngine` facade. The facade owns one `AVAudioSourceNode` whose real-time render block drives a `Synth` DSP core (sequenced wobble bass + drums + SFX voice pool). Main thread and audio thread communicate through a single `OSAllocatedUnfairLock`-guarded command queue. `GameState` stays pure (no AVFoundation), so the simulation and DSP are unit-testable with no audio hardware.

**Tech Stack:** Swift 6.2, AVFoundation (`AVAudioEngine` / `AVAudioSourceNode`), `os.OSAllocatedUnfairLock`, Swift Testing.

## Global Constraints

- Platform floor: macOS 14 (`Package.swift`). `OSAllocatedUnfairLock` (macOS 13+) and `AVAudioSourceNode` (macOS 10.15+) are within this floor.
- CI runs `swift build` + `swift test` on a `macos-15` runner with no guaranteed audio device. **No test may construct `AVAudioEngine` / `AudioEngine`.** Test only `GameState` events and `Synth.render`.
- Audio is **non-fatal**: `AudioEngine` catches all setup/start failures and degrades to a silent no-op. Nothing in `Renderer` / `MetalGameView` init may depend on audio succeeding.
- **No `import AVFoundation` in `GameState.swift`** — keeps the simulation hardware-free and CI-safe.
- The audio render block is `nonisolated`, touches zero `MainActor` state, allocates nothing in the per-sample loop, and only locks briefly at the top to drain commands.
- Test framework is Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`) — match `Tests/RadialAfterburnTests/GameStateTests.swift`.

---

### Task 1: Game audio events in GameState

Adds the pure event seam: an enum, an accumulation buffer on `GameState`, a drain method, and emission at every gameplay site. No audio code. Fully unit-tested.

**Files:**
- Create: `Sources/RadialAfterburn/GameAudioEvent.swift`
- Modify: `Sources/RadialAfterburn/GameState.swift`
- Test: `Tests/RadialAfterburnTests/GameStateAudioEventsTests.swift`

**Interfaces:**
- Produces:
  - `enum GameAudioEvent: Equatable, Sendable` with cases `.start`, `.fire`, `.explosion(EnemyKind)`, `.breach`, `.waveClear`, `.gameOver`, `.bonusLife`
  - `GameState.audioEvents: [GameAudioEvent]` (`private(set)`)
  - `mutating func GameState.drainAudioEvents() -> [GameAudioEvent]` — returns accumulated events and clears the buffer
- Consumes: existing `GameState`, `EnemyKind` (same module).

- [ ] **Step 1: Write the failing tests**

Create `Tests/RadialAfterburnTests/GameStateAudioEventsTests.swift`:

```swift
import Testing
@testable import RadialAfterburn

@Suite("Game audio events")
struct GameStateAudioEventsTests {
    @Test("Starting emits a start event and clears prior events")
    func startEmitsStartAndClears() {
        var game = GameState()
        game.start()
        game.fire()
        game.start()

        let events = game.drainAudioEvents()
        #expect(events == [.start])
    }

    @Test("Draining clears the buffer")
    func drainClearsBuffer() {
        var game = GameState()
        game.start()
        _ = game.drainAudioEvents()

        #expect(game.drainAudioEvents().isEmpty)
    }

    @Test("Firing emits a fire event")
    func firingEmitsFire() {
        var game = GameState()
        game.start()
        _ = game.drainAudioEvents()
        game.fire()

        #expect(game.drainAudioEvents().contains(.fire))
    }

    @Test("Destroying a wave-1 enemy emits a spike explosion")
    func killEmitsSpikeExplosion() {
        var game = GameState()
        let kind = destroyFirstEnemy(in: &game)

        #expect(kind == .spike)
        #expect(game.drainAudioEvents().contains(.explosion(.spike)))
    }

    @Test("A breach emits a breach event")
    func breachEmitsBreach() {
        var game = GameState()
        game.start()

        var sawBreach = false
        for _ in 0..<2000 {
            game.update(deltaTime: 0.05)
            if game.drainAudioEvents().contains(.breach) {
                sawBreach = true
                break
            }
        }

        #expect(sawBreach)
    }

    @Test("Losing all lives emits a game over event")
    func deathEmitsGameOver() {
        var game = GameState()
        game.start()

        var sawGameOver = false
        for _ in 0..<4000 {
            game.update(deltaTime: 0.05)
            if game.drainAudioEvents().contains(.gameOver) {
                sawGameOver = true
                break
            }
            if game.phase == .gameOver { break }
        }

        #expect(sawGameOver)
        #expect(game.phase == .gameOver)
    }

    @discardableResult
    private func destroyFirstEnemy(in game: inout GameState) -> EnemyKind {
        game.start()
        while game.enemies.isEmpty {
            game.update(deltaTime: 0.05)
        }

        let target = game.enemies[0]
        movePlayer(to: target.lane, in: &game)
        _ = game.drainAudioEvents()
        game.fire()

        for _ in 0..<80 where game.score == 0 {
            game.update(deltaTime: 0.05)
        }
        return target.kind
    }

    private func movePlayer(to lane: Int, in game: inout GameState) {
        while game.playerLane != lane {
            let clockwise = (lane - game.playerLane + GameState.laneCount) % GameState.laneCount
            let counterClockwise = (game.playerLane - lane + GameState.laneCount) % GameState.laneCount
            game.move(clockwise <= counterClockwise ? 1 : -1)
            game.update(deltaTime: 0.08)
        }
    }
}
```

- [ ] **Step 2: Add the enum and a stubbed (non-emitting) seam so tests compile and fail on assertions**

Create `Sources/RadialAfterburn/GameAudioEvent.swift`:

```swift
enum GameAudioEvent: Equatable, Sendable {
    case start
    case fire
    case explosion(EnemyKind)
    case breach
    case waveClear
    case gameOver
    case bonusLife
}
```

In `Sources/RadialAfterburn/GameState.swift`, add the property after the `waveBanner` declaration (currently line 93, inside the `struct GameState` stored-property block):

```swift
    private(set) var waveBanner: Float = 0
    private(set) var audioEvents: [GameAudioEvent] = []
```

Add the drain method next to the other `mutating` methods (e.g. right after `togglePause()`):

```swift
    mutating func drainAudioEvents() -> [GameAudioEvent] {
        defer { audioEvents.removeAll(keepingCapacity: true) }
        return audioEvents
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter GameStateAudioEventsTests`
Expected: builds, but assertions FAIL (e.g. `firingEmitsFire`, `startEmitsStartAndClears` fail because no events are emitted yet).

- [ ] **Step 4: Wire emissions at every gameplay site**

In `GameState.start()`, clear the buffer alongside the other resets and append `.start` at the end of the method:

```swift
        waveBanner = 0
        audioEvents.removeAll(keepingCapacity: true)
        nextBonusLife = 25_000
        random = SeededRandom(seed: 0x4e454f4e)
        beginWave()
        audioEvents.append(.start)
    }
```

In `GameState.fire()`, append `.fire` after the cooldown is set:

```swift
        shotCooldown = max(0.075, 0.15 - Float(wave) * 0.004)
        audioEvents.append(.fire)
    }
```

In `GameState.update()`, append `.waveClear` inside the wave-clear branch (alongside the existing `waveBanner = 1.25` / `emitShockwave` block, before `beginWave()`):

```swift
            waveBanner = 1.25
            audioEvents.append(.waveClear)
            emitShockwave(
```

In `GameState.resolveCollisions()`, append `.explosion(enemy.kind)` right after the existing `emitExplosion(...)` call inside the per-shot loop:

```swift
            emitExplosion(lane: enemy.lane, depth: enemy.depth, kind: enemy.kind)
            audioEvents.append(.explosion(enemy.kind))
```

And append `.bonusLife` inside the bonus-life `while` loop in the same method:

```swift
        while score >= nextBonusLife {
            lives += 1
            nextBonusLife += 25_000
            audioEvents.append(.bonusLife)
        }
```

In `GameState.resolveBreaches()`, append `.breach` once a breach is being processed, and `.gameOver` when lives run out. Replace the tail of the method:

```swift
        combo = 1
        lives -= 1
        flash = 1
        screenShake = 1
        tunnelKick = 1
        audioEvents.append(.breach)

        if lives <= 0 {
            phase = .gameOver
            audioEvents.append(.gameOver)
        } else {
            playerLane = wrappedLane(playerLane + Self.laneCount / 2)
            spawnTimer = max(spawnTimer, 1)
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter GameStateAudioEventsTests`
Expected: PASS (all 6 tests). Also run the full suite to confirm no regressions:
Run: `swift test`
Expected: PASS (existing `GameStateTests` still green).

- [ ] **Step 6: Commit**

```bash
git add Sources/RadialAfterburn/GameAudioEvent.swift Sources/RadialAfterburn/GameState.swift Tests/RadialAfterburnTests/GameStateAudioEventsTests.swift
git commit -m "feat: emit audio events from game state"
```

---

### Task 2: Synth DSP core

The real-time synthesizer: a sample-clocked dubstep sequencer (kick, snare, hats, wobble bass), an intensity parameter, and an SFX voice pool. Operates on a plain mono `Float` buffer so it is testable with no audio hardware. A `tanh` soft-clip guarantees output stays within `[-1, 1]`.

**Files:**
- Create: `Sources/RadialAfterburn/Synth.swift`
- Test: `Tests/RadialAfterburnTests/SynthTests.swift`

**Interfaces:**
- Consumes: `GameAudioEvent`, `EnemyKind` (Task 1 / existing).
- Produces:
  - `final class Synth: @unchecked Sendable`
  - `init(sampleRate: Float)`
  - `enum Synth.Command: Sendable` with cases `.event(GameAudioEvent)`, `.intensity(Float)`, `.music(Bool)`, `.sfx(Bool)`, `.masterVolume(Float)`, `.mute(Bool)`
  - `func push(_ command: Synth.Command)` — thread-safe, called from the main thread
  - `func render(into buffer: UnsafeMutableBufferPointer<Float>)` — fills `buffer.count` mono samples; called from the audio thread

- [ ] **Step 1: Write the failing tests**

Create `Tests/RadialAfterburnTests/SynthTests.swift`:

```swift
import Testing
@testable import RadialAfterburn

@Suite("Synth")
struct SynthTests {
    private func renderBuffer(_ synth: Synth, frames: Int = 4800) -> [Float] {
        var buffer = [Float](repeating: 0, count: frames)
        buffer.withUnsafeMutableBufferPointer { synth.render(into: $0) }
        return buffer
    }

    @Test("Music render produces only finite samples")
    func finiteSamples() {
        let synth = Synth(sampleRate: 48_000)
        synth.push(.intensity(1))
        let buffer = renderBuffer(synth)

        #expect(buffer.allSatisfy { $0.isFinite })
    }

    @Test("Output stays within full scale")
    func boundedSamples() {
        let synth = Synth(sampleRate: 48_000)
        synth.push(.intensity(1))
        synth.push(.event(.explosion(.tanker)))
        let buffer = renderBuffer(synth)

        #expect(buffer.allSatisfy { abs($0) <= 1 })
    }

    @Test("Muting silences all output")
    func muteSilences() {
        let synth = Synth(sampleRate: 48_000)
        synth.push(.intensity(1))
        synth.push(.event(.explosion(.tanker)))
        synth.push(.mute(true))
        let buffer = renderBuffer(synth)

        #expect(buffer.allSatisfy { $0 == 0 })
    }

    @Test("Triggering an SFX produces audible output")
    func sfxAudible() {
        let synth = Synth(sampleRate: 48_000)
        synth.push(.music(false))
        synth.push(.event(.explosion(.tanker)))
        let buffer = renderBuffer(synth)
        let energy = buffer.reduce(Float(0)) { $0 + abs($1) }

        #expect(energy > 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SynthTests`
Expected: FAIL to build — `cannot find 'Synth' in scope`.

- [ ] **Step 3: Implement the Synth**

Create `Sources/RadialAfterburn/Synth.swift`:

```swift
import Foundation
import os

final class Synth: @unchecked Sendable {
    enum Command: Sendable {
        case event(GameAudioEvent)
        case intensity(Float)
        case music(Bool)
        case sfx(Bool)
        case masterVolume(Float)
        case mute(Bool)
    }

    private struct Voice {
        var active = false
        var age: Float = 0
        var duration: Float = 1
        var phase: Float = 0
        var freq: Float = 0
        var freqEnd: Float = 0
        var amp: Float = 0
        var noiseMix: Float = 0
    }

    private let sampleRate: Float
    private let commands = OSAllocatedUnfairLock<[Command]>(initialState: [])

    // Render-thread-only state.
    private var sampleClock: UInt64 = 0
    private var intensity: Float = 0
    private var targetIntensity: Float = 0
    private var musicEnabled = true
    private var sfxEnabled = true
    private var muted = false
    private var masterVolume: Float = 0.8

    private var lastStep = -1
    private var bassPhase: Float = 0
    private var bassFreq: Float = 55
    private var bassEnv: Float = 0
    private var bassFilterLP: Float = 0
    private var wobblePhase: Float = 0
    private var wobbleRate: Float = 4
    private var kickPhase: Float = 0
    private var kickEnv: Float = 0
    private var snareEnv: Float = 0
    private var hatEnv: Float = 0
    private var noiseState: UInt32 = 0x1234_5678

    private static let voiceCount = 16
    private var voices: [Voice]

    init(sampleRate: Float) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.voices = Array(repeating: Voice(), count: Self.voiceCount)
    }

    func push(_ command: Command) {
        commands.withLock { $0.append(command) }
    }

    func render(into buffer: UnsafeMutableBufferPointer<Float>) {
        drainCommands()

        let dt = 1 / sampleRate
        let samplesPerBeat = sampleRate * 60 / 140
        let samplesPerStep = Double(samplesPerBeat / 4)

        for frame in 0..<buffer.count {
            intensity += (targetIntensity - intensity) * 0.00005

            let step = Int((Double(sampleClock) / samplesPerStep).truncatingRemainder(dividingBy: 16))
            if step != lastStep {
                lastStep = step
                advanceStep(step)
            }

            var sample: Float = 0
            if musicEnabled { sample += renderMusic(dt: dt) }
            if sfxEnabled { sample += renderVoices(dt: dt) }

            sample = tanh(sample * masterVolume)
            buffer[frame] = muted ? 0 : sample
            sampleClock &+= 1
        }
    }

    private func drainCommands() {
        let drained: [Command]? = commands.withLock { queue in
            if queue.isEmpty { return nil }
            let copy = queue
            queue.removeAll(keepingCapacity: true)
            return copy
        }
        guard let drained else { return }
        for command in drained {
            switch command {
            case .event(let event): handleEvent(event)
            case .intensity(let value): targetIntensity = min(1, max(0, value))
            case .music(let on): musicEnabled = on
            case .sfx(let on): sfxEnabled = on
            case .masterVolume(let value): masterVolume = min(1, max(0, value))
            case .mute(let value): muted = value
            }
        }
    }

    private func advanceStep(_ step: Int) {
        let bassNotes: [Float] = [55, 55, 55, 73.42, 49, 49, 65.41, 55,
                                  55, 55, 55, 73.42, 49, 49, 41.20, 49]
        bassFreq = bassNotes[step]
        bassEnv = 0.9

        let rates: [Float] = [2, 4, 8, 4]
        wobbleRate = rates[(step / 4) % 4] * (1 + intensity)

        if step == 0 || step == 10 { kickEnv = 1 }
        if step == 8 { snareEnv = 1 }
        if step % 2 == 1 { hatEnv = 1 }
    }

    private func renderMusic(dt: Float) -> Float {
        var out: Float = 0

        if bassEnv > 0.0001 {
            wobblePhase += wobbleRate * dt
            if wobblePhase >= 1 { wobblePhase -= 1 }
            let lfo = (sin(wobblePhase * 2 * Float.pi) + 1) * 0.5
            let cutoff = 0.02 + lfo * (0.25 + intensity * 0.35)

            bassPhase += bassFreq * dt
            if bassPhase >= 1 { bassPhase -= 1 }
            let saw = bassPhase * 2 - 1
            bassFilterLP += cutoff * (saw - bassFilterLP)

            out += bassFilterLP * bassEnv * 0.7
            bassEnv = max(0, bassEnv - dt * 0.5)
        }

        if kickEnv > 0.0001 {
            kickPhase += (40 + kickEnv * kickEnv * 220) * dt
            if kickPhase >= 1 { kickPhase -= 1 }
            out += sin(kickPhase * 2 * Float.pi) * kickEnv * 0.9
            kickEnv = max(0, kickEnv - dt * 3.2)
        }

        if snareEnv > 0.0001 {
            out += nextNoise() * snareEnv * 0.5
            snareEnv = max(0, snareEnv - dt * 6)
        }

        if hatEnv > 0.0001 {
            out += nextNoise() * hatEnv * 0.25 * intensity
            hatEnv = max(0, hatEnv - dt * 20)
        }

        return out
    }

    private func renderVoices(dt: Float) -> Float {
        var out: Float = 0
        for index in voices.indices where voices[index].active {
            var voice = voices[index]
            let t = min(1, voice.age / voice.duration)
            let env = (1 - t) * (1 - t)
            let freq = voice.freq + (voice.freqEnd - voice.freq) * t

            voice.phase += freq * dt
            if voice.phase >= 1 { voice.phase -= 1 }
            let tone = sin(voice.phase * 2 * Float.pi)
            let noise = nextNoise()
            out += (tone * (1 - voice.noiseMix) + noise * voice.noiseMix) * env * voice.amp

            voice.age += dt
            if voice.age >= voice.duration { voice.active = false }
            voices[index] = voice
        }
        return out
    }

    private func handleEvent(_ event: GameAudioEvent) {
        switch event {
        case .start:
            trigger(freq: 440, freqEnd: 880, duration: 0.12, amp: 0.3, noiseMix: 0)
        case .fire:
            trigger(freq: 900, freqEnd: 300, duration: 0.06, amp: 0.18, noiseMix: 0.15)
        case .explosion(let kind):
            let pitch = 1 + intensity * 0.8
            switch kind {
            case .spike:
                trigger(freq: 220 * pitch, freqEnd: 60, duration: 0.22, amp: 0.4, noiseMix: 0.5)
            case .flipper:
                trigger(freq: 180 * pitch, freqEnd: 50, duration: 0.30, amp: 0.5, noiseMix: 0.55)
            case .tanker:
                trigger(freq: 90 * pitch, freqEnd: 35, duration: 0.50, amp: 0.7, noiseMix: 0.4)
            }
        case .breach:
            trigger(freq: 320, freqEnd: 40, duration: 0.6, amp: 0.6, noiseMix: 0.3)
        case .waveClear:
            trigger(freq: 300, freqEnd: 1200, duration: 0.7, amp: 0.4, noiseMix: 0.1)
        case .gameOver:
            trigger(freq: 200, freqEnd: 30, duration: 1.2, amp: 0.6, noiseMix: 0.2)
        case .bonusLife:
            trigger(freq: 600, freqEnd: 1400, duration: 0.4, amp: 0.4, noiseMix: 0)
        }
    }

    private func trigger(freq: Float, freqEnd: Float, duration: Float, amp: Float, noiseMix: Float) {
        var index = voices.firstIndex { !$0.active }
        if index == nil {
            var oldest: Float = -1
            for candidate in voices.indices where voices[candidate].age > oldest {
                oldest = voices[candidate].age
                index = candidate
            }
        }
        guard let slot = index else { return }
        voices[slot] = Voice(active: true, age: 0, duration: duration, phase: 0,
                             freq: freq, freqEnd: freqEnd, amp: amp, noiseMix: noiseMix)
    }

    private func nextNoise() -> Float {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Float(Int32(bitPattern: noiseState)) / Float(Int32.max)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SynthTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/RadialAfterburn/Synth.swift Tests/RadialAfterburnTests/SynthTests.swift
git commit -m "feat: add procedural dubstep synth core"
```

---

### Task 3: AudioEngine facade

Wraps `AVAudioEngine` + one `AVAudioSourceNode` around the `Synth`. Bridges main-thread control calls into `Synth.push`. All setup is non-fatal: on failure the facade becomes a silent no-op. There is no unit test (it needs audio hardware and is excluded from CI); it is verified by `swift build` and a manual run.

**Files:**
- Create: `Sources/RadialAfterburn/AudioEngine.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `Synth`, `Synth.Command`, `GameAudioEvent` (Task 1/2).
- Produces (`@MainActor final class AudioEngine`):
  - `init()`
  - `func post(_ events: [GameAudioEvent])`
  - `func setIntensity(wave: Int, combo: Int, comboPulse: Float, playing: Bool)`
  - `func toggleMusic()`
  - `func toggleSFX()`
  - `func nudgeVolume(_ delta: Float)`
  - `func toggleMute()`

- [ ] **Step 1: Link AVFoundation**

In `Package.swift`, add the framework to the executable target's `linkerSettings`:

```swift
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation")
            ]
```

- [ ] **Step 2: Implement the facade**

Create `Sources/RadialAfterburn/AudioEngine.swift`:

```swift
import AVFoundation
import os

@MainActor
final class AudioEngine {
    private let engine = AVAudioEngine()
    private let synth: Synth
    private var sourceNode: AVAudioSourceNode?
    private var available = false

    private var masterVolume: Float = 0.8
    private var musicOn = true
    private var sfxOn = true
    private var muted = false

    private let log = Logger(subsystem: "RadialAfterburn", category: "audio")

    init() {
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = hardwareRate > 0 ? hardwareRate : 48_000
        synth = Synth(sampleRate: Float(sampleRate))
        start(sampleRate: sampleRate)
    }

    private func start(sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            log.error("Audio unavailable: could not create output format")
            return
        }

        let synth = self.synth
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, ablPointer in
            let frames = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
            guard let first = buffers.first, let data = first.mData else { return noErr }

            let capacity = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let count = min(frames, capacity)
            let mono = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            synth.render(into: mono)

            for channel in 1..<buffers.count {
                guard let channelData = buffers[channel].mData else { continue }
                let destination = channelData.assumingMemoryBound(to: Float.self)
                for frame in 0..<count {
                    destination[frame] = mono[frame]
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node

        do {
            try engine.start()
            available = true
        } catch {
            available = false
            log.error("Audio unavailable: engine failed to start (\(error.localizedDescription))")
        }
    }

    func post(_ events: [GameAudioEvent]) {
        guard available else { return }
        for event in events {
            synth.push(.event(event))
        }
    }

    func setIntensity(wave: Int, combo: Int, comboPulse: Float, playing: Bool) {
        guard available else { return }
        guard playing else {
            synth.push(.intensity(0.05))
            return
        }
        let waveLevel = min(1, Float(max(0, wave - 1)) / 9)
        let comboBoost = min(0.4, Float(max(0, combo - 1)) * 0.05) + comboPulse * 0.2
        synth.push(.intensity(min(1, waveLevel * 0.7 + comboBoost)))
    }

    func toggleMusic() {
        guard available else { return }
        musicOn.toggle()
        synth.push(.music(musicOn))
    }

    func toggleSFX() {
        guard available else { return }
        sfxOn.toggle()
        synth.push(.sfx(sfxOn))
    }

    func nudgeVolume(_ delta: Float) {
        guard available else { return }
        masterVolume = min(1, max(0, masterVolume + delta))
        synth.push(.masterVolume(masterVolume))
    }

    func toggleMute() {
        guard available else { return }
        muted.toggle()
        synth.push(.mute(muted))
    }
}
```

- [ ] **Step 3: Verify the build**

Run: `swift build`
Expected: builds with no errors or warnings.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/RadialAfterburn/AudioEngine.swift
git commit -m "feat: add AVFoundation audio engine facade"
```

---

### Task 4: Renderer integration

`Renderer` owns the `AudioEngine`, drains `GameState` audio events each frame, and pushes them plus the intensity snapshot. Verified by `swift build`, the full test suite (no regressions), and a manual run that produces sound.

**Files:**
- Modify: `Sources/RadialAfterburn/Renderer.swift`

**Interfaces:**
- Consumes: `AudioEngine` (Task 3), `GameState.drainAudioEvents()` (Task 1).
- Produces: `Renderer.audio: AudioEngine` (internal `let`, readable by `MetalGameView` in Task 5).

- [ ] **Step 1: Add the audio engine property**

In `Sources/RadialAfterburn/Renderer.swift`, add the stored property next to `var game = GameState()` (currently line 21):

```swift
    var game = GameState()
    let audio = AudioEngine()
    var onHUDUpdate: ((GameState) -> Void)?
```

> `AudioEngine` is `@MainActor` and `Renderer` is `@MainActor`, so the inline default initializer runs on the main actor. It never throws; any audio failure is handled internally.

- [ ] **Step 2: Forward events and intensity each frame**

In `Renderer.draw(in:)`, replace the existing `game.update(deltaTime: deltaTime)` line (currently line 49) with:

```swift
        game.update(deltaTime: deltaTime)
        audio.post(game.drainAudioEvents())
        audio.setIntensity(
            wave: game.wave,
            combo: game.combo,
            comboPulse: game.comboPulse,
            playing: game.phase == .playing
        )
```

- [ ] **Step 3: Verify build and tests**

Run: `swift build`
Expected: builds cleanly.
Run: `swift test`
Expected: PASS (all suites — no regressions; tests never construct `Renderer`/`AudioEngine`).

- [ ] **Step 4: Manual smoke check**

Run: `swift run RadialAfterburn`
Expected: window opens, a low idle wobble loop is audible on the title screen; pressing Return starts the game and firing produces zap blips, kills produce explosion booms, and the music intensifies on later waves. Close the window to exit.

- [ ] **Step 5: Commit**

```bash
git add Sources/RadialAfterburn/Renderer.swift
git commit -m "feat: drive audio from the render loop"
```

---

### Task 5: Player audio controls

Adds keyboard controls (M music, N SFX, `[`/`]` volume, `\` mute) in `MetalGameView` and a second help-bar line in `main.swift`.

**Files:**
- Modify: `Sources/RadialAfterburn/MetalGameView.swift`
- Modify: `Sources/RadialAfterburn/main.swift`

**Interfaces:**
- Consumes: `Renderer.audio` (Task 4) — `toggleMusic()`, `toggleSFX()`, `nudgeVolume(_:)`, `toggleMute()`.

- [ ] **Step 1: Handle the audio control keys**

In `Sources/RadialAfterburn/MetalGameView.swift`, add cases to the `switch event.keyCode` block inside `keyDown(with:)` (after the existing `case 53:` / before `default:`):

```swift
        case 53:
            NSApplication.shared.terminate(nil)
        case 46:
            renderer?.audio.toggleMusic()
        case 45:
            renderer?.audio.toggleSFX()
        case 33:
            renderer?.audio.nudgeVolume(-0.1)
        case 30:
            renderer?.audio.nudgeVolume(0.1)
        case 42:
            renderer?.audio.toggleMute()
        default:
            break
```

> Key codes (ANSI US): `M`=46, `N`=45, `[`=33, `]`=30, `\`=42. These keys are also added to `heldKeys` but `processHeldKeys()` ignores them, so there is no repeat behavior — toggles fire once per press (repeats early-return before the switch).

- [ ] **Step 2: Extend the help bar to two lines**

In `Sources/RadialAfterburn/main.swift`, change the `helpLabel` initializer (currently line 9):

```swift
    private let helpLabel = NSTextField(labelWithString: "←/A  MOVE   →/D  MOVE   SPACE  FIRE   P  PAUSE\nM  MUSIC   N  SFX   [ / ]  VOLUME   \\  MUTE")
```

Then allow it to render two lines. In `loadView()`, immediately after `configure(label: helpLabel, size: 12, weight: .medium)` (currently line 40), add:

```swift
        helpLabel.usesSingleLineMode = false
        helpLabel.maximumNumberOfLines = 2
        helpLabel.cell?.wraps = true
```

- [ ] **Step 3: Verify build and tests**

Run: `swift build`
Expected: builds cleanly.
Run: `swift test`
Expected: PASS (no regressions).

- [ ] **Step 4: Manual smoke check**

Run: `swift run RadialAfterburn`
Expected: the help bar shows two lines including the audio controls. During play: `M` toggles the music layer, `N` toggles SFX, `[` / `]` lower/raise volume, `\` mutes/unmutes everything. Close the window to exit.

- [ ] **Step 5: Commit**

```bash
git add Sources/RadialAfterburn/MetalGameView.swift Sources/RadialAfterburn/main.swift
git commit -m "feat: add keyboard audio controls and help text"
```

---

## Self-Review

**Spec coverage:**
- Synthesized-in-code audio, no assets → Tasks 2/3 (Synth + AVAudioSourceNode), no binary files. ✓
- Event seam in `GameState`, drained by `Renderer` → Tasks 1 & 4. ✓
- Single `OSAllocatedUnfairLock` command queue carrying both events and intensity → Task 2 (`Synth.Command` + `commands`), Task 3 (`push`). ✓
- Intensity ramps with waves/combo, ducks on non-play → Task 2 (`advanceStep`/`renderMusic` use `intensity`), Task 3 (`setIntensity` with `playing`). ✓
- SFX per event with combo→pitch folded into explosions → Task 2 (`handleEvent`, `pitch = 1 + intensity * 0.8`). ✓
- Controls M/N/`[`/`]`/`\` + two-line help → Task 5. ✓
- Non-fatal audio, no AVFoundation in `GameState`, CI-safe tests → Task 3 (guarded `do/catch`, `available`), Task 1 (pure enum), Tasks 1/2 tests never touch `AVAudioEngine`. ✓
- Bounded `[-1,1]` output as a design requirement → Task 2 (`tanh` soft-clip), `SynthTests.boundedSamples`. ✓

**Deliberate spec deviation:** the spec's testing section listed a `.bonusLife` unit test ("crossing 25k emits `.bonusLife`"). The `.bonusLife` *event is implemented and emitted* (Task 1, Step 4, bonus-life loop), but no automated test is included: reaching a 25,000 score deterministically requires a full auto-player that must also avoid game-over for many simulated waves, which is slow and brittle. It is covered by manual verification instead. All other listed event tests (fire, explosion, breach, game over) and the start/drain tests are included and robust.

**Placeholder scan:** no TBD/TODO/"handle edge cases"/"similar to Task N" — every step contains complete code or an exact command. ✓

**Type consistency:** `GameAudioEvent` cases identical across Tasks 1/2; `Synth.Command` cases identical between Task 2 (definition + `drainCommands`) and Task 3 (`push` call sites); `Synth.render(into:)` / `push(_:)` signatures match between Task 2 and the Task 3 render block and Task 2 tests; `AudioEngine` method names (`post`, `setIntensity(wave:combo:comboPulse:playing:)`, `toggleMusic`, `toggleSFX`, `nudgeVolume`, `toggleMute`) identical between Task 3 (definition), Task 4 (`Renderer`), and Task 5 (`MetalGameView`). ✓
