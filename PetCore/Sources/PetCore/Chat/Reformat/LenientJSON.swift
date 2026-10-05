//
//  LenientJSON.swift
//  PetCore
//
//  Broken JSON made valid (M33), by code, not the model: exact at any length. A forgiving parser reads what people
//  paste (smart quotes, comments, trailing or missing commas, single quotes, bare keys, Python's True/None, missing
//  closing brackets, text around it) and writes it back as valid JSON, indented, keys in their order.
//

import Foundation

public nonisolated enum LenientJSON {
    indirect enum Value {
        case object([(key: String, value: Value)])
        case array([Value])
        case string(String)
        /// As written (after repair), so "1.50" stays "1.50".
        case number(String)
        case bool(Bool)
        case null
    }

    /// Valid, indented JSON and what was fixed (empty when it was only reformatted). Nil when there's no `{` or `[`.
    public static func repair(_ text: String) -> (json: String, fixes: [String])? {
        var parser = Parser(text)
        guard let value = parser.document() else { return nil }
        let json = print(value)
        // The printer only writes valid JSON; checked anyway, so a bug here can never hand back broken JSON.
        guard (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)) != nil else { return nil }
        return (json, parser.fixes)
    }

    // MARK: Writing

    static func print(_ value: Value, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            return "{\n" + members.map { inner + quoted($0.key) + ": " + print($0.value, indent: inner) }.joined(separator: ",\n")
                + "\n" + indent + "}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + print($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .string(let text): return quoted(text)
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: Reading

    struct Parser {
        let chars: [Character]
        var at = 0
        private(set) var fixes: [String] = []

        init(_ text: String) {
            let straight = text.replacingOccurrences(of: "[“”„]", with: "\"", options: .regularExpression)
                .replacingOccurrences(of: "[‘’]", with: "'", options: .regularExpression)
            chars = Array(straight)
            if straight != text { fix("straightened smart quotes") }
        }

        mutating func fix(_ what: String) {
            if !fixes.contains(what) { fixes.append(what) }
        }

        var current: Character? { at < chars.count ? chars[at] : nil }

        /// From the first `{` or `[`; anything around the JSON is dropped.
        mutating func document() -> Value? {
            guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
            if chars[..<start].contains(where: { !$0.isWhitespace }) { fix("dropped the text around it") }
            at = start
            let value = self.value()
            skipSpace()
            if at < chars.count { fix("dropped the text around it") }
            return value
        }

        /// Whitespace and comments (`//`, `/* */`, `#`).
        mutating func skipSpace() {
            while let char = current {
                if char.isWhitespace { at += 1; continue }
                let next = at + 1 < chars.count ? chars[at + 1] : nil
                if char == "#" || (char == "/" && next == "/") {
                    fix("removed comments")
                    while let char = current, !char.isNewline { _ = char; at += 1 }
                } else if char == "/" && next == "*" {
                    fix("removed comments")
                    at += 2
                    while at < chars.count, !(chars[at] == "*" && at + 1 < chars.count && chars[at + 1] == "/") { at += 1 }
                    at = min(chars.count, at + 2)
                } else {
                    return
                }
            }
        }

        mutating func value() -> Value {
            skipSpace()
            guard let char = current else {
                fix("filled a missing value with null")
                return .null
            }
            switch char {
            case "{": return object()
            case "[": return array()
            case "\"", "'", "`": return .string(string())
            case "-", "+", ".", "0"..."9":
                return number()
            default:
                return word()
            }
        }

        mutating func object() -> Value {
            at += 1 // {
            var members: [(key: String, value: Value)] = []
            var comma = true // a member may follow
            while true {
                skipSpace()
                guard let char = current else { fix("closed missing brackets"); break }
                if char == "}" {
                    if comma, !members.isEmpty { fix("removed trailing commas") }
                    at += 1
                    break
                }
                if char == "]" { fix("fixed a mismatched bracket"); break } // the enclosing array's: leave it
                if char == "," {
                    if comma { fix("removed extra commas") }
                    at += 1
                    comma = true
                    continue
                }
                if !comma { fix("added missing commas") }
                guard let key = key() else { at += 1; continue } // a stray character: skip it
                skipSpace()
                if current == ":" || current == "=" {
                    at += 1
                } else {
                    fix("added missing colons")
                }
                members.append((key, value()))
                comma = false
            }
            return .object(members)
        }

        mutating func array() -> Value {
            at += 1 // [
            var items: [Value] = []
            var comma = true
            while true {
                skipSpace()
                guard let char = current else { fix("closed missing brackets"); break }
                if char == "]" {
                    if comma, !items.isEmpty { fix("removed trailing commas") }
                    at += 1
                    break
                }
                if char == "}" { fix("fixed a mismatched bracket"); break }
                if char == "," {
                    if comma { fix("removed extra commas") }
                    at += 1
                    comma = true
                    continue
                }
                if char == ":" { fix("removed a stray colon"); at += 1; continue }
                if !comma { fix("added missing commas") }
                items.append(value())
                comma = false
            }
            return .array(items)
        }

        /// A quoted key, or a bare one (`name:`), quoted.
        mutating func key() -> String? {
            guard let char = current else { return nil }
            if char == "\"" || char == "'" || char == "`" { return string() }
            var bare = ""
            while let char = current, !char.isWhitespace, !":=,{}[]\"'".contains(char) {
                bare.append(char)
                at += 1
            }
            guard !bare.isEmpty else { return nil }
            fix("quoted keys")
            return bare
        }

        /// A string in ", ' or `. A quote mark followed by more text (not , : } ]) belongs to the text; a line break
        /// or the end closes a string left open.
        mutating func string() -> String {
            let quote = chars[at]
            if quote != "\"" { fix("changed single quotes to double quotes") }
            at += 1
            var text = ""
            while let char = current {
                if char == quote {
                    var ahead = at + 1
                    while ahead < chars.count, chars[ahead] == " " || chars[ahead] == "\t" { ahead += 1 }
                    if ahead >= chars.count || ",:}]\n\r\"".contains(chars[ahead]) {
                        at += 1
                        return text
                    }
                    fix("escaped quotes inside text")
                    text.append(char)
                    at += 1
                    continue
                }
                if char.isNewline {
                    fix("closed unterminated text")
                    return text
                }
                if char == "\\", at + 1 < chars.count {
                    let next = chars[at + 1]
                    at += 2
                    switch next {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    case "r": text.append("\r")
                    case "b": text.append("\u{8}")
                    case "f": text.append("\u{c}")
                    case "u":
                        let hex = String(chars[at..<min(chars.count, at + 4)])
                        if hex.count == 4, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                            text.unicodeScalars.append(scalar)
                            at += 4
                        } else {
                            fix("fixed bad escapes")
                            text.append("u")
                        }
                    case "\"", "\\", "/", "'", "`": text.append(next)
                    default:
                        fix("fixed bad escapes")
                        text.append(next)
                    }
                    continue
                }
                text.append(char)
                at += 1
            }
            fix("closed unterminated text")
            return text
        }

        /// A number, repaired ("+1" → 1, ".5" → 0.5, "007" → 7, "0x1F" → 31); not a number at all → text.
        mutating func number() -> Value {
            var raw = ""
            while let char = current, char.isHexDigit || "+-.xXeE".contains(char) {
                raw.append(char)
                at += 1
            }
            if raw.lowercased().hasPrefix("0x"), let hex = Int(raw.dropFirst(2), radix: 16) {
                fix("rewrote numbers")
                return .number(String(hex))
            }
            // -Infinity, or a number running into letters ("10px"): a word.
            if let char = current, char.isLetter { return word(prefix: raw) }
            var repaired = raw
            if repaired.hasPrefix("+") { repaired.removeFirst() }
            let negative = repaired.hasPrefix("-")
            if negative { repaired.removeFirst() }
            if repaired.hasPrefix(".") { repaired = "0" + repaired }
            if repaired.hasSuffix(".") { repaired.removeLast() }
            repaired = repaired.replacingOccurrences(of: "^0+(?=\\d)", with: "", options: .regularExpression)
            repaired = (negative ? "-" : "") + repaired
            guard repaired.range(of: #"^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil else {
                fix("quoted text that wasn't a number")
                return .string(raw)
            }
            if repaired != raw { fix("rewrote numbers") }
            return .number(repaired)
        }

        /// true/false/null in any spelling (True, None, nil, undefined, NaN); any other bare word becomes text.
        mutating func word(prefix: String = "") -> Value {
            var word = prefix
            while let char = current, char.isLetter || char.isNumber || "_$-.".contains(char) {
                word.append(char)
                at += 1
            }
            guard !word.isEmpty else {
                fix("removed stray characters")
                at += 1
                return value()
            }
            switch word {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: break
            }
            switch word.lowercased() {
            case "true", "yes": fix("rewrote true, false and null"); return .bool(true)
            case "false", "no": fix("rewrote true, false and null"); return .bool(false)
            case "null", "none", "nil", "undefined", "nan", "infinity", "-infinity":
                fix("rewrote true, false and null")
                return .null
            default:
                // Words run on to the next delimiter: an unquoted value like `hello world`.
                while let char = current, !",}]\n".contains(char) { word.append(char); at += 1 }
                fix("quoted bare text")
                return .string(word.trimmingCharacters(in: .whitespaces))
            }
        }
    }
}
