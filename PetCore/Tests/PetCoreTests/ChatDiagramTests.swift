import Foundation
import Testing
import PDFKit
import WebKit
@testable import PetCore

struct ChatDiagramTests {
    static let samples: [ChatDiagram] = [
        .flowchart(title: "Sign up: the \"happy\" path", leftToRight: false,
                   nodes: [.init(id: "a", label: "Open app", shape: "start"), .init(id: "b", label: "Has account? (yes/no)", shape: "decision"),
                           .init(id: "c", label: "Create account; verify [email]", shape: "step")],
                   edges: [.init(from: "a", to: "b", label: nil), .init(from: "b", to: "c", label: "no: sign up"), .init(from: "c", to: "Done", label: "")]),
        .sequence(title: "Unbind", participants: ["App", "Backend"],
                  messages: [.init(from: "App", to: "Backend", text: "POST /unbind; serial: 12", reply: false),
                             .init(from: "Backend", to: "Camera", text: "release", reply: false), .init(from: "Backend", to: "App", text: "409 (1.1.x)", reply: true)]),
        .mindmap(root: "Antartech (software house)", branches: [.init(label: "Services: web & app", children: ["Branding", "IT outsourcing"]),
                                                               .init(label: "Clients", children: ["Sparknickel", "MGW Logistics"])]),
        .timeline(title: "Launch", periods: [.init(period: "May 2: rehearsal", events: ["15:00 run-through"]), .init(period: "May 3", events: ["Launch", "Press call"])]),
        .gantt(title: "Launch prep", tasks: [.init(section: "Design", name: "Press kit", start: "2026-10-05", days: 3),
                                             .init(section: "Design", name: "Slides: v2", start: "2026-10-08", days: 2),
                                             .init(section: "Ops", name: "Venue", start: "2026-10-06", days: 0)]),
        .pie(title: "Budget", slices: [.init(label: "Venue \"Grand Hall\"", value: 4500), .init(label: "Catering", value: 2800), .init(label: "Zero", value: 0)]),
    ]

    @Test func mermaidLooksRight() {
        let flow = Self.samples[0].mermaid
        #expect(flow.contains("flowchart TD") && flow.contains("n1([\"Open app\"])") && flow.contains("n2{\"Has account? (yes/no)\"}"))
        #expect(flow.contains("n2 -->|\"no: sign up\"| n3") && flow.contains("[\"Done\"]"), "undeclared nodes get a box")
        #expect(flow.contains("#quot;happy#quot;") == false && flow.contains("title: Sign up the happy path"))
        #expect(Self.samples[4].mermaid.contains("Venue :t3, 2026-10-06, 1d"), "zero-day tasks last a day")
        #expect(!Self.samples[5].mermaid.contains("Zero") && Self.samples[5].mermaid.contains("\"Venue #quot;Grand Hall#quot;\" : 4500"))
    }

    /// Every kind, with awkward labels, renders in the bundled mermaid.js.
    @MainActor @Test func everyKindRendersInMermaid() async throws {
        for diagram in Self.samples {
            let result = try await Self.render(diagram.mermaid)
            #expect(result.hasPrefix("done"), "\(diagram.kind): \(result)")
        }
    }

    @MainActor static func render(_ mermaid: String) async throws -> String {
        final class Handler: NSObject, WKScriptMessageHandler {
            var result: String?
            func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
                result = m.name == "done" ? "done" : "failed: \(m.body)"
            }
        }
        let handler = Handler()
        let config = WKWebViewConfiguration()
        config.userContentController.add(handler, name: "done")
        config.userContentController.add(handler, name: "failed")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        web.loadHTMLString(MermaidPage.html(mermaid), baseURL: nil)
        for _ in 0..<200 where handler.result == nil { try await Task.sleep(for: .milliseconds(50)) }
        return handler.result ?? "timeout"
    }
}

struct ChatDocumentTests {
    @Test func htmlEscapesAndKeepsStructure() {
        let page = ChatHTML.page("# Plan <b>\n\n**Bold** and [link](https://a.co) and [bad](javascript:alert(1))\n\n- one\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```mermaid\npie\n  \"x\" : 1\n```", title: "T")
        #expect(page.html.contains("<h1>Plan &lt;b&gt;</h1>") && page.html.contains("<strong>Bold</strong>"))
        #expect(page.html.contains("<a href=\"https://a.co\">link</a>") && !page.html.contains("javascript:"))
        #expect(page.html.contains("<th>A</th>") && page.html.contains("<td>2</td>") && page.diagrams.count == 1)
    }

