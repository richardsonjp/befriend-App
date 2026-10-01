//
//  Retriever.swift
//  PetCore
//
//  Finds the passages that answer a question: similarity of English sentence embeddings (question vs. each
//  passage's English note), plus a bonus for shared words, which catches names and terms in any language.
//

import Foundation
import NaturalLanguage

public nonisolated enum Retriever {
    /// How much each shared keyword adds on top of cosine similarity (0…1).
    static let keywordWeight = 0.15
    static let minScore = 0.05
    /// Added for pages just found for this very question.
    static let freshBoost = 0.3

    public struct Hit: Equatable, Sendable {
        public let document: ChatDocument
        public let passage: IndexedPassage
        public let score: Double

        public static func == (a: Hit, b: Hit) -> Bool {
            a.document.id == b.document.id && a.passage == b.passage && a.score == b.score
        }

        public var source: ChatSource {
            ChatSource(documentName: document.name, kind: document.kind, locator: passage.locator, text: passage.text, url: document.url)
        }
    }

    // ponytail: brute-force scan over every passage, an ANN index if libraries reach tens of thousands of passages.
    public static func rank(_ question: String, vector: [Double]?, in documents: [ChatDocument], boosting fresh: Set<UUID> = []) -> [Hit] {
        let words = keywords(question)
        return documents
            .flatMap { document in document.passages.map { (document, $0) } }
            .map { document, passage in
                let similarity = vector.flatMap { question in passage.vector.map { cosine(question, $0) } } ?? 0
                let shared = words.intersection(keywords(passage.text + " " + passage.note)).count
                let boost = fresh.contains(document.id) ? freshBoost : 0
                return Hit(document: document, passage: passage, score: similarity + Double(shared) * keywordWeight + boost)
            }
            .filter { $0.score >= minScore }
            .sorted { $0.score > $1.score }
    }

    /// The English sentence embedding, or nil where the OS doesn't have it (keyword search still works).
    public static func embed(_ text: String) -> [Double]? {
        NLEmbedding.sentenceEmbedding(for: .english)?.vector(for: text)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Lowercased words of 4+ letters, minus a few that carry no meaning.
    static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) })
    }

    static let stopWords: Set<String> = [
        "what", "when", "where", "which", "about", "this", "that", "these", "those", "with", "from", "have", "does",
        "there", "their", "they", "your", "into", "said", "says", "tell", "please", "file", "files", "passage",
    ]
}

/// The names a question is really about (M27): sites it mentions ("antartech.co" and "antartech"), "quoted
/// phrases", and words no dictionary knows (brand names, made-up names). When there are any, only passages that
/// mention one may answer it, and search looks for them exactly as typed: the small model otherwise "corrects"
/// antartech into Antarctica.
public nonisolated enum ExactTerms {
    static let maxTerms = 4

    /// `isWord` and `hasCorrection` are the spelling dictionaries (injected in tests).
    public static func find(_ question: String, isWord: (String) -> Bool = SpellCheck.isWord,
                            hasCorrection: (String) -> Bool = SpellCheck.hasCorrection) -> [String] {
        var terms: [String] = []
        func add(_ term: String) {
            let clean = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.count >= 3, !terms.contains(clean) { terms.append(clean) }
        }
        for link in WebSearch.links(in: question) {
            guard let host = link.host()?.lowercased().replacingOccurrences(of: "www.", with: "") else { continue }
            add(host)
            let labels = host.split(separator: ".")
            if labels.count >= 2 { add(String(labels[labels.count - 2])) } // "antartech" from antartech.co
        }
        if let quoted = try? NSRegularExpression(pattern: #"["“]([^"”]{2,60})["”]"#) {
            for match in quoted.matches(in: question, range: NSRange(question.startIndex..., in: question)) {
                if let range = Range(match.range(at: 1), in: question) { add(String(question[range])) }
            }
        }
        // Addresses already counted above: their pieces ("https", "www") aren't names.
        let words = question.replacingOccurrences(of: #"\S*://\S*|\b(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,24}\S*"#,
                                                  with: " ", options: [.regularExpression, .caseInsensitive])
        for word in MessageCheck.tokens(words) where word.count >= 4 {
            let lower = word.lowercased()
            guard !terms.contains(where: { $0.contains(lower) }), !Retriever.stopWords.contains(lower),
                  !lower.contains("."), lower.contains(where: \.isLetter) else { continue }
            // Unknown words are names ("Zqxwvy") unless they're lowercase typos the dictionary can fix ("webiste").
            let capitalised = word.first?.isUppercase == true
            if word.contains(where: \.isNumber) || (!isWord(lower) && (capitalised || !hasCorrection(lower))) { add(word) }
        }
        return Array(terms.prefix(maxTerms))
    }

    /// Whether text mentions any of the terms.
    public static func mentions(_ text: String, _ terms: [String]) -> Bool {
        let lower = text.lowercased()
        return terms.contains { lower.contains($0) }
    }
}
