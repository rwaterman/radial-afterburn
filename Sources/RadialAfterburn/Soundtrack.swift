import Foundation
import os

/// The game's looping theme, in the style of a Mega Drive / Genesis YM2612 + SN76489
/// track: growling FM octave bass, brass lead with LFO vibrato, FM e-piano stabs, a
/// PSG square arpeggio, and punchy drums. 150 BPM, E minor, 16 bars (25.6 s loop).
///
/// Rendered offline into five independent layers so the game can mix intensity by
/// wave (title screen = bass + chords + arp; full band once you're playing).
struct SongLayers: Sendable {
    var drums: [Float]
    var bass: [Float]
    var chords: [Float]
    var arp: [Float]
    var lead: [Float]

    var all: [[Float]] { [drums, bass, chords, arp, lead] }
}

enum Soundtrack {
    static let bpm: Float = 150
    static let bars = 16
    static let stepsPerBar = 16
    static var stepSeconds: Float { 60 / bpm / 4 }
    static var loopSeconds: Float { Float(bars * stepsPerBar) * stepSeconds }

    // MARK: Patches

    /// Slap-style FM bass: feedback saw growl in op1, hard pluck, sub-octave carrier.
    static let bass = FMPatch(
        ops: [
            FMOperator(ratio: 1, level: 2.6, attack: 0.002, decay: 0.07, sustain: 0.35, release: 0.05),
            FMOperator(ratio: 1, level: 0.75, attack: 0.002, decay: 0.35, sustain: 0.55, release: 0.06),
            FMOperator(ratio: 3, level: 1.1, attack: 0.002, decay: 0.04, sustain: 0.1, release: 0.05),
            FMOperator(ratio: 0.5, level: 0.55, attack: 0.003, decay: 0.4, sustain: 0.6, release: 0.07),
        ],
        algorithm: 4, feedback: 2.4)

    /// Brass lead: two 2-op stacks, the second detuned as a whole for chorus (detuning
    /// only a 1:1 carrier leaves a sub-audio DC wobble), modulators sag after the attack.
    static let lead = FMPatch(
        ops: [
            FMOperator(ratio: 1, level: 2.2, attack: 0.015, decay: 0.18, sustain: 0.55, release: 0.12),
            FMOperator(ratio: 1, level: 0.6, attack: 0.012, decay: 0.5, sustain: 0.8, release: 0.12),
            FMOperator(ratio: 2, level: 1.3, attack: 0.02, decay: 0.22, sustain: 0.4, release: 0.12, detune: 5),
            FMOperator(ratio: 1, level: 0.4, attack: 0.012, decay: 0.5, sustain: 0.8, release: 0.12, detune: 2.5),
        ],
        algorithm: 4, feedback: 1.2, vibrato: 0.35, vibratoRate: 5.8, vibratoDelay: 0.18)

    /// FM electric piano for chord stabs: bell-ish 14:1 stack plus a softer 1:1 stack.
    static let ePiano = FMPatch(
        ops: [
            FMOperator(ratio: 14, level: 0.9, attack: 0.002, decay: 0.05, sustain: 0, release: 0.05),
            FMOperator(ratio: 1, level: 0.45, attack: 0.003, decay: 0.45, sustain: 0.3, release: 0.18),
            FMOperator(ratio: 1, level: 1.6, attack: 0.003, decay: 0.25, sustain: 0.2, release: 0.1, detune: 1.5),
            FMOperator(ratio: 1, level: 0.55, attack: 0.003, decay: 0.6, sustain: 0.35, release: 0.2, detune: 1.5),
        ],
        algorithm: 4, feedback: 0.4)

    // MARK: Song data

    /// Chord per bar: (root MIDI in the bass octave, major?). Two 8-bar sections:
    /// A = i – VI – VII – V over a pedal feel, B = iv – i – VI – V with the C→B drop.
    static let chords: [(root: Int, major: Bool)] = [
        (40, false), (40, false), (36, true), (38, true), (40, false), (40, false), (36, true), (35, true),
        (33, false), (40, false), (36, true), (35, true), (33, false), (40, false), (36, true), (35, true),
    ]

