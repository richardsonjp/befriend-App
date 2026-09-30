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
                               draft: draft?.id == id ? draft?.text ?? "" : "")
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
    @State private var composerHeight: CGFloat = 0
    /// Web search for the next messages (M21); stays on until turned off.
    @AppStorage("chat.web") private var web = false
    @AppStorage("chat.webExplained") private var webExplained = false
    @State private var explainingWeb = false

    init(conversation: Conversation, library: ChatLibrary, friend: FriendProfile?, draft: String = "") {
        self.library = library
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
            .alert("Search the web?", isPresented: $explainingWeb) {
                Button("Turn On") {
                    webExplained = true
                    web = true
                }
                Button("Cancel", role: .cancel) {}
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

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                MessageList(thread: thread, editing: $editing, showSource: { shownSource = $0 },
                            resend: { id, text in thread.resend(from: id, as: text, web: web) })
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
                     send: send, stop: stop, onHeight: { composerHeight = $0 })
    }

    private func send() {
        guard thread.state == .idle else { return }
        thread.send(draft, web: web)
        draft = ""
    }

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
    @Binding var editing: UUID?
    let showSource: (ChatSource) -> Void
    let resend: (UUID, String) -> Void

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
                               edit: message.role == .user && thread.state == .idle ? { editing = message.id } : nil)
                }
            }
            ChatStatus(thread: thread)
            Color.clear.frame(height: 1).id(Self.end)
        }
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
                Label(notice, systemImage: "globe").font(.callout).foregroundStyle(.secondary)
            }
        case .checking:
            working("Thinking…", symbol: "ellipsis.bubble")
        case .browsing(let status):
            working(status, symbol: "globe")
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
    @State private var hovering = false

    var body: some View {
        let mine = message.role == .user
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                if mine, let edit, hovering {
                    Button(action: edit) { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Edit")
                        .accessibilityLabel("Edit message")
                }
                bubble(mine: mine)
            }
            if !message.sources.isEmpty { sources }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(message.text) }
            if let edit { Button("Edit", systemImage: "pencil", action: edit) }
        }
        .accessibilityAction(named: "Edit") { edit?() }
    }

    private func bubble(mine: Bool) -> some View {
        Group {
            if mine {
                Text(message.text).textSelection(.enabled)
            } else {
                MarkdownView(text: message.text, live: live)
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

    var body: some View {
        let share = total > 0 ? min(1, Double(used) / Double(total)) : 0
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3)
                Circle().trim(from: 0, to: share)
                    .stroke(color(share), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            Text("\(used.formatted()) / \(total.formatted())").font(.caption.monospacedDigit())
        }
        .help("Context used by the last answer: instructions, passages, conversation and answer")
        .accessibilityElement()
        .accessibilityLabel("Context used")
        .accessibilityValue("\(used) of \(total) tokens")
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