    @MainActor @Test func rendersDiagramsIntoHTMLAndPagedPDF() async throws {
        let text = (1...60).map { "Paragraph \($0) with enough words to wrap across the line and fill the page quickly." }.joined(separator: "\n\n")
        let markdown = "# Report\n\n" + ChatDiagramTests.samples[0].markdown + "\n\n" + text
        let output = try await ChatDocumentRenderer.render(markdown, title: "Report")
        let html = String(decoding: output.html, as: UTF8.self)
        #expect(html.contains("<svg") && !html.contains("<script"), "diagram inlined, script dropped")
        let pdf = try #require(PDFDocument(data: output.pdf))
        #expect(pdf.pageCount >= 3 && pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 595, height: 842))
        #expect(pdf.string?.contains("Paragraph 60") == true)
        try? output.pdf.write(to: URL(filePath: NSTemporaryDirectory()).appending(path: "befriend-doc.pdf"))
    }
}

struct DiagramIntentTests {
    @Test func picksKindAndDetectsRequests() {
        #expect(DiagramIntent.kind("draw a flowchart of the signup") == .flowchart)
        #expect(DiagramIntent.kind("make a mind map of antartech") == .mindmap)
        #expect(DiagramIntent.kind("sequence diagram for the unbind API call") == .sequence)
        #expect(DiagramIntent.kind("a gantt chart for the launch schedule") == .gantt)
        #expect(DiagramIntent.kind("pie chart of the budget breakdown") == .pie)
        #expect(DiagramIntent.kind("timeline of the company history") == .timeline)
        #expect(DiagramIntent.detect("Draw a flowchart of how login works"))
        #expect(DiagramIntent.detect("can you make me a mind map about this?"))
        #expect(!DiagramIntent.detect("what is a flowchart?"))
        #expect(FileIntent.detect("make a flowchart of the signup") == nil, "a diagram, not a file")
        #expect(FileIntent.detect("export this as an HTML page") == .html)
        #expect(DiagramIntent.mentions("write a PDF report with a flowchart"))
        #expect(ChatCommand.parse("/diagram mind map of my week")?.command.action == .diagram)
    }

    @MainActor @Test func diagramExportsAsSVGAndPNG() async throws {
        let drawn = try await ChatDocumentRenderer.diagram(ChatDiagramTests.samples[0].mermaid)
        let svg = String(decoding: drawn.svg, as: UTF8.self)
        #expect(svg.hasPrefix("<svg") && !svg.contains("foreignObject"), "plain SVG labels")
        #expect(drawn.png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        await #expect(throws: ChatDocumentRenderer.Failure.self) { try await ChatDocumentRenderer.diagram("flowchart TD\n  a --> ") }
    }
}

struct DiagramWiringTests {
    @Test func flowStepsBecomeArrows() {
        let steps: [DiagramMaker.FlowStep] = [
            .init(label: "Open app", question: false, ifNo: "", next: ""),
            .init(label: "Has account?", question: true, ifNo: "Create account", next: ""),
            .init(label: "Log in", question: false, ifNo: "", next: "Home"),
            .init(label: "Create account", question: false, ifNo: "", next: ""),
            .init(label: "Verify email", question: false, ifNo: "", next: ""),
            .init(label: "Home", question: false, ifNo: "", next: ""),
        ]
        let mermaid = DiagramMaker.flowchart(title: "", steps: steps).mermaid
        #expect(mermaid.contains("n1([\"Open app\"])") && mermaid.contains("n2{\"Has account?\"}") && mermaid.contains("n6([\"Home\"])"))
        #expect(mermaid.contains("n2 -->|\"yes\"| n3") && mermaid.contains("n2 -->|\"no\"| n4"))
        #expect(mermaid.contains("n3 --> n6") && !mermaid.contains("n3 --> n4") && mermaid.contains("n5 --> n6"))
    }

