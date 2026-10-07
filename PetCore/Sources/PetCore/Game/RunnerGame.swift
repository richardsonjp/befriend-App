//
//  RunnerGame.swift
//  PetCore
//
//  Desktop Runner (M42): the friend runs and jumps across the words on the Mac's screen. Every word the Mac reads
//  (OCR) is a ledge to stand on; drop through one to the line below, jump (and once more in mid-air) to the one above,
//  collect coins and stay above the lava that rises in waves. Pure rules, like `CatchGame`: y grows downwards, 0 is
//  the top of the screen, and the friend's position is its feet.
//

import CoreGraphics
import Foundation

public nonisolated struct RunnerGame: Sendable {
    /// A surface the friend can land on from above: the top of a word, or one of the game's clouds.
    public struct Ledge: Equatable, Sendable {
        public var minX: Double
        public var maxX: Double
        public var y: Double
        public var isCloud = false
    }

    public struct Coin: Equatable, Sendable {
        public var x: Double
        public var y: Double
    }

    public enum Event: Equatable, Sendable {
        case coin(x: Double, y: Double)
        case burned(x: Double)
        case over
    }

    public static let friendSize = 64.0
    public static let coinSize = 32.0
    public static let startLives = 3
    static let runSpeed = 520.0
    static let gravity = 2800.0
    static let jumpSpeed = 900.0 // about 145 points high when held: a few lines of text
    static let airJumpSpeed = 800.0
    static let jumpCut = 0.45 // letting go early keeps this much of the rise
    static let maxFall = 1800.0
    static let maxCoins = 5
    static let coinInterval = 1.2
    /// Feet this far past a ledge's end still stand on it, so a short word like "a" holds the friend.
    static let footing = friendSize * 0.25
    /// A re-read word this close to where the friend stands still holds it (OCR boxes wobble a little).
    static let snap = 6.0

    public let width: Double
    public let height: Double
    public private(set) var x: Double
    public private(set) var y: Double
    public private(set) var ledges: [Ledge]
    public internal(set) var coins: [Coin] = [] // tests place coins
    public private(set) var score = 0
    public private(set) var lives = startLives
    public private(set) var elapsed = 0.0
    public var isOver: Bool { lives <= 0 }
    public private(set) var isStanding = false
    /// Where the lava's surface is.
    public var lavaTop: Double { height * (1 - Self.lavaLevel(at: elapsed)) }

    private var vy = 0.0
    private var airJumps = 1
    private var jumpWasHeld = false
    private var dropWasHeld = false
    /// Dropping through the line at this height: its words don't catch the friend until it's below them.
    private var droppingFrom: Double?
    private var untilCoin = 0.5

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
        ledges = Self.clouds(width: width, height: height)
        x = width / 2
        y = 0
        respawn()
    }

    /// Two clouds a third of the way down, always above the highest lava, so a screen without text still plays.
    static func clouds(width: Double, height: Double) -> [Ledge] {
        [0.25, 0.75].map { Ledge(minX: width * $0 - 90, maxX: width * $0 + 90, y: height * 0.32, isCloud: true) }
    }

    /// Lava as a share of the height: 30 s waves that rise for 20 s and fall for 10, each peaking higher.
    public static func lavaLevel(at elapsed: Double) -> Double {
        let wave = (elapsed / 30).rounded(.down), phase = elapsed.truncatingRemainder(dividingBy: 30)
        let base = 0.05, peak = min(0.55, 0.2 + 0.07 * wave)
        let rise = phase < 20 ? phase / 20 : 1 - (phase - 20) / 10
        return base + (peak - base) * (0.5 - 0.5 * cos(rise * .pi))
    }

    /// The words on screen (boxes in the field, y down) became ledges. A friend standing on a word that's still
    /// there stays; one whose word scrolled away or vanished falls.
    public mutating func setWords(_ words: [CGRect]) {
        ledges = Self.clouds(width: width, height: height) + words.compactMap { word in
            guard word.width >= 4, word.height <= 200, word.minY >= Self.friendSize / 2, word.minY < height else { return nil }
            return Ledge(minX: Double(word.minX), maxX: Double(word.maxX), y: Double(word.minY))
        }
        guard isStanding else { return }
        if let under = ledges.filter({ supports($0) && abs($0.y - y) <= Self.snap }).min(by: { abs($0.y - y) < abs($1.y - y) }) {
            y = under.y
        } else {
            isStanding = false
        }
    }

    public mutating func step(dt: Double, steer: Double, jump: Bool, drop: Bool = false,
                              using rng: inout some RandomNumberGenerator) -> [Event] {
        guard !isOver, dt > 0 else { return [] }
        elapsed += dt
        let half = Self.friendSize / 2
        x = max(half, min(width - half, x + max(-1, min(1, steer)) * Self.runSpeed * dt))

        if jump, !jumpWasHeld {
            if isStanding {
                vy = -Self.jumpSpeed
                isStanding = false
            } else if airJumps > 0 {
                airJumps -= 1
                vy = -Self.airJumpSpeed
            }
        }
        if !jump, jumpWasHeld, vy < 0 { vy *= Self.jumpCut }
        jumpWasHeld = jump
        if drop, !dropWasHeld, isStanding {
            droppingFrom = y
            isStanding = false
        }
        dropWasHeld = drop
        if isStanding, !ledges.contains(where: { supports($0) && $0.y == y }) { isStanding = false } // ran off the end
        if !isStanding { fall(dt) }

        var events: [Event] = []
        spawnCoin(dt, using: &rng)
        let reach = (Self.friendSize + Self.coinSize) / 2 * 0.8
        let (lava, body) = (lavaTop, (x: x, y: y - half))
        coins.removeAll { coin in
            if coin.y > lava { return true }
            guard hypot(coin.x - body.x, coin.y - body.y) < reach else { return false }
            events.append(.coin(x: coin.x, y: coin.y))
            return true
        }
        score += events.count
        if y >= lavaTop {
            lives -= 1
            events.append(.burned(x: x))
            if isOver { events.append(.over) } else { respawn() }
        }
        return events
    }

    private func supports(_ ledge: Ledge) -> Bool {
        x >= ledge.minX - Self.footing && x <= ledge.maxX + Self.footing
    }

    /// One-way ledges: only landing from above stops the fall, and not on the line being dropped through.
    private mutating func fall(_ dt: Double) {
        let before = y
        vy = min(Self.maxFall, vy + Self.gravity * dt)
        y += vy * dt
        if let from = droppingFrom, y > from + Self.snap { droppingFrom = nil }
        let skip = droppingFrom
        guard vy > 0, let landing = ledges.filter({ ledge in
            supports(ledge) && ledge.y >= before && ledge.y <= y && skip.map { abs(ledge.y - $0) > Self.snap } ?? true
        }).min(by: { $0.y < $1.y }) else { return }
        y = landing.y
        land()
    }

    private mutating func land() {
        vy = 0
        isStanding = true
        airJumps = 1
        droppingFrom = nil
    }

    private mutating func spawnCoin(_ dt: Double, using rng: inout some RandomNumberGenerator) {
        untilCoin -= dt
        guard untilCoin <= 0 else { return }
        untilCoin = Self.coinInterval
        let safe = ledges.filter { $0.y < lavaTop - 80 && $0.y > Self.friendSize }
        guard coins.count < Self.maxCoins, let ledge = safe.randomElement(using: &rng) else { return }
        coins.append(Coin(x: Double.random(in: ledge.minX...ledge.maxX, using: &rng), y: ledge.y - Self.friendSize * 0.6))
    }

    /// Back on the highest ledge with room for the friend above it (a cloud at worst).
    private mutating func respawn() {
        let ledge = ledges.filter { $0.y >= Self.friendSize + 20 && $0.y < lavaTop - 80 }.min { $0.y < $1.y } ?? ledges[0]
        x = (ledge.minX + ledge.maxX) / 2
        y = ledge.y
        land()
        jumpWasHeld = true // a held jump from before doesn't fire on arrival
        dropWasHeld = true
    }
}
