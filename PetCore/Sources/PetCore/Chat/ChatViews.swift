//
//  ChatViews.swift
//  PetCore
//
//  Chat (M18): a sidebar with the Library and the saved conversations, and the chat itself. The iPhone shows it
//  full screen, the Mac in a window.
//

import SwiftUI

public struct ChatRoot: View {
    enum Page: Hashable {
        case library
        case conversation(UUID)
    }

    let library: ChatLibrary
    let friend: FriendProfile?
    let navigator: ChatNavigator?
    let sync: ChatSync?
    let close: (() -> Void)?
    @State private var page: Page?
    /// Text to type into the next conversation shown, from a follow-up.
    @State private var draft: (id: UUID, text: String)?
    /// Bumped on each follow-up, so the same conversation reopens with the new draft.
    @State private var opened = 0

    public init(library: ChatLibrary, friend: FriendProfile?, navigator: ChatNavigator? = nil, sync: ChatSync? = nil,
                close: (() -> Void)? = nil) {
        self.library = library
        self.friend = friend
        self.navigator = navigator
        self.sync = sync
        self.close = close
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                NavigationLink(value: Page.library) {
                    Label("Library", systemImage: "books.vertical")
                        .badge(library.libraryDocuments.count)
                }
                Section("Conversations") {
                    ForEach(library.conversations) { conversation in
                        NavigationLink(value: Page.conversation(conversation.id)) { ConversationRow(conversation: conversation) }
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(conversation.id) }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(conversation.id) }
                        }
                    }
                }
            }
            .navigationTitle("Chat")
            .safeAreaInset(edge: .bottom) {
                if let sync { ChatSyncStatus(sync: sync) }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newConversation() } label: { Label("New Conversation", systemImage: "square.and.pencil") }
                        .keyboardShortcut("n", modifiers: .command)
                }
                if let close {
                    ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) }
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            #endif
            .onAppear {
                follow(navigator?.pending)
                sync?.sync()
            }
            .onChange(of: navigator?.pending) { _, start in follow(start) }
        } detail: {
            switch page {
            case .library:
                ChatFilesView(library: library, scope: .library)
            case .conversation(let id):
                if let conversation = library.conversation(id) {
                    ChatScreen(conversation: conversation, library: library, friend: friend,
                               draft: draft?.id == id ? draft?.text ?? "" : "",
                               newConversation: { newConversation() }, openLibrary: { page = .library })
                        .id("\(id)-\(opened)")
                }
            case nil:
                ContentUnavailableView {
                    Label("Ask about your files", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Add files to the Library, then start a conversation. Everything stays on this device.")
                } actions: {
                    Button("New Conversation") { newConversation() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// Opens the empty conversation if there is one, rather than piling up more.
    @discardableResult
    private func newConversation() -> UUID {
        let empty = library.conversations.first { $0.messages.isEmpty } ?? Conversation()
        library.save(empty)
        page = .conversation(empty.id)
        return empty.id
    }

    /// A follow-up from the friend: that conversation (or a new one, also when it was deleted), draft typed in.
    private func follow(_ start: ChatStart?) {
        guard let start else { return }
        navigator?.pending = nil
        let id: UUID
        if let existing = start.conversation, library.conversation(existing) != nil {
            id = existing
        } else {
            id = newConversation()
        }
        draft = (id, start.draft)
        opened += 1
        page = .conversation(id)
    }

    private func delete(_ id: UUID) {
        if page == .conversation(id) { page = nil }
        library.delete(conversation: id)
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title).lineLimit(1)
            Text(conversation.updatedAt, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One conversation: the messages, the context meter, and the composer with this conversation's files.
struct ChatScreen: View {
    let library: ChatLibrary
    @State private var thread: ChatThread
    @State private var draft = ""
    @State private var shownSource: ChatSource?
    @State private var adder: FileAdder
    /// The user message being edited, if any.
    @State private var editing: UUID?
    /// The message being linked to others (M26).
    @State private var linking: MessageRef?
    /// The document open in the side panel (a research report).
    @State private var document: UUID?
    @State private var composerHeight: CGFloat = 0
    /// Web search for the next messages (M21); stays on until turned off.
    @AppStorage("chat.web") private var web = false
    @AppStorage("chat.webExplained") private var webExplained = false
    @State private var explainingWeb = false
    /// The answer whose "Search the web" offer waits for the web explanation (M32).
    @State private var pendingWeb: UUID?

    /// /new and /library: ChatRoot moves to another page.
    var newConversation: () -> Void = {}
    var openLibrary: () -> Void = {}
    @State private var clearing = false
    /// Research mode (M28): every message runs research at this effort.
    @AppStorage("chat.research") private var researching = false
    @AppStorage("chat.researchEffort") private var effortName = ResearchEffort.medium.rawValue

    init(conversation: Conversation, library: ChatLibrary, friend: FriendProfile?, draft: String = "",
         newConversation: @escaping () -> Void = {}, openLibrary: @escaping () -> Void = {}) {
        self.library = library
        self.newConversation = newConversation
        self.openLibrary = openLibrary
        _draft = State(initialValue: draft)
        _thread = State(initialValue: ChatThread(conversation, library: library, friend: friend))
        _adder = State(initialValue: FileAdder(library: library, scope: .conversation(conversation.id)))
    }

    var body: some View {
        messages
            .safeAreaInset(edge: .top) { UnavailableBanner(text: thread.unavailable) }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(thread.conversation.title)
            .toolbar {
                ToolbarItem { ContextMeter(used: thread.contextUsed, total: thread.contextSize) }
            }
            .sheet(item: $shownSource) { PassageSheet(source: $0) }
            .sheet(item: $linking) { LinkPicker(library: library, from: $0) }
            .inspector(isPresented: Binding(get: { openDocument != nil }, set: { if !$0 { document = nil } })) {
                if let message = openDocument {
                    DocumentPanel(message: message,
                                  editDiagram: thread.state == .idle ? { thread.replaceDiagram(in: message.id, from: $0, to: $1) } : nil,
                                  close: { document = nil })
                        .inspectorColumnWidth(min: 420, ideal: 620, max: 900)
                }
            }
            // A finished report opens beside the chat, as in Claude.
            .onChange(of: thread.conversation.messages.last?.id) { _, _ in
                if let last = thread.conversation.messages.last, last.isDocument { document = last.id }
            }
            .confirmationDialog("Clear this conversation?", isPresented: $clearing) {
                Button("Clear Messages", role: .destructive) { thread.clear() }
            } message: {
                Text("Its messages go; its files stay.")
            }
            .alert("Search the web?", isPresented: $explainingWeb) {
                Button(pendingWeb == nil ? "Turn On" : "Search") {
                    webExplained = true
                    // From an offer: this question only; the toggle stays as it was.
                    if let answer = pendingWeb { thread.searchWeb(answering: answer) } else { web = true }
                    pendingWeb = nil
                }
                Button("Cancel", role: .cancel) { pendingWeb = nil }
            } message: {
                Text("""
                    Your question is sent to Parallel Search (or Firecrawl if it's busy) and Wikipedia to find pages. \
                    Links you paste are read from this device. The pages are saved in this conversation, and your friend \
                    answers here, on this device.
                    """)
            }
            .onChange(of: library.conversation(thread.conversation.id)?.modifiedAt) {
                if let latest = library.conversation(thread.conversation.id) { thread.refresh(from: latest) }
            }
            .onAppear { thread.researchEffort = effort }
            .onKeyPress(.escape) {
                guard thread.state != .idle else { return .ignored }
                stop()
                return .handled
            }
            .fileAdding(adder)
            #if os(macOS)
            // ⌘V with copied files or an image attaches them (while the message box isn't taking the paste).
            .onPasteCommand(of: FileAdder.pasteTypes) { adder.add($0) }
            #endif
    }

    private var openDocument: ChatMessage? {
        document.flatMap { id in thread.conversation.messages.first { $0.id == id } }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                MessageList(thread: thread, library: library, editing: $editing, linking: $linking, showSource: { shownSource = $0 },
                            openDocument: { document = $0 },
                            resend: { id, text in thread.resend(from: id, as: text, web: web) },
                            searchWeb: { answer in
                                if webExplained { thread.searchWeb(answering: answer) } else { pendingWeb = answer; explainingWeb = true }
                            },
                            deepResearch: { answer, level in thread.deepResearch(answering: answer, effort: level ?? effort) })
                    .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread.state) { proxy.scrollTo(MessageList.end, anchor: .bottom) }
            .onChange(of: thread.conversation.messages.count) { proxy.scrollTo(MessageList.end, anchor: .bottom) }
            // The composer grew (files attached, more lines): keep the last message above it.
            .onChange(of: composerHeight) { proxy.scrollTo(MessageList.end, anchor: .bottom) }
            .onAppear { proxy.scrollTo(MessageList.end, anchor: .bottom) }
        }
    }

    private var composer: some View {
        ChatComposer(draft: $draft, library: library, conversation: thread.conversation.id, adder: adder,
                     answering: thread.state != .idle, disabled: thread.unavailable != nil,
                     web: Binding(get: { web }, set: { on in
                         if on && !webExplained { explainingWeb = true } else { web = on }
                     }),
                     research: $researching,
                     effort: Binding(get: { effort }, set: { effortName = $0.rawValue; thread.researchEffort = $0 }),
                     send: send, stop: stop, onHeight: { composerHeight = $0 })
    }

    private func send() {
        guard thread.state == .idle else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let (command, argument) = ChatCommand.parse(text), command.action == .research {
            let split = ResearchIntent.split(argument)
            guard !split.topic.isEmpty else { return }
            thread.research(split.topic, effort: split.effort ?? effort, typed: text)
            draft = ""
            return
        }
        if let (command, _) = ChatCommand.parse(text), runLocally(command, typed: text) {
            draft = ""
            return
        }
        if researching, ChatCommand.parse(text) == nil {
            thread.research(text, effort: effort, typed: text)
            draft = ""
            return
        }
        thread.send(draft, web: web)
        draft = ""
    }

    /// Commands about the app rather than the model. False for the ones the thread runs.
    private func runLocally(_ command: ChatCommand, typed: String) -> Bool {
        switch command.action {
        case .newConversation: newConversation()
        case .openLibrary: openLibrary()
        case .addFiles: adder.importing = true
        case .clear: clearing = true
        case .help: thread.note(ChatCommand.helpText, echoing: typed)
        case .listFiles: thread.note(filesText, echoing: typed)
        default: return false
        }
        return true
    }

    private var filesText: String {
        let attached = library.attached(to: thread.conversation.id), shared = library.libraryDocuments
        guard !attached.isEmpty || !shared.isEmpty else { return "No files yet. Add some with **+** or `/add`." }
        func list(_ documents: [ChatDocument]) -> String {
            documents.map { "- \($0.name) (\($0.url?.host() ?? $0.kind.title))" }.joined(separator: "\n")
        }
        return [attached.isEmpty ? nil : "**This conversation**\n" + list(attached),
                shared.isEmpty ? nil : "**Library**\n" + list(shared)].compactMap { $0 }.joined(separator: "\n\n")
    }

    private var effort: ResearchEffort { ResearchEffort(rawValue: effortName) ?? .medium }

    /// Stopped before the friend wrote anything: the question comes back to the box.
    private func stop() {
        if let question = thread.stop() { draft = question }
    }
}

struct UnavailableBanner: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.callout).padding(10).frame(maxWidth: .infinity)
                .background(.yellow.opacity(0.2))
        }
    }
}

