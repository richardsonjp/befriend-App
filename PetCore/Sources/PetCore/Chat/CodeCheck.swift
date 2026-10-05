//
//  CodeCheck.swift
//  PetCore
//
//  Code that runs (M40). A code answer is planned (an exact spec), written to the spec, then compiled with the real
//  compiler on Compiler Explorer through befriend's backend: errors go back to the model to fix, and once it builds
//  it runs once there, in Compiler Explorer's sandbox. Only the code block leaves the device.
//

import Foundation
import FoundationModels

/// What the backend's Compiler Explorer check said (`POST /api/code/check`).
public nonisolated struct CodeCheckResult: Codable, Equatable, Sendable {
    public var language: String
    public var compiler: String
    public var compiled: Bool
    public var errors: String
    public var ran: Bool
    public var exitCode: Int
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(language: String = "", compiler: String = "", compiled: Bool, errors: String = "", ran: Bool = false,
                exitCode: Int = 0, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.language = language
        self.compiler = compiler
        self.compiled = compiled
        self.errors = errors
        self.ran = ran
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Checks code (language as the backend names it, source) and runs it once when it builds.
public typealias CodeChecker = @Sendable (_ language: String, _ source: String) async throws -> CodeCheckResult

public nonisolated enum CodeCheck {
    /// The app's checker, set once it's signed in (the backend needs the session); nil checks nothing.
    @MainActor public static var checker: CodeChecker?

    /// "Check code on Compiler Explorer": on unless turned off.
    static let settingKey = "code.check"
    public static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    /// Languages the backend checks, from a fence tag, a file extension or the spec's word for it.
    static let languages: [String: String] = [
        "go": "go", "golang": "go", "python": "python", "py": "python", "python3": "python", "swift": "swift",
        "rust": "rust", "rs": "rust", "c": "c", "cpp": "cpp", "c++": "cpp", "cc": "cpp", "cxx": "cpp", "java": "java",
        "kotlin": "kotlin", "kt": "kotlin", "ruby": "ruby", "rb": "ruby", "csharp": "csharp", "c#": "csharp", "cs": "csharp",
    ]

    static func language(_ word: String?) -> String? {
        guard let word = word?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty else { return nil }
        return languages[word] ?? languages[word.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#")).inverted).first ?? ""]
    }

    /// How to run it, under the code.
    static let runHints: [String: String] = [
        "go": "go run %@", "python": "python3 %@", "swift": "swift %@", "rust": "rustc %@ && ./main", "c": "cc %@ && ./a.out",
        "cpp": "c++ %@ && ./a.out", "java": "java %@", "kotlin": "kotlinc %@ -include-runtime -d main.jar && java -jar main.jar",
        "ruby": "ruby %@", "csharp": "dotnet run",
    ]

    static let fileExtensions: [String: String] = [
        "go": "go", "python": "py", "swift": "swift", "rust": "rs", "c": "c", "cpp": "cpp", "java": "java", "kotlin": "kt",
        "ruby": "rb", "csharp": "cs",
    ]
}

extension APIClient {
    /// Compiles `source` on Compiler Explorer through the backend and runs it once when it builds.
    public func checkCode(language: String, source: String) async throws -> CodeCheckResult {
        struct Body: Encodable {
            let language: String
            let source: String
            let run: Bool
        }
        return try await send("POST", "code/check", body: Body(language: language, source: source, run: true), timeout: 120)
    }
}

// MARK: Writing it

@Generable
struct CodeSpec {
    @Guide(description: "The programming language, e.g. Go or Python")
    var language: String
    @Guide(description: "What the program takes in, exactly as asked")
    var input: String
    @Guide(description: "Every output the request asks for, one item each, exactly as asked (e.g. 'the odd numbers from 1 to 9999 as an array')")
    var outputs: [String]
    @Guide(description: "The program's steps in order, one short line each")
    var steps: [String]
}

/// Plans, writes, checks and fixes one code answer (M40), on either model.
@MainActor
final class CodeWriter {
    static let maxFixes = 3

    static let specInstructions = """
        You turn a request for a program into an exact specification. List every output the request asks for, \
        separately. If the language isn't named, pick the one the request implies.
        """
    static let writerInstructions = """
        You write a complete program for a specification. Write your own small helper functions (like isPrime) with \
        plain loops and arithmetic instead of library functions, except for printing. Include every import the code \
        uses and nothing it doesn't. No placeholders. Reply with the code in one fenced block tagged with its \
        language, and nothing else.
        """
    static let fixerInstructions = """
        You fix code so it compiles and runs. Fix exactly the errors given and keep everything else. Reply with the \
        complete corrected code in one fenced block, and nothing else.
        """

    struct Outcome {
        var markdown: String
        var file: ChatFile?
        /// Checked on Compiler Explorer and it built (and ran).
        var works: Bool
        var checked: Bool
        /// What Compiler Explorer said last, in full.
        var result: CodeCheckResult?
    }

    let brain: Brain
    /// Writes and fixes the code. On Apple's model with the permissive guardrails: the default ones refused a
    /// quarter of plain number-listing programs as "unsafe" (3 of 12 measured).
    let coder: Brain
    let checker: CodeChecker?
    let status: (String) -> Void

    init(brain: Brain, checker: CodeChecker?, status: @escaping (String) -> Void) {
        self.brain = brain
        if case .apple = brain { coder = .apple(SystemLanguageModel(guardrails: .permissiveContentTransformations)) } else { coder = brain }
        self.checker = checker
        self.status = status
    }

    /// The code for `request`; `earlier` is the last messages, for follow-ups ("now print it as JSON").
    func write(_ request: String, earlier: String) async throws -> Outcome {
        status("Planning the code…")
        let spec = try? await brain.respond(instructions: Self.specInstructions, prompt: earlier + "Request: " + request,
                                            schema: CodeSpec.generationSchema)
        let specText = spec.flatMap { try? CodeSpec($0) }.map(Self.text) ?? "Request: " + request
        status("Writing the code…")
        let first = try await coder.respond(instructions: Self.writerInstructions,
                                            prompt: earlier + "Write the program for this specification.\n\n" + specText)
        var code = CodeAnswer.firstBlock(in: first) ?? first
        let fence = Self.fenceTag(in: first)
        let language = CodeCheck.language(fence) ?? CodeCheck.language(spec.flatMap { try? CodeSpec($0) }?.language)
            ?? CodeAnswer.fileName(in: request).flatMap { CodeCheck.language(($0 as NSString).pathExtension) }

        var result: CodeCheckResult?
        if let checker, let language {
            var fixes = 0
            while true {
                status(fixes == 0 ? "Checking it on Compiler Explorer…" : "Checking the fix (\(fixes) of \(Self.maxFixes))…")
                guard let checked = try? await checker(language, code) else { break }
                result = checked
                guard !checked.compiled, fixes < Self.maxFixes, !checked.errors.isEmpty else { break }
                fixes += 1
                status("Fixing: " + (checked.errors.split(separator: "\n").first { $0.contains(":") }.map(String.init) ?? "the errors"))
                let fix = specText + "\n\nCode:\n```" + (fence ?? language) + "\n" + code + "\n```\n\nThe compiler says:\n"
                    + String(checked.errors.prefix(1500))
                guard let reply = try? await coder.respond(instructions: Self.fixerInstructions, prompt: fix) else { break }
                code = CodeAnswer.firstBlock(in: reply) ?? reply
            }
        }
        let name = CodeAnswer.fileName(in: request) ?? language.flatMap { CodeCheck.fileExtensions[$0] }.map { "main." + $0 }
        let markdown = Self.markdown(code: code, fence: fence ?? language ?? "", file: name, language: language, result: result)
        let file = name.map { ChatFile(name: $0, format: .txt, data: Data(code.utf8)) }
        return Outcome(markdown: markdown, file: CodeAnswer.fileName(in: request) == nil ? nil : file,
                       works: result?.compiled == true, checked: result != nil, result: result)
    }

    static func text(_ spec: CodeSpec) -> String {
        "Language: \(spec.language)\nInput: \(spec.input)\nOutputs, each separately:\n" + spec.outputs.map { "- \($0)" }.joined(separator: "\n")
            + "\nSteps:\n" + spec.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    static func fenceTag(in reply: String) -> String? {
        guard let open = reply.range(of: "```") else { return nil }
        let tag = reply[open.upperBound...].prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return tag.isEmpty ? nil : tag
    }

    /// The answer: the code, how to run it, and what Compiler Explorer said.
    static func markdown(code: String, fence: String, file: String?, language: String?, result: CodeCheckResult?) -> String {
        var parts = ["```\(fence)\n\(code.trimmingCharacters(in: .newlines))\n```"]
        if let language, let hint = CodeCheck.runHints[language], let file {
            parts.append("Run it with `\(hint.replacingOccurrences(of: "%@", with: file))`.")
        }
        guard let result else { return parts.joined(separator: "\n\n") }
        if result.compiled, result.ran {
            let output = (result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Each line on its own: a program printing three long arrays still shows the start of each.
            let shown = output.split(separator: "\n", omittingEmptySubsequences: false).prefix(30)
                .map { $0.count > 240 ? $0.prefix(240) + " …" : $0 }.joined(separator: "\n")
            let ending = result.timedOut ? " It ran out of time." : result.exitCode == 0 ? "" : " It exited with code \(result.exitCode)."
            parts.append("**Ran it**" + (result.compiler.isEmpty ? "" : " (\(result.compiler))") + ":" + ending + "\n```text\n"
                         + (shown.isEmpty ? "(no output)" : shown) + "\n```")
        } else if result.compiled {
            parts.append("**It compiles**" + (result.compiler.isEmpty ? "" : " (\(result.compiler))") + ".")
        } else {
            parts.append("**It still doesn't compile:**\n```text\n" + String(result.errors.prefix(1500)) + "\n```")
        }
        parts.append("_Checked on Compiler Explorer (godbolt.org)._")
        return parts.joined(separator: "\n\n")
    }
}
