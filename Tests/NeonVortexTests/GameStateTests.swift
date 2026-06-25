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

    @Test("Firing creates muzzle flash and kick")
    func firingCreatesMuzzleFlashAndKick() {
        var game = GameState()
        game.start()
        game.fire()

        #expect(game.muzzleFlashes.count == 1)
        #expect(game.muzzleFlashes[0].lane == game.playerLane)
        #expect(game.screenShake > 0)
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

    @Test("Starting resets transient effects")
    func startResetsTransientEffects() {
        var game = GameState()
        game.start()
        game.fire()

        #expect(!game.muzzleFlashes.isEmpty)
        #expect(game.screenShake > 0)

        game.start()

        #expect(game.muzzleFlashes.isEmpty)
        #expect(game.sparks.isEmpty)
        #expect(game.shockwaves.isEmpty)
        #expect(game.screenShake == 0)
        #expect(game.tunnelKick == 0)
        #expect(game.comboPulse == 0)
        #expect(game.waveBanner == 0)
    }

    @Test("Destroying an enemy creates spectacle effects")
    func enemyKillCreatesEffects() {
        var game = GameState()
        destroyFirstEnemy(in: &game)

        #expect(game.score > 0)
        #expect(!game.sparks.isEmpty)
        #expect(!game.shockwaves.isEmpty)
        #expect(game.screenShake > 0)
        #expect(game.tunnelKick > 0)
        #expect(game.comboPulse > 0)
    }

    @Test("Transient effects decay and expire")
    func transientEffectsDecayAndExpire() {
        var game = GameState()
        destroyFirstEnemy(in: &game)

        #expect(!game.sparks.isEmpty)
        #expect(!game.shockwaves.isEmpty)
        #expect(game.screenShake > 0)

        for _ in 0..<80 {
            game.update(deltaTime: 0.05)
        }

        #expect(game.muzzleFlashes.isEmpty)
        #expect(game.sparks.isEmpty)
        #expect(game.shockwaves.isEmpty)
        #expect(game.screenShake == 0)
        #expect(game.tunnelKick == 0)
        #expect(game.comboPulse == 0)
    }

    @Test("Seeded random is reproducible")
    func randomIsReproducible() {
        var first = SeededRandom(seed: 42)
        var second = SeededRandom(seed: 42)

        #expect(first.next() == second.next())
        #expect(first.next() == second.next())
    }

    @Test("Explosion sparks originate inside the tunnel's Z range")
    func sparksAreInTunnelSpace() {
        var game = GameState()
        destroyFirstEnemy(in: &game)

        #expect(!game.sparks.isEmpty)
        for spark in game.sparks {
            #expect(spark.position.z <= TunnelGeometry.nearZ + 0.01)
            #expect(spark.position.z >= TunnelGeometry.farZ - 0.01)
        }
    }

    private func destroyFirstEnemy(in game: inout GameState) {
        game.start()
        while game.enemies.isEmpty {
            game.update(deltaTime: 0.05)
        }

        let targetLane = game.enemies[0].lane
        movePlayer(to: targetLane, in: &game)
        game.fire()

        for _ in 0..<80 where game.score == 0 {
            game.update(deltaTime: 0.05)
        }
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
