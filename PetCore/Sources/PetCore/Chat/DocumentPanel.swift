//
//  DocumentPanel.swift
//  PetCore
//
//  Long documents as artifacts, the way Claude shows them: in the chat a compact card, and the document itself
//  rendered in a panel beside the conversation (a sheet on iPhone), with Copy and Download as Markdown, PDF or HTML.
//

import SwiftUI
import UniformTypeIdentifiers

/// In the chat, in place of the full report.
struct DocumentCard: View {
    let message: ChatMessage
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 52)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title(of: message.text)).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(Self.subtitle(of: message.text)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Open").font(.callout.weight(.medium)).foregroundStyle(.tint)
            }
            .padding(10)
            .frame(maxWidth: 520, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .accessibilityLabel("Document, \(Self.title(of: message.text))")
        .accessibilityHint("Opens the document")
    }

    static func title(of markdown: String) -> String {
        markdown.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "Document"
    }

    /// "Document · 1,240 words".
    static func subtitle(of markdown: String) -> String {
        "Document · \(markdown.split(whereSeparator: \.isWhitespace).count.formatted()) words"
    }
}

/// The document, rendered, with its actions.
struct DocumentPanel: View {
    let message: ChatMessage
    var editDiagram: ((String, String) -> Void)?
    let close: () -> Void
    @State private var export: (data: Data, type: UTType, name: String)?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownView(text: message.text, editDiagram: editDiagram)
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle(DocumentCard.title(of: message.text))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: close)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        Pasteboard.copy(message.text)
                        copied = true
                    }
                    Menu("Download", systemImage: "arrow.down.circle") {
                        Button("Markdown (.md)") { save(.md) }
                        Button("PDF") { save(.pdf) }
                        Button("Web page (.html)") { save(.html) }
                    }
                }
            }
        }
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                      document: ChatFileDocument(data: export?.data ?? Data()), contentType: export?.type ?? .data,
                      defaultFilename: export?.name) { _ in }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func save(_ format: ChatFileFormat) {
        let title = DocumentCard.title(of: message.text)
        Task {
            let data = format == .md ? ChatFileWriter.markdown(message.text)
                : await ChatFileWriter.document(message.text, title: title, format: format)
            export = (data, UTType(filenameExtension: format.rawValue) ?? .data, ChatFileMaker.fileName(title, format))
        }
    }
}

extension ChatMessage {
    /// Shown as a document (card + panel) rather than a chat bubble: research reports (not a team's answer).
    var isDocument: Bool { research.map { !$0.isTeam } ?? false }
}
