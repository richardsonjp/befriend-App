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
    /// Set when the line brings up an earlier chat (M19): what the user might ask next, for the bubble's buttons.
    public let followUp: ChatFollowUp?

    public init(action: PetAction, mood: PetMood, dialogue: String, followUp: ChatFollowUp? = nil) {
        self.action = action
        self.mood = mood
        self.dialogue = dialogue
        self.followUp = followUp
    }
}

public nonisolated extension PetReaction {
    /// The generation schema for a skin: its actions and moods as the only choices.
    static func schema(actions: [PetAction], moods: [PetMood]) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "PetReaction", description: "How a small companion reacts to what the user just did",
                                           properties: [
            .init(name: "action", description: "The animation the companion plays",
                  schema: DynamicGenerationSchema(name: "Action", anyOf: actions.map(\.rawValue))),
            .init(name: "mood", description: "The companion's current mood",
                  schema: DynamicGenerationSchema(name: "Mood", anyOf: moods.map(\.rawValue))),
            .init(name: "dialogue", description: "One short, friendly sentence the companion says, at most 12 words",
                  schema: DynamicGenerationSchema(type: String.self)),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Checking in about an earlier chat (M19). Property order steers the small model: naming the subject first
    /// keeps the line from parroting the chat (tried on the real model).
    static func topicSchema(actions: [PetAction], moods: [PetMood]) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "Topic", description: "Checking in about an earlier chat", properties: [
            .init(name: "subject", description: "What the earlier chat was about, in 2 to 5 words",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "dialogue", description: "A short, warm check-in question about that subject, like a friend asking how it went, at most 14 words; not the user's question",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "followUp", description: "The question the user would type to you next to dig deeper into the subject, e.g. starting with How, What, Why or Can you; at most 20 words",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "action", description: "The animation the companion plays",
                  schema: DynamicGenerationSchema(name: "Action", anyOf: actions.map(\.rawValue))),
            .init(name: "mood", description: "The companion's current mood",
                  schema: DynamicGenerationSchema(name: "Mood", anyOf: moods.map(\.rawValue))),
        ])
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
        case .slouching: PetReaction(action: .stretch, mood: .concerned, dialogue: "Sit up with me? Shoulders back!")
        case .encourage, .chatTopic: encouragement(avoiding: SaidLines())
        }
    }

    /// Canned encouragement for when the model can't answer: one the user hasn't heard lately, if any is left.
    static func encouragement(avoiding said: SaidLines) -> PetReaction {
        let fresh = cannedEncouragements.filter { !said.contains($0) }
        let text = (fresh.isEmpty ? cannedEncouragements : fresh).randomElement() ?? "You've got this!"
        return PetReaction(action: .cheer, mood: .proud, dialogue: text)
    }

    static let cannedEncouragements = [
        "You've got this!",
        "Small steps still move you forward.",
        "I'm proud of you, just so you know.",
        "One thing at a time. You're doing great.",
        "Progress, not perfection.",
        "Every little bit counts today.",
        "You're braver than you think.",
        "Take a breath. You're on track.",
        "Keep going, I believe in you!",
        "A little progress each day adds up.",
        "Be kind to yourself today.",
        "Look how far you've come already!",
    ]

    /// Model and phrasebook output is untrusted: sleep only makes sense once the user went idle, and dialogue
    /// must fit the bubble.
    func clamped(for trigger: Trigger) -> PetReaction {
        let sleepAllowed = if case .wentIdle = trigger { true } else { false }
        let text = dialogue.trimmingCharacters(in: .whitespacesAndNewlines)
        return PetReaction(
            action: action == .sleep && !sleepAllowed ? .idle : action,
            mood: mood,
            dialogue: text.count > Self.maxDialogueLength ? String(text.prefix(Self.maxDialogueLength - 1)) + "…" : text,
            followUp: followUp
        )
    }
}
