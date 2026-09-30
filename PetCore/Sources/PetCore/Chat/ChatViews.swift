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
    let close: (() -> Void)?
    @State private var page: Page?
    /// Text to type into the next conversation shown, from a follow-up.
    @State private var draft: (id: UUID, text: String)?
    /// Bumped on each follow-up, so the same conversation reopens with the new draft.
    @State private var opened = 0

    public init(library: ChatLibrary, friend: FriendProfile?, navigator: ChatNavigator? = nil, close: (() -> Void)? = nil) {
        self.library = library
        self.friend = friend
        self.navigator = navigator
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
            .onAppear { follow(navigator?.pending) }
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
        let conversation = thread.conversation
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                        if index == conversation.summarizedCount, index > 0 { SummaryDivider() }
                        MessageRow(message: message, showSource: { shownSource = $0 })
                    }
                    status
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread.state) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: conversation.messages.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .top) {
            if let unavailable = thread.unavailable {
                Label(unavailable, systemImage: "exclamationmark.triangle")
                    .font(.callout).padding(10).frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.2))
            }
        }
        .safeAreaInset(edge: .bottom) {
            ChatComposer(draft: $draft, library: library, conversation: conversation.id, adder: adder,
                         answering: thread.state != .idle, disabled: thread.unavailable != nil,
                         web: Binding(get: { web }, set: { on in
                             if on && !webExplained { explainingWeb = true } else { web = on }
                         }),
                         send: send, stop: thread.stop)
        }
        .navigationTitle(conversation.title)
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
        .fileAdding(adder)
        #if os(macOS)
        // ⌘V with copied files or an image attaches them (while the message box isn't taking the paste).
        .onPasteCommand(of: FileAdder.pasteTypes) { adder.add($0) }
        #endif
    }

    @ViewBuilder
    private var status: some View {
        switch thread.state {
        case .idle:
            if let failure = thread.failure {
                Label(failure, systemImage: "exclamationmark.bubble").foregroundStyle(.secondary)
            }
            if let notice = thread.notice {
                Label(notice, systemImage: "globe").font(.callout).foregroundStyle(.secondary)
            }
        case .browsing(let status):
            Label(status, systemImage: "globe").font(.callout).foregroundStyle(.secondary)
                .symbolEffect(.pulse)
        case .compacting:
            Label("Compacting conversation… summarising older messages to make room", systemImage: "rectangle.compress.vertical")
                .font(.callout).foregroundStyle(.secondary)
                .symbolEffect(.pulse)
        case .searching:
            Label("Searching your files…", systemImage: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
        case .answering(let text):
            MessageRow(message: ChatMessage(role: .friend, text: text.isEmpty ? "…" : text), live: true, showSource: { _ in })
        }
    }

    private func send() {
        guard thread.state == .idle else { return }
        thread.send(draft, web: web)
        draft = ""
    }
}

struct MessageRow: View {
    let message: ChatMessage
    /// Still streaming: previews (diagrams, HTML) wait for the finished answer.
    var live = false
    let showSource: (ChatSource) -> Void

    var body: some View {
        let mine = message.role == .user
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
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
            if !message.sources.isEmpty {
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
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
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
