//
//  ChatRouter.swift
//  PetCore
//
//  Which agent takes a chat message (M32): one typed call on the on-device model picks answer, web, research, a file,
//  a diagram, or "unclear". It replaces the keyword detectors and the guardrail's model check; the instant gibberish
//  check stays in front, and /commands still force a path.
//

import Foundation
import FoundationModels

public nonisolated enum ChatRouter {
    @Generable
    public enum Route: String, CaseIterable, Sendable {
        case answer, web, research, diagram, unclear
        case csvFile, jsonFile, calendarFile, pdfFile, htmlFile, markdownFile, textFile
    }

    @Generable
    struct Routing {
        @Guide(description: "true only if the message asks to make or add something new (a file, a diagram, an event in the calendar); false when it asks about or reads something the user already has")
        var creates: Bool
        @Guide(description: "Which helper takes the message")
        var route: Route
    }

    /// What the chat does with a message.
    public enum Action: Equatable, Sendable {
        case answer
        /// Needs fresh or outside facts (news, prices, weather, a named product or site).
        case web
        /// Asks for a broad, many-source investigation.
        case research
        case file(ChatFileFormat)
        case diagram
        case clarify
    }

    static let instructions = """
        You route a chat message to the helper that should take it. Pick one:
        answer: a question or chat the friend can answer from what it knows or the user's files ("what is recursion?", "thanks!", "summarize my notes").
        web: needs current or outside facts: news, prices, weather, scores, a named product, company or website ("weather in Jakarta today", "latest iPhone price").
        research: asks for a broad investigation across many sources ("compare the best budget laptops this year", "research the EV market in Indonesia").
        diagram: asks to draw a flowchart, mind map, timeline, gantt, pie chart or sequence diagram ("draw how login works").
        csvFile, jsonFile, calendarFile, pdfFile, htmlFile, markdownFile, textFile: asks to make that kind of file ("make a CSV of my budget", "add the launch to my calendar", "export this as a PDF").
        unclear: random letters or words that mean nothing.
        Only a request to make something picks a file or diagram; mentioning one ("what's in this PDF?") is answer.
        """

    /// The route, from the message and the last messages before it (so "make that a PDF" knows what "that" is).
    /// Nil when the model can't answer.
    static func route(_ message: String, recent: [ChatMessage], model: SystemLanguageModel) async -> Route? {
        let context = recent.filter { !$0.isAside }.suffix(2)
            .map { "\($0.role == .user ? "User" : "Friend"): \(PetBrain.quote($0.text, 200))" }.joined(separator: "\n")
        let prompt = (context.isEmpty ? "" : "Earlier:\n\(context)\n\n") + "Message: \"\(PetBrain.quote(message, 400))\""
        let session = LanguageModelSession(model: model, instructions: instructions)
        guard let routing = try? await session.respond(to: prompt, generating: Routing.self).content else { return nil }
        // Asking about a file isn't asking for one ("what's in the PDF I attached?" picked pdfFile every time).
        // The keyword detectors vouch for what the model misses ("add the meeting to my calendar" isn't "creating").
        let vouched = routing.creates || FileIntent.detect(message) != nil || DiagramIntent.detect(message)
        return vouched || !makesSomething(routing.route) ? routing.route : .answer
    }

    static func makesSomething(_ route: Route) -> Bool {
        ![.answer, .web, .research, .unclear].contains(route)
    }

    /// What to do. `check` is the instant guardrail's verdict: "unclear" only stops a borderline message (real words
    /// stay a question). No route (the model failed) falls back to the keyword detectors.
    static func action(_ route: Route?, for message: String, check: MessageCheck) -> Action {
        guard let route else {
            // ponytail: the old keyword detectors, kept only as the fallback when the routing call fails.
            if DiagramIntent.detect(message), FileIntent.detect(message) == nil { return .diagram }
            return FileIntent.detect(message).map(Action.file) ?? .answer
        }
        switch route {
        case .answer: return .answer
        case .web: return .web
        case .research: return .research
        case .diagram: return .diagram
        case .unclear: return check == .unsure ? .clarify : .answer
        case .csvFile: return .file(.csv)
        case .jsonFile: return .file(.json)
        case .calendarFile: return .file(.ics)
        case .pdfFile: return .file(.pdf)
        case .htmlFile: return .file(.html)
        case .markdownFile: return .file(.md)
        case .textFile: return .file(.txt)
        }
    }
}
