import SwiftUI
import UniformTypeIdentifiers

/// The assistant filling the window, like a chat app: past chats on the left, the conversation in the middle.
struct AssistantFullView: View {
    @Environment(BrowserState.self) var b
    @Bindable private var s = Settings.shared
    private var history = AssistantHistory.shared
    @State private var query = ""
    /// Chats the full-text index found for the query, with the passage that matched.
    @State private var found: [UUID: String] = [:]
    @State private var listVisible = true
    @State private var confirmClear = false

    private var chat: AssistantChat { b.assistant }
    private var configured: Bool { !s.aiProvider.needsKey || AIKeys.has(s.aiProvider) }
    private static let column: CGFloat = 760

    private var shown: [AssistantHistory.Summary] {
        AssistantHistory.matching(history.chats, query: query, found: found)
    }

    private var title: String {
        history.chats.first { $0.id == chat.id }?.title ?? L("New Chat")
    }

    var body: some View {
        HStack(spacing: 0) {
            if listVisible {
                sidebar.frame(width: 260).transition(.move(edge: .leading))
                Divider().opacity(0.5)
            }
            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                if configured {
                    AssistantMessages(chat: chat, maxWidth: Self.column)
                    AssistantComposer(chat: chat)
                        .frame(maxWidth: Self.column)
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "key.horizontal").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("Add an API key to start").font(.headline)
                        SettingsLink { Text("Open Settings") }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
        .background(VisualEffect(material: .sidebar, blending: .behindWindow).ignoresSafeArea())
        .animation(.easeOut(duration: 0.18), value: listVisible)
        .onExitCommand { b.assistantExpanded = false }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            guard chat.canAttachImages else { return false }
            AssistantComposer.load(providers, into: chat)
            return true
        }
        .confirmationDialog("Delete all saved chats?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) {
                history.clear()
                chat.newChat()
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Tacet Assistant").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .padding(.top, 6)
            Button { chat.newChat() } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            TextField("Search chats", text: $query).textFieldStyle(.roundedBorder)
                .modifier(ChatTextSearch(query: query, found: $found))
            if b.isPrivate {
                Text("Chats in private windows aren't saved.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if history.chats.isEmpty {
                        Text("No saved chats yet.").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    if !history.chats.isEmpty && shown.isEmpty {
                        Text("No chats found.").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(shown) { c in AssistantHistoryRow(summary: c, chat: chat, snippet: found[c.id]) {} }
                }
            }
            if !history.chats.isEmpty {
                Button("Delete All…") { confirmClear = true }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !listVisible && !b.isFullScreen { Spacer().frame(width: 70) }
            IconButton(systemName: "sidebar.left", help: listVisible ? "Hide Chats" : "Show Chats") { listVisible.toggle() }
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer()
            IconButton(systemName: "square.and.arrow.up", help: "Export as Markdown…") { AssistantExport.save(chat) }
                .disabled(chat.messages.isEmpty || chat.busy)
            IconButton(systemName: "arrow.down.right.and.arrow.up.left", help: "Exit Full Screen Chat") { b.assistantExpanded = false }
            IconButton(systemName: "xmark", help: "Close (⇧⌘A)") {
                b.assistantExpanded = false
                b.assistantVisible = false
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(WindowDragArea())
    }
}

/// One saved chat in a list: opens it; pins, exports or deletes it from its menu.
struct AssistantHistoryRow: View {
    let summary: AssistantHistory.Summary
    var chat: AssistantChat
    /// The passage a search found in the chat, shown under its title.
    var snippet: String? = nil
    var opened: () -> Void

    var body: some View {
        let current = summary.id == chat.id
        let pinned = summary.pinned == true
        HStack(spacing: 6) {
            Button {
                chat.open(summary)
                opened()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if pinned {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("Pinned")
                        }
                        Text(summary.title.isEmpty ? L("Untitled chat") : summary.title).lineLimit(1)
                    }
                    // Only a passage with a word found in it: a chat found by its title already shows why.
                    if let snippet, snippet.contains("\u{2}") {
                        highlightedSnippet(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(summary.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            IconButton(systemName: "trash", help: "Delete Chat") { delete(current) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(current ? Color.accentColor.opacity(0.14) : .clear))
        .contextMenu {
            Button(pinned ? L("Unpin Chat") : L("Pin Chat")) { AssistantHistory.shared.setPinned(summary.id, !pinned) }
            Button("Export as Markdown…") { AssistantExport.save(summary) }
            Divider()
            Button("Delete Chat", role: .destructive) { delete(current) }
        }
    }

    private func delete(_ current: Bool) {
        AssistantHistory.shared.delete(summary.id)
        if current { chat.newChat() }
    }
}

/// Looks the query up in the text of every saved chat a moment after typing stops, so each key doesn't start a search.
struct ChatTextSearch: ViewModifier {
    let query: String
    @Binding var found: [UUID: String]

    func body(content: Content) -> some View {
        content.task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { found = [:]; return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let hits = await AssistantSearch.shared.search(q)
            guard !Task.isCancelled else { return }
            found = Dictionary(hits.map { ($0.id, $0.snippet) }, uniquingKeysWith: { a, _ in a })
        }
    }
}

/// Saves a chat as a Markdown file the user picks.
enum AssistantExport {
    /// A saved chat, read from its file.
    @MainActor static func save(_ summary: AssistantHistory.Summary) {
        // The chat may have been saved a moment ago: its file is written first.
        AssistantHistory.shared.flush()
        guard let saved = AssistantHistory.shared.load(summary) else { return }
        write(saved)
    }

    /// The chat on screen as it is now: also one not saved yet, or one in a private window, which is never saved.
    @MainActor static func save(_ chat: AssistantChat) {
        guard let first = chat.messages.first(where: { $0.role == .user }) else { return }
        let listed = AssistantHistory.shared.chats.first { $0.id == chat.id }
        let title = listed?.title ?? AssistantHistory.title(first.text.isEmpty ? (first.pageTitle ?? L("Image")) : first.text)
        let messages = chat.messages.map { m in
            AssistantHistory.SavedMessage(user: m.role == .user, text: m.text, images: [], pageTitle: m.pageTitle, quote: m.quote,
                                          activity: [], links: m.links.map { .init(url: $0.url, title: $0.title) },
                                          sources: m.sources.map { .init(url: $0.url, title: $0.title) }, error: m.error,
                                          steps: nil, research: m.research, started: m.started, finished: m.finished)
        }
        write(.init(summary: .init(id: chat.id, title: title, date: listed?.date ?? Date(), provider: listed?.provider ?? ""),
                    messages: messages, transcript: [], model: nil))
    }

    @MainActor private static func write(_ saved: AssistantHistory.Saved) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = fileName(saved.summary.title) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try AssistantHistory.markdown(saved).write(to: url, atomically: true, encoding: .utf8) } catch { Dialogs.saveFailed(error, window: NSApp.keyWindow) }
    }

    /// The title without the characters a file name can't hold.
    static func fileName(_ title: String) -> String {
        let name = title.replacingOccurrences(of: "…", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\n")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? L("Untitled chat") : String(name.prefix(80))
    }
}
