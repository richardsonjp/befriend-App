//
//  PetReaction.swift
//  PetCore
//

import Foundation
import FoundationModels

@Generable(description: "How a small companion reacts to what the user just did")
public nonisolated struct PetReaction: Equatable, Sendable {
    @Guide(description: "The animation the companion plays")
    public let action: PetAction

    @Guide(description: "The companion's current mood")
    public let mood: PetMood

    @Guide(description: "One short, friendly sentence the companion says, at most 12 words")
    public let dialogue: String

    public init(action: PetAction, mood: PetMood, dialogue: String) {
        self.action = action
        self.mood = mood
        self.dialogue = dialogue
    }
}

public nonisolated extension PetReaction {
    static let maxDialogueLength = 80

    /// Canned reaction for when there is neither a model nor a phrasebook line.
    static func fallback(for trigger: Trigger) -> PetReaction {
        switch trigger {
        case .appSwitched(let name): PetReaction(action: .nudge, mood: .curious, dialogue: "Ooh, \(name)?")
        case .wentIdle: PetReaction(action: .sleep, mood: .sleepy, dialogue: "zzz…")
        case .returned: PetReaction(action: .wave, mood: .excited, dialogue: "Welcome back!")
        case .leftApp: PetReaction(action: .wave, mood: .content, dialogue: "See you soon!")
        case .poked: PetReaction(action: .laugh, mood: .playful, dialogue: "Hehe, that tickles!")
        case .checkIn: PetReaction(action: .wave, mood: .curious, dialogue: "Hey, how's it going?")
        }
    }

    /// Model and phrasebook output is untrusted: sleep only makes sense once the user went idle, and dialogue
    /// must fit the bubble.
    func clamped(for trigger: Trigger) -> PetReaction {
        let sleepAllowed = if case .wentIdle = trigger { true } else { false }
        let text = dialogue.trimmingCharacters(in: .whitespacesAndNewlines)
        return PetReaction(
            action: action == .sleep && !sleepAllowed ? .idle : action,
            mood: mood,
            dialogue: text.count > Self.maxDialogueLength ? String(text.prefix(Self.maxDialogueLength - 1)) + "…" : text
        )
    }
}