    @Test func ganttChainsDates() {
        let chart = DiagramMaker.gantt(title: "Launch", start: "2026-11-02", steps: [
            .init(section: "Make", name: "Design", days: 5, alongside: false),
            .init(section: "Make", name: "Copy", days: 2, alongside: true),
            .init(section: "Make", name: "Build", days: 10, alongside: false),
            .init(section: "Ship", name: "Launch", days: 0, alongside: false),
        ])
        let mermaid = chart.mermaid
        #expect(mermaid.contains("Design :t1, 2026-11-02, 5d") && mermaid.contains("Copy :t2, 2026-11-02, 2d"))
        #expect(mermaid.contains("Build :t3, 2026-11-07, 10d") && mermaid.contains("Launch :t4, 2026-11-17, 1d"))
    }
}

extension DiagramWiringTests {
    @Test func repliesAreInferred() {
        let messages = DiagramMaker.replies([("App", "Backend", "unbind"), ("Backend", "Camera", "release"),
                                             ("Camera", "Backend", "done"), ("Backend", "App", "ok"), ("Backend", "App", "extra")])
        #expect(messages.map(\.reply) == [false, false, true, true, false])
    }
}



extension ChatDocumentTests {
    @MainActor @Test func headingsStayWithWhatFollows() async throws {
        // Enough paragraphs that "## Late heading" falls at the bottom of page 1.
        for count in 20...24 {
            let text = (1...count).map { "Line \($0) of filler." }.joined(separator: "\n\n") + "\n\n## Late heading\n\nAfter it."
            let pdf = try #require(PDFDocument(data: try await ChatDocumentRenderer.render(text, title: "T").pdf))
            // Clipped text still extracts, so read only each page's visible area.
            func visible(_ index: Int) -> String { pdf.page(at: index)?.selection(for: CGRect(x: 0, y: 50, width: 595, height: 742))?.string ?? "" }
            let page = (0..<pdf.pageCount).first { visible($0).contains("After it") } ?? 0
            #expect(visible(page).contains("Late heading"), "heading split from its text at \(count)")
        }
    }
}

extension DiagramWiringTests {
    @Test func diagramGoesUnderItsHeading() {
        let diagram = ChatDiagramTests.samples[5]
        let placed = ChatFileMaker.placing(diagram, in: "# Guide\n\nIntro.\n\n## Flowchart\n\n[Image of flowchart]\n\n## Next steps\n\nGo.")
        #expect(placed.contains("## Flowchart\n\n```mermaid") && !placed.contains("[Image of") && placed.contains("## Next steps\n\nGo."))
        let appended = ChatFileMaker.placing(diagram, in: "# Guide\n\nIntro.")
        #expect(appended.hasSuffix("## Pie chart\n\n" + diagram.markdown + "\n"))
    }
}

extension DiagramWiringTests {
    @Test func looseStepsAreReached() {
        let mermaid = DiagramMaker.flowchart(title: "", steps: [
            .init(label: "Open app", question: false, ifNo: "", next: "Sign up"),
            .init(label: "Log in", question: false, ifNo: "", next: "Home"),
            .init(label: "Sign up", question: false, ifNo: "", next: "Home"),
            .init(label: "Home", question: false, ifNo: "", next: ""),
        ]).mermaid
        #expect(mermaid.contains("n1 --> n3") && mermaid.contains("n1 --> n2"), "Log in gets an arrow")
    }
}

extension ChatDocumentTests {
    @MainActor @Test func headingStaysWithItsDiagram() async throws {
        for count in 14...22 {
            let text = (1...count).map { "Line \($0) of filler." }.joined(separator: "\n\n") + "\n\n## Flowchart\n\n" + ChatDiagramTests.samples[0].markdown
            let pdf = try #require(PDFDocument(data: try await ChatDocumentRenderer.render(text, title: "T").pdf))
            func visible(_ index: Int) -> String { pdf.page(at: index)?.selection(for: CGRect(x: 0, y: 50, width: 595, height: 742))?.string ?? "" }
            let diagram = (0..<pdf.pageCount).first { visible($0).contains("Open app") } ?? 0
            #expect(visible(diagram).contains("Flowchart"), "heading left behind at \(count)")
        }
    }
}

