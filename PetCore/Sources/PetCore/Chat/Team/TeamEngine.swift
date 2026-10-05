//
//  TeamEngine.swift
//  PetCore
//
//  One chat, a team of agents (M34). A lead splits the question into 2–4 tasks; each worker (the user's files, the
//  web, this chat so far, or plain reasoning) works in its own clean 4K session and hands back a few short notes; a
//  writer sees only the question and the notes and writes one concise answer; a checker flags what the notes don't
//  back, and the writer fixes it once. Agents take turns on the one on-device model; web searches run at once.
//

import Foundation
import FoundationModels

public nonisolated enum TeamWorker: String, CaseIterable, Sendable {
    case files, web, thisChat, reasoning

    var label: String {
        switch self {
        case .files: "Your files"
        case .web: "Web"
        case .thisChat: "This chat"
        case .reasoning: "Thinking"
        }
    }
}

@MainActor
final class TeamEngine {
    @Generable
    enum Worker: String {
        case files, web, thisChat, reasoning
    }

    @Generable
    struct Assignment {
        @Guide(description: "Who does it: files (the user's own files), web (searching the internet), thisChat (what was said earlier in this conversation), reasoning (thinking it through, no lookup)")
        var worker: Worker
        @Guide(description: "What to find out, as one short question")
        var ask: String
    }

    @Generable
    struct Plan {
        @Guide(description: "2 to 4 tasks that together answer the question", .count(2...4))
        var tasks: [Assignment]
    }

    @Generable
    struct Check {
        @Guide(description: "Statements in the answer that none of the notes support; empty when every statement is backed", .maximumCount(3))
        var unsupported: [String]
    }

    static let maxTasks = 4
    /// Most a worker's notes may take in the writer's prompt (tokens).
    static let noteBudget = 150
    /// Most material a worker reads at once (tokens), leaving room for its instructions and notes in 4K.
    static let materialBudget = 2_400
    static let nothingFound = "Nothing found."

    static let leadInstructions = """
        You lead a small team answering the user's question. Split it into 2 to 4 short tasks, each for one helper: \
        files (the user's own files), web (the internet), thisChat (earlier in this conversation) or reasoning (thinking \
        it through). Use only the helpers that are available. Each task asks one thing.
        """
    static let workerInstructions = """
        You do one task for a team. Answer only the task, only from the material given. Write at most 4 short bullet \
        points of facts, each ending with its source number in brackets like [2]. If the material doesn't answer the \
        task, write exactly: Nothing found.
        """
    /// The reasoning worker has no material: it answers from what it knows (told apart from looked-up facts).
    static let reasoningInstructions = """
        You do one task for a team: think it through from general knowledge. Write at most 4 short bullet points with \
        the useful, concrete points (typical prices, trade-offs, things to watch for). Say "usually" or "roughly" \
        where it varies. Never refuse and never say you can't look things up.
        """
    static let writerRules = """
        This time your helpers already gathered notes for the question. Answer from the notes only, in your own words: \
        concise, a few sentences or a short list. Don't write source numbers and don't mention the notes or helpers. \
        If the notes don't answer part of it, say so briefly.
        """
    static let checkInstructions = """
        You check an answer against the notes it was written from. List the statements in the answer that no note \
        supports. Rewording is fine; only list claims with no backing.
        """

    private let model: SystemLanguageModel
    private let library: ChatLibrary
    private let conversation: Conversation
    private let writerInstructions: String
    private let update: (ResearchLog) -> Void
    private var log: ResearchLog
    /// Everything the workers read, numbered from 1 for their notes.
    private var sources: [ChatSource] = []
    /// The last two messages before the question, for every agent: "given my budget" means the one said earlier.
    private let recent: String

    init(question: String, model: SystemLanguageModel, library: ChatLibrary, conversation: Conversation,
         chatInstructions: String, update: @escaping (ResearchLog) -> Void) {
        self.model = model
        self.library = library
        self.conversation = conversation
        self.writerInstructions = chatInstructions + "\n\n" + Self.writerRules
        self.update = update
        self.recent = conversation.messages.dropLast().filter { !$0.isAside }.suffix(2)
            .map { "\($0.role == .user ? "User" : "Friend"): \(PetBrain.quote($0.text, 200))" }.joined(separator: "\n")
        var log = ResearchLog(topic: question, effort: .low)
        log.team = true
        log.status = "Planning…"
        self.log = log
    }

    private func status(_ text: String) {
        log.status = text
        update(log)
    }

