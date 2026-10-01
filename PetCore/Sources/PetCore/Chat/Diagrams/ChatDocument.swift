//
//  ChatDocument.swift
//  PetCore
//
//  Documents as HTML (M29): Markdown becomes one styled page with its ```mermaid blocks drawn by the bundled
//  mermaid.js. That page is the .html export (diagrams inlined as SVG, no script) and, printed to A4 by WebKit, the
//  PDF. Blocks that would straddle a page edge are pushed onto the next page before the page is cut.
//

import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public nonisolated enum ChatHTML {
    /// The page for `markdown`; `diagrams` holds each mermaid block's source, drawn into `<div id="dgN">`.
    static func page(_ markdown: String, title: String) -> (html: String, diagrams: [String]) {
        var diagrams: [String] = []
        var body: [String] = []
        for block in MarkdownBlock.parse(markdown) {
            switch block.kind {
            case .heading(let level): body.append("<h\(min(level, 4))>\(inline(block.text))</h\(min(level, 4))>")
            case .paragraph: body.append("<p>\(inline(block.text))</p>")
            case .quote: body.append("<blockquote>\(inline(block.text))</blockquote>")
            case .listItem(let depth, let marker):
                body.append("<div class=\"li\" style=\"margin-left:\((depth - 1) * 18)px\"><span class=\"m\">\(escape(marker))</span><span>\(inline(block.text))</span></div>")
            case .code(let language) where language == "mermaid":
                body.append("<pre class=\"code\" id=\"dg\(diagrams.count)\"><code>\(escape(block.plain))</code></pre>")
                diagrams.append(block.plain)
            case .code: body.append("<pre class=\"code\"><code>\(escape(block.plain))</code></pre>")
            case .table(let rows):
                let lines = rows.enumerated().map { index, row in
                    "<tr>" + row.map { index == 0 ? "<th>\(inline($0))</th>" : "<td>\(inline($0))</td>" }.joined() + "</tr>"
                }
                body.append("<table>" + lines.joined() + "</table>")
            }
        }
        let html = """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="color-scheme" content="light">
            <meta name="viewport" content="width=device-width, initial-scale=1"><title>\(escape(title))</title>
            <style>\(style)</style></head><body>
            \(body.joined(separator: "\n"))
            </body></html>
            """
        return (html, diagrams)
    }

    static let style = """
        body{margin:0 auto;max-width:760px;padding:0 48px;color:#1d1d1f;background:#fff;
        font:11pt/1.5 -apple-system,"Helvetica Neue",sans-serif}
        h1{font-size:22pt;margin:0 0 10px}h2{font-size:15pt;margin:18px 0 6px}h3,h4{font-size:12pt;margin:14px 0 4px}
        p{margin:0 0 8px}blockquote{margin:0 0 8px;padding-left:12px;border-left:3px solid #ccc;color:#555;font-style:italic}
        .li{margin-bottom:3px;display:flex;gap:6px}.li .m{min-width:14px;color:#666}
        pre.code{background:#f4f4f6;border-radius:6px;padding:10px;font:9pt ui-monospace,Menlo,monospace;white-space:pre-wrap}
        .diagram{margin:10px 0;text-align:center}.diagram svg{max-width:100%;height:auto}
        table{border-collapse:collapse;margin:6px 0 12px;font-size:10pt}th,td{border:1px solid #ddd;padding:4px 8px;text-align:left}
        th{background:#f4f4f6}code{font-family:ui-monospace,Menlo,monospace;font-size:.92em}a{color:#0066cc}
        """

    /// Bold, italic, code, strikethrough and links from the parsed Markdown; everything escaped.
    static func inline(_ text: AttributedString) -> String {
        text.runs.map { run in
            var piece = escape(String(text[run.range].characters))
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
            if intent.contains(.strikethrough) { piece = "<s>\(piece)</s>" }
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>"
            }
            return piece
        }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Draws a document's diagrams in WebKit, then hands back the self-contained HTML and the A4 PDF.
@MainActor
public enum ChatDocumentRenderer {
    public enum Failure: LocalizedError {
        case timedOut, noPDF, drawing(String)
        public var errorDescription: String? {
            switch self {
            case .timedOut: "Drawing took too long."
            case .noPDF: "Couldn't make the PDF."
            case .drawing(let reason): "Couldn't draw this diagram: \(reason)"
            }
        }
    }

    static let page = CGSize(width: 595, height: 842) // A4 in points (= CSS px)
    static let margin: CGFloat = 48

    public static func render(_ markdown: String, title: String) async throws -> (html: Data, pdf: Data) {
        let built = ChatHTML.page(markdown, title: title)
        let script = """
            <script>\(MermaidPage.script)</script><script>
            (async () => {
              const sources = \(MermaidPage.literal(built.diagrams.joined(separator: "\u{1E}"))).split('\\u001e').filter(s => s);
              mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'default' });
              for (const [i, src] of sources.entries()) {
                const el = document.getElementById('dg' + i);
                try { const { svg } = await mermaid.render('m' + i, src); el.outerHTML = '<div class="diagram">' + svg + '</div>'; }
                catch (e) { /* stays as code */ }
              }
              document.querySelectorAll('script').forEach(s => s.remove());
              const html = '<!doctype html>\\n' + document.documentElement.outerHTML;
              document.body.style.padding = '0 \(Int(margin))px';
              const h = \(Int(page.height - margin * 2));
              const items = [...document.body.children].flatMap(e => e.tagName === 'TABLE' ? [...e.rows].slice(1) : [e]);
              for (const el of items) {
                if (el.tagName === 'TR' && el === el.closest('table').rows[0]) continue;
                const r = el.getBoundingClientRect(), top = r.top + scrollY, edge = (Math.floor(top / h) + 1) * h;
                // A heading stays with the start of what follows it.
                const next = /^H[1-4]$/.test(el.tagName) && el.nextElementSibling;
                const n = next && next.getBoundingClientRect();
                const bottom = (n ? (n.height < h - r.height ? n.bottom : n.top + 60) : r.bottom) + scrollY;
                if (bottom <= edge || bottom - top >= h) continue;
                const s = document.createElement('div'); s.style.height = (edge - top) + 'px';
                if (el.tagName === 'TR') {
                  // The table splits: the rest moves to a new table on the next page, under a copy of the header.
                  const table = el.closest('table'), rest = table.cloneNode(false), rows = [...table.rows];
                  rest.appendChild(rows[0].cloneNode(true));
                  rows.slice(rows.indexOf(el)).forEach(r => rest.appendChild(r));
                  table.after(s); s.after(rest);
                } else { el.before(s); }
              }
              webkit.messageHandlers.ready.postMessage(html);
            })();
            </script>
            """
        let html = built.html.replacingOccurrences(of: "</body></html>", with: script + "</body></html>")
        let (webView, loader) = load(html, size: page)
        defer { webView.configuration.userContentController.removeAllScriptMessageHandlers() }
        let exported = try await loader.wait(seconds: 30)
        let tall = try await webView.pdf(configuration: WKPDFConfiguration())
        return (Data(exported.utf8), try paginate(tall, title: title))
    }

    /// One diagram drawn light, for Save as SVG / PNG (PNG at 2×).
    public static func diagram(_ mermaid: String) async throws -> (svg: Data, png: Data) {
        let width: CGFloat = 900
        let (webView, loader) = load(MermaidPage.html(mermaid, export: true), size: CGSize(width: width, height: 600))
        defer { webView.configuration.userContentController.removeAllScriptMessageHandlers() }
        let svg = try await loader.wait(seconds: 20)
        webView.frame.size.height = max(40, loader.height)
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(x: 0, y: 0, width: width, height: max(40, loader.height))
        snapshot.snapshotWidth = NSNumber(value: Double(width * 2))
        let image = try await webView.takeSnapshot(configuration: snapshot)
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw Failure.drawing("no image") }
        #else
        guard let png = image.pngData() else { throw Failure.drawing("no image") }
        #endif
        return (Data(svg.utf8), png)
    }

    private static func load(_ html: String, size: CGSize) -> (WKWebView, Loader) {
        let loader = Loader()
        let configuration = WKWebViewConfiguration()
        for name in ["ready", "done", "failed"] { configuration.userContentController.add(loader, name: name) }
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        webView.loadHTMLString(html, baseURL: nil)
        return (webView, loader)
    }

    /// Cuts one tall page into A4 pages with margins.
    static func paginate(_ tall: Data, title: String) throws -> Data {
        guard let provider = CGDataProvider(data: tall as CFData), let source = CGPDFDocument(provider), let first = source.page(at: 1)
        else { throw Failure.noPDF }
        let box = first.getBoxRect(.mediaBox)
        let slice = page.height - margin * 2
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, [kCGPDFContextTitle: title, kCGPDFContextCreator: "befriend"] as CFDictionary)
        else { throw Failure.noPDF }
        let count = max(1, Int((box.height / slice).rounded(.up)))
        for index in 0..<count {
            context.beginPDFPage(nil)
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: margin, width: page.width, height: slice))
            // The slice starting `index * slice` from the top lands between the margins.
            context.translateBy(x: (page.width - box.width) / 2 - box.minX,
                                y: margin - (box.height - CGFloat(index + 1) * slice) - box.minY)
            context.drawPDFPage(first)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private final class Loader: NSObject, WKScriptMessageHandler {
        private var continuation: CheckedContinuation<String, Error>?
        private var result: Result<String, Error>?
        /// A diagram's drawn height ("done").
        private(set) var height: CGFloat = 0

        /// "ready" carries the page's HTML, "done" a diagram's {height, svg}, "failed" the reason.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let outcome: Result<String, Error>
            switch message.name {
            case "done":
                let body = message.body as? [String: Any]
                height = CGFloat(body?["height"] as? Double ?? 0)
                outcome = .success(body?["svg"] as? String ?? "")
            case "failed": outcome = .failure(Failure.drawing((message.body as? String).map { String($0.prefix(160)) } ?? "unknown error"))
            default: outcome = .success(message.body as? String ?? "")
            }
            if let continuation { self.continuation = nil; continuation.resume(with: outcome) } else { result = outcome }
        }

        func wait(seconds: Double) async throws -> String {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    if let pending = self?.continuation { self?.continuation = nil; pending.resume(throwing: Failure.timedOut) }
                }
            }
        }
    }
}
