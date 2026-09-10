//
//  PetReaction.swift
//  befriend
//
//  The shared action vocabulary. The model generates it, every character renders it.
//

import Foundation
import FoundationModels

@Generable
nonisolated enum PetAction: String, CaseIterable {
    case idle, wave, nudge, sleep, celebrate

    /// One-shots play briefly then settle back to idle; idle and sleep hold until the next reaction.
    var isOneShot: Bool {
        switch self {
        case .wave, .nudge, .celebrate: true
        case .idle, .sleep: false
        }
    }
}

@Generable
nonisolated enum PetMood: String, CaseIterable {
    case content, curious, concerned, excited
}

@Generable(description: "How a small desktop pet reacts to what the user just did")
nonisolated struct PetReaction: Equatable {
    @Guide(description: "The animation the pet plays")
    let action: PetAction

    @Guide(description: "The pet's current mood")
    let mood: PetMood

    @Guide(description: "One short, friendly sentence the pet says, at most 12 words")
    let dialogue: String
}

nonisolated extension PetReaction {
    static let maxDialogueLength = 80

    /// Canned reaction for when the model is unavailable or generation fails.
    static func fallback(for trigger: Trigger) -> PetReaction {
        switch trigger {
        case .appSwitched(let name): PetReaction(action: .nudge, mood: .curious, dialogue: "Ooh, \(name)?")
        case .wentIdle: PetReaction(action: .sleep, mood: .content, dialogue: "zzz…")
        case .returned: PetReaction(action: .wave, mood: .excited, dialogue: "Welcome back!")
        }
    }

    /// Model output is untrusted: sleep only makes sense once the user went idle, and dialogue must fit the bubble.
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
