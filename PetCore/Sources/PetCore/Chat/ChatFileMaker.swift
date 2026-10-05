//
//  ChatFileMaker.swift
//  PetCore
//
//  Asks the on-device model for a file's content (M25). Tables, records and events come back as typed structures
//  that ChatFileWriter turns into valid CSV, JSON and iCalendar; documents come back as Markdown for .md, .txt and
//  .pdf. Each file is one fresh session, so the chat's own context stays untouched.
//

import Foundation
import FoundationModels

/// A file the friend made, kept in the reply that brought it (and synced with the conversation).
public nonisolated struct ChatFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let format: ChatFileFormat
    public let data: Data

    public init(id: UUID = UUID(), name: String, format: ChatFileFormat, data: Data) {
        self.id = id
        self.name = name
        self.format = format
        self.data = data
    }

    /// A copy on disk to preview, share or save.
    public func temporaryURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "chat-files/\(id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
        return url
    }
}

public nonisolated enum ChatFileMaker {
    public enum Failure: LocalizedError {
        case nothing, unavailable

        public var errorDescription: String? {
            switch self {
            case .nothing: "I couldn't make that file from what I have. Try saying what should go in it."
            case .unavailable: "Apple Intelligence is needed to make files."
            }
        }
    }

    static let documentInstructions = """
        You write clean, well-organised documents in Markdown: a # title, short sections with ## headings, bullet \
        lists, and Markdown tables where they help. Use only the material given and the request; don't invent facts. \
        Write only the document, with no introduction or closing remarks, and never mention the material, passages, \
        files or web pages it came from.
        """

    /// Skills that answer in the chat: neutral, clean Markdown.
    public static let skillInstructions = """
        You help with a task and write the result in clean Markdown. Use only the material given and the request; \
        don't invent facts. Write only the result, with no introduction or closing remarks.
        """

    static let tableInstructions = """
        You turn material into a tidy table. Pick clear column names, one row per item, one value per cell, the same \
        columns in every row. Use only the material given and the request; don't invent facts.
        """

    static let eventInstructions = """
        You turn material into calendar events. Use real dates (YYYY-MM-DD) and 24-hour times (HH:mm), worked out \
        from today's date when the material says "tomorrow" or "next Monday". Use only the material and the request.
        """

    /// `instructions` adds a skill's own rules; `material` is the conversation and file passages to draw on.
    public static func make(_ format: ChatFileFormat, request: String, material: String, instructions extra: String? = nil,
                            columns: [String]? = nil, now: Date = .now, brain: Brain = .onDevice) async throws -> ChatFile {
        if case .apple(let model) = brain, !model.isAvailable { throw Failure.unavailable }
        // The small model gets "next Monday" wrong on its own: it gets a table of the coming days to read from.
        // The small model can't do date arithmetic: dates are worked out here and written in beside their words.
        let material = annotateDates(material, now: now), request = annotateDates(request, now: now)
        // Today's date only where dates matter (in a table it turns into rows about today).
        let dated = format == .ics || format == .md || format == .txt || format == .pdf || format == .html
        let prompt = (material.isEmpty ? "" : "Material:\n\(material)\n\n") + "Request: \(request)" + (dated ? "\n\n" + calendarNote(now) : "")
        switch format {
        case .md, .txt, .pdf, .html:
            let drawing = format != .txt && DiagramIntent.mentions(request)
            let rules = [extra, drawing ? "Don't draw diagrams, charts or ASCII art: the app adds the diagram after your text." : nil]
                .compactMap { $0 }.joined(separator: "\n\n")
            var markdown = try await respond(documentInstructions, rules.isEmpty ? nil : rules, prompt, brain: brain)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.nothing }
            let title = Self.title(of: markdown) ?? String(request.prefix(40))
            // "…with a flowchart": drawn from the same material and added at the end (not in plain text).
            if drawing {
                let kind = DiagramIntent.kind(request)
                if let diagram = try? await DiagramMaker.make(kind, request: request, material: material, brain: brain) {
                    markdown = placing(diagram, in: markdown)
                }
            }
            let data = switch format {
            case .md: ChatFileWriter.markdown(markdown)
            case .txt: ChatFileWriter.text(markdown)
            default: await ChatFileWriter.document(markdown, title: title, format: format)
            }
            return ChatFile(name: fileName(title, format), format: format, data: data)
        case .csv, .json:
            let (title, table) = try await makeTable(prompt, extra, columns: columns, brain: brain)
            let data = format == .csv ? ChatFileWriter.csv(table) : try ChatFileWriter.json(table)
            return ChatFile(name: fileName(title, format), format: format, data: data)
        case .ics:
            let (title, events) = try await makeEvents(prompt, extra, now: now, brain: brain)
            return ChatFile(name: fileName(title, .ics), format: .ics, data: ChatFileWriter.ics(events, calendarName: title, now: now))
        }
    }

    /// The diagram under the document's own heading for it ("## Flowchart"), replacing whatever the model put
    /// there ("[Image of flowchart]", ASCII boxes); otherwise in a section of its own at the end.
    static func placing(_ diagram: ChatDiagram, in markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let words = #"(?i)^#{1,4}\s.*\b(diagram|flow ?chart|mind ?map|timeline|gantt|pie chart|sequence|chart)\b"#
        guard let heading = lines.firstIndex(where: { $0.range(of: words, options: .regularExpression) != nil }) else {
            return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## \(diagram.kind.title)\n\n" + diagram.markdown + "\n"
        }
        let end = lines[(heading + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
        lines.replaceSubrange((heading + 1)..<end, with: ["", diagram.markdown, ""])
        return lines.joined(separator: "\n")
    }

    /// Documents stop at this many tokens, so material and writing fit the 4K window together.
    static let documentTokens = 1400

    private static func respond(_ base: String, _ extra: String?, _ prompt: String, brain: Brain) async throws -> String {
        try await brain.respond(instructions: base + (extra.map { "\n\n" + $0 } ?? ""), prompt: prompt, maxTokens: documentTokens)
    }

    // MARK: Tables

    /// With `fixed` columns (a skill's), every row must have exactly those cells.
    static func makeTable(_ prompt: String, _ extra: String?, columns fixed: [String]?, brain: Brain) async throws -> (String, ChatTable) {
        let cell = DynamicGenerationSchema(type: String.self)
        let row = fixed.map { DynamicGenerationSchema(arrayOf: cell, minimumElements: $0.count, maximumElements: $0.count) }
            ?? DynamicGenerationSchema(arrayOf: cell)
        var properties: [DynamicGenerationSchema.Property] = [
            .init(name: "title", description: "A short name for the table", schema: DynamicGenerationSchema(type: String.self)),
        ]
        if fixed == nil {
            properties.append(.init(name: "columns", description: "Column names",
                                    schema: DynamicGenerationSchema(arrayOf: cell, minimumElements: 1, maximumElements: 10)))
        }
        properties.append(.init(name: "rows", description: fixed.map { "One row per item: " + $0.joined(separator: ", ") }
                                    ?? "One row per item, with a value for every column",
                                schema: DynamicGenerationSchema(arrayOf: row, minimumElements: 1, maximumElements: 60)))
        let root = DynamicGenerationSchema(name: "Table", description: "A table", properties: properties)
        let content = try await brain.respond(instructions: tableInstructions + (extra.map { "\n\n" + $0 } ?? ""), prompt: prompt,
                                              schema: try GenerationSchema(root: root, dependencies: []))
        let columns = try fixed ?? content.value([String].self, forProperty: "columns").map { $0.trimmingCharacters(in: .whitespaces) }
        let rows = try content.value([[String]].self, forProperty: "rows").filter { !$0.allSatisfy(\.isEmpty) }
        guard !columns.isEmpty, !rows.isEmpty else { throw Failure.nothing }
        return (try content.value(String.self, forProperty: "title"), ChatTable(columns: columns, rows: rows))
    }

    // MARK: Events

    static func makeEvents(_ prompt: String, _ extra: String?, now: Date, brain: Brain) async throws -> (String, [ChatEvent]) {
        let text = DynamicGenerationSchema(type: String.self)
        let event = DynamicGenerationSchema(name: "Event", description: "A calendar event", properties: [
            .init(name: "title", description: "What it is", schema: text),
            .init(name: "date", description: "YYYY-MM-DD", schema: text),
            .init(name: "start", description: "HH:mm in 24-hour time, or empty for an all-day event", schema: text),
            .init(name: "durationMinutes", description: "How long it lasts in minutes (60 if unknown)", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "location", description: "Where, or empty", schema: text),
            .init(name: "notes", description: "Details, or empty", schema: text),
        ])
        let root = DynamicGenerationSchema(name: "Calendar", description: "Events for a calendar", properties: [
            .init(name: "title", description: "A short name for this set of events", schema: text),
            .init(name: "events", description: "The events", schema: DynamicGenerationSchema(arrayOf: event, minimumElements: 1, maximumElements: 30)),
        ])
        let content = try await brain.respond(instructions: eventInstructions + (extra.map { "\n\n" + $0 } ?? ""), prompt: prompt,
                                              schema: try GenerationSchema(root: root, dependencies: []))
        let items = try content.value([GeneratedContent].self, forProperty: "events")
        let events = items.compactMap { item -> ChatEvent? in
            guard let title = try? item.value(String.self, forProperty: "title"), !title.isEmpty,
                  let date = try? item.value(String.self, forProperty: "date") else { return nil }
            let start = (try? item.value(String.self, forProperty: "start")) ?? ""
            let given = (try? item.value(Int.self, forProperty: "durationMinutes")) ?? 0
            let minutes = given < 15 ? 60 : min(given, 24 * 60) // "0" or "5" means the model didn't know
            return Self.event(title: title, date: rolledForward(date, now: now), start: start, minutes: minutes,
                         location: try? item.value(String.self, forProperty: "location"), notes: try? item.value(String.self, forProperty: "notes"))
        }
        guard !events.isEmpty else { throw Failure.nothing }
        return (try content.value(String.self, forProperty: "title"), events)
    }

    /// Local time from the model's date and time strings; nil when the date doesn't parse.
    static func event(title: String, date: String, start: String, minutes: Int, location: String?, notes: String?) -> ChatEvent? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let time = start.trimmingCharacters(in: .whitespaces)
        formatter.dateFormat = time.isEmpty ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        guard let begin = formatter.date(from: time.isEmpty ? date : "\(date) \(time)") else { return nil }
        let allDay = time.isEmpty
        let end = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: begin)! : begin.addingTimeInterval(Double(minutes) * 60)
        return ChatEvent(title: title, start: begin, end: end, allDay: allDay,
                         location: location.flatMap { $0.isEmpty ? nil : $0 }, notes: notes.flatMap { $0.isEmpty ? nil : $0 })
    }

    static func calendarNote(_ now: Date) -> String {
        let weekday = now.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_US")))
        return "Today is \(weekday), \(isoDay(now)). Dates in [brackets] are already worked out: use them as written."
    }

    /// "May 3rd at 10:00" → "May 3rd at 10:00 [2027-05-03 10:00]", "next Monday" → "next Monday [2026-10-05]": Apple's
    /// date detector resolves them (relative to `now`); a year-less date already past means next year's.
    static func annotateDates(_ text: String, now: Date) -> String {
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return text }
        var result = text
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let date = match.date, let range = Range(match.range, in: text) else { continue }
            let words = text[range]
            let timed = words.range(of: #"\d:\d|\d\s*(am|pm|a\.m\.|p\.m\.)|noon|midnight"#, options: [.regularExpression, .caseInsensitive]) != nil
            let named = words.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression) != nil
            var resolved = date
            if !named, let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now), resolved < yesterday,
               let next = Calendar.current.date(byAdding: .year, value: 1, to: resolved) {
                resolved = next
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = timed ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
            result.insert(contentsOf: " [\(formatter.string(from: resolved))]", at: result.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: range.upperBound)))
        }
        return result
    }

    /// A date without a year the model placed in the past ("May 3rd" in October) means the next one.
    static func rolledForward(_ date: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: date), let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now),
              day < yesterday, let next = Calendar.current.date(byAdding: .year, value: 1, to: day), next > yesterday else { return date }
        return formatter.string(from: next)
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: Names

    static func title(of markdown: String) -> String? {
        // The first heading, whatever its level: the small model often starts at "##".
        markdown.split(whereSeparator: \.isNewline).first { $0.range(of: #"^#{1,6} "#, options: .regularExpression) != nil }
            .map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
    }

    /// "Launch budget.csv": the title, safe for any file system, not too long.
    static func fileName(_ title: String, _ format: ChatFileFormat) -> String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\\\:*?\"<>|\n\r\t")).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let base = safe.isEmpty ? "befriend" : String(safe.prefix(60)).trimmingCharacters(in: .whitespaces)
        return base + "." + format.rawValue
    }
}