    /// The answer, the sources its notes used, the log, and whether a web task was left out (the web is off).
    func run(web: Bool) async throws -> (answer: String, sources: [ChatSource], log: ResearchLog, wantedWeb: Bool) {
        let question = log.topic
        let planned = await plan(question, web: web)
        let tasks = Self.usable(planned, question: question, web: web, hasHistory: conversation.messages.count > 1)
        log.steps = tasks.map { ResearchLog.Step(question: "\($0.worker.label): \($0.ask)") }
        update(log)
        try Task.checkCancellation()

        // The web for every web task at once (the network is the slow part), then each worker in turn on the model.
        let webTasks = tasks.filter { $0.worker == .web }
        if !webTasks.isEmpty { status("Searching the web…") }
        let pages = await ResearchEngine.inOrder(webTasks.map(\.ask)) { await ResearchEngine.found($0, terms: [], external: nil) }
        var pagesByAsk: [String: [WebSource]] = [:]
        for (task, found) in zip(webTasks, pages) { pagesByAsk[task.ask] = Array(found.prefix(3)) }

        var notes: [(task: TeamTask, text: String)] = []
        for (index, task) in tasks.enumerated() {
            status("\(task.worker.label): \(task.ask)")
            let note = await work(task, pages: pagesByAsk[task.ask] ?? [])
            notes.append((task, note))
            log.steps[index].done = true
            log.steps[index].note = note
            log.steps[index].notes = Self.isNothing(note) ? 0 : note.split(separator: "\n").count
            update(log)
            try Task.checkCancellation()
        }

        status("Writing…")
        let found = notes.filter { !Self.isNothing($0.text) }
        let notesText = Self.notesBlock(found.isEmpty ? notes : found)
        var answer = try await write(question: question, notes: notesText)
        try Task.checkCancellation()
        status("Checking…")
        let unsupported = await check(answer, notes: notesText)
        if !unsupported.isEmpty {
            status("Fixing…")
            answer = (try? await write(question: question, notes: notesText, fix: (answer, unsupported))) ?? answer
        }
        log.status = "Done"
        log.finishedAt = .now
        return (answer, Self.cited(sources, by: found.map(\.text)), log, planned.contains { $0.worker == .web } && !web)
    }

    private var earlier: String { recent.isEmpty ? "" : "Earlier in this chat:\n\(recent)\n\n" }

    // MARK: Lead

    private func plan(_ question: String, web: Bool) async -> [TeamTask] {
        let files = library.documents(for: conversation.id).filter { $0.kind != .web }.count
        let available = [files > 0 ? "files (\(files))" : nil, web ? "web" : nil, conversation.messages.count > 1 ? "thisChat" : nil, "reasoning"]
            .compactMap { $0 }.joined(separator: ", ")
        let prompt = earlier + "Available helpers: \(available)\n\nQuestion: \(question)"
        let session = LanguageModelSession(model: model, instructions: Self.leadInstructions)
        guard let plan = try? await session.respond(to: prompt, generating: Plan.self).content else { return [] }
        return plan.tasks.map { TeamTask(worker: TeamWorker(rawValue: $0.worker.rawValue) ?? .reasoning, ask: $0.ask) }
    }

    /// The lead's tasks the team can do: the web only when it's on, this chat only when there's history; at most
    /// four; none left (or no plan) → think about the question itself.
    static func usable(_ tasks: [TeamTask], question: String, web: Bool, hasHistory: Bool) -> [TeamTask] {
        var seen = Set<String>()
        let kept = tasks.filter { task in
            !task.ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (web || task.worker != .web) && (hasHistory || task.worker != .thisChat)
                && seen.insert(task.worker.rawValue + "|" + task.ask.lowercased()).inserted
        }
        return kept.isEmpty ? [TeamTask(worker: .reasoning, ask: question)] : Array(kept.prefix(maxTasks))
    }

    // MARK: Workers

