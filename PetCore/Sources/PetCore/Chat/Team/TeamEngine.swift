//
//  TeamEngine.swift
//  PetCore
//
//  One chat, a team of agents (M34). A lead splits the question into 2–4 tasks; each worker (the user's files, the
//  web, this chat so far, or plain reasoning) works in its own clean 4K session and hands back a few short notes; a
//  writer sees only the question and the notes and writes one concise answer; a checker flags what the notes don't
//  back, and the writer fixes it once. Agents take turns on the one on-device model; web searches run at once.
//  Files and web are looked up the way deep research does it (ResearchEngine.swift): one pool of sources, read
//  per task into facts checked against their source. Deep research is this engine at a research effort.
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
    /// Most a worker's notes may run to.
    static let noteTokens = 220
    /// Most a worker's notes may take in the writer's prompt (tokens).
    static let noteBudget = 150
    /// Most of this chat a worker reads at once (tokens), leaving room for its instructions and notes in 4K.
    static let materialBudget = 2_400
    static let nothingNoted = "Nothing found."
    /// Web pages kept per web task.
    static let pagesPerTask = 3

    static let leadInstructions = """
        You lead a small team answering the user's question. Split it into 2 to 4 short tasks, each for one helper: \
        files (the user's own files), web (the internet), thisChat (earlier in this conversation) or reasoning (thinking \
        it through). Use only the helpers that are available. Each task asks one thing.
        """
    /// The this-chat worker reads the conversation: what was said, not passages with numbers.
    static let chatWorkerInstructions = """
        You look through the conversation so far for one task. Write at most 4 short bullet points saying what was \
        said about it, with the exact names, places and numbers. If nothing in the conversation is about it, write \
        exactly: Nothing found.
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
    static let answerCheckInstructions = """
        You check an answer against the notes it was written from. List the statements in the answer that no note \
        supports. Rewording is fine; only list claims with no backing.
        """

    let model: SystemLanguageModel
    let library: ChatLibrary
    let conversation: Conversation
    let update: (ResearchLog) -> Void
    var log: ResearchLog
    // The pool every lookup reads from (deep research and team tasks alike).
    var texts: [String] = [] // each source's text, by index
    var notes: [ResearchNote] = []
    /// Every source cut into passages (with their meaning vectors), and which passages each question has seen.
    var chunks: [(source: Int, text: String, vector: [Double]?)] = []
    var shown: Set<String> = []
    var siteHome: SitePage?
    /// What a fact from someone else's page must name to count: the topic's exact terms and the site's own name.
    var subjectNames: [String] = []
    /// The user's own model for deep research (M37): the plan, then one call writes the report from every source.
    var chosen: ChosenModel?
    var brain: Brain { chosen.map(Brain.nine) ?? .apple(model) }
    /// Every agent's session this turn, for the context meter (M36).
    private(set) var uses: [AgentUse] = []
    private let writerInstructions: String
    /// The last two messages before the question, for every agent: "given my budget" means the one said earlier.
    private let recent: String

    /// `effort` nil: a quick team answer (`answer(web:)`); else deep research at that effort (`report()`).
    init(topic: String, effort: ResearchEffort?, model: SystemLanguageModel, library: ChatLibrary, conversation: Conversation,
         chatInstructions: String = "", update: @escaping (ResearchLog) -> Void) {
        self.model = model
        self.library = library
        self.conversation = conversation
        self.writerInstructions = chatInstructions + "\n\n" + Self.writerRules
        self.update = update
        self.recent = conversation.messages.dropLast().filter { !$0.isAside }.suffix(2)
            .map { "\($0.role == .user ? "User" : "Friend"): \(PetBrain.quote($0.text, 200))" }.joined(separator: "\n")
        // A quick answer reads like low-effort research: one pass per task.
        var log = ResearchLog(topic: topic, effort: effort ?? .low)
        log.team = effort == nil ? true : nil
        self.log = log
    }

    func record(_ name: String, _ instructions: String, _ prompt: String, _ answer: String) async {
        uses.append(await ContextBudget.use(name, instructions: instructions, prompt: prompt, answer: answer, model: model))
    }

    func status(_ text: String) {
        log.status = text
        update(log)
    }

    /// The answer, the sources its notes used, the log, and whether a web task was left out (the web is off).
    /// `reading`: a worker that must take the whole question (this chat, when the plain answer couldn't fit it).
    func answer(web: Bool, reading: TeamWorker? = nil) async throws -> (answer: String, sources: [ChatSource], log: ResearchLog, wantedWeb: Bool) {
        let question = log.topic
        subjectNames = ExactTerms.find(question)
        let planned = await lead(question, web: web)
        let documents = library.documents(for: conversation.id).filter { $0.kind != .web }
        // A question that points back ("what did we decide earlier") always reads this chat, however it got here.
        let hasHistory = conversation.messages.count > 1
        let reading = reading ?? (hasHistory && ChatMemory.pointsBack(question) ? .thisChat : nil)
        let tasks = Self.usable(planned, question: question, web: web, hasHistory: hasHistory, reading: reading) { ask in
            !Retriever.rank(ask, vector: Retriever.embed(ask), in: documents).isEmpty
        }
        log.steps = tasks.map { ResearchLog.Step(question: "\($0.worker.label): \($0.ask)") }
        update(log)
        try Task.checkCancellation()

        // Look-ups go to the shared pool: the user's files, then the web for every web task at once; then each
        // look-up task is read into facts from it, as deep research reads its questions.
        let asks = tasks.map(\.ask)
        let lookups = tasks.indices.filter { tasks[$0].worker == .files || tasks[$0].worker == .web }
        let fileAsks = tasks.filter { $0.worker == .files }.map(\.ask)
        if !fileAsks.isEmpty { addOwnMaterial(topic: question, questions: fileAsks) }
        let webAsks = tasks.filter { $0.worker == .web }.map(\.ask)
        if !webAsks.isEmpty {
            status("Searching the web…")
            await searchAll(webAsks, terms: subjectNames, limit: Self.pagesPerTask)
        }
        if !lookups.isEmpty { try await readAll(questions: asks, only: lookups) }

        var written: [(task: TeamTask, text: String)] = []
        for (index, task) in tasks.enumerated() {
            let note: String
            if lookups.contains(index) {
                note = Self.bullets(notes.filter { $0.question == index })
            } else {
                status("\(task.worker.label): \(task.ask)")
                note = await think(task)
            }
            written.append((task, note))
            log.steps[index].done = true
            log.steps[index].note = note
            log.steps[index].notes = Self.isNothing(note) ? 0 : note.split(separator: "\n").count
            update(log)
            try Task.checkCancellation()
        }

        status("Writing…")
        let found = written.filter { !Self.isNothing($0.text) }
        let notesText = Self.notesBlock(found.isEmpty ? written : found)
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
        return (answer, chips(), log, planned.contains { $0.worker == .web } && !web)
    }

    private var earlier: String { recent.isEmpty ? "" : "Earlier in this chat:\n\(recent)\n\n" }

    // MARK: Lead

    private func lead(_ question: String, web: Bool) async -> [TeamTask] {
        let files = library.documents(for: conversation.id).filter { $0.kind != .web }.count
        let available = [files > 0 ? "files (\(files))" : nil, web ? "web" : nil, conversation.messages.count > 1 ? "thisChat" : nil, "reasoning"]
            .compactMap { $0 }.joined(separator: ", ")
        let prompt = earlier + "Available helpers: \(available)\n\nQuestion: \(question)"
        let session = LanguageModelSession(model: model, instructions: Self.leadInstructions)
        guard let plan = try? await session.respond(to: prompt, generating: Plan.self).content else { return [] }
        await record("Lead", Self.leadInstructions, prompt, plan.tasks.map { "\($0.worker.rawValue): \($0.ask)" }.joined(separator: "\n"))
        return plan.tasks.map { TeamTask(worker: TeamWorker(rawValue: $0.worker.rawValue) ?? .reasoning, ask: $0.ask) }
    }

    /// The lead's tasks the team can do: the web only when it's on, this chat only when there's history; at most
    /// four; none left (or no plan) → think about the question itself. The small lead often plans "reasoning" for
    /// what's in the user's files ("ticket prices from my launch plan"): a task `matchesFiles` reads the files, and
    /// a question that matches them is always read from the files as a whole.
    static func usable(_ tasks: [TeamTask], question: String, web: Bool, hasHistory: Bool, reading: TeamWorker? = nil,
                       matchesFiles: (String) -> Bool = { _ in false }) -> [TeamTask] {
        var seen = Set<String>()
        let tasks = tasks.map { $0.worker == .reasoning && matchesFiles($0.ask) ? TeamTask(worker: .files, ask: $0.ask) : $0 }
        let kept = tasks.filter { task in
            !task.ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (web || task.worker != .web) && (hasHistory || task.worker != .thisChat)
                && seen.insert(task.worker.rawValue + "|" + task.ask.lowercased()).inserted
        }
        // The whole question too: the lead's own files task can miss ("What is the URL of my launch plan?").
        let asked = kept.contains { $0.worker == .files && $0.ask.lowercased() == question.lowercased() }
        let files = !asked && matchesFiles(question) ? [TeamTask(worker: .files, ask: question)] : []
        // The whole question, as with files: the lead's own task for that worker can ask something narrower.
        let must = reading.map { worker in
            kept.contains { $0.worker == worker && $0.ask.lowercased() == question.lowercased() } ? [] : [TeamTask(worker: worker, ask: question)]
        } ?? []
        let all = must + files + kept
        return all.isEmpty ? [TeamTask(worker: .reasoning, ask: question)] : Array(all.prefix(maxTasks))
    }

    // MARK: Workers

    /// This chat and reasoning: a session of their own (look-ups are read from the pool instead).
    private func think(_ task: TeamTask) async -> String {
        var material = task.worker == .thisChat ? chatMaterial(for: task.ask) : []
        if task.worker == .thisChat, material.isEmpty { return Self.nothingNoted }
        let instructions = task.worker == .reasoning ? Self.reasoningInstructions : Self.chatWorkerInstructions
        func prompt() -> String {
            // This chat's worker reads the conversation itself, so the last two messages aren't repeated on top.
            task.worker == .thisChat ? "Task: \(task.ask)\n\nThe conversation:\n" + material.joined(separator: "\n")
                : earlier + "Task: \(task.ask)"
        }
        // Measured (M36): what's least related to the task goes until the notes have room (the oldest first among
        // equals), so a question about something said long ago still finds it.
        let fixed = await ContextBudget.tokens(instructions: instructions, model: model)
        let limit = model.contextSize - fixed - Self.noteTokens - ContextBudget.margin
        var order = ContextBudget.dropOrder(material, for: task.ask)[...]
        var dropped = Set<Int>()
        let all = material
        while all.count - dropped.count > 1, await ContextBudget.tokens(prompt(), model: model) > limit, let next = order.popFirst() {
            dropped.insert(next)
            material = all.indices.filter { !dropped.contains($0) }.map { all[$0] }
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let note = (try? await session.respond(to: prompt(), options: GenerationOptions(maximumResponseTokens: Self.noteTokens)).content)
            ?? Self.nothingNoted
        await record("\(task.worker.label): \(task.ask)", instructions, prompt(), note)
        return Self.trimmed(note)
    }

    /// A look-up task's facts as notes, with the pool's source numbers: "- It costs $5 [2]".
    static func bullets(_ facts: [ResearchNote]) -> String {
        let lines = keyFacts(facts).prefix(5).map { "- \($0.fact.trimmingCharacters(in: .whitespacesAndNewlines)) [\($0.source + 1)]" }
        return lines.isEmpty ? nothingNoted : trimmed(lines.joined(separator: "\n"))
    }

    /// This chat for a worker, in order: as much as the estimate allows, the least related to `ask` left out first
    /// (measuring trims the rest), so something said long ago can still be found.
    private func chatMaterial(for ask: String) -> [String] {
        var lines: [String] = []
        if let summary = conversation.summary { lines.append("Notes on older messages: " + summary) }
        lines += conversation.messages.dropLast().filter { !$0.isAside }.map { ChatPrompt.line(ChatPrompt.shortened($0)) }
        // When some of it is about the task, only that (and the notes on older messages): the small model misses one
        // line about the venue among forty about snacks.
        let words = Retriever.keywords(ask)
        let related = lines.filter { $0.hasPrefix("Notes on older messages") || !words.intersection(Retriever.keywords($0)).isEmpty }
        if related.contains(where: { !$0.hasPrefix("Notes on older messages") }) { lines = related }
        let costs = lines.map { ChatPrompt.estimate($0) + 2 }
        var total = costs.reduce(0, +), dropped = Set<Int>()
        for index in ContextBudget.dropOrder(lines, for: ask) where total > Self.materialBudget && lines.count - dropped.count > 1 {
            dropped.insert(index)
            total -= costs[index]
        }
        return lines.indices.filter { !dropped.contains($0) }.map { lines[$0] }
    }

    static func trimmed(_ note: String) -> String {
        // Only the bullet points when there are any: the small model opens with "I can't look things up, but…".
        let lines = note.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let bullets = lines.filter { $0.range(of: #"^([-*•]|\d+[.)])\s"#, options: .regularExpression) != nil }
        let note = (bullets.isEmpty ? note : bullets.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        // "I'm sorry, but I can't assist with that." is no note.
        if bullets.isEmpty, note.range(of: #"(?i)^(i'?m sorry|i apologi[sz]e|i can'?t|i cannot|i am unable|sorry)"#, options: .regularExpression) != nil {
            return nothingNoted
        }
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

    // MARK: Writer and checker

    private func write(question: String, notes: String, fix: (draft: String, unsupported: [String])? = nil) async throws -> String {
        var prompt = earlier + "Question: \(question)\n\nNotes:\n\(notes)"
        if let fix {
            prompt += "\n\nYour first answer:\n\(fix.draft)\n\nThese statements aren't backed by the notes; remove or correct them, keep the rest:\n"
                + fix.unsupported.map { "- \($0)" }.joined(separator: "\n")
        }
        let used = await ContextBudget.tokens(instructions: writerInstructions, model: model) + ContextBudget.tokens(prompt, model: model)
        let options = GenerationOptions(maximumResponseTokens: ContextBudget.cap(used: used, contextSize: model.contextSize,
                                                                                 ceiling: ContextBudget.writerCeiling))
        let session = LanguageModelSession(model: model, instructions: writerInstructions)
        let answer = try await session.respond(to: prompt, options: options).content.trimmingCharacters(in: .whitespacesAndNewlines)
        await record(fix == nil ? "Writer" : "Writer (fixing)", writerInstructions, prompt, answer)
        return answer
    }

    private func check(_ answer: String, notes: String) async -> [String] {
        let session = LanguageModelSession(model: model, instructions: Self.answerCheckInstructions)
        let prompt = "Notes:\n\(notes)\n\nAnswer:\n\(answer)"
        let flagged = (try? await session.respond(to: prompt, generating: Check.self).content.unsupported) ?? []
        await record("Checker", Self.answerCheckInstructions, prompt, flagged.joined(separator: "\n"))
        return flagged.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// One task of the lead's plan.
nonisolated struct TeamTask: Equatable, Sendable {
    let worker: TeamWorker
    let ask: String
}
