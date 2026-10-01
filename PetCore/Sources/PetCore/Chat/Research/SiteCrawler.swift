//
//  SiteCrawler.swift
//  PetCore
//
//  Deep research on a named website (M28): its key pages (About, Services, Pricing, Portfolio, Team, Blog, Contact)
//  found from its own links, and an SEO check measured from the HTML itself (title, description, headings,
//  canonical, Open Graph, structured data, image alt text, links, robots.txt, sitemap). Facts are measured here; the
//  model only turns them into advice.
//

import Foundation

public nonisolated struct SitePage: Equatable, Sendable {
    public let url: URL
    public let html: String
    public let source: WebSource
}

public nonisolated enum SiteCrawler {
    /// Words in a link that point at the pages worth reading, most useful first.
    static let keyWords: [(String, Int)] = [
        ("about", 10), ("tentang", 10), ("service", 9), ("layanan", 9), ("product", 9), ("solution", 8), ("pricing", 9),
        ("price", 8), ("harga", 8), ("plan", 6), ("portfolio", 8), ("work", 6), ("project", 6), ("case", 7), ("client", 7),
        ("customer", 6), ("team", 7), ("company", 5), ("career", 4), ("blog", 5), ("news", 4), ("article", 4),
        ("contact", 6), ("kontak", 6), ("faq", 5), ("feature", 6),
    ]
    static let skipWords = ["login", "signin", "sign-in", "register", "cart", "checkout", "privacy", "terms", "cookie", "#",
                            "mailto:", "tel:", "javascript:", "wp-admin", "feed", ".pdf", ".jpg", ".png", ".zip"]

    static let articleFolders: Set<String> = ["blog", "blogs", "news", "article", "articles", "insights", "posts", "post", "case-studies", "stories"]
    static let maxArticles = 4

    /// Same-site links from a page, with their link text, best key pages first.
    static func keyLinks(in html: String, base: URL, limit: Int) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, options: .caseInsensitive)
        else { return [] }
        let host = base.host()?.replacingOccurrences(of: "www.", with: "")
        var scored: [(URL, Int)] = []
        var seen: Set<String> = [WebSearch.pageKey(base)]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let hrefRange = Range(match.range(at: 1), in: html), let textRange = Range(match.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange])
            let lower = href.lowercased()
            guard !skipWords.contains(where: { lower.contains($0) }), let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme ?? ""), url.host()?.replacingOccurrences(of: "www.", with: "") == host else { continue }
            let segments = url.pathComponents.filter { $0 != "/" }
            let article = segments.count > 1 && articleFolders.contains(segments[0].lowercased())
            var key = WebSearch.pageKey(url)
            if let hash = key.firstIndex(of: "#") { key = String(key[..<hash]) }
            guard seen.insert(key).inserted else { continue }
            let text = (lower + " " + String(html[textRange]).lowercased())
            // Articles come after the key pages, a few at most: often case studies, sometimes general advice.
            let score = article ? 1 : keyWords.filter { text.contains($0.0) }.map(\.1).max() ?? 0
            if score > 0 { scored.append((url, score)) }
        }
        let pages = scored.filter { $0.1 > 1 }.sorted { $0.1 > $1.1 }.map(\.0)
        let articles = scored.filter { $0.1 == 1 }.prefix(maxArticles).map(\.0)
        return Array((pages + articles).prefix(limit))
    }

    /// The home page and up to `pages - 1` key pages, read on this device.
    public static func crawl(_ home: URL, pages: Int, session: URLSession = .shared,
                             progress: @escaping @Sendable (URL) -> Void = { _ in }) async -> [SitePage] {
        guard let first = try? await raw(home, session: session) else { return [] }
        var result = [first]
        for link in keyLinks(in: first.html, base: first.url, limit: max(0, pages - 1)) {
            guard !Task.isCancelled else { break }
            progress(link)
            if let page = try? await raw(link, session: session) { result.append(page) }
        }
        return result
    }

    static func raw(_ url: URL, session: URLSession) async throws -> SitePage {
        var request = URLRequest(url: url, timeoutInterval: WebSearch.timeout)
        request.setValue(WebSearch.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), (http.mimeType ?? "").contains("html")
        else { throw WebSearch.Failure.unreadable }
        let html = String(decoding: data.prefix(WebSearch.maxDownload), as: UTF8.self)
        let page = WebSearch.readable(html: html)
        let final = http.url ?? url
        return SitePage(url: final, html: html, source: WebSource(url: final, title: page.title ?? final.absoluteString, text: page.text))
    }
}

