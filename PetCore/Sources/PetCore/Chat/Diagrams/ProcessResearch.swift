//
//  ProcessResearch.swift
//  PetCore
//
//  Flowcharts of a real process, drawn from sources (M29): "how a Fazz payment works" is searched for, the
//  subject's own site read when the request names it, and this conversation's files and pages used; the model
//  lists the steps the passages describe, each tied to its passage, and a step whose words aren't in that passage
//  goes. Left to itself the model drew a plausible payment flow that wasn't Fazz's.
//

import Foundation
import FoundationModels
import NaturalLanguage

@MainActor
enum ProcessResearch {
    struct Result {
        let diagram: ChatDiagram
        let sources: [ChatSource]
    }

    /// A passage shown to the model, with where it came from.
    private struct Piece {
        let text: String
        let source: ChatSource
    }

    /// Fewer documented steps than this isn't a process worth drawing as "theirs".
    static let minimumSteps = 3
    static let passageBudget = 2200

    /// Nil when the sources don't describe the process well enough.
    static func flowchart(request: String, subject: String, library: ChatLibrary, conversation: Conversation,
                          model: SystemLanguageModel, status: (String) -> Void) async -> Result? {
        var pieces: [Piece] = []
        // This conversation's own files and pages first: research done earlier is the best material.
        let documents = library.documents(for: conversation.id)
        for hit in Retriever.rank(request, vector: Retriever.embed(request), in: documents).prefix(8)
        where ExactTerms.mentions(hit.passage.text, [subject.lowercased()]) || hit.document.kind != .web {
            pieces.append(Piece(text: hit.passage.text, source: ChatSource(documentName: ChatPrompt.passageLabel(hit), kind: hit.document.kind,
                                                                           locator: .none, text: hit.passage.text, url: hit.document.url)))
        }
        // Their own site, when the request names it.
        if let site = WebSearch.links(in: request).first {
            status("Reading \(site.host() ?? "the site")…")
            for page in await SiteCrawler.crawl(site, pages: 6) { pieces += passages(of: page.source) }
        }
        // What the web says about this process.
        let process = processWords(request).split(separator: " ").filter { $0 != subject.lowercased() }.joined(separator: " ")
        status("Searching how \(process.isEmpty ? subject : process) works…")
        let queries = ["\(subject) \(process) how it works", "\(subject) \(process) process steps", "\(subject) \(process) flow"]
        let found = (try? await WebSearch.search(objective: request, queries: queries)) ?? []
        for source in WebSource.distinct(found.filter { ExactTerms.mentions($0.title + " " + $0.text, [subject.lowercased()]) }).prefix(5) {
            pieces += passages(of: source)
        }
        guard !Task.isCancelled, !pieces.isEmpty else { return nil }
        status("Reading how it works…")
        return await steps(request: request, subject: subject, from: closest(pieces, to: request), model: model)
    }

    /// "payment" from "make a flowchart of how a Fazz payment works".
    static func processWords(_ request: String) -> String {
        let skip: Set<String> = ["make", "draw", "create", "show", "give", "flowchart", "flow", "chart", "diagram", "how", "does", "do",
                                 "work", "works", "the", "a", "an", "of", "for", "me", "please", "process", "can", "you", "is", "it"]
        return request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." })
            .map(String.init).filter { !skip.contains($0) && !$0.contains(".") }.joined(separator: " ")
    }

    private static func passages(of source: WebSource) -> [Piece] {
        let chip = ChatSource(documentName: source.title, kind: .web, locator: .none, text: String(source.text.prefix(3000)), url: source.url)
        return Chunker.passages(from: [(source.text, .none)]).map { Piece(text: $0.text, source: chip) }
    }

