import Foundation
import FoundationModels
import Testing
@testable import PetCore

struct CodeAnswerTests {
    static let goRequest = "create a go code file as main.go\ncreate a code in which it is trying to return an output of all odd and even and prime number between an input of 1-9999 numbers as an array"

    @Test func codeFileNamesAreNotWebsites() {
        #expect(WebSearch.links(in: Self.goRequest).isEmpty, "main.go is a file")
        #expect(WebSearch.links(in: "fix lib.rs and app.css, then query.sql").isEmpty)
        #expect(WebSearch.links(in: "what does openai.com say?").map(\.absoluteString) == ["https://openai.com"])
        #expect(WebSearch.links(in: "see https://lib.rs").map(\.absoluteString) == ["https://lib.rs"], "typed as a link, it is one")
        #expect(WebSearch.links(in: "read tokopedia.co.id").map(\.absoluteString) == ["https://tokopedia.co.id"])
    }

    @Test func theNamedFileHoldsTheCode() throws {
        #expect(CodeAnswer.fileName(in: Self.goRequest) == "main.go")
        #expect(CodeAnswer.fileName(in: "write a script in rename_files.py please") == "rename_files.py")
        #expect(CodeAnswer.fileName(in: "write a function that adds numbers") == nil)
        let answer = "Here it is:\n```go\npackage main\n\nfunc main() {}\n```\nRun it with `go run main.go`."
        let file = try #require(CodeAnswer.file(for: Self.goRequest, answer: answer))
        #expect(file.name == "main.go" && String(decoding: file.data, as: UTF8.self) == "package main\n\nfunc main() {}\n")
        #expect(CodeAnswer.file(for: Self.goRequest, answer: "No code here.") == nil)
    }

    @Test func theRouterSendsCodeRequestsToCode() async {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        var misses: [String] = []
        for message in [Self.goRequest, "write a python script that renames every file in a folder", "create a swift function that reverses a string"] {
            let route = await ChatRouter.route(message, recent: [], model: model)
            if ChatRouter.action(route, for: message, check: .valid) != .code { misses.append("\(message.prefix(40)) → \(String(describing: route))") }
        }
        #expect(misses.count <= 1, "\(misses)")
    }

    /// The real model, end to end: the code comes back whole, with main.go attached.
    @MainActor @Test func aGoProgramComesWithItsFile() async throws {
        let library = ChatLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let thread = ChatThread(Conversation(), library: library, friend: nil)
        guard thread.unavailable == nil else { return }
        thread.settings = ModelSettings(defaults: UserDefaults(suiteName: "code-\(UUID().uuidString)")!, secret: InMemorySecret())
        thread.send(Self.goRequest)
        for _ in 0..<1200 where thread.state != .idle || thread.conversation.messages.last?.role != .friend { try await Task.sleep(for: .milliseconds(100)) }
        let reply = try #require(thread.conversation.messages.last)
        let file = try #require(reply.files?.first, "\(reply.text)")
        #expect(file.name == "main.go")
        let code = String(decoding: file.data, as: UTF8.self)
        let out = FileManager.default.temporaryDirectory.appending(path: "befriend-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try code.write(to: out.appending(path: "main.go"), atomically: true, encoding: .utf8)
        print("CODE at", out.path(), "\n", code)
        #expect(code.contains("package main") && code.contains("func main()"))
    }
}
