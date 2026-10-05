import Foundation
import FoundationModels
import Testing
@testable import PetCore

struct ChatRouterTests {
    @Test func routesBecomeActions() {
        #expect(ChatRouter.action(.calendarFile, for: "", check: .valid) == .file(.ics))
        #expect(ChatRouter.action(.diagram, for: "", check: .valid) == .diagram)
        #expect(ChatRouter.action(.web, for: "", check: .valid) == .web)
        // "Unclear" only stops a borderline message; real words stay a question.
        #expect(ChatRouter.action(.unclear, for: "", check: .unsure) == .clarify)
        #expect(ChatRouter.action(.unclear, for: "", check: .valid) == .answer)
    }

    @Test func noRouteFallsBackToTheKeywords() {
        #expect(ChatRouter.action(nil, for: "Can you make a CSV of the budget?", check: .valid) == .file(.csv))
        #expect(ChatRouter.action(nil, for: "Draw a flowchart of how login works", check: .valid) == .diagram)
        #expect(ChatRouter.action(nil, for: "what is a flowchart?", check: .valid) == .answer)
    }

    /// The real model on labelled messages: at most one miss.
    @Test func routesRealMessages() async {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        let cases: [(String, ChatRouter.Action)] = [
            ("make a CSV of my monthly budget", .file(.csv)),
            ("draw a flowchart of how the login works", .diagram),
            ("what's the weather in Jakarta today?", .web),
            ("compare the best budget laptops this year across reviews", .research),
            ("what is recursion?", .answer),
            ("thanks, that helped!", .answer),
            ("what's in the PDF I attached?", .answer),
            ("add the launch meeting on Friday to my calendar", .file(.ics)),
            ("hi!", .answer),
            ("how do I split the bill 3 ways with tip?", .answer),
        ]
        var misses: [String] = []
        for (message, expected) in cases {
            let route = await ChatRouter.route(message, recent: [], model: model)
            let action = ChatRouter.action(route, for: message, check: .valid)
            if action != expected { misses.append("\(message) → \(action)") }
        }
        // A follow-up knows what "that" is from the messages before it.
        let earlier = [ChatMessage(role: .user, text: "summarize my trip notes"), ChatMessage(role: .friend, text: "Day 1: Bali. Day 2: Ubud. Day 3: Nusa Penida.")]
        let followUp = await ChatRouter.route("now make that a PDF", recent: earlier, model: model)
        if ChatRouter.action(followUp, for: "now make that a PDF", check: .valid) != .file(.pdf) { misses.append("follow-up → \(String(describing: followUp))") }
        #expect(misses.count <= 1, "\(misses)")
    }
}
