import AVFoundation

/// All sound is synthesized procedurally at startup — no bundled audio, matching the
/// "everything from code" spirit of the renderer. A small pool of player voices is
/// round-robined so rapid fire and explosions overlap instead of cutting each other off.
/// If the audio engine can't start, the game runs silently rather than crashing.
@MainActor
final class GameAudio {
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var voices: [AVAudioPlayerNode] = []
    private var voiceIndex = 0
    private let ambientNode = AVAudioPlayerNode()
    private var enabled = false

    private let fire: AVAudioPCMBuffer
    private let explosion: AVAudioPCMBuffer
    private let bigExplosion: AVAudioPCMBuffer
    private let waveClear: AVAudioPCMBuffer
    private let lifeLost: AVAudioPCMBuffer
    private let bonus: AVAudioPCMBuffer
    private let ambient: AVAudioPCMBuffer

    init() {
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        format = fmt

        // Short descending zap with a noisy attack click.
        fire = GameAudio.buffer(format: fmt, seconds: 0.14) { t, i in
            let phase = 2 * .pi * (880.0 * t + 0.5 * -3600.0 * t * t)
            let body = sin(phase)
            let square = body >= 0 ? 1.0 : -1.0
            let click = i < 60 ? Double.random(in: -1...1) * exp(-t * 90) * 0.4 : 0
            return (body * 0.7 + square * 0.25 + click) * exp(-t * 16) * 0.5
        }

        // Filtered noise crackle over a low thump.
        var exLP = 0.0
        explosion = GameAudio.buffer(format: fmt, seconds: 0.35) { t, _ in
            let white = Double.random(in: -1...1)
            exLP += (white - exLP) * 0.22
            let crackle = exLP * exp(-t * 8)
            let thump = sin(2 * .pi * 95 * t) * exp(-t * 6)
            return (crackle * 0.8 + thump * 0.6) * 0.85
        }

        // Longer, lower, with a falling sub-sweep — for tankers.
        var bigLP = 0.0
        bigExplosion = GameAudio.buffer(format: fmt, seconds: 0.6) { t, _ in
            let white = Double.random(in: -1...1)
            bigLP += (white - bigLP) * 0.14
            let crackle = bigLP * exp(-t * 4.5)
            let thump = (sin(2 * .pi * 55 * t) + sin(2 * .pi * 40 * t) * 0.6) * exp(-t * 4)
            let sweep = sin(2 * .pi * (120 - 80 * t) * t) * exp(-t * 5) * 0.3
            return (crackle * 0.7 + thump * 0.7 + sweep) * 0.9
        }

        // Rising triad with shimmer — soft attack, slow tail.
        waveClear = GameAudio.buffer(format: fmt, seconds: 0.7) { t, _ in
            let env = min(1, t * 8) * exp(-t * 2.2)
            let f = 330.0 + 500.0 * t
            let chord = sin(2 * .pi * f * t) * 0.4
                + sin(2 * .pi * f * 1.5 * t) * 0.3
                + sin(2 * .pi * f * 2 * t) * 0.2
            let shimmer = sin(2 * .pi * (1800 + 600 * sin(2 * .pi * 6 * t)) * t) * 0.15
            return (chord + shimmer) * env * 0.6
        }

        // Descending tone with a sub octave — losing a life.
        lifeLost = GameAudio.buffer(format: fmt, seconds: 0.5) { t, _ in
            let f = 520.0 - 360.0 * t
            let tone = sin(2 * .pi * f * t) * 0.6 + sin(2 * .pi * f * 0.5 * t) * 0.5
            return tone * exp(-t * 3) * 0.7
        }

        // Two ascending blips — bonus life.
        bonus = GameAudio.buffer(format: fmt, seconds: 0.4) { t, _ in
            let second = t >= 0.18
            let seg = second ? t - 0.18 : t
            let f = second ? 1320.0 : 880.0
            return sin(2 * .pi * f * seg) * exp(-seg * 14) * 0.5
        }

        // Seamless 4s drone loop: every frequency completes whole cycles in 4s.
        ambient = GameAudio.buffer(format: fmt, seconds: 4.0) { t, _ in
            let lfo = 0.6 + 0.4 * sin(2 * .pi * 0.25 * t)
            let low = (sin(2 * .pi * 55 * t) + sin(2 * .pi * 55.25 * t)) * 0.35
            let mid = sin(2 * .pi * 82.5 * t) * 0.25
            let body = sin(2 * .pi * 110 * t) * 0.4
            let air = sin(2 * .pi * 220 * t) * 0.05 * (0.5 + 0.5 * sin(2 * .pi * 0.5 * t))
            return (low + mid + body) * lfo * 0.18 + air
        }

        for _ in 0..<8 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            voices.append(node)
        }
        engine.attach(ambientNode)
        engine.connect(ambientNode, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.85

        do {
            try engine.start()
            enabled = true
            for voice in voices { voice.play() }
            ambientNode.volume = 0.22
            ambientNode.scheduleBuffer(ambient, at: nil, options: .loops, completionHandler: nil)
            ambientNode.play()
        } catch {
            enabled = false
        }
    }

    /// Play the sounds for one frame's worth of gameplay events.
    func handle(_ e: FrameEvents) {
        guard enabled else { return }
        for _ in 0..<e.shotsFired { play(fire, volume: 0.32) }
        for _ in 0..<e.explosions { play(explosion, volume: 0.5) }
        for _ in 0..<e.bigExplosions { play(bigExplosion, volume: 0.75) }
        if e.waveCleared { play(waveClear, volume: 0.6) }
        if e.lifeLost { play(lifeLost, volume: 0.75) }
        if e.bonusLife { play(bonus, volume: 0.6) }
    }

    private func play(_ buffer: AVAudioPCMBuffer, volume: Float) {
        let node = voices[voiceIndex]
        voiceIndex = (voiceIndex + 1) % voices.count
        node.volume = volume
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    private static func buffer(format: AVAudioFormat, seconds: Double, _ gen: (Double, Int) -> Double) -> AVAudioPCMBuffer {
        let n = max(1, Int(seconds * format.sampleRate))
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let samples = buf.floatChannelData![0]
        for i in 0..<n {
            let t = Double(i) / format.sampleRate
            samples[i] = Float(max(-1, min(1, gen(t, i))))
        }
        return buf
    }
}
