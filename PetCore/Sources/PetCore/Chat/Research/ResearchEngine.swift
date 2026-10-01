//
//  ResearchEngine.swift
//  PetCore
//
//  Deep research (M28), the way research assistants do it, fitted to a 4K on-device model: every step is its own
//  fresh session. Plan sub-questions → gather sources (web search per question, a named site's key pages, the
//  user's files and earlier chats) → read each source once and note facts per question → look for gaps and search
//  again → write each section from its notes with [n] citations → a summary, an SEO section for a named site, and
//  the sources. The model never sees more than one source or one section at a time.
//

import Foundation
import FoundationModels

/// How much effort a research run spends: more questions, more pages, more rounds of filling gaps.
public nonisolated enum ResearchEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high, extraHigh = "extra-high"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .extraHigh: "Extra High"
        }
    }
    var questions: Int { switch self { case .low: 3; case .medium: 5; case .high: 7; case .extraHigh: 10 } }
    /// Web pages read from search, across all questions.
    var pages: Int { switch self { case .low: 6; case .medium: 15; case .high: 24; case .extraHigh: 36 } }
    var gapRounds: Int { switch self { case .low: 0; case .medium: 1; case .high: 2; case .extraHigh: 3 } }
    /// Batches of passages read per question (each the next-closest ones).
    var readPasses: Int { switch self { case .low, .medium: 1; case .high: 2; case .extraHigh: 3 } }
    var sitePages: Int { switch self { case .low: 4; case .medium: 8; case .high: 10; case .extraHigh: 12 } }
    public var estimate: String {
        switch self {
        case .low: "about 1 min"
        case .medium: "2–4 min"
        case .high: "4–7 min"
        case .extraHigh: "8–12 min"
        }
    }

    /// "low", "medium", "high", "extra-high", "extra high", "xhigh".
    public init?(word: String) {
        switch word.lowercased().replacingOccurrences(of: " ", with: "-") {
        case "low": self = .low
        case "medium", "med": self = .medium
        case "high": self = .high
        case "extra-high", "extrahigh", "xhigh", "max": self = .extraHigh
        default: return nil
        }
    }
}

/// What a research run did, kept on the report message: the plan, and what was read for each question.
public nonisolated struct ResearchLog: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public let question: String
        public var done = false
        public var notes = 0
    }

    public struct Source: Codable, Equatable, Sendable {
        public let title: String
        public let url: URL?
        /// "web", "site", "files", "chats".
        public let kind: String
    }

    public let topic: String
    public let effort: ResearchEffort
    public var steps: [Step] = []
    public var sources: [Source] = []
    /// What it's doing right now (live only).
    public var status = "Planning…"
    public var startedAt = Date.now
    public var finishedAt: Date?
}

struct ResearchNote: Equatable {
    let question: Int
    let fact: String
    let source: Int
}

@MainActor
final class ResearchEngine {
    private let model: SystemLanguageModel
    private let library: ChatLibrary
    private let conversation: Conversation
    private let update: (ResearchLog) -> Void
    private var log: ResearchLog
    private var texts: [String] = [] // each source's text, by index
    private var notes: [ResearchNote] = []
    /// Every source cut into passages (with their meaning vectors), and which passages each question has seen.
    private var chunks: [(source: Int, text: String, vector: [Double]?)] = []
    private var shown: Set<String> = []
    private var siteHome: SitePage?
    /// What a fact from someone else's page must name to count: the topic's exact terms and the site's own name.
    private var subjectNames: [String] = []

    init(topic: String, effort: ResearchEffort, model: SystemLanguageModel, library: ChatLibrary, conversation: Conversation,
         update: @escaping (ResearchLog) -> Void) {
        self.model = model
        self.library = library
        self.conversation = conversation
        self.update = update
        self.log = ResearchLog(topic: topic, effort: effort)
    }

    private func status(_ text: String) {
        log.status = text
        update(log)
    }

