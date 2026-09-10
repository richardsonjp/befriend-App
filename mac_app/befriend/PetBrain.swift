//
//  PetBrain.swift
//  befriend
//

import Foundation
import FoundationModels
import os

/// Turns triggers into reactions: the on-device model when it's available, canned fallbacks otherwise.
/// One request at a time. Triggers that arrive mid-request still land in memory; only the latest one waits its turn.
final class PetBrain {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "brain")

    // ponytail: in-memory log for this launch only; the Phase 4 backend owns the durable event log.
    nonisolated static let memoryLimit = 6

    /// Static block: never interpolated, so it stays byte-identical across calls.
    nonisolated static let instructions = """
        You are a small, friendly pet who lives in the corner of the user's Mac screen.
        You notice what the user is doing and react briefly, like a playful companion.

        Actions:
        - idle: nothing worth reacting to
        - wave: greet the user, especially when they come back
        - nudge: show interest in what the user just switched to
        - sleep: the user has gone idle, so doze off and say something sleepy
        - celebrate: something good or exciting happened

        Moods: content, curious, concerned, excited. Pick the mood that matches the dialogue.

        Rules:
        - Dialogue is one short sentence, at most 12 words, spoken to the user.
        - React to what the user did; don't narrate it back to them.
        - Mention the app name only sometimes.
        - Be warm and playful, never judgmental, pushy, or preachy.
        - Never mention being an AI or a language model.
        """

    var onReaction: (PetReaction) -> Void = { _ in }

    private let model = SystemLanguageModel.default
    private let forceFallback: Bool
    private let appSwitchCooldown: TimeInterval
    private var memory: [TriggerRecord] = []
    private var pending: TriggerRecord?
    private var isBusy = false
    private var lastAppSwitchReaction: Date?
    private var nextSession: LanguageModelSession?
    private var hasExplainedFallback = false

    init(
        forceFallback: Bool = ProcessInfo.processInfo.environment["PET_FORCE_FALLBACK"] == "1",
        appSwitchCooldown: TimeInterval = 20
    ) {
        self.forceFallback = forceFallback
        self.appSwitchCooldown = appSwitchCooldown
        Self.log.info("Model availability: \(String(describing: self.model.availability), privacy: .public)")
        prepareNextSession()
    }

    func handle(_ trigger: Trigger) {
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

    /// App switches are rate-limited so the pet isn't chatty; going idle and coming back always get through.
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
            // guardrailViolation, exceededContextWindowSize, unsupportedLanguageOrLocale, … all degrade the same way.
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

    /// The first unavailable fallback tells the user why the pet is in simple mode; later ones stay quiet.
    private func explainOnce(_ reason: SystemLanguageModel.Availability.UnavailableReason, over reaction: PetReaction) -> PetReaction {
        guard !hasExplainedFallback else { return reaction }
        hasExplainedFallback = true
        Self.log.notice("Model unavailable, using fallbacks: \(String(describing: reason), privacy: .public)")
        return PetReaction(action: reaction.action, mood: .concerned, dialogue: Self.explanation(for: reason))
    }

    private static func explanation(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This Mac can't run Apple Intelligence, so I'll keep it simple."
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off, so I'll keep it simple."
        case .modelNotReady: "My brain is still downloading. Simple mode for now!"
        @unknown default: "My brain isn't available, so I'll keep it simple."
        }
    }
}

nonisolated struct TriggerRecord: Equatable {
    let trigger: Trigger
    let at: Date
}

nonisolated extension Trigger {
    static let maxAppNameLength = 40
    private static let promptLocale = Locale(identifier: "en_US") // the prompt is English regardless of system locale

    /// Full sentence for the "Now:" line.
    var promptLine: String {
        switch self {
        // App names are quoted so the model reads them as data, not as more instructions.
        case .appSwitched(let name): "The user switched to the app \"\(name)\"."
        case .wentIdle(let seconds): "The user has been away from the keyboard for \(Self.format(seconds, width: .wide))."
        case .returned(let seconds): "The user came back after \(Self.format(seconds, width: .wide)) away."
        }
    }

    /// Short form for the recent-events list.
    var memoryLine: String {
        switch self {
        case .appSwitched(let name): "switched to \"\(name)\""
        case .wentIdle: "went idle"
        case .returned(let seconds): "came back after \(Self.format(seconds, width: .wide))"
        }
    }

    /// App names are external input going into the prompt: flatten whitespace (no forged prompt lines),
    /// swap double quotes (can't break out of the quoting), and cap length.
    var sanitized: Trigger {
        guard case .appSwitched(let name) = self else { return self }
        let flat = name.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "\"", with: "'")
        return .appSwitched(name: flat.isEmpty ? "Unknown" : String(flat.prefix(Self.maxAppNameLength)))
    }

    static func format(_ seconds: TimeInterval, width: Duration.UnitsFormatStyle.UnitWidth) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: width, maximumUnitCount: 1).locale(promptLocale)
        )
    }
}
