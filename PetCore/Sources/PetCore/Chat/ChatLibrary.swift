//
//  ChatLibrary.swift
//  PetCore
//
//  The chat's files and conversations, saved as JSON in Application Support/Chat on this device only. Adding a
//  file runs in the background: extract its text (Ingest), split it into passages, give each an English note (the
//  model translates or sums up passages in other languages, so English questions find them) and an embedding.
//

import Foundation
import UniformTypeIdentifiers
import Speech
import ImageIO
import AVFoundation
import FoundationModels
import NaturalLanguage
import Observation
import os

@MainActor @Observable
public final class ChatLibrary {
    private nonisolated static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "chat")

    /// A file being added, with what it's doing now.
    public struct Job: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let kind: ChatDocumentKind
        public let scope: ChatDocument.Scope
        /// The spoken language (audio and video), as a locale identifier.
        public let language: String?
        public var status: String
        public var failure: String?
    }

    public private(set) var documents: [ChatDocument] = []
    public private(set) var conversations: [Conversation] = []
    public private(set) var jobs: [Job] = []
    /// Files with a saved thumbnail (images and videos).
    public private(set) var thumbnails: Set<UUID> = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Where each file added this session came from, so audio and video can be transcribed again in another
    /// language. Temporary copies (Photos, the clipboard) are deleted with their file.
    @ObservationIgnored private var sources: [UUID: (url: URL, temporary: Bool)] = [:]
    private let root: URL

    public init(root: URL = URL.applicationSupportDirectory.appending(path: "Chat", directoryHint: .isDirectory)) {
        self.root = root
        documents = Self.loadAll(ChatDocument.self, from: documentsDir).sorted { $0.addedAt > $1.addedAt }
        conversations = Self.loadAll(Conversation.self, from: conversationsDir).sorted { $0.updatedAt > $1.updatedAt }
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: thumbnailsDir.path)) ?? []
        thumbnails = Set(saved.compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) })
    }

    private var thumbnailsDir: URL { root.appending(path: "Thumbnails", directoryHint: .isDirectory) }

    public func thumbnail(for id: UUID) -> URL? {
        thumbnails.contains(id) ? thumbnailsDir.appending(path: "\(id).jpg") : nil
    }

    private var documentsDir: URL { root.appending(path: "Documents", directoryHint: .isDirectory) }
    private var conversationsDir: URL { root.appending(path: "Conversations", directoryHint: .isDirectory) }

    public var libraryDocuments: [ChatDocument] { documents.filter { $0.scope == .library } }

    /// What a conversation searches: the library, and files attached to it.
    public func documents(for conversation: UUID) -> [ChatDocument] {
        documents.filter { $0.scope == .library || $0.scope == .conversation(conversation) }
    }

    public func attached(to conversation: UUID) -> [ChatDocument] {
        documents.filter { $0.scope == .conversation(conversation) }
    }

    // MARK: Conversations

    /// Questions and their answers from the last `days`, newest first: what the friend may bring up (M19).
    public func recentExchanges(days: Int = 7, now: Date = .now) -> [ChatExchange] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        return conversations.flatMap { conversation in
            zip(conversation.messages, conversation.messages.dropFirst()).compactMap { question, answer in
                guard question.role == .user, answer.role == .friend, answer.date >= since else { return nil }
                return ChatExchange(conversationID: conversation.id, question: question.text, answer: answer.text, date: answer.date)
            }
        }
        .sorted { $0.date > $1.date }
    }

    public func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    public func save(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        Self.write(conversation, to: conversationsDir.appending(path: "\(conversation.id).json"))
    }

    /// Also removes the files attached to it.
    public func delete(conversation id: UUID) {
        conversations.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: conversationsDir.appending(path: "\(id).json"))
        for document in attached(to: id) { delete(document: document.id) }
    }

    // MARK: Files

    public func delete(document id: UUID) {
        documents.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: documentsDir.appending(path: "\(id).json"))
        forget(id)
    }

    /// Shares a conversation's file with every conversation.
    public func moveToLibrary(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index] = documents[index].with(scope: .library)
        Self.write(documents[index], to: documentsDir.appending(path: "\(id).json"))
    }

    /// Adds a file the user picked. `language` is the spoken language for audio and video; by default the device's
    /// (or English, where speech-to-text doesn't support it). `temporary` copies are deleted with the file.
    public func add(_ url: URL, scope: ChatDocument.Scope, language: Locale? = nil, temporary: Bool = false, id: UUID = UUID()) {
        guard let kind = Ingest.kind(of: url) else {
            if temporary { try? FileManager.default.removeItem(at: url) }
            return fail(Job(id: id, name: url.lastPathComponent, kind: .text, scope: scope, language: nil, status: ""),
                        Ingest.Failure.unsupported)
        }
        sources[id] = (url, temporary)
        let media = kind == .audio || kind == .video
        Task {
            let spoken = media ? await Self.spokenLanguage(language) : nil
            start(Job(id: id, name: url.lastPathComponent, kind: kind, scope: scope, language: spoken?.identifier, status: "Reading…")) { progress in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if kind == .image || kind == .video {
                    await Self.saveThumbnail(of: url, video: kind == .video, to: self.thumbnailsDir.appending(path: "\(id).jpg"))
                    await MainActor.run { _ = self.thumbnails.insert(id) }
                }
                return try await Ingest.extract(url, kind: kind, language: spoken ?? .current, progress: progress)
            }
        }
    }

    /// Transcribes an audio or video file again in another language, if its source is still at hand.
    public func transcribe(_ id: UUID, in language: Locale) {
        guard let source = sources[id] else { return }
        let scope = documents.first { $0.id == id }?.scope ?? jobs.first { $0.id == id }?.scope ?? .library
        tasks.removeValue(forKey: id)?.cancel()
        jobs.removeAll { $0.id == id }
        documents.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: documentsDir.appending(path: "\(id).json"))
        add(source.url, scope: scope, language: language, temporary: source.temporary, id: id)
    }

    /// Whether `transcribe(_:in:)` can run for this file (its source is known this session).
    public func canTranscribeAgain(_ id: UUID) -> Bool { sources[id] != nil }

    /// Adds pasted text.
    public func add(text: String, name: String, scope: ChatDocument.Scope) {
        start(Job(id: UUID(), name: name, kind: .text, scope: scope, language: nil, status: "Reading…")) { _ in
            Ingest.Extracted(segments: [(text, .none)], note: nil)
        }
    }

    /// Most passages kept from one web page: the ones closest to the question.
    nonisolated static let passagesPerPage = 6

    /// Saves web pages as "Web" files of a conversation (M21), keeping each page's passages closest to `question`, and
    /// returns them once they're searchable. A page already saved there (same address) is refreshed, not duplicated.
    public func addWeb(_ sources: [WebSource], question: String, scope: ChatDocument.Scope,
                       progress: @escaping @Sendable (String) -> Void = { _ in }) async -> [ChatDocument] {
        var added: [ChatDocument] = []
        for (number, source) in sources.enumerated() {
            guard !Task.isCancelled else { break }
            progress("Reading \(source.site) (\(number + 1) of \(sources.count))…")
            let pieces = Self.closest(Chunker.passages(from: [(source.text, .none)]), to: question, keep: Self.passagesPerPage)
            guard !pieces.isEmpty, let passages = try? await Self.index(pieces, progress: { _ in }) else { continue }
            if let old = documents.first(where: { $0.url == source.url && $0.scope == scope }) { delete(document: old.id) }
            let document = ChatDocument(name: source.title, kind: .web, scope: scope, passages: passages, url: source.url)
            documents.insert(document, at: 0)
            Self.write(document, to: documentsDir.appending(path: "\(document.id).json"))
            added.append(document)
        }
        return added
    }

    /// The `keep` passages sharing the most words with the question, in page order.
    nonisolated static func closest(_ pieces: [(text: String, locator: PassageLocator)], to question: String,
                                    keep: Int) -> [(text: String, locator: PassageLocator)] {
        guard pieces.count > keep else { return pieces }
        let words = Retriever.keywords(question)
        let ranked = pieces.indices.sorted {
            words.intersection(Retriever.keywords(pieces[$0].text)).count > words.intersection(Retriever.keywords(pieces[$1].text)).count
        }
        return ranked.prefix(keep).sorted().map { pieces[$0] }
    }

    /// Stops a file being added, or dismisses one that failed.
    public func cancel(_ job: UUID) {
        tasks.removeValue(forKey: job)?.cancel()
        jobs.removeAll { $0.id == job }
        forget(job)
    }

    private func forget(_ id: UUID) {
        if let source = sources.removeValue(forKey: id), source.temporary { try? FileManager.default.removeItem(at: source.url) }
        if thumbnails.remove(id) != nil { try? FileManager.default.removeItem(at: thumbnailsDir.appending(path: "\(id).jpg")) }
    }

    private func start(_ job: Job, extract: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Ingest.Extracted) {
        jobs.append(job)
        let id = job.id
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor [weak self] in self?.update(id) { $0.status = status } }
        }
        tasks[id] = Task { [weak self] in
            do {
                let extracted = try await extract(report)
                let pieces = Chunker.passages(from: extracted.segments)
                let passages = try await Self.index(pieces, progress: report)
                let document = ChatDocument(id: id, name: job.name, kind: job.kind, scope: job.scope, passages: passages,
                                            note: extracted.note, language: job.language)
                self?.finish(document)
            } catch {
                guard !Task.isCancelled else { return } // the user cancelled: whatever threw doesn't matter
                Self.log.error("Adding \(job.name, privacy: .private) failed: \(String(describing: error), privacy: .public)")
                self?.fail(job, error)
            }
        }
    }

    private func finish(_ document: ChatDocument) {
        guard tasks.removeValue(forKey: document.id) != nil else { return } // cancelled meanwhile
        jobs.removeAll { $0.id == document.id }
        documents.insert(document, at: 0)
        Self.write(document, to: documentsDir.appending(path: "\(document.id).json"))
    }

    /// A failed job stays with its reason until dismissed (`cancel`).
    private func fail(_ job: Job, _ error: Error) {
        tasks.removeValue(forKey: job.id)
        let message = (error as? LocalizedError)?.errorDescription ?? "This file couldn't be added."
        if jobs.contains(where: { $0.id == job.id }) {
            update(job.id) { $0.failure = message }
        } else {
            var failed = job
            failed.failure = message
            jobs.append(failed)
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    /// The picked language, else the device's, else English, as speech-to-text knows it.
    nonisolated static func spokenLanguage(_ picked: Locale?) async -> Locale {
        if let picked { return picked }
        return await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
    }

    /// A small JPEG of an image or a video's first second, for the attachment cards.
    nonisolated static func saveThumbnail(of url: URL, video: Bool, to file: URL) async {
        let side: CGFloat = 240
        var image: CGImage?
        if video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: side, height: side)
            image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: side]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: Indexing

    /// Each passage gets an English note and the note's embedding. The note is the passage itself when it's English
    /// already, or in a language the on-device model doesn't support (Indonesian, for one): those are found by
    /// shared words, like names, instead.
    nonisolated static func index(_ pieces: [(text: String, locator: PassageLocator)],
                                  progress: @escaping @Sendable (String) -> Void) async throws -> [IndexedPassage] {
        let model = SystemLanguageModel.default
        var passages: [IndexedPassage] = []
        for (number, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            var note = piece.text
            if model.isAvailable, let language = language(of: piece.text), language != .english,
               model.supportsLocale(Locale(identifier: language.rawValue)) {
                progress("Writing English notes \(number + 1)/\(pieces.count)…")
                note = await englishNote(piece.text, model: model) ?? piece.text
            }
            passages.append(IndexedPassage(text: piece.text, note: note, vector: Retriever.embed(note), locator: piece.locator))
        }
        return passages
    }

    nonisolated static func language(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    nonisolated static let noteInstructions = """
        You write one or two short English sentences saying what a passage covers, keeping its names, numbers and \
        key terms. Write only those sentences.
        """

    nonisolated static func englishNote(_ text: String, model: SystemLanguageModel) async -> String? {
        let session = LanguageModelSession(model: model, instructions: noteInstructions)
        return try? await session.respond(to: "Passage:\n" + text).content
    }

    // MARK: Files on disk

    private nonisolated static func loadAll<T: Decodable>(_ type: T.Type, from dir: URL) -> [T] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
    }

    private nonisolated static func write(_ value: some Encodable, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            log.error("Saving \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
