import Foundation
import PDFKit
import Testing
@testable import PetCore

struct ResearchTests {
    @Test func researchRequestsAndDepth() {
        #expect(ResearchIntent.detect("research about antartech.co website"))
        #expect(ResearchIntent.detect("im telling you to research about this site"))
        #expect(ResearchIntent.detect("Deep dive into the EV market"))
        #expect(!ResearchIntent.detect("what is the launch date?"))
        #expect(ResearchIntent.split("high antartech.co") == (.high, "antartech.co"))
        #expect(ResearchIntent.split("extra high the EV market") == (.extraHigh, "the EV market"))
        #expect(ResearchIntent.split("xhigh antartech.co").effort == .extraHigh)
        #expect(ResearchIntent.split("antartech.co") == (nil, "antartech.co"))
    }

    @Test func reportFilesOnlyWhenAsked() {
        #expect(TeamEngine.requestedReportFormats("antartech.co").isEmpty)
        #expect(TeamEngine.requestedReportFormats("antartech.co and make it a pdf") == [.pdf])
        #expect(TeamEngine.requestedReportFormats("the EV market, export as markdown") == [.md])
        #expect(TeamEngine.requestedReportFormats("antartech.co especially their line of work. make them into a pdf and md fiile") == [.pdf, .md])
        #expect(TeamEngine.withoutFileRequest("antartech.co especially their line of work. make them into a pdf and md fiile")
                == "antartech.co especially their line of work")
        #expect(TeamEngine.withoutFileRequest("the EV market, export as markdown") == "the EV market")
        #expect(TeamEngine.withoutFileRequest("pdf readers on the market") == "pdf readers on the market")
    }

    @Test func effortsGrow() {
        let levels = ResearchEffort.allCases
        #expect(levels.map(\.title) == ["Low", "Medium", "High", "Extra High"])
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0.questions < $1.questions && $0.pages < $1.pages })
    }

    @Test @MainActor func topicsAndNames() {
        #expect(TeamEngine.cleanTopic("research about antartech.co website") == "antartech.co")
        #expect(TeamEngine.cleanTopic("Deep research on the EV market") == "EV market")
        #expect(TeamEngine.organisation("Antartech Solutions - Software House") == "Antartech Solutions")
    }

    @Test @MainActor func nonFactsAndSectionCleanup() {
        #expect(TeamEngine.isNonFact("The source does not state who uses antartech.co"))
        #expect(!TeamEngine.isNonFact("PT Sparknickel uses its procurement system [6]"))
        let messy = "## Offerings\nThey build apps [1].\n[2]\n[3], [4]\nThey build apps [1].\nThey also do branding [2]."
        #expect(TeamEngine.cleanSection(messy) == "They build apps [1].\nThey also do branding [2].")
    }

    @Test func keyPagesComeFirst() {
        let html = """
            <a href="/about-us">About Us</a><a href="/login">Log in</a><a href="https://other.com/pricing">x</a>
            <a href="/pricing">Pricing</a><a href="/random">Random</a><a href="/about-us#team">Team</a><a href="/blog">Blog</a>
            """
        let links = SiteCrawler.keyLinks(in: html, base: URL(string: "https://www.example.co/")!, limit: 5).map { $0.path() }
        #expect(links == ["/about-us", "/pricing", "/blog"])
    }

    @Test func seoMeasuresThePage() {
        let html = """
            <html lang="en"><head><title>Short</title><meta name="description" content="A good description that is long enough to count as a proper summary of the page.">
            <link rel="canonical" href="https://example.co/"><meta property="og:title" content="x">
            <script type="application/ld+json">{"@type":"Organization"}</script></head>
            <body><h1>Hello</h1><h2>A</h2><img src="a.png" alt="Logo"><img src="b.png"><a href="/x">x</a><a href="https://y.com">y</a></body></html>
            """
        let page = SitePage(url: URL(string: "https://example.co/")!, html: html,
                            source: WebSource(url: URL(string: "https://example.co/")!, title: "Short", text: "Hello A"))
        let seo = SEOPage.measure(page)
        #expect(seo.lang == "en" && seo.canonical != nil && seo.openGraph && seo.structuredData == ["Organization"])
        #expect(seo.h1 == ["Hello"] && seo.h2Count == 1 && seo.images == 2 && seo.imagesWithoutAlt == 1)
        #expect(seo.internalLinks == 1 && seo.externalLinks == 1)
        #expect(seo.issues.contains { $0.hasPrefix("title is 5 characters") } && seo.issues.contains("1 of 2 images have no alt text"))
        let report = SEOReport(pages: [seo, seo], robotsTxt: true, sitemap: false)
        #expect(report.siteIssues == ["All 2 pages share one title.", "All 2 pages share one meta description."])
    }
}

