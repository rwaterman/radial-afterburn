import AVFoundation
import CoreText
import Metal
import UniformTypeIdentifiers

/// Headless gameplay capture: a scripted player runs a deterministic game, every
/// frame is rendered offscreen with the HUD composited in, and the soundtrack plus
/// SFX are mixed offline to the same clock. Written as H.264 + AAC with
/// `AVAssetWriter`, so it needs no screen-recording permission and no ffmpeg.
@MainActor
func runRecording(path: String, seconds: Int, width: Int, height: Int) -> Bool {
    let fps = 60
    guard let renderer = makeHeadlessRenderer(),
          let run = simulate(renderer: renderer, seconds: seconds, fps: fps) else { return false }
    let sampleRate = GameAudio.sampleRate
    let samplesPerFrame = Int(sampleRate) / fps
    let hits = run.hits.map { (effect: $0.effect, sample: $0.frame * samplesPerFrame) }
    let audio = mixAudio(frames: run.snapshots.count, samplesPerFrame: samplesPerFrame, volumes: run.volumes, hits: hits, sampleRate: sampleRate)

    // Pass 2: encode video and audio as separate files, then mux. AVAssetWriter
    // deadlocks when one writer interleaves a polled video input with an AAC input
    // (the encoder's priming lag makes it hold the video side), so each input gets
    // its own writer and a passthrough export joins them without re-encoding.
    let url = URL(fileURLWithPath: path)
    let videoURL = url.appendingPathExtension("video.mp4")
    let audioURL = url.appendingPathExtension("audio.m4a")
    defer {
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: audioURL)
    }
    guard writeVideo(to: videoURL, renderer: renderer, snapshots: run.snapshots, width: width, height: height, fps: fps),
          writeAudio(to: audioURL, samples: audio, sampleRate: sampleRate),
          mux(video: videoURL, audio: audioURL, into: url)
    else { return false }
    return true
}

/// A wave-1 game takes several seconds before anything reaches the visible part of
/// the tunnel, so captures start `preroll` seconds into play and show the title
/// as a fading overlay instead of a wait.
private let prerollSeconds: Float = 8.5

/// "RADIAL AFTERBURN" overlay opacity: on for two seconds, then a half-second fade.
private func titleFade(frame: Int, fps: Int) -> CGFloat {
    let t = CGFloat(frame) / CGFloat(fps)
    return max(0, min(1, (2.5 - t) * 2))
}

struct SimulatedRun {
    var snapshots: [GameState]
    var volumes: [[Float]]
    var hits: [(effect: SoundEffect, frame: Int)]
}

@MainActor
private func makeHeadlessRenderer() -> Renderer? {
    guard let device = MTLCreateSystemDefaultDevice() else { _ = report("no Metal device", nil); return nil }
    do { return try Renderer(device: device, colorPixelFormat: .bgra8Unorm) } catch { _ = report("renderer", error); return nil }
}

/// Run the scripted player for `seconds`, after a pre-roll that is simulated but
/// not kept. Returns a snapshot per frame, the eased music mix per frame, and
/// the SFX that fired, for the renderer and the audio mixer to replay.
@MainActor
private func simulate(renderer: Renderer, seconds: Int, fps: Int) -> SimulatedRun? {
    let dt = 1 / Float(fps)
    let prerollFrames = Int(prerollSeconds * Float(fps))
    let frameCount = max(1, seconds * fps)
    var run = SimulatedRun(snapshots: [], volumes: [], hits: [])
    run.snapshots.reserveCapacity(frameCount)
    var mix = [Float](repeating: 0, count: GameAudio.fullMix.count)
    var player = ScriptedPlayer()
    renderer.game.start()
    for frame in -prerollFrames..<frameCount {
        player.act(on: &renderer.game, frame: frame)
        renderer.game.update(deltaTime: dt)
        GameAudio.ease(&mix, toward: GameAudio.mix(phase: renderer.game.phase, wave: renderer.game.wave), deltaTime: dt)
        if frame >= 0 {
            run.hits += SoundEffect.triggered(by: renderer.game.events).map { (effect: $0, frame: frame) }
            run.volumes.append(mix)
            run.snapshots.append(renderer.game)
        }
        renderer.game.drainEvents()
    }
    return run
}