/// The conversation: messages (one of them maybe being edited), the summary divider, and what the friend is doing.
struct MessageList: View {
    static let end = "end"
    let thread: ChatThread
    let library: ChatLibrary
    @Binding var editing: UUID?
    @Binding var linking: MessageRef?
    let showSource: (ChatSource) -> Void
    var openDocument: (UUID) -> Void = { _ in }
    let resend: (UUID, String) -> Void
    var searchWeb: (UUID) -> Void = { _ in }
    /// Nil effort: the composer's.
    var deepResearch: (UUID, ResearchEffort?) -> Void = { _, _ in }

    var body: some View {
        let conversation = thread.conversation
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                if index == conversation.summarizedCount, index > 0 { SummaryDivider() }
                if editing == message.id {
                    MessageEditor(text: message.text, cancel: { editing = nil }) { text in
                        editing = nil
                        resend(message.id, text)
                    }
                } else {
                    MessageRow(message: message, showSource: showSource,
                               edit: message.role == .user && thread.state == .idle ? { editing = message.id } : nil,
                               library: library, conversationID: conversation.id,
                               link: message.isAside ? nil : { linking = MessageRef(conversationID: conversation.id, messageID: message.id) },
                               editDiagram: thread.state == .idle ? { thread.replaceDiagram(in: message.id, from: $0, to: $1) } : nil,
                               openDocument: message.isDocument ? { openDocument(message.id) } : nil)
                    // Only under the last answer: taking an older one would redo the chat from there.
                    if let offer = message.offer, message.id == conversation.messages.last?.id, thread.state == .idle {
                        OfferButton(offer: offer, take: { level in offer == .web ? searchWeb(message.id) : deepResearch(message.id, level) })
                    }
                }
            }
            ChatStatus(thread: thread)
            Color.clear.frame(height: 1).id(Self.end)
        }
    }
}

