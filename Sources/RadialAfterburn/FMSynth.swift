import Foundation

/// One operator of a YM2612-style 4-operator FM voice.
///
/// `level` means amplitude (0...1) for a carrier and phase-modulation depth in
/// radians for a modulator, so patches read the way the chip's register sheets do.
/// Envelope times are seconds; `decay` and `release` are exponential time constants.
struct FMOperator {
    var ratio: Float
    var level: Float
    var attack: Float = 0.004
    var decay: Float = 0.2
    var sustain: Float = 1
    var release: Float = 0.08
    var detune: Float = 0
}

/// A 4-operator patch using the YM2612's eight routing algorithms (op1 → op4):
/// 0: 1→2→3→4   1: (1+2)→3→4   2: (1+(2→3))→4   3: ((1→2)+3)→4
/// 4: (1→2)+(3→4)   5: 1→(2+3+4)   6: (1→2)+3+4   7: 1+2+3+4
struct FMPatch {
    var ops: [FMOperator]
    var algorithm: Int
    /// Op1 self-modulation in radians of phase per unit output; π ≈ the chip's FB=7.
    var feedback: Float = 0
    /// LFO vibrato depth in semitones, fading in after `vibratoDelay`.
    var vibrato: Float = 0
    var vibratoRate: Float = 5.5
    var vibratoDelay: Float = 0.12
}

/// Offline FM / PSG renderer. Everything adds into plain `[Float]` buffers, so the
/// synth has no audio-thread concerns and is unit-testable without a device.
/// Writes past the end of the buffer wrap to its start, which keeps loop seams clean.
enum FMSynth {
    static func frequency(midi: Int) -> Float {
        440 * pow(2, (Float(midi) - 69) / 12)
    }

    /// Add one FM note into `out` starting at sample `start`.
    static func renderNote(
        _ patch: FMPatch, midi: Int, gate: Float, velocity: Float,
        sampleRate: Float, into out: inout [Float], at start: Int
    ) {
        precondition(patch.ops.count == 4, "FM patch needs exactly 4 operators")
        // Scalar per-operator state: SIMD would read better, but unoptimized debug
        // builds run this loop ~10x slower that way, and the theme renders at launch.
        let o = patch.ops
        func k(_ seconds: Float) -> Float { exp(-1 / (seconds * sampleRate)) }
        let l0 = o[0].level * velocity, l1 = o[1].level * velocity, l2 = o[2].level * velocity, l3 = o[3].level * velocity
        let a0 = 1 / o[0].attack, a1 = 1 / o[1].attack, a2 = 1 / o[2].attack, a3 = 1 / o[3].attack
        let s0 = o[0].sustain, s1 = o[1].sustain, s2 = o[2].sustain, s3 = o[3].sustain
        let kd0 = k(o[0].decay), kd1 = k(o[1].decay), kd2 = k(o[2].decay), kd3 = k(o[3].decay)
        let kr0 = k(o[0].release), kr1 = k(o[1].release), kr2 = k(o[2].release), kr3 = k(o[3].release)
        let twoPi = 2 * Float.pi
        let dt0 = o[0].detune * twoPi / sampleRate, dt1 = o[1].detune * twoPi / sampleRate
        let dt2 = o[2].detune * twoPi / sampleRate, dt3 = o[3].detune * twoPi / sampleRate
        let r0 = o[0].ratio, r1 = o[1].ratio, r2 = o[2].ratio, r3 = o[3].ratio
        let longestRelease = o.map(\.release).max() ?? 0.1
        let gateSamples = Int(gate * sampleRate)
        let total = gateSamples + Int(longestRelease * 7 * sampleRate)

        let baseStep = twoPi * frequency(midi: midi) / sampleRate
        let vibrato = patch.vibrato, vibratoRate = patch.vibratoRate, vibratoDelay = patch.vibratoDelay
        let fb = patch.feedback
        let alg = patch.algorithm
        var p0: Float = 0, p1: Float = 0, p2: Float = 0, p3: Float = 0
        var d0: Float = 1, d1: Float = 1, d2: Float = 1, d3: Float = 1
        var rel0: Float = 1, rel1: Float = 1, rel2: Float = 1, rel3: Float = 1
        var feedbackMemory: Float = 0
        let invSampleRate = 1 / sampleRate
        let invLevel0 = l0 > 0 ? 1 / l0 : 0

        out.withUnsafeMutableBufferPointer { buffer in
            let count = buffer.count
            var index = start % count
            for i in 0..<total {
                let t = Float(i) * invSampleRate
                var step = baseStep
                if vibrato > 0, t > vibratoDelay {
                    let depth = vibrato * min(1, (t - vibratoDelay) * 4)
                    // 2^(x/12) ≈ 1 + 0.0578x for small x
                    step *= 1 + 0.0578 * depth * sin(twoPi * vibratoRate * t)
                }
                p0 += r0 * step + dt0; if p0 >= twoPi { p0 -= twoPi }
                p1 += r1 * step + dt1; if p1 >= twoPi { p1 -= twoPi }
                p2 += r2 * step + dt2; if p2 >= twoPi { p2 -= twoPi }
                p3 += r3 * step + dt3; if p3 >= twoPi { p3 -= twoPi }

                let e0 = min(t * a0, 1) * (s0 + (1 - s0) * d0) * rel0 * l0
                let e1 = min(t * a1, 1) * (s1 + (1 - s1) * d1) * rel1 * l1
                let e2 = min(t * a2, 1) * (s2 + (1 - s2) * d2) * rel2 * l2
                let e3 = min(t * a3, 1) * (s3 + (1 - s3) * d3) * rel3 * l3
                d0 *= kd0; d1 *= kd1; d2 *= kd2; d3 *= kd3
                if i >= gateSamples { rel0 *= kr0; rel1 *= kr1; rel2 *= kr2; rel3 *= kr3 }

                // Feedback follows the op's unit output shaped by its envelope (so the
                // growl decays with the note), averaged over two samples like the chip.
                let raw = sin(p0 + fb * feedbackMemory)
                feedbackMemory = (feedbackMemory + raw * (e0 * invLevel0)) * 0.5
                let o1 = raw * e0
                let sample: Float
                switch alg {
                case 0:
                    let o2 = sin(p1 + o1) * e1
                    let o3 = sin(p2 + o2) * e2
                    sample = sin(p3 + o3) * e3
                case 1:
                    let o2 = sin(p1) * e1
                    let o3 = sin(p2 + o1 + o2) * e2
                    sample = sin(p3 + o3) * e3
                case 2:
                    let o2 = sin(p1) * e1
                    let o3 = sin(p2 + o2) * e2
                    sample = sin(p3 + o1 + o3) * e3
                case 3:
                    let o2 = sin(p1 + o1) * e1
                    let o3 = sin(p2) * e2
                    sample = sin(p3 + o2 + o3) * e3
                case 4:
                    let o2 = sin(p1 + o1) * e1
                    let o3 = sin(p2) * e2
                    sample = o2 + sin(p3 + o3) * e3
                case 5:
                    sample = sin(p1 + o1) * e1 + sin(p2 + o1) * e2 + sin(p3 + o1) * e3
                case 6:
                    sample = sin(p1 + o1) * e1 + sin(p2) * e2 + sin(p3) * e3
                default:
                    sample = o1 + sin(p1) * e1 + sin(p2) * e2 + sin(p3) * e3
                }
                buffer[index] += sample
                index += 1
                if index == count { index = 0 }
            }
        }
    }

