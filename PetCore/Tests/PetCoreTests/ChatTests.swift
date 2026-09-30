import Foundation
import Testing
@testable import PetCore

struct ChunkerTests {
    @Test func splitsOnSentencesNearTheTarget() {
        let text = (1...10).map { "Sentence number \($0) has five words." }.joined(separator: " ")
        let passages = Chunker.passages(from: [(text, .none)], target: 12)
        #expect(passages.count == 5) // 6 words each → two sentences a passage
        #expect(passages[0].text == "Sentence number 1 has five words. Sentence number 2 has five words.")
    }

    @Test func pagesNeverShareAPassage() {
        let passages = Chunker.passages(from: [("Page one text.", .page(1)), ("Page two text.", .page(2))])
        #expect(passages.map(\.locator) == [.page(1), .page(2)])
    }

    @Test func aPassageKeepsItsFirstTimestamp() {
        let passages = Chunker.passages(from: [("Hello there.", .time(3)), ("More words here.", .time(9))], target: 100)
        #expect(passages.count == 1 && passages[0].locator == .time(3))
    }

    @Test func runOnTextIsCut() {
        let words = Array(repeating: "word", count: 250).joined(separator: " ")
        #expect(Chunker.passages(from: [(words, .none)], target: 100).count == 3)
    }

    @Test func locatorLabels() {
        #expect(PassageLocator.page(3).label == "p.3")
        #expect(PassageLocator.time(134.7).label == "02:14")
        #expect(PassageLocator.none.label == nil)
    }
}

struct RetrieverTests {
    private func document(_ name: String, _ passages: [(String, [Double])]) -> ChatDocument {
        ChatDocument(name: name, kind: .text, scope: .library,
                     passages: passages.map { IndexedPassage(text: $0.0, note: $0.0, vector: $0.1, locator: .none) })
    }

    @Test func ranksBySimilarityThenKeywords() {
        let docs = [document("a", [("Cats sleep a lot", [1, 0]), ("Budget for March", [0, 1])])]
        let hits = Retriever.rank("how much budget", vector: [0.1, 0.9], in: docs)
        #expect(hits.first?.passage.text == "Budget for March")
    }

    @Test func keywordsFindPassagesWithoutVectors() {
        let docs = [document("notes", [("Rapat dengan Budi tentang anggaran", []), ("Unrelated text here", [])])]
        let hits = Retriever.rank("What did Budi say?", vector: nil, in: docs)
        #expect(hits.count == 1 && hits[0].source.label == "notes")
    }

    @Test func cosine() {
        #expect(Retriever.cosine([1, 0], [1, 0]) == 1)
        #expect(Retriever.cosine([1, 0], [0, 1]) == 0)
        #expect(Retriever.cosine([], []) == 0)
    }
}

struct ChatPromptTests {
    @Test func budgetKeepsRoomForTheAnswer() {
        let split = ChatPrompt.split(contextSize: 4096, instructions: 500, question: 30)
        #expect(split.passages == ChatPrompt.maxPassageTokens)
        #expect(split.passages + split.history == 4096 - ChatPrompt.answerReserve - ChatPrompt.overhead - 530)
        #expect(ChatPrompt.split(contextSize: 1000, instructions: 900, question: 50) == (0, 0))
    }

    @Test func compactsTheOldestButNeverTheLastExchange() {
        #expect(ChatPrompt.toCompact(messageTokens: [100, 100, 100], summaryTokens: 0, budget: 400) == 0)
        #expect(ChatPrompt.toCompact(messageTokens: [300, 300, 100, 100], summaryTokens: 50, budget: 300) == 2)
        #expect(ChatPrompt.toCompact(messageTokens: [500, 500], summaryTokens: 0, budget: 10) == 0)
    }

    @Test func fitting() {
        #expect(ChatPrompt.fitting([100, 200, 300], budget: 350) == 2)
        #expect(ChatPrompt.fitting([500], budget: 100) == 0)
    }

    @Test func promptHoldsSummaryHistoryPassagesAndQuestion() {
        let doc = ChatDocument(name: "notes.pdf", kind: .pdf, scope: .library,
                               passages: [IndexedPassage(text: "Launch is May 3.", note: "Launch date", vector: nil, locator: .page(2))])
        let hit = Retriever.Hit(document: doc, passage: doc.passages[0], score: 1)
        let prompt = ChatPrompt.make(summary: "They planned a launch.", recent: [ChatMessage(role: .user, text: "Hi")],
                                     passages: [hit], question: "When is launch?")
        #expect(prompt.contains("(notes):\nThey planned a launch."))
        #expect(prompt.contains("User: Hi"))
        #expect(prompt.contains("[1] notes.pdf · p.2: Launch is May 3."))
        #expect(prompt.hasSuffix("Question: When is launch?"))
    }

