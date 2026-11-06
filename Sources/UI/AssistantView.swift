import SwiftUI
import UniformTypeIdentifiers

/// The assistant chat, in a panel on the right of the window.
struct AssistantPanel: View {
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared
    var maxWidth: Double = .infinity
    @State private var showHistory = false
    /// The width while the edge is dragged, saved to settings only when the drag ends.
    @State private var dragWidth: Double?
    @State private var dragStart: Double?

    static let minWidth = 340.0
    private var width: Double { min(max(Self.minWidth, dragWidth ?? s.assistantWidth), max(Self.minWidth, maxWidth)) }

    private var chat: AssistantChat { b.assistant }
    private var configured: Bool { !s.aiProvider.needsKey || AIKeys.has(s.aiProvider) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if configured {
                AssistantMessages(chat: chat)
                AssistantComposer(chat: chat)
            } else {
                setup
            }
        }
        .frame(width: width)
        .background(VisualEffect(material: .sidebar, blending: .withinWindow))
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                Color.clear
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            }
                .frame(width: 7)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let base = dragStart ?? width
                            if dragStart == nil { dragStart = base }
                            dragWidth = min(max(Self.minWidth, maxWidth), max(Self.minWidth, base - v.translation.width))
                        }
                        .onEnded { _ in
                            if let dragWidth { s.assistantWidth = dragWidth }
                            dragWidth = nil
                            dragStart = nil
                        }
                )
                .help("Drag to resize")
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            guard chat.canAttachImages else { return false }
            AssistantComposer.load(providers, into: chat)
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("Tacet Assistant").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            IconButton(systemName: "clock.arrow.circlepath", help: "Chat History") { showHistory.toggle() }
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    AssistantHistoryList(chat: chat) { showHistory = false }
                }
            IconButton(systemName: "square.and.arrow.up", help: "Export as Markdown…") { AssistantExport.save(chat) }
                .disabled(chat.messages.isEmpty || chat.busy)
            IconButton(systemName: "square.and.pencil", help: "New Chat") { chat.newChat() }
                .disabled(chat.messages.isEmpty && chat.draft.isEmpty)
            IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Full Screen Chat") { b.assistantExpanded = true }
            IconButton(systemName: "xmark", help: "Close (⇧⌘A)") { b.assistantVisible = false }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(WindowDragArea())
    }

    private var setup: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.horizontal").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Add an API key to start").font(.headline)
            Text("Tacet Assistant uses your own key from Anthropic, OpenAI, OpenRouter, DeepSeek or any OpenAI-compatible server. The key stays in your Keychain.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SettingsLink { Text("Open Settings") }
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Messages

struct AssistantMessages: View {
    var chat: AssistantChat
    /// The conversation's width in the full-window chat; the panel uses all of its width.
    var maxWidth: CGFloat = .infinity
    @Environment(BrowserState.self) var b

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty { AssistantSuggestions(chat: chat) }
                    ForEach(chat.messages) { m in
                        // Only the message that changed is drawn again (and its Markdown read again) as a reply streams in.
                        let last = m.id == chat.messages.last?.id
                        AssistantBubble(message: m, thinking: chat.busy && last, retry: last && chat.canRetry ? { chat.retry() } : nil,
                                        question: m.research ? chat.question(before: m.id) : nil)
                            .equatable()
                            .id(m.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }
}

struct AssistantSuggestions: View {
    var chat: AssistantChat

    private var prompts: [String] {
        if AssistantSources.isVideo(chat.browser?.current?.url) {
            return ["Summarise this video", "What are the key moments, with timestamps?"]
        }
        return chat.pageToAttach != nil
            ? ["Summarise this page", "What are the key points?", "Explain the text I selected"]
            : ["What can you do?", "Explain the text I selected"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about the page you're reading, or anything else.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(prompts, id: \.self) { p in
                Button {
                    chat.draft = L(p)
                    chat.send()
                } label: {
                    Text(LocalizedStringKey(p)).font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}

struct AssistantBubble: View {
    let message: AssistantChat.Message
    let thinking: Bool
    /// Asks for this reply again; only the last one can be.
    var retry: (() -> Void)? = nil
    /// What was asked, for the title of an exported research report.
    var question: String? = nil
    @Environment(BrowserState.self) var b
    @State private var copied = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if let page = message.pageTitle {
                        Label(page, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ForEach(Array(message.tabTitles.enumerated()), id: \.offset) { _, title in
                        Label(title, systemImage: "at").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let quote = message.quote {
                        Text("“\(quote)”").font(.caption).italic().foregroundStyle(.secondary).lineLimit(3)
                            .multilineTextAlignment(.trailing)
                    }
                    if !message.images.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(message.images.enumerated()), id: \.offset) { _, img in
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.18)))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if AssistantActivity.shows(message.steps) {
                    AssistantActivityView(steps: message.steps, research: message.research, started: message.started,
                                          finished: message.finished, running: thinking && message.error == nil,
                                          writing: !message.text.isEmpty)
                } else if thinking && message.text.isEmpty && message.error == nil {
                    ProgressView().controlSize(.small)
                }
                if !message.text.isEmpty {
                    AssistantMarkdown(text: message.text, unverified: message.unverified)
                }
                ForEach(Array(message.links.enumerated()), id: \.offset) { _, link in
                    Button { b.newTab(url: link.url) } label: {
                        Label(link.title, systemImage: "arrow.up.right.square").lineLimit(1)
                    }
                    .help(link.url.absoluteString)
                }
                if !message.sources.isEmpty, !thinking {
                    AssistantSourceChips(sources: message.sources)
                }
                ForEach(Array(message.activity.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if !thinking, !message.text.isEmpty || retry != nil || message.usage != nil {
                    actions
                }
            }
            // Links in a reply open in a new tab here, not in another browser.
            .environment(\.openURL, OpenURLAction { url in
                b.newTab(url: url)
                return .handled
            })
            .contextMenu {
                Button("Copy") { copy() }
                if message.research, !thinking, !message.text.isEmpty {
                    Menu("Export Report") { ResearchExportMenu(message: message, question: question).items }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if !message.text.isEmpty {
                IconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copy", size: 11) { copy() }
            }
            if let retry {
                IconButton(systemName: "arrow.clockwise", help: "Ask Again", size: 11) { retry() }
            }
            if message.research, !message.text.isEmpty {
                ResearchExportMenu(message: message, question: question)
            }
            Spacer(minLength: 8)
            // Only what the provider reported; nothing is estimated, and no price, which isn't reliably known.
            if let usage = message.usage {
                Text(usage.summary())
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .help("Tokens this answer used, as your provider reported them: read by the model (in), written by it (out), and read from the provider's cache, which costs less (cached).")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    /// Inline Markdown (bold, italics, code, links), keeping the model's line breaks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

extension AssistantBubble: Equatable {
    /// What the bubble shows; images and links are only ever added, so their counts are enough.
    static func == (lhs: Self, rhs: Self) -> Bool {
        let l = lhs.message, r = rhs.message
        return lhs.thinking == rhs.thinking && (lhs.retry == nil) == (rhs.retry == nil) && l.id == r.id && l.text == r.text
            && l.activity == r.activity && l.steps == r.steps && l.finished == r.finished
            && l.error == r.error && l.links.count == r.links.count && l.sources.count == r.sources.count
            && l.images.count == r.images.count && l.pageTitle == r.pageTitle && l.quote == r.quote
            && l.unverified == r.unverified
            && l.tabTitles == r.tabTitles && l.usage == r.usage
    }
}

// MARK: - Composer

struct AssistantComposer: View {
    @Bindable var chat: AssistantChat
    @FocusState private var focused: Bool
    /// The tab highlighted in the `@` list, chosen with Return.
    @State private var mentionIndex = 0
    /// The draft as it was when Escape closed the `@` list, so it stays closed until the user types again.
    @State private var dismissedMention: String?

    /// The `@` list: what's typed after the `@`, and the open tabs that match it; nil when no tab is being picked.
    private var mention: (query: String, tabs: [Tab])? {
        guard let query = AssistantChat.mentionQuery(in: chat.draft), chat.draft != dismissedMention else { return nil }
        let tabs = chat.mentionableTabs
        guard !tabs.isEmpty || !chat.mentionedTabIDs.isEmpty else { return nil }
        guard chat.mentionedTabIDs.count < AssistantChat.maxMentionedTabs else { return (query, []) }
        let found = AssistantChat.mentionMatches(tabs.map { ($0.title, $0.url) }, query: query).map { tabs[$0] }
        return (query, Array(found.prefix(8)))
    }

    private func choose(_ tab: Tab) {
        chat.mention(tab)
        mentionIndex = 0
        focused = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let mention {
                mentionList(mention.tabs, query: mention.query)
            }
            if chat.pageToAttach != nil || !chat.images.isEmpty || chat.selection != nil || !chat.mentionedTabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let selection = chat.selection {
                            chip(title: "“" + AssistantChat.quote(selection) + "”", icon: nil, symbol: "text.quote",
                                 help: "The selected text is sent with your next message") { chat.selection = nil }
                        }
                        if let page = chat.pageToAttach {
                            chip(title: page.title, icon: page.favicon) { chat.removePageAttachment() }
                        }
                        ForEach(chat.mentionedTabs) { tab in
                            chip(title: tab.title, icon: tab.favicon, symbol: "at", help: "This tab is read and sent with your next message") {
                                chat.mentionedTabIDs.removeAll { $0 == tab.id }
                            }
                        }
                        ForEach(chat.images) { img in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: img.image).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                                Button { chat.images.removeAll { $0.id == img.id } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove")
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                if chat.canAttachImages {
                    IconButton(systemName: "photo.badge.plus", help: "Attach Image") { pickImages() }
                }
                TextField(chat.deepResearch ? L("What should Tacet research?") : L("Ask Tacet Assistant…"), text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        // With the @ list open, Return picks the highlighted tab instead of sending.
                        if let tabs = mention?.tabs, !tabs.isEmpty {
                            let tab = tabs[min(mentionIndex, tabs.count - 1)]
                            DispatchQueue.main.async { choose(tab) }
                            return .handled
                        }
                        // After the key is handled, so the field shows the emptied draft.
                        DispatchQueue.main.async { chat.send() }
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard let tabs = mention?.tabs, !tabs.isEmpty else { return .ignored }
                        mentionIndex = min(mentionIndex + 1, tabs.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard let tabs = mention?.tabs, !tabs.isEmpty else { return .ignored }
                        mentionIndex = max(mentionIndex - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard mention != nil else { return .ignored }
                        dismissedMention = chat.draft
                        return .handled
                    }
                    .onChange(of: chat.draft) { _, _ in mentionIndex = 0 }
                    .padding(.vertical, 5)
                if chat.busy {
                    IconButton(systemName: "stop.circle.fill", help: "Stop", tint: .accentColor, size: 16) { chat.stop() }
                } else {
                    IconButton(systemName: "arrow.up.circle.fill", help: "Send", tint: .accentColor, size: 16) { chat.send() }
                        .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.images.isEmpty
                                  && chat.mentionedTabs.isEmpty)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 6) {
                // Labels when there's room, icons alone in a narrow panel.
                ViewThatFits(in: .horizontal) {
                    switches(compact: false)
                    switches(compact: true)
                }
                Spacer(minLength: 4)
                ChatModelMenu(chat: chat)
            }
            Text("Answers come from your AI provider and can be wrong.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .onAppear { focused = true }
    }

    private func switches(compact: Bool) -> some View {
        HStack(spacing: 6) {
            WebAccessButton(compact: compact)
            BrowserUseButton(compact: compact)
            if Settings.shared.aiProvider != .apple { DeepResearchButton(chat: chat, compact: compact) }
        }
        .fixedSize()
    }

    /// The open tabs that match what's typed after `@`, to attach one to the next message.
    private func mentionList(_ tabs: [Tab], query: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if chat.mentionedTabIDs.count >= AssistantChat.maxMentionedTabs {
                Text(String(format: L("Up to %d tabs can go with one message."), AssistantChat.maxMentionedTabs))
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            } else if tabs.isEmpty {
                Text(String(format: L("No open tab matches “%@”."), query))
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            } else {
                Text("Attach a tab").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
                ForEach(Array(tabs.enumerated()), id: \.element.id) { n, tab in
                    Button { choose(tab) } label: {
                        HStack(spacing: 6) {
                            if let icon = tab.favicon {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "globe").font(.caption).frame(width: 14)
                            }
                            Text(tab.title.isEmpty ? (tab.url.map(InputResolver.displayHost) ?? "") : tab.title)
                                .font(.callout).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(n == min(mentionIndex, tabs.count - 1) ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.url?.absoluteString ?? "")
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func chip(title: String, icon: NSImage?, symbol: String = "doc.text",
                      help: LocalizedStringKey = "This page is sent with your next message", remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 12, height: 12) } else { Image(systemName: symbol).font(.caption) }
            Text(title).font(.caption).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Don't attach this page")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help(help)
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let img = NSImage(contentsOf: url) { chat.addImage(img) } }
    }

    static func load(_ providers: [NSItemProvider], into chat: AssistantChat) {
        for p in providers {
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage { DispatchQueue.main.async { chat.addImage(img) } }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, let img = NSImage(contentsOf: url) { DispatchQueue.main.async { chat.addImage(img) } }
                }
            }
        }
    }
}

/// Past chats, newest first, to reopen or delete.
struct AssistantHistoryList: View {
    var chat: AssistantChat
    var close: () -> Void
    @Environment(BrowserState.self) var b
    private var history = AssistantHistory.shared
    @State private var query = ""
    /// Chats the full-text index found for the query, with the passage that matched.
    @State private var found: [UUID: String] = [:]
    @State private var confirmClear = false

    init(chat: AssistantChat, close: @escaping () -> Void) {
        self.chat = chat
        self.close = close
    }

    private var shown: [AssistantHistory.Summary] {
        AssistantHistory.matching(history.chats, query: query, found: found)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chat History").font(.headline)
                Spacer()
                if !history.chats.isEmpty {
                    Button("Delete All…") { confirmClear = true }.buttonStyle(.link).font(.caption)
                }
            }
            // Shown with any saved chat, not only with many: it finds words inside the chats, and one long chat is
            // already worth searching.
            if !history.chats.isEmpty {
                TextField("Search chats", text: $query).textFieldStyle(.roundedBorder)
                    .modifier(ChatTextSearch(query: query, found: $found))
            }
            if b.isPrivate {
                Text("Chats in private windows aren't saved.").font(.caption).foregroundStyle(.secondary)
            }
            if history.chats.isEmpty {
                Text("No saved chats yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if shown.isEmpty {
                            Text("No chats found.").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                        }
                        ForEach(shown) { c in AssistantHistoryRow(summary: c, chat: chat, snippet: found[c.id], opened: close) }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(12)
        .frame(width: 320)
        .confirmationDialog("Delete all saved chats?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("This can't be undone.")
        }
    }
}

/// A small switch below the chat box, tinted when on.
struct ChatSwitch: View {
    let title: LocalizedStringKey
    let symbol: String
    let on: Bool
    var compact = false
    /// Marked as a beta with a small tag after its name.
    var beta = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(SwitchLabelStyle(compact: compact, beta: beta))
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// A switch's label: its icon and name, or only the icon when there's little room.
struct SwitchLabelStyle: LabelStyle {
    let compact: Bool
    var beta = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if !compact { configuration.title }
            if beta && !compact {
                Text("Beta").font(.system(size: 7.5, weight: .bold)).textCase(.uppercase).opacity(0.75)
            }
        }
    }
}

/// Turns the assistant's web search and fetch on and off from the chat.
struct WebAccessButton: View {
    @Bindable private var s = Settings.shared
    var compact = false

    var body: some View {
        ChatSwitch(title: "Web access", symbol: "globe", on: s.aiWeb, compact: compact) { s.aiWeb.toggle() }
            .accessibilityLabel("Web access")
            .help(s.aiWeb ? "The assistant can search the web and read pages. Click to turn off." : "Let the assistant search the web and read pages")
    }
}

/// Turns page control on and off from the chat. The first time, it explains what that means.
struct BrowserUseButton: View {
    @Bindable private var s = Settings.shared
    var compact = false
    @State private var explaining = false

    var body: some View {
        ChatSwitch(title: "Browser use", symbol: "cursorarrow.click.2", on: s.aiControl, compact: compact, beta: true) {
            if s.aiControl { s.aiControl = false } else if s.aiControlExplained { s.aiControl = true } else { explaining = true }
        }
        .help(s.aiControl ? "Browser use (beta): the assistant can click, type and scroll on the current page. Click to turn off."
                          : "Browser use (beta): let the assistant click, type and scroll on the current page")
        .alert("Turn on browser use?", isPresented: $explaining) {
            Button("Turn On") {
                s.aiControlExplained = true
                s.aiControl = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("When you ask, the assistant can use the page in the current tab for you, where you're signed in. It asks before sending, buying or deleting anything, and never fills in passwords or card numbers. A page can try to trick it, so watch what it does and press Stop if needed.")
        }
    }
}

/// Turns Deep research on and off for this chat's next messages. It needs the web, so it turns Web access on.
struct DeepResearchButton: View {
    @Bindable var chat: AssistantChat
    var compact = false
    @Bindable private var s = Settings.shared

    var body: some View {
        let on = chat.deepResearch && s.aiWeb
        let depth = String(format: L("Depth: %@. %@"), s.aiResearchDepth.title, s.aiResearchDepth.summary)
        HStack(spacing: 1) {
            ChatSwitch(title: "Deep research", symbol: "binoculars", on: on, compact: compact, beta: true) {
                if on { chat.deepResearch = false } else { turnOn() }
            }
            .accessibilityLabel("Deep research")
            .accessibilityValue(on ? s.aiResearchDepth.title : "")
            .help((on ? L("Deep research (beta) is on: the assistant searches widely, reads many pages, checks the facts and writes a report with its sources. Click to turn off.")
                      : L("Deep research (beta): many searches, pages read in full, facts checked, and a report with its sources. Takes a few minutes."))
                  + "\n" + depth)
            depthMenu
        }
    }

    /// Quick, Standard or Thorough, remembered for every chat. Choosing one turns Deep research on.
    private var depthMenu: some View {
        Menu {
            ForEach(ResearchDepth.allCases) { d in
                Toggle(isOn: Binding(get: { s.aiResearchDepth == d }, set: { _ in s.aiResearchDepth = d; turnOn() })) {
                    Text(d.title)
                    Text(d.summary)
                }
            }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Research depth")
        .accessibilityLabel("Research depth")
    }

    private func turnOn() {
        chat.deepResearch = true
        s.aiWeb = true
    }
}

/// The model for this chat, from the provider's list.
struct ChatModelMenu: View {
    var chat: AssistantChat
    private var models = AIModels.shared
    private var s = Settings.shared

    init(chat: AssistantChat) { self.chat = chat }

    var body: some View {
        let list = models.models(for: s.aiProvider)
        let current = list.first { $0.id == chat.model }?.name ?? chat.model
        Menu {
            ForEach(list) { m in
                Button { chat.model = m.id } label: {
                    if m.id == chat.model { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                }
            }
            if list.isEmpty { Text(models.loading.contains(s.aiProvider) ? "Loading models…" : "No models loaded") }
            Divider()
            Button("Refresh List") { models.refresh(s.aiProvider, force: true) }
        } label: {
            Text(current).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 130)
        .help("Model for this chat")
        .onAppear { models.refresh(s.aiProvider) }
    }
}

struct BetaBadge: View {
    var body: some View {
        Text("Beta").font(.system(size: 9.5, weight: .bold)).textCase(.uppercase)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(.tint)
    }
}

/// Opens and closes the assistant panel; shown only when the assistant is turned on.
struct AssistantButton: View {
    @Environment(BrowserState.self) var b
    private var s = Settings.shared

    var body: some View {
        if s.aiEnabled {
            IconButton(systemName: "sparkles", help: "Tacet Assistant (⇧⌘A)", tint: b.assistantVisible ? .accentColor : nil) {
                b.assistantVisible.toggle()
            }
        }
    }
}

// MARK: - Introduction

/// Shown once to people who used Tacet before the assistant existed.
struct AssistantIntro: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 62, height: 62)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("New: Tacet Assistant").font(.system(size: 22, weight: .bold))
                }
                Text("An AI assistant in a panel beside the page, for questions about what you're reading.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 10) {
                feature("doc.text.magnifyingglass", "Summaries and answers about the page you have open")
                feature("photo", "Images too, with models that can read them")
                feature("key", "Your own key: Anthropic, OpenAI, OpenRouter, DeepSeek, or a model on your Mac with Ollama")
                feature("hand.raised", "Off until you turn it on. Nothing is sent until you ask something")
            }
            .frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: 10) {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Turn On…") {
                    Settings.shared.aiEnabled = true
                    dismiss()
                    openSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            Text("You can change this anytime in Settings › AI.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(width: 500)
    }

    private func feature(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings

struct AIPane: View {
    @Bindable private var s = Settings.shared
    @State private var key = ""
    @State private var saved = false

    private var modelBinding: Binding<String> {
        Binding(get: { s.aiModelName },
                set: { var m = s.aiModels; m[s.aiProvider.rawValue] = $0; s.aiModels = m })
    }

    /// Empty means none chosen: the default model does small jobs.
    private var smallModelBinding: Binding<String> {
        Binding(get: { s.aiSmallModels[s.aiProvider.rawValue] ?? "" },
                set: { var m = s.aiSmallModels; m[s.aiProvider.rawValue] = $0; s.aiSmallModels = m })
    }

    private var visionBinding: Binding<Bool> {
        Binding(get: { s.aiProvider.supportsImages(s.aiModelName) },
                set: { var v = s.aiVision; v[s.aiProvider.visionKey(s.aiModelName)] = $0; s.aiVision = v })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $s.aiEnabled) {
                    Text("Turn on Tacet Assistant")
                }
                Text("Tacet Assistant answers questions about the page you're reading in a panel on the right (⇧⌘A). It is off unless you turn it on, and nothing is sent until you ask something.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider") {
                Picker("Provider", selection: $s.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.name).tag($0) }
                }
                if s.aiProvider == .apple {
                    AppleModelNotice()
                }
                if s.aiProvider.isLocal {
                    LocalServerSettings(provider: s.aiProvider)
                }
                if s.aiProvider == .custom {
                    LabeledContent("Server address") {
                        TextField("", text: $s.aiBaseURL, prompt: Text(AIProvider.custom.defaultBaseURL))
                            .textFieldStyle(.roundedBorder).frame(minWidth: 260)
                            .onSubmit { AIModels.shared.refresh(.custom, force: true) }
                    }
                    Text("Any server that speaks the OpenAI Chat Completions API, such as Ollama or LM Studio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if s.aiProvider != .apple && !s.aiProvider.isLocal {
                LabeledContent(s.aiProvider.needsKey ? "API key" : "API key (optional)") {
                    HStack {
                        SecureField("", text: $key, prompt: Text("Paste your key here"))
                            .textFieldStyle(.roundedBorder).frame(minWidth: 240)
                            .onSubmit(saveKey)
                        Button(saved ? "Saved" : "Save", action: saveKey).disabled(saved)
                    }
                }
                }
                if s.aiProvider != .apple {
                LabeledContent("Default model") {
                    ModelPicker(provider: s.aiProvider, selection: modelBinding)
                }
                if s.aiProvider.isLocal {
                    LocalContextNote(provider: s.aiProvider, model: s.aiModelName)
                }
                if let error = AIModels.shared.errors[s.aiProvider] {
                    Text(String(format: L("Couldn't load the models: %@"), error)).font(.caption).foregroundStyle(.orange)
                }
                Toggle("This model can read images", isOn: visionBinding)
                LabeledContent("Model for small jobs") {
                    SmallModelPicker(provider: s.aiProvider, selection: smallModelBinding)
                }
                Text("A smaller, cheaper model for jobs done behind the scenes, such as naming chats. With none, chats are named after your first question and the default model does the rest.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Length", selection: $s.aiDetailed) {
                    Text("Short and to the point").tag(false)
                    Text("Detailed").tag(true)
                }
                Toggle("Personality", isOn: $s.aiPersonality)
                if let fast = s.aiProvider.fastModel {
                    Toggle(isOn: $s.aiQuickFast) {
                        Text("Faster answers in the command bar")
                        Text(String(format: L("Uses %@, a smaller model that starts answering sooner."), fast))
                    }
                }
            } header: {
                Text("Answers")
            } footer: {
                Text("With Personality on, Tacet Assistant is calm and direct, with a dry sense of humour now and then. Off, it answers in a neutral voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            PersonalInstructionsSettings()
            MemorySettings()
            Section {
                Toggle("Web access: search the web and read pages", isOn: $s.aiWeb)
                if s.aiWeb {
                    SearchEngineSettings()
                }
            } footer: {
                Text(s.aiProvider == .anthropic
                     ? "The assistant can look things up and open pages that appear in the chat. With Anthropic, searches and pages are handled on Anthropic's servers; the search engines above are used with the other providers."
                     : "The assistant can look things up and open pages that appear in the chat. Searches try the engines above in order, skipping those not set up, and move to the next one if a search fails. DuckDuckGo needs no setup. Pages are downloaded by your Mac without cookies or logins.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $s.aiControl) {
                    HStack(spacing: 6) { Text("Browser use: let the assistant click, type and scroll on pages"); BetaBadge() }
                }
            } footer: {
                Text("When you ask, the assistant can use the page in the current tab for you, where you're signed in. It asks before sending, buying or deleting anything, and never fills in passwords or card numbers. A page can try to trick it, so watch what it does and press Stop if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("When you ask something, your message, the attached page and any images are sent to the provider you chose, under their privacy terms. With a server on your own Mac, such as Ollama, nothing leaves your computer unless the assistant searches the web. Your API key is kept in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadKey()
            AIModels.shared.refresh(s.aiProvider)
        }
        .onChange(of: s.aiProvider) { _, p in
            loadKey()
            AIModels.shared.refresh(p)
        }
        .onChange(of: key) { _, _ in saved = false }
    }

    /// Read off the main thread, so Settings doesn't freeze if macOS asks for Keychain access.
    private func loadKey() {
        let p = s.aiProvider
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) { AIKeys.get(p) }.value
            guard s.aiProvider == p else { return }
            key = found ?? ""
            saved = true
        }
    }

    private func saveKey() {
        AIKeys.set(key, for: s.aiProvider)
        saved = true
        AIModels.shared.refresh(s.aiProvider, force: true)
    }
}

/// The search engines the assistant tries, in order, with what each needs: SearXNG an address, Brave a key.
struct SearchEngineSettings: View {
    @Bindable private var s = Settings.shared
    @State private var braveKey = ""
    /// The key as it is in the Keychain, nil until it has been read; the button says "Saved" while the field matches it.
    @State private var savedKey: String?

    private var braveSaved: Bool { savedKey == braveKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let order = SearchEngineKind.ordered(s.aiSearchOrder)
        LabeledContent("Search engines") {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(order.enumerated()), id: \.element) { n, kind in
                    HStack(spacing: 6) {
                        Text(verbatim: "\(n + 1). \(kind.name)")
                        if !ready(kind) {
                            Text("Not set up").font(.caption).foregroundStyle(.secondary)
                        }
                        Button { move(n, by: -1) } label: { Label("Move Up", systemImage: "chevron.up").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).disabled(n == 0)
                            .help("Move Up")
                        Button { move(n, by: 1) } label: { Label("Move Down", systemImage: "chevron.down").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).disabled(n == order.count - 1)
                            .help("Move Down")
                    }
                }
            }
        }
        LabeledContent("SearXNG address") {
            TextField("", text: $s.aiSearXNGURL, prompt: Text(verbatim: "https://searx.example.org"))
                .textFieldStyle(.roundedBorder).frame(minWidth: 260)
        }
        LabeledContent("Brave Search API key") {
            HStack {
                SecureField("", text: $braveKey, prompt: Text("Paste your key here"))
                    .textFieldStyle(.roundedBorder).frame(minWidth: 240)
                    .onSubmit(saveBraveKey)
                Button(braveSaved ? "Saved" : "Save", action: saveBraveKey).disabled(braveSaved || savedKey == nil)
            }
        }
        .onAppear(perform: loadBraveKey)
    }

    private func ready(_ kind: SearchEngineKind) -> Bool {
        switch kind {
        case .searxng: SearXNG(address: s.aiSearXNGURL) != nil
        case .brave: !(savedKey ?? "").isEmpty
        case .duckDuckGo: true
        }
    }

    private func move(_ n: Int, by delta: Int) {
        var order = SearchEngineKind.ordered(s.aiSearchOrder)
        let to = n + delta
        guard order.indices.contains(to) else { return }
        order.swapAt(n, to)
        s.aiSearchOrder = order.map(\.rawValue)
    }

    /// Read off the main thread, so Settings doesn't freeze if macOS asks for Keychain access.
    private func loadBraveKey() {
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) { BraveKey.get() }.value ?? ""
            braveKey = found
            savedKey = found
        }
    }

    private func saveBraveKey() {
        BraveKey.set(braveKey)
        savedKey = braveKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the on-device model can and can't do, and whether this Mac can run it.
struct AppleModelNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = AppleModel.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label("Ready on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Label {
                Text("Apple's model is free, works offline and nothing leaves your Mac, but it is limited: it is much smaller than cloud models, makes more mistakes, reads only the start of long pages and videos, can't see images, and is less reliable at using pages for you. For long or hard questions, use a cloud provider.")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Chooses one of the provider's models from its own list, or takes a typed name when the list can't be loaded.
struct ModelPicker: View {
    let provider: AIProvider
    @Binding var selection: String
    private var models = AIModels.shared

    init(provider: AIProvider, selection: Binding<String>) {
        self.provider = provider
        _selection = selection
    }

    var body: some View {
        let list = models.models(for: provider)
        HStack(spacing: 6) {
            if list.isEmpty {
                if models.loading.contains(provider) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").foregroundStyle(.secondary)
                } else {
                    TextField("", text: $selection, prompt: Text("Type a model name"))
                        .textFieldStyle(.roundedBorder).frame(minWidth: 200)
                }
            } else {
                Picker("", selection: $selection) {
                    if !list.contains(where: { $0.id == selection }) { Text(selection).tag(selection) }
                    ForEach(list) { m in Text(m.name).tag(m.id) }
                }
                .labelsHidden()
                .frame(minWidth: 200)
            }
            Button { models.refresh(provider, force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("Refresh List")
                .disabled(models.loading.contains(provider))
        }
    }
}

/// The model for small jobs: the provider's models, with "Same as Default Model" first for none.
struct SmallModelPicker: View {
    let provider: AIProvider
    @Binding var selection: String
    private var models = AIModels.shared

    init(provider: AIProvider, selection: Binding<String>) {
        self.provider = provider
        _selection = selection
    }

    var body: some View {
        let list = models.models(for: provider)
        if list.isEmpty {
            TextField("", text: $selection, prompt: Text("Same as Default Model"))
                .textFieldStyle(.roundedBorder).frame(minWidth: 200)
        } else {
            Picker("", selection: $selection) {
                Text("Same as Default Model").tag("")
                if !selection.isEmpty, !list.contains(where: { $0.id == selection }) { Text(selection).tag(selection) }
                ForEach(list) { m in Text(m.name).tag(m.id) }
            }
            .labelsHidden()
            .frame(minWidth: 200)
        }
    }
}

/// Ollama and LM Studio: no key, an address that's usually right, and what to do when the server isn't on.
struct LocalServerSettings: View {
    let provider: AIProvider
    @Bindable private var s = Settings.shared
    private var models = AIModels.shared

    init(provider: AIProvider) { self.provider = provider }

    var body: some View {
        LabeledContent("Server address") {
            TextField("", text: Binding(get: { s.aiLocalURLs[provider.rawValue] ?? "" },
                                        set: { s.aiLocalURLs[provider.rawValue] = $0 }),
                      prompt: Text(provider.defaultBaseURL))
                .textFieldStyle(.roundedBorder).frame(minWidth: 260)
                .onSubmit { AIModels.shared.refresh(provider, force: true) }
        }
        HStack {
            if models.loading.contains(provider) {
                ProgressView().controlSize(.small)
                Text("Looking for models…").font(.caption).foregroundStyle(.secondary)
            } else if models.errors[provider] == nil, !models.models(for: provider).isEmpty {
                Label(String(format: L("Connected · %d models"), models.models(for: provider).count), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            Spacer()
            Button("Check Again") { AIModels.shared.refresh(provider, force: true) }.controlSize(.small)
            if let url = provider.appURL { Link(String(format: L("Get %@"), provider.name), destination: url).font(.caption) }
        }
        Text(provider == .ollama
             ? "Runs models on your Mac with Ollama: no key, and nothing leaves your Mac unless the assistant searches the web. Download a model with ollama pull, such as ollama pull gemma3 or llama3.2-vision for pictures."
             : "Runs models on your Mac with LM Studio: no key, and nothing leaves your Mac unless the assistant searches the web. Download a model in LM Studio, then start its server in the Developer tab.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