    /// SN76489-style square wave with the chip's 16-step (4-bit) volume ladder.
    static func renderSquare(
        midi: Int, gate: Float, decay: Float, velocity: Float,
        sampleRate: Float, into out: inout [Float], at start: Int
    ) {
        let step = frequency(midi: midi) / sampleRate
        let kDecay = exp(-1 / (decay * sampleRate))
        let total = Int(gate * sampleRate)
        var phase: Float = 0
        var env = velocity
        out.withUnsafeMutableBufferPointer { buffer in
            let count = buffer.count
            for i in 0..<total {
                phase += step
                if phase >= 1 { phase -= 1 }
                let quantized = (env * 15).rounded(.down) / 15
                buffer[(start + i) % count] += (phase < 0.5 ? quantized : -quantized)
                env *= kDecay
            }
        }
    }

    /// 15-bit LFSR white noise, as the SN76489 noise channel produced it.
    struct Noise {
        private var shift: UInt16 = 0x4000
        mutating func next() -> Float {
            let bit = (shift ^ (shift >> 1)) & 1
            shift = (shift >> 1) | (bit << 14)
            return shift & 1 == 0 ? -1 : 1
        }
    }

    /// Drum hits rendered as short one-shots: a sampled-feel kick, a noise snare, and
    /// hi-hats from high-passed LFSR noise.
    enum Drum {
        case kick, snare, closedHat, openHat
    }

    static func renderDrum(_ drum: Drum, velocity: Float, sampleRate: Float, into out: inout [Float], at start: Int) {
        var noise = Noise()
        var previousNoise: Float = 0
        var phase: Float = 0
        let total: Int
        switch drum {
        case .kick: total = Int(0.32 * sampleRate)
        case .snare: total = Int(0.26 * sampleRate)
        case .closedHat: total = Int(0.06 * sampleRate)
        case .openHat: total = Int(0.22 * sampleRate)
        }
        out.withUnsafeMutableBufferPointer { buffer in
            let count = buffer.count
            for i in 0..<total {
                let t = Float(i) / sampleRate
                let n = noise.next()
                let highPassed = (n - previousNoise) * 0.5
                previousNoise = n
                let sample: Float
                switch drum {
                case .kick:
                    let f = 48 + 140 * exp(-t * 28)
                    phase += 2 * .pi * f / sampleRate
                    let click = t < 0.004 ? n * 0.5 : 0
                    sample = (sin(phase) * 1.1 + click) * exp(-t * 9)
                case .snare:
                    let f = 150 + 70 * exp(-t * 40)
                    phase += 2 * .pi * f / sampleRate
                    sample = n * 0.55 * exp(-t * 14) + sin(phase) * 0.5 * exp(-t * 26)
                case .closedHat:
                    sample = highPassed * 0.7 * exp(-t * 55)
                case .openHat:
                    sample = highPassed * 0.6 * exp(-t * 14)
                }
                buffer[(start + i) % count] += max(-1, min(1, sample)) * velocity
            }
        }
    }
}
