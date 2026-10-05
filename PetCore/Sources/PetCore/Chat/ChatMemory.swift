//
//  ChatMemory.swift
//  PetCore
//
//  Memory past the 4K window (M26). Every question and answer is a "turn", embedded on this device and searched
//  like a file passage. Quick recall puts the few most related older turns into the prompt; deep recall reads up to
//  four slices of history, each in its own 4K session that notes what matters for the question, and the answer is
//  written from those notes. Messages the user linked are always recalled together. Only the conversation's own
//  history: each chat sees itself, never the others (M34).
//

import Foundation
import Observation

/// A message, anywhere: which conversation, which message.
public nonisolated struct MessageRef: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { conversationID.uuidString + messageID.uuidString }
    public let conversationID: UUID
    public let messageID: UUID

    public init(conversationID: UUID, messageID: UUID) {
        self.conversationID = conversationID
        self.messageID = messageID
    }
}

/// A question and its answer (or a lone message): what memory stores and recalls.
public nonisolated struct ChatTurn: Equatable, Sendable {
    public let conversationID: UUID
    public let conversationTitle: String
    /// The messages in it; the first names the turn.
    public let messages: [ChatMessage]

    public var ref: MessageRef { MessageRef(conversationID: conversationID, messageID: messages[0].id) }
    public var date: Date { messages.last?.date ?? .distantPast }

    /// "User: … / You: …", each message capped so one long answer can't fill a slice.
    func text(cap: Int = 600) -> String {
        messages.map { message in
            let body = message.text.count > cap ? String(message.text.prefix(cap - 1)) + "…" : message.text
            return (message.role == .user ? "User: " : "You: ") + body
        }.joined(separator: "\n")
    }

    func contains(_ id: UUID) -> Bool { messages.contains { $0.id == id } }
}

