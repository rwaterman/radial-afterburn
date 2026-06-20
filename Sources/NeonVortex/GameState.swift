import Foundation
import simd

enum GamePhase: Equatable {
    case title
    case playing
    case paused
    case gameOver
}

enum EnemyKind: CaseIterable {
    case spike
    case flipper
    case tanker

    var speedMultiplier: Float {
        switch self {
        case .spike: 1
        case .flipper: 0.82
        case .tanker: 0.62
        }
    }

    var score: Int {
        switch self {
        case .spike: 100
        case .flipper: 250
        case .tanker: 500
        }
    }
}

struct Enemy: Identifiable {
    let id: UUID
    var lane: Int
    var depth: Float
    var kind: EnemyKind
    var phase: Float
}

struct Shot: Identifiable {
    let id: UUID
    var lane: Int
    var depth: Float
}

struct Spark: Identifiable {
    let id: UUID
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var life: Float
    var color: SIMD4<Float>
}

struct GameState {
    static let laneCount = 16

    private(set) var phase: GamePhase = .title
    private(set) var playerLane = 0
    private(set) var score = 0
    private(set) var highScore = 0
    private(set) var lives = 3
    private(set) var wave = 1
    private(set) var enemies: [Enemy] = []
    private(set) var shots: [Shot] = []
    private(set) var sparks: [Spark] = []
    private(set) var flash: Float = 0
    private(set) var combo = 1

    private var spawnTimer: Float = 0
    private var enemiesRemaining = 0
    private var shotCooldown: Float = 0
    private var laneMoveCooldown: Float = 0
    private var nextBonusLife = 25_000
    private var random = SeededRandom(seed: 0x4e454f4e)

    mutating func start() {
        phase = .playing
        playerLane = 0
        score = 0
        lives = 3
        wave = 1
        enemies = []
        shots = []
        sparks = []
        flash = 0
        combo = 1
        nextBonusLife = 25_000
        random = SeededRandom(seed: 0x4e454f4e)
        beginWave()
    }

    mutating func togglePause() {
        switch phase {
        case .playing: phase = .paused
        case .paused: phase = .playing
        default: break
        }
    }

    mutating func move(_ direction: Int) {
        guard phase == .playing, laneMoveCooldown <= 0 else { return }
        playerLane = wrappedLane(playerLane + direction)
        laneMoveCooldown = 0.075
    }

    mutating func fire() {
        guard phase == .playing, shotCooldown <= 0 else { return }
        shots.append(Shot(id: UUID(), lane: playerLane, depth: 0.04))
        shotCooldown = max(0.075, 0.15 - Float(wave) * 0.004)
    }

    mutating func update(deltaTime rawDeltaTime: Float) {
        let deltaTime = min(rawDeltaTime, 1 / 20)
        flash = max(0, flash - deltaTime * 2.8)
        sparks = sparks.compactMap { spark in
            var next = spark
            next.position += next.velocity * deltaTime
            next.velocity *= max(0, 1 - deltaTime * 2)
            next.life -= deltaTime
            return next.life > 0 ? next : nil
        }

        guard phase == .playing else { return }

        shotCooldown -= deltaTime
        laneMoveCooldown -= deltaTime
        spawnTimer -= deltaTime

        if enemiesRemaining > 0, spawnTimer <= 0 {
            spawnEnemy()
            enemiesRemaining -= 1
            spawnTimer = max(0.18, 0.72 - Float(wave) * 0.035)
        }

        let enemySpeed = 0.075 + Float(wave) * 0.006
        for index in enemies.indices {
            enemies[index].depth -= enemySpeed * enemies[index].kind.speedMultiplier * deltaTime
            enemies[index].phase += deltaTime

            if enemies[index].kind == .flipper,
               enemies[index].phase > max(0.35, 1.1 - Float(wave) * 0.025) {
                enemies[index].phase = 0
                let direction = random.nextBool() ? 1 : -1
                enemies[index].lane = wrappedLane(enemies[index].lane + direction)
            }
        }

        for index in shots.indices {
            shots[index].depth += (0.95 + Float(wave) * 0.012) * deltaTime
        }
        shots.removeAll { $0.depth > 1.05 }

        resolveCollisions()
        resolveBreaches()

        if enemiesRemaining == 0, enemies.isEmpty {
            wave += 1
            combo = 1
            flash = 0.8
            beginWave()
        }
    }

    private mutating func beginWave() {
        enemiesRemaining = 7 + wave * 3
        spawnTimer = wave == 1 ? 0.8 : 1.5
    }

