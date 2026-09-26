//
//  Harvester.swift
//  Harvest
//
//  Answers the prompts from `apiserver harvest inputs` with Apple's on-device model, so befriend's own model can
//  be distilled from it. Runs for hours; everything here is built around being interrupted and resumed.
//

import Foundation
import FoundationModels
import PetCore

// MARK: - The files

/// The first line of inputs.jsonl. Only `count` is used here: the system message in it is what the *student*
/// will be trained against, not what the teacher is told (see `Harvester.instructions`).
struct InputHeader: Decodable {
    let count: Int
}

/// One synthetic user and the seven calls that make its personality.
struct InputRecord: Decodable {
    let id: String
    /// The skin this friend wears; absent in inputs written before skins varied (the built-in one).
    let skin: HarvestSkin?
    let calls: [InputCall]
}

/// A skin as `harvest inputs` writes it: its moods in order, and the actions drawn for each.
struct HarvestSkin: Decodable {
    let moods: [String]
    let actions: [String: [String]]

    static let builtIn = HarvestSkin(
        moods: PetMood.builtIn.map(\.rawValue),
        actions: Dictionary(uniqueKeysWithValues: PetMood.builtIn.map { ($0.rawValue, PetAction.builtIn.map(\.rawValue)) })
    )

    /// Every action in some mood, in first-seen order.
    var allActions: [String] {
        var all: [String] = []
        for mood in moods {
            for action in actions[mood] ?? [] where !all.contains(action) {
                all.append(action)
            }
        }
        return all
    }
}

struct InputCall: Decodable {
    let kind: String
    let trigger: String?
    let user: String
}

/// One answered call, appended to outputs.jsonl. Identical in shape to what a llama.cpp-served model would
/// produce, so `harvest filter` never needs to know which of them wrote it.
struct OutputLine: Codable {
    let id: String
    let kind: String
    let trigger: String?
    let output: String
}

// MARK: - What the model is asked to produce

/// Guided generation rather than free text: the on-device model can't be given a grammar, and a malformed row
/// costs a whole generation. The rows are assembled here instead, from a shape the model can't get wrong.
@Generable
nonisolated struct GeneratedProfile {
    @Guide(description: "One or two sentences describing the friend, 20 to 200 characters")
    var summary: String

    @Guide(description: "Single-word character traits of the friend, like \"nosy\" or \"patient\". At most 24 characters each", .count(4))
    var traits: [String]

    @Guide(description: "How the friend talks, described rather than demonstrated: tone, rhythm, habits. Not a line of dialogue. 20 to 160 characters")
    var voice: String

    @Guide(description: "Guidance spoken to the friend itself, starting \"You are <friend name>.\" Tell it what to call the user. Describe how to behave; never repeat the user's answers back as facts about the friend, since the answers describe the user, not the friend. Second person throughout. 40 to 600 characters")
    var instructions: String
}

/// One line of a chunk, generated under a schema built from the friend's skin (moods and actions vary per skin).
nonisolated struct GeneratedLine {
    let action: String
    let text: String
}

nonisolated struct GeneratedMood {
    let mood: String
    let lines: [GeneratedLine]
}

nonisolated enum ChunkSchema {
    /// One property per mood of the skin, each exactly two lines, so the model can't skip or repeat a mood; actions
    /// are the skin's, and Rows keeps each mood to its own.
    static func make(for skin: HarvestSkin) throws -> GenerationSchema {
        let line = DynamicGenerationSchema(name: "Line", properties: [
            .init(name: "action", description: "The animation the friend plays",
                  schema: DynamicGenerationSchema(name: "Action", anyOf: skin.allActions)),
            .init(name: "text", description: "One short thing the friend says at this exact moment, at most 80 characters",
                  schema: DynamicGenerationSchema(type: String.self)),
        ])
        let moods = skin.moods.map { mood in
            DynamicGenerationSchema.Property(
                name: mood, description: "What the friend says when it feels \(mood.replacingOccurrences(of: "_", with: " "))",
                schema: DynamicGenerationSchema(arrayOf: line, minimumElements: 2, maximumElements: 2)
            )
        }
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Chunk", properties: moods), dependencies: [])
    }

    static func parse(_ content: GeneratedContent, skin: HarvestSkin) throws -> [GeneratedMood] {
        try skin.moods.map { mood in
            GeneratedMood(mood: mood, lines: try content.value([GeneratedContent].self, forProperty: mood).map {
                GeneratedLine(action: try $0.value(String.self, forProperty: "action"),
                              text: try $0.value(String.self, forProperty: "text"))
            })
        }
    }
}

// MARK: - Rows

