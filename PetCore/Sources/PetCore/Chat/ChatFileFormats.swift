//
//  ChatFileFormats.swift
//  PetCore
//
//  Writing chat files well (M25). The model fills a typed structure and these write the file, so the format is
//  always valid: CSV per RFC 4180, JSON with real numbers and booleans, iCalendar per RFC 5545, and PDF pages laid
//  out from Markdown. Markdown and plain text come from the model and are tidied here.
//

import CoreText
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public nonisolated enum ChatFileFormat: String, Codable, CaseIterable, Sendable {
    case md, txt, csv, json, ics, pdf, html

    public var title: String {
        switch self {
        case .md: "Markdown"
        case .txt: "Text"
        case .csv: "CSV"
        case .json: "JSON"
        case .ics: "Calendar"
        case .pdf: "PDF"
        case .html: "HTML"
        }
    }

    public var symbol: String {
        switch self {
        case .md: "doc.richtext"
        case .txt: "doc.plaintext"
        case .csv: "tablecells"
        case .json: "curlybraces"
        case .ics: "calendar"
        case .pdf: "doc.text"
        case .html: "chevron.left.forwardslash.chevron.right"
        }
    }

    public var mimeType: String {
        switch self {
        case .md: "text/markdown"
        case .txt: "text/plain"
        case .csv: "text/csv"
        case .json: "application/json"
        case .ics: "text/calendar"
        case .pdf: "application/pdf"
        case .html: "text/html"
        }
    }
}

/// A table the model filled: a header row and rows of cells.
public nonisolated struct ChatTable: Equatable, Sendable {
    public let columns: [String]
    public let rows: [[String]]

    /// Every row as wide as the header: short rows padded, long ones cut.
    public var normalized: ChatTable {
        let width = columns.count
        return ChatTable(columns: columns, rows: rows.map { Array(($0 + Array(repeating: "", count: max(0, width - $0.count))).prefix(width)) })
    }
}

/// A calendar event the model filled; times are this device's local time.
public nonisolated struct ChatEvent: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let location: String?
    public let notes: String?
}

