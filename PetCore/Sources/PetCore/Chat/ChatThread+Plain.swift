//
//  ChatThread+Plain.swift
//  PetCore
//
//  A chat turn on the user's own model (M37), and the offers under answers (M32, M37): the web, deep research, and
//  "Answer on this Mac" when 9Router couldn't answer.
//

import Foundation
import os

extension ChatThread {
    /// One streamed call to the user's own model with the whole conversation and its files (M37). If it can't
    /// answer, the friend says why and offers Apple's model; nothing switches on its own.
    func plainAnswer(_ question: String, chosen: ChosenModel) async {
        defer { if !Task.isCancelled { state = .idle } }
        justFound = []
        unreadSites = []
        let sources = PlainChat.sources(library.documents(for: conversation.id), question: question)
        let request = PlainChat.messages(instructions: instructions, history: Array(conversation.messages.dropLast()), sources: sources,
                                         question: question, limit: chosen.limits.limit)
        var text = ""
        do {
            state = .answering("")
            for try await snapshot in NineRouter(chosen.config).stream(request.messages, model: chosen.name, maxTokens: request.answerTokens) {
                guard !Task.isCancelled else { break }
                text = snapshot
                state = .answering(text)
            }
        } catch is CancellationError {
        } catch {
            Self.log.error("9Router answer failed: \(String(describing: error), privacy: .public)")
            guard text.isEmpty else { return notice = error.localizedDescription }
            var reply = ChatMessage(role: .friend, text: (error as? LocalizedError)?.errorDescription ?? Self.message(for: error), aside: true)
            reply.offer = .onDevice
            return finishTurn(reply)
        }
        guard !text.isEmpty else { return }
        var reply = ChatMessage(role: .friend, text: text)
        reply.model = chosen.name
        conversation.messages.append(reply)
        let sent = request.messages.map { ContextBudget.estimate($0.text) }.reduce(0, +) + ContextBudget.estimate(text)
        meter([AgentUse(name: chosen.name, tokens: sent)])
        library.save(conversation)
    }


    /// The question the friend's `answer` replied to, and where that answer is.
    func asked(before answer: UUID) -> (question: ChatMessage, at: Int)? {
        guard let at = conversation.messages.firstIndex(where: { $0.id == answer }),
              let question = conversation.messages[..<at].last(where: { $0.role == .user }) else { return nil }
        return (question, at)
    }

    /// The offer under a failed 9Router answer, taken (M37): the question again, on Apple's model this once.
    public func answerOnDevice(answering answer: UUID) {
        guard let asked = asked(before: answer) else { return }
        onDeviceOnce = true // read (and cleared) as the turn starts
        resend(from: asked.question.id, as: asked.question.text)
    }

    /// The offer under an answer, taken (M32): the question again, this time searching the web.
    public func searchWeb(answering answer: UUID) {
        guard let asked = asked(before: answer) else { return }
        resend(from: asked.question.id, as: asked.question.text, web: true)
    }

    /// The offer under an answer, taken (M32): deep research on its question. The answer stays, without the offer.
    public func deepResearch(answering answer: UUID, effort: ResearchEffort) {
        guard state == .idle, let asked = asked(before: answer) else { return }
        conversation.messages[asked.at].offer = nil
        research(asked.question.text, effort: effort, typed: "Deep research: " + asked.question.text)
    }
}