/// Looping GIF of the busiest stretch of a scripted run: simulate a long game,
/// score every `seconds`-long window by explosions and wave clears, and encode
/// the winner with ImageIO.
@MainActor
func runGIF(path: String, seconds: Int, width: Int, height: Int) -> Bool {
    // Simulate at the game's 60 Hz so the run matches the video, output every 4th frame.
    let simFPS = 60, stride = 4
    guard let renderer = makeHeadlessRenderer(),
          let run = simulate(renderer: renderer, seconds: 45, fps: simFPS) else { return false }
    let window = max(1, seconds * simFPS)
    var score = [Int](repeating: 0, count: run.snapshots.count)
    for hit in run.hits {
        switch hit.effect {
        case .explosion: score[hit.frame] += 1
        case .bigExplosion: score[hit.frame] += 2
        case .bomb: score[hit.frame] += 12
        default: break
        }
    }
    // Wave 2 onward has flippers and the palette shift; wave 1 reads as tiny dots.
    let earliest = run.snapshots.firstIndex { $0.wave >= 2 } ?? 0
    var best = earliest, bestScore = -1, rolling = 0
    for frame in earliest..<score.count {
        rolling += score[frame]
        if frame >= earliest + window { rolling -= score[frame - window] }
        if frame >= earliest + window - 1, rolling > bestScore { bestScore = rolling; best = frame - window + 1 }
    }
    // A bomb is the showpiece: if one fired, frame it 60% of the way through the
    // loop so the build-up and the aftermath both show.
    let leadIn = window * 6 / 10
    if let bomb = run.hits.first(where: { $0.effect == .bomb && $0.frame - leadIn >= earliest })?.frame {
        best = min(bomb - leadIn, score.count - window)
    }
    let frames = Swift.stride(from: best, to: min(best + window, run.snapshots.count), by: stride)

    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.gif.identifier as CFString, frames.underestimatedCount, nil)
    else { return report("cannot create GIF at \(path)", nil) }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: Double(stride) / Double(simFPS)]] as CFDictionary
    for frame in frames {
        renderer.game = run.snapshots[frame]
        var bgra = renderer.renderSnapshot(width: width, height: height, time: Float(frame) / Float(simFPS))
        guard bgra.count == width * height * 4 else { return report("render failed at frame \(frame)", nil) }
        drawHUD(into: &bgra, width: width, height: height, game: run.snapshots[frame], titleAlpha: 0)
        guard let image = makeCGImage(bgra: bgra, width: width, height: height) else { return report("image failed at frame \(frame)", nil) }
        CGImageDestinationAddImage(destination, image, frameProperties)
    }
    return CGImageDestinationFinalize(destination) || report("GIF finalize failed", nil)
}

private func report(_ message: String, _ error: Error?) -> Bool {
    FileHandle.standardError.write(Data("record: \(message)\(error.map { ": \($0)" } ?? "")\n".utf8))
    return false
}

@MainActor
private func writeVideo(to url: URL, renderer: Renderer, snapshots: [GameState], width: Int, height: Int, fps: Int) -> Bool {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return report("cannot create video writer", nil) }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 2_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { return report("video writer", writer.error) }
    writer.startSession(atSourceTime: .zero)

    let dt = 1 / Float(fps)
    for (frame, snapshot) in snapshots.enumerated() {
        renderer.game = snapshot
        var bgra = renderer.renderSnapshot(width: width, height: height, time: Float(frame) * dt)
        guard bgra.count == width * height * 4 else { return report("render failed at frame \(frame)", nil) }
        drawHUD(into: &bgra, width: width, height: height, game: snapshot, titleAlpha: titleFade(frame: frame, fps: fps))

        guard let pool = adaptor.pixelBufferPool else { return report("no pixel buffer pool", writer.error) }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return report("no pixel buffer", nil) }
        CVPixelBufferLockBaseAddress(pb, [])
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        bgra.withUnsafeBytes { src in
            for row in 0..<height {
                memcpy(base + row * stride, src.baseAddress! + row * width * 4, width * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { return report("video writer", writer.error) }
            usleep(1_000)
        }
        guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
            return report("video append failed at frame \(frame)", writer.error)
        }
    }
    input.markAsFinished()
    return finish(writer)
}