extension DiagramWiringTests {
    /// The flowchart from the Fazz chat: "go to step 6" became boxes, and a failed check led to "Payment successful".
    @Test func noIsAnOutcomeAndStepNumbersResolve() {
        let mermaid = DiagramMaker.flowchart(title: "Fazz Payment Flowchart", steps: [
            .init(label: "Payment initiated", question: false, ifNo: "", next: ""),
            .init(label: "Account details retrieved", question: false, ifNo: "", next: ""),
            .init(label: "Authenticated", question: true, ifNo: "Payment declined", next: ""),
            .init(label: "Payment processed", question: false, ifNo: "", next: "go to step 5"),
            .init(label: "Payment complete", question: false, ifNo: "", next: ""),
        ]).mermaid
        #expect(!mermaid.contains("Go to step") && !mermaid.contains("go to step"))
        #expect(mermaid.contains("n3{\"Authenticated?\"}") && mermaid.contains("n3 -->|\"yes\"| n4") && mermaid.contains("n4 --> n5"))
        #expect(mermaid.contains("n6([\"Payment declined\"])") && mermaid.contains("n3 -->|\"no\"| n6"))
        #expect(!mermaid.contains("n6 -->"), "a declined payment ends; it doesn't lead to success")
    }

    @Test func noOutcomeCanRejoinAndStepReferencesWork() {
        let mermaid = DiagramMaker.flowchart(title: "", steps: [
            .init(label: "Open app", question: false, ifNo: "", next: ""),
            .init(label: "Has account?", question: true, ifNo: "Create account", noThen: "Home", next: ""),
            .init(label: "Log in", question: false, ifNo: "", next: ""),
            .init(label: "Home", question: false, ifNo: "", next: ""),
            .init(label: "Retry?", question: true, ifNo: "step 1", next: "step 4"),
        ]).mermaid
        #expect(mermaid.contains("n6[\"Create account\"]") && mermaid.contains("n2 -->|\"no\"| n6") && mermaid.contains("n6 --> n4"))
        #expect(mermaid.contains("n5 -->|\"no\"| n1") && !mermaid.contains("n5 -->|\"yes\"| n4"), "yes never points back")
    }
}

extension DiagramWiringTests {
    @Test func startsWithAStepAndSharesOutcomes() {
        let mermaid = DiagramMaker.flowchart(title: "", steps: [
            .init(label: "Customer orders coffee?", question: true, ifNo: "Offer another drink", next: ""),
            .init(label: "In stock?", question: true, ifNo: "Offer another drink", noThen: "Pay", next: ""),
            .init(label: "Milk available?", question: true, ifNo: "Offer another drink", noThen: "Pay", next: ""),
            .init(label: "Pay", question: false, ifNo: "", next: ""),
        ]).mermaid
        #expect(mermaid.contains("n1([\"Customer orders coffee\"])"))
        #expect(mermaid.components(separatedBy: "Offer another drink").count == 2, "one shared box")
        #expect(mermaid.contains("n2 -->|\"no\"| n5") && mermaid.contains("n3 -->|\"no\"| n5") && mermaid.contains("n5 --> n4"))
    }
}

extension DiagramWiringTests {
    @Test func rewordedStepsAreTheSameStep() {
        #expect(DiagramMaker.sameStep("retrieve account details", "account details retrieved"))
        #expect(DiagramMaker.sameStep("process payment", "payment processed"))
        #expect(!DiagramMaker.sameStep("create account", "log in"))
        let mermaid = DiagramMaker.flowchart(title: "", steps: [
            .init(label: "Payment initiated", question: false, ifNo: "", next: "Retrieve Account Details"),
            .init(label: "Account details retrieved", question: false, ifNo: "", next: "Authenticate User"),
            .init(label: "Payment complete", question: false, ifNo: "", next: ""),
        ]).mermaid
        #expect(!mermaid.contains("Retrieve Account Details") && !mermaid.contains("Authenticate User"))
        #expect(mermaid.contains("n1 --> n2") && mermaid.contains("n2 --> n3"))
    }
}