    private func work(_ task: TeamTask, pages: [WebSource]) async -> String {
        let material: String
        switch task.worker {
        case .files: material = filesMaterial(for: task.ask)
        case .web: material = webMaterial(pages, for: task.ask)
        case .thisChat: material = chatMaterial()
        case .reasoning: material = ""
        }
        if task.worker != .reasoning, material.isEmpty { return Self.nothingFound }
        let prompt = earlier + "Task: \(task.ask)" + (material.isEmpty ? "" : "\n\nMaterial:\n\(material)")
        let session = LanguageModelSession(model: model, instructions: task.worker == .reasoning ? Self.reasoningInstructions : Self.workerInstructions)
        let note = (try? await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 220)).content) ?? Self.nothingFound
        return Self.trimmed(note)
    }

    /// The number the workers cite `source` by (the same source keeps its number).
    private func numbered(_ source: ChatSource) -> Int {
        if let index = sources.firstIndex(where: { $0.label == source.label && $0.text == source.text }) { return index + 1 }
        sources.append(source)
        return sources.count
    }

    private func filesMaterial(for ask: String) -> String {
        let documents = library.documents(for: conversation.id).filter { $0.kind != .web }
        let hits = Retriever.rank(ask, vector: Retriever.embed(ask), in: documents).prefix(8)
        return Self.fitting(hits.map { hit in "[\(numbered(hit.source))] (\(hit.source.label)) \(hit.passage.text)" })
    }

    private func webMaterial(_ pages: [WebSource], for ask: String) -> String {
        let vector = Retriever.embed(ask)
        // Each page cut into passages; the ones closest to the task, across pages.
        let passages = pages.flatMap { page in
            Chunker.passages(from: [(page.text, .none)]).map { (page: page, text: $0.text) }
        }
        let ranked = passages.map { item in
            (item, vector.flatMap { question in Retriever.embed(item.text).map { Retriever.cosine(question, $0) } } ?? 0)
        }.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
        return Self.fitting(ranked.map { item in
            let number = numbered(ChatSource(documentName: item.page.title, kind: .web, locator: .none, text: item.text, url: item.page.url))
            return "[\(number)] (\(item.page.site)) \(item.text)"
        })
    }

    private func chatMaterial() -> String {
        var lines: [String] = []
        if let summary = conversation.summary { lines.append("Notes on older messages: " + summary) }
        lines += conversation.messages.dropLast().filter { !$0.isAside }.map { ChatPrompt.line(ChatPrompt.shortened($0)) }
        // The newest count most: keep the end when it doesn't all fit.
        let kept = ChatPrompt.fitting(lines.reversed().map { ChatPrompt.estimate($0) + 2 }, budget: Self.materialBudget)
        return lines.suffix(kept).joined(separator: "\n")
    }

    /// The leading lines that fit the material budget.
    static func fitting(_ lines: some Sequence<String>) -> String {
        let lines = Array(lines)
        return lines.prefix(ChatPrompt.fitting(lines.map { ChatPrompt.estimate($0) + 2 }, budget: materialBudget)).joined(separator: "\n")
    }

    static func trimmed(_ note: String) -> String {
        // Only the bullet points when there are any: the small model opens with "I can't look things up, but…".
        let lines = note.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let bullets = lines.filter { $0.range(of: #"^([-*•]|\d+[.)])\s"#, options: .regularExpression) != nil }
        let note = (bullets.isEmpty ? note : bullets.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChatPrompt.estimate(note) > noteBudget else { return note }
        // Whole lines up to the budget.
        var kept: [String] = [], used = 0
        for line in note.split(separator: "\n").map(String.init) {
            used += ChatPrompt.estimate(line) + 1
            guard used <= noteBudget else { break }
            kept.append(line)
        }
        return kept.isEmpty ? String(note.prefix(noteBudget * 3)) : kept.joined(separator: "\n")
    }

    static func isNothing(_ note: String) -> Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("nothing found")
    }

    static func notesBlock(_ notes: [(task: TeamTask, text: String)]) -> String {
        notes.map { "\($0.task.worker.label), on \"\($0.task.ask)\":\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// The sources the notes cite ([2]).
    static func cited(_ sources: [ChatSource], by notes: [String]) -> [ChatSource] {
        let numbers = Set(notes.flatMap { note in
            note.matches(of: #/\[(\d+)\]/#).compactMap { Int($0.1) }
        })
        let used = sources.enumerated().filter { numbers.contains($0.offset + 1) }.map(\.element)
        return ChatSource.merged(used)
    }

    // MARK: Writer and checker

    private func write(question: String, notes: String, fix: (draft: String, unsupported: [String])? = nil) async throws -> String {
        var prompt = earlier + "Question: \(question)\n\nNotes:\n\(notes)"
        if let fix {
            prompt += "\n\nYour first answer:\n\(fix.draft)\n\nThese statements aren't backed by the notes; remove or correct them, keep the rest:\n"
                + fix.unsupported.map { "- \($0)" }.joined(separator: "\n")
        }
        let session = LanguageModelSession(model: model, instructions: writerInstructions)
        return try await session.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func check(_ answer: String, notes: String) async -> [String] {
        let session = LanguageModelSession(model: model, instructions: Self.checkInstructions)
        let prompt = "Notes:\n\(notes)\n\nAnswer:\n\(answer)"
        let flagged = (try? await session.respond(to: prompt, generating: Check.self).content.unsupported) ?? []
        return flagged.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// One task of the lead's plan.
nonisolated struct TeamTask: Equatable, Sendable {
    let worker: TeamWorker
    let ask: String
}
