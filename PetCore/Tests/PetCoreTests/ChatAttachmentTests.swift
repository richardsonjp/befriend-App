import Foundation
import Testing
@testable import PetCore

@MainActor struct ChatAttachmentTests {
    static func library() -> ChatLibrary {
        ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    static func added(_ text: String, to library: ChatLibrary, scope: ChatDocument.Scope) async throws -> ChatDocument {
        library.add(text: text, name: "Pasted text", scope: scope)
        for _ in 0..<100 where !library.documents.contains(where: { $0.scope == scope && $0.passages.first?.text == text }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(library.documents.first { $0.scope == scope && $0.passages.first?.text == text })
    }

    @Test func boxFilesAreSentWithTheMessageAndOnlyThenUsedAndSynced() async throws {
        let library = Self.library()
        var changes: [ChatLibrary.Change] = []
        library.onChange = { changes.append($0) }
        let chat = UUID()
        let document = try await Self.added("The venue is the Grand Hall.", to: library, scope: .draft(chat))
        #expect(!library.documents(for: chat).contains { $0.id == document.id }, "not searched before it's sent")
        #expect(!changes.contains { $0.id == document.id }, "not synced before it's sent")

        let sent = try #require(library.sendDrafts(of: chat))
        #expect(sent == [ChatMessage.Attachment(id: document.id, name: "Pasted text", kind: .text)])
        #expect(library.documents(for: chat).contains { $0.id == document.id }, "the conversation keeps using it")
        #expect(library.items(in: .draft(chat)).isEmpty, "the box is empty")
        #expect(changes.contains { $0.id == document.id && !$0.deleted }, "synced once sent")
        #expect(library.sendDrafts(of: chat) == nil)

        library.unsend(sent, in: chat)
        #expect(library.items(in: .draft(chat)).map(\.id) == [document.id], "taken back: in the box again")
    }

    @Test func aMessageCarriesItsFilesAndStoppingGivesThemBack() async throws {
        let library = Self.library()
        let thread = ChatThread(Conversation(), library: library, friend: nil)
        guard thread.unavailable == nil else { return }
        let id = thread.conversation.id
        let document = try await Self.added("Tickets cost 25 dollars.", to: library, scope: .draft(id))
        thread.send("How much are tickets?")
        #expect(thread.conversation.messages.last?.attachments?.map(\.id) == [document.id])
        #expect(library.items(in: .draft(id)).isEmpty)
        #expect(thread.stop() == "How much are tickets?")
        #expect(library.items(in: .draft(id)).map(\.id) == [document.id], "stopped before an answer: back in the box")
    }

    @Test func messagesWithoutAttachmentsStillLoad() throws {
        let old = try JSONEncoder().encode(ChatMessage(role: .user, text: "hi"))
        #expect(try JSONDecoder().decode(ChatMessage.self, from: old).attachments == nil)
        var message = ChatMessage(role: .user, text: "see file")
        message.attachments = [ChatMessage.Attachment(id: UUID(), name: "a.pdf", kind: .pdf)]
        #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)).attachments == message.attachments)
        #expect(message.with(text: "edited").attachments == message.attachments)
    }
}