    @Test func instructionsCarryTheFriendsVoice() {
        #expect(!ChatPrompt.instructions(for: nil).contains("Your name"))
    }
}

struct ChatStorageTests {
    @Test func conversationTitleAndRoundTrip() throws {
        var conversation = Conversation()
        #expect(conversation.title == "New conversation")
        conversation.messages = [ChatMessage(role: .user, text: String(repeating: "a", count: 60))]
        conversation.summary = "s"
        #expect(conversation.title.count == Conversation.titleLength)
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(back == conversation)
    }

    @MainActor @Test func libraryPersistsConversationsAndPastedText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ChatLibrary(root: root)
        var conversation = Conversation()
        conversation.messages = [ChatMessage(role: .user, text: "Hello")]
        library.save(conversation)
        library.add(text: "Remember the milk.", name: "Groceries", scope: .conversation(conversation.id))
        for _ in 0..<100 where library.documents.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        let reopened = ChatLibrary(root: root)
        #expect(reopened.conversations == [conversation])
        #expect(reopened.documents(for: conversation.id).map(\.name) == ["Groceries"])
        #expect(reopened.libraryDocuments.isEmpty)
        reopened.delete(conversation: conversation.id)
        #expect(ChatLibrary(root: root).documents.isEmpty) // attachments go with their conversation
    }

    @Test func unsupportedFilesAreRecognised() {
        #expect(Ingest.kind(of: URL(filePath: "/a/b.pdf")) == .pdf)
        #expect(Ingest.kind(of: URL(filePath: "/a/b.m4a")) == .audio)
        #expect(Ingest.kind(of: URL(filePath: "/a/b.mov")) == .video)
        #expect(Ingest.kind(of: URL(filePath: "/a/b.heic")) == .image)
        #expect(Ingest.kind(of: URL(filePath: "/a/b.md")) == .text)
        #expect(Ingest.kind(of: URL(filePath: "/a/b.zip")) == nil)
    }
}

struct PasteTests {
    @MainActor @Test func pastedFilesAndImagesAreAttached() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ChatLibrary(root: root)
        let conversation = UUID()
        let adder = FileAdder(library: library, scope: .conversation(conversation))

        let note = root.appending(path: "notes.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "The launch is on May 3.".write(to: note, atomically: true, encoding: .utf8)
        let copiedFile = NSItemProvider(contentsOf: note)!
        // A copied image (e.g. a screenshot) arrives as data with no file behind it.
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let copiedImage = NSItemProvider(item: png as NSData, typeIdentifier: "public.png")
        copiedImage.suggestedName = "Screenshot"

        adder.add([copiedFile, copiedImage])
        for _ in 0..<150 where library.documents.count + library.jobs.filter({ $0.failure != nil }).count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(library.attached(to: conversation).map(\.name).contains("notes.txt"))
        // The 1-pixel image has nothing to read, so it fails, but it was taken in, named and typed.
        let names = library.documents.map(\.name) + library.jobs.map(\.name)
        #expect(names.contains("Screenshot.png"))
    }
}

struct ComposerTests {
    @Test func longPastesBecomeFiles() {
        let block = String(repeating: "log line\n", count: 200)
        let split = ChatComposer.pastedBlock(old: "Look at this: ", new: "Look at this: " + block)
        #expect(split?.draft == "Look at this: " && split?.pasted == block)
        let middle = ChatComposer.pastedBlock(old: "ab", new: "a" + block + "b")
        #expect(middle?.draft == "ab" && middle?.pasted == block)
        #expect(ChatComposer.pastedBlock(old: "", new: "short paste") == nil)
        #expect(ChatComposer.pastedBlock(old: "", new: String(repeating: " ", count: 2000)) == nil)
    }

    @MainActor @Test func aConversationFileMovesToTheLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ChatLibrary(root: root)
        let conversation = UUID()
        library.add(text: "Launch is May 3.", name: "Notes", scope: .conversation(conversation))
        for _ in 0..<100 where library.documents.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let id = try #require(library.documents.first?.id)
        library.moveToLibrary(id)
        #expect(library.items(in: .library).map(\.name) == ["Notes"])
        #expect(library.items(in: .conversation(conversation)).isEmpty)
        #expect(ChatLibrary(root: root).libraryDocuments.map(\.id) == [id])
    }
}
