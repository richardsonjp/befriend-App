//
//  MessageCheck.swift
//  PetCore
//
//  The chat's guardrail (M22): is a message something to answer, or keyboard noise like "asd"? An instant check on
//  this device first (known words, keyboard runs, repeats); only borderline messages ask the model. Gibberish gets a
//  "what do you mean?" instead of a search, a web lookup or an answer.
//

import Foundation
import FoundationModels
import NaturalLanguage
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public nonisolated enum MessageCheck: Equatable, Sendable {
    case valid
    case gibberish
    /// Can't tell from the words alone: ask the model.
    case unsure

    /// Short replies that aren't in a spelling dictionary but mean something.
    static let shortWords: Set<String> = [
        "hi", "hey", "yo", "ok", "okay", "k", "thx", "ty", "lol", "why", "how", "who", "what", "when", "where", "yes", "no",
        "yep", "nope", "sure", "help", "hmm", "wow", "cool", "nice", "thanks", "bye", "hello", "again", "more", "go", "gg",
        "brb", "gtg", "idk", "imo", "imho", "tldr", "tl", "dr", "pls", "plz", "u", "r", "ur", "ya", "yeah", "nah", "omg", "btw",
        "fyi", "asap", "wat", "wut", "doin", "gonna", "wanna", "kinda", "bout",
    ]
    static let keyboardRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890"]

    /// Judges a message from its words. `isWord` says whether a word is in the message language's dictionary.
    public static func judge(_ message: String, isWord: (String) -> Bool = SpellCheck.isWord) -> MessageCheck {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return .gibberish }
        if !WebSearch.links(in: text).isEmpty { return .valid }
        let words = tokens(text)
        guard !words.isEmpty else { return .gibberish }
        // Scripts without spaces or Latin spelling (Chinese, Japanese, Thai…) aren't judged by these rules.
        if words.contains(where: { word in word.unicodeScalars.contains { !$0.isASCII && $0.properties.isAlphabetic } && !latin(word) }) {
            return .valid
        }
        let lowered = words.map { $0.lowercased() }
        if lowered.allSatisfy({ shortWords.contains($0) }) { return .valid }
        let known = zip(words, lowered).filter { word, lower in
            shortWords.contains(lower) || word.contains(where: \.isNumber) || (word.first?.isUppercase == true && word.count > 1)
                || (lower.count > 1 && !mashed(lower) && isWord(lower))
        }.count
        let share = Double(known) / Double(words.count)
        if share >= 0.5 { return .valid }
        if known == 0, words.count <= 3 || lowered.allSatisfy(mashed) { return .gibberish }
        return share == 0 && lowered.filter(mashed).count * 2 >= words.count ? .gibberish : .unsure
    }

    static func tokens(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
    }

    private static func latin(_ word: String) -> Bool {
        word.unicodeScalars.allSatisfy { $0.isASCII || ("\u{00C0}"..."\u{024F}").contains($0) }
    }

    /// Keyboard mashing: a run along a keyboard row ("asdf"), one letter over and over ("aaaa"), or a long word with
    /// no vowels ("sdfghj").
    static func mashed(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 3 else { return false }
        if Set(letters).count == 1 { return true }
        if keyboardRows.contains(where: { $0.contains(letters) || String($0.reversed()).contains(letters) }) { return true }
        return letters.count >= 5 && !letters.contains(where: { "aeiouy".contains($0) })
    }

    // MARK: Borderline: ask the model

    /// Tried on the real model: named examples and a true/false field got 10 of 10 borderline cases right.
    static let modelInstructions = """
        You decide whether a chat message is meaningful: something a friend could understand and reply to, in any \
        language, including slang, typos and abbreviations ("wat r u doin", "brb", "thx"). Random letters and \
        keyboard mashing ("dfg kjh", "asdkj qwe") and placeholder text ("lorem ipsum") are not meaningful.
        """

    /// The model's verdict on a borderline message. If it can't answer, the message goes through.
    public static func askModel(_ message: String, model: SystemLanguageModel = .default) async -> Bool {
        guard model.isAvailable else { return true }
        let session = LanguageModelSession(model: model, instructions: modelInstructions)
        let root = DynamicGenerationSchema(name: "Verdict", description: "Whether the message is meaningful", properties: [
            .init(name: "meaningful", description: "true if a friend could understand and reply to it",
                  schema: DynamicGenerationSchema(type: Bool.self)),
        ])
        guard let schema = try? GenerationSchema(root: root, dependencies: []),
              let reply = try? await session.respond(to: "Message: \"\(PetBrain.quote(message, 300))\"", schema: schema).content,
              let meaningful = try? reply.value(Bool.self, forProperty: "meaningful") else { return true }
        return meaningful
    }

    /// What the friend says to a message it couldn't make sense of.
    static let clarifications = [
        "I'm not sure what you mean. Could you ask that as a full question?",
        "Hmm, I didn't catch that. What would you like to know?",
        "That one lost me. Can you say it another way?",
    ]
}

