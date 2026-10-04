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
        for _ in 0..<100 where library.attached(to: thread.conversation.id).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(library.attached(to: thread.conversation.id).count == 1)
        #expect(library.conversation(thread.conversation.id)?.messages.count == 2)
    }
}
