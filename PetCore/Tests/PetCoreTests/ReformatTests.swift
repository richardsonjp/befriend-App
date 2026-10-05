import Foundation
import FoundationModels
import Testing
@testable import PetCore

struct LenientJSONTests {
    static func repaired(_ text: String) -> (value: Any, json: String, fixes: [String]) {
        let result = LenientJSON.repair(text)!
        return (try! JSONSerialization.jsonObject(with: Data(result.json.utf8), options: .fragmentsAllowed), result.json, result.fixes)
    }

    @Test(arguments: [
        (#"{"a": 1,}"#, "removed trailing commas"),
        (#"{"a": 1 "b": 2}"#, "added missing commas"),
        (#"{'a': 'x'}"#, "changed single quotes to double quotes"),
        (#"{a: 1, b_c: 2}"#, "quoted keys"),
        (#"{"a": True, "b": None, "c": NaN}"#, "rewrote true, false and null"),
        (#"{"a": [1, 2"#, "closed missing brackets"),
        (#"{"a": 1 // one"#, "removed comments"),
        ("{“a”: “x”}", "straightened smart quotes"),
        (#"here you go: {"a": 1} thanks"#, "dropped the text around it"),
        (#"{"a": +1, "b": .5, "c": 007, "d": 0x1F}"#, "rewrote numbers"),
        (#"{"a": "line"#, "closed unterminated text"),
        (#"{"say": "he said "hi" ok"}"#, "escaped quotes inside text"),
        (#"{"a": hello world}"#, "quoted bare text"),
    ])
    func repairs(_ broken: String, _ fix: String) {
        let result = Self.repaired(broken)
        #expect(result.fixes.contains(fix), "\(result.fixes)")
    }

    @Test func valuesSurviveTheRepair() {
        let result = Self.repaired(#"{name:'Ann', tags:['a','b',], "ok": True, price: 1.50, n: .5, "say": "he said "hi" ok"}"#)
        let object = result.value as! [String: Any]
        #expect(object["name"] as? String == "Ann")
        #expect(object["tags"] as? [String] == ["a", "b"])
        #expect(object["ok"] as? Bool == true)
        #expect(object["say"] as? String == #"he said "hi" ok"#)
        #expect(result.json.contains("\"price\": 1.50"), "numbers as written")
        #expect(result.json.contains("\"n\": 0.5"))
    }

    @Test func keepsKeyOrderAndIndents() {
        let json = LenientJSON.repair(#"{"z":1,"a":{"y":[1,{"b":2}],"c":{}},"m":[]}"#)!.json
        #expect(json == """
            {
              "z": 1,
              "a": {
                "y": [
                  1,
                  {
                    "b": 2
                  }
                ],
                "c": {}
              },
              "m": []
            }
            """)
        #expect(LenientJSON.repair(#"{"a": 1}"#)!.fixes.isEmpty, "valid JSON is only reformatted")
    }

    @Test func alwaysValidEvenFromGarbage() {
        for junk in ["{{{", "[,,,]", "{:::}", "{\"a\" \"b\" \"c\"}", "[}{]", "{a:{b:{c:", "[1 2 3 'x' y z]", "{\"a\": @#!}", "{\"k\": 10px}"] {
            #expect(LenientJSON.repair(junk) != nil, "\(junk)")
        }
        #expect(LenientJSON.repair("no brackets here") == nil)
    }
}

struct ReformatterTests {
    @Test func repliesWithFixedJSONOnlyForJSON() {
        let reply = Reformatter.byCode("fix this json: {a:1,}")!
        #expect(reply.hasPrefix("Fixed JSON: quoted keys, removed trailing commas."))
        #expect(reply.contains("```json\n{\n  \"a\": 1\n}\n```"))
        #expect(Reformatter.byCode("Reformat:\n```json\n[1,2,]\n```") != nil, "from a fenced block")
        #expect(Reformatter.byCode("tidy this python:\ndef f():\n    return [1, 2]") == nil, "code with brackets isn't JSON")
        #expect(Reformatter.byCode("can you fix my code") == nil)
    }

    @Test func routerSendsPastedFixesToReformat() async {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        var misses: [String] = []
        for message in ["fix this json: {a:1, b:[1,2,],}", "reformat this curl: curl -X POST https://api.x.io/v1 -H 'A: b' -d '{\"a\":1}'",
                        "can you prettify this JSON? [{\"id\":1},{\"id\":2}]"] {
            let route = await ChatRouter.route(message, recent: [], model: model)
            if ChatRouter.action(route, for: message, check: .valid) != .reformat { misses.append("\(message) → \(String(describing: route))") }
        }
        #expect(misses.isEmpty, "\(misses)")
    }
}

struct CurlFormatterTests {
    /// What a real zsh makes of the command: `curl` swapped for printf, one argument a line (NUL-separated).
    static func shellWords(_ command: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "TOKEN=abc; printf '%s\\0' " + command.dropFirst("curl".count)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    @Test func fixesAChatMangledCurl() throws {
        let mangled = """
            here: curl –X POST “https://api.example.com/v1/items?a=1&b=2”
            —header “Content-Type: application/json”
            -H 'Authorization: Bearer x' —data '{name: "Ann", tags: ["a",], ok: True'
            """
        let (command, fixes) = try #require(CurlFormatter.repair(mangled))
        #expect(fixes.contains("straightened smart quotes") && fixes.contains("fixed dashes") && fixes.contains("fixed the JSON body"))
        #expect(command.hasPrefix("curl 'https://api.example.com/v1/items?a=1&b=2' \\\n  -X POST \\\n  --header 'Content-Type: application/json'"))
        let words = try Self.shellWords(command)
        #expect(words.prefix(3) == ["https://api.example.com/v1/items?a=1&b=2", "-X", "POST"])
        let body = try #require(words.last)
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(object?["name"] as? String == "Ann" && object?["ok"] as? Bool == true)
        #expect(body.contains("\n  \"name\": \"Ann\""), "pretty body")
    }

    @Test func undoesWindowsAndPowerShell() throws {
        let cmd = #"curl ^"https://x.io/a^" ^"#.appending("\n") + #"  -H ^"Accept: */*^" ^"#.appending("\n") + #"  --data-raw ^"^{^\^"a^\^":1^}^""#
        let (command, fixes) = try #require(CurlFormatter.repair(cmd))
        #expect(fixes.contains("converted from Windows cmd"))
        #expect(try Self.shellWords(command) == ["https://x.io/a", "-H", "Accept: */*", "--data-raw", "{\n  \"a\": 1\n}"])
        let powershell = "curl.exe https://x.io `\n  -H \"A: b\""
        let (ps, psFixes) = try #require(CurlFormatter.repair(powershell))
        #expect(psFixes.contains("converted from PowerShell"))
        #expect(try Self.shellWords(ps) == ["https://x.io", "-H", "A: b"])
    }

    @Test func quotesStaySafeAndVariablesExpand() throws {
        let (command, _) = try #require(CurlFormatter.repair(#"curl https://x.io -d "it's \"fine\"" -H "Authorization: Bearer $TOKEN""#))
        #expect(try Self.shellWords(command) == ["https://x.io", "-d", #"it's "fine""#, "-H", "Authorization: Bearer abc"])
        let (open, fixes) = try #require(CurlFormatter.repair("curl https://x.io -H 'A: b"))
        #expect(fixes.contains("closed quotes left open"))
        #expect(try Self.shellWords(open) == ["https://x.io", "-H", "A: b"])
        #expect(CurlFormatter.repair("no command here") == nil)
    }

    @Test func reformatterRepliesWithBash() {
        let reply = Reformatter.byCode("reformat this curl: curl -X POST https://x.io -d '{\"a\":1,}'")!
        #expect(reply.hasPrefix("Fixed curl: fixed the JSON body."))
        #expect(reply.contains("```bash\ncurl https://x.io \\\n  -X POST \\\n  -d '{\n  \"a\": 1\n}'\n```"))
    }
}
