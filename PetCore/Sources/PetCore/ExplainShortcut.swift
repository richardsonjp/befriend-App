//
//  ExplainShortcut.swift
//  PetCore
//
//  The Mac's "explain part of the screen" shortcut (M31): either a tap of modifiers alone (⌘⌥ by default: press them,
//  let go, nothing else in between) or modifiers with a key (⌃⇧E). ⌘⌥ with a key (⌘⌥Esc) never counts as the tap, so
//  other apps' shortcuts keep working.
//

import Foundation

public nonisolated struct ExplainShortcut: Codable, Equatable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        public var count: Int { rawValue.nonzeroBitCount }

        /// In Apple's order: ⌃⌥⇧⌘.
        public var symbols: String {
            [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { contains($0.0) }.map(\.1).joined()
        }
    }

    public var modifiers: Modifiers
    /// The key with the modifiers; nil for a tap of the modifiers alone.
    public var keyCode: UInt16?
    /// How the key reads ("E", "F5"), for showing the shortcut.
    public var keyName: String?

    public init(modifiers: Modifiers, keyCode: UInt16? = nil, keyName: String? = nil) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.keyName = keyName
    }

    public static let standard = ExplainShortcut(modifiers: [.command, .option])

    public var display: String { modifiers.symbols + (keyName ?? "") }

    /// A key needs at least one modifier (a bare letter would fire while typing). A tap needs two: a lone ⇧ or ⌘
    /// gets tapped by accident all day.
    public var isValid: Bool { keyCode == nil ? modifiers.count >= 2 : !modifiers.isEmpty }
}

/// Spots a tap of modifiers alone, fed every modifier change and every other key or click.
public nonisolated struct ModifierTap: Sendable {
    public let target: ExplainShortcut.Modifiers
    /// Longest the modifiers may be held for it to count as a tap.
    public static let window: TimeInterval = 0.6

    private var held: ExplainShortcut.Modifiers = []
    private var armedAt: Date?
    /// Something else happened while modifiers were down: no tap until they're all released.
    private var spoiled = false

    public init(target: ExplainShortcut.Modifiers) { self.target = target }

    /// The modifiers now held. True when this release completes a tap.
    public mutating func modifiers(_ now: ExplainShortcut.Modifiers, at time: Date) -> Bool {
        held = now
        if now.isEmpty {
            defer { armedAt = nil; spoiled = false }
            guard let armedAt, !spoiled else { return false }
            return time.timeIntervalSince(armedAt) <= Self.window
        }
        if !target.isSuperset(of: now) {
            spoiled = true
        } else if now == target, armedAt == nil, !spoiled {
            armedAt = time
        }
        return false
    }

    /// A key or mouse button went down.
    public mutating func otherInput() {
        if !held.isEmpty { spoiled = true }
    }
}