private func writeAudio(to url: URL, samples: [Float], sampleRate: Double) -> Bool {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return report("cannot create audio writer", nil) }
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 160_000,
    ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    guard writer.startWriting() else { return report("audio writer", writer.error) }
    writer.startSession(atSourceTime: .zero)
    let chunk = Int(sampleRate)
    for start in stride(from: 0, to: samples.count, by: chunk) {
        let end = min(samples.count, start + chunk)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { return report("audio writer", writer.error) }
            usleep(1_000)
        }
        guard let buffer = audioSampleBuffer(Array(samples[start..<end]), startSample: start, sampleRate: sampleRate),
              input.append(buffer) else { return report("audio append failed at sample \(start)", writer.error) }
    }
    input.markAsFinished()
    return finish(writer)
}

private func finish(_ writer: AVAssetWriter) -> Bool {
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    return writer.status == .completed || report("finish failed", writer.error)
}

/// Join the two tracks with a passthrough export: H.264 and AAC are copied as-is.
private func mux(video videoURL: URL, audio audioURL: URL, into url: URL) -> Bool {
    final class Outcome: @unchecked Sendable { var ok = false }
    let outcome = Outcome()
    let done = DispatchSemaphore(value: 0)
    Task {
        defer { done.signal() }
        do {
            let composition = AVMutableComposition()
            for (source, mediaType) in [(videoURL, AVMediaType.video), (audioURL, .audio)] {
                let asset = AVURLAsset(url: source)
                guard let sourceTrack = try await asset.loadTracks(withMediaType: mediaType).first,
                      let track = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { _ = report("missing \(mediaType.rawValue) track", nil); return }
                let range = try await sourceTrack.load(.timeRange)
                try track.insertTimeRange(range, of: sourceTrack, at: .zero)
            }
            try? FileManager.default.removeItem(at: url)
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                _ = report("cannot create export session", nil); return
            }
            if #available(macOS 15, *) {
                try await export.export(to: url, as: .mp4)
            } else {
                export.outputURL = url
                export.outputFileType = .mp4
                await export.export()
                if let error = export.error { throw error }
            }
            outcome.ok = true
        } catch {
            _ = report("mux failed", error)
        }
    }
    // The task runs on the main actor, so keep the run loop turning while we wait.
    while done.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    return outcome.ok
}

/// Plays like a decent human rather than an aimbot: lets enemies come into view
/// before engaging, sticks with a target instead of flicking between them, and
/// only fires when lined up.
private struct ScriptedPlayer {
    private var targetID: UUID?

    mutating func act(on game: inout GameState, frame: Int) {
        switch game.phase {
        case .title, .gameOver:
            game.start()
            return
        case .paused, .playing:
            break
        }
        let engageDepth: Float = 0.42
        // Panic bomb: several enemies about to breach, or the tube is swarming.
        let nearRim = game.enemies.filter { $0.depth < 0.22 }.count
        let visible = game.enemies.filter { $0.depth < 0.55 }.count
        if game.bombs > 0, nearRim >= 2 || visible >= 4 {
            game.bomb()
            targetID = nil
            return
        }
        if let id = targetID, !game.enemies.contains(where: { $0.id == id }) { targetID = nil }
        if targetID == nil {
            targetID = game.enemies.filter { $0.depth < engageDepth }.min(by: { $0.depth < $1.depth })?.id
        }
        guard let target = game.enemies.first(where: { $0.id == targetID }) else { return }
        let n = GameState.laneCount
        var delta = (target.lane - game.playerLane) % n
        if delta > n / 2 { delta -= n }
        if delta < -n / 2 { delta += n }
        if delta != 0 {
            game.move(delta > 0 ? 1 : -1)
        } else if frame % 6 == 0 {
            game.fire()
        }
    }
}

/// Music layers looped under the per-frame mix, SFX dropped in at their sample
/// positions, scaled like the live mixer's output volume.
private func mixAudio(frames: Int, samplesPerFrame: Int, volumes: [[Float]], hits: [(effect: SoundEffect, sample: Int)], sampleRate: Double) -> [Float] {
    let layers = Soundtrack.render(sampleRate: Float(sampleRate)).all
    let loop = layers[0].count
    let total = frames * samplesPerFrame
    var out = [Float](repeating: 0, count: total)
    for frame in 0..<frames {
        let from = volumes[frame]
        let to = volumes[min(frame + 1, frames - 1)]
        for s in 0..<samplesPerFrame {
            let i = frame * samplesPerFrame + s
            let blend = Float(s) / Float(samplesPerFrame)
            var sample: Float = 0
            for (layerIndex, layer) in layers.enumerated() {
                sample += layer[i % loop] * (from[layerIndex] + (to[layerIndex] - from[layerIndex]) * blend)
            }
            out[i] = sample
        }
    }
    var rendered: [SoundEffect: [Float]] = [:]
    for hit in hits {
        let samples = rendered[hit.effect] ?? hit.effect.render(sampleRate: sampleRate)
        rendered[hit.effect] = samples
        for (offset, value) in samples.enumerated() where hit.sample + offset < total {
            out[hit.sample + offset] += value * hit.effect.volume
        }
    }
    return out.map { max(-1, min(1, $0 * 0.85)) }
}