    /// The report (Markdown), its sources for chips, and the log.
    func run() async throws -> (report: String, sources: [ChatSource], log: ResearchLog) {
        let topic = log.topic, depth = log.effort
        let terms = ExactTerms.find(topic)
        subjectNames = terms
        let site = WebSearch.links(in: topic).first

        // 1. Plan.
        status("Planning the research…")
        let questions = await plan(topic, count: depth.questions)
        log.steps = questions.map { ResearchLog.Step(question: $0) }
        update(log)
        try Task.checkCancellation()

        // 2. Gather: the named site's key pages and its SEO, the user's own material, then the web per question.
        var seo: SEOReport?
        if let site {
            status("Reading \(site.host() ?? "the site")…")
            let pages = await SiteCrawler.crawl(site, pages: depth.sitePages) { [weak self] url in
                Task { @MainActor in self?.status("Reading \(url.path().isEmpty ? url.absoluteString : url.path())…") }
            }
            for page in pages { add(page.source.title, page.url, "site", page.source.text) }
            siteHome = pages.first
            status("Checking the site's SEO…")
            seo = await SEOReport.check(pages)
            // What others say: the organisation's own name (from its home page title), not just its address.
            if let name = pages.first.map({ Self.organisation($0.source.title) }), !name.isEmpty {
                subjectNames.append(name.lowercased())
                for query in ["\(name)", "\(name) reviews", "\(name) company profile"] {
                    status("Searching what others say: \(query)")
                    await search(query, terms: terms + [name.lowercased()], limit: 2, external: site)
                    try Task.checkCancellation()
                }
            }
        }
        addOwnMaterial(topic: topic, questions: questions)
        try Task.checkCancellation()
        let perQuestion = max(1, depth.pages / max(1, questions.count))
        for (index, question) in questions.enumerated() {
            status("Searching: \(question)")
            await search(question, terms: terms, limit: perQuestion)
            _ = index
            try Task.checkCancellation()
        }

        // 3. For each question, read the passages closest to it across every source.
        try await readAll(questions: questions)

        // 4. Gaps: questions with few facts get another search, then reading.
        for round in 0..<depth.gapRounds {
            let thin = questions.indices.filter { index in notes.filter { $0.question == index }.count < 3 }
            let gaps = await findGaps(questions: questions, thin: thin)
            guard !gaps.isEmpty else { break }
            status("Filling gaps (round \(round + 1))…")
            for gap in gaps {
                await search(gap, terms: terms, limit: 2)
                try Task.checkCancellation()
            }
            try await readAll(questions: questions, only: thin)
        }

        // 5. Write: each section from its notes, then the summary, then SEO.
        var sections: [(String, String)] = []
        for (index, question) in questions.enumerated() {
            status("Writing: \(question)")
            sections.append((question, await writeSection(question, notes: notes.filter { $0.question == index })))
            log.steps[index].done = true
            update(log)
            try Task.checkCancellation()
        }
        status("Writing the summary…")
        let summary = await summarize(topic, sections: sections)
        // SEO advice is written from the measurements by code: the model contradicted them ("all pages lack <h1>").
        let seoSection = seo.map(Self.seoFixes)
        // At a glance: a diagram drawn from the written sections, short labels only, each checked against them.
        // A mind map of what they do unless the request names another kind ("… with a timeline").
        status("Drawing the overview…")
        let written = sections.filter { $0.1 != Self.nothingFound }.map { "## \($0.0)\n\($0.1)" }.joined(separator: "\n\n")
        let kind = DiagramIntent.mentions(topic) ? DiagramIntent.kind(topic) : .mindmap
        let request = kind == .mindmap
            ? "A mind map of \(Self.title(Self.cleanTopic(topic))): 4 to 6 main areas of what it does, each with 2 or 3 short examples. Labels of 1 to 4 words."
            : topic
        let overview = (try? await DiagramMaker.make(kind, request: request, material: String(written.prefix(6000)), model: model))
            .flatMap { Self.groundedMap($0, in: written, root: Self.siteName(siteHome?.url) ?? Self.title(Self.cleanTopic(topic))) }
        log.status = "Done"
        log.finishedAt = .now
        return (assemble(topic: topic, summary: summary, sections: sections, overview: overview, seo: seo, seoText: seoSection), chips(), log)
    }

    // MARK: Steps