// MARK: SEO

/// What an SEO check measures on one page.
public nonisolated struct SEOPage: Equatable, Sendable {
    public let url: URL
    public let title: String?
    public let description: String?
    public let h1: [String]
    public let h2Count: Int
    public let canonical: String?
    public let robots: String?
    public let lang: String?
    public let openGraph: Bool
    public let structuredData: [String]
    public let images: Int
    public let imagesWithoutAlt: Int
    public let internalLinks: Int
    public let externalLinks: Int
    public let words: Int
    public let bytes: Int

    /// Plain findings, worst first: what a person would fix.
    public var issues: [String] {
        var found: [String] = []
        if title == nil { found.append("no <title>") } else if let title, title.count < 30 || title.count > 60 {
            found.append("title is \(title.count) characters (aim for 30–60)")
        }
        if description == nil { found.append("no meta description") } else if let description, description.count < 70 || description.count > 160 {
            found.append("meta description is \(description.count) characters (aim for 70–160)")
        }
        if h1.isEmpty { found.append("no <h1> heading") } else if h1.count > 1 { found.append("\(h1.count) <h1> headings (use one)") }
        if canonical == nil { found.append("no canonical link") }
        if robots?.lowercased().contains("noindex") == true { found.append("robots meta says noindex: search engines are told to skip it") }
        if lang == nil { found.append("no lang attribute on <html>") }
        if !openGraph { found.append("no Open Graph tags (link previews on social apps)") }
        if structuredData.isEmpty { found.append("no structured data (JSON-LD)") }
        if imagesWithoutAlt > 0 { found.append("\(imagesWithoutAlt) of \(images) images have no alt text") }
        if words < 300 { found.append("only about \(words) words of visible text") }
        if bytes > 1_500_000 { found.append("HTML is \(bytes / 1000) KB (heavy)") }
        if url.scheme != "https" { found.append("not served over HTTPS") }
        return found
    }

    static func measure(_ page: SitePage) -> SEOPage {
        let html = page.html
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            let value = WebSearch.decodeEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func all(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
            return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
                Range(match.range(at: 1), in: html).map { String(html[$0]) }
            }
        }
        let host = page.url.host()?.replacingOccurrences(of: "www.", with: "")
        let links = all(#"<a\b[^>]*href\s*=\s*["']([^"'#]+)["']"#).compactMap { URL(string: $0, relativeTo: page.url)?.absoluteURL }
            .filter { ["http", "https"].contains($0.scheme ?? "") }
        let inside = links.filter { $0.host()?.replacingOccurrences(of: "www.", with: "") == host }.count
        let images = all(#"(<img\b[^>]*>)"#)
        let types = all(#"<script[^>]*application/ld\+json[^>]*>([\s\S]*?)</script>"#).flatMap { block in
            (try? NSRegularExpression(pattern: #""@type"\s*:\s*"([^"]+)""#)).map { regex in
                regex.matches(in: block, range: NSRange(block.startIndex..., in: block)).compactMap { Range($0.range(at: 1), in: block).map { String(block[$0]) } }
            } ?? []
        }
        let h1s = all(#"<h1\b[^>]*>([\s\S]*?)</h1>"#).map {
            $0.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return SEOPage(
            url: page.url,
            title: first(#"<title[^>]*>([\s\S]*?)</title>"#),
            description: first(#"<meta[^>]+name\s*=\s*["']description["'][^>]*content\s*=\s*["']([^"']*)["']"#)
                ?? first(#"<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]*name\s*=\s*["']description["']"#),
            h1: h1s,
            h2Count: all(#"(<h2\b)"#).count,
            canonical: first(#"<link[^>]+rel\s*=\s*["']canonical["'][^>]*href\s*=\s*["']([^"']+)["']"#),
            robots: first(#"<meta[^>]+name\s*=\s*["']robots["'][^>]*content\s*=\s*["']([^"']*)["']"#),
            lang: first(#"<html[^>]*\blang\s*=\s*["']([^"']+)["']"#),
            openGraph: html.range(of: #"property\s*=\s*["']og:"#, options: .regularExpression) != nil,
            structuredData: Array(Set(types)).sorted(),
            images: images.count,
            imagesWithoutAlt: images.filter { $0.range(of: #"\balt\s*=\s*["'][^"']+["']"#, options: [.regularExpression, .caseInsensitive]) == nil }.count,
            internalLinks: inside,
            externalLinks: links.count - inside,
            words: page.source.text.split(whereSeparator: \.isWhitespace).count,
            bytes: html.utf8.count
        )
    }
}

/// The site-wide SEO picture: every page measured, plus robots.txt and the sitemap.
public nonisolated struct SEOReport: Equatable, Sendable {
    public let pages: [SEOPage]
    public let robotsTxt: Bool
    public let sitemap: Bool

    /// For the report and the model: one block of measured facts.
    public var summary: String {
        var lines = ["robots.txt: \(robotsTxt ? "found" : "missing"). sitemap.xml: \(sitemap ? "found" : "missing")."]
        lines += siteIssues
        if !commonIssues.isEmpty { lines.append("Every page: " + commonIssues.joined(separator: "; ") + ".") }
        for page in pages {
            let path = page.url.path().isEmpty ? "/" : page.url.path()
            var facts = ["title “\(page.title ?? "none")”", "\(page.words) words", "\(page.h2Count) h2",
                         "\(page.internalLinks) internal / \(page.externalLinks) external links"]
            if !page.structuredData.isEmpty { facts.append("structured data: " + page.structuredData.joined(separator: ", ")) }
            let own = issues(of: page)
            lines.append("\(path): " + facts.joined(separator: ", ") + (own.isEmpty ? "." : ". Issues: " + own.joined(separator: "; ") + "."))
        }
        return lines.joined(separator: "\n")
    }

    /// Issues every page has, said once rather than on every row.
    public var commonIssues: [String] {
        guard pages.count > 1, let first = pages.first else { return [] }
        return first.issues.filter { issue in pages.allSatisfy { $0.issues.contains(issue) } }
    }

    /// A page's issues apart from the ones every page has.
    public func issues(of page: SEOPage) -> [String] {
        let common = Set(commonIssues)
        return page.issues.filter { !common.contains($0) }
    }

    /// Problems across pages: every page with the same title or description.
    public var siteIssues: [String] {
        var found: [String] = []
        let titles = pages.compactMap(\.title), descriptions = pages.compactMap(\.description)
        if pages.count > 1, Set(titles).count == 1, titles.count == pages.count { found.append("All \(pages.count) pages share one title.") }
        if pages.count > 1, Set(descriptions).count == 1, descriptions.count == pages.count {
            found.append("All \(pages.count) pages share one meta description.")
        }
        return found
    }

    public static func check(_ pages: [SitePage], session: URLSession = .shared) async -> SEOReport? {
        guard let home = pages.first?.url, var root = URLComponents(url: home, resolvingAgainstBaseURL: false) else { return nil }
        root.path = ""
        root.query = nil
        func exists(_ path: String) async -> Bool {
            guard let url = root.url?.appending(path: path) else { return false }
            var request = URLRequest(url: url, timeoutInterval: WebSearch.timeout)
            request.setValue(WebSearch.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (_, response) = try? await session.data(for: request) else { return false }
            return ((response as? HTTPURLResponse)?.statusCode ?? 404) < 400
        }
        let robots = await exists("robots.txt"), sitemap = await exists("sitemap.xml")
        return SEOReport(pages: pages.map(SEOPage.measure), robotsTxt: robots, sitemap: sitemap)
    }
}