/// The compact format from backend/pkg/phrasetable. Assembled here rather than generated, so the only thing the
/// model decides is the words. `harvest filter` re-parses this with the real decoder, which is the drift check.
nonisolated enum Rows {
    static let maxTextLength = 80
    static let separator = "|"

    static func profile(_ p: GeneratedProfile) -> String? {
        let traits = p.traits.map { clean($0, max: 24) }.filter { !$0.isEmpty && !$0.contains(",") }
        guard traits.count >= 3 else { return nil }
        let rows = [
            "summary" + separator + clean(p.summary, max: 200),
            "traits" + separator + traits.prefix(5).joined(separator: ","),
            "voice" + separator + clean(p.voice, max: 160),
            "instructions" + separator + clean(p.instructions, max: 600),
        ]
        return rows.contains(where: { $0.hasSuffix(separator) }) ? nil : rows.joined(separator: "\n") + "\n"
    }

    /// Every mood must be present exactly once; a chunk missing one would fail the backend's decoder anyway, and
    /// failing here means it is simply retried on the next run.
    /// An action the skin didn't draw for a mood becomes idle, as the production validator does.
    static func chunk(_ moods: [GeneratedMood], skin: HarvestSkin) -> String? {
        var byMood: [String: [GeneratedLine]] = [:]
        for entry in moods where byMood[entry.mood] == nil {
            byMood[entry.mood] = entry.lines
        }
        var out = ""
        for mood in skin.moods {
            let allowed = skin.actions[mood] ?? []
            let lines = (byMood[mood] ?? [])
                .map { GeneratedLine(action: allowed.contains($0.action) ? $0.action : "idle", text: clean($0.text, max: maxTextLength)) }
                .filter { $0.text.count >= 4 }
            guard lines.count >= 2 else { return nil }
            out += mood + "\n"
            for line in lines.prefix(3) {
                out += line.action + separator + line.text + "\n"
            }
        }
        return out
    }

    /// Collapses whitespace, drops the separator, and trims to length at a word boundary where it can. This is
    /// formatting, not editing: the words stay the teacher's.
    static func clean(_ text: String, max: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: separator, with: "/")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard flattened.count > max else { return flattened }
        let cut = String(flattened.prefix(max))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > max / 2 {
            return String(cut[cut.startIndex..<space])
        }
        return cut
    }
}

// MARK: - Running

@MainActor
final class Harvester {
    /// What the teacher is told. Deliberately not the student's system message: that one describes the row
    /// format, which guided generation makes irrelevant here. Only the content needs to match.
    static let instructions = """
        You create the personality of a small animated companion called a "friend" that lives on the user's \
        Mac and iPhone.
        Write in English. Make the friend warm, playful and specific to this user; never generic, never mean.
        Never say or imply the friend is an AI, a bot, a program or a language model.
        Keep everything the friend says short: at most 80 characters, one sentence.
        Every line must belong to the moment being asked about; a line that would fit any other moment is wrong.
        Name the user in only a line or two, not in every line.
        Use {app} only for lines about switching apps; it is replaced by the app's name. No other placeholders.
        """

    private let model = SystemLanguageModel.default
    private let outputs: FileHandle
    private var done: Set<String>
    private var written = 0
    private var failed = 0

    init(outputsPath: String) throws {
        if !FileManager.default.fileExists(atPath: outputsPath) {
            FileManager.default.createFile(atPath: outputsPath, contents: nil)
        }
        done = try Harvester.alreadyAnswered(at: outputsPath)
        outputs = try FileHandle(forWritingTo: URL(fileURLWithPath: outputsPath))
        try outputs.seekToEnd()
    }

    /// A resumed run must not redo work, so every call already in outputs.jsonl is remembered up front.
    private static func alreadyAnswered(at path: String) throws -> Set<String> {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        var keys: Set<String> = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let answered = try? decoder.decode(OutputLine.self, from: Data(line)) else { continue }
            keys.insert(key(answered.id, answered.kind, answered.trigger))
        }
        return keys
    }

    static func key(_ id: String, _ kind: String, _ trigger: String?) -> String {
        "\(id)|\(kind)|\(trigger ?? "")"
    }

    func checkAvailability() -> String? {
        switch model.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "this Mac can't run Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off in System Settings"
        case .unavailable(.modelNotReady): "the model is still downloading"
        case .unavailable(let other): "unavailable: \(other)"
        }
    }

    func isDone(_ id: String, _ call: InputCall) -> Bool {
        done.contains(Self.key(id, call.kind, call.trigger))
    }

    /// Answers one call. Returns false when nothing was written, so the caller can pace itself; a skipped call is
    /// simply picked up by the next run.
    func answer(id: String, skin: HarvestSkin, call: InputCall) async -> Bool {
        // A fresh session per call: byte-identical instructions and an empty transcript, so the 4K window never
        // fills with earlier users and the model can't parrot the last friend it wrote.
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        do {
            let rows: String? = if call.kind == "profile" {
                Rows.profile(try await session.respond(to: call.user, generating: GeneratedProfile.self).content)
            } else {
                Rows.chunk(try ChunkSchema.parse(try await session.respond(to: call.user, schema: try ChunkSchema.make(for: skin)).content, skin: skin), skin: skin)
            }
            guard let rows else {
                failed += 1
                FileHandle.standardError.write(Data("  \(id) \(call.trigger ?? call.kind): incomplete, will retry\n".utf8))
                return false
            }
            try write(OutputLine(id: id, kind: call.kind, trigger: call.trigger, output: rows))
            written += 1
            return true
        } catch {
            failed += 1
            FileHandle.standardError.write(Data("  \(id) \(call.trigger ?? call.kind): \(error)\n".utf8))
            return false
        }
    }

    /// Flushed per line: an interrupted run loses at most the call in flight.
    private func write(_ line: OutputLine) throws {
        var data = try JSONEncoder().encode(line)
        data.append(UInt8(ascii: "\n"))
        try outputs.write(contentsOf: data)
        try outputs.synchronize()
        done.insert(Self.key(line.id, line.kind, line.trigger))
    }

    var tally: (written: Int, failed: Int) { (written, failed) }
}
