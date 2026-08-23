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
    /// Drawn lane position, eased toward `lane` so flipper lane changes slide.
    var visualLane: Float
}

/// One-frame gameplay events, accumulated until the renderer drains them to drive
/// audio. Kept on `GameState` (which stays Metal/audio-free) so it remains testable.
struct FrameEvents {
    var shotsFired = 0
    var explosions = 0
    var bigExplosions = 0
    var waveCleared = false
    var lifeLost = false
    var bonusLife = false
    var bombs = 0
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
    /// Screen-clearing bombs; refilled to `bombsPerWave` at the start of each wave.
    private(set) var bombs = 0
    static let bombsPerWave = 2
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
    private(set) var playerVisualLane: Float = 0
    /// Camera follow position: trails `playerVisualLane` on a slower ease so the
    /// view glides instead of lurching with every lane step.
    private(set) var cameraLane: Float = 0
    private(set) var cameraLaneVel: Float = 0
    private(set) var hitStop: Float = 0
    private(set) var events = FrameEvents()

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
        playerVisualLane = 0
        cameraLane = 0
        cameraLaneVel = 0
        hitStop = 0
        events = FrameEvents()
        nextBonusLife = 25_000
        random = SeededRandom(seed: 0x4e454f4e)
        beginWave()
    }

    /// Renderer reads `events` once per frame then drains; `update` only adds to it.
    mutating func drainEvents() { events = FrameEvents() }

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
        screenShake = min(1, screenShake + 0.01)
        events.shotsFired += 1
        shotCooldown = max(0.075, 0.15 - Float(wave) * 0.004)
    }

    /// Detonate a bomb: every enemy on screen explodes (tankers don't split), the
    /// combo ticks once, and the whole tube kicks.
    mutating func bomb() {
        guard phase == .playing, bombs > 0, !enemies.isEmpty else { return }
        bombs -= 1
        for enemy in enemies {
            score += enemy.kind.score * combo
            emitExplosion(lane: enemy.lane, depth: enemy.depth, kind: enemy.kind)
            events.explosions += 1
        }
        highScore = max(highScore, score)
        combo = min(combo + 1, 9)
        comboPulse = 1
        enemies.removeAll()
        flash = 1
        screenShake = 1
        tunnelKick = 1
        hitStop = max(hitStop, 0.16)
        events.bombs += 1
        emitShockwave(
            position: TunnelGeometry.worldPoint(lane: playerLane, depth: 0.06, wave: wave),
            radius: 0.1,
            speed: 3.2,
            life: 0.9,
            color: SIMD4(1, 0.85, 0.3, 1)
        )
        awardBonusLives()
    }

    mutating func update(deltaTime rawDeltaTime: Float) {
        let deltaTime = min(rawDeltaTime, 1 / 20)

        // Hit-stop: on heavy impacts the world crunches to a near-freeze for a few
        // frames while input and effects keep running, so hits land with weight.
        if hitStop > 0 { hitStop = max(0, hitStop - deltaTime) }
        let simDelta = hitStop > 0 ? deltaTime * 0.18 : deltaTime

        flash = max(0, flash - deltaTime * 2.8)
        screenShake = max(0, screenShake - deltaTime * 3.6)
        tunnelKick = max(0, tunnelKick - deltaTime * 2.2)
        comboPulse = max(0, comboPulse - deltaTime * 3.8)
        waveBanner = max(0, waveBanner - deltaTime)

        // Slide the drawn player position toward its lane along the shortest arc.
        playerVisualLane = easeLane(playerVisualLane, toward: Float(playerLane), dt: deltaTime, rate: 22)
        let prevCamera = cameraLane
        cameraLane = easeLane(cameraLane, toward: playerVisualLane, dt: deltaTime, rate: 5)
        cameraLaneVel = shortestLaneDelta(from: prevCamera, to: cameraLane) / max(deltaTime, 1e-4)

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
        spawnTimer -= simDelta

        if enemiesRemaining > 0, spawnTimer <= 0 {
            spawnEnemy()
            enemiesRemaining -= 1
            spawnTimer = max(0.16, 0.6 - Float(wave) * 0.03)
        }

        let enemySpeed = 0.075 + Float(wave) * 0.006
        for index in enemies.indices {
            enemies[index].depth -= enemySpeed * enemies[index].kind.speedMultiplier * simDelta
            enemies[index].phase += simDelta
            enemies[index].visualLane = easeLane(enemies[index].visualLane, toward: Float(enemies[index].lane), dt: deltaTime, rate: 13)

            if enemies[index].kind == .flipper,
               enemies[index].phase > max(0.35, 1.1 - Float(wave) * 0.025) {
                enemies[index].phase = 0
                let direction = random.nextBool() ? 1 : -1
                enemies[index].lane = wrappedLane(enemies[index].lane + direction)
            }
        }

        for index in shots.indices {
            shots[index].depth += (0.95 + Float(wave) * 0.012) * simDelta
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
            hitStop = max(hitStop, 0.07)
            events.waveCleared = true
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
        bombs = Self.bombsPerWave
        enemiesRemaining = 9 + wave * 4
        spawnTimer = wave == 1 ? 0.8 : 1.5
        // A few enemies start part-way down the tube so the wave engages sooner.
        for i in 0..<3 {
            spawnEnemy(depth: 0.72 + Float(i) * 0.1)
            enemiesRemaining -= 1
        }
    }

    private mutating func spawnEnemy(depth: Float = 1) {
        let roll = random.nextFloat()
        let kind: EnemyKind
        if wave >= 4, roll > 0.82 {
            kind = .tanker
        } else if wave >= 2, roll > 0.52 {
            kind = .flipper
        } else {
            kind = .spike
        }

        let lane = random.nextInt(upperBound: Self.laneCount)
        enemies.append(
            Enemy(
                id: UUID(),
                lane: lane,
                depth: depth,
                kind: kind,
                phase: random.nextFloat(),
                visualLane: Float(lane)
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
                events.bigExplosions += 1
                hitStop = max(hitStop, 0.09)
                let leftLane = wrappedLane(enemy.lane - 1)
                let rightLane = wrappedLane(enemy.lane + 1)
                spawnedEnemies.append(
                    Enemy(id: UUID(), lane: leftLane, depth: enemy.depth + 0.04, kind: .spike, phase: 0, visualLane: Float(leftLane))
                )
                spawnedEnemies.append(
                    Enemy(id: UUID(), lane: rightLane, depth: enemy.depth + 0.04, kind: .spike, phase: 0, visualLane: Float(rightLane))
                )
            } else {
                events.explosions += 1
                if combo >= 7 { hitStop = max(hitStop, 0.05) }
            }
        }

        enemies.removeAll { destroyedEnemies.contains($0.id) }
        enemies.append(contentsOf: spawnedEnemies)
        shots.removeAll { destroyedShots.contains($0.id) }
        awardBonusLives()
    }

    private mutating func awardBonusLives() {
        while score >= nextBonusLife {
            lives += 1
            nextBonusLife += 25_000
            events.bonusLife = true
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
        hitStop = max(hitStop, 0.12)
        events.lifeLost = true

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
            sparkCount = 30
            shockRadius = 0.04
            shockSpeed = 0.85
        case .flipper:
            sparkCount = 40
            shockRadius = 0.05
            shockSpeed = 1.0
        case .tanker:
            sparkCount = 64
            shockRadius = 0.08
            shockSpeed = 1.25
        }

        // Bright core flash: a fat, stationary, short-lived spark.
        sparks.append(
            Spark(
                id: UUID(),
                position: origin,
                velocity: SIMD3(0, 0, 0),
                life: 0.14,
                initialLife: 0.14,
                scale: kind == .tanker ? 9 : 6,
                color: SIMD4(1, 1, 1, 1) * 0.5 + color * 0.5
            )
        )

        emitShockwave(
            position: origin,
            radius: shockRadius,
            speed: shockSpeed,
            life: kind == .tanker ? 0.72 : 0.55,
            color: color
        )

        for index in 0..<sparkCount {
            let angle = random.nextFloat() * .pi * 2
            let speed = 0.2 + random.nextFloat() * (kind == .tanker ? 1.1 : 0.8)
            let life = 0.3 + random.nextFloat() * (kind == .tanker ? 0.8 : 0.6)
            let scale = 0.8 + random.nextFloat() * (index % 3 == 0 ? 2.2 : 1.3)
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

    /// Shortest signed lane distance around the ring, in (-laneCount/2, laneCount/2].
    private func shortestLaneDelta(from: Float, to: Float) -> Float {
        let n = Float(Self.laneCount)
        let d = to - from
        return d - (d / n).rounded() * n
    }

    /// Exponential ease of a lane position toward a target along the shortest arc,
    /// kept wrapped into [0, laneCount).
    private func easeLane(_ current: Float, toward target: Float, dt: Float, rate: Float) -> Float {
        let n = Float(Self.laneCount)
        var next = current + shortestLaneDelta(from: current, to: target) * (1 - exp(-dt * rate))
        next = next.truncatingRemainder(dividingBy: n)
        return next < 0 ? next + n : next
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
