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
        /// Working out which agent takes the message (the router, M32).
        case checking
        case compacting
        case searching
        /// Reading links or searching the web, with what it's doing.
        case browsing(String)
        /// Making a file or running a skill.
        case making(String)
        /// Reading older conversation in passes (deep recall).
        case remembering(String)
        /// Deep research under way; `research` has the live plan.
        case researching
        case answering(String)
    }

    /// Pages kept from one web search (links in the message come on top).
    nonisolated static let webPages = 5

    public private(set) var conversation: Conversation
    public private(set) var state = State.idle
    public private(set) var failure: String?
    /// A heads-up about the last turn that didn't stop it, e.g. the web search finding nothing.
    public private(set) var notice: String?
    /// Where an explained screenshot was taken (M31): shown above the explanation.
    public private(set) var origin: ScreenExplainer.Origin?
    /// The research under way: plan, sources, what it's doing.
    public private(set) var research: ResearchLog?
    /// Tokens in the instructions alone: the meter's reading before the first answer.
    public private(set) var baseline: Int?
    private let library: ChatLibrary
    private let instructions: String
    private let handOverInstructions: String
    private let model = SystemLanguageModel.default
    @ObservationIgnored private var turn: Task<Void, Never>?
    /// Pages this question's browsing saved: they rank first for it.
    @ObservationIgnored private var justFound: Set<UUID> = []
    /// Sites named in this question that couldn't be read: the answer says so first.
    @ObservationIgnored private var unreadSites: [String] = []

    public init(_ conversation: Conversation, library: ChatLibrary, friend: FriendProfile?) {
        self.conversation = conversation
        self.library = library
        self.instructions = ChatPrompt.instructions(for: friend)
        self.handOverInstructions = PetBrain.makeInstructions(for: friend, base: ChatPrompt.handOverBase)
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

    /// With `web`, the question is also searched on the web; links in it are read either way. A /command runs as
    /// its command (the screen handles the ones that aren't about the model); a request for a file makes one.
    public func send(_ question: String, web: Bool = false) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, state == .idle, unavailable == nil else { return }
        failure = nil
        notice = nil
        conversation.messages.append(ChatMessage(role: .user, text: question))
        library.save(conversation)
        state = .searching // busy from the moment it's sent, so Stop works at once
        let invocation = ChatCommand.parse(question)
        turn = Task {
            switch invocation?.command.action {
            case .file(let format)?:
                await makeFile(format, request: invocation?.argument ?? "", instructions: nil, web: web)
            case .skill(let skill)?:
                await run(skill, named: invocation?.command.resultName ?? "the result", argument: invocation?.argument ?? "", web: web)
            case .ask(let template)?:
                let argument = invocation?.argument ?? ""
                let request = template.replacingOccurrences(of: "%@", with: argument.isEmpty ? "this conversation" : "this: " + argument)
                await answer(request)
            case .research?:
                let split = ResearchIntent.split(invocation?.argument ?? "")
                await runResearch(split.topic, effort: split.effort ?? researchEffort)
            case .diagram?:
                await makeDiagram(request: invocation?.argument ?? "", web: web)
            case .web?:
                await browse(for: invocation?.argument ?? question, web: true)
                guard !Task.isCancelled else { return }
                await answer(invocation?.argument ?? question)
            case nil:
                let action = await route(question)
                guard !Task.isCancelled else { return } // stopped: stop() already tidied up
                switch action {
                case .clarify: return clarify()
                case .diagram: return await makeDiagram(request: question, web: web)
                case .file(let format): return await makeFile(format, request: question, instructions: nil, web: web)
                case .reformat: return await reformat(question)
                case .answer, .web, .research: break
                }
                await browse(for: question, web: web)
                guard !Task.isCancelled else { return }
                await answer(question, offering: ChatMessage.Offer.after(action, web: web))
            default:
                state = .idle // screen commands never reach here
            }
        }
    }

    /// Explains a captured part of the screen (M31). The screenshot is attached to this conversation, the user's turn
    /// names what it is ("Screenshot · …", the chat's title), and the explanation takes the shape that fits. With
    /// `web`, what it is is searched too and the best excerpts join the prompt.
    public func explain(screenshot png: Data, web: Bool = false, origin: ScreenExplainer.Origin? = nil) {
        guard state == .idle, unavailable == nil else { return }
        self.origin = origin
        failure = nil
        notice = nil
        state = .making("Looking…")
        turn = Task {
            defer { if !Task.isCancelled { state = .idle } }
            var text = ""
            do {
                let read = try await ScreenExplainer.read(png)
                let glance = try await ScreenExplainer.glance(read, origin: origin, model: model)
                guard !Task.isCancelled else { return }
                // The title, then where it was taken: follow-ups (and the chat later) still know it.
                let title = ScreenExplainer.title(glance.what)
                conversation.messages.append(ChatMessage(role: .user, text: origin.map { title + "\n" + $0.line } ?? title))
                library.save(conversation)
                let file = FileManager.default.temporaryDirectory.appending(path: "Screenshot \(UUID().uuidString.prefix(8)).png")
                try png.write(to: file)
                library.add(file, scope: .conversation(conversation.id), temporary: true)
                let found = web ? await lookUp(glance, origin: origin) : []
                guard !Task.isCancelled else { return }
                let session = LanguageModelSession(model: model, instructions: ScreenExplainer.instructions)
                state = .answering("")
                for try await snapshot in session.streamResponse(to: ScreenExplainer.prompt(glance, read: read, web: found, origin: origin)) {
                    guard !Task.isCancelled else { break }
                    text = snapshot.content
                    state = .answering(text)
                }
            } catch is CancellationError {
                // Stopped: keep what was written.
            } catch {
                Self.log.error("Explaining a screenshot failed: \(String(describing: error), privacy: .public)")
                if text.isEmpty { return failure = (error as? ScreenExplainer.Failure)?.errorDescription ?? Self.message(for: error) }
            }
            guard !text.isEmpty else { return }
            conversation.messages.append(ChatMessage(role: .friend, text: text))
            library.save(conversation)
        }
    }

    /// The web's take on a screenshot: a search and Wikipedia, at once. Nothing found is a notice, not a failure.
    private func lookUp(_ glance: ScreenExplainer.Glance, origin: ScreenExplainer.Origin?) async -> [WebSource] {
        let query = [glance.search.isEmpty ? glance.what : glance.search, origin?.domain ?? origin?.app]
            .compactMap { $0 }.joined(separator: " ")
        state = .browsing("Searching the web for “\(query)”…")
        async let searched = try? WebSearch.search(objective: "What is \(glance.what)?", queries: [query])
        async let encyclopedia = try? WebSearch.wikipedia(query, limit: 1)
        let found = WebSource.distinct(((await searched) ?? []) + ((await encyclopedia) ?? []))
        if found.isEmpty { notice = "Couldn't search the web; explained from the screenshot alone." }
        return found
    }

    /// The effort a /research without one uses (the composer's Research menu sets it).
    public var researchEffort = ResearchEffort.medium

    /// Deep research on `topic`, shown as the user's `typed` message (M28).
    public func research(_ topic: String, effort: ResearchEffort, typed: String) {
        guard state == .idle, unavailable == nil, !topic.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        failure = nil
        notice = nil
        conversation.messages.append(ChatMessage(role: .user, text: typed))
        library.save(conversation)
        state = .researching
        turn = Task { await runResearch(topic, effort: effort) }
    }

    private func runResearch(_ request: String, effort: ResearchEffort) async {
        state = .researching
        // "… make them into a pdf and md file" is about the output, not the topic.
        let topic = ResearchEngine.withoutFileRequest(request)
        let engine = ResearchEngine(topic: topic, effort: effort, model: model, library: library, conversation: conversation) { [weak self] log in
            self?.research = log
        }
        do {
            let result = try await engine.run()
            guard !Task.isCancelled else { return }
            // The report lives in the chat; file copies only when the request asked for them.
            let title = "Research – " + ResearchEngine.title(ResearchEngine.cleanTopic(topic))
            var files: [ChatFile] = []
            for format in Self.requestedReportFormats(request) {
                let data = switch format {
                case .md: ChatFileWriter.markdown(result.report)
                case .txt: ChatFileWriter.text(result.report)
                default: await ChatFileWriter.document(result.report, title: title, format: format)
                }
                files.append(ChatFile(name: ChatFileMaker.fileName(title, format), format: format, data: data))
            }
            var reply = ChatMessage(role: .friend, text: result.report, sources: result.sources, files: files.isEmpty ? nil : files)
            reply.research = result.log
            research = nil
            finishTurn(reply)
        } catch {
            research = nil
            guard !Task.isCancelled else { return }
            failure = Self.message(for: error)
            state = .idle
        }
    }

    /// "… make them into a pdf and md file": every format a research request asks its report in.
    nonisolated static func requestedReportFormats(_ request: String) -> [ChatFileFormat] {
        let lower = request.lowercased()
        let patterns: [(String, ChatFileFormat)] = [(#"\bpdfs?\b"#, .pdf), (#"\b(markdown|md)\b|\.md\b"#, .md),
                                                    (#"\bhtml\b|\bweb ?page\b"#, .html), (#"\b(txt|text file|plain text)\b"#, .txt)]
        return patterns.filter { lower.range(of: $0.0, options: .regularExpression) != nil }.map(\.1)
    }

    /// A message from the app itself (/help, /files): shown, never used as context.
    public func note(_ text: String, echoing command: String) {
        guard state == .idle else { return }
        conversation.messages.append(ChatMessage(role: .user, text: command, aside: true))
        conversation.messages.append(ChatMessage(role: .friend, text: text, aside: true))
        library.save(conversation)
    }

    /// /clear: the messages and their notes go; the conversation and its files stay.
    public func clear() {
        guard state == .idle else { return }
        conversation.messages = []
        conversation.summary = nil
        conversation.summarizedCount = 0
        conversation.contextUsed = nil
        library.save(conversation)
    }

    // MARK: Files and skills (M25)

    /// Tokens of conversation and file passages a file or skill gets: the rest of the window is its output.
    nonisolated static let materialBudget = (conversation: 500, passages: 1100)

    /// Reads the request's links (and searches, with Search on) first, like an answer would; with a name in the
    /// request and nothing about it found, says so rather than inventing a file.
    private func makeFile(_ format: ChatFileFormat, request: String, instructions: String?, columns: [String]? = nil, web: Bool = false) async {
        let ask = request.isEmpty ? "Make it from this conversation." : request
        await browse(for: ask, web: web)
        guard !Task.isCancelled else { return }
        state = .making("Making your \(format.title) file…")
        let gathered = await material(for: ask)
        guard gathered.grounded else {
            failure = "I couldn't find anything about \(gathered.missing) to put in a file"
                + (unreadSitesNote.map { " (\($0))" } ?? "") + ". Turn on Search, or add a file about it."
            unreadSites = []
            return state = .idle
        }
        unreadSites = []
        do {
            let file: ChatFile
            do {
                file = try await ChatFileMaker.make(format, request: ask, material: gathered.text, instructions: instructions,
                                                    columns: columns, model: model)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                // Too much to fit with room to write: try once with the first half of the material.
                file = try await ChatFileMaker.make(format, request: ask, material: String(gathered.text.prefix(gathered.text.count / 2)),
                                                    instructions: instructions, columns: columns, model: model)
            }
            guard !Task.isCancelled else { return }
            let line = await handOver("a \(format.title) file called \(file.name)")
            finishTurn(ChatMessage(role: .friend, text: line, files: [file]))
        } catch {
            guard !Task.isCancelled else { return }
            Self.log.error("Making a file failed: \(String(describing: error), privacy: .public)")
            failure = (error as? LocalizedError)?.errorDescription ?? Self.message(for: error)
            state = .idle
        }
    }

    /// A diagram in the chat (M29): the model fills a typed structure, the app writes the Mermaid.
    private func makeDiagram(request: String, web: Bool) async {
        let ask = request.isEmpty ? "Draw this conversation." : request
        let kind = DiagramIntent.kind(ask)
        await browse(for: ask, web: web)
        guard !Task.isCancelled else { return }
        state = .making("Drawing your \(kind.title.lowercased())…")
        let gathered = await material(for: ask)
        unreadSites = []
        // A flowchart of a named subject's process ("how a Fazz payment works") is drawn from sources first; then,
        // if this conversation has material about it, as a general outline that says so.
        var outline = false
        if kind == .flowchart, let subject = ExactTerms.find(ask).first {
            state = .making("Researching how it works…")
            if let found = await ProcessResearch.flowchart(request: ask, subject: subject, library: library, conversation: conversation,
                                                          model: model, status: { [weak self] in self?.state = .making($0) }) {
                guard !Task.isCancelled else { return }
                let line = await handOver("a flowchart")
                let note = "_Drawn from \(found.sources.count) source\(found.sources.count == 1 ? "" : "s"): only steps they describe._"
                return finishTurn(ChatMessage(role: .friend, text: line + "\n\n" + found.diagram.markdown + "\n\n" + note, sources: found.sources))
            }
            guard !Task.isCancelled else { return }
            // Nothing about it anywhere (searches for "netmonk" only found Netmon, a different product): say so
            // rather than draw someone else's process.
            guard gathered.grounded else {
                failure = "I couldn't find how \(subject) works in public sources: searches only turned up other products. "
                    + "Paste a link to its docs or add a file about it, and I'll draw it from that."
                return state = .idle
            }
            outline = true
            state = .making("Drawing a general outline…")
        }
        guard gathered.grounded else {
            failure = "I couldn't find anything about \(gathered.missing) to draw. Turn on Search, or add a file about it."
            return state = .idle
        }
        do {
            let diagram: ChatDiagram
            do {
                diagram = try await DiagramMaker.make(kind, request: ask, material: gathered.text, model: model)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                diagram = try await DiagramMaker.make(kind, request: ask, material: String(gathered.text.prefix(gathered.text.count / 2)), model: model)
            }
            guard !Task.isCancelled else { return }
            let line = await handOver("a \(kind.title.lowercased())")
            let caveat = outline ? "\n\n_I couldn't find how this works in public sources, so this is a general outline, not their actual process._" : ""
            finishTurn(ChatMessage(role: .friend, text: line + "\n\n" + diagram.markdown + caveat))
        } catch {
            guard !Task.isCancelled else { return }
            Self.log.error("Making a diagram failed: \(String(describing: error), privacy: .public)")
            failure = (error as? LocalizedError)?.errorDescription ?? Self.message(for: error)
            state = .idle
        }
    }

    private func run(_ skill: ChatSkill, named name: String, argument: String, web: Bool = false) async {
        let ask = argument.isEmpty ? "Use this conversation." : argument
        if let format = skill.file {
            return await makeFile(format, request: ask, instructions: skill.instructions, columns: skill.columns, web: web)
        }
        await browse(for: ask, web: web)
        guard !Task.isCancelled else { return }
        state = .making("Working on \(name)…")
        do {
            let session = LanguageModelSession(model: model, instructions: ChatFileMaker.skillInstructions + "\n\n" + skill.instructions)
            let material = await material(for: ask).text
            unreadSites = []
            let output = try await session.respond(to: (material.isEmpty ? "" : "Material:\n\(material)\n\n") + "Request: \(ask)").content
            guard !Task.isCancelled else { return }
            let line = await handOver(name)
            let result = String(decoding: ChatFileWriter.markdown(output), as: UTF8.self) // no wrapping code fence
            finishTurn(ChatMessage(role: .friend, text: line + "\n\n" + result))
        } catch {
            guard !Task.isCancelled else { return }
            failure = Self.message(for: error)
            state = .idle
        }
    }

    private func finishTurn(_ reply: ChatMessage) {
        conversation.messages.append(reply)
        library.save(conversation)
        state = .idle
    }

    /// The recent conversation and the passages closest to the request, within the material budget.
    /// The same exact-name rules as answers (M27): with a name in the request, only passages and earlier messages
    /// that mention it; `grounded` is false when a name was asked about and nothing mentions it.
    private func material(for request: String) async -> (text: String, grounded: Bool, missing: String) {
        let terms = ExactTerms.find(request)
        let recent = conversation.messages.dropLast()
            .filter { !$0.isAside && !$0.text.hasPrefix("/") && (terms.isEmpty || ExactTerms.mentions(ChatPrompt.shortened($0).text, terms)) }
        let keep = ChatPrompt.fitting(recent.reversed().map { ChatPrompt.estimate($0.text) + 4 }, budget: Self.materialBudget.conversation)
        let lines = recent.suffix(keep).map { ChatPrompt.line(ChatPrompt.shortened($0)) }
        let ranked = Retriever.rank(request, vector: Retriever.embed(request), in: library.documents(for: conversation.id), boosting: justFound)
        let named = WebSearch.links(in: request)
        let usable = ChatPrompt.usable(ranked, question: request, terms: terms, named: named, fresh: justFound)
        justFound = []
        // A named site's own passages lead, in page order (overview and services before testimonials).
        let siteKeys = named.map { WebSearch.pageKey($0).split(separator: "/").first.map(String.init) ?? "" }
        func fromSite(_ hit: Retriever.Hit) -> Bool {
            hit.document.url.map { url in siteKeys.contains(WebSearch.pageKey(url).split(separator: "/").first.map(String.init) ?? "") } == true
        }
        let ordered = usable.filter(fromSite).sorted {
            ($0.document.passages.firstIndex(of: $0.passage) ?? 0) < ($1.document.passages.firstIndex(of: $1.passage) ?? 0)
        }
        let hits = ordered + usable.filter { !fromSite($0) }
        let passages = hits.prefix(ChatPrompt.fitting(hits.map { ChatPrompt.estimate($0.passage.text) + 20 }, budget: Self.materialBudget.passages))
        var parts: [String] = []
        if !lines.isEmpty { parts.append("Conversation:\n" + lines.joined(separator: "\n")) }
        if !passages.isEmpty {
            parts.append("From the user's files and web pages:\n"
                + passages.map { "- (\(ChatPrompt.passageLabel($0))) \($0.passage.text)" }.joined(separator: "\n"))
        }
        // A user message only naming the thing ("research antartech.co") isn't material about it.
        let grounded = terms.isEmpty || !passages.isEmpty
        return (parts.joined(separator: "\n\n"), grounded, terms.first ?? "")
    }

    /// "couldn't open antartech.co", for messages.
    private var unreadSitesNote: String? {
        unreadSites.isEmpty ? nil : "couldn't open " + ListFormatter.localizedString(byJoining: unreadSites)
    }

    /// The friend's one short line handing the result over, in its own voice (plain text: its own instructions,
    /// not the chat's Markdown rules).
    private func handOver(_ what: String) async -> String {
        let fallback = "Here's \(what)!"
        guard model.isAvailable else { return fallback }
        let session = LanguageModelSession(model: model, instructions: handOverInstructions)
        let prompt = "Hand the user \(what), which is ready. One short, warm sentence, under 15 words."
        guard let line = try? await session.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty, line.count < 160, !line.contains("`"), !line.contains("\n") else { return fallback }
        return line
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

    /// The question the friend's `answer` replied to, and where that answer is.
    private func asked(before answer: UUID) -> (question: ChatMessage, at: Int)? {
        guard let at = conversation.messages.firstIndex(where: { $0.id == answer }),
              let question = conversation.messages[..<at].last(where: { $0.role == .user }) else { return nil }
        return (question, at)
    }

    /// The offer under an answer, taken (M32): the question again, this time searching the web.
    public func searchWeb(answering answer: UUID) {
        guard let asked = asked(before: answer) else { return }
        resend(from: asked.question.id, as: asked.question.text, web: true)
    }

    /// The offer under an answer, taken (M32): deep research on its question. The answer stays, without the offer.
    public func deepResearch(answering answer: UUID, effort: ResearchEffort) {
        guard state == .idle, let asked = asked(before: answer) else { return }
        conversation.messages[asked.at].offer = nil
        research(asked.question.text, effort: effort, typed: "Deep research: " + asked.question.text)
    }

    /// A diagram edited in place (M29): its code in a friend's message swapped for the new code.
    public func replaceDiagram(in messageID: UUID, from old: String, to new: String) {
        guard state == .idle, let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              let range = conversation.messages[index].text.range(of: old) else { return }
        conversation.messages[index] = conversation.messages[index].with(text: conversation.messages[index].text.replacingCharacters(in: range, with: new))
        library.save(conversation)
    }

    /// A newer copy from the other device (sync): taken while nothing is under way here.
    public func refresh(from latest: Conversation) {
        guard state == .idle, (latest.modifiedAt ?? .distantPast) > (conversation.modifiedAt ?? .distantPast) else { return }
        conversation = latest
    }

    // MARK: Guardrail

    /// The instant gibberish check, then the router picks the agent (M32).
    private func route(_ question: String) async -> ChatRouter.Action {
        let check = MessageCheck.judge(question)
        guard check != .gibberish else { return .clarify }
        state = .checking
        let route = await ChatRouter.route(question, recent: conversation.messages.dropLast(), model: model)
        return ChatRouter.action(route, for: question, check: check)
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
        unreadSites = unread
        if web {
            let queries = await searchQueries(for: question)
            state = .browsing("Searching the web for “\(queries.first ?? question)”…")
            async let searched = try? WebSearch.search(objective: question, queries: queries)
            async let encyclopedia = try? WebSearch.wikipedia(queries.first ?? question, limit: 1)
            var found = ((await searched) ?? []) + ((await encyclopedia) ?? [])
            // With a name in the question, look-alike results aren't kept: only pages that mention it.
            let terms = ExactTerms.find(question)
            if !terms.isEmpty { found = found.filter { ExactTerms.mentions($0.title + " " + $0.text, terms) } }
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
        let added = await library.addWeb(sources, question: question, scope: .conversation(conversation.id),
                                         terms: ExactTerms.find(question), named: links, progress: report)
        justFound = Set(added.map(\.id))
        if !unread.isEmpty {
            notice = "Couldn't read " + ListFormatter.localizedString(byJoining: unread) + (added.isEmpty ? "." : "; answering from what was found.")
        }
    }

    /// Two or three short search queries from the model; the question itself if the model can't.
    /// Two or three queries from the model; a name the question is about leads, exactly as typed, and the model's
    /// queries only stay if they keep it (no "correcting" antartech into Antarctica).
    private func searchQueries(for question: String) async -> [String] {
        let terms = ExactTerms.find(question)
        var queries: [String] = []
        if model.isAvailable {
            let session = LanguageModelSession(model: model, instructions: ChatPrompt.queryInstructions)
            queries = ChatPrompt.queries(from: (try? await session.respond(to: "Question: " + question).content) ?? "")
        }
        return ChatPrompt.searchQueries(model: queries, terms: terms, question: question)
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

    private func answer(_ question: String, offering offer: ChatMessage.Offer? = nil) async {
        // A stopped turn leaves the state alone: the next message may already be under way.
        defer { if !Task.isCancelled { state = .idle } }
        let budget = ChatPrompt.split(contextSize: contextSize, instructions: ChatPrompt.estimate(instructions),
                                      question: ChatPrompt.estimate(question))
        state = .searching
        let ranked = Retriever.rank(question, vector: Retriever.embed(question), in: library.documents(for: conversation.id),
                                    boosting: justFound)
        // Exact names win (M27): with a name or site in the question, only passages about it; otherwise web pages
        // from earlier searches only when they share words with the question.
        let terms = ExactTerms.find(question)
        let hits = ChatPrompt.usable(ranked, question: question, terms: terms, named: WebSearch.links(in: question), fresh: justFound)
        justFound = []
        let named = WebSearch.links(in: question).map { WebSearch.pageKey($0) }
        let readNamed = hits.contains { hit in hit.document.url.map { url in named.contains { WebSearch.pageKey(url).hasPrefix($0) } } == true }
        let groundingNote = ChatPrompt.groundingNote(terms: terms, found: !hits.isEmpty, unread: unreadSites,
                                                     read: readNamed ? named : [])
        unreadSites = []
        let passageTokens = hits.map { ChatPrompt.estimate($0.passage.text) + 20 }
        let passages = Array(hits.prefix(ChatPrompt.fitting(passageTokens, budget: budget.passages)))
        // Room the passages didn't need goes to the conversation.
        let history = budget.history + budget.passages - passageTokens.prefix(passages.count).reduce(0, +)
        await compactIfNeeded(budget: history)
        guard !Task.isCancelled else { return }

        // Memory (M26): older turns, here and in other conversations, recalled for this question; its room comes
        // out of the conversation's share.
        let recall = await recall(for: question)
        guard !Task.isCancelled else { return }
        state = .searching
        // A question about a named site or name: earlier messages that don't mention it are left out, so an old
        // off-target answer (Antarctica for antartech) can't steer the new one.
        let earlier = conversation.messages[conversation.summarizedCount..<(conversation.messages.count - 1)]
            .filter { !$0.isAside && !$0.text.hasPrefix("/") && (terms.isEmpty || ExactTerms.mentions(ChatPrompt.shortened($0).text, terms)) }
        let summaryTokens = conversation.summary.map(ChatPrompt.estimate) ?? 0
        let recallTokens = recall.block.map(ChatPrompt.estimate) ?? 0
        let keep = ChatPrompt.fitting(earlier.reversed().map { ChatPrompt.estimate($0.text) + 4 }, budget: history - summaryTokens - recallTokens)
        let siteHits = passages.filter { hit in hit.document.url.map { url in named.contains { WebSearch.pageKey(url).hasPrefix($0) } } == true }
        let asked = siteHits.isEmpty ? question
            : ChatPrompt.siteTask(sites: named.map { $0.split(separator: "/").first.map(String.init) ?? $0 },
                                  titles: Array(Set(siteHits.map(\.document.name))), question: question)
        let prompt = ChatPrompt.make(summary: conversation.summary, recent: Array(earlier.suffix(keep)), passages: passages,
                                     question: asked, recalled: recall.block, note: groundingNote)

        let session = LanguageModelSession(model: model, instructions: instructions)
        guard let text = await stream(prompt, in: session) else { return }
        var reply = ChatMessage(role: .friend, text: text, sources: ChatSource.merged(passages.map(\.source)) + recall.sources)
        reply.offer = offer
        conversation.messages.append(reply)
        conversation.contextUsed = await count(instructions: instructions, prompt: prompt, answer: text)
        library.save(conversation)
    }

    static let cutOff = "Cut off: that was more than I can write at once."

    /// Streams the answer into `state`. Nil when nothing was written (`failure` says why); stopped, or out of room
    /// after some text (with the cut-off notice), keeps what was written.
    private func stream(_ prompt: String, in session: LanguageModelSession) async -> String? {
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
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where !text.isEmpty {
            notice = Self.cutOff
        } catch {
            Self.log.error("Chat answer failed: \(String(describing: error), privacy: .public)")
            if text.isEmpty { failure = Self.message(for: error) }
        }
        return text.isEmpty ? nil : text
    }

    /// The reformat agent (M33): code when it can (JSON, curl), else the model with nothing but the pasted text and
    /// the request, so the whole window is the text and its fix. Too long to fit twice: said at once.
    private func reformat(_ question: String) async {
        if let reply = Reformatter.byCode(question) { return finishTurn(ChatMessage(role: .friend, text: reply)) }
        defer { if !Task.isCancelled { state = .idle } }
        let room = Reformatter.maxInputTokens(contextSize: contextSize,
                                               instructionTokens: await count(instructions: Reformatter.taskInstructions))
        guard await Reformatter.tokens(question, model: model) <= room else {
            return finishTurn(ChatMessage(role: .friend, text: Reformatter.tooLong(maxTokens: room)))
        }
        let session = LanguageModelSession(model: model, instructions: Reformatter.taskInstructions)
        guard let text = await stream(question, in: session) else { return }
        conversation.messages.append(ChatMessage(role: .friend, text: text))
        library.save(conversation)
    }

    // MARK: Memory (M26)

    /// Most tokens deep recall's notes may take in the answer's prompt.
    nonisolated static let notesBudget = 700

    /// Quick recall: a few related older turns. Deep recall (the question points back, or much matches): up to four
    /// 4K passes over history, each noting what helps, and the answer gets the notes. Never what's already in view.
    private func recall(for question: String) async -> (block: String?, sources: [ChatSource]) {
        let current = conversation.id
        let inView = Set(conversation.messages[conversation.summarizedCount...].map(\.id))
        let turns = ChatMemory.turns(of: conversation) // this chat only (M34)
        guard !turns.isEmpty else { return (nil, []) }
        let vectors = await library.memory.vectors(for: turns)
        let ranked = ChatMemory.rank(question: question, vector: Retriever.embed(question), turns: turns, vectors: vectors,
                                     current: current, excluding: inView, links: library.links(of:))
        guard !ranked.isEmpty else { return (nil, []) }
        guard ChatMemory.wantsDeep(question, ranked: ranked), model.isAvailable else {
            guard let quick = ChatMemory.quickBlock(ranked) else { return (nil, []) }
            return (quick.text, quick.used.map(ChatMemory.source))
        }
        let slices = ChatMemory.slices(ranked)
        var notes: [String] = []
        var used: [ChatMemory.Scored] = []
        for (index, slice) in slices.enumerated() {
            guard !Task.isCancelled else { break }
            state = .remembering(slices.count == 1 ? "Remembering…" : "Remembering… (pass \(index + 1) of \(slices.count))")
            let session = LanguageModelSession(model: model, instructions: ChatMemory.passInstructions)
            guard let note = try? await session.respond(to: ChatMemory.passPrompt(question: question, slice: slice)).content,
                  !ChatMemory.isEmptyNote(note) else { continue }
            notes.append(note.trimmingCharacters(in: .whitespacesAndNewlines))
            used += slice.prefix(2)
        }
        guard !notes.isEmpty else { return (nil, []) }
        var block = "Notes from earlier in this conversation, read just now for this question:\n" + notes.joined(separator: "\n")
        if ChatPrompt.estimate(block) > Self.notesBudget { block = String(block.prefix(Self.notesBudget * 3)) + "…" }
        return (block, used.prefix(4).map(ChatMemory.source))
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
