//
//  WebSearch.swift
//  PetCore
//
//  The chat's web research (M21). Search goes to Parallel's free search (compact, question-relevant excerpts),
//  falling back to Firecrawl's keyless search; Wikipedia is asked directly; links in a message are fetched from this
//  device. What comes back is untrusted web text: it only ever enters prompts as passages, never as instructions.
//

import Foundation
import PDFKit

/// One page found on the web: its address, title, and the text worth keeping.
public nonisolated struct WebSource: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let text: String

    public var site: String { url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }

    /// The same page under another query string or fragment (e.g. `?changes=_3`) counts once.
    var pageKey: String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return (components?.string ?? url.absoluteString).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Drops repeats: the same page, or the same title on the same site.
    static func distinct(_ sources: [WebSource]) -> [WebSource] {
        var pages = Set<String>(), titles = Set<String>()
        return sources.filter { pages.insert($0.pageKey).inserted && titles.insert($0.site + "|" + $0.title.lowercased()).inserted }
    }
}

public nonisolated enum WebSearch {
    static let userAgent = "befriend/1.0 (iOS and macOS app; on-device assistant)"
    static let timeout: TimeInterval = 20
    /// Bigger pages are cut here before any parsing.
    static let maxDownload = 3_000_000
    /// Links read from one message.
    static let maxLinks = 3

    public enum Failure: LocalizedError {
        case unreachable(String), unreadable

        public var errorDescription: String? {
            switch self {
            case .unreachable(let site): "Couldn't reach \(site)."
            case .unreadable: "That page couldn't be read."
            }
        }
    }

    // MARK: Search

    /// Parallel first; Firecrawl if Parallel fails or finds nothing.
    public static func search(objective: String, queries: [String], session: URLSession = .shared) async throws -> [WebSource] {
        do {
            let found = try await parallel(objective: objective, queries: queries, session: session)
            if !found.isEmpty { return found }
        } catch {
            if error is CancellationError { throw error }
        }
        return try await firecrawl(query: queries.first ?? objective, session: session)
    }

    static let parallelEndpoint = URL(string: "https://search.parallel.ai/mcp")!

    /// Parallel's MCP server over plain HTTPS: one JSON-RPC `tools/call` of `web_search`.
    static func parallel(objective: String, queries: [String], session: URLSession) async throws -> [WebSource] {
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "web_search",
                       "arguments": ["objective": String(objective.prefix(200)), "search_queries": Array(queries.prefix(3)),
                                     "model_name": "apple-foundation-models"]],
        ]
        var request = URLRequest(url: parallelEndpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unreachable("Parallel Search") }
        return try parseParallel(data)
    }

    /// The tool result is JSON text inside the JSON-RPC result: `{"results":[{url,title,excerpts:[…]}]}`.
    static func parseParallel(_ data: Data) throws -> [WebSource] {
        struct RPC: Decodable {
            struct Result: Decodable {
                struct Content: Decodable { let text: String? }
                let content: [Content]
            }
            let result: Result?
        }
        struct Found: Decodable {
            struct Item: Decodable {
                let url: String
                let title: String?
                let excerpts: [String]?
            }
            let results: [Item]
        }
        guard let text = try JSONDecoder().decode(RPC.self, from: data).result?.content.compactMap(\.text).first,
              let json = text.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode(Found.self, from: json).results.compactMap { item in
            guard let url = URL(string: item.url), let excerpts = item.excerpts, !excerpts.isEmpty else { return nil }
            return WebSource(url: url, title: item.title ?? url.absoluteString, text: excerpts.joined(separator: "\n\n"))
        }
    }

    static let firecrawlEndpoint = URL(string: "https://api.firecrawl.dev/v2/search")!

    /// Firecrawl's keyless search, with each result's page as Markdown. It refuses some networks without a key.
    static func firecrawl(query: String, session: URLSession) async throws -> [WebSource] {
        var request = URLRequest(url: firecrawlEndpoint, timeoutInterval: timeout * 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["query": query, "limit": 5, "scrapeOptions": ["formats": ["markdown"], "onlyMainContent": true]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unreachable("web search") }
        return try parseFirecrawl(data)
    }

    static func parseFirecrawl(_ data: Data) throws -> [WebSource] {
        struct Reply: Decodable {
            struct Item: Decodable {
                let url: String
                let title: String?
                let description: String?
                let markdown: String?
            }
            struct Results: Decodable { let web: [Item]? }
            let success: Bool
            let data: Results?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.success else { throw Failure.unreachable("web search") }
        return (reply.data?.web ?? []).compactMap { item in
            guard let url = URL(string: item.url), let text = item.markdown ?? item.description, !text.isEmpty else { return nil }
            return WebSource(url: url, title: item.title ?? url.absoluteString, text: text)
        }
    }

    // MARK: Wikipedia

    /// The best-matching English Wikipedia articles' summaries.
    public static func wikipedia(_ query: String, limit: Int = 2, session: URLSession = .shared) async throws -> [WebSource] {
        var search = URLComponents(string: "https://en.wikipedia.org/w/rest.php/v1/search/page")!
        search.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        struct Pages: Decodable {
            struct Page: Decodable { let key: String }
            let pages: [Page]
        }
        struct Summary: Decodable {
            let title: String
            let extract: String?
            let content_urls: [String: [String: String]]?
        }
        let pages = try JSONDecoder().decode(Pages.self, from: try await get(search.url!, session: session)).pages
        var sources: [WebSource] = []
        for page in pages {
            let key = page.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page.key
            guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(key)"),
                  let summary = try? JSONDecoder().decode(Summary.self, from: try await get(url, session: session)),
                  let extract = summary.extract, !extract.isEmpty else { continue }
            let link = summary.content_urls?["desktop"]?["page"].flatMap(URL.init(string:))
                ?? URL(string: "https://en.wikipedia.org/wiki/\(key)")!
            sources.append(WebSource(url: link, title: summary.title + " – Wikipedia", text: extract))
        }
        return sources
    }

    // MARK: Links

    /// http(s) links in a message, at most `maxLinks`.
    public static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var seen = Set<URL>()
        return matches.compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme?.lowercased()) && seen.insert($0).inserted }
            .prefix(maxLinks)
            .map { $0 }
    }

    /// Reads a page (HTML, plain text or PDF) from this device.
    public static func fetch(_ url: URL, session: URLSession = .shared) async throws -> WebSource {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.unreachable(url.host() ?? url.absoluteString)
        }
        let body = data.prefix(maxDownload)
        let type = http.mimeType ?? ""
        if type == "application/pdf" || url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(data: Data(body)), let text = pdf.string, !text.isEmpty else { throw Failure.unreadable }
            return WebSource(url: url, title: pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? url.lastPathComponent,
                             text: text)
        }
        let raw = String(decoding: body, as: UTF8.self)
        guard type.contains("html") else {
            guard type.hasPrefix("text/"), !raw.isEmpty else { throw Failure.unreadable }
            return WebSource(url: url, title: url.lastPathComponent, text: raw)
        }
        let page = readable(html: raw)
        guard !page.text.isEmpty else { throw Failure.unreadable }
        return WebSource(url: url, title: page.title ?? url.host() ?? url.absoluteString, text: page.text)
    }

    // ponytail: tag stripping, not a real readability parser; good enough for articles and docs pages.
    /// The visible text of a page: scripts, styles and markup dropped, block ends kept as line breaks.
    static func readable(html: String) -> (title: String?, text: String) {
        let title = firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html).map(decodeEntities)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var text = html
        for pattern in [#"<(script|style|noscript|svg|template|head|nav|footer|form)\b[\s\S]*?</\1>"#, #"<!--[\s\S]*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>"#, with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return (title?.isEmpty == false ? title : nil, lines.joined(separator: "\n"))
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
                                    ("&rdquo;", "”"), ("&ldquo;", "“")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        let numeric = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        for match in (numeric?.matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []).reversed() {
            guard let range = Range(match.range, in: result), let hex = Range(match.range(at: 1), in: result),
                  let digits = Range(match.range(at: 2), in: result),
                  let code = UInt32(result[digits], radix: result[hex].isEmpty ? 10 : 16),
                  let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(range, with: String(Character(scalar)))
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func get(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unreachable(url.host() ?? "the site") }
        return data
    }
}
