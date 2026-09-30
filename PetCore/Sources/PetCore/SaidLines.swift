//
//  SaidLines.swift
//  PetCore
//
//  The encouraging lines the friend already said on this device (M17), so each new one is different: the latest
//  few go into the prompt as lines not to reuse, and a line matching any of them is rejected.
//

import Foundation

public nonisolated struct SaidLines: Codable, Equatable, Sendable {
    static let limit = 60
    static let promptCount = 8
    private static let defaultsKey = "brain.saidLines"

    /// Oldest first.
    public private(set) var lines: [String] = []

    public init(lines: [String] = []) {
        self.lines = Array(lines.suffix(Self.limit))
    }

    /// Same words, ignoring case, spacing and punctuation.
    public func contains(_ text: String) -> Bool {
        let key = Self.key(text)
        return lines.contains { Self.key($0) == key }
    }

    public func adding(_ text: String) -> SaidLines {
        contains(text) ? self : SaidLines(lines: lines + [text])
    }

    /// The "don't repeat" part of the prompt; nil before anything was said.
    var promptLine: String? {
        guard !lines.isEmpty else { return nil }
        return "Say something new, in different words from these lines you already said:\n"
            + lines.suffix(Self.promptCount).map { "- \($0)" }.joined(separator: "\n")
    }

    private static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    static func load(from defaults: UserDefaults) -> SaidLines {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(SaidLines.self, from: $0) } ?? SaidLines()
    }

    func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
