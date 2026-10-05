import Foundation
import FoundationModels
import Testing
@testable import PetCore

struct PlainChatTests {
    static func history(_ count: Int, size: Int) -> [ChatMessage] {
        (0..<count).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .friend, text: "Message \($0) " + String(repeating: "word ", count: size / 5)) }
    }

    @Test func everythingGoesInOneRequestWhenItFits() {
        let sources = [PlainChat.Source(name: "plan.txt", text: "The launch is on 14 November.", passages: ["The launch is on 14 November."])]
        let request = PlainChat.messages(instructions: "You are a friend.", history: Self.history(4, size: 50), sources: sources,
                                         question: "When is the launch?", limit: 32_000)
        let roles = request.messages.map(\.role)
        #expect(roles == [.system, .user, .assistant, .user, .assistant, .user])
        #expect(request.messages[0].text.contains("=== plan.txt ===\nThe launch is on 14 November."))
        #expect(request.messages.last?.text == "When is the launch?")
        #expect(request.answerTokens == 4_000)
    }

    @Test func overTheLimitOldMessagesThenWholeFilesGive() {
        let long = String(repeating: "Unrelated text about the weather. ", count: 300)
        let sources = [PlainChat.Source(name: "plan.txt", text: long + "Tickets cost 25 dollars.", passages: ["Tickets cost 25 dollars."])]
        let request = PlainChat.messages(instructions: "You are a friend.", history: Self.history(40, size: 400), sources: sources,
                                         question: "How much are tickets?", limit: 4_000)
        let size = request.messages.map { ContextBudget.estimate($0.text) + 4 }.reduce(0, +)
        #expect(size <= 4_000 - request.answerTokens, "\(size)")
        #expect(request.answerTokens == 1_000, "a quarter of a small limit")
        #expect(request.messages[0].text.contains("Tickets cost 25 dollars.") && !request.messages[0].text.contains("weather"),
                "the file cut to its closest passage")
        #expect(request.messages.dropLast().last?.text.hasPrefix("Message 39") == true, "the newest messages stay")
    }
}

@MainActor struct PlainChatTurnTests {
    static func thread(answering handler: @escaping NineRouterStub.Handler) -> (ChatThread, String) {
        let host = "nine-\(UUID().uuidString.lowercased()).test"
        NineRouterStub.serve(host: host, handler: handler)
        let settings = ModelSettings(defaults: UserDefaults(suiteName: "plain-\(UUID().uuidString)")!, secret: InMemorySecret())
        settings.baseURL = "http://\(host)/v1"
        settings.choose(.model("cc/claude-sonnet-4.5"), for: .chat)
        let thread = ChatThread(Conversation(), library: ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
                                friend: nil)
        thread.settings = settings
        return (thread, host)
    }

    static func idle(_ thread: ChatThread) async throws {
        for _ in 0..<300 where thread.state != .idle || thread.conversation.messages.last?.role != .friend {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func aTurnIsOneStreamedCallToTheChosenModel() async throws {
        let sent = Box<[String: Any]>([:])
        let (thread, _) = Self.thread { _, body in
            sent.value = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            return (200, Data(["data: {\"choices\":[{\"delta\":{\"content\":\"Hi there, \"}}]}", "data: {\"choices\":[{\"delta\":{\"content\":\"friend!\"}}]}", "data: [DONE]"]
                .map { $0 + "\n\n" }.joined().utf8))
        }
        guard thread.unavailable == nil else { return }
        thread.send("hello?")
        try await Self.idle(thread)
        let reply = try #require(thread.conversation.messages.last)
        #expect(reply.text == "Hi there, friend!" && reply.model == "cc/claude-sonnet-4.5")
        #expect(sent.value["model"] as? String == "cc/claude-sonnet-4.5" && sent.value["stream"] as? Bool == true)
        let messages = sent.value["messages"] as? [[String: Any]] ?? []
        #expect(messages.first?["role"] as? String == "system" && messages.last?["content"] as? String == "hello?")
        #expect(thread.conversation.contextAgents == nil && (thread.conversation.contextUsed ?? 0) > 0)
    }

    @Test func whenItCantAnswerTheFriendSaysSoAndOffersThisMac() async throws {
        let (thread, _) = Self.thread { _, _ in (502, Data(#"{"error":{"message":"All providers in the combo failed"}}"#.utf8)) }
        guard thread.unavailable == nil else { return }
        thread.send("hello?")
        try await Self.idle(thread)
        let reply = try #require(thread.conversation.messages.last)
        #expect(reply.text == "9Router: All providers in the combo failed")
        #expect(reply.isAside && reply.offer == .onDevice, "not context, and the way out is offered")
        thread.answerOnDevice(answering: reply.id)
        try await Self.idle(thread)
        let onDevice = try #require(thread.conversation.messages.last)
        #expect(onDevice.model == nil && !onDevice.isAside, "answered on this Mac")
        #expect(thread.conversation.messages.count == 2, "the failed reply was replaced")
    }
}