public nonisolated enum ChatFileWriter {
    // MARK: CSV

    /// RFC 4180: comma-separated, CRLF lines, fields with commas, quotes or line breaks quoted, quotes doubled.
    public static func csv(_ table: ChatTable) -> Data {
        let table = table.normalized
        func field(_ value: String) -> String {
            let needsQuotes = value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" } || value.hasPrefix(" ") || value.hasSuffix(" ")
            return needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        let lines = ([table.columns] + table.rows).map { $0.map(field).joined(separator: ",") }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    // MARK: JSON

    /// An array of objects, one per row, keyed by the columns; numbers, booleans and empty cells get their JSON types.
    public static func json(_ table: ChatTable) throws -> Data {
        let table = table.normalized
        let keys = uniqueKeys(table.columns)
        let objects: [[String: Any]] = table.rows.map { row in
            Dictionary(uniqueKeysWithValues: zip(keys, row.map(typed)))
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func typed(_ cell: String) -> Any {
        let value = cell.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return NSNull() }
        switch value.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: break
        }
        // Plain numbers, and "4,500" with thousands commas; "007" and "+62…" stay text, where leading characters matter.
        let digits = value.range(of: #"^-?[1-9]\d{0,2}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil
            ? value.replacingOccurrences(of: ",", with: "") : value
        if digits.range(of: #"^-?(0|[1-9]\d*)(\.\d+)?$"#, options: .regularExpression) != nil {
            return digits.contains(".") ? (Double(digits) ?? value) as Any : (Int(digits) ?? Double(digits) ?? value) as Any
        }
        return value
    }

    /// camelCase keys from the column names, never two alike.
    static func uniqueKeys(_ columns: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return columns.enumerated().map { index, column in
            let words = column.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            var key = words.enumerated().map { $0 == 0 ? $1.lowercased() : $1.prefix(1).uppercased() + $1.dropFirst().lowercased() }.joined()
            if key.isEmpty { key = "field\(index + 1)" }
            seen[key, default: 0] += 1
            return seen[key]! > 1 ? "\(key)\(seen[key]!)" : key
        }
    }

    // MARK: iCalendar

    /// RFC 5545: CRLF lines folded at 75 bytes, text escaped, times in UTC, a stable UID per event.
    public static func ics(_ events: [ChatEvent], calendarName: String, now: Date = .now) -> Data {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//befriend//Chat//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
                     "X-WR-CALNAME:" + escape(calendarName)]
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(UUID().uuidString)@befriend")
            lines.append("DTSTAMP:" + utc(now))
            if event.allDay {
                lines.append("DTSTART;VALUE=DATE:" + day(event.start))
                lines.append("DTEND;VALUE=DATE:" + day(max(event.end, Calendar.current.date(byAdding: .day, value: 1, to: event.start)!)))
            } else {
                lines.append("DTSTART:" + utc(event.start))
                lines.append("DTEND:" + utc(max(event.end, event.start.addingTimeInterval(60))))
            }
            lines.append("SUMMARY:" + escape(event.title))
            if let location = event.location, !location.isEmpty { lines.append("LOCATION:" + escape(location)) }
            if let notes = event.notes, !notes.isEmpty { lines.append("DESCRIPTION:" + escape(notes)) }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return Data((lines.map(fold).joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Lines longer than 75 bytes continue on the next line after a space, never splitting a character.
    static func fold(_ line: String) -> String {
        var parts: [String] = []
        var current = ""
        var bytes = 0
        for character in line {
            let size = String(character).utf8.count
            let limit = parts.isEmpty ? 75 : 74
            if bytes + size > limit {
                parts.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        parts.append(current)
        return parts.joined(separator: "\r\n ")
    }

    private static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    // MARK: Markdown and text

    /// The model's Markdown, tidied: no wrapping ``` fence around the whole thing, no chatter before the title,
    /// one blank line between blocks, a final newline.
    public static func markdown(_ text: String) -> Data {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```"), body.hasSuffix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().dropLast().joined(separator: "\n")
        }
        if let heading = body.range(of: #"(?m)^#{1,3} "#, options: .regularExpression), body[..<heading.lowerBound].count < 120 {
            body = String(body[heading.lowerBound...]) // "Sure! Here's your document:" before the title goes
        }
        // A blank line around every heading, and before a list that follows a paragraph.
        body = body.replacingOccurrences(of: #"(?m)^(#{1,6} .*)$"#, with: "\n$1\n", options: .regularExpression)
        body = body.replacingOccurrences(of: #"(?m)^([^\n\-*#\d|>].*)\n([-*] |\d+\. )"#, with: "$1\n\n$2", options: .regularExpression)
        body = body.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return Data((body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
    }

    /// Plain text: Markdown marks removed (headings, bold, bullets become "-", code fences dropped).
    public static func text(_ markdown: String) -> Data {
        let blocks = MarkdownBlock.parse(String(decoding: self.markdown(markdown), as: UTF8.self))
        let lines = blocks.map { block -> String in
            let text = String(block.text.characters)
            switch block.kind {
            case .heading: return text.uppercased()
            case .listItem(let depth, let marker): return String(repeating: "  ", count: depth - 1) + (marker == "•" ? "- " : marker.isEmpty ? "  " : marker + " ") + text
            case .code: return block.plain
            case .table(let rows): return rows.map { $0.map { String($0.characters) }.joined(separator: "\t") }.joined(separator: "\n")
            default: return text
            }
        }
        return Data((lines.joined(separator: "\n\n") + "\n").utf8)
    }

    // MARK: PDF

    public static let pageSize = CGSize(width: 595, height: 842) // A4 in points
    static let margin: CGFloat = 56

    /// A .pdf or .html of a Markdown document, its diagrams drawn (M29). PDF falls back to plain CoreText pages
    /// if WebKit can't draw it.
    @MainActor
    public static func document(_ markdown: String, title: String, format: ChatFileFormat) async -> Data {
        let tidy = String(decoding: self.markdown(markdown), as: UTF8.self)
        do {
            let output = try await ChatDocumentRenderer.render(tidy, title: title)
            return format == .html ? output.html : output.pdf
        } catch {
            return format == .html ? Data(ChatHTML.page(tidy, title: title).html.utf8) : pdf(markdown, title: title)
        }
    }

    /// Markdown laid out on A4 pages: title and headings in bold, lists indented, code monospaced, tables as rows.
    public static func pdf(_ markdown: String, title: String) -> Data {
        let body = attributed(MarkdownBlock.parse(String(decoding: self.markdown(markdown), as: UTF8.self)))
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title, kCGPDFContextCreator: "befriend"] as CFDictionary)
        else { return Data() }
        let framesetter = CTFramesetterCreateWithAttributedString(body)
        let frame = CGRect(x: margin, y: margin, width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        var start = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: frame, transform: nil)
            let textFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(textFrame, context)
            let visible = CTFrameGetVisibleStringRange(textFrame)
            context.endPDFPage()
            guard visible.length > 0 else { break }
            start += visible.length
        } while start < body.length
        context.closePDF()
        return data as Data
    }

    private static func attributed(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks {
            let text = String(block.text.characters)
            switch block.kind {
            case .heading(let level):
                result.append(line(text, font: font(level == 1 ? 22 : level == 2 ? 17 : 14, bold: true), before: level == 1 ? 0 : 10, after: 6))
            case .listItem(let depth, let marker):
                let indent = CGFloat(depth) * 16
                result.append(line((marker.isEmpty ? "" : marker + "\t") + text, font: font(11), indent: indent, after: 3))
            case .quote:
                result.append(line(text, font: font(11, italic: true), indent: 14, after: 6))
            case .code:
                result.append(line(block.plain, font: monospaced(9.5), indent: 10, after: 8))
            case .table(let rows):
                for (index, row) in rows.enumerated() {
                    result.append(line(row.map { String($0.characters) }.joined(separator: "   |   "),
                                       font: index == 0 ? font(10.5, bold: true) : font(10.5), after: 2))
                }
                result.append(line("", font: font(6), after: 4))
            case .paragraph:
                result.append(line(text, font: font(11), after: 7))
            }
        }
        return result
    }

    private static func line(_ text: String, font: CTFont, indent: CGFloat = 0, before: CGFloat = 0, after: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent + (text.contains("\t") ? 14 : 0)
        style.firstLineHeadIndent = indent
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 14)]
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineSpacing = 2
        return NSAttributedString(string: text + "\n", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            .paragraphStyle: style,
        ])
    }

    private static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    private static func monospaced(_ size: CGFloat) -> CTFont {
        CTFontCreateWithName("Menlo" as CFString, size, nil)
    }
}