extension DiagramWiringTests {
    @Test func noBranchRightAfterTheDecision() {
        let mermaid = DiagramMaker.flowchart(title: "", steps: [
            .init(label: "Open app", question: false, ifNo: "", next: ""),
            .init(label: "Has account?", question: true, ifNo: "Create account", next: ""),
            .init(label: "Create account", question: false, ifNo: "", next: ""),
            .init(label: "Verify email", question: false, ifNo: "", next: ""),
            .init(label: "Home", question: false, ifNo: "", next: ""),
        ]).mermaid
        #expect(mermaid.contains("n2 -->|\"no\"| n3") && mermaid.contains("n2 -->|\"yes\"| n5") && mermaid.contains("n3 --> n4") && mermaid.contains("n4 --> n5"))
        #expect(mermaid.components(separatedBy: "Create account").count == 2, "no duplicate box")
    }
}

extension DiagramWiringTests {
    /// The second Fazz flowchart: "Go to step 6" and "Go to step 7" listed as steps themselves.
    @Test func referenceStepsAreRemoved() {
        let step = { (label: String) in DiagramMaker.FlowStep(label: label, question: false, ifNo: "", next: "") }
        let mermaid = DiagramMaker.flowchart(title: "Fazz Payment Flowchart", steps: [
            step("Payment initiated"), step("Account details retrieved"), step("Authentication requested"),
            step("Authentication granted"), step("Payment processed"),
            .init(label: "Go to step 6", question: true, ifNo: "Payment declined", next: ""),
            step("Go to step 7"), step("Payment successful"), step("Payment complete"),
        ]).mermaid
        #expect(!mermaid.localizedCaseInsensitiveContains("step 6") && !mermaid.localizedCaseInsensitiveContains("step 7"))
        #expect(mermaid.contains("n5 --> n6") && mermaid.contains("n6[\"Payment successful\"]") && mermaid.contains("n6 --> n7"))
        #expect(mermaid.contains("n7([\"Payment complete\"])") && !mermaid.contains("n7 -->"))
        #expect(DiagramMaker.referencedStep("Return to step 2?") == 2 && DiagramMaker.referencedStep("Step up security") == nil)
    }
}

extension DiagramWiringTests {
    @Test func repeatsCollapseAndPlainStepsOnlyGoForward() {
        let step = { (label: String, next: String) in DiagramMaker.FlowStep(label: label, question: false, ifNo: "", next: next) }
        let mermaid = DiagramMaker.flowchart(title: "", steps: [step("Fazz enables payment", ""), step("Accept money", ""),
            step("Move money", "Accept money"), step("Move money", "Accept money"), step("Move money", ""), step("Settle money", "")]).mermaid
        #expect(mermaid.components(separatedBy: "Move money").count == 2)
        #expect(mermaid.contains("n2 --> n3") && mermaid.contains("n3 --> n4") && !mermaid.contains("n3 --> n2"))
    }
}

extension DiagramWiringTests {
    /// The happy-path-only Fazz chart: the failure points become decisions with an ending of their own.
    @Test func failureChecksBecomeDecisions() {
        let step = { (label: String) in DiagramMaker.FlowStep(label: label, question: false, ifNo: "", next: "") }
        let steps = [step("Payment initiated"), step("Account details retrieved"), step("Authentication requested"),
                     step("Authentication granted"), step("Payment processed"), step("Payment successful"), step("Payment complete")]
        let checked = DiagramMaker.applying([(3, "Authenticated?", "Authentication failed"), (4, "Enough balance", "Payment declined"),
                                             (0, "Started?", "Nothing"), (6, "Done?", "Stuck")], to: steps)
        #expect(checked.map(\.label) == ["Payment initiated", "Account details retrieved", "Authentication requested", "Authenticated?",
                                          "Enough balance?", "Payment processed", "Payment successful", "Payment complete"])
        let mermaid = DiagramMaker.flowchart(title: "", steps: checked).mermaid
        #expect(mermaid.contains("n4 -->|\"yes\"| n5") && mermaid.contains("n5 -->|\"yes\"| n6") && mermaid.contains("n6 --> n7"))
        #expect(mermaid.contains("n4 -->|\"no\"| n9") && mermaid.contains("n9([\"Authentication failed\"])"))
        #expect(mermaid.contains("n5 -->|\"no\"| n10") && mermaid.contains("n10([\"Payment declined\"])"))
    }
}