/// The friend's offer under its answer (M32): the web, or deep research (a tap: the composer's effort; the menu:
/// another).
struct OfferButton: View {
    let offer: ChatMessage.Offer
    let take: (ResearchEffort?) -> Void

    var body: some View {
        Group {
            switch offer {
            case .web:
                Button { take(nil) } label: { Label("Search the web for this", systemImage: "globe") }
            case .research:
                Menu {
                    ForEach(ResearchEffort.allCases) { level in
                        Button("\(level.title) · \(level.estimate)") { take(level) }
                    }
                } label: {
                    Label("Deep research this", systemImage: "binoculars")
                } primaryAction: { take(nil) }
                .fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// What the friend is doing right now, or what went wrong last.
struct ChatStatus: View {
    let thread: ChatThread

    var body: some View {
        switch thread.state {
        case .idle:
            if let failure = thread.failure {
                Label(failure, systemImage: "exclamationmark.bubble").foregroundStyle(.secondary)
            }
            if let notice = thread.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        case .checking:
            working("Thinking…", symbol: "ellipsis.bubble")
        case .browsing(let status):
            working(status, symbol: "globe")
        case .making(let status):
            working(status, symbol: "wand.and.stars")
        case .remembering(let status):
            working(status, symbol: "clock.arrow.circlepath")
        case .researching:
            if let log = thread.research { ResearchProgress(log: log) } else { working("Planning the research…", symbol: "magnifyingglass.circle") }
        case .compacting:
            working("Compacting conversation… summarising older messages to make room", symbol: "rectangle.compress.vertical")
        case .searching:
            working("Searching your files…", symbol: "magnifyingglass")
        case .answering(let text):
            MessageRow(message: ChatMessage(role: .friend, text: text.isEmpty ? "…" : text), live: true, showSource: { _ in })
        }
    }

    private func working(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.callout).foregroundStyle(.secondary).symbolEffect(.pulse)
    }
}

/// Editing a sent message in place: Send replaces it and everything after it.
struct MessageEditor: View {
    @State private var text: String
    let cancel: () -> Void
    let send: (String) -> Void
    @FocusState private var focused: Bool

    init(text: String, cancel: @escaping () -> Void, send: @escaping (String) -> Void) {
        _text = State(initialValue: text)
        self.cancel = cancel
        self.send = send
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($focused)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.tint, lineWidth: 1.5))
                .onKeyPress(.escape) {
                    cancel()
                    return .handled
                }
            Text("Sending replaces this message and everything after it.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.bordered)
                Button("Send") { send(text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear { focused = true }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    /// Still streaming: previews (diagrams, HTML) wait for the finished answer.
    var live = false
    let showSource: (ChatSource) -> Void
    /// Offered on the user's own messages while the friend is idle.
    var edit: (() -> Void)?
    /// Linking (M26): where this message lives, and the picker.
    var library: ChatLibrary?
    var conversationID: UUID?
    var link: (() -> Void)?
    /// Diagram edits (M29): old code, new code.
    var editDiagram: ((String, String) -> Void)?
    /// A document (research report): a card in the chat that opens it in the side panel.
    var openDocument: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let mine = message.role == .user
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if let log = message.research { ResearchStepsDisclosure(log: log) } // above the report, as in Claude
            if let openDocument { DocumentCard(message: message, open: openDocument) } else { bubble(mine: mine) }
            ForEach(message.files ?? []) { ChatFileCard(file: $0) }
            if !message.sources.isEmpty { sources }
            HStack(spacing: 10) {
                if let library, let conversationID {
                    LinkBadge(library: library, ref: MessageRef(conversationID: conversationID, messageID: message.id))
                }
                if !live { actions }
            }
            .frame(minHeight: 18)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(message.text) }
            if let edit { Button("Edit", systemImage: "pencil", action: edit) }
            if let link { Button("Link to…", systemImage: "link", action: link) }
        }
        .accessibilityAction(named: "Edit") { edit?() }
        .accessibilityAction(named: "Link to…") { link?() }
    }

    /// Copy · Edit · Link to…: on hover on the Mac, always under the message on the iPhone (no hover there).
    @ViewBuilder
    private var actions: some View {
        #if os(macOS)
        let shown = hovering
        #else
        let shown = true
        #endif
        HStack(spacing: 12) {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(message.text) }
                .help("Copy")
            if let edit {
                Button("Edit", systemImage: "pencil", action: edit).help("Edit and send again")
            }
            if let link {
                Button("Link to…", systemImage: "link.badge.plus", action: link).help("Link to other messages: memory recalls them together")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
    }

    private func bubble(mine: Bool) -> some View {
        Group {
            if mine {
                Text(message.text).textSelection(.enabled)
            } else {
                MarkdownView(text: message.text, live: live, editDiagram: editDiagram)
            }
        }
        .padding(10)
        .background(mine ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 14))
        .opacity(message.isAside ? 0.7 : 1)
    }

    private var sources: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(message.sources) { source in
                    Button { showSource(source) } label: {
                        Label(source.label, systemImage: source.kind.symbol).font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Shows the passage this answer used")
                }
            }
        }
    }
}

