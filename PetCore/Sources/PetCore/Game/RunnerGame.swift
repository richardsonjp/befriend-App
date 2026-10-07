//
//  RunnerGame.swift
//  PetCore
//
//  Desktop Runner (M42): the friend runs and jumps along the top edges of the real windows on the Mac, collecting
//  coins while lava rises in waves from the bottom. Pure rules, like `CatchGame`: y grows downwards, 0 is the top of
//  the screen, and the friend's position is its feet.
//

import CoreGraphics
import Foundation

public nonisolated struct RunnerGame: Sendable {
    /// A surface the friend can land on from above: part of a window's top edge, or one of the game's clouds.
    public struct Ledge: Equatable, Sendable {
        /// The window's number; clouds are negative.
        public var window: Int
        public var minX: Double
        public var maxX: Double
        public var y: Double
        /// The window's left edge, so a friend standing on it moves with it.
        public var left: Double

        public var isCloud: Bool { window < 0 }
    }

    public struct Window: Sendable {
        public var id: Int
        /// In the field's coordinates (top-left origin, y down).
        public var frame: CGRect

        public init(id: Int, frame: CGRect) {
            self.id = id
            self.frame = frame
        }
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
    static let jumpSpeed = 1150.0 // about 236 points high when held
    static let jumpCut = 0.45 // letting go early keeps this much of the rise
    static let maxFall = 1800.0
    static let maxCoins = 5
    static let coinInterval = 1.2
    static let minLedge = 40.0
    /// Feet this far past a ledge's end still stand on it.
    static let footing = friendSize * 0.25

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
    public var isStanding: Bool { ground != nil }
    /// Where the lava's surface is.
    public var lavaTop: Double { height * (1 - Self.lavaLevel(at: elapsed)) }

    private var vy = 0.0
    private var ground: Int?
    private var jumpWasHeld = false
    private var untilCoin = 0.5

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
        ledges = Self.clouds(width: width, height: height)
        x = width / 2
        y = 0
        respawn()
    }

    /// Two clouds a third of the way down, always above the highest lava, so there's somewhere to stand.
    static func clouds(width: Double, height: Double) -> [Ledge] {
        let y = height * 0.32, half = 90.0
        return [0.25, 0.75].enumerated().map { index, at in
            Ledge(window: -1 - index, minX: width * at - half, maxX: width * at + half, y: y, left: width * at - half)
        }
    }

    /// Lava as a share of the height: 30 s waves that rise for 20 s and fall for 10, each peaking higher.
    public static func lavaLevel(at elapsed: Double) -> Double {
        let wave = (elapsed / 30).rounded(.down), phase = elapsed.truncatingRemainder(dividingBy: 30)
        let base = 0.05, peak = min(0.55, 0.2 + 0.07 * wave)
        let rise = phase < 20 ? phase / 20 : 1 - (phase - 20) / 10
        return base + (peak - base) * (0.5 - 0.5 * cos(rise * .pi))
    }

    /// The visible parts of each window's top edge. `windows` are front to back; a window in front covers the edges
    /// of those behind it where it overlaps them.
    public static func ledges(windows: [Window], width: Double, height: Double) -> [Ledge] {
        windows.enumerated().flatMap { index, window -> [Ledge] in
            let frame = window.frame, top = Double(frame.minY)
            guard frame.width >= 80, top >= friendSize / 2, top < height else { return [] }
            var spans = [(max(0, Double(frame.minX)), min(width, Double(frame.maxX)))]
            for front in windows[..<index] where Double(front.frame.minY) <= top && top <= Double(front.frame.maxY) {
                let cut = (Double(front.frame.minX), Double(front.frame.maxX))
                spans = spans.flatMap { span in
                    [(span.0, min(span.1, cut.0)), (max(span.0, cut.1), span.1)].filter { $0.1 > $0.0 }
                }
            }
            return spans.filter { $0.1 - $0.0 >= minLedge }.map {
                Ledge(window: window.id, minX: $0.0, maxX: $0.1, y: top, left: Double(frame.minX))
            }
        }
    }

    /// The windows moved, opened or closed. A friend standing on one moves with it, and falls if it's gone.
    public mutating func setWindows(_ windows: [Window]) {
        let mine = Self.ledges(windows: windows, width: width, height: height)
        if let standing = ground, standing >= 0 {
            if let before = ledges.first(where: { $0.window == standing }), let after = mine.first(where: { $0.window == standing }) {
                x = max(Self.friendSize / 2, min(width - Self.friendSize / 2, x + after.left - before.left))
                y = after.y
            }
        }
        ledges = Self.clouds(width: width, height: height) + mine
        if let standing = ground, !ledges.contains(where: { $0.window == standing && supports($0) }) { ground = nil }
    }

    public mutating func step(dt: Double, steer: Double, jump: Bool, using rng: inout some RandomNumberGenerator) -> [Event] {
        guard !isOver, dt > 0 else { return [] }
        elapsed += dt
        let half = Self.friendSize / 2
        x = max(half, min(width - half, x + max(-1, min(1, steer)) * Self.runSpeed * dt))

        if jump, !jumpWasHeld, ground != nil {
            vy = -Self.jumpSpeed
            ground = nil
        }
        if !jump, jumpWasHeld, vy < 0 { vy *= Self.jumpCut }
        jumpWasHeld = jump
        if let standing = ground, !ledges.contains(where: { $0.window == standing && supports($0) }) { ground = nil }
        if ground == nil { fall(dt) }

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

    /// One-way ledges: only landing from above stops the fall.
    private mutating func fall(_ dt: Double) {
        let before = y
        vy = min(Self.maxFall, vy + Self.gravity * dt)
        y += vy * dt
        guard vy > 0, let landing = ledges.filter({ supports($0) && $0.y >= before && $0.y <= y }).min(by: { $0.y < $1.y })
        else { return }
        y = landing.y
        vy = 0
        ground = landing.window
    }

    private mutating func spawnCoin(_ dt: Double, using rng: inout some RandomNumberGenerator) {
        untilCoin -= dt
        guard untilCoin <= 0 else { return }
        untilCoin = Self.coinInterval
        let safe = ledges.filter { $0.y < lavaTop - 80 }
        guard coins.count < Self.maxCoins, let ledge = safe.randomElement(using: &rng) else { return }
        coins.append(Coin(x: Double.random(in: ledge.minX...ledge.maxX, using: &rng), y: ledge.y - Self.friendSize * 0.6))
    }

    /// Back on the highest ledge with room for the friend above it (a cloud at worst).
    private mutating func respawn() {
        let ledge = ledges.filter { $0.y >= Self.friendSize + 20 && $0.y < lavaTop - 80 }.min { $0.y < $1.y } ?? ledges[0]
        x = (ledge.minX + ledge.maxX) / 2
        y = ledge.y
        vy = 0
        ground = ledge.window
        jumpWasHeld = true // a held jump from before doesn't fire on arrival
    }
}