    /// Lead melody, one string per bar: `NOTE:steps` tokens, `-` for a rest.
    static let melody: [String] = [
        "E5:4 B4:2 E5:2 G5:4 F#5:2 E5:2",
        "D5:6 B4:2 D5:4 E5:4",
        "C5:4 E5:2 G5:2 A5:4 G5:2 E5:2",
        "D5:4 F#5:4 A5:6 -:2",
        "E5:4 B4:2 E5:2 G5:4 B5:4",
        "A5:2 G5:2 F#5:2 E5:2 D5:4 E5:4",
        "C5:4 E5:4 G5:4 A5:2 B5:2",
        "B4:4 D#5:4 F#5:4 B5:4",
        "A5:8 C6:4 B5:4",
        "G5:8 E5:8",
        "C6:6 B5:2 A5:4 G5:4",
        "F#5:8 D#5:8",
        "A5:4 B5:4 C6:4 E6:4",
        "D6:4 B5:4 G5:8",
        "A5:2 G5:2 E5:2 G5:2 A5:4 C6:4",
        "B5:12 -:4",
    ]

    /// Bass figure for one bar as (step, interval, steps). `third` is resolved per chord.
    static let bassFigure: [(step: Int, interval: Int, length: Int)] = [
        (0, 0, 2), (2, 0, 1), (3, 12, 1), (4, 0, 2), (6, 7, 1), (7, 12, 1),
        (8, 0, 2), (10, 0, 1), (11, 12, 1), (12, 0, 1), (13, 0, 1), (14, 10, 1), (15, 12, 1),
    ]
    static let bassWalkUp: [(step: Int, interval: Int, length: Int)] = [
        (12, 0, 1), (13, -1, 1), (14, 5, 1), (15, 7, 1),  // -1 = chord third
    ]

    // MARK: Render

    enum Layer: Int, CaseIterable {
        case drums, bass, chords, arp, lead
    }

    /// Render all five layers, one per core; each is peak-normalized to 0.9.
    static func render(sampleRate: Float) -> SongLayers {
        let results = OSAllocatedUnfairLock(initialState: [[Float]](repeating: [], count: Layer.allCases.count))
        DispatchQueue.concurrentPerform(iterations: Layer.allCases.count) { i in
            let layer = normalized(renderLayer(Layer(rawValue: i)!, sampleRate: sampleRate))
            results.withLock { $0[i] = layer }
        }
        let layers = results.withLock { $0 }
        return SongLayers(drums: layers[0], bass: layers[1], chords: layers[2], arp: layers[3], lead: layers[4])
    }

