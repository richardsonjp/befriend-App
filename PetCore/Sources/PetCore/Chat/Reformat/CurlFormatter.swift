//
//  CurlFormatter.swift
//  PetCore
//
//  A curl command made runnable again (M33), by code: what chat apps and Windows do to it undone (smart quotes,
//  "—data" dashes, lost or foreign line continuations, cmd's ^ escapes, quotes left open), then written one flag per
//  line with a pretty JSON body. Checked by reading the result back the way a shell would; never run.
//

import Foundation

public nonisolated enum CurlFormatter {
    /// One shell word, and whether it held a `$` outside single quotes (a variable the user wants expanded).
    struct Word: Equatable {
        var text: String
        var expands = false
    }

    /// Options that take a value (the next word).
    static let valued: Set<String> = [
        "-X", "--request", "-H", "--header", "-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii",
        "--json", "-u", "--user", "-A", "--user-agent", "-b", "--cookie", "-c", "--cookie-jar", "-e", "--referer", "-F", "--form",
        "--form-string", "-o", "--output", "-T", "--upload-file", "--url", "-x", "--proxy", "-U", "--proxy-user", "-m", "--max-time",
        "--connect-timeout", "-w", "--write-out", "--cert", "-E", "--key", "--cacert", "-K", "--config", "-r", "--range", "-z",
        "--time-cond", "--retry", "--limit-rate", "--resolve", "--oauth2-bearer", "-D", "--dump-header", "--max-redirs",
    ]
    static let bodies: Set<String> = ["-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--json"]

    /// The command rewritten and what was fixed; nil when there's no curl in it or it doesn't read back the same.
    public static func repair(_ text: String) -> (command: String, fixes: [String])? {
        guard let start = text.range(of: #"\bcurl(\.exe)?\s"#, options: .regularExpression) else { return nil }
        var fixes: [String] = []
        func fix(_ what: String) { if !fixes.contains(what) { fixes.append(what) } }
        var source = String(text[start.lowerBound...])
        let original = source

        source = source.replacingOccurrences(of: "[“”„]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[‘’]", with: "'", options: .regularExpression)
        if source != original { fix("straightened smart quotes") }
        // Chat apps turn "--data" into "—data" and "-H" into "–H".
        let dashed = source.replacingOccurrences(of: #"(?<=\s)[—–]([A-Za-z])(?=\s)"#, with: "-$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\s)[—–]-?([A-Za-z][\w-]+)"#, with: "--$1", options: .regularExpression)
        if dashed != source { fix("fixed dashes") }
        source = dashed
        // Windows cmd ("Copy as cURL (cmd)"): ^ escapes every special character and ends lines.
        if source.contains("^\"") || source.range(of: #"\^\r?\n"#, options: .regularExpression) != nil {
            source = source.replacingOccurrences(of: #"\^\r?\n"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\^(.)"#, with: "$1", options: .regularExpression)
            fix("converted from Windows cmd")
        }
        // PowerShell ends lines with a backtick; bash with a backslash (and a lost one is only whitespace to a shell).
        if source.range(of: #"`[ \t]*\r?\n"#, options: .regularExpression) != nil { fix("converted from PowerShell") }
        source = source.replacingOccurrences(of: #"[`\\][ \t]*\r?\n"#, with: " ", options: .regularExpression)

        let (words, closed) = self.words(source)
        if closed { fix("closed quotes left open") }
        guard words.first.map({ $0.text == "curl" || $0.text == "curl.exe" }) == true, words.count > 1 else { return nil }

        // URL first, then every option in its order; a JSON body repaired.
        var urls: [Word] = [], options: [[Word]] = []
        var index = 1
        while index < words.count {
            let word = words[index]
            index += 1
            guard word.text.hasPrefix("-"), word.text.count > 1 else { urls.append(word); continue }
            guard valued.contains(word.text) else { options.append([word]); continue }
            guard index < words.count else { options.append([word]); break }
            var value = words[index]
            index += 1
            if bodies.contains(word.text), let pretty = prettyBody(value.text) {
                if pretty.fixes.isEmpty == false { fix("fixed the JSON body") }
                value.text = pretty.json
            }
            options.append([word, value])
        }
        let lines = ["curl" + urls.map { " " + quoted($0) }.joined()] + options.map { $0.map(quoted).joined(separator: " ") }
        let command = lines.enumerated().map { $0.offset == 0 ? $0.element : "  " + $0.element }.joined(separator: " \\\n")

        // Read back as a shell would: the same words, in the printed order.
        let printed = [Word(text: "curl")] + urls + options.flatMap { $0 } // curl.exe is written as curl, for bash and zsh
        guard self.words(command).words.map(\.text) == printed.map(\.text) else { return nil }
        return (command, fixes)
    }

    static func prettyBody(_ body: String) -> (json: String, fixes: [String])? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        return LenientJSON.repair(trimmed)
    }

    /// Shell words: whitespace splits; '…' is literal; "…" and bare text take backslash escapes. A quote still open
    /// at the end is closed there (`closed`).
    static func words(_ text: String) -> (words: [Word], closed: Bool) {
        var words: [Word] = [], word = Word(text: ""), inWord = false
        var quote: Character?
        var chars = text.makeIterator()
        while let char = chars.next() {
            if quote == "'" {
                if char == "'" { quote = nil } else { word.text.append(char) }
                continue
            }
            if quote == "\"" {
                if char == "\"" { quote = nil; continue }
                if char == "\\", let next = chars.next() {
                    if "\"\\$`".contains(next) { word.text.append(next) } else if next != "\n" { word.text += "\\" + String(next) }
                    continue
                }
                if char == "$" { word.expands = true }
                word.text.append(char)
                continue
            }
            switch char {
            case "'", "\"":
                quote = char
                inWord = true
            case "\\":
                // A backslash ending the line joins the lines; it doesn't start a word.
                if let next = chars.next(), next != "\n" {
                    word.text.append(next)
                    inWord = true
                }
            case _ where char.isWhitespace:
                if inWord { words.append(word) }
                word = Word(text: "")
                inWord = false
            default:
                if char == "$" { word.expands = true }
                word.text.append(char)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return (words, quote != nil)
    }

    /// Shell-safe: bare when plain, '…' when literal, "…" when it holds a variable to expand.
    static func quoted(_ word: Word) -> String {
        if !word.text.isEmpty, word.text.range(of: #"^[A-Za-z0-9_./:=@%+,-]+$"#, options: .regularExpression) != nil {
            return word.text
        }
        if word.expands {
            let escaped = word.text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "`", with: "\\`")
            return "\"" + escaped + "\""
        }
        return "'" + word.text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
