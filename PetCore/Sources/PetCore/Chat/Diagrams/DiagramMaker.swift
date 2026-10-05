//
//  DiagramMaker.swift
//  PetCore
//
//  Asks the on-device model to fill a diagram (M29): one fresh session, a typed structure per kind, and the app
//  writes the Mermaid (ChatDiagram). The kind comes from the request's words, flowchart by default.
//

import Foundation
import FoundationModels

public nonisolated enum DiagramIntent {
    /// The kind a request asks for, from its words.
    public static func kind(_ request: String) -> ChatDiagramKind {
        let text = request.lowercased()
        if text.range(of: #"\b(sequence|interaction|who calls|request flow|api calls?)\b"#, options: .regularExpression) != nil { return .sequence }
        if text.range(of: #"\b(mind ?map|brainstorm|topic map|overview map)\b"#, options: .regularExpression) != nil { return .mindmap }
        if text.range(of: #"\b(timeline|history|chronolog|milestones?)\b"#, options: .regularExpression) != nil { return .timeline }
        if text.range(of: #"\b(gantt|schedule|project plan|roadmap)\b"#, options: .regularExpression) != nil { return .gantt }
        if text.range(of: #"\b(pie|share|breakdown|split|proportion|percent)"#, options: .regularExpression) != nil { return .pie }
        return .flowchart
    }

    /// A diagram named anywhere in a request ("a PDF report with a flowchart").
    public static func mentions(_ message: String) -> Bool {
        message.range(of: #"\b(diagram|flow ?chart|mind ?map|timeline|gantt|pie chart|sequence diagram)s?\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "draw a flowchart of…", "make a mind map", "diagram the signup flow".
    public static func detect(_ message: String) -> Bool {
        message.range(of: #"\b(draw|make|create|generate|show|give me|sketch|map out|visuali[sz]e|diagram)\b[^.?!]{0,40}\b(diagram|flow ?chart|flow|mind ?map|timeline|gantt|pie chart|sequence diagram|chart)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
            || message.range(of: #"^\s*diagram\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public nonisolated enum DiagramMaker {
    public enum Failure: LocalizedError {
        case nothing
        public var errorDescription: String? { "I couldn't turn that into a diagram. Try saying what it should show." }
    }

    static let instructions = """
        You turn material into a clear diagram. Use short labels (2 to 6 words), only what the material and request \
        say, and keep names exactly as written. Prefer 4 to 12 items; never invent steps or facts.
        """

    public static func make(_ kind: ChatDiagramKind, request: String, material: String,
                            brain: Brain = .onDevice) async throws -> ChatDiagram {
        let text = DynamicGenerationSchema(type: String.self)
        func list(_ item: DynamicGenerationSchema, _ max: Int, _ description: String) -> DynamicGenerationSchema.Property {
            .init(name: "items", description: description, schema: DynamicGenerationSchema(arrayOf: item, minimumElements: 1, maximumElements: max))
        }
        let title = DynamicGenerationSchema.Property(name: "title", description: "A short title", schema: text)
        let root: DynamicGenerationSchema
        switch kind {
        case .flowchart:
            // The small model can't wire a graph by ids: it lists steps in order and names where they branch.
            let step = DynamicGenerationSchema(name: "Step", description: "One step", properties: [
                .init(name: "label", description: "What happens, 2 to 6 words (never 'go to step 3'); a decision is a short yes/no question ending with ?", schema: text),
                .init(name: "question", description: "true only if this step is a yes/no decision", schema: DynamicGenerationSchema(type: Bool.self)),
                .init(name: "ifNo", description: "For a decision: what happens when the answer is no, 2 to 5 words (like 'Payment declined'); otherwise empty", schema: text),
                .init(name: "noThen", description: "For a decision: the label of the step the no path continues to, or empty if it ends there", schema: text),
                .init(name: "next", description: "The label of the step that comes after this one if it isn't the following step; otherwise empty", schema: text),
            ])
            root = DynamicGenerationSchema(name: "Flowchart", description: "A flowchart", properties: [
                title, list(step, 14, "Every step in order along the yes path; each decision says what happens on no"),
            ])
        case .sequence:
            let message = DynamicGenerationSchema(name: "Message", description: "One message", properties: [
                .init(name: "from", description: "Who sends it", schema: text),
                .init(name: "to", description: "Who receives it", schema: text),
                .init(name: "text", description: "What is sent, 2 to 6 words", schema: text),
            ])
            root = DynamicGenerationSchema(name: "Sequence", description: "A sequence diagram", properties: [
                title, list(message, 16, "The messages, in order"),
            ])
        case .mindmap:
            let branch = DynamicGenerationSchema(name: "Branch", description: "A main idea", properties: [
                .init(name: "label", description: "The idea, 1 to 4 words", schema: text),
                .init(name: "children", description: "Details, 1 to 4 words each",
                      schema: DynamicGenerationSchema(arrayOf: text, minimumElements: 0, maximumElements: 5)),
            ])
            root = DynamicGenerationSchema(name: "MindMap", description: "A mind map", properties: [title, list(branch, 7, "The main ideas")])
        case .timeline:
            let period = DynamicGenerationSchema(name: "Period", description: "A point in time", properties: [
                .init(name: "period", description: "The date or period", schema: text),
                .init(name: "events", description: "What happened then", schema: DynamicGenerationSchema(arrayOf: text, minimumElements: 1, maximumElements: 4)),
            ])
            root = DynamicGenerationSchema(name: "Timeline", description: "A timeline", properties: [title, list(period, 12, "The periods, in order")])
        case .gantt:
            let task = DynamicGenerationSchema(name: "Task", description: "A task", properties: [
                .init(name: "section", description: "The phase it belongs to", schema: text),
                .init(name: "name", description: "The task, 2 to 5 words", schema: text),
                .init(name: "days", description: "How many days it takes", schema: DynamicGenerationSchema(type: Int.self)),
                .init(name: "alongside", description: "true if it runs at the same time as the task before it", schema: DynamicGenerationSchema(type: Bool.self)),
            ])
            root = DynamicGenerationSchema(name: "Gantt", description: "A project schedule", properties: [
                title, .init(name: "start", description: "The first task's start date, YYYY-MM-DD", schema: text),
                list(task, 20, "The tasks in order"),
            ])
        case .pie:
            let slice = DynamicGenerationSchema(name: "Slice", description: "A part", properties: [
                .init(name: "label", description: "What it is", schema: text),
                .init(name: "value", description: "Its amount", schema: DynamicGenerationSchema(type: Double.self)),
            ])
            root = DynamicGenerationSchema(name: "Pie", description: "A pie chart", properties: [title, list(slice, 10, "The parts")])
        }
        let prompt = (material.isEmpty ? "" : "Material:\n\(material)\n\n") + "Request: \(request)"
            + (kind == .gantt ? "\n\n" + ChatFileMaker.calendarNote(.now) : "")
        let content = try await brain.respond(instructions: instructions, prompt: ChatFileMaker.annotateDates(prompt, now: .now),
                                              schema: try GenerationSchema(root: root, dependencies: []))
        let name = (try? content.value(String.self, forProperty: "title")) ?? ""
        let diagram: ChatDiagram
        if kind == .flowchart {
            // The model lists the happy path; a second look finds where it can fail, as decisions.
            var steps = try flowSteps(content)
            if steps.filter({ !$0.label.isEmpty }).count < 3 { // two boxes isn't a process: one more try
                let again = try await brain.respond(instructions: instructions, prompt: ChatFileMaker.annotateDates(prompt, now: .now),
                                                    schema: try GenerationSchema(root: root, dependencies: []))
                if let more = try? flowSteps(again), more.count > steps.count { steps = more }
            }
            diagram = flowchart(title: name, steps: await withFailures(steps, request: request, brain: brain))
        } else {
            diagram = try decode(kind, title: name, content)
        }
        guard diagram.isUsable else { throw Failure.nothing }
        return diagram
    }

    private static func flowSteps(_ content: GeneratedContent) throws -> [FlowStep] {
        func string(_ item: GeneratedContent, _ key: String) -> String { ((try? item.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespaces) }
        return try content.value([GeneratedContent].self, forProperty: "items").map {
            FlowStep(label: string($0, "label"), question: (try? $0.value(Bool.self, forProperty: "question")) ?? false,
                     ifNo: string($0, "ifNo"), noThen: string($0, "noThen"), next: string($0, "next"))
        }
    }

    static let failureInstructions = """
        You review the steps of a process for where it can go wrong. Pick the steps that can fail or be refused \
        in this particular process, at most three; none if nothing in it can fail. For each, write the yes/no \
        question that decides it, in this process's own words, and what happens when the answer is no. Never pick \
        the first step.
        """

    /// The steps where things can go wrong, as decisions with their failure ending. The model can't wire branches
    /// on its own (it drew only the happy path), but it can say which steps can fail, one at a time.
    static func withFailures(_ steps: [FlowStep], request: String, brain: Brain) async -> [FlowStep] {
        let real = steps.filter { !$0.label.isEmpty && referencedStep($0.label) == nil }
        guard real.count >= 3, real.filter(\.question).count < 3 else { return steps }
        let text = DynamicGenerationSchema(type: String.self)
        let check = DynamicGenerationSchema(name: "Check", description: "A step that can fail", properties: [
            .init(name: "step", description: "The number of the step", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "question", description: "The yes/no question that decides it, ending with ?", schema: text),
            .init(name: "failure", description: "What happens when the answer is no, 2 to 5 words", schema: text),
        ])
        let root = DynamicGenerationSchema(name: "Review", description: "Where the process can fail", properties: [
            .init(name: "checks", description: "Steps that can fail, at most three",
                  schema: DynamicGenerationSchema(arrayOf: check, minimumElements: 0, maximumElements: 3)),
        ])
        let numbered = real.enumerated().map { "\($0.offset + 1). \($0.element.label)" }.joined(separator: "\n")
        guard let schema = try? GenerationSchema(root: root, dependencies: []),
              let content = try? await brain.respond(instructions: failureInstructions, prompt: "Process: \(request)\n\nSteps:\n\(numbered)", schema: schema),
              let items = try? content.value([GeneratedContent].self, forProperty: "checks") else { return steps }
        let checks = items.compactMap { item -> (Int, String, String)? in
            guard let number = try? item.value(Int.self, forProperty: "step"),
                  let question = try? item.value(String.self, forProperty: "question"),
                  let failure = try? item.value(String.self, forProperty: "failure") else { return nil }
            return (number - 1, question.trimmingCharacters(in: .whitespaces), failure.trimmingCharacters(in: .whitespaces))
        }
        return applying(checks, to: real)
    }

    /// Each check becomes a decision with its failure ending (no → "Authentication failed"). A check about the
    /// step itself replaces it ("Authentication granted" → "Authenticated?"); one guarding an action goes before
    /// it ("Enough balance?" → yes → "Payment processed"). Not the first or last step, not one that's already a
    /// decision, and only with both a question and a failure.
    static func applying(_ checks: [(step: Int, question: String, failure: String)], to steps: [FlowStep]) -> [FlowStep] {
        var replaced: [Int: FlowStep] = [:], before: [Int: FlowStep] = [:]
        for check in checks.prefix(3) {
            guard check.step > 0, check.step < steps.count - 1, !steps[check.step].question, replaced[check.step] == nil,
                  before[check.step] == nil, !check.question.isEmpty, !check.failure.isEmpty,
                  check.question.split(separator: " ").count <= 8 else { continue }
            let question = check.question.hasSuffix("?") ? check.question : check.question + "?"
            let decision = FlowStep(label: question, question: true, ifNo: check.failure, noThen: "", next: "")
            if related(question, steps[check.step].label) {
                replaced[check.step] = FlowStep(label: question, question: true, ifNo: check.failure, noThen: "", next: steps[check.step].next)
            } else {
                before[check.step] = decision
            }
        }
        return steps.enumerated().flatMap { index, step -> [FlowStep] in
            var current = replaced[index] ?? step
            // The step before a check leads into it, not past it to the step the check guards.
            if before[index + 1] != nil {
                current = FlowStep(label: current.label, question: current.question, ifNo: current.ifNo, noThen: current.noThen, next: "")
            }
            return (before[index].map { [$0] } ?? []) + [current]
        }
    }

    /// When most steps are questions, at most one decision per three steps (three at most): when the model makes every step a question
    /// ("Account details retrieved?"), the real checks (granted, verified, successful…) stay decisions and the
    /// rest go back to being steps.
    static func fewerDecisions(_ steps: [FlowStep]) -> [FlowStep] {
        let decisions = steps.indices.filter { steps[$0].question }
        // Only when most steps are questions: two real checks in a four-step flow are fine.
        guard decisions.count * 2 > steps.count else { return steps }
        let allowed = min(3, max(1, steps.count / 3))
        let check = #"(?i)\b(authori[sz]|authenticat|approv|grant|verif|valid|confirm|success|accept|enough|sufficient|available|in stock|correct|match|pass|eligible|allow|ok\b|can\b)"#
        func score(_ index: Int) -> Int {
            (steps[index].label.range(of: check, options: .regularExpression) != nil ? 2 : 0) + (steps[index].ifNo.isEmpty ? 0 : 1)
        }
        let kept = Set(decisions.sorted { score($0) == score($1) ? $0 > $1 : score($0) > score($1) }.prefix(allowed))
        return steps.enumerated().map { index, step in
            guard step.question, !kept.contains(index) else { return step }
            return FlowStep(label: step.label.trimmingCharacters(in: CharacterSet(charactersIn: "? ")), question: false, ifNo: "", next: step.next)
        }
    }

    static func isFailure(_ label: String) -> Bool {
        label.range(of: #"(?i)\b(fail(s|ed|ure)?|refus(e|ed|al)|declin(e|ed)|reject(s|ed|ion)?|den(y|ied)|invalid|error|unsupported|insufficient|mismatch|cancel(l?ed)?|blocked|expired|not\s+\w+|stop(ped)?|unable|timeout|timed out|halt(s|ed)?|incomplete|unsuccessful|abort(s|ed)?|lost|unpaid|unverified|unauthori[sz]ed|wrong|bounced|reversed)\b"#,
                    options: .regularExpression) != nil
    }

    /// The same subject in two labels: a shared word start ("Authenticated?" / "Authentication granted").
    static func related(_ a: String, _ b: String) -> Bool {
        func roots(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 5 }.map { String($0.prefix(6)) })
        }
        return !roots(a).isDisjoint(with: roots(b))
    }

    private static func decode(_ kind: ChatDiagramKind, title: String, _ content: GeneratedContent) throws -> ChatDiagram {
        func string(_ item: GeneratedContent, _ key: String) -> String { ((try? item.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespaces) }
        switch kind {
        case .flowchart:
            return flowchart(title: title, steps: try flowSteps(content))
        case .sequence:
            let sent = try content.value([GeneratedContent].self, forProperty: "items").map {
                (from: string($0, "from"), to: string($0, "to"), text: string($0, "text"))
            }.filter { !$0.from.isEmpty && !$0.to.isEmpty }
            return .sequence(title: title, participants: [], messages: Self.replies(sent))
        case .mindmap:
            let branches = try content.value([GeneratedContent].self, forProperty: "items").map {
                ChatDiagram.Branch(label: string($0, "label"), children: (try? $0.value([String].self, forProperty: "children")) ?? [])
            }.filter { !$0.label.isEmpty }
            return .mindmap(root: title.isEmpty ? "Topic" : title, branches: branches)
        case .timeline:
            let periods = try content.value([GeneratedContent].self, forProperty: "items").map {
                ChatDiagram.Period(period: string($0, "period"), events: (try? $0.value([String].self, forProperty: "events")) ?? [])
            }.filter { !$0.period.isEmpty }
            return .timeline(title: title, periods: periods)
        case .gantt:
            let tasks = try content.value([GeneratedContent].self, forProperty: "items").map {
                GanttStep(section: string($0, "section"), name: string($0, "name"),
                          days: (try? $0.value(Int.self, forProperty: "days")) ?? 1,
                          alongside: (try? $0.value(Bool.self, forProperty: "alongside")) ?? false)
            }
            return gantt(title: title, start: ChatFileMaker.rolledForward(string(content, "start"), now: .now), steps: tasks)
        case .pie:
            let slices = try content.value([GeneratedContent].self, forProperty: "items").map {
                ChatDiagram.Slice(label: string($0, "label"), value: (try? $0.value(Double.self, forProperty: "value")) ?? 0)
            }.filter { !$0.label.isEmpty }
            return .pie(title: title, slices: slices)
        }
    }
}

nonisolated extension DiagramMaker {
    struct FlowStep: Equatable {
        let label: String
        let question: Bool
        /// What happens on "no" ("Payment declined"), or a step it goes to ("step 6", a step's label).
        let ifNo: String
        /// Where the "no" outcome continues; empty: it ends there.
        var noThen = ""
        let next: String
    }
    struct GanttStep: Equatable { let section: String; let name: String; let days: Int; let alongside: Bool }

    /// Steps in order become arrows along the yes path: each to `next` (or the following step). A decision's "no"
    /// goes to the step it names, or to an outcome box of its own ("Payment declined") that ends there or rejoins
    /// `noThen`. "Step 6" / "go to step 6" mean the sixth step, never a box called "Go to step 6".
    static func flowchart(title: String, steps listed: [FlowStep]) -> ChatDiagram {
        // The same step twice ("Move money" ×12 when the model loops) is one step.
        var seen = Set<String>()
        // A failure listed on the main path ("Thank you → Payment declined") belongs to a "no", not the sequence.
        let tidied = listed.map { step in // "Transfer to Fazz ?" → "Transfer to Fazz?"
            FlowStep(label: step.label.replacingOccurrences(of: #"\s+\?"#, with: "?", options: .regularExpression),
                     question: step.question, ifNo: step.ifNo, noThen: step.noThen, next: step.next)
        }
        let given = withoutReferenceSteps(tidied.filter { !$0.label.isEmpty })
            .filter { seen.insert($0.label.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))).inserted }
            .enumerated().filter { $0.offset == 0 || $0.element.question || !isFailure($0.element.label) }.map(\.element)
        var steps = given.enumerated().map { index, step in
            // A flowchart starts with a step, not a question ("Customer orders coffee?" → "Customer orders coffee").
            if index == 0 && step.question {
                return FlowStep(label: step.label.trimmingCharacters(in: CharacterSet(charactersIn: "?")), question: false, ifNo: "", next: step.next)
            }
            // A decision is a question: "Authentication requested" → "Authentication requested?".
            return step.question && !step.label.hasSuffix("?")
                ? FlowStep(label: step.label + "?", question: true, ifNo: step.ifNo, noThen: step.noThen, next: step.next) : step
        }
        steps = fewerDecisions(steps)
        func stepNumber(_ reference: String) -> Int? {
            guard let match = reference.range(of: #"(?i)^\s*((go|goes|return|continue|jump)\s+(back\s+)?to\s+)?step\s+(\d+)\s*$"#, options: .regularExpression)
            else { return nil }
            return Int(reference[match].filter(\.isNumber)).map { $0 - 1 }
        }
        func clean(_ reference: String) -> String {
            reference.replacingOccurrences(of: #"(?i)^\s*(go|goes|return|continue|jump)\s+(back\s+)?to\s+"#, with: "", options: .regularExpression)
                .lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        func find(_ reference: String, after index: Int) -> Int? {
            if let number = stepNumber(reference) { return steps.indices.contains(number) && number != index ? number : nil }
            let wanted = clean(reference)
            guard !wanted.isEmpty else { return nil }
            // Same words in another form ("Retrieve account details" is "Account details retrieved").
            let matches = steps.indices.filter { $0 != index && sameStep(wanted, clean(steps[$0].label)) }
            return matches.first { $0 > index } ?? matches.first
        }
        // ponytail: a `next` naming no step is ignored (the steps are already in order); appending it as a new box
        // duplicated the flow whenever the model reworded a step.
        func id(_ index: Int) -> String { "s\(index + 1)" }
        var nodes = steps.enumerated().map { index, step in
            ChatDiagram.Node(id: id(index), label: step.label,
                             shape: step.question ? "decision" : index == 0 ? "start" : index == steps.count - 1 ? "end" : "step")
        }
        var edges: [ChatDiagram.Edge] = []
        for (index, step) in steps.enumerated() {
            // `next` only points forward: pointing back, it turned every "yes" into "start over". A loop back goes
            // through a "no" outcome that says where it rejoins.
            // A decision's "yes" is the step listed after it: its `next` jumped over steps and left them unreachable.
            let named = step.question ? nil : find(step.next, after: index).flatMap { $0 > index ? $0 : nil }
            var next = named ?? (index + 1 < steps.count ? index + 1 : nil)
            // A "no" never leads to the final step: that's the success ending ("Payment successful?" no →
            // "Payment complete" was the model's mistake). It gets a stop of its own instead.
            let last = steps.count - 1
            let pointsAtEnd = step.question && find(step.ifNo, after: index) == last
            let noTarget = step.question && !pointsAtEnd ? find(step.ifNo, after: index) : nil
            // The step after a decision named as its "no": that step is the no branch, so "yes" skips ahead
            // (to the last step, where the branches usually meet).
            if let noTarget, noTarget == next, noTarget == index + 1 {
                next = steps.count - 1 > noTarget ? steps.count - 1 : nil
            }
            if let next { edges.append(.init(from: id(index), to: id(next), label: step.question ? "yes" : nil)) }
            guard step.question else { continue }
            if next == nil { // a decision as the last step still needs a "yes"
                nodes.append(.init(id: "d\(index + 1)", label: "Done", shape: "end"))
                edges.append(.init(from: id(index), to: "d\(index + 1)", label: "yes"))
            }
            if let target = noTarget, target != next {
                edges.append(.init(from: id(index), to: id(target), label: "no"))
            } else {
                // The "no" outcome, a box of its own (shared by decisions that end the same way): ends there, or
                // carries on where it says.
                let label = step.ifNo.isEmpty || stepNumber(step.ifNo) != nil || pointsAtEnd ? "Stopped" : step.ifNo
                // A failure ends there ("Process halted" doesn't go on to "Payment complete"); an optional
                // choice ("No sugar") may rejoin.
                let rejoin = isFailure(label) ? nil : find(step.noThen, after: index)
                if let shared = nodes.first(where: { $0.id.hasPrefix("o") && $0.label.lowercased() == label.lowercased() }) {
                    edges.append(.init(from: id(index), to: shared.id, label: "no"))
                    continue
                }
                let outcome = "o\(index + 1)"
                nodes.append(.init(id: outcome, label: label, shape: rejoin == nil ? "end" : "step"))
                edges.append(.init(from: id(index), to: outcome, label: "no"))
                if let rejoin { edges.append(.init(from: outcome, to: id(rejoin), label: nil)) }
            }
        }
        // A step nothing leads to hangs loose: the step before it leads there.
        for index in steps.indices.dropFirst() where !edges.contains(where: { $0.to == id(index) }) {
            edges.append(.init(from: id(index - 1), to: id(index), label: steps[index - 1].question ? "yes" : nil))
        }
        // A decision never has two "yes" (or two "no") arrows: the first stays.
        var leaving = Set<String>()
        edges = edges.filter { edge in edge.label.map { leaving.insert(edge.from + "|" + $0).inserted } ?? true }
        return .flowchart(title: title, leftToRight: false, nodes: nodes, edges: edges)
    }

    /// "6" from "Go to step 6", "step 6?", "return to step 6"; nil for a real step.
    static func referencedStep(_ label: String) -> Int? {
        guard let match = label.range(of: #"(?i)^\s*((go|goes|return|continue|jump|proceed)\s+(back\s+)?to\s+)?step\s+(\d+)\s*[?.!]?\s*$"#,
                                      options: .regularExpression) else { return nil }
        return Int(label[match].filter(\.isNumber))
    }

    /// Steps that are only a reference ("Go to step 6") aren't steps: they go, and the step before them leads to
    /// the step they point at (numbered as the model listed them).
    static func withoutReferenceSteps(_ steps: [FlowStep]) -> [FlowStep] {
        var kept: [FlowStep] = []
        for (index, step) in steps.enumerated() {
            guard let number = referencedStep(step.label) else { kept.append(step); continue }
            let target = number - 1
            guard steps.indices.contains(target), target != index, referencedStep(steps[target].label) == nil,
                  let previous = kept.popLast() else { continue }
            // Only when the step before had no destination of its own.
            kept.append(previous.next.isEmpty
                ? FlowStep(label: previous.label, question: previous.question, ifNo: previous.ifNo, noThen: previous.noThen, next: steps[target].label)
                : previous)
        }
        return kept
    }

    /// Two labels for the same step: one inside the other, or most word stems shared.
    static func sameStep(_ a: String, _ b: String) -> Bool {
        if a.contains(b) || b.contains(a) { return true }
        func stems(_ text: String) -> Set<String> {
            Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { word in
                var stem = String(word)
                // "processed" / "process" / "processing" all become "proces".
                for suffixes in [["ing", "ed"], ["es", "s", "e"]] {
                    for suffix in suffixes where stem.count > suffix.count + 3 && stem.hasSuffix(suffix) {
                        stem.removeLast(suffix.count)
                        break
                    }
                }
                return stem
            }.filter { !["the", "a", "an", "to", "of", "and", "is"].contains($0) })
        }
        let x = stems(a), y = stems(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.6
    }

    /// A message back along an earlier, still-open message (B → A after A → B) is drawn as a reply.
    static func replies(_ sent: [(from: String, to: String, text: String)]) -> [ChatDiagram.Message] {
        var open: [(String, String)] = []
        return sent.map { message in
            if let index = open.lastIndex(where: { $0 == (message.to.lowercased(), message.from.lowercased()) }) {
                open.remove(at: index)
                return .init(from: message.from, to: message.to, text: message.text, reply: true)
            }
            open.append((message.from.lowercased(), message.to.lowercased()))
            return .init(from: message.from, to: message.to, text: message.text, reply: false)
        }
    }

    /// Tasks one after another (or alongside the one before), from `start` (tomorrow if it isn't a date).
    static func gantt(title: String, start: String, steps: [GanttStep], now: Date = .now) -> ChatDiagram {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let format = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)
        var cursor = (try? format.parse(start)) ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        var previousStart = cursor
        var tasks: [ChatDiagram.Task] = []
        for step in steps where !step.name.isEmpty {
            let days = max(1, step.days)
            let begin = step.alongside && !tasks.isEmpty ? previousStart : cursor
            tasks.append(.init(section: step.section, name: step.name, start: begin.formatted(format), days: days))
            previousStart = begin
            cursor = max(cursor, calendar.date(byAdding: .day, value: days, to: begin)!)
        }
        return .gantt(title: title, tasks: tasks)
    }
}

nonisolated extension ChatDiagram {
    /// Enough to draw: at least two items (a single box isn't a diagram).
    var isUsable: Bool {
        switch self {
        case .flowchart(_, _, let nodes, let edges): nodes.count >= 2 && !edges.isEmpty
        case .sequence(_, _, let messages): !messages.isEmpty
        case .mindmap(_, let branches): branches.count >= 2
        case .timeline(_, let periods): periods.count >= 2
        case .gantt(_, let tasks): !tasks.isEmpty
        case .pie(_, let slices): slices.filter { $0.value > 0 }.count >= 2
        }
    }
}