    static func renderLayer(_ layer: Layer, sampleRate: Float) -> [Float] {
        var out = [Float](repeating: 0, count: Int(loopSeconds * sampleRate))
        let stepSamples = Int(stepSeconds * sampleRate)
        func at(_ bar: Int, _ step: Int) -> Int { (bar * stepsPerBar + step) * stepSamples }

        for bar in 0..<bars {
            let chord = chords[bar]
            let third = chord.major ? 4 : 3
            let isSectionB = bar >= 8
            let isTurnaround = bar % 4 == 3

            switch layer {
            case .drums:
                // Rock backbeat, extra kick on odd bars, open hat before the bar line,
                // snare fill into each section change.
                for step in stride(from: 0, to: stepsPerBar, by: 2) {
                    let accent: Float = step % 4 == 0 ? 0.6 : 0.4
                    FMSynth.renderDrum(step == 14 ? .openHat : .closedHat, velocity: accent, sampleRate: sampleRate, into: &out, at: at(bar, step))
                }
                for step in [0, 8] + (bar % 2 == 1 ? [10] : []) {
                    FMSynth.renderDrum(.kick, velocity: 1, sampleRate: sampleRate, into: &out, at: at(bar, step))
                }
                let snares = bar % 8 == 7 ? [4, 12, 13, 14, 15] : [4, 12]
                for (n, step) in snares.enumerated() {
                    let velocity: Float = step == 4 || step == 12 ? 0.95 : 0.55 + Float(n) * 0.1
                    FMSynth.renderDrum(.snare, velocity: velocity, sampleRate: sampleRate, into: &out, at: at(bar, step))
                }

            case .bass:
                // Driving octave figure, walking up into every fourth bar.
                var figure = bassFigure
                if isTurnaround {
                    figure.removeAll { $0.step >= 12 }
                    figure += bassWalkUp
                }
                for note in figure {
                    let interval = note.interval == -1 ? third : note.interval
                    FMSynth.renderNote(bass, midi: chord.root + interval, gate: Float(note.length) * stepSeconds * 0.8,
                                       velocity: note.interval == 0 ? 1 : 0.85, sampleRate: sampleRate, into: &out, at: at(bar, note.step))
                }

            case .chords:
                // Offbeat e-piano stabs in A, held pads in B.
                let voicing = [chord.root + 19, chord.root + 24, chord.root + 24 + third]
                let hits: [(step: Int, length: Int)] = isSectionB ? [(0, 14)] : [(2, 2), (6, 2), (10, 2), (14, 2)]
                for hit in hits {
                    for midi in voicing {
                        FMSynth.renderNote(ePiano, midi: midi, gate: Float(hit.length) * stepSeconds * 0.9, velocity: 0.5,
                                           sampleRate: sampleRate, into: &out, at: at(bar, hit.step))
                    }
                }

            case .arp:
                // PSG square running a 6-note cycle over 16 steps so the accents drift.
                let cycle = [0, third, 7, 12, 7, third]
                for step in 0..<stepsPerBar {
                    let midi = chord.root + 24 + cycle[(bar * stepsPerBar + step) % cycle.count]
                    FMSynth.renderSquare(midi: midi, gate: stepSeconds * 0.9, decay: 0.07, velocity: 0.55,
                                         sampleRate: sampleRate, into: &out, at: at(bar, step))
                }

            case .lead:
                var step = 0
                for token in melody[bar].split(separator: " ") {
                    let parts = token.split(separator: ":")
                    let length = Int(parts[1])!
                    if parts[0] != "-" {
                        FMSynth.renderNote(lead, midi: midiNote(String(parts[0])), gate: Float(length) * stepSeconds * 0.85,
                                           velocity: 0.8, sampleRate: sampleRate, into: &out, at: at(bar, step))
                    }
                    step += length
                }
                precondition(step == stepsPerBar, "melody bar \(bar + 1) has \(step) steps, expected \(stepsPerBar)")
            }
        }
        return out
    }

    /// Finish a layer: strip sub-audio drift (FM feedback and 1:1 stacks leave a DC
    /// wobble, and the chip's output was capacitor-coupled anyway), then scale the
    /// peak to 0.9. The filter is primed with a pass over the loop so the seam is clean.
    private static func normalized(_ samples: [Float]) -> [Float] {
        var out = samples
        var previousInput: Float = 0
        var previousOutput: Float = 0
        for pass in 0..<2 {
            for i in out.indices {
                let input = samples[i]
                previousOutput = input - previousInput + 0.997 * previousOutput
                previousInput = input
                if pass == 1 { out[i] = previousOutput }
            }
        }
        let peak = out.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return out }
        let gain = 0.9 / peak
        return out.map { $0 * gain }
    }

    /// "C#5" → MIDI 73. Octave 4 is the middle octave (C4 = 60).
    static func midiNote(_ name: String) -> Int {
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        var chars = Array(name)
        let letter = letters[chars.removeFirst()]!
        var accidental = 0
        if chars.first == "#" { accidental = 1; chars.removeFirst() }
        if chars.first == "b" { accidental = -1; chars.removeFirst() }
        let octave = Int(String(chars))!
        return (octave + 1) * 12 + letter + accidental
    }

    /// Mix the layers at the in-game volumes into a single 16-bit mono WAV, for
    /// listening to the theme without launching the game (`--export-music`).
    static func exportWAV(layers: SongLayers, sampleRate: Float, path: String) -> Bool {
        let count = layers.drums.count
        var mixed = [Float](repeating: 0, count: count)
        for (layer, volume) in zip(layers.all, GameAudio.fullMix) {
            for i in 0..<count { mixed[i] += layer[i] * volume }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(byteCount + 36); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        let pcm = mixed.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return FileManager.default.createFile(atPath: path, contents: data)
    }
}
