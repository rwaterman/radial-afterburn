import Testing
@testable import NeonVortex

@Suite("Game state")
struct GameStateTests {
    @Test("Starting resets the game")
    func startResetsState() {
        var game = GameState()
        game.start()

        #expect(game.phase == .playing)
        #expect(game.score == 0)
        #expect(game.lives == 3)
        #expect(game.wave == 1)
    }

    @Test("Player movement wraps around the tube")
    func movementWraps() {
        var game = GameState()
        game.start()
        game.move(-1)

        #expect(game.playerLane == GameState.laneCount - 1)
    }

    @Test("Firing creates a shot")
    func firingCreatesShot() {
        var game = GameState()
        game.start()
        game.fire()

        #expect(game.shots.count == 1)
        #expect(game.shots[0].lane == game.playerLane)
    }

    @Test("Pause freezes simulation")
    func pauseFreezesSimulation() {
        var game = GameState()
        game.start()
        game.fire()
        let depth = game.shots[0].depth
        game.togglePause()
        game.update(deltaTime: 1)

        #expect(game.phase == .paused)
        #expect(game.shots[0].depth == depth)
    }

    @Test("Seeded random is reproducible")
    func randomIsReproducible() {
        var first = SeededRandom(seed: 42)
        var second = SeededRandom(seed: 42)

        #expect(first.next() == second.next())
        #expect(first.next() == second.next())
    }
}
