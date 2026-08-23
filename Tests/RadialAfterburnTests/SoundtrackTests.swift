import Testing
@testable import RadialAfterburn

@Suite("Soundtrack")
struct SoundtrackTests {
    /// Low sample rate keeps the full-song render fast; the sequencer logic is identical.
    static let sampleRate: Float = 8_000

    @Test("Every layer renders the full loop, finite, bounded, and audible")
    func layersAreWellFormed() {
        let layers = Soundtrack.render(sampleRate: Self.sampleRate)
        let expected = Int(Soundtrack.loopSeconds * Self.sampleRate)
        for layer in layers.all {
            #expect(layer.count == expected)
            #expect(layer.allSatisfy { $0.isFinite && abs($0) <= 0.9001 })
            #expect(layer.contains { abs($0) > 0.5 })
        }
    }

    @Test("Layers carry no DC offset")
    func layersAreCentered() {
        let layers = Soundtrack.render(sampleRate: Self.sampleRate)
        for layer in layers.all {
            let mean = layer.reduce(0, +) / Float(layer.count)
            #expect(abs(mean) < 0.005)
        }
    }

    @Test("Note tails past the loop end wrap to the start")
    func tailsWrap() {
        var out = [Float](repeating: 0, count: 800)
        FMSynth.renderNote(Soundtrack.lead, midi: 69, gate: 0.05, velocity: 1, sampleRate: Self.sampleRate, into: &out, at: 700)
        #expect(out[..<100].contains { $0 != 0 })
    }

    @Test("All eight YM2612 algorithms produce bounded output")
    func algorithmsAreBounded() {
        for algorithm in 0..<8 {
            var patch = Soundtrack.lead
            patch.algorithm = algorithm
            var out = [Float](repeating: 0, count: 2_000)
            FMSynth.renderNote(patch, midi: 60, gate: 0.1, velocity: 1, sampleRate: Self.sampleRate, into: &out, at: 0)
            #expect(out.allSatisfy { $0.isFinite && abs($0) <= 4 })
            #expect(out.contains { abs($0) > 0.1 })
        }
    }

    @Test("Note names map to MIDI")
    func noteNames() {
        #expect(Soundtrack.midiNote("C4") == 60)
        #expect(Soundtrack.midiNote("A4") == 69)
        #expect(Soundtrack.midiNote("C#5") == 73)
        #expect(Soundtrack.midiNote("Bb3") == 58)
    }

    @Test("Music mix follows the game phase")
    func mixFollowsPhase() {
        let title = GameAudio.mix(phase: .title, wave: 1)
        let playing = GameAudio.mix(phase: .playing, wave: 1)
        let late = GameAudio.mix(phase: .playing, wave: 8)
        #expect(title[0] == 0 && title[4] == 0)
        #expect(playing[0] > 0 && playing[4] > 0)
        #expect(late[4] > playing[4])
        #expect(GameAudio.mix(phase: .paused, wave: 3).allSatisfy { $0 < 0.2 })
    }
}
