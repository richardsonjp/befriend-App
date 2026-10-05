//
//  ContextBudget.swift
//  PetCore
//
//  Fitting each agent into its 4K (M36). Every session is the on-device model's 4K window, so a prompt is measured
//  before it's sent (the model's own token count where the OS has it) and trimmed in a set order until the answer
//  has room; the answer is then capped at the room left, up to a ceiling per job, so it can't run past the window.
//

import Foundation
import FoundationModels

public nonisolated enum ContextBudget {
    /// Room an answer needs at least; trimming stops once it has it.
    static let answerFloor = 500
    /// The longest a job's answer may be, when there's room.
    static let answerCeiling = 900
    static let writerCeiling = 600
    static let explainCeiling = 300
    /// Kept free past the answer (the session's own framing).
    static let margin = 24
    /// Without the model's count (before macOS/iOS 26.4): characters a token, on the safe side for code and symbols.
    static let fallbackCharactersPerToken = 2.5

    /// Tokens in `text`: the model's own count when the OS has it, else an estimate that errs high.
    static func tokens(_ text: String, model: SystemLanguageModel) async -> Int {
        guard !text.isEmpty else { return 0 }
        if #available(iOS 26.4, macOS 26.4, *), model.isAvailable, let count = try? await model.tokenCount(for: text) {
            return count
        }
        return estimate(text)
    }

    static func tokens(instructions: String, model: SystemLanguageModel) async -> Int {
        if #available(iOS 26.4, macOS 26.4, *), model.isAvailable, let count = try? await model.tokenCount(for: Instructions(instructions)) {
            return count
        }
        return estimate(instructions)
    }

    static func estimate(_ text: String) -> Int {
        max(1, Int((Double(text.count) / fallbackCharactersPerToken).rounded(.up)))
    }

    /// Most tokens an answer may write: what `used` leaves of the window, up to `ceiling` (and never under 64, so
    /// something can always be said).
    static func cap(used: Int, contextSize: Int, ceiling: Int) -> Int {
        max(64, min(ceiling, contextSize - used - margin))
    }

    // MARK: The plain answer's prompt

    /// What a plain answer's prompt is made of, besides the question and the summary (which always stay).
    struct AnswerParts {
        var recalled: String?
        /// Oldest first.
        var recent: [ChatMessage]
        /// Best first.
        var passages: [Retriever.Hit]
    }

    enum Cut: Equatable { case recall, oldestRecent, lowestPassage }

    /// What goes next when the prompt doesn't fit: recalled turns, then the oldest messages (the last question and
    /// answer stay), then the lowest passages (the best one stays), then the last messages, then the best passage.
    /// Nil when there's nothing left to cut.
    static func nextCut(hasRecall: Bool, recent: Int, passages: Int, keepLast: Int = ChatPrompt.keepLast) -> Cut? {
        if hasRecall { return .recall }
        if recent > keepLast { return .oldestRecent }
        if passages > 1 { return .lowestPassage }
        if recent > 0 { return .oldestRecent }
        if passages > 0 { return .lowestPassage }
        return nil
    }

    /// Cuts `parts` until `measure` says they fit `limit` tokens. Returns what's kept, its size, and whether
    /// messages of the conversation had to go (a question that points back may then need the team, M36 C).
    static func fit(_ parts: AnswerParts, limit: Int,
                    measure: (AnswerParts) async -> Int) async -> (parts: AnswerParts, tokens: Int, droppedRecent: Bool) {
        var parts = parts
        var tokens = await measure(parts)
        var droppedRecent = false
        while tokens > limit,
              let cut = nextCut(hasRecall: parts.recalled != nil, recent: parts.recent.count, passages: parts.passages.count) {
            switch cut {
            case .recall: parts.recalled = nil
            case .oldestRecent:
                parts.recent.removeFirst()
                droppedRecent = true
            case .lowestPassage: parts.passages.removeLast()
            }
            tokens = await measure(parts)
        }
        return (parts, tokens, droppedRecent)
    }
}