    /// The passages most about the process (meaning plus shared words), up to the budget.
    private static func closest(_ pieces: [Piece], to request: String) -> [Piece] {
        let vector = Retriever.embed(request)
        let words = Retriever.keywords(request)
        let ranked = pieces.map { piece in
            let meaning = vector.flatMap { query in Retriever.embed(piece.text).map { Retriever.cosine(query, $0) } } ?? 0
            return (piece, meaning + 0.15 * Double(words.intersection(Retriever.keywords(piece.text)).count))
        }.sorted { $0.1 > $1.1 }
        var picked: [Piece] = [], tokens = 0
        for (piece, _) in ranked where picked.count < 12 && !picked.contains(where: { $0.text == piece.text }) {
            let cost = ChatPrompt.estimate(piece.text) + 8
            guard tokens + cost <= passageBudget else { continue }
            picked.append(piece)
            tokens += cost
        }
        return picked
    }

    static let instructions = """
        You read sources about how a process works and list its steps in order, as the sources describe them. Only \
        steps a passage states; leave out anything they don't say, even if it's usual. A step that checks or \
        approves something is a yes/no question, with what happens when the answer is no if a passage says. Give \
        each step the number of the passage it comes from. If the passages don't describe the process, return no steps.
        """

    private static func steps(request: String, subject: String, from pieces: [Piece], model: SystemLanguageModel) async -> Result? {
        let text = DynamicGenerationSchema(type: String.self)
        let step = DynamicGenerationSchema(name: "Step", description: "One step of the process", properties: [
            .init(name: "quote", description: "The sentence in the passage that describes this step, copied", schema: text),
            .init(name: "label", description: "The step in 2 to 6 of your own words; a check is a short yes/no question ending with ?", schema: text),
            .init(name: "question", description: "true only if this step is a yes/no check", schema: DynamicGenerationSchema(type: Bool.self)),
            .init(name: "ifNo", description: "For a check: what happens when the answer is no, if a passage says; otherwise empty", schema: text),
            .init(name: "passage", description: "The number of the passage it comes from", schema: DynamicGenerationSchema(type: Int.self)),
        ])
        let root = DynamicGenerationSchema(name: "Process", description: "The process the passages describe", properties: [
            .init(name: "describes", description: "true only if the passages describe this process step by step (not a list of projects or features)",
                  schema: DynamicGenerationSchema(type: Bool.self)),
            .init(name: "title", description: "A short title", schema: text),
            .init(name: "steps", description: "The steps in order; empty if the passages don't describe it",
                  schema: DynamicGenerationSchema(arrayOf: step, minimumElements: 0, maximumElements: 12)),
        ])
        let numbered = pieces.enumerated().map { "[\($0.offset + 1)] \($0.element.text)" }.joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: instructions)
        guard let schema = try? GenerationSchema(root: root, dependencies: []),
              let content = try? await session.respond(to: "Process: \(request)\n\nPassages:\n\(numbered)", schema: schema).content,
              let items = try? content.value([GeneratedContent].self, forProperty: "steps"),
              (try? content.value(Bool.self, forProperty: "describes")) != false else { return nil }
        var kept: [(step: DiagramMaker.FlowStep, source: ChatSource)] = []
        var quotes: [String] = [] // what the sources said, to tell a process from a portfolio
        for item in items {
            guard let number = try? item.value(Int.self, forProperty: "passage"), pieces.indices.contains(number - 1),
                  let label = (try? item.value(String.self, forProperty: "label"))?.trimmingCharacters(in: .whitespaces), !label.isEmpty
            else { continue }
            let passage = pieces[number - 1]
            let quote = ((try? item.value(String.self, forProperty: "quote")) ?? "").trimmingCharacters(in: .whitespaces)
            // The step must be in its passage (its quote is, or most of its words are), and the short label about it.
            let grounded = documented(quote, in: passage.text) && !Retriever.keywords(label).isDisjoint(with: Retriever.keywords(quote))
                || ResearchEngine.supported(label, by: passage.text)
            guard grounded, isAction(label) else { continue } // the box text itself does something
            quotes.append(quote.isEmpty ? label : quote)
            let question = (try? item.value(Bool.self, forProperty: "question")) ?? false
            let ifNo = ((try? item.value(String.self, forProperty: "ifNo")) ?? "").trimmingCharacters(in: .whitespaces)
            if question, !ifNo.isEmpty, !DiagramMaker.isFailure(ifNo), documented(ifNo, in: passage.text) {
                // "no → our team will send you an agreement" is the next step, not a failure.
                kept.append((DiagramMaker.FlowStep(label: plain(label), question: false, ifNo: "", next: ""), passage.source))
                kept.append((DiagramMaker.FlowStep(label: short(ifNo), question: false, ifNo: "", next: ""), passage.source))
            } else {
                // A check is drawn as a decision only when its source says what happens on "no"; otherwise the
                // "no" branch would be invented, so it stays a step.
                let failure = !ifNo.isEmpty && documented(ifNo, in: passage.text) ? short(ifNo) : ""
                let decision = question && !failure.isEmpty
                kept.append((DiagramMaker.FlowStep(label: decision ? short(label) : plain(label), question: decision, ifNo: failure, next: ""),
                             passage.source))
            }
        }
        // One source's process: stitched across sources, a general guide's steps ran into Fazz's own.
        // Steps it documents, plus a lead for how-to pages (docs, help, guides) over news and blog articles.
        func key(_ source: ChatSource) -> String { source.url?.absoluteString ?? source.documentName }
        let counts = Dictionary(grouping: kept, by: { key($0.source) }).mapValues(\.count)
        func score(_ source: ChatSource) -> Int { (counts[key(source)] ?? 0) + howToBonus(source.url) }
        guard let best = kept.max(by: { score($0.source) < score($1.source) })?.source else { return nil }
        let steps = kept.filter { $0.source == best }.map(\.step)
        // Reworded as commands ("Create a website"), a portfolio's "Created a website…" is still a portfolio.
        guard steps.count >= minimumSteps, !isAchievementList(steps.map(\.label)), !isAchievementList(quotes) else { return nil }
        let title = ((try? content.value(String.self, forProperty: "title")) ?? "").trimmingCharacters(in: .whitespaces)
        let diagram = DiagramMaker.flowchart(title: title.isEmpty ? "How it works: \(subject)" : title, steps: steps)
        return diagram.isUsable ? Result(diagram: diagram, sources: [best]) : nil
    }

    static func howToBonus(_ url: URL?) -> Int {
        let path = (url?.host() ?? "") + (url?.path() ?? "")
        // News and blog first: "/newsroom/…/guide" is an article, not a how-to page.
        if path.range(of: #"(?i)/(news|newsroom|blog|press)/"#, options: .regularExpression) != nil { return -2 }
        if path.range(of: #"(?i)(^|[./])(docs?|help|support|guide|guides|faq|how-?to|getting-started|learn|kb)([./-]|$)"#, options: .regularExpression) != nil { return 3 }
        return 0
    }

    /// A step does something: it has a verb, and isn't a condition ("Whether you open…") or a thing ("Board Resolution").
    static func isAction(_ text: String) -> Bool {
        guard !text.isEmpty, text.range(of: #"(?i)^\s*(whether|depending|if|when|although|unless)\b"#, options: .regularExpression) == nil else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var verb = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, _ in
            if tag == .verb { verb = true }
            return !verb
        }
        return verb
    }

    /// "Created a website… Engineered a platform… Built a CMS…": a portfolio, not the steps of a process.
    static func isAchievementList(_ labels: [String]) -> Bool {
        let past = labels.filter { label in
            guard let first = label.split(separator: " ").first?.lowercased() else { return false }
            return first.count > 4 && first.hasSuffix("ed") && !["need", "proceed", "succeed"].contains(first)
        }
        return past.count * 2 > labels.count
    }

    /// Box text stays short: the first eight words of a copied sentence.
    static func short(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let cut = words.prefix(8).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        return words.count > 8 ? cut + "…" : cut
    }

    /// A statement, short: "Submit documents?" → "Submit documents".
    static func plain(_ text: String) -> String {
        short(text.trimmingCharacters(in: CharacterSet(charactersIn: "? ")))
    }

    /// Half the words of `label` appear in `text` (a question reworded from a statement still counts).
    static func documented(_ label: String, in text: String) -> Bool {
        let words = Retriever.keywords(label)
        guard !words.isEmpty else { return false }
        let lower = text.lowercased()
        return Double(words.filter { lower.contains(String($0.prefix(5))) }.count) / Double(words.count) >= 0.5
    }
}
