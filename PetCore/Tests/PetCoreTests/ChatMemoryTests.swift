import Foundation
import Testing
@testable import PetCore

struct ChatMemoryTests {
    private func conversation(_ pairs: [(String, String)], aside: Bool = false) -> Conversation {
        var conversation = Conversation()
        for (question, answer) in pairs {
            conversation.messages.append(ChatMessage(role: .user, text: question, aside: aside))
            conversation.messages.append(ChatMessage(role: .friend, text: answer, aside: aside))
        }
        return conversation
    }

    @Test func turnsPairQuestionsWithAnswersAndSkipAsides() {
        var chat = conversation([("cat name?", "Mochi"), ("budget?", "4,500")])
        chat.messages.append(ChatMessage(role: .user, text: "asd", aside: true))
        chat.messages.append(ChatMessage(role: .user, text: "unanswered"))
        let turns = ChatMemory.turns(of: chat)
        #expect(turns.map { $0.messages.map(\.text) } == [["cat name?", "Mochi"], ["budget?", "4,500"], ["unanswered"]])
    }

    @Test func questionsThatPointBack() {
        #expect(ChatMemory.pointsBack("What did we decide about the budget last week?"))
        #expect(ChatMemory.pointsBack("remember my cat's name?"))
        #expect(!ChatMemory.pointsBack("How big is the context window?"))
    }

    @Test func rankingKeepsWhatsInViewOutAndOthersNeedMore() {
        let here = conversation([("my cat is named Mochi", "Cute!"), ("weather today", "Sunny")])
        let other = conversation([("Mochi likes tuna", "Noted"), ("unrelated", "ok")])
        let turns = ChatMemory.turns(of: here) + ChatMemory.turns(of: other)
        var vectors: [UUID: [Double]] = [:]
        vectors[turns[0].messages[0].id] = [1, 0]   // cat, here
        vectors[turns[1].messages[0].id] = [0, 1]   // weather, here
        vectors[turns[2].messages[0].id] = [0.5, 0.5] // tuna, other conversation: only ~0.7
        vectors[turns[3].messages[0].id] = [0, 1]
        let ranked = ChatMemory.rank(question: "what's my cat called", vector: [1, 0], turns: turns, vectors: vectors,
                                     current: here.id, excluding: [], links: { _ in [] })
        #expect(ranked.first?.turn.messages[0].text == "my cat is named Mochi")
        #expect(ranked.contains { $0.turn.messages[0].text == "Mochi likes tuna" }, "clearly related elsewhere counts")
        #expect(!ranked.contains { $0.turn.messages[0].text == "unrelated" })
        let hidden = ChatMemory.rank(question: "cat", vector: [1, 0], turns: turns, vectors: vectors, current: here.id,
                                     excluding: [here.messages[0].id], links: { _ in [] })
        #expect(!hidden.contains { $0.turn.conversationID == here.id && $0.turn.messages[0].text.contains("Mochi") })
    }

    @Test func linksComeAlong() {
        let chat = conversation([("launch date?", "May 3rd"), ("venue?", "Grand Hall")])
        let turns = ChatMemory.turns(of: chat)
        let vectors = [turns[0].messages[0].id: [1.0, 0], turns[1].messages[0].id: [0.0, 1]]
        let venue = MessageRef(conversationID: chat.id, messageID: chat.messages[2].id)
        let ranked = ChatMemory.rank(question: "launch", vector: [1, 0], turns: turns, vectors: vectors, current: chat.id, excluding: [],
                                     links: { $0.messageID == chat.messages[0].id ? [venue] : [] })
        #expect(ranked.map { $0.turn.messages[0].text } == ["launch date?", "venue?"])
        #expect(ranked[1].linked)
    }

    @Test func slicesFitAndStopAtFour() {
        let long = String(repeating: "word ", count: 500)
        let chat = conversation((0..<60).map { ("q\($0) " + long, "a") })
        let ranked = ChatMemory.turns(of: chat).map { ChatMemory.Scored(turn: $0, score: 1, linked: false) }
        let slices = ChatMemory.slices(ranked)
        #expect(slices.count == ChatMemory.maxPasses)
        #expect(slices.allSatisfy { slice in slice.map { ChatPrompt.estimate($0.turn.text()) + 12 }.reduce(0, +) <= ChatMemory.sliceBudget })
    }

    @Test func emptyNotesAreRecognised() {
        #expect(ChatMemory.isEmptyNote(" Nothing relevant."))
        #expect(!ChatMemory.isEmptyNote("- The cat is Mochi"))
    }

    @MainActor @Test func linksAreTwoWayAndUnlink() {
        let library = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let a = conversation([("one", "1")]), b = conversation([("two", "2")])
        library.save(a)
        library.save(b)
        let x = MessageRef(conversationID: a.id, messageID: a.messages[0].id), y = MessageRef(conversationID: b.id, messageID: b.messages[1].id)
        library.link(x, y)
        #expect(library.links(of: x) == [y] && library.links(of: y) == [x])
        library.link(x, y, on: false)
        #expect(library.links(of: x).isEmpty && library.links(of: y).isEmpty)
    }
}
