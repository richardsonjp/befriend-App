//
//  MarkdownBlocks.swift
//  PetCore
//
//  Splits the model's Markdown into blocks the chat can draw: headings, paragraphs, list items, quotes, code (with
//  its language: bash, html, mermaid, …) and tables. Foundation's own parser does the work; inline styling (bold,
//  italic, `code`, links) stays on the AttributedString for SwiftUI's Text.
//

import Foundation

public nonisolated struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(Int)
        /// `marker` is "•", "3." or "" for a list item's second paragraph.
        case listItem(depth: Int, marker: String)
        case quote
        case code(language: String?)
        case table(rows: [[AttributedString]])
    }

    public let id: Int
    public let kind: Kind
    public var text: AttributedString

    /// The raw text of a code block.
    public var plain: String { String(text.characters).trimmingCharacters(in: .newlines) }

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }
        var builder = Builder()
        for run in parsed.runs {
            builder.add(AttributedString(parsed[run.range]), intent: run.presentationIntent)
        }
        return builder.blocksFlushed
    }

    private struct Builder {
        var blocks: [MarkdownBlock] = []
        private var lastKey: Int?
        private var lastListItem: Int?
        private var table: (id: Int, rows: [Int], cells: [Int: [Int: AttributedString]])?

        mutating func add(_ piece: AttributedString, intent: PresentationIntent?) {
            let components = intent?.components ?? []
            if let tableComponent = components.first(where: { if case .table = $0.kind { true } else { false } }) {
                return addCell(piece, components: components, table: tableComponent.identity)
            }
            flushTable()
            let key = components.first?.identity ?? -1
            if key == lastKey, !blocks.isEmpty {
                blocks[blocks.count - 1].text += piece
                return
            }
            lastKey = key
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind(of: components), text: piece))
        }

        private mutating func kind(of components: [PresentationIntent.IntentType]) -> Kind {
            for component in components {
                switch component.kind {
                case .codeBlock(let language): return .code(language: language.flatMap { $0.isEmpty ? nil : $0.lowercased() })
                case .header(let level): return .heading(level)
                case .listItem(let ordinal):
                    let depth = components.filter { [.orderedList, .unorderedList].contains($0.kind) }.count
                    let ordered = components.first { [.orderedList, .unorderedList].contains($0.kind) }?.kind == .orderedList
                    let continued = lastListItem == component.identity
                    lastListItem = component.identity
                    return .listItem(depth: max(1, depth), marker: continued ? "" : (ordered ? "\(ordinal)." : "•"))
                case .blockQuote: return .quote
                default: continue
                }
            }
            return .paragraph
        }

        private mutating func addCell(_ piece: AttributedString, components: [PresentationIntent.IntentType], table id: Int) {
            if table?.id != id { flushTable(); table = (id, [], [:]) }
            lastKey = nil
            var row = -1, column = 0
            for component in components {
                switch component.kind {
                case .tableCell(let index): column = index
                case .tableHeaderRow, .tableRow: row = component.identity
                default: break
                }
            }
            if table?.rows.contains(row) == false { table?.rows.append(row) }
            table?.cells[row, default: [:]][column, default: AttributedString()] += piece
        }

        private mutating func flushTable() {
            guard let table else { return }
            self.table = nil
            let width = (table.cells.values.flatMap(\.keys).max() ?? 0) + 1
            let rows = table.rows.map { row in (0..<width).map { table.cells[row]?[$0] ?? AttributedString() } }
            blocks.append(MarkdownBlock(id: blocks.count, kind: .table(rows: rows), text: AttributedString()))
        }

        var blocksFlushed: [MarkdownBlock] {
            var copy = self
            copy.flushTable()
            return copy.blocks
        }
    }
}
