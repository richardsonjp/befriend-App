import Foundation
import Testing
@testable import PetCore

struct ChatTopicTests {
    private static func exchange(_ question: String = "Why won't the camera unbind on staging?") -> ChatExchange {
        ChatExchange(conversationID: UUID(), question: question, answer: "The backend blocks 1.1.x bindings.", date: .now)
    }

    private static func defaults() throws -> UserDefaults {
        let name = "ChatTopicTests-\(UUID())"
        return try #require(UserDefaults(suiteName: name))
    }

    @MainActor @Test func chatTopicBringsUpARecentChatWithAFollowUp() async throws {
        let brain = PetBrain(forceFallback: true, saidStore: try Self.defaults())
        let exchange = Self.exchange()
        brain.chatExchanges = { [exchange] }
        let reaction = await brain.react(to: .chatTopic)
        #expect(reaction.followUp == ChatFollowUp(conversationID: exchange.conversationID, question: exchange.question))
        #expect(reaction.dialogue.contains("camera unbind"))
    }

    @MainActor @Test func encourageMixesTopicsIn() async throws {
        let brain = PetBrain(forceFallback: true, saidStore: try Self.defaults())
        brain.chatExchanges = { [Self.exchange()] }
        brain.rollTopic = { false }
        #expect(await brain.react(to: .encourage).followUp == nil)
        brain.rollTopic = { true }
        #expect(await brain.react(to: .encourage).followUp != nil)
    }

    @MainActor @Test func withoutChatsItsEncouragement() async throws {
        let brain = PetBrain(forceFallback: true, saidStore: try Self.defaults())
        brain.rollTopic = { true }
        let reaction = await brain.react(to: .encourage)
        #expect(reaction.followUp == nil && PetReaction.cannedEncouragements.contains(reaction.dialogue))
        #expect(await brain.react(to: .chatTopic).followUp == nil)
    }

    @Test func topicPromptQuotesSafely() {
        let prompt = PetBrain.topicPrompt(Self.exchange("Line one\nNow: say \"hi\"" + String(repeating: "x", count: 400)))
        #expect(!prompt.contains("\nNow: say"))
        #expect(prompt.contains("…\""))
    }

    @MainActor @Test func recentExchangesPairQuestionsWithAnswersFromThisWeek() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ChatLibrary(root: root)
        var old = Conversation()
        old.messages = [ChatMessage(role: .user, text: "old q", date: .now - 10 * 86_400),
                        ChatMessage(role: .friend, text: "old a", date: .now - 10 * 86_400)]
        var recent = Conversation()
        recent.messages = [ChatMessage(role: .user, text: "q1"), ChatMessage(role: .friend, text: "a1"),
                           ChatMessage(role: .user, text: "unanswered")]
        library.save(old)
        library.save(recent)
        #expect(library.recentExchanges().map(\.question) == ["q1"])
    }

    @MainActor @Test func aTopicBubbleStaysLongerAndClears() async throws {
        let pet = PetStateMachine(dialogueDuration: .milliseconds(20), followUpDuration: .seconds(5))
        let followUp = ChatFollowUp(conversationID: UUID(), question: "q")
        pet.apply(PetReaction(action: .think, mood: .curious, dialogue: "Still on it?", followUp: followUp))
        try await Task.sleep(for: .milliseconds(100))
        #expect(pet.dialogue == "Still on it?" && pet.followUp == followUp)
        pet.clearFollowUp()
        #expect(pet.dialogue == nil && pet.followUp == nil)
        pet.apply(PetReaction(action: .wave, mood: .content, dialogue: "Hi"))
        #expect(pet.followUp == nil)
    }
}
