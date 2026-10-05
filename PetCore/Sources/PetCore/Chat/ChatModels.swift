//
//  ChatModels.swift
//  PetCore
//
//  Local RAG chat (M18): the user's files as searchable passages, and saved conversations. Everything stays on
//  this device, in Application Support/Chat.
//

import Foundation
import Observation

/// Where a passage sits in its file, for the source chips.
public nonisolated enum PassageLocator: Codable, Equatable, Hashable, Sendable {
    case page(Int)
    case time(TimeInterval)
    case none

    /// "p.3", "02:14", or nothing.
    public var label: String? {
        switch self {
        case .page(let page): "p.\(page)"
        case .time(let seconds): Pomodoro.clock(seconds.rounded(.down))
        case .none: nil
        }
    }
}

public nonisolated enum ChatDocumentKind: String, Codable, Sendable {
    case text, pdf, image, audio, video
    /// A page found on the web (M21).
    case web
    /// An earlier turn memory recalled (M26): only ever a source chip, never a file.
    case memory

    public var symbol: String {
        switch self {
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .web: "globe"
        case .memory: "clock.arrow.circlepath"
        }
    }
}

/// A searchable piece of a file: its text, an English note saying what it covers (the text itself when it's
/// already English), and the note's embedding.
public nonisolated struct IndexedPassage: Codable, Equatable, Sendable {
    public let text: String
    public let note: String
    public let vector: [Double]?
    public let locator: PassageLocator
}

public nonisolated struct ChatDocument: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: Codable, Equatable, Hashable, Sendable {
        /// Searched by every conversation.
        case library
        /// Attached to one conversation only.
        case conversation(UUID)
        /// In a conversation's message box, not sent yet: neither searched nor synced. Sending attaches it to the
        /// message and the conversation, as in Claude.
        case draft(UUID)
    }

    public let id: UUID
    public let name: String
    public let kind: ChatDocumentKind
    public let scope: Scope
    public let addedAt: Date
    public let passages: [IndexedPassage]
    /// E.g. "Only the first 15 minutes were used."
    public let note: String?
    /// The spoken language it was transcribed in (audio and video), as a locale identifier.
    public let language: String?
    /// Where a web page came from.
    public let url: URL?
    /// Last changed on any device, for sync (the newer copy wins).
    public var modifiedAt: Date?

    public init(id: UUID = UUID(), name: String, kind: ChatDocumentKind, scope: Scope, addedAt: Date = .now,
                passages: [IndexedPassage], note: String? = nil, language: String? = nil, url: URL? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scope = scope
        self.addedAt = addedAt
        self.passages = passages
        self.note = note
        self.language = language
        self.url = url
    }

    public var isDraft: Bool { if case .draft = scope { true } else { false } }

    public func with(scope: Scope) -> ChatDocument {
        ChatDocument(id: id, name: name, kind: kind, scope: scope, addedAt: addedAt, passages: passages, note: note,
                     language: language, url: url)
    }

    func with(passages: [IndexedPassage]) -> ChatDocument {
        var copy = ChatDocument(id: id, name: name, kind: kind, scope: scope, addedAt: addedAt, passages: passages, note: note,
                                language: language, url: url)
        copy.modifiedAt = modifiedAt
        return copy
    }

    /// For upload: embeddings are big and each device makes its own.
    func withoutVectors() -> ChatDocument {
        with(passages: passages.map { IndexedPassage(text: $0.text, note: $0.note, vector: nil, locator: $0.locator) })
    }

    /// After download: embeddings for passages that came without them.
    func embedded() -> ChatDocument {
        with(passages: passages.map { $0.vector != nil ? $0 : IndexedPassage(text: $0.text, note: $0.note, vector: Retriever.embed($0.note), locator: $0.locator) })
    }
}

/// A passage an answer used, copied into the message so its chip still works after the file is removed.
public nonisolated struct ChatSource: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(documentName)|\(locator.label ?? "")|\(text.hashValue)" }
    public let documentName: String
    public let kind: ChatDocumentKind
    public let locator: PassageLocator
    public let text: String
    /// The page, for web sources.
    public var url: URL? = nil

    public var label: String { [documentName, locator.label].compactMap { $0 }.joined(separator: " · ") }

    /// One chip per place: passages from the same page (or the same page of a file) are shown together.
    static func merged(_ sources: [ChatSource]) -> [ChatSource] {
        var order: [String] = []
        var texts: [String: [String]] = [:]
        var first: [String: ChatSource] = [:]
        for source in sources {
            let key = source.label + "|" + (source.url?.absoluteString ?? "")
            if first[key] == nil { order.append(key); first[key] = source }
            texts[key, default: []].append(source.text)
        }
        return order.compactMap { key in
            first[key].map { ChatSource(documentName: $0.documentName, kind: $0.kind, locator: $0.locator,
                                        text: texts[key, default: []].joined(separator: "\n\n…\n\n"), url: $0.url) }
        }
    }
}

