import Foundation
import Testing
@testable import PetCore

struct ExactTermsTests {
    private let dictionary: Set<String> = ["research", "about", "website", "tell", "what", "does", "this", "company", "launch",
                                           "budget", "when", "cat", "called"]
    private func find(_ text: String) -> [String] {
        ExactTerms.find(text, isWord: { dictionary.contains($0) }, hasCorrection: { $0 == "webiste" })
    }

    @Test func typosAreNotNames() {
        #expect(find("research this webiste: https://www.antartech.co/") == ["antartech.co", "antartech"])
    }

    @Test func bareDomainsAreLinks() {
        #expect(WebSearch.links(in: "research about website antartech.co").map(\.absoluteString) == ["https://antartech.co"])
        #expect(WebSearch.links(in: "see docs.swift.org/guide.").map(\.absoluteString) == ["https://docs.swift.org/guide"])
        #expect(WebSearch.links(in: "open notes.txt and report.pdf, e.g. this").isEmpty)
        #expect(WebSearch.links(in: "https://www.antartech.co/ and antartech.co").count == 1, "the same site counts once")
        #expect(WebSearch.links(in: "mail me at a@b.co").isEmpty)
    }

    @Test func termsAreWhatTheQuestionIsAbout() {
        #expect(find("research about website antartech.co") == ["antartech.co", "antartech"])
        #expect(find(#"what does "Mai Gei Wo Express" do?"#) == ["mai gei wo express"])
        #expect(find("tell me about Zqxwvy Labs").contains("zqxwvy"))
        #expect(find("iPhone 17 launch budget").contains("iphone"))
        #expect(find("when is the launch budget").isEmpty)
    }

    @Test func mentions() {
        #expect(ExactTerms.mentions("Antartech Solutions builds apps", ["antartech"]))
        #expect(!ExactTerms.mentions("Antarctica Global Technology", ["antartech", "antartech.co"]))
    }
}

struct GroundingTests {
    private func hit(_ name: String, _ text: String, url: String? = nil, kind: ChatDocumentKind = .web) -> Retriever.Hit {
        let document = ChatDocument(name: name, kind: kind, scope: .library,
                                    passages: [IndexedPassage(text: text, note: text, vector: nil, locator: .none)], url: url.flatMap(URL.init(string:)))
        return Retriever.Hit(document: document, passage: document.passages[0], score: 1)
    }

    @Test func searchKeepsTheNameAsTyped() {
        #expect(ChatPrompt.searchQueries(model: ["Antarctica tech website", "antartech services"], terms: ["antartech.co", "antartech"],
                                         question: "research antartech.co") == ["antartech.co", "antartech services"])
        #expect(ChatPrompt.searchQueries(model: ["apple context window"], terms: [], question: "x") == ["apple context window"])
    }

    @Test func onlyPassagesAboutTheName() {
        let hits = [hit("Antarctica Global Technology", "Provider of IT services in Mumbai", url: "https://antarcticaglobal.com"),
                    hit("Antartech Solutions - Software House", "We create web and mobile apps", url: "https://www.antartech.co/"),
                    hit("Directory", "Antartech builds apps for exporters", url: "https://example.org")]
        let kept = ChatPrompt.usable(hits, question: "research antartech.co", terms: ["antartech.co", "antartech"],
                                     named: [URL(string: "https://antartech.co")!], fresh: [])
        #expect(kept.map(\.document.name) == ["Antartech Solutions - Software House", "Directory"])
    }

    @Test func oldWebPagesNeedAWordInCommon() {
        let old = hit("Garden tips", "Tomatoes like sun"), file = hit("notes.pdf", "Venue costs", kind: .pdf)
        let kept = ChatPrompt.usable([old, file], question: "what about the launch budget", terms: [], named: [], fresh: [])
        #expect(kept.map(\.document.name) == ["notes.pdf"])
        #expect(ChatPrompt.usable([old], question: "x", terms: [], named: [], fresh: [old.document.id]).count == 1)
    }

    @Test func missingNamesAreSaidFirst() {
        let note = ChatPrompt.groundingNote(terms: ["zqxwvy"], found: false, unread: ["antartech.co"]) ?? ""
        #expect(note.contains("antartech.co couldn't be opened") && note.contains("\"zqxwvy\"") && note.contains("first sentence"))
        #expect(ChatPrompt.groundingNote(terms: ["antartech"], found: true, unread: []) == nil)
    }
}

struct TypoOrNameTests {
    @Test func onlyRealSlipsAreTypos() {
        #expect(SpellCheck.isNearMiss("webiste", of: "website") && SpellCheck.isNearMiss("teh", of: "the"))
        #expect(SpellCheck.isNearMiss("recive", of: "receive"))
        #expect(!SpellCheck.isNearMiss("netmonk", of: "net monk") && !SpellCheck.isNearMiss("netmonk", of: "net-monk"))
        #expect(!SpellCheck.isNearMiss("fazz", of: "fizz") && !SpellCheck.isNearMiss("grafana", of: "griffin"))
        #expect(!SpellCheck.isNearMiss("kubernetes", of: "Kubernetes"))
        #expect(SpellCheck.editDistance("kitten", "sitting") == 3)
    }

    /// "show me how netmonk installation works" drew LogRhythm's NetMon: lowercase netmonk was taken for a typo.
    @Test func lowercaseProductNamesAreNames() {
        #expect(ExactTerms.find("show me how netmonk installation works") == ["netmonk"])
        #expect(ExactTerms.find("tell me about the webiste") .isEmpty)
    }
}
