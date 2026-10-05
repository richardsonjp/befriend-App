//
//  Reformatter.swift
//  PetCore
//
//  The reformat agent (M33): "fix this JSON", "reformat this curl". Code repairs what it knows exactly and at any
//  length; the model never has to copy a long text back through its 4K context.
//

import Foundation

public nonisolated enum Reformatter {
    /// What to repair: the first fenced block when there is one, else the whole message.
    static func pasted(in message: String) -> String {
        guard let open = message.range(of: "```") else { return message }
        let rest = message[open.upperBound...]
        let body = rest.drop { $0 != "\n" }.dropFirst() // skip the language tag line
        guard let close = body.range(of: "```") else { return String(body) }
        return String(body[..<close.lowerBound])
    }

    /// JSON, not code that has brackets in it: at most a one-line lead-in ("fix this json:"), and either it says
    /// JSON or starts with `{`/`[`.
    static func looksLikeJSON(_ text: String, message: String) -> Bool {
        guard !text.contains("curl "), let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return false }
        let lead = text[..<start]
        guard !lead.contains(where: \.isNewline), lead.count <= 80 else { return false }
        return message.localizedCaseInsensitiveContains("json") || lead.allSatisfy(\.isWhitespace)
    }

    /// The friend's reply when code can do it, else nil (the model's turn).
    static func byCode(_ message: String) -> String? {
        let text = pasted(in: message)
        if let (command, fixes) = CurlFormatter.repair(text) {
            let what = fixes.isEmpty ? "Reformatted curl:" : "Fixed curl: " + fixes.joined(separator: ", ") + "."
            return what + "\n\n```bash\n" + command + "\n```"
        }
        guard looksLikeJSON(text, message: message), let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let (json, fixes) = LenientJSON.repair(String(text[start...])) else { return nil } // the lead-in isn't a fix
        let what = fixes.isEmpty ? "Reformatted JSON (it was already valid):" : "Fixed JSON: " + fixes.joined(separator: ", ") + "."
        return what + "\n\n```json\n" + json + "\n```"
    }
}
