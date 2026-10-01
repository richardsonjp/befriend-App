//
//  ChatLinkViews.swift
//  PetCore
//
//  Linking messages by hand (M26): "Link to…" picks other messages, in any conversation, that memory then always
//  recalls together with this one; the 🔗 badge lists them, with Unlink.
//

import SwiftUI

/// Every message of every conversation, searchable; tapping one links it.
struct LinkPicker: View {
    let library: ChatLibrary
    let from: MessageRef
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let linked = Set(library.links(of: from))
        NavigationStack {
            List {
                ForEach(library.conversations) { conversation in
                    let matches = conversation.messages.filter { message in
                        !message.isAside && message.id != from.messageID
                            && (query.isEmpty || message.text.localizedCaseInsensitiveContains(query))
                    }
                    if !matches.isEmpty {
                        Section(conversation.title) {
                            ForEach(matches) { message in
                                let ref = MessageRef(conversationID: conversation.id, messageID: message.id)
                                Button {
                                    library.link(from, ref, on: !linked.contains(ref))
                                } label: {
                                    HStack(alignment: .top) {
                                        LinkRowText(message: message)
                                        Spacer(minLength: 8)
                                        if linked.contains(ref) { Image(systemName: "link").foregroundStyle(.tint) }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(linked.contains(ref) ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search messages")
            .navigationTitle("Link to…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}

struct LinkRowText: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((message.role == .user ? "You: " : "Friend: ") + message.text.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(2)
            Text(message.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "🔗 2" on a linked message: what it's linked to, each with Unlink.
struct LinkBadge: View {
    let library: ChatLibrary
    let ref: MessageRef
    @State private var showing = false

    var body: some View {
        let links = library.links(of: ref)
        if !links.isEmpty {
            Button { showing = true } label: {
                Label("\(links.count)", systemImage: "link").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Linked messages: recalled together")
            .accessibilityLabel("\(links.count) linked messages")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Linked messages").font(.headline)
                    Text("Memory always recalls these together.").font(.caption).foregroundStyle(.secondary)
                    ForEach(links, id: \.self) { target in
                        HStack(alignment: .top) {
                            if let message = library.message(target) {
                                VStack(alignment: .leading, spacing: 2) {
                                    LinkRowText(message: message)
                                    if target.conversationID != ref.conversationID, let other = library.conversation(target.conversationID) {
                                        Text("in “\(other.title)”").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("A message that was deleted").foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Unlink") { library.link(ref, target, on: false) }.buttonStyle(.borderless)
                        }
                    }
                }
                .padding()
                .frame(width: 340)
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}
