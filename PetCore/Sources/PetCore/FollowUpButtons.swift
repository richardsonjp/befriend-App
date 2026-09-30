//
//  FollowUpButtons.swift
//  PetCore
//
//  Under a speech bubble that brings up an earlier chat (M19): follow it up in a new chat, or continue the chat it
//  came from. Either way Chat opens with the suggested question typed in, not sent.
//

import SwiftUI

public struct FollowUpButtons: View {
    let followUp: ChatFollowUp
    let open: (ChatStart) -> Void

    public init(followUp: ChatFollowUp, open: @escaping (ChatStart) -> Void) {
        self.followUp = followUp
        self.open = open
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button { open(ChatStart(conversation: nil, draft: followUp.question)) } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            Button { open(ChatStart(conversation: followUp.conversationID, draft: followUp.question)) } label: {
                Label("Continue that chat", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .font(.caption.weight(.medium))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .help(followUp.question)
    }
}

public nonisolated extension ChatFollowUp {
    /// befriend://followup?c=<conversation>&q=<question>: the widget's tap on a chat topic.
    var url: URL? {
        var components = URLComponents()
        components.scheme = "befriend"
        components.host = "followup"
        components.queryItems = [URLQueryItem(name: "c", value: conversationID.uuidString), URLQueryItem(name: "q", value: question)]
        return components.url
    }

    init?(url: URL) {
        guard url.scheme == "befriend", url.host() == "followup",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "c" })?.value.flatMap(UUID.init(uuidString:)),
              let question = items.first(where: { $0.name == "q" })?.value, !question.isEmpty else { return nil }
        self.init(conversationID: id, question: String(question.prefix(500)))
    }
}
