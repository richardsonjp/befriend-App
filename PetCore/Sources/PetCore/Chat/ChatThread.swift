//
//  ChatThread.swift
//  PetCore
//
//  One conversation with the friend about the user's files, on the on-device model. Each turn is a fresh session:
//  the instructions, then a prompt holding the summary of older messages, the recent ones that fit, the passages
//  that matched, and the question (see ChatPrompt). Answers stream in.
//

import Foundation
import FoundationModels
import Observation
import os

@MainActor @Observable
public final class ChatThread {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "chat")

    public enum State: Equatable {
        case idle
        /// Making sure a borderline message means something (the guardrail's model check).
        case checking
        case compacting
        case searching
        /// Reading links or searching the web, with what it's doing.
        case browsing(String)
        case answering(String)
    }

    /// Pages kept from one web search (links in the message come on top).
    nonisolated static let webPages = 5

    public private(set) var conversation: Conversation
    public private(set) var state = State.idle
    public private(set) var failure: String?
    /// A heads-up about the last turn that didn't stop it, e.g. the web search finding nothing.
    public private(set) var notice: String?
    /// Tokens in the instructions alone: the meter's reading before the first answer.
    public private(set) var baseline: Int?
    private let library: ChatLibrary
    private let instructions: String
    private let model = SystemLanguageModel.default
    @ObservationIgnored private var turn: Task<Void, Never>?
    /// Pages this question's browsing saved: they rank first for it.
    @ObservationIgnored private var justFound: Set<UUID> = []

    public init(_ conversation: Conversation, library: ChatLibrary, friend: FriendProfile?) {
        self.conversation = conversation
        self.library = library
        self.instructions = ChatPrompt.instructions(for: friend)
        Task { baseline = await count(instructions: instructions) }
    }

    public var contextSize: Int { model.contextSize }
    public var contextUsed: Int { conversation.contextUsed ?? baseline ?? ChatPrompt.estimate(instructions) }

    /// Why chat can't run here, or nil when it can.
    public var unavailable: String? {
        if case .unavailable(let reason) = model.availability {
            return PetBrain.explanation(for: reason).replacingOccurrences(of: ", so I'll keep it simple.", with: ", so chat can't run.")
        }
        return nil
    }

    /// With `web`, the question is also searched on the web; links in it are read either way.
    public func send(_ question: String, web: Bool = false) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, state == .idle, unavailable == nil else { return }
        failure = nil
        notice = nil
        conversation.messages.append(ChatMessage(role: .user, text: question))
        library.save(conversation)
        state = .searching // busy from the moment it's sent, so Stop works at once
        turn = Task {
            let sensible = await makesSense(question)
            guard !Task.isCancelled else { return } // stopped: stop() already tidied up
            guard sensible else { return clarify() }
            await browse(for: question, web: web)
            guard !Task.isCancelled else { return }
            await answer(question)
        }
    }

    /// Edits one of the user's messages: it and everything after it go, and the new text is sent in its place.
    public func resend(from messageID: UUID, as text: String, web: Bool = false) {
        guard state == .idle, let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        conversation.messages.removeSubrange(index...)
        if conversation.summarizedCount > index {
            // The notes covered messages that are gone: start them over; compaction redoes them if needed.
            conversation.summary = nil
            conversation.summarizedCount = 0
        }
        conversation.contextUsed = nil
        send(text, web: web)
    }

    /// A newer copy from the other device (sync): taken while nothing is under way here.
    public func refresh(from latest: Conversation) {
        guard state == .idle, (latest.modifiedAt ?? .distantPast) > (conversation.modifiedAt ?? .distantPast) else { return }
        conversation = latest
    }

    // MARK: Guardrail

    /// The instant check, then the model for borderline messages.
    private func makesSense(_ question: String) async -> Bool {
        switch MessageCheck.judge(question) {
        case .valid: return true
        case .gibberish: return false
        case .unsure:
            state = .checking
            return await MessageCheck.askModel(question, model: model)
        }
    }

    /// Gibberish: the friend asks what was meant. Neither message is used as context later.
    private func clarify() {
        if let last = conversation.messages.indices.last { conversation.messages[last] = conversation.messages[last].markedAside() }
        let reply = MessageCheck.clarifications.randomElement() ?? MessageCheck.clarifications[0]
        conversation.messages.append(ChatMessage(role: .friend, text: reply, aside: true))
        library.save(conversation)
        state = .idle
    }

    // MARK: Web

    /// Reads the message's links and, with `web`, searches; what's found becomes this conversation's Web files, so
    /// the answer (and later questions) can use it. Each page is cut to its closest passages before the model sees it.
    private func browse(for question: String, web: Bool) async {
        let links = WebSearch.links(in: question)
        guard web || !links.isEmpty else { return }
        state = .browsing(links.isEmpty ? "Searching the web…" : "Reading the link…")
        var sources: [WebSource] = []
        var unread: [String] = []
        for link in links {
            do { sources.append(try await WebSearch.fetch(link)) } catch { unread.append(link.host() ?? link.absoluteString) }
        }
        if web {
            let queries = await searchQueries(for: question)
            state = .browsing("Searching the web for “\(queries.first ?? question)”…")
            async let searched = try? WebSearch.search(objective: question, queries: queries)
            async let encyclopedia = try? WebSearch.wikipedia(queries.first ?? question, limit: 1)
            let found = ((await searched) ?? []) + ((await encyclopedia) ?? [])
            let linked = sources.count
            sources = Array(WebSource.distinct(sources + found).prefix(linked + Self.webPages))
            if found.isEmpty { unread.append("the web search") }
        }
        guard !Task.isCancelled else { return }
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor [weak self] in
                guard let self, case .browsing = self.state else { return } // stopped meanwhile
                self.state = .browsing(status)
            }
        }
        let added = await library.addWeb(sources, question: question, scope: .conversation(conversation.id), progress: report)
        justFound = Set(added.map(\.id))
        if !unread.isEmpty {
            notice = "Couldn't read " + ListFormatter.localizedString(byJoining: unread) + (added.isEmpty ? "." : "; answering from what was found.")
        }
    }

    /// Two or three short search queries from the model; the question itself if the model can't.
    private func searchQueries(for question: String) async -> [String] {
        guard model.isAvailable else { return [String(question.prefix(100))] }
        let session = LanguageModelSession(model: model, instructions: ChatPrompt.queryInstructions)
        let text = (try? await session.respond(to: "Question: " + question).content) ?? ""
        let queries = ChatPrompt.queries(from: text)
        return queries.isEmpty ? [String(question.prefix(100))] : queries
    }

    /// Stops searching, reading and answering at once. Before the friend wrote anything, the question is taken back
    /// out of the chat and returned, for the message box; after, the partial answer stays and nil comes back.
    @discardableResult
    public func stop() -> String? {
        let early: Bool
        switch state {
        case .idle: return nil
        case .answering(let text): early = text.isEmpty
        default: early = true
        }
        turn?.cancel()
        turn = nil
        state = .idle
        guard early, let last = conversation.messages.last, last.role == .user else { return nil }
        conversation.messages.removeLast()
        library.save(conversation)
        return last.text
    }

    private func answer(_ question: String) async {
        // A stopped turn leaves the state alone: the next message may already be under way.
        defer { if !Task.isCancelled { state = .idle } }
        let budget = ChatPrompt.split(contextSize: contextSize, instructions: ChatPrompt.estimate(instructions),
                                      question: ChatPrompt.estimate(question))
        state = .searching
        let hits = Retriever.rank(question, vector: Retriever.embed(question), in: library.documents(for: conversation.id),
                                  boosting: justFound)
        justFound = []
        let passageTokens = hits.map { ChatPrompt.estimate($0.passage.text) + 20 }
        let passages = Array(hits.prefix(ChatPrompt.fitting(passageTokens, budget: budget.passages)))
        // Room the passages didn't need goes to the conversation.
        let history = budget.history + budget.passages - passageTokens.prefix(passages.count).reduce(0, +)
        await compactIfNeeded(budget: history)

        let earlier = conversation.messages[conversation.summarizedCount..<(conversation.messages.count - 1)].filter { !$0.isAside }
        let summaryTokens = conversation.summary.map(ChatPrompt.estimate) ?? 0
        let keep = ChatPrompt.fitting(earlier.reversed().map { ChatPrompt.estimate($0.text) + 4 }, budget: history - summaryTokens)
        let prompt = ChatPrompt.make(summary: conversation.summary, recent: Array(earlier.suffix(keep)), passages: passages, question: question)

        let session = LanguageModelSession(model: model, instructions: instructions)
        var text = ""
        do {
            state = .answering("")
            for try await snapshot in session.streamResponse(to: prompt) {
                guard !Task.isCancelled else { break }
                text = snapshot.content
                state = .answering(text)
            }
        } catch is CancellationError {
            // Stopped: keep what was written.
        } catch {
            Self.log.error("Chat answer failed: \(String(describing: error), privacy: .public)")
            if text.isEmpty { return failure = Self.message(for: error) }
        }
        guard !text.isEmpty else { return }
        conversation.messages.append(ChatMessage(role: .friend, text: text, sources: ChatSource.merged(passages.map(\.source))))
        conversation.contextUsed = await count(instructions: instructions, prompt: prompt, answer: text)
        library.save(conversation)
    }

    /// Summarises the oldest messages the history budget can't hold, a chunk at a time, showing `.compacting`.
    private func compactIfNeeded(budget: Int) async {
        while true {
            let open = Array(conversation.messages[conversation.summarizedCount..<(conversation.messages.count - 1)])
            let count = ChatPrompt.toCompact(messageTokens: open.map { ChatPrompt.estimate($0.text) + 4 },
                                             summaryTokens: conversation.summary.map(ChatPrompt.estimate) ?? 0, budget: budget)
            guard count > 0 else { return }
            state = .compacting
            let chunk = ChatPrompt.fitting(open.prefix(count).map { ChatPrompt.estimate($0.text) + 4 }, budget: ChatPrompt.compactChunk)
            let batch = Array(open.prefix(max(1, chunk)))
            let session = LanguageModelSession(model: model, instructions: ChatPrompt.summarizerInstructions)
            let request = ChatPrompt.summaryRequest(previous: conversation.summary, messages: batch.filter { !$0.isAside })
            if let summary = try? await session.respond(to: request).content {
                conversation.summary = String(summary.prefix(ChatPrompt.summaryLimit))
            } else {
                Self.log.notice("Summarising failed; the oldest messages are dropped without a summary")
            }
            conversation.summarizedCount += batch.count
            library.save(conversation)
        }
    }

    /// Exact counts on 26.4 and later; an estimate before that.
    private func count(instructions: String, prompt: String = "", answer: String = "") async -> Int {
        if #available(iOS 26.4, macOS 26.4, *), model.isAvailable {
            do {
                let fixed = try await model.tokenCount(for: Instructions(instructions))
                let asked = prompt.isEmpty ? 0 : try await model.tokenCount(for: prompt)
                let said = answer.isEmpty ? 0 : try await model.tokenCount(for: answer)
                return fixed + asked + said
            } catch {
                Self.log.notice("Token count failed: \(String(describing: error), privacy: .public)")
            }
        }
        return [instructions, prompt, answer].map(ChatPrompt.estimate).reduce(0, +)
    }

    static func message(for error: Error) -> String {
        switch error as? LanguageModelSession.GenerationError {
        case .guardrailViolation?, .refusal?: "I can't help with that one. Try asking another way?"
        case .exceededContextWindowSize?: "That was too much for me at once. Try a shorter question, or start a new conversation."
        case .assetsUnavailable?: "My brain isn't ready yet. Try again in a moment."
        case .rateLimited?, .concurrentRequests?: "I'm a bit busy. Try again in a moment."
        case .unsupportedLanguageOrLocale?: "I can't answer in that language yet."
        default: "Something went wrong. Try again?"
        }
    }
}
