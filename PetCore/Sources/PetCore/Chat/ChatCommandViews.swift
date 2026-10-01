//
//  ChatCommandViews.swift
//  PetCore
//
//  The "/" menu above the message box, and the file cards on the friend's replies (M25).
//

import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Every command matching what's typed after "/", grouped; the highlighted one is picked with Return or Tab.
struct CommandMenu: View {
    let commands: [ChatCommand]
    let highlighted: Int
    let pick: (ChatCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(ChatCommand.Group.allCases, id: \.self) { group in
                        let members = commands.filter { $0.group == group }
                        if !members.isEmpty {
                            Text(group.rawValue.uppercased())
                                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 6)
                            ForEach(members) { command in
                                row(command, selected: commands.firstIndex(of: command) == highlighted).id(command.id)
                            }
                        }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 240)
            .onChange(of: highlighted) { proxy.scrollTo(commands[safe: highlighted]?.id) }
        }
        .accessibilityLabel("Commands")
    }

    private func row(_ command: ChatCommand, selected: Bool) -> some View {
        Button { pick(command) } label: {
            HStack(spacing: 8) {
                Text("/" + command.name).font(.callout.monospaced().weight(.semibold))
                if !command.hint.isEmpty { Text(command.hint).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Text(command.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("/\(command.name), \(command.summary)")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A file the friend made: preview, save, share, and for calendars, add to Calendar.
struct ChatFileCard: View {
    let file: ChatFile
    @State private var preview: URL?
    @State private var saving = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.gradient)
                .overlay { Image(systemName: file.format.symbol).foregroundStyle(.white).font(.system(size: 17, weight: .medium)) }
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(file.format.title) · \(file.data.count.formatted(.byteCount(style: .file)))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if file.format == .ics {
                Button("Add to Calendar", systemImage: "calendar.badge.plus", action: addToCalendar)
            }
            Button("Preview", systemImage: "eye") { preview = try? file.temporaryURL() }
            Button("Save", systemImage: "square.and.arrow.down") { saving = true }
            if let url = try? file.temporaryURL() {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(10)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .quickLookPreview($preview)
        .fileExporter(isPresented: $saving, document: ChatFileDocument(data: file.data),
                      contentType: UTType(filenameExtension: file.format.rawValue) ?? .data, defaultFilename: file.name) { _ in }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.format.title) file, \(file.name)")
    }

    private var tint: Color {
        switch file.format {
        case .csv: .green
        case .json: .orange
        case .ics: .red
        case .pdf: .pink
        case .md: .indigo
        case .txt: .gray
        case .html: .teal
        }
    }

    /// The Mac opens it in Calendar; the iPhone's preview offers "Add All".
    private func addToCalendar() {
        guard let url = try? file.temporaryURL() else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        preview = url
        #endif
    }
}

struct ChatFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
