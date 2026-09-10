//
//  PetBrain.swift
//  PetCore
//

import Foundation
import FoundationModels
import os

/// Turns triggers into reactions: the on-device model when it's available, canned fallbacks otherwise.
/// One request at a time. Triggers that arrive mid-request still land in memory; only the latest one waits its turn.
public final class PetBrain {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "brain")

    // ponytail: in-memory log for this launch only; the backend owns the durable event log.
    nonisolated static let memoryLimit = 6

    /// Static block: never interpolated, so it stays byte-identical across calls.
    nonisolated static let instructions = """
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
        forceFallback: Bool = ProcessInfo.processInfo.environment["PET_FORCE_FALLBACK"] == "1",
        appSwitchCooldown: TimeInterval = 20
    ) {
        self.forceFallback = forceFallback
        self.appSwitchCooldown = appSwitchCooldown
        Self.log.info("Model availability: \(String(describing: self.model.availability), privacy: .public)")
        prepareNextSession()
    }

    public func handle(_ trigger: Trigger) {
        let record = TriggerRecord(trigger: trigger.sanitized, at: .now)
        memory = Array((memory + [record]).suffix(Self.memoryLimit))
        if isBusy { pending = record } else { start(record) }
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
        let reaction: PetReaction
        if forceFallback {
            reaction = .fallback(for: record.trigger)
        } else {
            switch model.availability {
            case .available:
                reaction = await generate(for: record)
            case .unavailable(let reason):
                reaction = explainOnce(reason, over: .fallback(for: record.trigger))
            }
        }
        return reaction.clamped(for: record.trigger)
    }

    private func generate(for record: TriggerRecord) async -> PetReaction {
        let session = nextSession ?? makeSession()
        nextSession = nil
        defer { prepareNextSession() }
        do {
            let prompt = Self.dynamicBlock(for: record, memory: memory)
            return try await session.respond(to: prompt, generating: PetReaction.self).content
        } catch {
            // guardrailViolation, exceededContextWindowSize, rateLimited, … all degrade the same way.
            Self.log.error("Generation failed, using fallback: \(String(describing: error), privacy: .public)")
            return .fallback(for: record.trigger)
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
        LanguageModelSession(model: model, instructions: Self.instructions)
    }

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
        Self.log.notice("Model unavailable, using fallbacks: \(String(describing: reason), privacy: .public)")
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
