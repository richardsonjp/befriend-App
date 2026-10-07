//
//  CatchGame.swift
//  PetCore
//
//  Catch (M41): food and bombs fall across the Mac desktop and the friend runs along the bottom, steered by tilting
//  the iPhone. Pure rules, so the Mac only draws them; y grows downwards, 0 is the top of the screen.
//

import Foundation

public nonisolated struct CatchGame: Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case fruit, vegetable, meat, bomb

        public var points: Int { self == .meat ? 2 : self == .bomb ? 0 : 1 }
        public var emojis: [String] {
            switch self {
            case .fruit: ["🍎", "🍌", "🍇"]
            case .vegetable: ["🥕", "🥦", "🌽"]
            case .meat: ["🍖", "🥩", "🍗"]
            case .bomb: ["💣"]
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public var kind: Kind
        public var emoji: String
        public var x: Double
        public var y: Double
        public var speed: Double
    }

    public enum Event: Equatable, Sendable {
        case caught(Kind, points: Int, x: Double)
        case bomb(x: Double)
        case over
    }

    /// The friend's sprite (`CharacterView.size`); an item is caught when it reaches the friend's head over its body.
    public static let friendSize = 64.0
    public static let itemSize = 40.0
    public static let runSpeed = 900.0 // points a second at full tilt
    public static let startLives = 3

    public let width: Double
    public let height: Double
    public private(set) var friendX: Double
    public internal(set) var items: [Item] = [] // tests place items
    public private(set) var score = 0
    public private(set) var lives = startLives
    public private(set) var elapsed = 0.0
    public var isOver: Bool { lives <= 0 }
    private var untilSpawn = 0.5

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
        friendX = width / 2
    }

    /// Seconds between items: one a second at first, down to 0.35 s after about 1.5 minutes.
    public static func spawnInterval(at elapsed: Double) -> Double { max(0.35, 1.0 - elapsed * 0.0075) }
    /// Fall speed in points a second: crosses a 1,000-point screen in about 5 s at first, 1.7 s at the cap.
    public static func fallSpeed(at elapsed: Double) -> Double { min(600, 200 + elapsed * 4) }
    public static func bombChance(at elapsed: Double) -> Double { min(0.35, 0.2 + elapsed * 0.0015) }

    /// The tilt in degrees from the calibrated hold → steer from -1 (full left) to 1: still within ±4°, full at 30°.
    public static func steer(degrees: Double) -> Double {
        let dead = 4.0, full = 30.0
        guard abs(degrees) > dead else { return 0 }
        return max(-1, min(1, (abs(degrees) - dead) / (full - dead))) * (degrees < 0 ? -1 : 1)
    }

    /// The device axis (x, y) to steer along, from gravity at calibration, so any hold works. Upright (portrait or
    /// landscape, like a steering wheel): the screen-plane direction across gravity, so turning it right steers
    /// right. Flat: the phone's x axis (tip the right edge down).
    public static func tiltAxis(calibrated g: (x: Double, y: Double, z: Double)) -> (x: Double, y: Double) {
        let length = (g.x * g.x + g.y * g.y).squareRoot()
        guard length > 0.5 else { return (1, 0) }
        return (-g.y / length, g.x / length)
    }

    /// How far the phone is tipped along `axis`, in degrees (positive = right).
    public static func tiltDegrees(gravity g: (x: Double, y: Double, z: Double), axis: (x: Double, y: Double)) -> Double {
        asin(max(-1, min(1, g.x * axis.x + g.y * axis.y))) * 180 / .pi
    }

    public mutating func step(dt: Double, steer: Double, using rng: inout some RandomNumberGenerator) -> [Event] {
        guard !isOver, dt > 0 else { return [] }
        elapsed += dt
        let half = Self.friendSize / 2
        friendX = max(half, min(width - half, friendX + max(-1, min(1, steer)) * Self.runSpeed * dt))

        untilSpawn -= dt
        if untilSpawn <= 0 {
            untilSpawn = Self.spawnInterval(at: elapsed)
            items.append(spawn(using: &rng))
        }

        var events: [Event] = []
        let catchTop = height - Self.friendSize
        let reach = (Self.friendSize + Self.itemSize) / 2 * 0.8 // a little forgiving, not the full sprite box
        items = items.compactMap { item in
            var item = item
            let before = item.y
            item.y += item.speed * dt
            if before < catchTop, item.y >= catchTop, abs(item.x - friendX) < reach {
                events.append(item.kind == .bomb ? .bomb(x: item.x) : .caught(item.kind, points: item.kind.points, x: item.x))
                return nil
            }
            return item.y > height + Self.itemSize ? nil : item
        }
        for event in events {
            switch event {
            case .caught(_, let points, _): score += points
            case .bomb: lives -= 1
            case .over: break
            }
        }
        if isOver { events.append(.over) }
        return events
    }

    private func spawn(using rng: inout some RandomNumberGenerator) -> Item {
        let kind: Kind = Double.random(in: 0..<1, using: &rng) < Self.bombChance(at: elapsed)
            ? .bomb : [.fruit, .vegetable, .meat].randomElement(using: &rng)!
        let margin = Self.itemSize / 2
        let speed = Self.fallSpeed(at: elapsed) * Double.random(in: 0.85...1.15, using: &rng)
        return Item(kind: kind, emoji: kind.emojis.randomElement(using: &rng)!,
                    x: Double.random(in: margin...max(margin, width - margin), using: &rng), y: -Self.itemSize, speed: speed)
    }
}

/// Seeded randomness, so a game replays exactly in tests.
public nonisolated struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 { // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