public nonisolated enum ChatMemory {
    /// Quick recall: this many older turns at most, within `quickBudget` tokens.
    static let quickTurns = 3
    static let quickBudget = 550
    /// Deep recall: up to `maxPasses` slices of at most `sliceBudget` tokens, from the best `deepCandidates` turns.
    static let maxPasses = 4
    static let sliceBudget = 2800
    static let deepCandidates = 40
    /// Similarity a turn needs to count as related; other conversations need more.
    static let minScore = 0.35
    /// This many strong matches make a question worth a deep recall even without "earlier".
    static let deepWhenStrong = 6
    static let strongScore = 0.6

    /// Turns from messages: each user message with the friend's reply after it; asides and app notes left out.
    public static func turns(of conversation: Conversation) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var pending: ChatMessage?
        for message in conversation.messages where !message.isAside {
            switch message.role {
            case .user:
                if let pending { turns.append(ChatTurn(conversationID: conversation.id, conversationTitle: conversation.title, messages: [pending])) }
                pending = message
            case .friend:
                let messages = pending.map { [$0, message] } ?? [message]
                turns.append(ChatTurn(conversationID: conversation.id, conversationTitle: conversation.title, messages: messages))
                pending = nil
            }
        }
        if let pending { turns.append(ChatTurn(conversationID: conversation.id, conversationTitle: conversation.title, messages: [pending])) }
        return turns
    }

    /// Questions that point back at earlier conversation.
    public static func pointsBack(_ question: String) -> Bool {
        let pattern = #"\b(earlier|before|previously|last (time|week|month|night|year)|yesterday|remember|recall|you said|i said|i told you|did (i|we)|we (decided|agreed|talked|discussed)|what did|again|back when|the other day|ago)\b"#
        return question.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public struct Scored: Equatable, Sendable {
        public let turn: ChatTurn
        public let score: Double
        /// Brought in because the user linked it to a recalled turn.
        public let linked: Bool
    }

    /// Ranks this conversation's older turns for a question; turns still in the prompt and other conversations are
    /// left out. Linked turns follow the turns they're linked to.
    static func rank(question: String, vector: [Double]?, turns: [ChatTurn], vectors: [UUID: [Double]],
                     current: UUID, excluding inPrompt: Set<UUID>, links: (MessageRef) -> [MessageRef]) -> [Scored] {
        let words = Retriever.keywords(question)
        var scored: [Scored] = turns.compactMap { turn in
            guard turn.conversationID == current, !turn.messages.contains(where: { inPrompt.contains($0.id) }) else { return nil }
            let similarity = vector.flatMap { question in vectors[turn.messages[0].id].map { Retriever.cosine(question, $0) } } ?? 0
            let shared = words.intersection(Retriever.keywords(turn.text())).count
            let score = similarity + Double(shared) * Retriever.keywordWeight
            return score >= minScore ? Scored(turn: turn, score: score, linked: false) : nil
        }
        .sorted { $0.score > $1.score }
        // Links: a recalled turn brings the turns linked to any of its messages, right after it.
        var seen = Set(scored.map(\.turn.ref))
        var withLinks: [Scored] = []
        for item in scored {
            withLinks.append(item)
            for message in item.turn.messages {
                for target in links(MessageRef(conversationID: item.turn.conversationID, messageID: message.id)) {
                    guard let linked = turns.first(where: { $0.conversationID == target.conversationID && $0.contains(target.messageID) }),
                          seen.insert(linked.ref).inserted else { continue }
                    withLinks.append(Scored(turn: linked, score: item.score, linked: true))
                }
            }
        }
        scored = withLinks
        return scored
    }

    /// Whether to read history in several passes for this question.
    static func wantsDeep(_ question: String, ranked: [Scored]) -> Bool {
        pointsBack(question) || ranked.filter { $0.score >= strongScore }.count >= deepWhenStrong
    }

    /// Groups turns (best first) into slices that each fit one session; at most `maxPasses`.
    static func slices(_ ranked: [Scored]) -> [[Scored]] {
        var slices: [[Scored]] = []
        var current: [Scored] = []
        var used = 0
        for item in ranked.prefix(deepCandidates) {
            let tokens = ChatPrompt.estimate(item.turn.text()) + 12
            if used + tokens > sliceBudget, !current.isEmpty {
                slices.append(current)
                if slices.count == maxPasses { return slices }
                current = []
                used = 0
            }
            current.append(item)
            used += tokens
        }
        if !current.isEmpty, slices.count < maxPasses { slices.append(current) }
        return slices
    }

    /// The quick-recall block for the prompt, oldest first so it reads like a story.
    static func quickBlock(_ ranked: [Scored]) -> (text: String, used: [Scored])? {
        let picked = Array(ranked.prefix(quickTurns))
        let fitting = picked.prefix(ChatPrompt.fitting(picked.map { ChatPrompt.estimate($0.turn.text(cap: 350)) + 12 }, budget: quickBudget))
        guard !fitting.isEmpty else { return nil }
        let lines = fitting.sorted { $0.turn.date < $1.turn.date }.map { item in
            "- (\(label(item.turn))) " + item.turn.text(cap: 350).replacingOccurrences(of: "\n", with: " / ")
        }
        return ("Recalled from earlier (older than the conversation above):\n" + lines.joined(separator: "\n"), Array(fitting))
    }

    /// "3 Oct".
    static func label(_ turn: ChatTurn) -> String {
        turn.date.formatted(.dateTime.day().month(.abbreviated))
    }

    static let passInstructions = """
        You read earlier messages between the user and their companion and note what helps answer the user's new \
        question: facts, names, numbers, decisions, plans. Write at most 5 short bullet points, each saying when or \
        where it came from if that matters. If nothing in them helps, write exactly: Nothing relevant.
        """

    static func passPrompt(question: String, slice: [Scored]) -> String {
        "New question: \(question)\n\nEarlier messages:\n" + slice.sorted { $0.turn.date < $1.turn.date }.map { item in
            "(\(label(item.turn)))\n" + item.turn.text()
        }.joined(separator: "\n\n")
    }

    /// A pass that found nothing says so; anything else is notes.
    static func isEmptyNote(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("nothing relevant")
    }

    /// The chip under an answer: "Remembered · 3 Oct".
    static func source(_ item: Scored) -> ChatSource {
        ChatSource(documentName: "Remembered · " + label(item.turn), kind: .memory, locator: .none, text: item.turn.text(cap: 4000))
    }
}

/// This device's embeddings of every turn's question, cached on disk and filled in as chats grow (or sync in).
@MainActor @Observable
public final class ChatMemoryIndex {
    @ObservationIgnored private var vectors: [UUID: [Double]] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var dirty = false

    public init(folder: URL) {
        file = folder.appending(path: "memory-vectors.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([UUID: [Float]].self, from: data) {
            vectors = saved.mapValues { $0.map(Double.init) }
        }
    }

    /// Vectors for every turn, embedding the ones not seen before (off the main actor).
    func vectors(for turns: [ChatTurn]) async -> [UUID: [Double]] {
        let missing = turns.filter { vectors[$0.messages[0].id] == nil }.map { ($0.messages[0].id, $0.text(cap: 400)) }
        if !missing.isEmpty {
            let made = await Task.detached { missing.compactMap { id, text in Retriever.embed(text).map { (id, $0) } } }.value
            for (id, vector) in made { vectors[id] = vector }
            dirty = true
            save()
        }
        return vectors
    }

    private func save() {
        guard dirty else { return }
        dirty = false
        let compact = vectors.mapValues { $0.map(Float.init) } // half the size; similarity doesn't need doubles
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(compact).write(to: file, options: .atomic)
    }
}
