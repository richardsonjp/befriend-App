import Foundation
import FoundationModels
import Testing
@testable import PetCore

struct TeamPlanTests {
    @Test func usableTasksFollowWhatsAvailable() {
        let tasks = [TeamTask(worker: .web, ask: "latest price"), TeamTask(worker: .thisChat, ask: "what did I pick"),
                     TeamTask(worker: .files, ask: "my budget"), TeamTask(worker: .files, ask: "My budget"),
                     TeamTask(worker: .reasoning, ask: "compare"), TeamTask(worker: .reasoning, ask: "  "),
                     TeamTask(worker: .files, ask: "fees"), TeamTask(worker: .files, ask: "taxes")]
        let offline = TeamEngine.usable(tasks, question: "q", web: false, hasHistory: false)
        #expect(offline.map(\.worker) == [.files, .reasoning, .files, .files], "no web, no history, no repeats, at most 4")
        #expect(TeamEngine.usable(tasks, question: "q", web: true, hasHistory: true).first?.worker == .web)
        #expect(TeamEngine.usable([], question: "why is the sky blue?", web: false, hasHistory: false)
                == [TeamTask(worker: .reasoning, ask: "why is the sky blue?")], "no plan: think about the question")
        let reasoned = [TeamTask(worker: .reasoning, ask: "ticket price in my plan"), TeamTask(worker: .reasoning, ask: "is it a good deal")]
        let mine = TeamEngine.usable(reasoned, question: "my launch?", web: false, hasHistory: false) { $0.contains("my") }
        #expect(mine.map(\.worker) == [.files, .reasoning], "a task about the user's files reads them")
        #expect(TeamEngine.usable([reasoned[1]], question: "is my launch ok?", web: false, hasHistory: false) { $0.contains("my") }
                .map(\.worker) == [.files, .reasoning], "a question matching the files always reads them")
    }

    @Test func notesKeepOnlyTheirPoints() {
        #expect(TeamEngine.trimmed("I can't look things up, but here's what I know.\n- Ubud is cheaper\n* Seminyak has beaches") == "- Ubud is cheaper\n* Seminyak has beaches")
        #expect(TeamEngine.trimmed("Ubud is usually cheaper.") == "Ubud is usually cheaper.")
        #expect(TeamEngine.trimmed("I'm sorry, but I can't assist with that.") == TeamEngine.nothingNoted)
    }

    @Test func notesStayShortAndCiteTheirSources() {
        let long = (1...40).map { "- fact number \($0) about the launch [\($0 % 3 + 1)]" }.joined(separator: "\n")
        #expect(ChatPrompt.estimate(TeamEngine.trimmed(long)) <= TeamEngine.noteBudget)
        #expect(TeamEngine.isNothing(" Nothing found.") && !TeamEngine.isNothing("- It costs $5 [1]"))
        let facts = [ResearchNote(question: 0, fact: "The venue holds 300 people", source: 1),
                     ResearchNote(question: 0, fact: "The venue holds 300 people.", source: 2)]
        #expect(TeamEngine.bullets(facts) == "- The venue holds 300 people [2]", "pool numbers, repeats once")
        #expect(TeamEngine.bullets([]) == TeamEngine.nothingNoted)
    }

    @Test func teamLogsLoadOldAndShowAsAnswersNotDocuments() throws {
        var report = ChatMessage(role: .friend, text: "# Report")
        report.research = ResearchLog(topic: "x", effort: .medium)
        let old = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(report))
        #expect(old.research?.isTeam == false && old.isDocument)
        var log = ResearchLog(topic: "y", effort: .low)
        log.team = true
        report.research = log
        #expect(!report.isDocument, "a team's answer is a chat bubble")
    }
}

struct TeamRunTests {
    /// The real model: two-part question, this chat's history and reasoning, one answer with the working kept.
    @MainActor @Test func aTeamAnswersFromItsNotes() async throws {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        let library = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var conversation = Conversation()
        conversation.messages = [
            ChatMessage(role: .user, text: "My budget for the trip is 800 dollars and I'm going to Bali for 5 days."),
            ChatMessage(role: .friend, text: "Nice! 800 dollars for 5 days in Bali works out to 160 a day."),
            ChatMessage(role: .user, text: "Given my budget, should I stay in Ubud or Seminyak, and what should I watch out for?"),
        ]
        let start = ContinuousClock.now
        let engine = TeamEngine(topic: conversation.messages[2].text, effort: nil, model: model, library: library, conversation: conversation,
                                chatInstructions: ChatPrompt.instructions(for: nil)) { _ in }
        let result = try await engine.answer(web: false)
        print("TEAM took", ContinuousClock.now - start, "steps:", result.log.steps.map(\.question))
        #expect(!result.answer.isEmpty)
        #expect(result.answer.contains("Ubud") || result.answer.contains("Seminyak"), "it answers what was asked")
        #expect((1...TeamEngine.maxTasks).contains(result.log.steps.count) && result.log.steps.allSatisfy(\.done))
        #expect(result.log.isTeam && result.log.finishedAt != nil)
        #expect(!result.log.steps.contains { $0.question.hasPrefix("Web") }, "the web is off")
    }

    /// Files are read from the shared pool, as research reads: facts with their source, a chip for the file.
    @MainActor @Test func filesAreReadIntoCitedFacts() async throws {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        let library = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var conversation = Conversation()
        library.add(text: "Launch plan. The launch event is on 14 November at the Grand Hall in Jakarta. Tickets cost 25 dollars. "
                    + "The venue holds 300 people. Catering is by Warung Kita.", name: "launch.txt", scope: .conversation(conversation.id))
        for _ in 0..<100 where library.documents(for: conversation.id).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        conversation.messages = [ChatMessage(role: .user, text: "From my launch plan, where and when is the event, and how much are tickets?")]
        let engine = TeamEngine(topic: conversation.messages[0].text, effort: nil, model: model, library: library, conversation: conversation,
                                chatInstructions: ChatPrompt.instructions(for: nil)) { _ in }
        let result = try await engine.answer(web: false)
        print("TEAM files:", result.log.steps.map { "\($0.question) => \($0.note ?? "-")" }, "ANSWER:", result.answer)
        #expect(result.answer.contains("Grand Hall") || result.answer.contains("14 November"))
        #expect(!result.answer.localizedCaseInsensitiveContains("sorry"), "the team found it, no refusal")
        #expect(result.sources.contains { $0.documentName.contains("Your files") }, "the file is a chip")
    }

    @Test func routerSendsMultiPartQuestionsToTheTeam() async {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        var misses: [String] = []
        for message in ["compare my notes on the launch plan with what the news says about the market",
                        "what are the pros and cons of renting vs buying a car for my budget, and which fits my plan better?"] {
            let route = await ChatRouter.route(message, recent: [], model: model)
            if ChatRouter.action(route, for: message, check: .valid) != .team { misses.append("\(message) → \(String(describing: route))") }
        }
        #expect(misses.count <= 1, "\(misses)")
    }
}
