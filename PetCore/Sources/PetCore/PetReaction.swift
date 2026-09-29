//
//  PetReaction.swift
//  PetCore
//

import Foundation
import FoundationModels

/// How the friend reacts to what the user just did. The model generates it under `schema(for:)`, built from what
/// the skin can play, since each skin names its own actions and moods.
public nonisolated struct PetReaction: Equatable, Sendable {
    public let action: PetAction
    public let mood: PetMood
    public let dialogue: String

    public init(action: PetAction, mood: PetMood, dialogue: String) {
        self.action = action
        self.mood = mood
        self.dialogue = dialogue
    }
}

public nonisolated extension PetReaction {
    /// The generation schema for a skin: its actions and moods as the only choices.
    static func schema(actions: [PetAction], moods: [PetMood]) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "PetReaction",
            description: "How a small companion reacts to what the user just did",
            properties: [
                .init(name: "action", description: "The animation the companion plays",
                      schema: DynamicGenerationSchema(name: "Action", anyOf: actions.map(\.rawValue))),
                .init(name: "mood", description: "The companion's current mood",
                      schema: DynamicGenerationSchema(name: "Mood", anyOf: moods.map(\.rawValue))),
                .init(name: "dialogue", description: "One short, friendly sentence the companion says, at most 12 words",
                      schema: DynamicGenerationSchema(type: String.self)),
            ]
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    init(_ content: GeneratedContent) throws {
        self.init(
            action: PetAction(try content.value(String.self, forProperty: "action")),
            mood: PetMood(try content.value(String.self, forProperty: "mood")),
            dialogue: try content.value(String.self, forProperty: "dialogue")
        )
    }

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
        case .pomodoro(.focusStarted): PetReaction(action: .cheer, mood: .excited, dialogue: "Let's focus! See you when it's done.")
        case .pomodoro(.focusEnded): PetReaction(action: .celebrate, mood: .proud, dialogue: "Nice work! Stretch with me?")
        case .pomodoro(.calledOut): PetReaction(action: .wave, mood: .shy, dialogue: "Just a quick hi! Keep going.")
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
