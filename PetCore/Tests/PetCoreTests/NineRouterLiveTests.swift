import AppKit
import Foundation
import FoundationModels
import Testing
@testable import PetCore

/// Against a real 9Router on this Mac. Runs only with NINEROUTER_KEY set (the key never lives in the code). Tried
/// 2026-10-05: Antigravity (ag/) models do it all; Cursor (cu/) models act as a coding agent and refuse prompts about
/// files ("unsupported IDE tool"), so they don't suit befriend.
///   NINEROUTER_KEY=… NINEROUTER_MODELS=cu/a,ag/b swift test --filter NineRouterLive
@MainActor struct NineRouterLiveTests {
    static let key = ProcessInfo.processInfo.environment["NINEROUTER_KEY"]
    static let models = (ProcessInfo.processInfo.environment["NINEROUTER_MODELS"] ?? "ag/gemini-3.8-flash-low,ag/gemini-3.7-flash-medium")
        .split(separator: ",").map(String.init)
    static var config: NineRouter.Config { .init(apiKey: key) }

    static func chosen(_ model: String, seesImages: Bool = false) -> ChosenModel {
        ChosenModel(name: model, limits: ModelLimits(limit: 100_000, seesImages: seesImages), config: config)
    }

    @Test func listsModelsAndStreamsAndStructures() async throws {
        guard Self.key != nil else { return }
        let router = NineRouter(Self.config)
        let listed = try await router.models()
        print("LIVE models:", listed.count)
        for model in Self.models {
            #expect(listed.contains { $0.id == model }, "\(model) is listed")
            var streamed = ""
            for try await text in router.stream([.init(.user, "Count from 1 to 5, digits and spaces only.")], model: model, maxTokens: 40) { streamed = text }
            print("LIVE \(model) stream:", streamed.prefix(60))
            #expect(streamed.contains("3"), "\(model) streams")
            do {
                let glance = try await router.respond([.init(.user, "What is this part of a screen?\nTypeError: unsupported operand type(s) for +: 'int' and 'str' (shop.py, line 42)")],
                                                      model: model, generating: ScreenExplainer.Glance.self)
                print("LIVE \(model) structured:", glance.kind, "·", glance.what)
                #expect(glance.kind == .error || glance.kind == .code, "\(model) reads it as an error")
            } catch {
                Issue.record("\(model) structured failed: \(error)")
            }
        }
    }

    @Test func aChatTurnAndAnExplainAndAReport() async throws {
        guard Self.key != nil, let model = Self.models.first else { return }
        let settings = ModelSettings(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!, secret: InMemorySecret(Self.key))
        settings.choose(.model(model), for: .chat)
        settings.choose(.model(model), for: .explain)
        settings.setLimits(ModelLimits(limit: 100_000, seesImages: true), for: model)
        let library = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let thread = ChatThread(Conversation(), library: library, friend: nil)
        thread.settings = settings

        // Chat: a file in the box, sent with the question.
        library.add(text: "Launch plan. The launch party is on 14 November at the Grand Hall in Jakarta. Tickets cost 25 dollars.",
                    name: "plan.txt", scope: .draft(thread.conversation.id))
        for _ in 0..<100 where library.items(in: .draft(thread.conversation.id)).contains(where: \.isWorking) { try await Task.sleep(for: .milliseconds(50)) }
        thread.send("From my plan: where is the launch party, and how much are tickets?")
        for _ in 0..<1200 where thread.state != .idle || thread.conversation.messages.last?.role != .friend { try await Task.sleep(for: .milliseconds(100)) }
        let chat = try #require(thread.conversation.messages.last)
        print("LIVE chat via \(chat.model ?? "-"):", chat.text.prefix(200))
        #expect(chat.model == model && chat.text.contains("Grand Hall") && chat.text.contains("25"), "\(chat.text)")

        // Explain: a chart with no text, seen as an image.
        let explainThread = ChatThread(Conversation(), library: library, friend: nil)
        explainThread.settings = settings
        explainThread.explain(screenshot: Self.barChart())
        for _ in 0..<1200 where explainThread.state != .idle || (explainThread.conversation.messages.last?.role != .friend && explainThread.failure == nil) {
            try await Task.sleep(for: .milliseconds(100))
        }
        print("LIVE explain title:", explainThread.conversation.title, "· failure:", explainThread.failure ?? "-")
        print("LIVE explain:", explainThread.conversation.messages.last?.text.prefix(240) ?? "-")
        #expect(explainThread.failure == nil && explainThread.conversation.messages.last?.model == model)

        // Research: the plan and the whole report on the model (sources gathered live).
        let engine = TeamEngine(topic: "the James Webb Space Telescope", effort: .low, model: .default, library: library, conversation: Conversation()) { _ in }
        engine.chosen = Self.chosen(model)
        let start = ContinuousClock.now
        let report = try await engine.report()
        print("LIVE report in", ContinuousClock.now - start, "· sources", report.log.sources.count, "· cited", report.sources.count,
              "· calls", engine.uses.map(\.name))
        print("LIVE report headings:", report.report.split(separator: "\n").filter { $0.hasPrefix("#") })
        #expect(report.report.contains("## Summary") && report.report.contains("## Sources") && !report.sources.isEmpty)
    }

    /// Three bars, no text: only a model that sees it can say what it is.
    static func barChart() -> Data {
        let size = NSSize(width: 600, height: 400)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
            NSColor.black.setFill(); NSRect(x: 40, y: 40, width: 520, height: 3).fill(); NSRect(x: 40, y: 40, width: 3, height: 320).fill()
            for (index, height) in [80.0, 160, 300].enumerated() {
                NSColor.systemBlue.setFill()
                NSRect(x: 90 + Double(index) * 160, y: 43, width: 100, height: height).fill()
            }
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}