private func audioSampleBuffer(_ samples: [Float], startSample: Int, sampleRate: Double) -> CMSampleBuffer? {
    var description = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    let byteCount = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
    guard let format, let block else { return nil }
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
    var sampleBuffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
        presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate)),
        packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
    return sampleBuffer
}

/// Composite the same HUD the AppKit window shows (score line, status banner,
/// help bar) onto a BGRA frame with CoreText.
private func drawHUD(into bgra: inout [UInt8], width: Int, height: Int, game: GameState, titleAlpha: CGFloat) {
    bgra.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // CoreGraphics' origin is bottom-left; `y` below is measured from the top.
        func draw(_ text: String, size: CGFloat, bold: Bool, color: CGColor, x: CGFloat?, y: CGFloat) {
            let font = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo") as CFString, size, nil)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
            for (index, lineText) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, String(lineText) as CFString, attributes))
                let bounds = CTLineGetBoundsWithOptions(line, [])
                let lineX = x ?? (CGFloat(width) - bounds.width) / 2
                ctx.textPosition = CGPoint(x: lineX, y: CGFloat(height) - y - CGFloat(index) * size * 1.25)
                CTLineDraw(line, ctx)
            }
        }

        let comboGlow = CGFloat(max(0, min(1, game.comboPulse)))
        let scoreColor = CGColor(red: 0.2 + comboGlow * 0.8, green: 0.95, blue: 1 - comboGlow * 0.65, alpha: 1)
        // Small frames (GIF) get a compact score line and no help bar.
        let compact = width < 800
        let scoreLine = compact
            ? String(format: "SCORE %08d   WAVE %02d   BOMBS %d   ×%d", game.score, game.wave, game.bombs, game.combo)
            : String(format: "SCORE %08d   HIGH %08d   WAVE %02d   LIVES %d   BOMBS %d   ×%d", game.score, game.highScore, game.wave, game.lives, game.bombs, game.combo)
        draw(scoreLine, size: compact ? 13 : 16, bold: true, color: scoreColor, x: compact ? 14 : 24, y: compact ? 26 : 36)
        if !compact {
            draw("←/A  MOVE   →/D  MOVE   SPACE  FIRE   CTRL/⌥  BOMB   P  PAUSE   M  MUSIC",
                 size: 12, bold: false, color: CGColor(red: 0.25, green: 0.85, blue: 1, alpha: 0.8), x: nil, y: CGFloat(height) - 22)
        }

        let centerY = CGFloat(height) / 2 - 20
        if titleAlpha > 0 {
            draw("RADIAL AFTERBURN", size: 44, bold: true, color: CGColor(red: 1, green: 0.12, blue: 0.62, alpha: titleAlpha), x: nil, y: centerY - 60)
        }
        switch game.phase {
        case .title:
            draw("RADIAL AFTERBURN\n\nPRESS RETURN", size: 34, bold: true, color: CGColor(red: 1, green: 0.12, blue: 0.62, alpha: 1), x: nil, y: centerY - 34)
        case .playing where game.waveBanner > 0 && titleAlpha == 0:
            let glow = CGFloat(max(0, min(1, game.waveBanner)))
            draw(String(format: "WAVE %02d", game.wave), size: 34, bold: true,
                 color: CGColor(red: 0.2 + glow * 0.8, green: 1, blue: 0.85, alpha: 0.35 + glow * 0.65), x: nil, y: centerY)
        case .paused:
            draw("PAUSED", size: 34, bold: true, color: CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1), x: nil, y: centerY)
        case .gameOver:
            draw("GAME OVER\n\nPRESS RETURN", size: 34, bold: true, color: CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 1), x: nil, y: centerY - 34)
        case .playing:
            break
        }
    }
}
