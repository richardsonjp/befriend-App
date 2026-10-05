//
//  CodeAnswer.swift
//  PetCore
//
//  Asked for code (M40): the answer is complete code that runs, not a sketch, with room to finish it; and a file
//  the user named ("create a go file as main.go") comes attached, ready to save.
//

import Foundation

public nonisolated enum CodeAnswer {
    /// Put to the model with the question: the small model drops imports and mixes types unless told.
    static let note = """
        This asks for code. Write complete code that runs as it is: every import or package it uses, types that \
        match (convert between int and float where needed), no placeholders or "..." left to fill in. Put it in one \
        fenced block tagged with its language, then one short line on how to run it.
        """

    /// Under code from Apple's model: it's small, so its code needs a look before it runs.
    static let onDeviceNotice = "Written by the small on-device model: check it before you run it. A 9Router model (Models…) writes code more reliably."

    /// Code file extensions, for the file a request names.
    static let extensions = [
        "go", "py", "swift", "js", "ts", "jsx", "tsx", "rs", "java", "kt", "kts", "c", "h", "cpp", "hpp", "cc", "cs", "rb",
        "php", "sh", "bash", "zsh", "sql", "html", "css", "scss", "lua", "dart", "r", "m", "pl", "ex", "exs", "scala", "vue",
        "yaml", "yml", "toml", "json", "xml",
    ]

    /// The file a request names ("as main.go", "in utils.py"), if any.
    static func fileName(in request: String) -> String? {
        let pattern = #"(?<![\w./-])([A-Za-z0-9_][\w-]*\.("# + extensions.joined(separator: "|") + #"))(?![\w-])"#
        guard let match = request.range(of: pattern, options: .regularExpression) else { return nil }
        return String(request[match])
    }

    /// The first fenced code block's contents.
    static func firstBlock(in answer: String) -> String? {
        guard let open = answer.range(of: "```") else { return nil }
        let body = answer[open.upperBound...].drop { $0 != "\n" }.dropFirst()
        guard let close = body.range(of: "```") else { return nil }
        let code = String(body[..<close.lowerBound])
        return code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : code
    }

    /// The named file, holding the answer's code, when the request named one.
    static func file(for request: String, answer: String) -> ChatFile? {
        guard let name = fileName(in: request), let code = firstBlock(in: answer) else { return nil }
        return ChatFile(name: name, format: .txt, data: Data(code.utf8))
    }
}
