//
//  Vocabulary.swift
//  PetCore
//
//  Actions and moods are names a skin draws (M9): any skin may add its own, so they're strings rather than enums.
//  The built-in names (vocabulary v1, shared with backend/pkg/utils/vocabulary) are what pixel-cat draws and what
//  older phrasebooks use; the constants below keep call sites readable.
//

import Foundation

public nonisolated enum Vocabulary {
    public static let version = 1
}

/// An animation name: a skin clip like "wave", played as "wave/<mood>" when the skin drew that combination.
public nonisolated struct PetAction: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let idle: PetAction = "idle", wave: PetAction = "wave", nudge: PetAction = "nudge"
    public static let sleep: PetAction = "sleep", celebrate: PetAction = "celebrate", dance: PetAction = "dance"
    public static let laugh: PetAction = "laugh", cry: PetAction = "cry", yawn: PetAction = "yawn"
    public static let stretch: PetAction = "stretch", think: PetAction = "think", peek: PetAction = "peek"
    public static let hide: PetAction = "hide", shrug: PetAction = "shrug", facepalm: PetAction = "facepalm"
    public static let cheer: PetAction = "cheer", jump: PetAction = "jump", spin: PetAction = "spin"
    public static let sit: PetAction = "sit", love: PetAction = "love"

    /// The built-in skin's actions, in vocabulary order.
    public static let builtIn: [PetAction] = [
        .idle, .wave, .nudge, .sleep, .celebrate, .dance, .laugh, .cry, .yawn, .stretch,
        .think, .peek, .hide, .shrug, .facepalm, .cheer, .jump, .spin, .sit, .love,
    ]

    /// Poses the friend holds until the next reaction; anything else, a skin's own actions included, plays briefly
    /// and settles back to idle.
    private static let holding: Set<String> = ["idle", "sleep", "think", "hide", "sit", "focus"]

    public var isOneShot: Bool { !Self.holding.contains(rawValue) }
}

/// A mood name: a skin draws actions in it, and a 16×16 head (mini/<mood>.png).
public nonisolated struct PetMood: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let content: PetMood = "content", curious: PetMood = "curious", concerned: PetMood = "concerned"
    public static let excited: PetMood = "excited", sleepy: PetMood = "sleepy", bored: PetMood = "bored"
    public static let playful: PetMood = "playful", proud: PetMood = "proud", shy: PetMood = "shy"
    public static let grumpy: PetMood = "grumpy", calm: PetMood = "calm", lonely: PetMood = "lonely"
    /// The one mood of a skin drawn without moods.
    public static let none: PetMood = "default"

    /// The built-in skin's moods, in vocabulary order.
    public static let builtIn: [PetMood] = [
        .content, .curious, .concerned, .excited, .sleepy, .bored, .playful, .proud, .shy, .grumpy, .calm, .lonely,
    ]
}
