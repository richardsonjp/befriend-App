//
//  MarkdownView.swift
//  PetCore
//
//  Draws a chat answer's Markdown: headings, lists, quotes, tables, and code blocks with their language and a Copy
//  button. Mermaid diagrams and HTML get a live preview (a local web view: no network, HTML without scripts), with
//  a Preview/Code switch. While an answer is still streaming, previews wait and code shows as code.
//

import SwiftUI

struct MarkdownView: View {
    let text: String
    var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .paragraph:
                    Text(block.text)
                case .heading(let level):
                    Text(block.text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                case .listItem(let depth, let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).monospacedDigit().frame(minWidth: 14, alignment: .trailing)
                        Text(block.text)
                    }
                    .padding(.leading, CGFloat(depth - 1) * 18)
                case .quote:
                    Text(block.text).italic().foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
                case .code(let language):
                    CodeBlockView(code: block.plain, language: language, live: live)
                case .table(let rows):
                    TableBlockView(rows: rows)
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String?
    let live: Bool
    @State private var showCode = false
    @State private var copied = false

    private var previewable: Bool { !live && (language == "mermaid" || language == "html") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "code").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if previewable {
                    Picker("View", selection: $showCode) {
                        Text("Preview").tag(false)
                        Text("Code").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                Button {
                    Pasteboard.copy(code)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if previewable && !showCode {
                WebPreview(kind: language == "mermaid" ? .mermaid(code) : .html(code))
            } else {
                ScrollView(.horizontal) {
                    Text(code).font(.callout.monospaced()).padding(10).fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

struct TableBlockView: View {
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    GridRow {
                        ForEach(rows[index].indices, id: \.self) { column in
                            Text(rows[index][column])
                                .fontWeight(index == 0 ? .semibold : .regular)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: 260, alignment: .leading)
                                .background(index == 0 ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
                                .border(.quaternary, width: 0.5)
                        }
                    }
                }
            }
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
