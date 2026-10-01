//
//  DiagramViews.swift
//  PetCore
//
//  A drawn diagram's menu in the chat (M29): save it as PNG or SVG (drawn light, on white) and edit its Mermaid
//  with a live preview.
//

import SwiftUI
import UniformTypeIdentifiers

struct DiagramMenu: View {
    let code: String
    /// Saves edited code into the message; nil where the message can't change (while the friend is busy).
    var edit: ((String) -> Void)?
    @State private var export: (data: Data, type: UTType)?
    @State private var editing = false
    @State private var failure: String?

    var body: some View {
        Menu {
            Button("Save as PNG", systemImage: "photo") { save(png: true) }
            Button("Save as SVG", systemImage: "square.on.circle") { save(png: false) }
            if edit != nil {
                Divider()
                Button("Edit Diagram…", systemImage: "pencil") { editing = true }
            }
        } label: {
            Label("Diagram", systemImage: "ellipsis.circle").labelStyle(.iconOnly).font(.caption)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Diagram options")
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                      document: ChatFileDocument(data: export?.data ?? Data()), contentType: export?.type ?? .png,
                      defaultFilename: "Diagram") { _ in }
        .sheet(isPresented: $editing) {
            DiagramEditor(code: code) { new in
                editing = false
                if new != code { edit?(new) }
            } cancel: { editing = false }
        }
        .alert("Couldn't save the diagram", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
    }

    private func save(png: Bool) {
        Task {
            do {
                let drawn = try await ChatDocumentRenderer.diagram(code)
                export = png ? (drawn.png, .png) : (drawn.svg, .svg)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// The diagram's Mermaid beside (Mac) or above (iPhone) a preview that redraws as you type.
struct DiagramEditor: View {
    @State var code: String
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var drawn = ""

    var body: some View {
        NavigationStack {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { editor.frame(minWidth: 320); Divider(); preview.frame(minWidth: 360) }
                VStack(spacing: 0) { preview.frame(maxHeight: 320); Divider(); editor }
            }
            .navigationTitle("Edit Diagram")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(code) }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 460)
        #endif
        .task(id: code) {
            // Redraw once typing pauses.
            try? await Task.sleep(for: .milliseconds(drawn.isEmpty ? 0 : 500))
            drawn = code
        }
    }

    private var editor: some View {
        TextEditor(text: $code)
            .font(.callout.monospaced())
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .padding(8)
            .accessibilityLabel("Mermaid code")
    }

    private var preview: some View {
        ScrollView {
            if !drawn.isEmpty { WebPreview(kind: .mermaid(drawn)).id(drawn).padding(8) }
        }
    }
}