struct ResearchQualityTests {
    @Test func inventedNamesAndNumbersAreDropped() {
        let facts = "Antartech is a software house offering web and app development [1]. Clients include MGW Express and PT Sparknickel."
        let section = "Antartech builds web and apps for MGW Express [1]. Alex Smith and Jordan Lee are its founders [2]. "
            + "It raised a funding round of $500,000. According to the text, reviews are positive. They serve PT Sparknickel [1]."
        let kept = TeamEngine.grounded(section, in: facts)
        #expect(kept.contains("MGW Express [1]") && kept.contains("PT Sparknickel [1]"))
        #expect(!kept.contains("Alex Smith") && !kept.contains("500,000") && !kept.contains("the text"))
    }

    @Test func factsMustComeFromTheirSource() {
        #expect(!TeamEngine.supported("Key processes include software design, development, testing, and deployment", by: "Our portfolio. See our work."))
        #expect(TeamEngine.supported("They replaced 47 Excel spreadsheets with one smart pricing engine",
                                         by: "We replaced 47 Excel spreadsheets with one smart pricing engine for export logistics."))
        #expect(TeamEngine.grounded("Quality at antarctic.co is maintained through testing [4].", in: "antartech.co tests its software").isEmpty)
        #expect(TeamEngine.grounded("These challenges are not explicitly mentioned. No differentiation was mentioned in [5].", in: "x").isEmpty)
    }

    @Test func outsideFactsMustNameTheSubject() {
        let names = ["antartech.co", "antartech solutions"]
        #expect(!TeamEngine.aboutSubject("Donna Karina works at Universitas Padjadjaran", kind: "web", names: names))
        #expect(TeamEngine.aboutSubject("Donna Karina is CPO at Antartech", kind: "web", names: names))
        #expect(TeamEngine.aboutSubject("They built MGW Express", kind: "site", names: names))
    }

    @Test func seoFixesFollowTheMeasurements() {
        func page(_ path: String, h1: [String]) -> SEOPage {
            SEOPage(url: URL(string: "https://a.co\(path)")!, title: "Same title for the whole site here", description: nil, h1: h1,
                    h2Count: 1, canonical: nil, robots: nil, lang: "en", openGraph: true, structuredData: [], images: 0,
                    imagesWithoutAlt: 0, internalLinks: 3, externalLinks: 0, words: 900, bytes: 1000)
        }
        let fixes = TeamEngine.seoFixes(SEOReport(pages: [page("/", h1: ["A"]), page("/about-us", h1: [])], robotsTxt: true, sitemap: true))
        #expect(fixes.contains("own title") && fixes.contains("`<h1>` heading** on /about-us") && !fixes.contains("Open Graph"))
    }

    @Test func refusalsFillerAndLeadingCitations() {
        let facts = "A growing Indonesian export logistics company is a client. Useful for export forwarders, freight companies and 3PL providers."
        #expect(TeamEngine.grounded("I'm sorry, but I cannot complete that request.", in: facts).isEmpty)
        #expect(TeamEngine.grounded("The tech stack is then used to define the client's requirements and capabilities.", in: facts).isEmpty)
        #expect(TeamEngine.citationsLast("[9] A growing Indonesian export logistics company is a client. [8] It suits freight companies.")
                == "A growing Indonesian export logistics company is a client. [9] It suits freight companies. [8]")
    }

    @Test func keyFactsSkipFragmentsAndRepeats() {
        let notes = ["Client", "Richardson Jayaputra is the Chief Executive Officer", "Richardson Jayaputra is Chief Executive Officer of Antartech",
                     "Rizky Syawal is the Chief Technology Officer"].enumerated().map { ResearchNote(question: 0, fact: $0.element, source: $0.offset) }
        #expect(TeamEngine.keyFacts(notes).map(\.fact) == ["Richardson Jayaputra is the Chief Executive Officer", "Rizky Syawal is the Chief Technology Officer"])
    }

    @Test func summaryIsOneSentenceThenBullets() {
        let tidy = TeamEngine.tidySummary(["Antartech is a software house.", "- It builds logistics platforms [8]", "Stray line.",
                                               "- It builds logistics platforms [9]", "- A", "- B", "- C", "- D", "- E", "- F"])
        #expect(tidy.hasPrefix("Antartech is a software house.\n- It builds logistics platforms [8]\n- Stray line."))
        #expect(tidy.components(separatedBy: "\n").count == 7 && !tidy.contains("[9]"))
        #expect(TeamEngine.grounded("It builds apps [1]. It builds apps [2].", in: "it builds apps") == "It builds apps [1].")
    }

    @Test func overviewMapKeepsBackedShortLabels() {
        let report = "Fazz offers payment infrastructure, business accounts and Fazz Agen for MSMEs in Indonesia and Singapore."
        let map = ChatDiagram.mindmap(root: "x", branches: [
            .init(label: "Payment infrastructure", children: ["Business accounts", "Quantum blockchain", "Fazz Agen"]),
            .init(label: "Markets", children: ["Indonesia", "Singapore"]),
            .init(label: "Galactic expansion plans", children: ["Mars"]),
        ])
        let kept = TeamEngine.groundedMap(map, in: report, root: "Fazz")
        #expect(kept == .mindmap(root: "Fazz", branches: [.init(label: "Payment infrastructure", children: ["Business accounts", "Fazz Agen"]),
                                                          .init(label: "Markets", children: ["Indonesia", "Singapore"])]))
        #expect(TeamEngine.siteName(URL(string: "https://www.antartech.co/about")) == "Antartech")
        #expect(!TeamEngine.aboutSubject("Email Us: fazzaindia@gmail.com, Fazza India", kind: "web", names: ["fazz.com", "fazz"]))
    }

    @Test func pageChromeIsNotAFact() {
        #expect(TeamEngine.isChrome("See Pricing See Our Works"))
        #expect(TeamEngine.isChrome("Our Portfolio See our work Category All Client Project Description Tech Stack"))
        #expect(!TeamEngine.isChrome("Antartech replaced 47 spreadsheets with a smart pricing engine"))
    }

    @Test func citationsMoveToSentenceEnds() {
        #expect(TeamEngine.citationsLast("For example, [8] describes a payment system.") == "For example, [8] describes a payment system.")
        #expect(TeamEngine.citationsLast("[8] Mistakes cost most once they cross an ocean [9].") == "Mistakes cost most once they cross an ocean [9].")
        #expect(TeamEngine.grounded("The client is an Indonesian export logistics company, suggesting a global reach.",
                                        in: "A growing Indonesian export logistics company is a client") == "The client is an Indonesian export logistics company.")
        #expect(TeamEngine.citationsLast("[1] Antartech.co builds apps. [2] It is in Jakarta.") == "Antartech.co builds apps. [1] It is in Jakarta. [2]")
    }

    @Test func seoSaysCommonIssuesOnce() {
        func page(_ path: String, words: Int) -> SEOPage {
            SEOPage(url: URL(string: "https://a.co\(path)")!, title: "Antartech Solutions - Software House", description: nil, h1: ["A"],
                    h2Count: 1, canonical: nil, robots: nil, lang: "en", openGraph: false, structuredData: [], images: 0,
                    imagesWithoutAlt: 0, internalLinks: 3, externalLinks: 0, words: words, bytes: 1000)
        }
        let report = SEOReport(pages: [page("/", words: 900), page("/pricing", words: 23)], robotsTxt: true, sitemap: true)
        #expect(report.commonIssues.contains("no canonical link") && report.commonIssues.contains("no meta description"))
        #expect(report.issues(of: report.pages[1]) == ["only about 23 words of visible text"])
        #expect(report.issues(of: report.pages[0]).isEmpty)
    }

    @Test func blogArticlesComeLast() {
        let html = #"<a href="/about-us">About</a><a href="/blog">Blog</a><a href="/blog/2wWTuKlR8pJUV4vmnSnltS">Figma plugins</a><a href="/services/web">Web</a>"#
        let links = SiteCrawler.keyLinks(in: html, base: URL(string: "https://antartech.co")!, limit: 10).map { $0.path() }
        #expect(links.contains("/about-us") && links.contains("/blog") && links.contains("/services/web"))
        #expect(links.last == "/blog/2wWTuKlR8pJUV4vmnSnltS", "articles come after the key pages")
    }
}