    private mutating func spawnEnemy() {
        let roll = random.nextFloat()
        let kind: EnemyKind
        if wave >= 4, roll > 0.82 {
            kind = .tanker
        } else if wave >= 2, roll > 0.52 {
            kind = .flipper
        } else {
            kind = .spike
        }

        enemies.append(
            Enemy(
                id: UUID(),
                lane: random.nextInt(upperBound: Self.laneCount),
                depth: 1,
                kind: kind,
                phase: random.nextFloat()
            )
        )
    }

    private mutating func resolveCollisions() {
        var destroyedEnemies = Set<UUID>()
        var destroyedShots = Set<UUID>()
        var spawnedEnemies: [Enemy] = []

        for shot in shots {
            guard let enemy = enemies
                .filter({ $0.lane == shot.lane && !destroyedEnemies.contains($0.id) })
                .min(by: { abs($0.depth - shot.depth) < abs($1.depth - shot.depth) }),
                  abs(enemy.depth - shot.depth) < 0.055 else { continue }

            destroyedEnemies.insert(enemy.id)
            destroyedShots.insert(shot.id)
            score += enemy.kind.score * combo
            highScore = max(highScore, score)
            combo = min(combo + 1, 9)
            flash = min(1, flash + 0.14)
            emitExplosion(lane: enemy.lane, depth: enemy.depth, kind: enemy.kind)

            if enemy.kind == .tanker {
                spawnedEnemies.append(
                    Enemy(id: UUID(), lane: wrappedLane(enemy.lane - 1), depth: enemy.depth + 0.04, kind: .spike, phase: 0)
                )
                spawnedEnemies.append(
                    Enemy(id: UUID(), lane: wrappedLane(enemy.lane + 1), depth: enemy.depth + 0.04, kind: .spike, phase: 0)
                )
            }
        }

        enemies.removeAll { destroyedEnemies.contains($0.id) }
        enemies.append(contentsOf: spawnedEnemies)
        shots.removeAll { destroyedShots.contains($0.id) }

        while score >= nextBonusLife {
            lives += 1
            nextBonusLife += 25_000
        }
    }

    private mutating func resolveBreaches() {
        let breached = enemies.filter { $0.depth <= 0.025 }
        guard !breached.isEmpty else { return }

        for enemy in breached {
            emitExplosion(lane: enemy.lane, depth: 0.02, kind: enemy.kind)
        }
        enemies.removeAll { $0.depth <= 0.025 }
        shots.removeAll()
        combo = 1
        lives -= 1
        flash = 1

        if lives <= 0 {
            phase = .gameOver
        } else {
            playerLane = wrappedLane(playerLane + Self.laneCount / 2)
            spawnTimer = max(spawnTimer, 1)
        }
    }

    private mutating func emitExplosion(lane: Int, depth: Float, kind: EnemyKind) {
        let origin = tunnelPoint(lane: lane, depth: depth)
        let color: SIMD4<Float>
        switch kind {
        case .spike: color = SIMD4(1, 0.18, 0.55, 1)
        case .flipper: color = SIMD4(1, 0.72, 0.05, 1)
        case .tanker: color = SIMD4(0.2, 0.9, 1, 1)
        }

        for _ in 0..<12 {
            let angle = random.nextFloat() * .pi * 2
            let speed = 0.08 + random.nextFloat() * 0.32
            sparks.append(
                Spark(
                    id: UUID(),
                    position: origin,
                    velocity: SIMD2(cos(angle), sin(angle)) * speed,
                    life: 0.25 + random.nextFloat() * 0.5,
                    color: color
                )
            )
        }
    }

    func tunnelPoint(lane: Int, depth: Float) -> SIMD2<Float> {
        let angle = Float(lane) / Float(Self.laneCount) * .pi * 2 - .pi / 2
        let radius = 0.91 * (1 - depth) + 0.09
        let center = SIMD2<Float>(sin(Float(wave) * 0.31) * 0.035, cos(Float(wave) * 0.23) * 0.025)
        return center * depth + SIMD2(cos(angle), sin(angle)) * radius
    }

    private func wrappedLane(_ lane: Int) -> Int {
        (lane % Self.laneCount + Self.laneCount) % Self.laneCount
    }
}

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    mutating func nextFloat() -> Float {
        Float(next() & 0x00ff_ffff) / Float(0x0100_0000)
    }

    mutating func nextInt(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }

    mutating func nextBool() -> Bool {
        next() & 1 == 0
    }
}
