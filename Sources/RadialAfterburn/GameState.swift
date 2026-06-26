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

struct MuzzleFlash: Identifiable {
    let id: UUID
    var lane: Int
    var life: Float
    var initialLife: Float
}

struct Spark: Identifiable {
    let id: UUID
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var life: Float
    var initialLife: Float
    var scale: Float
    var color: SIMD4<Float>
}

struct Shockwave: Identifiable {
    let id: UUID
    var position: SIMD3<Float>
    var radius: Float
    var speed: Float
    var life: Float
    var initialLife: Float
    var color: SIMD4<Float>
}

struct GameState {
    static let laneCount = TunnelGeometry.laneCount

    private(set) var phase: GamePhase = .title
    private(set) var playerLane = 0
    private(set) var score = 0
    private(set) var highScore = 0
    private(set) var lives = 3
    private(set) var wave = 1
    private(set) var enemies: [Enemy] = []
    private(set) var shots: [Shot] = []
    private(set) var muzzleFlashes: [MuzzleFlash] = []
    private(set) var sparks: [Spark] = []
    private(set) var shockwaves: [Shockwave] = []
    private(set) var flash: Float = 0
    private(set) var combo = 1
    private(set) var screenShake: Float = 0
    private(set) var tunnelKick: Float = 0
    private(set) var comboPulse: Float = 0
    private(set) var waveBanner: Float = 0

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
        muzzleFlashes = []
        sparks = []
        shockwaves = []
        flash = 0
        combo = 1
        screenShake = 0
        tunnelKick = 0
        comboPulse = 0
        waveBanner = 0
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
        muzzleFlashes.append(MuzzleFlash(id: UUID(), lane: playerLane, life: 0.12, initialLife: 0.12))
        screenShake = min(1, screenShake + 0.025)
        shotCooldown = max(0.075, 0.15 - Float(wave) * 0.004)
    }

    mutating func update(deltaTime rawDeltaTime: Float) {
        let deltaTime = min(rawDeltaTime, 1 / 20)
        flash = max(0, flash - deltaTime * 2.8)
        screenShake = max(0, screenShake - deltaTime * 3.6)
        tunnelKick = max(0, tunnelKick - deltaTime * 2.2)
        comboPulse = max(0, comboPulse - deltaTime * 3.8)
        waveBanner = max(0, waveBanner - deltaTime)
        muzzleFlashes = muzzleFlashes.compactMap { flash in
            var next = flash
            next.life -= deltaTime
            return next.life > 0 ? next : nil
        }
        sparks = sparks.compactMap { spark in
            var next = spark
            next.position += next.velocity * deltaTime
            next.velocity *= max(0, 1 - deltaTime * 1.8)
            next.life -= deltaTime
            return next.life > 0 ? next : nil
        }
        shockwaves = shockwaves.compactMap { shockwave in
            var next = shockwave
            next.radius += next.speed * deltaTime
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
            screenShake = min(1, screenShake + 0.18)
            tunnelKick = min(1, tunnelKick + 0.7)
            waveBanner = 1.25
            emitShockwave(
                position: SIMD3<Float>(0, 0, TunnelGeometry.depthZ(0.5)),
                radius: 0.12,
                speed: 2.4,
                life: 0.8,
                color: SIMD4(0.2, 1, 0.95, 1)
            )
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
            comboPulse = min(1, comboPulse + 0.18 + Float(combo) * 0.025)
            flash = min(1, flash + 0.1 + Float(combo) * 0.012)
            screenShake = min(1, screenShake + shakeAmount(for: enemy.kind) + Float(combo) * 0.004)
            tunnelKick = min(1, tunnelKick + kickAmount(for: enemy.kind))
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
        screenShake = 1
        tunnelKick = 1

        if lives <= 0 {
            phase = .gameOver
        } else {
            playerLane = wrappedLane(playerLane + Self.laneCount / 2)
            spawnTimer = max(spawnTimer, 1)
        }
    }

    private mutating func emitExplosion(lane: Int, depth: Float, kind: EnemyKind) {
        let origin = TunnelGeometry.worldPoint(lane: lane, depth: depth, wave: wave)
        let color: SIMD4<Float>
        switch kind {
        case .spike: color = SIMD4(1, 0.18, 0.55, 1)
        case .flipper: color = SIMD4(1, 0.72, 0.05, 1)
        case .tanker: color = SIMD4(0.2, 0.9, 1, 1)
        }

        let sparkCount: Int
        let shockRadius: Float
        let shockSpeed: Float
        switch kind {
        case .spike:
            sparkCount = 18
            shockRadius = 0.035
            shockSpeed = 0.72
        case .flipper:
            sparkCount = 24
            shockRadius = 0.045
            shockSpeed = 0.9
        case .tanker:
            sparkCount = 40
            shockRadius = 0.07
            shockSpeed = 1.12
        }

        emitShockwave(
            position: origin,
            radius: shockRadius,
            speed: shockSpeed,
            life: kind == .tanker ? 0.72 : 0.55,
            color: color
        )

        for index in 0..<sparkCount {
            let angle = random.nextFloat() * .pi * 2
            let speed = 0.18 + random.nextFloat() * (kind == .tanker ? 0.9 : 0.62)
            let life = 0.28 + random.nextFloat() * (kind == .tanker ? 0.72 : 0.52)
            let scale = 0.7 + random.nextFloat() * (index % 3 == 0 ? 1.9 : 1.1)
            let zKick = (random.nextFloat() - 0.5) * speed * 0.6
            sparks.append(
                Spark(
                    id: UUID(),
                    position: origin,
                    velocity: SIMD3(cos(angle) * speed, sin(angle) * speed, zKick),
                    life: life,
                    initialLife: life,
                    scale: scale,
                    color: color
                )
            )
        }
    }

    private mutating func emitShockwave(
        position: SIMD3<Float>,
        radius: Float,
        speed: Float,
        life: Float,
        color: SIMD4<Float>
    ) {
        shockwaves.append(
            Shockwave(
                id: UUID(),
                position: position,
                radius: radius,
                speed: speed,
                life: life,
                initialLife: life,
                color: color
            )
        )
    }

    private func shakeAmount(for kind: EnemyKind) -> Float {
        switch kind {
        case .spike: 0.05
        case .flipper: 0.07
        case .tanker: 0.14
        }
    }

    private func kickAmount(for kind: EnemyKind) -> Float {
        switch kind {
        case .spike: 0.12
        case .flipper: 0.18
        case .tanker: 0.32
        }
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
