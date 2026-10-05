import AppKit
import Foundation
import Testing
@testable import PetCore

@MainActor struct ScreenExplainerTests {
    /// A screenshot of some text, as a terminal shows it.
    static func screenshot(_ lines: [String]) -> Data {
        let font = NSFont.monospacedSystemFont(ofSize: 22, weight: .regular)
        let size = NSSize(width: 1100, height: 40 + 34 * lines.count)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 20, y: 20 + 34 * index), withAttributes: [.font: font, .foregroundColor: NSColor.black])
            }
            return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    static let error = ["Traceback (most recent call last):", "  File \"shop.py\", line 42, in total",
                        "    return price + tax", "TypeError: unsupported operand type(s) for +: 'int' and 'str'"]

    @Test func everyKindHasItsOwnShape() {
        let shapes = ScreenExplainer.Kind.allCases.map(ScreenExplainer.shape(for:))
        #expect(Set(shapes).count == shapes.count)
        #expect(ScreenExplainer.shape(for: .error).contains("How to fix"))
        #expect(ScreenExplainer.shape(for: .chart).contains("Takeaway"))
    }

    @Test func titleNamesWhatItIs() {
        #expect(ScreenExplainer.title(" A Python TypeError on line 42. ") == "Screenshot · A Python TypeError on line 42")
        #expect(ScreenExplainer.title("  ") == "Screenshot")
    }

    @Test func webExcerptsOnlyJoinThePromptWhenFound() {
        let glance = ScreenExplainer.Glance(kind: .error, what: "A Python TypeError", search: "TypeError unsupported operand int str")
        let offline = ScreenExplainer.prompt(glance, read: "TypeError")
        #expect(!offline.contains("Found on the web"))
        let pages = (1...5).map { WebSource(url: URL(string: "https://example.com/\($0)")!, title: "Page \($0)", text: String(repeating: "x", count: 2_000)) }
        let online = ScreenExplainer.prompt(glance, read: "TypeError", web: pages)
        #expect(online.contains("[example.com] Page 3") && !online.contains("Page 4"))
        #expect(online.count < offline.count + ScreenExplainer.webPages * (ScreenExplainer.webExcerpt + 60) + 200)
    }

    @Test func originKeepsOnlyTheSiteAndHidesPrivateWindows() {
        typealias Origin = ScreenExplainer.Origin
        #expect(Origin.domain(from: "https://www.GitHub.com/a/pull/42?token=secret#x") == "github.com")
        #expect(Origin.domain(from: "file:///Users/me/a.html") == nil)
        #expect(Origin.domain(from: "not a url") == nil)
        #expect(Origin(app: "Safari", title: "Pull request #42", domain: "github.com").line == "Safari · github.com · Pull request #42")
        #expect(Origin(app: "Terminal", title: "  ").line == "Terminal")
        #expect(Origin(app: "Chrome", title: "My bank", domain: "bank.com", hidden: true).line == "Chrome")
        let glance = ScreenExplainer.Glance(kind: .error, what: "A Python TypeError", search: "")
        #expect(ScreenExplainer.prompt(glance, read: "x", origin: Origin(app: "Terminal")).contains("Taken from (app · site · window title): Terminal"))
        #expect(!ScreenExplainer.prompt(glance, read: "x").contains("Taken from"))
    }

    @Test func readsTheTextInTheScreenshot() async throws {
        let read = try await ScreenExplainer.read(Self.screenshot(Self.error))
        #expect(read.contains("TypeError") && read.contains("line 42"))
        #expect(read.count <= ScreenExplainer.readBudget)
    }

    @Test func blankScreenshotSaysSo() async {
        await #expect(throws: ScreenExplainer.Failure.self) { try await ScreenExplainer.read(Self.screenshot([])) }
    }

    /// The whole turn on the real model: titled conversation, screenshot attached, an error-shaped explanation.
    @Test func explainsAnErrorIntoItsOwnConversation() async throws {
        let library = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let thread = ChatThread(Conversation(), library: library, friend: nil)
        guard thread.unavailable == nil else { return }
        thread.explain(screenshot: Self.screenshot(Self.error))
        for _ in 0..<600 where thread.state != .idle || thread.conversation.messages.count < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let messages = thread.conversation.messages
        #expect(thread.failure == nil)
        #expect(messages.count == 2 && messages[0].role == .user && messages[1].role == .friend)
        #expect(thread.conversation.title.hasPrefix("Screenshot"))
        #expect(messages[1].text.localizedCaseInsensitiveContains("fix"))
        let words = messages[1].text.split(whereSeparator: \.isWhitespace).count
        #expect(words <= ScreenExplainer.maxWords + 40, "short, at a glance: \(words) words")
        // Plain English: short sentences (with a little slack for the model) and no semicolons.
        let sentences = messages[1].text.split(whereSeparator: { ".!?\n".contains($0) })
        let longest = sentences.map { $0.split(whereSeparator: \.isWhitespace).count }.max() ?? 0
        #expect(longest <= ScreenExplainer.maxSentenceWords + 5, "longest sentence: \(longest) words")
        #expect(!messages[1].text.contains(";"))
        for _ in 0..<100 where library.attached(to: thread.conversation.id).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(library.attached(to: thread.conversation.id).count == 1)
        #expect(library.conversation(thread.conversation.id)?.messages.count == 2)
    }
}

@MainActor struct ExplainInboxTests {
    @Test func appAdoptsWhatTheShareExtensionSaved() throws {
        let container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let shared = ChatLibrary(root: container.appending(path: "Explained/\(UUID().uuidString)"))
        var conversation = Conversation()
        conversation.messages = [ChatMessage(role: .user, text: "Screenshot · Wi-Fi settings"), ChatMessage(role: .friend, text: "These are…")]
        shared.save(conversation)
        let app = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var changes: [ChatLibrary.Change] = []
        app.onChange = { changes.append($0) }
        ExplainInbox.adoptAll(into: app, container: container)
        #expect(app.conversation(conversation.id)?.messages.count == 2)
        #expect(changes.contains { $0.id == conversation.id }, "it syncs like any chat")
        let left = try FileManager.default.contentsOfDirectory(atPath: container.appending(path: "Explained").path)
        #expect(left.isEmpty)
    }
}
