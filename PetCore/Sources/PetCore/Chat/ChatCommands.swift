//
//  ChatCommands.swift
//  PetCore
//
//  Chat's / commands (M25): files (/csv, /pdf …), helpers (/summarize, /web …), file shortcuts (/files, /add …), and
//  built-in skills (/standup, /flashcards …). A skill is a recipe for a fresh session: neutral instructions, and
//  optionally a file it produces. Typing "/" lists them all.
//

import Foundation

public nonisolated struct ChatSkill: Equatable, Sendable {
    public let instructions: String
    /// The skill's result is a file of this kind; nil means an answer in the chat.
    public let file: ChatFileFormat?
    /// Tables with set columns (flashcards: Question, Answer); nil lets the model choose.
    public var columns: [String]? = nil
}

public nonisolated struct ChatCommand: Equatable, Identifiable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case files = "Files"
        case chat = "Chat"
        case library = "Your files"
        case work = "Work"
        case study = "Study"
        case planning = "Planning"
        case writing = "Writing"
        case help = "Help"
    }

    public enum Action: Equatable, Sendable {
        /// Make a file of this kind.
        case file(ChatFileFormat)
        /// Ask the friend, the command rewritten into a request ("%@" is what was typed after it).
        case ask(String)
        /// Search the web for what was typed.
        case web
        /// Deep research (M28).
        case research
        /// A diagram (M29), drawn in Mermaid.
        case diagram
        case skill(ChatSkill)
        /// Handled by the screen, not the model.
        case newConversation, clear, listFiles, addFiles, openLibrary, help
    }

    public let name: String
    public let group: Group
    public let summary: String
    /// Shown after the name in the menu, e.g. "<language> <text>".
    public let hint: String
    public let action: Action

    public var id: String { name }

    public static let all: [ChatCommand] = files + helpers + shortcuts + skills + [
        ChatCommand(name: "help", group: .help, summary: "Every command and skill", hint: "", action: .help),
    ]

    static let files: [ChatCommand] = [
        ChatCommand(name: "md", group: .files, summary: "A Markdown document", hint: "<what it's about>", action: .file(.md)),
        ChatCommand(name: "txt", group: .files, summary: "A plain text file", hint: "<what it's about>", action: .file(.txt)),
        ChatCommand(name: "csv", group: .files, summary: "A spreadsheet table (CSV)", hint: "<what to list>", action: .file(.csv)),
        ChatCommand(name: "json", group: .files, summary: "Structured data (JSON)", hint: "<what to list>", action: .file(.json)),
        ChatCommand(name: "ics", group: .files, summary: "Calendar events to add to Calendar", hint: "<which events>", action: .file(.ics)),
        ChatCommand(name: "pdf", group: .files, summary: "A PDF document", hint: "<what it's about>", action: .file(.pdf)),
        ChatCommand(name: "html", group: .files, summary: "A web page (HTML) with its diagrams", hint: "<what it's about>", action: .file(.html)),
    ]

    static let helpers: [ChatCommand] = [
        ChatCommand(name: "summarize", group: .chat, summary: "Sum up this conversation, or what you paste", hint: "[text]",
                    action: .ask("Summarise %@ in a few short bullet points.")),
        ChatCommand(name: "translate", group: .chat, summary: "Translate text", hint: "<language> <text>",
                    action: .ask("Translate this, keeping its meaning and tone. The first word is the language to translate into: %@")),
        ChatCommand(name: "explain", group: .chat, summary: "Explain something clearly", hint: "<topic>",
                    action: .ask("Explain clearly, with a short example: %@")),
        ChatCommand(name: "web", group: .chat, summary: "Search the web for this message", hint: "<question>", action: .web),
        ChatCommand(name: "research", group: .chat, summary: "Deep research: plan, read many sources, cited report",
                    hint: "[low|medium|high|extra high] <topic>", action: .research),
        ChatCommand(name: "diagram", group: .chat, summary: "A flowchart, sequence, mind map, timeline, gantt or pie chart",
                    hint: "[kind] <what it shows>", action: .diagram),
        ChatCommand(name: "new", group: .chat, summary: "Start a new conversation", hint: "", action: .newConversation),
        ChatCommand(name: "clear", group: .chat, summary: "Clear this conversation's messages", hint: "", action: .clear),
    ]

    static let shortcuts: [ChatCommand] = [
        ChatCommand(name: "files", group: .library, summary: "What this conversation can search", hint: "", action: .listFiles),
        ChatCommand(name: "add", group: .library, summary: "Add files to this conversation", hint: "", action: .addFiles),
        ChatCommand(name: "library", group: .library, summary: "Open the Library", hint: "", action: .openLibrary),
    ]

    static func skill(_ name: String, _ group: Group, _ summary: String, _ hint: String, file: ChatFileFormat? = nil,
                      columns: [String]? = nil, _ instructions: String) -> ChatCommand {
        ChatCommand(name: name, group: group, summary: summary, hint: hint,
                    action: .skill(ChatSkill(instructions: instructions, file: file, columns: columns)))
    }

    /// How the friend names a skill's result: "your standup", "your meeting notes".
    public var resultName: String { "your " + name.replacingOccurrences(of: "-", with: " ") }

    static let skills: [ChatCommand] = [
        // Work
        skill("standup", .work, "Yesterday, today, blockers", "[notes]", """
            Write a daily standup in Markdown with three short sections: **Yesterday**, **Today**, **Blockers** \
            (write "None" when there are none). Bullet points, plain and brief.
            """),
        skill("meeting-notes", .work, "Summary, decisions and action items", "[notes]", file: .md, """
            Write meeting notes: a # title, a two-sentence summary, a "Decisions" list, and an "Action items" table \
            with Owner, Task and Due columns (write "—" when unknown).
            """),
        skill("email-reply", .work, "Draft a reply", "<the email, or what to say>", """
            Draft a clear, polite email reply: a greeting, the reply in short paragraphs, and a sign-off. Match the \
            original's formality. No subject line unless asked.
            """),
        skill("todo", .work, "Turn text into a checklist", "<text>", """
            Turn the material into a Markdown checklist ("- [ ] …"), one concrete action a line, most important first.
            """),
        // Study
        skill("flashcards", .study, "Question and answer cards (CSV for Anki/Quizlet)", "<topic or notes>", file: .csv,
              columns: ["Question", "Answer"], """
            Make study flashcards: each row is a question someone could be asked about the material, and its short \
            answer. One fact a card, 8 to 20 cards.
            """),
        skill("quiz", .study, "5 questions to test yourself", "<topic>", """
            Write a 5-question quiz in Markdown: numbered questions, each with options A–D, then an "Answers" section \
            with the right letter and one line of why.
            """),
        skill("eli5", .study, "Explain it simply", "<topic>", """
            Explain it like to a curious 10-year-old: short sentences, one everyday comparison, no jargon.
            """),
        skill("outline", .study, "A structured outline", "<topic or file>", """
            Write a Markdown outline: a # title, ## main sections, and nested bullet points under each. No prose.
            """),
        // Planning
        skill("plan", .planning, "Break a goal into scheduled steps (calendar)", "<goal and deadline>", file: .ics, """
            Break the goal into 3 to 10 concrete steps and schedule each as an event, spread sensibly from today \
            to the deadline, at reasonable working hours.
            """),
        skill("schedule", .planning, "Turn text with dates into calendar events", "<text with dates>", file: .ics, """
            Make one event for every dated or timed thing in the material, and nothing else.
            """),
        skill("compare", .planning, "Pros and cons side by side", "<options>", """
            Compare the options in a Markdown table (one column per option, rows for the key factors), then a short \
            "Pros" and "Cons" list for each, then one line with a recommendation and why.
            """),
        // Writing
        skill("rewrite", .writing, "Say it more clearly", "<text>", """
            Rewrite the text to be clearer and easier to read, keeping its meaning and language. Only the rewritten text.
            """),
        skill("shorten", .writing, "Make it shorter", "<text>", """
            Rewrite the text at about half its length, keeping every key point. Only the shortened text.
            """),
        skill("tone", .writing, "Change the tone", "<casual|formal|friendly> <text>", """
            Rewrite the text in the tone named by its first word (casual, formal or friendly), keeping its meaning. \
            Only the rewritten text.
            """),
        skill("proofread", .writing, "Fix spelling and grammar", "<text>", """
            Correct the spelling, grammar and punctuation. Give the corrected text, then a short "Changes" list.
            """),
    ]

    /// "/csv the budget" → (csv, "the budget"). Nil when the text isn't a known command.
    public static func parse(_ text: String) -> (command: ChatCommand, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }.lowercased()
        guard let command = all.first(where: { $0.name == name }) else { return nil }
        return (command, body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// While typing a command name: the matching commands, in menu order. Nil once past the name (or not a command).
    public static func suggestions(for draft: String) -> [ChatCommand]? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        let typed = draft.dropFirst().lowercased()
        let matches = all.filter { $0.name.hasPrefix(typed) }
        return matches.isEmpty ? nil : matches
    }

    /// For /help: every command a line, by group.
    public static var helpText: String {
        Group.allCases.map { group in
            "**\(group.rawValue)**\n" + all.filter { $0.group == group }
                .map { "- `/\($0.name)\($0.hint.isEmpty ? "" : " " + $0.hint)`: \($0.summary)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// Natural requests for a file ("make a CSV of the budget", "export this as a PDF"): an instant word check, so
/// ordinary chat never pays for it. The model then fills the file.
public nonisolated enum FileIntent {
    static let formats: [(pattern: String, format: ChatFileFormat)] = [
        ("csv|spreadsheet|excel( file| sheet)?", .csv),
        ("json", .json),
        ("\\.?ics|calendar (event|invite|file)s?|events? (for|in) (my )?calendar", .ics),
        ("pdf", .pdf),
        ("html( page| file)?", .html),
        ("markdown|\\.?md( file)?", .md),
        ("\\.?txt|text file|plain text", .txt),
    ]
    static let verbs = "make|create|export|generate|give me|turn|convert|save|write|put|produce|buat|bikin|ekspor|simpan"

    /// The file kind must be what's being made ("make a CSV", "export this as a PDF", "turn it into JSON"), not
    /// just mentioned ("read this PDF and write a summary" stays a question).
    public static func detect(_ message: String) -> ChatFileFormat? {
        let text = message.lowercased()
        if text.range(of: #"\badd (it |this |them |these )?to (my )?calendar\b"#, options: .regularExpression) != nil { return .ics }
        for entry in formats {
            let pattern = #"\b("# + verbs + #")\b[^.?!\n]{0,40}?\b(as|into|to|in|a|an|me)\s+(an?\s+)?("# + entry.pattern + #")\b"#
            // …or right after the verb: "create calendar events", "write a PDF".
            let direct = #"\b("# + verbs + #")\s+(an?\s+|some\s+|the\s+)?("# + entry.pattern + #")\b"#
            if text.range(of: pattern, options: .regularExpression) != nil || text.range(of: direct, options: .regularExpression) != nil {
                return entry.format
            }
        }
        return nil
    }
}

public nonisolated enum ResearchIntent {
    /// "research …", "investigate …", "deep dive into …", "look into …": worth offering deep research for.
    public static func detect(_ message: String) -> Bool {
        message.range(of: #"^\s*(please\s+|can you\s+|could you\s+|i'?m telling you to\s+)?(do\s+)?(a\s+)?(deep\s+)?(research|investigate|deep[- ]dive|look into|analy[sz]e)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "/research high antartech.co" → (.high, "antartech.co"); also "extra high …". No effort word → nil.
    public static func split(_ argument: String) -> (effort: ResearchEffort?, topic: String) {
        let words = argument.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if words.count >= 2, words[0].lowercased() == "extra", words[1].lowercased() == "high" {
            return (.extraHigh, words.dropFirst(2).joined(separator: " "))
        }
        guard let first = words.first, let effort = ResearchEffort(word: first) else { return (nil, argument) }
        return (effort, words.dropFirst().joined(separator: " "))
    }
}
