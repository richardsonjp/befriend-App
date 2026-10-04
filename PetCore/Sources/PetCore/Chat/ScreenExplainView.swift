//
//  ScreenExplainView.swift
//  PetCore
//
//  The explanation of a captured part of the screen (M31): the Mac's card beside the box and the iPhone's share
//  sheet. What it is, the explanation streaming in, follow-ups asked right here, and the way into the full chat.
//

import SwiftUI

public struct ScreenExplainView: View {
    let thread: ChatThread
    /// Nil where chat can't be opened from here (the iPhone's share sheet): it says where the explanation went.
    let openChat: (() -> Void)?
    let close: () -> Void
    @State private var question = ""
    @FocusState private var asking: Bool

    public init(thread: ChatThread, openChat: (() -> Void)?, close: @escaping () -> Void) {
        self.thread = thread
        self.openChat = openChat
        self.close = close
    }

    /// "A Python TypeError on line 42", from the chat's title.
    private var what: String {
        let title = thread.conversation.messages.first?.text ?? ""
        return title.hasPrefix("Screenshot · ") ? String(title.dropFirst("Screenshot · ".count)) : "Explain"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label(what, systemImage: "text.viewfinder").font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(thread.conversation.messages.dropFirst()) { message in
                            if message.role == .user {
                                Text(message.text).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            } else {
                                MarkdownView(text: message.text)
                            }
                        }
                        status
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onChange(of: thread.state) { scroll.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask more…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($asking)
                    .onSubmit(ask)
                    .disabled(thread.state != .idle || thread.conversation.messages.isEmpty)
                if let openChat {
                    Button("Open in Chat", action: openChat).disabled(thread.conversation.messages.isEmpty)
                } else if !thread.conversation.messages.isEmpty {
                    Text("Saved to befriend's Chat").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder private var status: some View {
        switch thread.state {
        case .idle:
            if let failure = thread.failure ?? (thread.conversation.messages.isEmpty ? thread.unavailable : nil) {
                Text(failure).foregroundStyle(.red).font(.callout)
            }
        case .answering(let text) where !text.isEmpty:
            MarkdownView(text: text, live: true)
        case .making(let what), .browsing(let what), .remembering(let what):
            ProgressView { Text(what).font(.callout) }.progressViewStyle(.linear)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        thread.send(text)
        question = ""
    }
}