extension ChatDocumentTests {
    @Test func listItemsKeepTheirTextTogether() {
        let html = ChatHTML.page("1. **Duplicate titles:** every page shares one title.", title: "T").html
        #expect(html.contains("<span class=\"m\">1.</span><span><strong>Duplicate titles:</strong> every page shares one title.</span>"))
    }

    @MainActor @Test func longTablesSplitWithTheirHeader() async throws {
        let rows = (1...60).map { "| /page\($0) | \($0 * 10) | issue text for this page |" }.joined(separator: "\n")
        let output = try await ChatDocumentRenderer.render("# T\n\n| Page | Words | Issues |\n|---|---|---|\n" + rows, title: "T")
        let pdf = try #require(PDFDocument(data: output.pdf))
        func visible(_ index: Int) -> String { pdf.page(at: index)?.selection(for: CGRect(x: 0, y: 50, width: 595, height: 742))?.string ?? "" }
        #expect(pdf.pageCount >= 2 && visible(1).contains("Page") && visible(1).contains("Words"), "header repeats")
        #expect(!String(decoding: output.html, as: UTF8.self).contains("padding-top"))
    }
}

struct ResearchSearchOrderTests {
    actor InFlight {
        var now = 0, peak = 0
        func enter() { now += 1; peak = max(peak, now) }
        func leave() { now -= 1 }
    }

    /// Searches run at once, but pages come back in the order asked: the first finishing last changes nothing.
    @Test func searchesRunAtOnceAndKeepTheirOrder() async {
        let inFlight = InFlight()
        let results = await TeamEngine.inOrder([3, 2, 1]) { delay in
            await inFlight.enter()
            try? await Task.sleep(for: .milliseconds(100 * delay))
            await inFlight.leave()
            return delay
        }
        #expect(results == [3, 2, 1])
        #expect(await inFlight.peak == 3, "at once, not one after another")
    }
}