/// The system spelling dictionaries: a word is real if English or one of the device's languages knows it. (Guessing a
/// lone word's language picks one where nonsense passes, so it isn't guessed.)
public nonisolated enum SpellCheck {
    static var languages: [String] {
        var codes = ["en"]
        for preferred in Locale.preferredLanguages {
            let code = String(preferred.prefix { $0 != "-" && $0 != "_" })
            if !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    /// A misspelling the dictionaries can fix ("webiste" → website): a typo, not a name. Any guess at all isn't
    /// enough: "netmonk" only splits into "net monk", and treated as a typo the product was never looked up.
    public static func hasCorrection(_ word: String) -> Bool {
        guesses(word).contains { isNearMiss(word, of: $0) }
    }

    /// A guess that fixes a slip: the same letters swapped ("teh" → the), one letter off in a word of six or more
    /// ("recive" → receive), or two in a long one. Not a split ("net monk"), not the same word capitalised
    /// ("Kubernetes"), not a short look-alike ("fazz" → fizz).
    static func isNearMiss(_ word: String, of guess: String) -> Bool {
        let a = word.lowercased(), b = guess.lowercased()
        guard a != b, !b.contains(" "), !b.contains("-") else { return false }
        if a.sorted() == b.sorted() { return true }
        let distance = editDistance(a, b)
        return (distance == 1 && a.count >= 6) || (distance == 2 && a.count >= 8)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return x.isEmpty ? y.count : previous[y.count]
    }

    private static func guesses(_ word: String) -> [String] {
        let codes = languages
        #if os(macOS)
        return MainActorBox.run {
            let checker = NSSpellChecker.shared
            let range = NSRange(location: 0, length: (word as NSString).length)
            return codes.compactMap { code in checker.availableLanguages.first { $0.hasPrefix(code) } }.flatMap { language in
                checker.guesses(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0) ?? []
            }
        }
        #else
        return MainActorBox.run {
            let range = NSRange(location: 0, length: (word as NSString).length)
            return codes.compactMap { code in UITextChecker.availableLanguages.first { $0.hasPrefix(code) } }.flatMap { language in
                UITextChecker().guesses(forWordRange: range, in: word, language: language) ?? []
            }
        }
        #endif
    }

    public static func isWord(_ word: String) -> Bool {
        let codes = languages
        #if os(macOS)
        return MainActorBox.run {
            let checker = NSSpellChecker.shared
            let available = codes.compactMap { code in checker.availableLanguages.first { $0.hasPrefix(code) } }
            return available.contains { language in
                checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
        }
        #else
        return MainActorBox.run {
            let available = codes.compactMap { code in UITextChecker.availableLanguages.first { $0.hasPrefix(code) } }
            let range = NSRange(location: 0, length: (word as NSString).length)
            return available.contains { language in
                UITextChecker().rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language).location == NSNotFound
            }
        }
        #endif
    }
}

/// The spell checkers are main-thread APIs; the check itself is instant.
private nonisolated enum MainActorBox {
    static func run<T: Sendable>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(work) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }
}
