import Foundation
import Testing
@testable import PetCore

struct GuardrailTests {
    private let dictionary: Set<String> = ["what", "is", "the", "launch", "date", "do", "you", "mean", "camera", "unbind"]
    private func judge(_ text: String) -> MessageCheck { MessageCheck.judge(text) { dictionary.contains($0) } }

    @Test func keyboardNoiseIsGibberish() {
        for text in ["asd", "asdf jkl", "sdfghj", "aaaaaa", "?", "   ", "asd sdf"] {
            #expect(judge(text) == .gibberish, "\(text)")
        }
    }

    @Test func realMessagesPass() {
        for text in ["What is the launch date?", "hi", "why?", "thanks", "Budi", "unbind camera 1.1.x",
                     "read https://swift.org", "日本語で説明して"] {
            #expect(judge(text) == .valid, "\(text)")
        }
    }

    @Test func unclearMessagesGoToTheModel() {
        #expect(judge("lorem ipsum dolor sit amet") == .unsure)
    }

    @Test func mashing() {
        #expect(MessageCheck.mashed("qwer") && MessageCheck.mashed("lkjh") && MessageCheck.mashed("zzzz") && MessageCheck.mashed("bcdfgh"))
        #expect(!MessageCheck.mashed("launch") && !MessageCheck.mashed("ok"))
    }
}

@MainActor struct ChatTurnTests {
    private func thread() -> (ChatThread, ChatLibrary) {
        let library = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        return (ChatThread(Conversation(), library: library, friend: nil), library)
    }

    @Test func gibberishGetsAClarificationAndIsNeverContext() async throws {
        let (thread, _) = thread()
        guard thread.unavailable == nil else { return } // send() needs the model on this machine
        thread.send("asd", web: true)
        for _ in 0..<50 where thread.conversation.messages.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let messages = thread.conversation.messages
        #expect(messages.count == 2 && messages.allSatisfy(\.isAside))
        #expect(MessageCheck.clarifications.contains(messages[1].text))
        #expect(thread.conversation.title == "New conversation")
    }

    @Test func stoppingEarlyGivesTheQuestionBack() {
        let (thread, _) = thread()
        guard thread.unavailable == nil else { return }
        thread.send("What is the launch date?")
        #expect(thread.stop() == "What is the launch date?")
        #expect(thread.conversation.messages.isEmpty && thread.state == .idle)
        #expect(thread.stop() == nil)
    }

    @Test func editingDropsWhatCameAfter() {
        let library = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var conversation = Conversation()
        conversation.messages = [ChatMessage(role: .user, text: "first"), ChatMessage(role: .friend, text: "a1"),
                                 ChatMessage(role: .user, text: "second"), ChatMessage(role: .friend, text: "a2")]
        conversation.summary = "notes"
        conversation.summarizedCount = 3
        let thread = ChatThread(conversation, library: library, friend: nil)
        guard thread.unavailable == nil else { return }
        thread.resend(from: conversation.messages[2].id, as: "second, edited")
        thread.stop()
        #expect(thread.conversation.messages.map(\.text) == ["first", "a1"])
        #expect(thread.conversation.summary == nil && thread.conversation.summarizedCount == 0)
    }
}
