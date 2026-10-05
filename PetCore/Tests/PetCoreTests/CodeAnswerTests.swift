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
        #expect(CodeAnswer.firstBlock(in: answer) == "package main\n\nfunc main() {}\n")
        #expect(CodeAnswer.firstBlock(in: "No code here.") == nil)
        #expect(CodeAnswer.isRequest(Self.goRequest) && CodeAnswer.isRequest("write a python script to rename files"))
        #expect(!CodeAnswer.isRequest("what is a script in theatre?"))
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

    /// Compiler Explorer directly, as the backend calls it (the backend isn't needed for the test).
    static let godbolt: CodeChecker = { language, source in
        let compiler = ["go": ("gl1260", "go"), "python": ("python314", "python"), "swift": ("swift640", "swift")][language]!
        var request = URLRequest(url: URL(string: "https://godbolt.org/api/compiler/\(compiler.0)/compile")!, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["source": source, "lang": compiler.1, "options": [
            "userArguments": "", "compilerOptions": ["executorRequest": true], "filters": ["execute": true]]])
        let (data, _) = try await URLSession.shared.data(for: request)
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        func text(_ lines: Any?) -> String { ((lines as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
        let build = reply["buildResult"] as? [String: Any]
        let built = (build?["code"] as? Int) == 0
        let ran = reply["didExecute"] as? Bool ?? false
        let exit = reply["code"] as? Int ?? -1
        let stdout = text(reply["stdout"]), stderr = text(reply["stderr"])
        let scriptFailed = ran && exit != 0 && stdout.isEmpty
        return CodeCheckResult(language: language, compiler: compiler.0, compiled: built && !scriptFailed,
                               errors: built ? (scriptFailed ? stderr : "") : text(build?["stderr"]), ran: ran, exitCode: exit,
                               stdout: stdout, stderr: stderr)
    }

    static func runLocally(_ code: String) -> String {
        guard FileManager.default.fileExists(atPath: "/opt/homebrew/bin/go"), !code.isEmpty else { return "" }
        let dir = FileManager.default.temporaryDirectory.appending(path: "measure-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? code.write(to: dir.appending(path: "main.go"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/go")
        process.arguments = ["run", "main.go"]
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The measurement (M40): the user's Go request on Apple's model, planned, written, checked and fixed on the
    /// real Compiler Explorer. Baseline before M40: 0 of 3 compiled.
    @MainActor @Test func theAppleModelsGoProgramIsCheckedAndFixed() async throws {
        guard SystemLanguageModel.default.isAvailable, ProcessInfo.processInfo.environment["CODE_MEASURE"] != nil else { return }
        var works = 0, correct = 0
        for trial in 1...12 {
            let writer = CodeWriter(brain: .onDevice, checker: Self.godbolt) { _ in }
            guard let outcome = try? await writer.write(Self.goRequest, earlier: "") else { print("MEASURE \(trial): refused"); continue }
            // Godbolt cuts long output (the odd list alone is ~25,000 characters): judge the full run, on this Mac.
            let squeezed = Self.runLocally(outcome.file.map { String(decoding: $0.data, as: UTF8.self) } ?? "").replacingOccurrences(of: #"[\[\],]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let right = squeezed.contains("1 3 5 7 9 11") && squeezed.contains("2 4 6 8 10 12") && squeezed.contains("2 3 5 7 11 13 17")
            works += outcome.works ? 1 : 0
            correct += right && outcome.works ? 1 : 0
            print("MEASURE \(trial): works=\(outcome.works) right=\(right) file=\(outcome.file?.name ?? "-")")
            if outcome.works && !right {
                let lines = Self.runLocally(outcome.file.map { String(decoding: $0.data, as: UTF8.self) } ?? "").split(separator: "\n")
                print("MEASURE wrong: " + lines.map { String($0.prefix(70)) }.joined(separator: " | "))
            }
            if !outcome.works { print("MEASURE errors: " + String((outcome.result?.errors ?? "unchecked").prefix(200)).replacingOccurrences(of: "\n", with: " | ")) }
        }
        print("MEASURE TOTAL: works \(works)/12, right \(correct)/12")
    }
}

@MainActor struct CodeWriterTests {
    static func model(_ replies: [String]) -> (Brain, Box<Int>) {
        let host = "nine-\(UUID().uuidString.lowercased()).test", calls = Box(0)
        NineRouterStub.serve(host: host) { _, _ in
            defer { calls.value += 1 }
            let reply = replies[min(calls.value, replies.count - 1)]
            return (200, NineRouterTests.json(["choices": [["message": ["content": reply]]]]))
        }
        return (.nine(ChosenModel(name: "m", limits: ModelLimits(), config: .init(baseURL: URL(string: "http://\(host)/v1")!))), calls)
    }

    static let spec = #"{"language":"Go","input":"none","outputs":["odd numbers","even numbers"],"steps":["loop","print"]}"#

    @Test func errorsGoBackUntilItRunsAndTheOutputIsShown() async throws {
        let (brain, _) = Self.model([Self.spec, "```go\nbroken\n```", "```go\nfixed\n```"])
        let seen = Box<[String]>([])
        let checker: CodeChecker = { language, source in
            let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            seen.value.append(source)
            return source == "fixed" ? CodeCheckResult(language: language, compiler: "x86-64 gc 1.26.0", compiled: true, ran: true, stdout: "odd [1 3 5]")
                : CodeCheckResult(language: language, compiled: false, errors: "./example.go:5:2: undefined: sort")
        }
        let outcome = try await CodeWriter(brain: brain, checker: checker) { _ in }.write("create a go file as main.go that prints odd numbers", earlier: "")
        #expect(seen.value == ["broken", "fixed"] && outcome.works && outcome.checked)
        #expect(outcome.markdown.contains("```go\nfixed\n```") && outcome.markdown.contains("Run it with `go run main.go`"))
        #expect(outcome.markdown.contains("**Ran it** (x86-64 gc 1.26.0):") && outcome.markdown.contains("odd [1 3 5]"))
        #expect(outcome.markdown.contains("Checked on Compiler Explorer"))
        #expect(outcome.file?.name == "main.go" && String(decoding: outcome.file!.data, as: UTF8.self).trimmingCharacters(in: .newlines) == "fixed")
    }

    @Test func itGivesUpAfterThreeFixesAndSaysSo() async throws {
        let (brain, _) = Self.model([Self.spec, "```go\nbroken\n```"])
        let checks = Box(0)
        let checker: CodeChecker = { language, _ in
            checks.value += 1
            return CodeCheckResult(language: language, compiled: false, errors: "./example.go:1:1: expected 'package'")
        }
        let outcome = try await CodeWriter(brain: brain, checker: checker) { _ in }.write("write a go program that prints hi", earlier: "")
        #expect(checks.value == CodeWriter.maxFixes + 1 && !outcome.works)
        #expect(outcome.markdown.contains("**It still doesn't compile:**") && outcome.file == nil, "no file named, none attached")
    }

    @Test func withoutACheckerItsTheCodeAsWritten() async throws {
        let (brain, _) = Self.model([Self.spec, "```go\npackage main\n```"])
        let outcome = try await CodeWriter(brain: brain, checker: nil) { _ in }.write("write a go program", earlier: "")
        #expect(!outcome.checked && !outcome.markdown.contains("Compiler Explorer") && outcome.markdown.hasPrefix("```go\npackage main\n```"))
    }
}
