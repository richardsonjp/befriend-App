import Foundation
import Testing
@testable import PetCore

struct WebSearchTests {
    @Test func parsesParallelResults() throws {
        let inner = #"{"search_id":"s","results":[{"url":"https://developer.apple.com/a","title":"Managing the context window","excerpts":["4096 tokens per session","Divide it into steps"]},{"url":"https://x.dev","title":"No excerpts","excerpts":[]}]}"#
        let rpc = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": ["content": [["type": "text", "text": inner]]]])
        let sources = try WebSearch.parseParallel(rpc)
        #expect(sources.count == 1)
        #expect(sources[0].title == "Managing the context window" && sources[0].text == "4096 tokens per session\n\nDivide it into steps")
        #expect(sources[0].site == "developer.apple.com")
    }

    @Test func parsesFirecrawlResultsAndRefusals() throws {
        let ok = ##"{"success":true,"data":{"web":[{"url":"https://www.example.com/p","title":"Example","markdown":"# Hello"}]}}"##
        #expect(try WebSearch.parseFirecrawl(Data(ok.utf8)).map(\.site) == ["example.com"])
        let refused = #"{"success":false,"error":"your IP address looks suspicious"}"#
        #expect(throws: WebSearch.Failure.self) { try WebSearch.parseFirecrawl(Data(refused.utf8)) }
    }

    @Test func readableTextFromHTML() {
        let html = """
            <html><head><title>Launch &amp; Budget</title><style>p{}</style></head>
            <body><nav>Menu</nav><script>alert("x")</script><h1>Launch</h1><p>It moved to May&nbsp;3rd &#8212; Budi&#x27;s call.</p>
            <!-- hidden --><ul><li>One</li><li>Two</li></ul><footer>© 2026</footer></body></html>
            """
        let page = WebSearch.readable(html: html)
        #expect(page.title == "Launch & Budget")
        #expect(page.text == "Launch\nIt moved to May 3rd — Budi's call.\nOne\nTwo")
    }

    @Test func findsLinksInAMessage() {
        let links = WebSearch.links(in: "Read https://example.com/a and www.swift.org, not ftp://x.org or mailto:a@b.c. Again https://example.com/a")
        #expect(links.map(\.absoluteString) == ["https://example.com/a", "http://www.swift.org"])
    }

    @Test func cleansTheModelsQueries() {
        let text = "1. Apple Foundation Models context\n- \"on-device LLM token limit\"\n\n• WWDC25 foundation models\nextra fourth query"
        #expect(ChatPrompt.queries(from: text) == ["Apple Foundation Models context", "on-device LLM token limit", "WWDC25 foundation models"])
    }

    @Test func keepsAPagesClosestPassagesInOrder() {
        let pieces: [(text: String, locator: PassageLocator)] = [
            ("Cookie policy and privacy", .none), ("The launch moved to May third", .none),
            ("Newsletter signup", .none), ("Budget for the launch is twelve thousand", .none),
        ]
        let kept = ChatLibrary.closest(pieces, to: "When is the launch and what's the budget?", keep: 2).map(\.text)
        #expect(kept == ["The launch moved to May third", "Budget for the launch is twelve thousand"])
    }
}

struct WebDedupTests {
    @Test func samePageCountsOnce() {
        let a = WebSource(url: URL(string: "https://developer.apple.com/doc/context?changes=_3")!, title: "Context", text: "x")
        let b = WebSource(url: URL(string: "https://developer.apple.com/doc/context/")!, title: "Context", text: "y")
        let c = WebSource(url: URL(string: "https://developer.apple.com/doc/other")!, title: "Context", text: "z")
        let d = WebSource(url: URL(string: "https://swift.org")!, title: "Swift", text: "w")
        #expect(WebSource.distinct([a, b, c, d]).map(\.text) == ["x", "w"])
    }

    @Test func chipsMergePerPage() {
        let one = ChatSource(documentName: "Docs", kind: .web, locator: .none, text: "a", url: URL(string: "https://a.dev"))
        let two = ChatSource(documentName: "Docs", kind: .web, locator: .none, text: "b", url: URL(string: "https://a.dev"))
        let pdf = ChatSource(documentName: "notes.pdf", kind: .pdf, locator: .page(2), text: "c")
        let merged = ChatSource.merged([one, pdf, two])
        #expect(merged.map(\.label) == ["Docs", "notes.pdf · p.2"])
        #expect(merged[0].text == "a\n\n…\n\nb")
    }
}
