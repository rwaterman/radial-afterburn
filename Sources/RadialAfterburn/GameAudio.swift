import AVFoundation

/// All sound is synthesized procedurally — no bundled audio, matching the
/// "everything from code" spirit of the renderer. SFX are short PCM one-shots
/// round-robined across a voice pool so rapid fire and explosions overlap. The
/// soundtrack (`Soundtrack`) is rendered in the background at launch as five
/// sample-locked looping layers whose volumes follow the game phase and wave.
/// If the audio engine can't start, the game runs silently rather than crashing.
@MainActor
final class GameAudio {
    nonisolated static let sampleRate = 44_100.0
    /// Layer volumes (drums, bass, chords, arp, lead) at full intensity.
    nonisolated static let fullMix: [Float] = [0.45, 0.38, 0.28, 0.18, 0.48]

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var voices: [AVAudioPlayerNode] = []
    private var voiceIndex = 0
    private var enabled = false

    private var musicNodes: [AVAudioPlayerNode] = []
    private var musicVolumes: [Float] = Array(repeating: 0, count: 5)
    private(set) var musicEnabled = true

    private var effects: [SoundEffect: AVAudioPCMBuffer] = [:]

    init() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: GameAudio.sampleRate, channels: 1)!
        format = fmt
        for effect in SoundEffect.allCases {
            effects[effect] = GameAudio.buffer(format: fmt, samples: effect.render(sampleRate: GameAudio.sampleRate))
        }

        for _ in 0..<8 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            voices.append(node)
        }
        for _ in 0..<GameAudio.fullMix.count {
            let node = AVAudioPlayerNode()
            node.volume = 0
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            musicNodes.append(node)
        }
        engine.mainMixerNode.outputVolume = 0.85

        do {
            try engine.start()
            enabled = true
            for voice in voices { voice.play() }
        } catch {
            FileHandle.standardError.write(Data("audio: engine failed to start, running silent (\(error))\n".utf8))
            enabled = false
            return
        }

        // The theme takes a moment to synthesize; render it off the main thread and
        // start all layers on one shared clock so they stay sample-locked.
        Task.detached(priority: .userInitiated) { [weak self] in
            let layers = Soundtrack.render(sampleRate: Float(GameAudio.sampleRate))
            await self?.startMusic(layers)
        }
    }

    private func startMusic(_ layers: SongLayers) {
        let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1))
        for (node, samples) in zip(musicNodes, layers.all) {
            let buffer = GameAudio.buffer(format: format, samples: samples)
            node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            node.play(at: startTime)
        }
    }

    /// Play this frame's SFX and ease the music layers toward the mix for the
    /// current phase and wave.
    func update(_ game: GameState, deltaTime: Float) {
        guard enabled else { return }
        for effect in SoundEffect.triggered(by: game.events) {
            play(effects[effect]!, volume: effect.volume)
        }

        let target = musicEnabled ? GameAudio.mix(phase: game.phase, wave: game.wave) : Array(repeating: 0, count: musicNodes.count)
        GameAudio.ease(&musicVolumes, toward: target, deltaTime: deltaTime)
        for i in musicNodes.indices { musicNodes[i].volume = musicVolumes[i] }
    }

    /// Exponential glide of layer volumes toward a target mix (no clicks, ~0.2 s).
    nonisolated static func ease(_ volumes: inout [Float], toward target: [Float], deltaTime: Float) {
        let amount = 1 - exp(-deltaTime * 5)
        for i in volumes.indices { volumes[i] += (target[i] - volumes[i]) * amount }
    }

    func toggleMusic() {
        musicEnabled.toggle()
    }

    /// Per-layer volumes (drums, bass, chords, arp, lead). The title screen idles on
    /// bass, chords, and arp; drums and lead come in when play starts, and the lead
    /// and arp grow with the wave. Pause and game over duck everything.
    nonisolated static func mix(phase: GamePhase, wave: Int) -> [Float] {
        let full = fullMix
        switch phase {
        case .title:
            return [0, full[1] * 0.7, full[2], full[3] * 0.8, 0]
        case .playing:
            let ramp = min(1, Float(wave - 1) / 5)
            return [full[0], full[1], full[2], full[3] * (0.6 + 0.4 * ramp), full[4] * (0.75 + 0.25 * ramp)]
        case .paused:
            return full.map { $0 * 0.3 }
        case .gameOver:
            return [0, full[1] * 0.4, full[2] * 0.5, 0, 0]
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, volume: Float) {
        let node = voices[voiceIndex]
        voiceIndex = (voiceIndex + 1) % voices.count
        node.volume = volume
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    private static func buffer(format: AVAudioFormat, samples: [Float]) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }
}

/// Synthesized one-shot effects, shared by live playback and the video recorder.
enum SoundEffect: CaseIterable {
    case fire, explosion, bigExplosion, waveClear, lifeLost, bonus