    private func plan(_ topic: String, count: Int) async -> [String] {
        let root = DynamicGenerationSchema(name: "Plan", description: "Research plan", properties: [
            .init(name: "questions", description: "Sub-questions that together answer the topic",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 2, maximumElements: count)),
        ])
        let session = LanguageModelSession(model: model, instructions: Self.planInstructions)
        let prompt = "Topic: \(topic)\nWrite \(count) sub-questions. Keep names and websites exactly as written."
        guard let schema = try? GenerationSchema(root: root, dependencies: []),
              let content = try? await session.respond(to: prompt, schema: schema).content,
              let questions = try? content.value([String].self, forProperty: "questions"), !questions.isEmpty else { return [topic] }
        return Array(questions.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(count))
    }

    @discardableResult
    private func add(_ title: String, _ url: URL?, _ kind: String, _ text: String) -> Int? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !log.sources.contains(where: { url != nil && $0.url.map(WebSearch.pageKey) == url.map(WebSearch.pageKey) }) else { return nil }
        // A site's pages often share one title: tell them apart by path.
        var name = title
        if let url, log.sources.contains(where: { $0.title == title }) || kind == "site", !url.path().isEmpty, url.path() != "/" {
            name = "\(title) · \(url.path())"
        }
        log.sources.append(ResearchLog.Source(title: name, url: url, kind: kind))
        texts.append(text)
        update(log)
        return texts.count - 1
    }

    /// The user's files: what's closest to the topic and each question, as one source.
    private func addOwnMaterial(topic: String, questions: [String]) {
        let documents = library.documents(for: conversation.id).filter { $0.kind != .web }
        var passages: [String] = []
        for query in [topic] + questions {
            let hits = Retriever.rank(query, vector: Retriever.embed(query), in: documents).prefix(2)
            passages += hits.map { "(\($0.source.label)) \($0.passage.text)" }.filter { !passages.contains($0) }
        }
        if !passages.isEmpty { add("Your files", nil, "files", passages.joined(separator: "\n")) }
        // ponytail: earlier chats are left out: they hold the model's own past answers, so a wrong guess
        // ("$500,000 funding") came back as a "source". Add them back only as clearly-marked context if asked.
    }

    /// `external`: leave out pages of this site (looking for what others say).
    private func search(_ question: String, terms: [String], limit: Int, external: URL? = nil) async {
        let queries = external == nil ? ChatPrompt.searchQueries(model: [question], terms: terms, question: question) : [question]
        var found = (try? await WebSearch.search(objective: question, queries: queries)) ?? []
        if !terms.isEmpty { found = found.filter { ExactTerms.mentions($0.title + " " + $0.text, terms) } }
        if let external, let host = external.host()?.replacingOccurrences(of: "www.", with: "") {
            found = found.filter { $0.site != host }
        }
        for source in WebSource.distinct(found).prefix(limit) { add(source.title, source.url, "web", source.text) }
    }

    /// One question at a time: the passages closest to it from every source (meaning plus shared words), and
    /// facts for that question only. Shown one source against all questions at once, the small model filed facts
    /// under the wrong question (pricing as "how to contact them").
    private func readAll(questions: [String], only: [Int]? = nil) async throws {
        let chunked = Set(chunks.map(\.source))
        for index in texts.indices where !chunked.contains(index) {
            for piece in Chunker.passages(from: [(texts[index], .none)]) { chunks.append((index, piece.text, Retriever.embed(piece.text))) }
        }
        let fact = DynamicGenerationSchema(name: "Fact", description: "A fact", properties: [
            .init(name: "source", description: "The number in brackets of the passage it comes from", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "fact", description: "One specific fact that answers the question, in a short sentence", schema: DynamicGenerationSchema(type: String.self)),
        ])
        let root = DynamicGenerationSchema(name: "Notes", description: "Facts that answer the question", properties: [
            .init(name: "facts", description: "Facts that answer the question; empty if none do",
                  schema: DynamicGenerationSchema(arrayOf: fact, minimumElements: 0, maximumElements: 8)),
        ])
        guard let schema = try? GenerationSchema(root: root, dependencies: []) else { return }
        for question in only ?? Array(questions.indices) {
          for pass in 0..<log.effort.readPasses {
            status("Reading for: \(questions[question])" + (pass > 0 ? " (more, \(pass + 1))" : ""))
            let picked = closest(to: questions[question], for: question)
            guard !picked.isEmpty else { break }
            picked.forEach { shown.insert("\(question)|\($0)") }
            let excerpt = picked.map { "[\(chunks[$0].source + 1)] \(chunks[$0].text)" }.joined(separator: "\n")
            let session = LanguageModelSession(model: model, instructions: Self.noteInstructions)
            let prompt = "Question: \(questions[question])\n\nPassages:\n\(excerpt)"
            if let content = try? await session.respond(to: prompt, schema: schema).content,
               let items = try? content.value([GeneratedContent].self, forProperty: "facts") {
                let allowed = Set(picked.map { chunks[$0].source })
                for item in items {
                    guard let number = try? item.value(Int.self, forProperty: "source"), allowed.contains(number - 1),
                          let text = try? item.value(String.self, forProperty: "fact"), !text.isEmpty, !Self.isNonFact(text),
                          text.split(whereSeparator: \.isWhitespace).count <= Self.maxFactWords, !Self.isChrome(text),
                          Self.supported(text, by: texts[number - 1]),
                          Self.aboutSubject(text, kind: log.sources[number - 1].kind, names: subjectNames),
                          !notes.contains(where: { $0.question == question && $0.fact.lowercased() == text.lowercased() }) else { continue }
                    notes.append(ResearchNote(question: question, fact: text, source: number - 1))
                    log.steps[question].notes += 1
                }
                update(log)
            }
            try Task.checkCancellation()
          }
        }
    }

    /// The unseen passages most about `text`, up to the reading budget.
    private func closest(to text: String, for question: Int) -> [Int] {
        let vector = Retriever.embed(text + " " + log.topic)
        let words = Retriever.keywords(text)
        let ranked = chunks.indices.filter { !shown.contains("\(question)|\($0)") }.map { index in
            let meaning = vector.flatMap { query in chunks[index].vector.map { Retriever.cosine(query, $0) } } ?? 0
            // The site's own key pages (home, about, services) say what it does; articles tell one story each.
            let keyPage = log.sources[chunks[index].source].kind == "site" && !Self.isArticle(log.sources[chunks[index].source].url)
            return (index, meaning + 0.15 * Double(words.intersection(Retriever.keywords(chunks[index].text)).count) + (keyPage ? 0.12 : 0))
        }.sorted { $0.1 > $1.1 }
        var picked: [Int] = [], tokens = 0
        for (index, _) in ranked where picked.count < 12 {
            let cost = ChatPrompt.estimate(chunks[index].text) + 8
            guard tokens + cost <= Self.sourceBudget else { continue }
            picked.append(index)
            tokens += cost
        }
        return picked.sorted()
    }

    /// Questions with fewer than three facts: the model suggests a search for each (or nothing).
    private func findGaps(questions: [String], thin: [Int]) async -> [String] {
        guard !thin.isEmpty else { return [] }
        let session = LanguageModelSession(model: model, instructions: Self.gapInstructions)
        let prompt = thin.map { index in
            "Question: \(questions[index])\nKnown so far: " + notes.filter { $0.question == index }.map(\.fact).joined(separator: " ")
        }.joined(separator: "\n\n")
        let text = (try? await session.respond(to: prompt).content) ?? ""
        return Array(ChatPrompt.queries(from: text).prefix(thin.count))
    }

    /// A short paragraph that answers the question (written, then checked), and the key facts under it, cited.
    /// The list carries the names, emails and figures even when the small model's paragraph drops them.
    private func writeSection(_ question: String, notes noted: [ResearchNote]) async -> String {
        let notes = await answering(question, noted)
        let points = Self.keyFacts(notes)
        guard notes.count >= Self.minimumFacts, !points.isEmpty else { return Self.nothingFound }
        let facts = notes.prefix(14).map { "[\($0.source + 1)] \($0.fact)" }.joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: Self.sectionInstructions)
        let written = (try? await session.respond(to: "Question: \(question)\n\nFacts:\n\(facts)",
                                                  options: GenerationOptions(maximumResponseTokens: 300)).content) ?? ""
        var paragraph = Self.grounded(Self.citationsLast(Self.cleanSection(written)), in: notes.map(\.fact).joined(separator: " "))
        if paragraph.split(whereSeparator: \.isWhitespace).count < 12 { paragraph = "" } // a refusal or filler
        let said = Retriever.keywords(paragraph)
        let list = points.filter { point in
            let words = Retriever.keywords(point.fact)
            return words.isEmpty || Double(words.intersection(said).count) / Double(words.count) < 0.6
        }
        guard !paragraph.isEmpty || list.count >= Self.minimumFacts else { return Self.nothingFound }
        let bullets = list.prefix(6).map { "- \($0.fact.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))) [\($0.source + 1)]" }
        return ([paragraph] + (bullets.isEmpty ? [] : [(paragraph.isEmpty ? "" : "**Key facts**\n") + bullets.joined(separator: "\n")]))
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Facts worth listing: three words or more (not a bare "Client" or "Payment gateway"), each
    /// saying something the ones before it didn't.
    static func keyFacts(_ notes: [ResearchNote]) -> [ResearchNote] {
        var kept: [ResearchNote] = []
        for note in notes where note.fact.split(whereSeparator: \.isWhitespace).count >= 3 {
            let words = Retriever.keywords(note.fact)
            let repeated = kept.contains { other in
                let shared = words.intersection(Retriever.keywords(other.fact)).count
                return Double(shared) / Double(max(1, min(words.count, Retriever.keywords(other.fact).count))) >= 0.7
            }
            if !repeated { kept.append(note) }
        }
        return kept
    }

    /// A noted fact must come from its source: most of its words appear there ("design, development, testing and
    /// deployment" noted from a 12-word portfolio page doesn't).
    static func supported(_ fact: String, by source: String) -> Bool {
        let words = Retriever.keywords(fact)
        guard words.count >= 2 else { return true }
        let text = source.lowercased()
        let found = words.filter { text.contains($0) }.count
        return Double(found) / Double(words.count) >= 0.6
    }

    /// On the subject's own site everything is about it; elsewhere (a LinkedIn profile, a directory) a fact must
    /// name it, or "works at Universitas Padjadjaran" ends up answering "case studies".
    static func aboutSubject(_ fact: String, kind: String, names: [String]) -> Bool {
        guard kind == "web", !names.isEmpty else { return true }
        let text = fact.lowercased()
        // Whole words: "fazz" is not "Fazza India".
        func mentions(_ word: some StringProtocol) -> Bool {
            text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: String(word)) + #"\b"#, options: .regularExpression) != nil
        }
        return names.contains { name in
            mentions(name) || name.split(separator: ".").first.map { $0.count > 3 && mentions($0) } == true
        }
    }

    /// "[9] The client list includes…" → "The client list includes… [9]".
    static func citationsLast(_ text: String) -> String {
        // A sentence ends at . ! ? followed by a space or the end ("antartech.co" doesn't end one).
        text.replacingOccurrences(of: #"\[\d+\]\s+(?=[^\[.!?]*(\.(?!\s|$)[^\[.!?]*)*\[\d+\])"#, with: "", options: .regularExpression) // already cited at its end
            .replacingOccurrences(of: #"\[(\d+)\]\s+([A-Z][^\[]*?[.!?])(?=\s|$)"#, with: "$2 [$1]", options: .regularExpression)
    }

    static func isArticle(_ url: URL?) -> Bool {
        guard let parts = url?.pathComponents.filter({ $0 != "/" }), parts.count > 1 else { return false }
        return SiteCrawler.articleFolders.contains(parts[0].lowercased())
    }

    /// Facts are short: a long one is a copied passage ("A shipment goes out An invoice is generated… Repeat").
    static let maxFactWords = 24

    /// Menus and buttons read off a page ("See Pricing See Our Works", "Category All Client Project Description").
    static func isChrome(_ text: String) -> Bool {
        text.range(of: #"\b(see (our|pricing|more|all)|read more|learn more|view (all|more)|click here|category all|our portfolio see|get started|contact us now)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A mind map keeps only the labels the report backs (a word of each in it) and stays small enough to read;
    /// other kinds pass as drawn. Nil when fewer than two areas are left.
    static func groundedMap(_ diagram: ChatDiagram, in report: String, root: String) -> ChatDiagram? {
        guard case .mindmap(_, let branches) = diagram else { return diagram }
        let known = report.lowercased()
        func backed(_ label: String) -> Bool {
            let words = Retriever.keywords(label)
            return !words.isEmpty && words.contains { known.contains($0) } && label.split(separator: " ").count <= 5
        }
        // A heading like "Markets" is backed by its examples ("Indonesia", "Singapore") if not by its own words.
        var used = Set<String>() // each example once, under its first branch
        let kept = branches.map { branch in
            ChatDiagram.Branch(label: branch.label, children: Array(branch.children.filter { backed($0) && used.insert($0.lowercased()).inserted }.prefix(3)))
        }
            .filter { $0.label.split(separator: " ").count <= 5 && (backed($0.label) || !$0.children.isEmpty) }
            .prefix(6)
        let centre = root.split(separator: " ").prefix(4).joined(separator: " ")
        return kept.count >= 2 ? .mindmap(root: centre.isEmpty ? "Topic" : centre, branches: Array(kept)) : nil
    }

    /// "Fazz" from fazz.com, "Antartech" from www.antartech.co.
    static func siteName(_ url: URL?) -> String? {
        guard let host = url?.host()?.replacingOccurrences(of: "www.", with: ""), let name = host.split(separator: ".").first, !name.isEmpty else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static let minimumFacts = 2
    static let nothingFound = "_Nothing reliable was found for this._"

    /// Sentences whose names or numbers appear in none of the facts are invented ("Alex Smith", "$500,000"), and
    /// sentences about the source rather than the subject ("the text does not mention…") say nothing: both go.
    static func grounded(_ section: String, in facts: String) -> String {
        let known = facts.lowercased()
        // ", suggesting a global reach": a guess hung on a fact goes, the fact stays.
        let section = section.replacingOccurrences(of: #",?\s+(suggesting|indicating|implying|which (suggests|indicates|implies))\b[^.\[]*"#,
                                                   with: "", options: [.regularExpression, .caseInsensitive])
        let paragraphs = section.components(separatedBy: "\n\n").map { paragraph -> String in
            var kept: [String] = []
            var said = Set<String>()
            paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
                guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
                let meta = sentence.range(of: #"\b(the|this|provided|given) (text|source|sources|material|facts)\b|^(i'?m sorry|i cannot|i can'?t|as an ai)"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil || isNonFact(sentence)
                // Vague filler ("the tech stack is then used to define requirements") shares few words with the facts.
                let words = Retriever.keywords(sentence)
                let shared = words.isEmpty ? 1 : Double(words.filter { known.contains($0) }.count) / Double(words.count)
                let key = sentence.lowercased().replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
                if !meta && shared >= 0.5 && claims(in: sentence).allSatisfy({ known.contains($0) }) && said.insert(key).inserted { kept.append(sentence) }
            }
            return kept.joined(separator: " ")
        }
        return paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The checkable parts of a sentence: numbers ("500,000", "400%") and capitalised names after its first word.
    static func claims(in sentence: String) -> [String] {
        let clean = sentence.replacingOccurrences(of: #"\[\d+(,\s*\d+)*\]"#, with: "", options: .regularExpression)
        let words = clean.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "," || $0 == ";" || $0 == ":" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?\"'’“”$")) }
        var found: [String] = []
        for (index, word) in words.enumerated() where !word.isEmpty {
            if word.contains("."), word.range(of: #"^[a-z0-9-]+\.[a-z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                found.append(word.lowercased()) // "antarctic.co" for "antartech.co" is a different site
            } else if word.rangeOfCharacter(from: .decimalDigits) != nil {
                found.append(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            } else if index > 0, word.first?.isUppercase == true, word.count > 2, !commonCapitals.contains(word) {
                found.append(word.lowercased())
            }
        }
        return found
    }

    static let commonCapitals: Set<String> = ["The", "They", "Their", "This", "These", "It", "Its", "In", "And", "Also", "However", "While",
                                              "For", "With", "UI", "UX", "API", "APIs", "AI", "IT", "SEO", "SMBs", "SMEs"]

    /// Only the facts that answer the question: notes drift (the team under "what tools do they use", pricing
    /// under "where are they"), and neither keywords nor the on-device embedding tell them apart. One short check.
    private func answering(_ question: String, _ notes: [ResearchNote]) async -> [ResearchNote] {
        guard notes.count > 1 else { return notes }
        let shown = Array(notes.prefix(20))
        let root = DynamicGenerationSchema(name: "Check", description: "Facts that answer the question", properties: [
            .init(name: "answers", description: "Numbers of the facts that directly answer the question",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Int.self), minimumElements: 0, maximumElements: shown.count)),
        ])
        let list = shown.enumerated().map { "\($0.offset + 1). \($0.element.fact)" }.joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: Self.checkInstructions)
        guard let schema = try? GenerationSchema(root: root, dependencies: []),
              let content = try? await session.respond(to: "Question: \(question)\n\nFacts:\n\(list)", schema: schema).content,
              let numbers = try? content.value([Int].self, forProperty: "answers") else { return notes }
        return shown.indices.filter { numbers.contains($0 + 1) }.map { shown[$0] }
    }

    /// Sections are prose: headings, lines that are only citations, and repeated lines go.
    static func cleanSection(_ text: String) -> String {
        var seen = Set<String>()
        let lines = String(decoding: ChatFileWriter.markdown(text), as: UTF8.self).components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { return false }
            if trimmed.range(of: #"^(\[\d+\][,\s]*)+$"#, options: .regularExpression) != nil { return false }
            return trimmed.isEmpty || seen.insert(trimmed.lowercased()).inserted
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "The source does not state who uses it": not a fact.
    static func isNonFact(_ text: String) -> Bool {
        text.range(of: #"\b(does not|doesn't|do not|don't|did not) (state|mention|say|specify|provide|include)|not (explicitly |specifically )?(mentioned|stated|specified|provided|listed)|no (information|mention|details|other|specific)|(was|were) (mentioned|provided|listed)|absence of|lack of (explicit|specific)|(could|may|might) be relevant|(some|these|the) facts|the report (notes|says|mentions)|lack of reliable|unknown|unclear"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Antartech Solutions" from "Antartech Solutions - Software House".
    static func organisation(_ title: String) -> String {
        title.components(separatedBy: CharacterSet(charactersIn: "-–—|:·")).first?.trimmingCharacters(in: .whitespaces) ?? title
    }

    /// "antartech.co especially their line of work" from "… . make them into a pdf and md file": the part that
    /// asks for files is about the output, and left in it ends up in the title and the summary.
    static func withoutFileRequest(_ request: String) -> String {
        let file = #"(pdf|md|markdown|html|txt|text file|docx?|file|fiile|files|document)"#
        let clause = #"[\s,.;]*(and\s+|then\s+)?(please\s+)?\b(make|turn|put|export|save|give|create|write|generate|convert)\b[^.!?]*\b"# + file + #"\b[^.!?]*[.!?]?\s*$"#
        let short = #"[\s,.;]+(as|in|into)\s+an?\s+"# + file + #"\b[^.!?]*$"#
        var topic = request
        for pattern in [clause, short] {
            topic = topic.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        topic = topic.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;")))
        return topic.isEmpty ? request : topic
    }

    /// "antartech.co" from "research about antartech.co website".
    static func cleanTopic(_ topic: String) -> String {
        topic.replacingOccurrences(of: #"^\s*(please\s+)?(do\s+)?(a\s+)?(deep\s+)?research(\s+(about|on|into|the))*\s+"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(website|site|web site)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func summarize(_ topic: String, sections: [(String, String)]) async -> String {
        // Only each section's paragraph: given the key-fact lists too, the model copies them out.
        let paragraphs = sections.filter { $0.1 != Self.nothingFound }.map { ($0.0, $0.1.components(separatedBy: "\n\n**Key facts**").first ?? $0.1) }
            .filter { !$0.1.hasPrefix("- ") }
        var body = paragraphs.map { "## \($0.0)\n\($0.1)" }.joined(separator: "\n\n")
        if ChatPrompt.estimate(body) > 2400 { body = String(body.prefix(7200)) }
        let session = LanguageModelSession(model: model, instructions: Self.summaryInstructions)
        let text = (try? await session.respond(to: "Topic: \(topic)\n\n\(body)", options: GenerationOptions(maximumResponseTokens: 450)).content) ?? ""
        let facts = sections.map(\.1).joined(separator: " ")
        let lines = String(decoding: ChatFileWriter.markdown(text), as: UTF8.self).components(separatedBy: "\n").map { line in
            let bullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            let kept = Self.grounded(bullet ? String(line.dropFirst(2)) : line, in: facts)
            return kept.isEmpty ? "" : (bullet ? "- " : "") + kept
        }
        return Self.tidySummary(lines)
    }

    /// One opening sentence, then up to six bullets, no line twice.
    static func tidySummary(_ lines: [String]) -> String {
        var seen = Set<String>(), opening: String?, bullets: [String] = []
        for line in lines where !line.isEmpty {
            let text = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            let key = text.lowercased().replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            guard seen.insert(key).inserted else { continue }
            if !line.hasPrefix("- "), opening == nil, bullets.isEmpty { opening = text } else { bullets.append("- " + text) }
        }
        return ([opening].compactMap { $0 } + bullets.prefix(6)).joined(separator: "\n")
    }

    /// The fixes that matter for this site, most impactful first, each saying why.
    static func seoFixes(_ seo: SEOReport) -> String {
        let all = seo.pages.flatMap(\.issues) + seo.siteIssues
        func has(_ words: String) -> Bool { all.contains { $0.localizedCaseInsensitiveContains(words) } }
        func pages(_ words: String) -> String {
            let paths = seo.pages.filter { $0.issues.contains { $0.localizedCaseInsensitiveContains(words) } }.map { $0.url.path().isEmpty ? "/" : $0.url.path() }
            return paths.count == seo.pages.count ? "every page" : ListFormatter.localizedString(byJoining: paths)
        }
        var fixes: [String] = []
        if has("noindex") { fixes.append("**Remove `noindex`** (\(pages("noindex"))): search engines are told to leave these pages out.") }
        if has("share one title") { fixes.append("**Give every page its own title** (30–60 characters, the page's topic first): with one title on every page, search engines can't tell them apart.") }
        if has("share one meta description") || has("meta description is") || has("no meta description") {
            fixes.append("**Write a meta description per page** (70–160 characters): it's the text under the link in results, and a shared or overlong one gets cut or replaced.")
        }
        if has("<h1>") { fixes.append("**Add one `<h1>` heading** on \(pages("<h1>")): it tells search engines and screen readers what the page is about.") }
        if has("words of visible text") { fixes.append("**Add real text** to \(pages("words of visible text")): thin pages rarely rank; describe the services, projects and clients in words, not only images.") }
        if has("canonical") { fixes.append("**Add canonical links** (\(pages("canonical"))): they point search engines at the one address to index.") }
        if has("structured data") { fixes.append("**Add structured data** (JSON-LD `Organization`, and `Article` on posts): enables richer results like logo and contact details.") }
        if has("open graph") { fixes.append("**Add Open Graph tags** (title, description, image): links shared on WhatsApp, LinkedIn and others then show a proper preview.") }
        if has("alt text") { fixes.append("**Add alt text to images** (\(pages("alt text"))): needed for accessibility and image search.") }
        if !seo.robotsTxt { fixes.append("**Add robots.txt** pointing to the sitemap.") }
        if !seo.sitemap { fixes.append("**Add sitemap.xml** so every page is found.") }
        guard !fixes.isEmpty else { return "No significant issues were measured." }
        return "Most important fixes, from what was measured on \(seo.pages.count) pages:\n\n"
            + fixes.prefix(6).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    // MARK: The report

    /// The named site's own one-line description of itself (its meta description), when it has one.
    private var about: String? {
        guard log.sources.first?.kind == "site", let html = siteHome,
              let description = SEOPage.measure(html).description, description.split(separator: " ").count >= 6 else { return nil }
        return description
    }

    private func assemble(topic: String, summary: String, sections: [(String, String)], overview: ChatDiagram?,
                          seo: SEOReport?, seoText: String?) -> String {
        let day = Date.now.formatted(date: .abbreviated, time: .omitted)
        var parts = ["# Research: \(Self.title(Self.cleanTopic(topic)))",
                     "_\(log.effort.title) effort research · \(log.sources.count) sources · \(day)_",
                     about.map { "**About:** \($0) [1]" } ?? "",
                     "## Summary\n\(summary)"].filter { !$0.isEmpty }
        if let overview { parts.append("## At a glance\n" + overview.markdown) }
        parts += sections.filter { $0.1 != Self.nothingFound }.map { "## \($0.0)\n\($0.1)" }
        if let seo {
            var table = "| Page | Words | Issues |\n|---|---|---|"
            for page in seo.pages {
                let own = seo.issues(of: page)
                table += "\n| \(page.url.path().isEmpty ? "/" : page.url.path()) | \(page.words) | \(own.isEmpty ? "–" : own.joined(separator: "; ")) |"
            }
            let site = (["robots.txt \(seo.robotsTxt ? "✓" : "missing")", "sitemap.xml \(seo.sitemap ? "✓" : "missing")"] + seo.siteIssues)
                .joined(separator: " · ")
            let everyPage = seo.commonIssues.isEmpty ? "" : "\n\n**On every page:** " + seo.commonIssues.joined(separator: "; ") + "."
            parts.append("## SEO\n\(seoText ?? "")\n\n**Measured:** \(site)\(everyPage)\n\n\(table)")
        }
        let open = sections.filter { $0.1.hasPrefix("_Nothing reliable") }.map(\.0)
        if !open.isEmpty { parts.append("## Open questions\n" + open.map { "- \($0)" }.joined(separator: "\n")) }
        parts.append("## Sources\n" + log.sources.enumerated().map { index, source in
            let label = source.url.map { "[\(source.title)](\($0.absoluteString))" } ?? source.title
            let kind = source.kind == "files" || source.kind == "chats" ? " _(yours)_" : source.kind == "site" ? " _(the site)_" : ""
            return "\(index + 1). \(label)\(kind)"
        }.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    private func chips() -> [ChatSource] {
        log.sources.enumerated().filter { index, _ in notes.contains { $0.source == index } }.map { index, source in
            ChatSource(documentName: "[\(index + 1)] \(source.title)", kind: source.url == nil ? .text : .web, locator: .none,
                       text: String(texts[index].prefix(3000)), url: source.url)
        }
    }

    static func title(_ topic: String) -> String {
        let clean = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 70 ? String(clean.prefix(69)) + "…" : clean
    }

    // MARK: Instructions

    /// Tokens of passages shown to a reading session.
    static let sourceBudget = 2400

    static let planInstructions = """
        You plan research. Break the topic into distinct sub-questions that together answer it thoroughly. When the \
        topic says what matters most ("especially their line of work"), most sub-questions go deep on that: what \
        exactly they do, for whom, how, with which examples. Ask only about concrete things public pages state: \
        services or products, projects and case studies, clients and industries, how they work, tools, team, \
        location, pricing, contact. Never ask about challenges, future plans, strategies, opinions, or how an \
        industry evolved, and nothing about finances, funding or competitors unless the topic asks. Each sub-question is short and specific. \
        Keep names exactly as written.
        """

    static let noteInstructions = """
        You take notes for a researcher. From the numbered passages, note specific facts that answer the question: \
        names, numbers, dates, offerings, projects, clients. Only facts a passage actually states and only ones that \
        answer this question; nothing from general knowledge. Give each the number of the passage it comes from. If \
        none answer it, return no facts.
        """

    static let checkInstructions = """
        You check research notes. Pick every fact that helps answer the question. Leave out facts that are clearly \
        about a different topic (for "where are they located", a pricing feature; for "what tools do they use", \
        the names of the team).
        """

    static let gapInstructions = """
        You review research notes. For each question, write one web search query (3 to 7 words) that would find what \
        is still missing. Keep names exactly as written. One query per line, nothing else.
        """

    static let sectionInstructions = """
        You write one paragraph of a research report from numbered facts: answer the question directly, connecting \
        the facts (what they have in common, what stands out) rather than listing them. Cite every claim with its \
        source number in brackets after it, like [3]. Use only the facts given; keep names, numbers and examples. \
        Under 120 words, no headings, no lists. No guesses ("suggesting", "likely"), and never say what a source \
        doesn't mention.
        """

    static let summaryInstructions = """
        You write the executive summary of a research report: first one sentence on what it is and what it does, then \
        4 to 6 bullet points with the most important findings, \
        keeping their [n] citations, then one sentence on what remains uncertain. Only what the sections say; \
        never mention files, formats or what you can't do. Markdown, no heading.
        """

}
