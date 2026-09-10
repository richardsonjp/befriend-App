//
//  PetBrain.swift
//  PetCore
//

import Foundation
import FoundationModels
import os

/// Turns triggers into reactions: the on-device model when it's available, the friend's phrasebook otherwise.
/// One request at a time for `handle`. Triggers that arrive mid-request still land in memory; only the latest one
/// waits its turn. Build a new brain when the friend's personality version changes.
public final class PetBrain {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "brain")

    // ponytail: in-memory log for this launch only; the backend owns the durable event log.
    nonisolated static let memoryLimit = 6
    /// Instructions plus schema must leave room in the 4K context for the prompt and the answer.
    nonisolated static let instructionTokenBudget = 1200

    /// Device-neutral base; the friend's name and persona are appended once per personality version.
    nonisolated static let baseInstructions = """
        You are a small, friendly companion who lives on the user's devices.
        You notice what the user is doing and react briefly, like a playful friend.

        Pick one action: idle, wave, nudge, sleep, celebrate, dance, laugh, cry, yawn, stretch, think, peek, hide, \
        shrug, facepalm, cheer, jump, spin, sit, love. Use sleep only when the user has gone idle.
        Pick the mood that matches the dialogue: content, curious, concerned, excited, sleepy, bored, playful, \
        proud, shy, grumpy, calm, lonely.

        Rules:
        - Dialogue is one short sentence, at most 12 words, spoken to the user.
        - React to what the user did; don't narrate it back to them.
        - Mention the app name only sometimes.
        - Be warm and playful, never judgmental, pushy, or preachy.
        - Never mention being an AI or a language model.
        """

    public var onReaction: (PetReaction) -> Void = { _ in }

    /// Never interpolated per call, so it stays byte-identical for the life of this brain.
    let instructions: String
    private let phrasebook: Phrasebook?
    private let model = SystemLanguageModel.default
    private let forceFallback: Bool
    private let appSwitchCooldown: TimeInterval
    private var memory: [TriggerRecord] = []
    private var pending: TriggerRecord?
    private var isBusy = false
    private var lastAppSwitchReaction: Date?
    private var nextSession: LanguageModelSession?
    private var hasExplainedFallback = false

    public init(
        friend: FriendProfile? = nil,
        forceFallback: Bool = ProcessInfo.processInfo.environment["PET_FORCE_FALLBACK"] == "1",
        appSwitchCooldown: TimeInterval = 20
    ) {
        self.instructions = Self.makeInstructions(for: friend)
        self.phrasebook = friend?.phrasebook
        self.forceFallback = forceFallback
        self.appSwitchCooldown = appSwitchCooldown
        Self.log.info("Model availability: \(String(describing: self.model.availability), privacy: .public)")
        prepareNextSession()
        #if DEBUG
        checkInstructionBudget()
        #endif
    }

    /// Fire-and-forget: the reaction arrives through `onReaction`.
    public func handle(_ trigger: Trigger) {
        let record = remember(trigger)
        if isBusy { pending = record } else { start(record) }
    }

    /// For callers that need the answer in place (intents, background refresh). No cooldown, no queue.
    public func react(to trigger: Trigger) async -> PetReaction {
        await makeReaction(for: remember(trigger))
    }

    /// An instant reaction without the model: a phrasebook line, or a canned one.
    public func quickReaction(to trigger: Trigger, mood: PetMood? = nil) -> PetReaction {
        let trigger = trigger.sanitized
        return phrasebook?.reaction(for: trigger, mood: mood) ?? PetReaction.fallback(for: trigger).clamped(for: trigger)
    }

    nonisolated static func makeInstructions(for friend: FriendProfile?) -> String {
        guard let friend else { return baseInstructions }
        var text = baseInstructions + "\n\nYour name is \"\(flattened(friend.name))\". Call the user \"\(flattened(friend.userNickname))\"."
        if let persona = friend.personality.content?.instructions, !persona.isEmpty {
            text += "\n\n" + persona
        }
        return text
    }

    /// Names are user input: keep them on one line and inside their quotes.
    private nonisolated static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "\"", with: "'")
    }

    private func remember(_ trigger: Trigger) -> TriggerRecord {
        let record = TriggerRecord(trigger: trigger.sanitized, at: .now)
        memory = Array((memory + [record]).suffix(Self.memoryLimit))
        return record
    }

    private func start(_ record: TriggerRecord) {
        guard claimCooldown(for: record.trigger) else { return }
        isBusy = true
        Task {
            let reaction = await makeReaction(for: record)
            Self.log.debug("\(record.trigger.promptLine) → \(reaction.action.rawValue, privacy: .public)/\(reaction.mood.rawValue, privacy: .public): \(reaction.dialogue)")
            onReaction(reaction)
            isBusy = false
            if let next = pending {
                pending = nil
                start(next)
            }
        }
    }

    /// App switches are rate-limited so the friend isn't chatty; everything else always gets through.
    private func claimCooldown(for trigger: Trigger) -> Bool {
        guard case .appSwitched = trigger else { return true }
        let now = Date.now
        if let last = lastAppSwitchReaction, now.timeIntervalSince(last) < appSwitchCooldown { return false }
        lastAppSwitchReaction = now
        return true
    }

    private func makeReaction(for record: TriggerRecord) async -> PetReaction {
        if forceFallback { return quickReaction(to: record.trigger) }
        switch model.availability {
        case .available:
            return await generate(for: record).clamped(for: record.trigger)
        case .unavailable(let reason):
            return explainOnce(reason, over: quickReaction(to: record.trigger))
        }
    }

    private func generate(for record: TriggerRecord) async -> PetReaction {
        let session = nextSession ?? makeSession()
        nextSession = nil
        defer { prepareNextSession() }
        do {
            let prompt = Self.dynamicBlock(for: record, memory: memory)
            return try await session.respond(to: prompt, generating: PetReaction.self).content
        } catch {
            // guardrailViolation, exceededContextWindowSize, rateLimited (backgrounded), … all degrade the same way.
            Self.log.error("Generation failed, using the phrasebook: \(String(describing: error), privacy: .public)")
            return quickReaction(to: record.trigger)
        }
    }

    /// Each trigger gets a fresh session: byte-identical instructions and an empty transcript, so the 4K window never
    /// fills and old lines don't get parroted. The next one is prewarmed right away so it's ready for the next trigger.
    private func prepareNextSession() {
        guard !forceFallback, nextSession == nil, model.isAvailable else { return }
        let session = makeSession()
        session.prewarm()
        nextSession = session
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: instructions)
    }

    #if DEBUG
    private func checkInstructionBudget() {
        guard model.isAvailable else { return }
        guard #available(iOS 26.4, macOS 26.4, *) else { return }
        let instructions = self.instructions
        Task { [model] in
            guard let count = try? await model.tokenCount(for: Instructions(instructions)) else { return }
            if count > Self.instructionTokenBudget {
                Self.log.fault("Instructions use \(count) tokens, over the \(Self.instructionTokenBudget)-token budget")
            }
        }
    }
    #endif

    /// Dynamic block: a trimmed window of earlier triggers, then the current one. Kept short for the 4K context.
    nonisolated static func dynamicBlock(for current: TriggerRecord, memory: [TriggerRecord]) -> String {
        let earlier = memory.filter { $0.at < current.at }.suffix(memoryLimit)
        let history = earlier.isEmpty
            ? "Recent events: none."
            : "Recent events (oldest first):\n" + earlier
                .map { "- \(Trigger.format(current.at.timeIntervalSince($0.at), width: .narrow)) ago: \($0.trigger.memoryLine)" }
                .joined(separator: "\n")
        return history + "\nNow: " + current.trigger.promptLine
    }

    /// The first unavailable fallback tells the user why the friend is in simple mode; later ones stay quiet.
    private func explainOnce(_ reason: SystemLanguageModel.Availability.UnavailableReason, over reaction: PetReaction) -> PetReaction {
        guard !hasExplainedFallback else { return reaction }
        hasExplainedFallback = true
        Self.log.notice("Model unavailable, using the phrasebook: \(String(describing: reason), privacy: .public)")
        return PetReaction(action: reaction.action, mood: .concerned, dialogue: Self.explanation(for: reason))
    }

    private static func explanation(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This device can't run Apple Intelligence, so I'll keep it simple."
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off, so I'll keep it simple."
        case .modelNotReady: "My brain is still downloading. Simple mode for now!"
        @unknown default: "My brain isn't available, so I'll keep it simple."
        }
    }
}