extension DiagramWiringTests {
    @Test func insertedChecksAreNotBypassed() {
        let steps: [DiagramMaker.FlowStep] = [.init(label: "Start", question: false, ifNo: "", next: ""),
                                              .init(label: "Currency conversion", question: false, ifNo: "", next: "Method selection"),
                                              .init(label: "Method selection", question: false, ifNo: "", next: ""),
                                              .init(label: "Done", question: false, ifNo: "", next: "")]
        let mermaid = DiagramMaker.flowchart(title: "", steps: DiagramMaker.applying([(2, "Rate available?", "Conversion failed")], to: steps)).mermaid
        #expect(mermaid.contains("n2 --> n3") && mermaid.contains("n3 -->|\"yes\"| n4") && !mermaid.contains("n2 --> n4"))
    }
}

extension DiagramWiringTests {
    @Test func failuresEndButOptionalChoicesRejoin() {
        let mermaid = DiagramMaker.flowchart(title: "", steps: [
            .init(label: "Start payment", question: false, ifNo: "", next: ""),
            .init(label: "Connect to Fazz?", question: true, ifNo: "Connection refused", noThen: "Send payment", next: ""),
            .init(label: "Add a note?", question: true, ifNo: "No note added", noThen: "Send payment", next: ""),
            .init(label: "Send payment", question: false, ifNo: "", next: ""),
        ]).mermaid
        #expect(mermaid.contains("n5([\"Connection refused\"])") && !mermaid.contains("n5 -->"))
        #expect(mermaid.contains("n6[\"No note added\"]") && mermaid.contains("n6 --> n4"))
        #expect(!DiagramMaker.isFailure("No note added") && DiagramMaker.isFailure("Payment not accepted"))
    }
}

extension DiagramWiringTests {
    /// The third Fazz chart: every decision's `next` was "Payment initiated", so each had two "yes" arrows.
    @Test func decisionsHaveOneYesAndNeverRestart() {
        let decision = { (label: String, no: String) in
            DiagramMaker.FlowStep(label: label, question: true, ifNo: no, noThen: "", next: "Payment initiated")
        }
        let mermaid = DiagramMaker.flowchart(title: "Fazz Payment Flowchart", steps: [
            .init(label: "Payment initiated", question: false, ifNo: "", next: ""),
            .init(label: "Account details retrieved", question: false, ifNo: "", next: ""),
            decision("Authentication requested", "Process halted"), decision("Authentication granted", "Process halted"),
            decision("Payment processed", "Payment incomplete"),
            .init(label: "Payment successful", question: false, ifNo: "", next: ""),
            .init(label: "Payment complete", question: false, ifNo: "", next: ""),
        ]).mermaid
        #expect(!mermaid.contains("-->|\"yes\"| n1"), "yes never goes back to the start")
        #expect(mermaid.contains("n3 -->|\"yes\"| n4") && mermaid.contains("n4 -->|\"yes\"| n5") && mermaid.contains("n5 -->|\"yes\"| n6"))
        for decision in ["n3", "n4", "n5"] {
            #expect(mermaid.components(separatedBy: "\(decision) -->|\"yes\"|").count == 2, "one yes from \(decision)")
        }
    }
}

extension DiagramWiringTests {
    @Test func lastDecisionGetsAYes() {
        let mermaid = DiagramMaker.flowchart(title: "", steps: [
            .init(label: "Start payment", question: false, ifNo: "", next: ""),
            .init(label: "Rails connected", question: false, ifNo: "", next: ""),
            .init(label: "Send payment?", question: true, ifNo: "Payment rejected", next: ""),
        ]).mermaid
        #expect(mermaid.contains("n3 -->|\"yes\"| n4") && mermaid.contains("n4([\"Done\"])") && mermaid.contains("n3 -->|\"no\"| n5"))
    }
}

