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
    /// Tries before a repeated line gives way to a canned one.
    nonisolated static let freshAttempts = 2
    /// Share of encouraging moments that bring up a recent chat instead, when there is one (M19).
    nonisolated static let topicShare = 2.0 / 3
    /// Topics come from the newest few exchanges.
    nonisolated static let topicPool = 5
    /// How much of a question and an answer the topic prompt quotes.
    nonisolated static let topicQuote = (question: 300, answer: 500)
    /// The small model repeats itself even when told not to: topics get a few more tries.
    nonisolated static let topicAttempts = 3
    /// Sampling temperature for a retry after a repeated line.
    nonisolated static let retryTemperature = 1.2

    /// Device-neutral base; the friend's name and persona are appended once per personality version.
    nonisolated static let baseInstructions = """
        You are a small, friendly companion who lives on the user's devices.
        You notice what the user is doing and react briefly, like a playful friend.

        Pick one of the allowed actions; use sleep only when the user has gone idle.
        Pick the allowed mood that matches the dialogue.

        Rules:
        - Dialogue is one short sentence, at most 12 words, spoken to the user.
        - React to what the user did; don't narrate it back to them.
        - Mention the app name only sometimes.
        - Be warm and playful, never judgmental, pushy, or preachy.
        - Never mention being an AI or a language model.
        """

    public var onReaction: (PetReaction) -> Void = { _ in }
    /// What the current skin can play, offered to the model as its only choices; the built-in names by default.
    public var skin: () -> (actions: [PetAction], moods: [PetMood]) = { (PetAction.builtIn, PetMood.builtIn) }
    /// A line about what the user is doing right now, e.g. a focus session, added under the current trigger.
    public var context: () -> String? = { nil }
    /// Recent chat questions and answers, newest first, for the friend to bring up (M19).
    public var chatExchanges: () -> [ChatExchange] = { [] }
    /// For tests: whether this encouraging moment brings up a chat.
    var rollTopic: () -> Bool = { Double.random(in: 0..<1) < PetBrain.topicShare }

    /// Never interpolated per call, so it stays byte-identical for the life of this brain.
    let instructions: String
    /// For checking in about earlier chats: their own rules, the same name and persona.
    let topicInstructions: String
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
    private let saidStore: UserDefaults
    private var said: SaidLines

    public init(
        friend: FriendProfile? = nil,
        forceFallback: Bool = ProcessInfo.processInfo.environment["PET_FORCE_FALLBACK"] == "1",
        appSwitchCooldown: TimeInterval = 20,
        saidStore: UserDefaults = .standard
    ) {
        self.saidStore = saidStore
        self.said = SaidLines.load(from: saidStore)
        self.instructions = Self.makeInstructions(for: friend)
        self.topicInstructions = Self.makeInstructions(for: friend, base: Self.topicBase)
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

    /// Fresh encouraging lines to show later (the widget's hours), kept out of the recent-events memory.
    public func encouragements(_ count: Int) async -> [PetReaction] {
        var lines: [PetReaction] = []
        for _ in 0..<count {
            lines.append(await makeReaction(for: TriggerRecord(trigger: .encourage, at: .now)))
        }
        return lines
    }

    /// An instant reaction without the model: a phrasebook line, or a canned one.
    public func quickReaction(to trigger: Trigger, mood: PetMood? = nil) -> PetReaction {
        let trigger = trigger.sanitized
        if trigger == .encourage { return PetReaction.encouragement(avoiding: said) }
        return phrasebook?.reaction(for: trigger, mood: mood) ?? PetReaction.fallback(for: trigger).clamped(for: trigger)
    }

    nonisolated static let topicBase = """
        You are a small, friendly companion who lives on the user's devices. Earlier the user asked you something in \
        chat. Check in about it later, like a friend who remembers: name its subject in a few words and ask how it \
        turned out or how it's going, in the shape of "Did the <subject> work out?" or "How's the <subject> going?". \
        Keep it short. Don't repeat their question or your answer. Never mention being an AI.
        """

    nonisolated static func makeInstructions(for friend: FriendProfile?, base: String = baseInstructions) -> String {
        guard let friend else { return base }
        var text = base + "\n\nYour name is \"\(flattened(friend.name))\". Call the user \"\(flattened(friend.userNickname))\"."
        if let persona = friend.personality.content?.instructions, !persona.isEmpty {
            text += "\n\n" + persona
        }
        return text
    }

    /// Names are user input: keep them on one line and inside their quotes.
    nonisolated static func flattened(_ text: String) -> String {
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
        let reaction: PetReaction
        if let exchange = topic(for: record.trigger) {
            reaction = await topicReaction(about: exchange)
        } else if forceFallback {
            reaction = quickReaction(to: record.trigger)
        } else {
            switch model.availability {
            case .available:
                reaction = await generate(for: record).clamped(for: record.trigger)
            case .unavailable where record.trigger.kind == .encourage:
                reaction = quickReaction(to: record.trigger) // an encouragement may be read hours later: no explaining
            case .unavailable(let reason):
                reaction = explainOnce(reason, over: quickReaction(to: record.trigger))
            }
        }
        if record.trigger.wantsFreshLine {
            said = said.adding(reaction.dialogue)
            said.save(to: saidStore)
        }
        return reaction
    }

    /// The exchange to bring up: always for `.chatTopic`, mostly for `.encourage`, never without recent chats.
    private func topic(for trigger: Trigger) -> ChatExchange? {
        switch trigger {
        case .chatTopic: break
        case .encourage: guard rollTopic() else { return nil }
        default: return nil
        }
        return chatExchanges().prefix(Self.topicPool).randomElement()
    }

    /// A fresh, one-time session (not the chat's own, not the reactions') checks in about the exchange and suggests a
    /// follow-up question.
    private func topicReaction(about exchange: ChatExchange) async -> PetReaction {
        let fallback = PetReaction(action: .think, mood: .curious, dialogue: Self.cannedTopicLine(exchange.question, avoiding: said),
                                   followUp: ChatFollowUp(conversationID: exchange.conversationID, question: exchange.question))
        guard !forceFallback, model.isAvailable else { return fallback }
        var prompt = Self.topicPrompt(exchange)
        if let avoid = said.promptLine { prompt += "\n" + avoid }
        do {
            let (actions, moods) = skin()
            let schema = try PetReaction.topicSchema(actions: actions, moods: moods)
            for attempt in 0..<Self.topicAttempts {
                let session = LanguageModelSession(model: model, instructions: topicInstructions)
                // A retry means the first line repeated an old one: loosen up so the second one differs.
                let options = GenerationOptions(temperature: attempt == 0 ? nil : Self.retryTemperature)
                let content = try await session.respond(to: prompt, schema: schema, options: options).content
                let line = try PetReaction(content)
                guard !said.contains(line.dialogue) else {
                    Self.log.debug("Chat topic repeated itself: \(line.dialogue)")
                    continue
                }
                let question = (try? content.value(String.self, forProperty: "followUp"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let followUp = ChatFollowUp(conversationID: exchange.conversationID,
                                            question: question.flatMap { $0.isEmpty ? nil : $0 } ?? exchange.question)
                return PetReaction(action: line.action, mood: line.mood, dialogue: line.dialogue, followUp: followUp)
                    .clamped(for: .chatTopic)
            }
        } catch {
            Self.log.error("Chat topic failed: \(String(describing: error), privacy: .public)")
            return fallback
        }
        Self.log.notice("Chat topic repeated itself twice, using a canned line")
        return fallback
    }

    nonisolated static func topicPrompt(_ exchange: ChatExchange) -> String {
        """
        The user asked: "\(quote(exchange.question, topicQuote.question))"
        You answered: "\(quote(exchange.answer, topicQuote.answer))"
        """
    }

    /// Chat text is the user's own, but it goes inside quotes in the prompt: one line, no double quotes, capped.
    nonisolated static func quote(_ text: String, _ limit: Int) -> String {
        let flat = flattened(text)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// A check-in without the model, in a wording not used lately for this question.
    nonisolated static func cannedTopicLine(_ question: String, avoiding said: SaidLines = SaidLines()) -> String {
        let subject = quote(question, 40)
        let lines = ["Still thinking about “\(subject)”?", "Any news on “\(subject)”?", "How did “\(subject)” turn out?",
                     "Want to dig into “\(subject)” again?"]
        return lines.first { !said.contains($0) } ?? lines.randomElement() ?? lines[0]
    }

    /// Lines that should be fresh are told what was already said, and a repeat is asked again in a new session.
    private func generate(for record: TriggerRecord) async -> PetReaction {
        defer { prepareNextSession() }
        let fresh = record.trigger.wantsFreshLine
        var prompt = Self.dynamicBlock(for: record, memory: memory, context: context())
        if fresh, let avoid = said.promptLine { prompt += "\n" + avoid }
        do {
            let (actions, moods) = skin()
            let schema = try PetReaction.schema(actions: actions, moods: moods)
            for _ in 0..<(fresh ? Self.freshAttempts : 1) {
                let session = nextSession ?? makeSession()
                nextSession = nil
                let reaction = try PetReaction(try await session.respond(to: prompt, schema: schema).content)
                if !fresh || !said.contains(reaction.dialogue) { return reaction }
            }
            Self.log.notice("The model repeated a line, using a canned one")
        } catch {
            // guardrailViolation, exceededContextWindowSize, rateLimited (backgrounded), … all degrade the same way.
            Self.log.error("Generation failed, using the phrasebook: \(String(describing: error), privacy: .public)")
        }
        return quickReaction(to: record.trigger)
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
    nonisolated static func dynamicBlock(for current: TriggerRecord, memory: [TriggerRecord], context: String? = nil) -> String {
        let earlier = memory.filter { $0.at < current.at }.suffix(memoryLimit)
        let history = earlier.isEmpty
            ? "Recent events: none."
            : "Recent events (oldest first):\n" + earlier
                .map { "- \(Trigger.format(current.at.timeIntervalSince($0.at), width: .narrow)) ago: \($0.trigger.memoryLine)" }
                .joined(separator: "\n")
        return history + "\nNow: " + current.trigger.promptLine + (context.map { "\n" + $0 } ?? "")
    }

    /// The first unavailable fallback tells the user why the friend is in simple mode; later ones stay quiet.
    private func explainOnce(_ reason: SystemLanguageModel.Availability.UnavailableReason, over reaction: PetReaction) -> PetReaction {
        guard !hasExplainedFallback else { return reaction }
        hasExplainedFallback = true
        Self.log.notice("Model unavailable, using the phrasebook: \(String(describing: reason), privacy: .public)")
        return PetReaction(action: reaction.action, mood: .concerned, dialogue: Self.explanation(for: reason))
    }

    static func explanation(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This device can't run Apple Intelligence, so I'll keep it simple."
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off, so I'll keep it simple."
        case .modelNotReady: "My brain is still downloading. Simple mode for now!"
        @unknown default: "My brain isn't available, so I'll keep it simple."
        }
    }
}
