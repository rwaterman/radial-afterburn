import AppKit
import MetalKit

@MainActor
final class MetalGameView: MTKView, MTKViewDelegate {
    private(set) var renderer: Renderer?
    private var audio: GameAudio?
    private var heldKeys = Set<UInt16>()
    private var inputTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    convenience init(gameFrame: CGRect) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.metalUnavailable
        }
        self.init(frame: gameFrame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0.008, 1)
        preferredFramesPerSecond = 120
        enableSetNeedsDisplay = false
        isPaused = false
        framebufferOnly = true
        renderer = try Renderer(device: device, colorPixelFormat: colorPixelFormat)
        let audio = GameAudio()
        self.audio = audio
        renderer?.audio = audio
        delegate = self
        inputTimer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.processHeldKeys()
            }
        }
    }

    func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func keyDown(with event: NSEvent) {
        if event.isARepeat {
            heldKeys.insert(event.keyCode)
            return
        }

        heldKeys.insert(event.keyCode)
        switch event.keyCode {
        case 36, 76:
            // Return starts a game from the title or game-over screen only, so a
            // stray press mid-run can't wipe a good score.
            if renderer?.game.phase != .playing { renderer?.game.start() }
        case 35:
            renderer?.game.togglePause()
        case 46:
            audio?.toggleMusic()
        case 49:
            renderer?.game.fire()
        case 53:
            NSApplication.shared.terminate(nil)
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        heldKeys.remove(event.keyCode)
    }

    /// keyUp never arrives for keys held while focus moves away; forget them so the
    /// ship doesn't keep sliding or firing when focus returns.
    override func resignFirstResponder() -> Bool {
        heldKeys.removeAll()
        return super.resignFirstResponder()
    }

    private func processHeldKeys() {
        if heldKeys.contains(123) || heldKeys.contains(0) {
            renderer?.game.move(-1)
        }
        if heldKeys.contains(124) || heldKeys.contains(2) {
            renderer?.game.move(1)
        }
        if heldKeys.contains(49) {
            renderer?.game.fire()
        }
    }
}