    var volume: Float {
        switch self {
        case .fire: 0.32
        case .explosion: 0.5
        case .bigExplosion: 0.75
        case .waveClear: 0.6
        case .lifeLost: 0.75
        case .bonus: 0.6
        }
    }

    /// Every effect one frame's events trigger, with repeats.
    static func triggered(by e: FrameEvents) -> [SoundEffect] {
        var out = [SoundEffect](repeating: .fire, count: e.shotsFired)
        out += [SoundEffect](repeating: .explosion, count: e.explosions)
        out += [SoundEffect](repeating: .bigExplosion, count: e.bigExplosions)
        if e.waveCleared { out.append(.waveClear) }
        if e.lifeLost { out.append(.lifeLost) }
        if e.bonusLife { out.append(.bonus) }
        return out
    }

    // Kept as small typed steps: Swift 6.1's type checker gives up on the
    // literal-heavy one-liners these started as.
    func render(sampleRate: Double) -> [Float] {
        var random = SeededRandom(seed: 0x5f78)
        func white() -> Double { Double(random.nextFloat()) * 2 - 1 }
        let twoPi: Double = 2 * .pi
        switch self {
        case .fire:
            // Short descending zap with a noisy attack click.
            return SoundEffect.samples(sampleRate: sampleRate, seconds: 0.14) { t, i in
                let sweep: Double = 880 * t - 1800 * t * t
                let body: Double = sin(twoPi * sweep)
                let square: Double = body >= 0 ? 1 : -1
                let click: Double = i < 60 ? white() * exp(-t * 90) * 0.4 : 0
                let mix: Double = body * 0.7 + square * 0.25 + click
                return mix * exp(-t * 16) * 0.5
            }
        case .explosion:
            // Filtered noise crackle over a low thump.
            var lowPass = 0.0
            return SoundEffect.samples(sampleRate: sampleRate, seconds: 0.35) { t, _ in
                lowPass += (white() - lowPass) * 0.22
                let crackle: Double = lowPass * exp(-t * 8)
                let thump: Double = sin(twoPi * 95 * t) * exp(-t * 6)
                return (crackle * 0.8 + thump * 0.6) * 0.85
            }
        case .bigExplosion:
            // Longer, lower, with a falling sub-sweep — for tankers.
            var lowPass = 0.0
            return SoundEffect.samples(sampleRate: sampleRate, seconds: 0.6) { t, _ in
                lowPass += (white() - lowPass) * 0.14
                let crackle: Double = lowPass * exp(-t * 4.5)
                let sub: Double = sin(twoPi * 55 * t) + sin(twoPi * 40 * t) * 0.6
                let thump: Double = sub * exp(-t * 4)
                let sweepHz: Double = 120 - 80 * t
                let sweep: Double = sin(twoPi * sweepHz * t) * exp(-t * 5) * 0.3
                return (crackle * 0.7 + thump * 0.7 + sweep) * 0.9
            }
        case .waveClear:
            // Rising triad with shimmer — soft attack, slow tail.
            return SoundEffect.samples(sampleRate: sampleRate, seconds: 0.7) { t, _ in
                let env: Double = min(1, t * 8) * exp(-t * 2.2)
                let f: Double = 330 + 500 * t
                let root: Double = sin(twoPi * f * t) * 0.4
                let fifth: Double = sin(twoPi * f * 1.5 * t) * 0.3
                let octave: Double = sin(twoPi * f * 2 * t) * 0.2
                let shimmerHz: Double = 1800 + 600 * sin(twoPi * 6 * t)
                let shimmer: Double = sin(twoPi * shimmerHz * t) * 0.15
                return (root + fifth + octave + shimmer) * env * 0.6
            }
        case .lifeLost:
            // Descending tone with a sub octave.
            return SoundEffect.samples(sampleRate: sampleRate, seconds: 0.5) { t, _ in
                let f: Double = 520 - 360 * t
                let tone: Double = sin(twoPi * f * t) * 0.6
                let sub: Double = sin(twoPi * f * 0.5 * t) * 0.5
                return (tone + sub) * exp(-t * 3) * 0.7
            }
        case .bonus:
            // Two ascending blips.
            return SoundEffect.samples(sampleRate: sampleRate, seconds: 0.4) { t, _ in
                let second = t >= 0.18
                let seg: Double = second ? t - 0.18 : t
                let f: Double = second ? 1320 : 880
                return sin(twoPi * f * seg) * exp(-seg * 14) * 0.5
            }
        }
    }

    private static func samples(sampleRate: Double, seconds: Double, _ gen: (Double, Int) -> Double) -> [Float] {
        let n = max(1, Int(seconds * sampleRate))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = Float(max(-1, min(1, gen(Double(i) / sampleRate, i))))
        }
        return out
    }
}
