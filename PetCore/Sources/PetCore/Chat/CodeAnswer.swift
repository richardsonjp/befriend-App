//
//  CodeAnswer.swift
//  PetCore
//
//  Asked for code (M40): spotting the request, the file it names ("create a go file as main.go"), and the code
//  block in a reply. CodeCheck.swift writes and checks it.
//

import Foundation

public nonisolated enum CodeAnswer {
    /// A request for code, for chat on the user's own model (no router there): a code file named, or "write/create/
    /// make … code/program/script/function".
    static func isRequest(_ message: String) -> Bool {
        fileName(in: message) != nil || message.range(of: #"(?i)\b(write|create|make|build|implement|generate|code)\b[^.?!]{0,60}\b(code|program|script|function|class|cli|app)\b"#,
                                                     options: .regularExpression) != nil
    }

    /// Under code from Apple's model: it's small, so its code needs a look before it runs.
    static let onDeviceNotice = "Written by the small on-device model, and it didn't pass the check: look it over before you run it. A 9Router model (Models…) writes code more reliably."

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
}
