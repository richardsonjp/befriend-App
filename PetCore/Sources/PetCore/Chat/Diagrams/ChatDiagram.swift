//
//  ChatDiagram.swift
//  PetCore
//
//  Diagrams (M29). The small model gets Mermaid syntax wrong, so it fills a typed structure (nodes and edges,
//  tasks, slices…) and the app writes the Mermaid: always valid, with labels quoted and escaped.
//

import Foundation

public nonisolated enum ChatDiagramKind: String, Codable, CaseIterable, Sendable {
    case flowchart, sequence, mindmap, timeline, gantt, pie

    public var title: String {
        switch self {
        case .flowchart: "Flowchart"
        case .sequence: "Sequence diagram"
        case .mindmap: "Mind map"
        case .timeline: "Timeline"
        case .gantt: "Gantt chart"
        case .pie: "Pie chart"
        }
    }
}

public nonisolated enum ChatDiagram: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public let id: String
        public let label: String
        /// "step" (box), "decision" (diamond), "start" / "end" (rounded).
        public let shape: String
    }

    public struct Edge: Equatable, Sendable {
        public let from: String
        public let to: String
        public let label: String?
    }

    public struct Message: Equatable, Sendable {
        public let from: String
        public let to: String
        public let text: String
        /// A reply (dashed arrow) rather than a request.
        public let reply: Bool
    }

    public struct Branch: Equatable, Sendable {
        public let label: String
        public let children: [String]
    }

    public struct Period: Equatable, Sendable {
        public let period: String
        public let events: [String]
    }

    public struct Task: Equatable, Sendable {
        public let section: String
        public let name: String
        /// YYYY-MM-DD.
        public let start: String
        public let days: Int
    }

    public struct Slice: Equatable, Sendable {
        public let label: String
        public let value: Double
    }

    case flowchart(title: String, leftToRight: Bool, nodes: [Node], edges: [Edge])
    case sequence(title: String, participants: [String], messages: [Message])
    case mindmap(root: String, branches: [Branch])
    case timeline(title: String, periods: [Period])
    case gantt(title: String, tasks: [Task])
    case pie(title: String, slices: [Slice])

    public var kind: ChatDiagramKind {
        switch self {
        case .flowchart: .flowchart
        case .sequence: .sequence
        case .mindmap: .mindmap
        case .timeline: .timeline
        case .gantt: .gantt
        case .pie: .pie
        }
    }

    // MARK: Mermaid

    /// Valid Mermaid for this diagram.
    public var mermaid: String {
        switch self {
        case .flowchart(let title, let leftToRight, let nodes, let edges):
            var ids: [String: String] = [:]
            for (index, node) in nodes.enumerated() { ids[node.id] = "n\(index + 1)" }
            var lines = Self.frontMatter(title) + ["flowchart \(leftToRight ? "LR" : "TD")"]
            for node in nodes {
                let label = Self.quoted(node.label)
                let id = ids[node.id]!
                switch node.shape.lowercased() {
                case "decision": lines.append("    \(id){\(label)}")
                case "start", "end": lines.append("    \(id)([\(label)])")
                default: lines.append("    \(id)[\(label)]")
                }
            }
            for edge in edges {
                // An edge to a node that wasn't declared gets a box of its own.
                for end in [edge.from, edge.to] where ids[end] == nil {
                    ids[end] = "n\(ids.count + 1)"
                    lines.append("    \(ids[end]!)[\(Self.quoted(end))]")
                }
                let label = edge.label.flatMap { $0.isEmpty ? nil : "|\(Self.quoted($0))|" } ?? ""
                lines.append("    \(ids[edge.from]!) -->\(label) \(ids[edge.to]!)")
            }
            return lines.joined(separator: "\n")
        case .sequence(let title, let participants, let messages):
            var names = participants
            for message in messages { for name in [message.from, message.to] where !names.contains(name) { names.append(name) } }
            var ids: [String: String] = [:]
            var lines = Self.frontMatter(title) + ["sequenceDiagram"]
            for (index, name) in names.enumerated() {
                ids[name] = "p\(index + 1)"
                lines.append("    participant p\(index + 1) as \(Self.plain(name))")
            }
            for message in messages {
                lines.append("    \(ids[message.from]!)\(message.reply ? "-->>" : "->>")\(ids[message.to]!): \(Self.plain(message.text))")
            }
            return lines.joined(separator: "\n")
        case .mindmap(let root, let branches):
            var lines = ["mindmap", "  root((\(Self.plain(root, strict: true))))"]
            for branch in branches {
                lines.append("    " + Self.plain(branch.label, strict: true))
                for child in branch.children { lines.append("      " + Self.plain(child, strict: true)) }
            }
            return lines.joined(separator: "\n")
        case .timeline(let title, let periods):
            var lines = ["timeline", "    title \(Self.plain(title, strict: true))"]
            for period in periods {
                let events = period.events.map { Self.plain($0, strict: true) }.joined(separator: " : ")
                lines.append("    \(Self.plain(period.period, strict: true))" + (events.isEmpty ? "" : " : " + events))
            }
            return lines.joined(separator: "\n")
        case .gantt(let title, let tasks):
            var lines = ["gantt", "    title \(Self.plain(title, strict: true))", "    dateFormat YYYY-MM-DD"]
            var section: String?
            for (index, task) in tasks.enumerated() {
                if task.section != section {
                    section = task.section
                    lines.append("    section \(Self.plain(task.section.isEmpty ? "Tasks" : task.section, strict: true))")
                }
                lines.append("    \(Self.plain(task.name, strict: true)) :t\(index + 1), \(task.start), \(max(1, task.days))d")
            }
            return lines.joined(separator: "\n")
        case .pie(let title, let slices):
            var lines = ["pie", "    title \(Self.plain(title, strict: true))"]
            for slice in slices where slice.value > 0 {
                let value = slice.value == slice.value.rounded() ? String(Int(slice.value)) : String(slice.value)
                lines.append("    \(Self.quoted(slice.label)) : \(value)")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func frontMatter(_ title: String) -> [String] {
        title.isEmpty ? [] : ["---", "title: \(plain(title, strict: true))", "---"]
    }

    /// A label inside quotes: quotes become Mermaid's #quot; and line breaks spaces.
    static func quoted(_ text: String) -> String {
        "\"" + flat(text).replacingOccurrences(of: "\"", with: "#quot;") + "\""
    }

    /// A label without quotes (sequence text, mind maps, timelines, tasks): characters Mermaid reads as syntax go.
    static func plain(_ text: String, strict: Bool = false) -> String {
        var clean = flat(text).replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "#", with: "")
        if strict {
            clean = clean.components(separatedBy: CharacterSet(charactersIn: "()[]{}:\"`")).joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return clean.isEmpty ? "–" : String(clean.prefix(80))
    }

    private static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The Markdown block for chats and .md files.
    public var markdown: String { "```mermaid\n\(mermaid)\n```" }
}