public nonisolated struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, friend }

    public let id: UUID
    public let role: Role
    public let text: String
    public let sources: [ChatSource]
    public let date: Date
    /// Stopped by the guardrail (the message and the friend's "what do you mean?"): shown, never used as context.
    public let aside: Bool?
    /// Files the friend made for this reply (M25).
    public let files: [ChatFile]?
    /// Messages the user linked this one to (M26): recalled together with it.
    public var links: [MessageRef]?
    /// The plan and sources of a research report (M28).
    public var research: ResearchLog?
    /// The 9Router model that wrote this answer (M37), for the chip under it; nil on-device.
    public var model: String?
    /// Files sent with this message: shown on it, and searched by the conversation from then on.
    public var attachments: [Attachment]?

    /// A sent file, by name and kind, so the chip stays even after the file is removed.
    public struct Attachment: Codable, Equatable, Hashable, Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let kind: ChatDocumentKind
    }
    /// A button under the friend's answer (M32): search the web for the question, or research it in depth.
    public var offer: Offer?

    public enum Offer: String, Codable, Sendable {
        case web, research
        /// The user's own model couldn't answer (M37): ask again on Apple's model, this once.
        case onDevice

        /// What the router's pick offers: the web only when the toggle is off (it's never searched unasked), and
        /// research always (it's long and online, so it waits for a tap).
        static func after(_ action: ChatRouter.Action, web: Bool) -> Offer? {
            switch action {
            case .web: web ? nil : .web
            case .research: .research
            default: nil
            }
        }
    }

    public init(id: UUID = UUID(), role: Role, text: String, sources: [ChatSource] = [], date: Date = .now, aside: Bool = false,
                files: [ChatFile]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
        self.date = date
        self.aside = aside ? true : nil
        self.files = files
    }

    public var isAside: Bool { aside == true }

    /// The same message with new text (an edited diagram, M29), keeping its links and research.
    func with(text: String) -> ChatMessage {
        var copy = ChatMessage(id: id, role: role, text: text, sources: sources, date: date, aside: isAside, files: files)
        copy.links = links
        copy.research = research
        copy.offer = offer
        copy.attachments = attachments
        copy.model = model
        return copy
    }

    func markedAside() -> ChatMessage {
        var copy = ChatMessage(id: id, role: role, text: text, sources: sources, date: date, aside: true, files: files)
        copy.links = links
        copy.attachments = attachments
        return copy
    }
}

/// One agent's share of a turn (M36): what it was, and the tokens its session used of its 4K.
public nonisolated struct AgentUse: Codable, Equatable, Sendable {
    public let name: String
    public let tokens: Int
}

public nonisolated struct Conversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var messages: [ChatMessage] = []
    /// What the model remembers of the messages before `summarizedCount`, which it no longer sees.
    public var summary: String?
    public var summarizedCount = 0
    /// Tokens the last exchange used (instructions, prompt and answer), for the context meter. For a turn of many
    /// agents (M36), the fullest agent's.
    public var contextUsed: Int?
    /// A turn of many agents: each one's use (its own 4K). Nil for a single answer.
    public var contextAgents: [AgentUse]?
    /// Last changed on any device, for sync (the newer copy wins).
    public var modifiedAt: Date?

    public init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
    }

    public static let titleLength = 40

    public var title: String {
        guard let first = messages.first(where: { $0.role == .user && !$0.isAside })?.text else { return "New conversation" }
        let flat = first.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > Self.titleLength ? String(flat.prefix(Self.titleLength - 1)) + "…" : flat
    }

    public var updatedAt: Date { messages.last?.date ?? createdAt }
}

/// A question the friend suggests asking next about an earlier chat (M19), and the conversation it came from.
public nonisolated struct ChatFollowUp: Codable, Equatable, Hashable, Sendable {
    public let conversationID: UUID
    public let question: String

    public init(conversationID: UUID, question: String) {
        self.conversationID = conversationID
        self.question = question
    }
}

/// One question the user asked in chat and the friend's answer, for the friend to bring up later.
public nonisolated struct ChatExchange: Equatable, Sendable {
    public let conversationID: UUID
    public let question: String
    public let answer: String
    public let date: Date
}

/// Open Chat on a conversation (nil: a new one) with `draft` typed in the box, not sent.
public nonisolated struct ChatStart: Equatable, Sendable {
    public let conversation: UUID?
    public let draft: String

    public init(conversation: UUID?, draft: String) {
        self.conversation = conversation
        self.draft = draft
    }
}

/// Asks an open (or about to open) ChatRoot to go somewhere: the friend's follow-up buttons set `pending`.
@MainActor @Observable
public final class ChatNavigator {
    public var pending: ChatStart?

    public init() {}
}

/// Splits text into passages of about `target` words, on sentence boundaries, keeping each piece's locator.
public nonisolated enum Chunker {
    public static let target = 120

    public static func passages(from segments: [(text: String, locator: PassageLocator)], target: Int = target) -> [(text: String, locator: PassageLocator)] {
        var result: [(String, PassageLocator)] = []
        var current: [String] = []
        var words = 0
        var locator = PassageLocator.none
        func flush() {
            let text = current.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append((text, locator)) }
            current = []
            words = 0
        }
        for segment in segments {
            // Pages stand alone: a passage never spans two, so its chip names one page.
            if case .page = segment.locator { flush() }
            for sentence in sentences(in: segment.text, target: target) {
                if current.isEmpty { locator = segment.locator }
                current.append(sentence)
                words += sentence.split(whereSeparator: \.isWhitespace).count
                if words >= target { flush() }
            }
        }
        flush()
        return result
    }

    /// Sentences, with any run-on longer than `target` words (OCR, transcripts without punctuation) cut into pieces.
    static func sentences(in text: String, target: Int = target) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            let words = sentence.split(whereSeparator: \.isWhitespace)
            guard words.count > target else { return sentences.append(sentence) }
            sentences += stride(from: 0, to: words.count, by: target).map { words[$0..<min($0 + target, words.count)].joined(separator: " ") }
        }
        return sentences
    }
}