struct SummaryDivider: View {
    var body: some View {
        HStack {
            VStack { Divider() }
            Label("Earlier messages summarised", systemImage: "rectangle.compress.vertical")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
            VStack { Divider() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("The friend remembers the messages above only as a summary")
    }
}

/// How full the model's context was on the last answer: "2,310 / 4,096".
struct ContextMeter: View {
    let used: Int
    let total: Int
    @State private var explaining = false

    var body: some View {
        let share = total > 0 ? min(1, Double(used) / Double(total)) : 0
        Button { explaining = true } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 3)
                    Circle().trim(from: 0, to: share)
                        .stroke(color(share), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                Text(label).font(.caption.monospacedDigit()).fixedSize() // never "2,3…"
            }
        }
        .buttonStyle(.plain)
        .help("Context used by the last answer: instructions, passages, conversation and answer")
        .popover(isPresented: $explaining) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(used.formatted()) of \(total.formatted()) tokens").font(.headline.monospacedDigit())
                Text("How much of the on-device model's memory the last answer used: instructions, file passages, the conversation and the answer. Near full, older messages get summarised.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Context used")
        .accessibilityValue("\(used) of \(total) tokens")
    }

    /// The Mac has room for "2,310 / 4,096"; the iPhone's toolbar gets "2.3k/4.1k".
    private var label: String {
        #if os(iOS)
        Self.compact(used) + "/" + Self.compact(total)
        #else
        "\(used.formatted()) / \(total.formatted())"
        #endif
    }

    static func compact(_ value: Int) -> String {
        guard value >= 1000 else { return String(value) }
        let thousands = (Double(value) / 1000 * 10).rounded() / 10
        return (thousands == thousands.rounded() ? String(Int(thousands)) : String(thousands)) + "k"
    }

    private func color(_ share: Double) -> Color {
        share < 0.6 ? .green : share < 0.85 ? .orange : .red
    }
}

struct PassageSheet: View {
    let source: ChatSource
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(source.text).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(source.label)
            .toolbar {
                if let url = source.url {
                    ToolbarItem(placement: .primaryAction) { Link(destination: url) { Label("Open Page", systemImage: "safari") } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}
