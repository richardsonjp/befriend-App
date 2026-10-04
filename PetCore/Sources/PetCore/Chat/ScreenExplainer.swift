//
//  ScreenExplainer.swift
//  PetCore
//
//  Explains a captured part of the screen (M31). Vision reads the text in it and a few labels for what it shows
//  (Ingest), the model decides what kind of thing it is (an error, code, a chart…), and the explanation takes the
//  shape that fits: an error gets its cause and fix, a chart its takeaway. All on this device.
//

import Foundation
import FoundationModels

public nonisolated enum ScreenExplainer {
    @Generable
    public enum Kind: String, CaseIterable, Sendable {
        case error, code, chart, ui, text, picture
    }

    @Generable
    public struct Glance: Sendable {
        @Guide(description: "What kind of thing the screenshot mainly shows: an error message, code, a chart or table, an app screen or settings, text to read, or a picture")
        public var kind: Kind
        @Guide(description: "What this is, in at most 10 words, like \"A Python TypeError on line 42\" or \"macOS Wi-Fi settings\"")
        public var what: String
    }

    public enum Failure: LocalizedError {
        case nothingFound
        public var errorDescription: String? {
            "I couldn't make out anything in that part of the screen. Try a bigger box around it?"
        }
    }

    /// Characters of read text the prompts carry, leaving the 4K context room for the instructions and the answer.
    static let readBudget = 6_000

    static let instructions = """
        You explain a part of the user's screen they captured. You can't see it: you get the text read from it and a \
        few labels for what it shows. Explain only from that; if something is unclear, say what you'd need. Plain, \
        friendly English, short paragraphs and lists, **bold** section labels, no headings. Under 200 words.
        """

    /// The sections an explanation of this kind has.
    static func shape(for kind: Kind) -> String {
        switch kind {
        case .error: "**What happened**, **Likely cause**, **How to fix**"
        case .code: "**What it does**, then **Key lines** (the few lines that matter, each with what it does)"
        case .chart: "**Takeaway** (the one thing it shows), then **Notable numbers**"
        case .ui: "**What this does** (the screen or setting), then **The options** (what each one means)"
        case .text: "**Summary**, then **Terms explained** (only the hard words, if any)"
        case .picture: "**What it shows**, then **Worth noticing**"
        }
    }

    /// The text and labels Vision reads from the screenshot.
    public static func read(_ png: Data) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: "screenshot-\(UUID().uuidString).png")
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let read = try await Ingest.describe(file)
        guard !read.isEmpty else { throw Failure.nothingFound }
        // ponytail: keeps the start of the text (Vision reads top to bottom); rank lines by size if long screens suffer.
        return String(read.prefix(readBudget))
    }

    public static func glance(_ read: String, model: SystemLanguageModel) async throws -> Glance {
        let session = LanguageModelSession(model: model)
        return try await session.respond(to: "What is this part of a screen?\n\n\(read)", generating: Glance.self).content
    }

    /// The chat's title for it: "Screenshot · A Python TypeError on line 42".
    public static func title(_ what: String) -> String {
        let what = what.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        return what.isEmpty ? "Screenshot" : "Screenshot · " + what
    }

    static func prompt(_ glance: Glance, read: String) -> String {
        """
        This is \(glance.what). Start with one line saying what it is, then these sections: \(shape(for: glance.kind)).

        Read from the screenshot:
        \(read)
        """
    }
}
