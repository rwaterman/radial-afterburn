import AppKit
import MetalKit

@MainActor
final class GameViewController: NSViewController {
    private var gameView: MetalGameView!
    private let scoreLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let helpLabel = NSTextField(labelWithString: "←/A  MOVE   →/D  MOVE   SPACE  FIRE   B/↓  BOMB   P  PAUSE   M  MUSIC")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        do {
            gameView = try MetalGameView(gameFrame: view.bounds)
        } catch {
            let message = NSTextField(labelWithString: "Metal is unavailable on this Mac.")
            message.textColor = .systemRed
            message.font = .monospacedSystemFont(ofSize: 22, weight: .bold)
            message.alignment = .center
            message.frame = view.bounds
            message.autoresizingMask = [.width, .height]
            view.addSubview(message)
            return
        }

        gameView.autoresizingMask = [.width, .height]
        view.addSubview(gameView)

        configure(label: scoreLabel, size: 16, weight: .bold)
        scoreLabel.alignment = .left
        scoreLabel.translatesAutoresizingMaskIntoConstraints = false

        configure(label: statusLabel, size: 34, weight: .heavy)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        configure(label: helpLabel, size: 12, weight: .medium)
        helpLabel.textColor = NSColor(calibratedRed: 0.25, green: 0.85, blue: 1, alpha: 0.8)
        helpLabel.alignment = .center
        helpLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scoreLabel)
        view.addSubview(statusLabel)
        view.addSubview(helpLabel)

        NSLayoutConstraint.activate([
            scoreLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            scoreLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
            helpLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            helpLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18)
        ])

        gameView.renderer?.onHUDUpdate = { [weak self] game in
            self?.updateHUD(game)
        }
        updateHUD(GameState())
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(gameView)
    }

    private func configure(label: NSTextField, size: CGFloat, weight: NSFont.Weight) {
        label.font = .monospacedSystemFont(ofSize: size, weight: weight)
        label.textColor = NSColor(calibratedRed: 0.2, green: 0.95, blue: 1, alpha: 1)
        label.drawsBackground = false
        label.isBezeled = false
    }

    private func updateHUD(_ game: GameState) {
        let comboGlow = CGFloat(max(0, min(1, game.comboPulse)))
        scoreLabel.textColor = NSColor(
            calibratedRed: 0.2 + comboGlow * 0.8,
            green: 0.95,
            blue: 1 - comboGlow * 0.65,
            alpha: 1
        )
        scoreLabel.stringValue = String(
            format: "SCORE %08d   HIGH %08d   WAVE %02d   LIVES %d   BOMBS %d   ×%d",
            game.score,
            game.highScore,
            game.wave,
            game.lives,
            game.bombs,
            game.combo
        )

        switch game.phase {
        case .title:
            statusLabel.stringValue = "RADIAL AFTERBURN\n\nPRESS RETURN"
            statusLabel.textColor = NSColor(calibratedRed: 1, green: 0.12, blue: 0.62, alpha: 1)
        case .playing:
            if game.waveBanner > 0 {
                let bannerGlow = CGFloat(max(0, min(1, game.waveBanner)))
                statusLabel.stringValue = String(format: "WAVE %02d", game.wave)
                statusLabel.textColor = NSColor(
                    calibratedRed: 0.2 + bannerGlow * 0.8,
                    green: 1,
                    blue: 0.85,
                    alpha: 0.35 + bannerGlow * 0.65
                )
            } else {
                statusLabel.stringValue = ""
            }
        case .paused:
            statusLabel.stringValue = "PAUSED"
            statusLabel.textColor = .systemYellow
        case .gameOver:
            statusLabel.stringValue = "GAME OVER\n\nPRESS RETURN"
            statusLabel.textColor = .systemRed
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = GameViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = "Radial Afterburn"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let arguments = CommandLine.arguments
if let idx = arguments.firstIndex(of: "--export-music") {
    let path = idx + 1 < arguments.count ? arguments[idx + 1] : "theme.wav"
    let sampleRate = Float(GameAudio.sampleRate)
    let ok = Soundtrack.exportWAV(layers: Soundtrack.render(sampleRate: sampleRate), sampleRate: sampleRate, path: path)
    exit(ok ? 0 : 1)
}
func intArg(_ name: String, _ def: Int) -> Int {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count, let v = Int(arguments[i + 1]) else { return def }
    return v
}
if let idx = arguments.firstIndex(of: "--screenshot") {
    let path = idx + 1 < arguments.count ? arguments[idx + 1] : "screenshot.png"
    let ok = MainActor.assumeIsolated {
        runScreenshot(path: path, frames: intArg("--frames", 90), width: intArg("--width", 1100), height: intArg("--height", 760))
    }
    exit(ok ? 0 : 1)
}
if let idx = arguments.firstIndex(of: "--gif") {
    let path = idx + 1 < arguments.count ? arguments[idx + 1] : "demo.gif"
    let ok = MainActor.assumeIsolated {
        runGIF(path: path, seconds: intArg("--seconds", 6), width: intArg("--width", 550), height: intArg("--height", 380))
    }
    exit(ok ? 0 : 1)
}
if let idx = arguments.firstIndex(of: "--record") {
    let path = idx + 1 < arguments.count ? arguments[idx + 1] : "demo.mp4"
    let ok = MainActor.assumeIsolated {
        runRecording(path: path, seconds: intArg("--seconds", 30), width: intArg("--width", 1100), height: intArg("--height", 760))
    }
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