extension DiagramWiringTests {
    /// The fourth Fazz chart: failures rejoined "Payment complete", and a "no" pointed at it.
    @Test func noNeverReachesTheSuccessEnding() {
        let mermaid = DiagramMaker.flowchart(title: "Fazz Payment Flowchart", steps: [
            .init(label: "Payment initiated", question: false, ifNo: "", next: ""),
            .init(label: "Account details retrieved", question: false, ifNo: "", next: ""),
            .init(label: "Authentication requested?", question: true, ifNo: "Process halted", noThen: "Payment complete", next: ""),
            .init(label: "Authentication granted?", question: true, ifNo: "Payment incomplete", noThen: "Payment complete", next: ""),
            .init(label: "Payment processed", question: false, ifNo: "", next: ""),
            .init(label: "Payment successful?", question: true, ifNo: "Payment complete", next: ""),
            .init(label: "Payment complete", question: false, ifNo: "", next: ""),
        ]).mermaid
        let intoEnd = mermaid.components(separatedBy: "\n").filter { $0.hasSuffix(" n7") }
        #expect(intoEnd == ["    n6 -->|\"yes\"| n7"], "only success reaches Payment complete: \(intoEnd)")
        #expect(mermaid.contains("n8([\"Process halted\"])") && mermaid.contains("n9([\"Payment incomplete\"])"))
        #expect(mermaid.contains("n6 -->|\"no\"| n10") && mermaid.contains("n10([\"Stopped\"])") && !mermaid.contains("Done"))
        #expect(DiagramMaker.isFailure("Process halted") && DiagramMaker.isFailure("Payment incomplete"))
    }
}

extension DiagramWiringTests {
    @Test func failuresAreNotOnTheMainPath() {
        let step = { (label: String) in DiagramMaker.FlowStep(label: label, question: false, ifNo: "", next: "") }
        let mermaid = DiagramMaker.flowchart(title: "", steps: [step("Enter cafe"), step("Payment"), step("Thank you"), step("Payment declined")]).mermaid
        #expect(!mermaid.contains("Payment declined") && mermaid.contains("n3([\"Thank you\"])"))
    }
}

extension DiagramWiringTests {
    /// The fifth Fazz chart: every step a decision.
    @Test func onlyRealChecksStayDecisions() {
        let ask = { (label: String) in DiagramMaker.FlowStep(label: label, question: true, ifNo: "Process halted", next: "") }
        let mermaid = DiagramMaker.flowchart(title: "", steps: [
            .init(label: "Payment initiated", question: false, ifNo: "", next: ""),
            ask("Account details retrieved?"), ask("Authentication requested?"), ask("Authentication granted?"),
            ask("Payment processed?"), ask("Payment successful?"),
        ]).mermaid
        #expect(mermaid.contains("n2[\"Account details retrieved\"]") && mermaid.contains("n3[\"Authentication requested\"]"))
        #expect(mermaid.contains("n4{\"Authentication granted?\"}") && mermaid.contains("n5[\"Payment processed\"]"))
        #expect(mermaid.contains("n6{\"Payment successful?\"}"))
        #expect(mermaid.components(separatedBy: "{").count - 1 == 2, "two decisions in six steps")
    }
}

struct ProcessResearchTests {
    @MainActor @Test func processWordsAndDocumentedSteps() {
        #expect(ProcessResearch.processWords("make a flowchart of how a Fazz payment works") == "fazz payment")
        #expect(ProcessResearch.processWords("draw how antartech.co onboards clients") == "onboards clients")
        #expect(ProcessResearch.documented("Verify identity?", in: "Customers must verify their identity with an ID card before trading."))
        #expect(!ProcessResearch.documented("Fraud screening", in: "Customers must verify their identity with an ID card."))
        #expect(ExactTerms.find("make a flowchart of how a Fazz payment works").contains { $0.lowercased() == "fazz" })
        #expect(ExactTerms.find("flowchart of ordering coffee at a cafe").isEmpty, "a general process isn't researched")
        #expect(ProcessResearch.short("Follow the steps to fill out your business profile information") == "Follow the steps to fill out your business…")
        #expect(ProcessResearch.plain("Submit documents?") == "Submit documents")
        #expect(ProcessResearch.isAction("Submit the required documents") && ProcessResearch.isAction("Log in to Fazz Business"))
        #expect(!ProcessResearch.isAction("Board Resolution") && !ProcessResearch.isAction("Whether you open the account online"))
        #expect(ProcessResearch.howToBonus(URL(string: "https://docs.fazz.com/docs/getting-started")) > ProcessResearch.howToBonus(URL(string: "https://fazz.com/newsroom/business/guide")))
        #expect(ProcessResearch.isAchievementList(["Created a website", "Engineered a platform", "Implemented content", "Built a CMS"]))
        #expect(!ProcessResearch.isAchievementList(["Log in to Fazz Business", "Click Deposit", "Documents verified and account opened"]))
    }
}
