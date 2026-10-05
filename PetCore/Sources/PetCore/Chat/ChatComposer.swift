//
//  ChatComposer.swift
//  PetCore
//
//  The message box, as one glass card: the files about to be sent as cards on top, the text, then + on the left and
//  send on the right. Long pasted text becomes a "Pasted text" file instead of a wall in the box. As in Claude, files
//  go with the message they're sent with and leave the box (the conversation keeps using them).
//

import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    let library: ChatLibrary
    let conversation: UUID
    let adder: FileAdder
    let answering: Bool
    let disabled: Bool
    @Binding var web: Bool
    @Binding var research: Bool
    @Binding var effort: ResearchEffort
    let send: () -> Void
    let stop: () -> Void
    /// The card's height as it grows (files, more lines), so the chat can keep its last message in view.
    var onHeight: (CGFloat) -> Void = { _ in }
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?
    /// The highlighted row of the "/" menu.
    @State private var highlighted = 0
    @State private var confirmingClear = false

    /// Pasting this many characters or more at once makes a file of them.
    static let pasteAsFile = 1000

    var body: some View {
        let items = library.items(in: .draft(conversation))
        let commands = ChatCommand.suggestions(for: draft)
        VStack(alignment: .leading, spacing: 10) {
            if let commands {
                CommandMenu(commands: commands, highlighted: min(highlighted, commands.count - 1)) { pick($0) }
                Divider()
            }
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { AttachmentCard(item: $0, library: library) }
                        if items.count >= 2 {
                            Button("Clear All", role: .destructive) { confirmingClear = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityHint("Removes every file from the message box")
                        }
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                .scrollClipDisabled()
                .confirmationDialog("Remove all \(items.count) files from the message box?", isPresented: $confirmingClear) {
                    Button("Remove All", role: .destructive) { library.removeAll(in: .draft(conversation), web: false) }
                }
            }
            TextField("Ask about your files", text: $draft, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .frame(maxWidth: .infinity, alignment: .leading) // fill the card, full screen too
                .focused($focused)
                .onSubmit {
                    if let commands, let command = commands[safe: highlighted] { pick(command) } else { send() }
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    insertNewline()
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow, .tab], phases: .down) { press in
                    guard let commands else { return .ignored }
                    switch press.key {
                    case .upArrow: highlighted = max(0, highlighted - 1)
                    case .downArrow: highlighted = min(commands.count - 1, highlighted + 1)
                    default: if let command = commands[safe: highlighted] { pick(command) }
                    }
                    return .handled
                }
                .onChange(of: draft) { highlighted = 0 }
                .padding(.horizontal, 4)
            HStack(spacing: 10) {
                AddFilesMenu(adder: adder, pastedText: { draft += $0 }) {
                    Image(systemName: "plus").fontWeight(.semibold)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .fixedSize()
                .accessibilityLabel("Add photos and files")
                webButton
                ResearchButton(on: $research, effort: $effort)
                Spacer()
                sendButton
            }
            .controlSize(.large)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: onHeight)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onChange(of: draft) { old, new in
            guard let split = Self.pastedBlock(old: old, new: new) else { return }
            library.add(text: split.pasted, name: "Pasted text", scope: .draft(conversation))
            draft = split.draft
        }
    }

    /// On-off web search, as a chip: tinted while on.
    private var webButton: some View {
        Button { web.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                Text("Search")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(web ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(web ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.secondary), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(web ? "Web search is on for your messages" : "Search the web too")
        .accessibilityValue(web ? "On" : "Off")
        .accessibilityAddTraits(web ? .isSelected : [])
        .accessibilityHint("Also searches the web for your next messages")
    }

    private var sendButton: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Files still being read go with the message once they're ready.
        let reading = library.readingDrafts(of: conversation)
        return Button(action: answering ? stop : send) {
            Image(systemName: answering ? "stop.fill" : "arrow.up").fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .disabled(!answering && (empty || disabled || reading))
        .keyboardShortcut(answering ? KeyboardShortcut(".", modifiers: .command) : KeyboardShortcut(.return, modifiers: .command))
        .help(answering ? "Stop (⌘. or Esc)" : reading ? "Waiting for your files to be read" : "Send (Return)")
        .accessibilityLabel(answering ? "Stop answering" : "Send")
    }

    /// Puts "/name " in the box; commands that need nothing typed after them run right away.
    private func pick(_ command: ChatCommand) {
        draft = "/" + command.name + " "
        selection = TextSelection(insertionPoint: draft.endIndex)
        if command.hint.isEmpty { send() } // the rest wait for what goes after them
    }

    /// Shift-Return: a new line where the cursor is (Return sends).
    private func insertNewline() {
        guard case .selection(let range)? = selection?.indices, range.upperBound <= draft.endIndex else {
            draft += "\n"
            return
        }
        let offset = draft.distance(from: draft.startIndex, to: range.lowerBound)
        draft.replaceSubrange(range, with: "\n")
        selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: offset + 1))
    }

    /// If `new` is `old` with a long block pasted in, the draft without it and the block.
    static func pastedBlock(old: String, new: String) -> (draft: String, pasted: String)? {
        guard new.count - old.count >= pasteAsFile else { return nil }
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
        let keptSuffix = min(suffix, old.count - prefix)
        let start = new.index(new.startIndex, offsetBy: prefix)
        let end = new.index(new.endIndex, offsetBy: -keptSuffix)
        guard start < end else { return nil }
        let pasted = String(new[start..<end])
        return pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (old, pasted)
    }
}

/// One attached file in the composer: thumbnail or type tile, name, what it's doing; × to remove.
struct AttachmentCard: View {
    let item: ChatFileItem
    let library: ChatLibrary

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(item: item, library: library, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(item.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                if item.isMedia { SpokenLanguageMenu(item: item, library: library) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 240, alignment: .leading)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.65), in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(item.isWorking ? "Cancel adding \(item.name)" : "Remove \(item.name)")
        }
        .contextMenu {
            Button(item.isWorking ? "Cancel" : "Remove", systemImage: "trash", role: .destructive, action: remove)
        }
    }

    private func remove() {
        if case .ready = item.status { library.delete(document: item.id) } else { library.cancel(item.id) }
    }
}
