//
//  WebPreview.swift
//  PetCore
//
//  A small web view for chat previews, kept local: network loads are blocked and links don't navigate. Mermaid
//  runs the bundled mermaid.js (strict mode) on a page of our own, with the diagram inserted as text. Model-written
//  HTML is shown with its scripts turned off.
//

import SwiftUI
import WebKit

struct WebPreview: View {
    enum Kind: Equatable {
        case mermaid(String)
        case html(String)
    }

    let kind: Kind
    @State private var height: CGFloat = 80
    @State private var failure: String?
    private static let maxHeight: CGFloat = 600

    var body: some View {
        if let failure {
            Label("Couldn't draw this: \(failure)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        } else {
            WebBox(kind: kind, height: $height, failure: $failure)
                .frame(height: min(height, Self.maxHeight))
                .accessibilityLabel(kind.isMermaid ? "Diagram" : "HTML preview")
        }
    }
}

private extension WebPreview.Kind {
    var isMermaid: Bool { if case .mermaid = self { true } else { false } }
}

#if os(macOS)
private typealias ViewRepresentable = NSViewRepresentable
#else
private typealias ViewRepresentable = UIViewRepresentable
#endif

private struct WebBox: ViewRepresentable {
    let kind: WebPreview.Kind
    @Binding var height: CGFloat
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view) }
    #else
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view) }
    #endif

    private func make(_ context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = kind.isMermaid
        config.userContentController.add(context.coordinator, name: "done")
        config.userContentController.add(context.coordinator, name: "failed")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        #endif
        let html = page
        Task { @MainActor in
            if let rules = await Self.offline() { config.userContentController.add(rules) }
            view.loadHTMLString(html, baseURL: nil)
        }
        return view
    }

    private static func dismantle(_ view: WKWebView) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.stopLoading()
    }

    private var page: String {
        switch kind {
        case .html(let html): return html
        case .mermaid(let diagram): return Self.mermaidPage(diagram)
        }
    }

    // MARK: Mermaid

    private static let mermaidJS: String = Bundle.module.url(forResource: "mermaid.min", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    static func mermaidPage(_ diagram: String) -> String {
        // JSONEncoder escapes "/" as "\/", so the diagram can't close the script tag.
        let literal = (try? JSONEncoder().encode(diagram)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>html,body{margin:0;padding:8px;background:transparent;font:13px -apple-system,sans-serif}
            svg{max-width:100%;height:auto}</style>
            <script>\(mermaidJS)</script></head>
            <body><div id="d"></div><script>
            (async () => {
              const dark = matchMedia('(prefers-color-scheme: dark)').matches;
              mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default' });
              try {
                const { svg } = await mermaid.render('diagram', \(literal));
                document.getElementById('d').innerHTML = svg;
                webkit.messageHandlers.done.postMessage(document.getElementById('d').getBoundingClientRect().height + 16);
              } catch (e) {
                webkit.messageHandlers.failed.postMessage(String(e && e.message || e));
              }
            })();
            </script></body></html>
            """
    }

    // MARK: Offline

    private static var rules: WKContentRuleList?

    /// Blocks every network load, so a preview never reaches the internet.
    @MainActor private static func offline() async -> WKContentRuleList? {
        if let rules { return rules }
        let json = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]"#
        rules = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "befriend-chat-offline",
                                                                                   encodedContentRuleList: json)
        return rules
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebBox

        init(_ parent: WebBox) {
            self.parent = parent
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "done", let height = message.body as? Double {
                parent.height = height
            } else if message.name == "failed" {
                parent.failure = (message.body as? String).map { String($0.prefix(160)) } ?? "unknown error"
            }
        }

        /// Only the page itself loads: links and redirects are refused.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.navigationType == .other && (action.request.url?.scheme ?? "about") == "about" ? .allow : .cancel
        }

        /// HTML runs no scripts of its own, so its height is measured from here.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard case .html = parent.kind else { return }
            Task { @MainActor in
                if let height = try? await webView.callAsyncJavaScript("return document.body.scrollHeight",
                                                                       contentWorld: .defaultClient) as? Double {
                    parent.height = height
                }
            }
        }
    }
}
