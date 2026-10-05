import Foundation
import FoundationModels
import Testing
@testable import PetCore

struct ContextBudgetTests {
    static func hits(_ count: Int, size: Int) -> [Retriever.Hit] {
        (0..<count).map { index in
            let passage = IndexedPassage(text: "Passage \(index): " + String(repeating: "fact ", count: size / 5), note: "", vector: nil, locator: .none)
            let document = ChatDocument(name: "notes \(index).txt", kind: .text, scope: .library, passages: [passage])
            return Retriever.Hit(document: document, passage: passage, score: 1 - Double(index) / 100)
        }
    }

    static func messages(_ count: Int, size: Int) -> [ChatMessage] {
        (0..<count).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .friend, text: "Message \($0): " + String(repeating: "word ", count: size / 5)) }
    }

    @Test func cutsRecallThenOldMessagesThenPassagesKeepingTheBest() {
        typealias Budget = ContextBudget
        #expect(Budget.nextCut(hasRecall: true, recent: 5, passages: 3) == .recall)
        #expect(Budget.nextCut(hasRecall: false, recent: 5, passages: 3) == .oldestRecent)
        #expect(Budget.nextCut(hasRecall: false, recent: 2, passages: 3) == .lowestPassage, "the last question and answer stay")
        #expect(Budget.nextCut(hasRecall: false, recent: 2, passages: 1) == .oldestRecent, "the best passage outlasts them")
        #expect(Budget.nextCut(hasRecall: false, recent: 0, passages: 1) == .lowestPassage)
        #expect(Budget.nextCut(hasRecall: false, recent: 0, passages: 0) == nil)
    }

    @Test func fitsByMeasuringAndSaysWhenMessagesWent() async {
        let parts = ContextBudget.AnswerParts(recalled: String(repeating: "r", count: 300), recent: Self.messages(6, size: 100),
                                              passages: Self.hits(4, size: 100))
        // Measured in characters here, for a predictable test.
        let fitted = await ContextBudget.fit(parts, limit: 700) { parts in
            (parts.recalled?.count ?? 0) + parts.recent.map(\.text.count).reduce(0, +) + parts.passages.map(\.passage.text.count).reduce(0, +)
        }
        #expect(fitted.parts.recalled == nil)
        #expect(fitted.tokens <= 700 && fitted.droppedRecent)
        #expect(fitted.parts.recent.last?.text.hasPrefix("Message 5") == true, "the newest stay")
        #expect(fitted.parts.passages.first?.passage.text.hasPrefix("Passage 0") == true, "the best stays")
        let roomy = await ContextBudget.fit(parts, limit: 10_000) { _ in 500 }
        #expect(roomy.parts.recalled != nil && !roomy.droppedRecent, "nothing cut when it fits")
    }

    @Test func answersGetTheRoomLeftUpToTheirCeiling() {
        #expect(ContextBudget.cap(used: 1_000, contextSize: 4_096, ceiling: 900) == 900)
        #expect(ContextBudget.cap(used: 3_500, contextSize: 4_096, ceiling: 900) == 4_096 - 3_500 - ContextBudget.margin)
        #expect(ContextBudget.cap(used: 4_090, contextSize: 4_096, ceiling: 900) == 64, "always room for something")
        #expect(ContextBudget.estimate(String(repeating: "x", count: 25)) == 10, "2.5 characters a token without the OS count")
    }

    /// The real model's count: a long chat with many passages is trimmed until the answer has its room.
    @Test func aCrowdedPromptFitsTheRealWindow() async {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        let instructions = ChatPrompt.instructions(for: nil)
        let fixed = await ContextBudget.tokens(instructions: instructions, model: model)
        let limit = model.contextSize - fixed - ContextBudget.answerFloor
        let parts = ContextBudget.AnswerParts(recalled: String(repeating: "Earlier we talked about the launch. ", count: 30),
                                              recent: Self.messages(24, size: 600), passages: Self.hits(8, size: 900))
        func prompt(_ parts: ContextBudget.AnswerParts) -> String {
            ChatPrompt.make(summary: "They plan a launch.", recent: parts.recent, passages: parts.passages, question: "When is the launch?",
                            recalled: parts.recalled)
        }
        let fitted = await ContextBudget.fit(parts, limit: limit) { await ContextBudget.tokens(prompt($0), model: model) }
        let real = await ContextBudget.tokens(prompt(fitted.parts), model: model)
        #expect(real <= limit, "\(real) of \(limit)")
        #expect(fitted.droppedRecent && fitted.parts.recent.count >= 1)
        #expect(ContextBudget.cap(used: fixed + real, contextSize: model.contextSize, ceiling: ContextBudget.answerCeiling) >= ContextBudget.answerFloor - ContextBudget.margin)
    }

    @Test func oldChatsLoadAndTeamsRecordEachAgent() throws {
        var conversation = Conversation()
        conversation.contextUsed = 2_100
        let old = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(old.contextUsed == 2_100 && old.contextAgents == nil)
        conversation.contextAgents = [AgentUse(name: "Lead", tokens: 400), AgentUse(name: "Writer", tokens: 2_900)]
        #expect(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation)).contextAgents?.count == 2)
    }

    @Test func pointingBackPastWhatFitsGoesToTheTeam() {
        #expect(ContextBudget.needsTeam(droppedRecent: true, question: "what did we decide earlier about the venue?"))
        #expect(!ContextBudget.needsTeam(droppedRecent: false, question: "what did we decide earlier about the venue?"), "it all fit")
        #expect(!ContextBudget.needsTeam(droppedRecent: true, question: "what's a good venue?"), "it doesn't point back")
        let lines = ["User: hi", "User: the venue is the Grand Hall", "You: nice", "User: lunch ideas?"]
        #expect(ContextBudget.dropOrder(lines, for: "which venue did we pick")[...].last == 1, "the related line goes last")
        #expect(ContextBudget.dropOrder(lines, for: "which venue did we pick").first == 0, "oldest first among equals")
        let tasks = TeamEngine.usable([TeamTask(worker: .reasoning, ask: "venues")], question: "the venue we picked earlier?",
                                      web: false, hasHistory: true, reading: .thisChat)
        #expect(tasks.first == TeamTask(worker: .thisChat, ask: "the venue we picked earlier?"))
    }

    /// The real model, end to end: a detail far back in a long chat, asked about again.
    @MainActor @Test func aDetailFarBackIsFoundByTheTeam() async throws {
        let library = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var conversation = Conversation()
        conversation.messages = [ChatMessage(role: .user, text: "For the launch party we decided the venue is the Grand Hall in Jakarta."),
                                 ChatMessage(role: .friend, text: "Great, the Grand Hall it is!")]
            + (0..<40).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .friend,
                                         text: "Another thought about snacks and music number \($0): " + String(repeating: "chips, playlists and lights. ", count: 12)) }
        let thread = ChatThread(conversation, library: library, friend: nil)
        guard thread.unavailable == nil else { return }
        thread.send("What venue did we decide on earlier for the launch party?")
        for _ in 0..<1200 where thread.state != .idle || thread.conversation.messages.last?.role != .friend {
            try await Task.sleep(for: .milliseconds(100))
        }
        let reply = try #require(thread.conversation.messages.last)
        #expect(reply.text.contains("Grand Hall"), "\(reply.text)")
        #expect(reply.research?.isTeam == true, "read by a team: the history didn't fit the plain answer")
    }
}
