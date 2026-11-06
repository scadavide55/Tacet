import SwiftUI
import UniformTypeIdentifiers

@Observable
final class LibraryRouter {
    static let shared = LibraryRouter()
    var section = LibraryView.Section.history
}

struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case history, bookmarks, readingList, highlights, downloads
        var id: String { rawValue }
        var label: String { self == .readingList ? L("Reading List") : L(rawValue.capitalized) }
        var symbol: String {
            ["history": "clock", "bookmarks": "book", "readingList": "eyeglasses", "highlights": "highlighter", "downloads": "arrow.down.circle"][rawValue]!
        }
    }

    static var requestedSection: Section {
        get { LibraryRouter.shared.section }
        set { LibraryRouter.shared.section = newValue }
    }

    private var router = LibraryRouter.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { router.section }, set: { if let v = $0 { router.section = v } })) { s in
                Label(s.label, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch router.section {
            case .history: HistoryList(open: open)
            case .bookmarks: BookmarkList(open: open)
            case .readingList: ReadingListView(openOnline: open)
            case .highlights: HighlightsList(open: open)
            case .downloads: DownloadsList(searchable: true).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .tint(Settings.shared.accent)
    }

    private func open(_ urls: [URL]) {
        if !WindowRegistry.shared.open(urls) { openWindow(id: "main") }
    }
}

// MARK: - History

struct HistoryList: View {
    let open: ([URL]) -> Void
    private var history = History.shared
    @State private var query = ""
    @State private var selection = Set<UUID>()
    /// Search results, found off the main thread; nil while the search field is empty.
    @State private var results: [HistoryEntry]?
    /// Pages whose text matches, when Tacet keeps what pages said.
    @State private var pageHits: [PageText.Hit] = []

    private var groups: [(Date, [HistoryEntry])] {
        let list = query.isEmpty ? history.entries : (results ?? [])
        let cal = Calendar.current
        let grouped = Dictionary(grouping: list) { cal.startOfDay(for: $0.date) }
        return grouped.sorted { $0.key > $1.key }.map { ($0.key, $0.value.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        let groups = groups
        List(selection: $selection) {
            if !query.isEmpty && !pageHits.isEmpty { PageTextResults(hits: pageHits, open: open) }
            ForEach(groups, id: \.0) { day, entries in
                SwiftUI.Section(day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(entries) { e in
                        HStack(spacing: 10) {
                            Group {
                                if let icon = Favicons.shared.cached(e.url.host) {
                                    Image(nsImage: icon).resizable()
                                } else {
                                    Image(systemName: "globe").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title.isEmpty ? e.url.absoluteString : e.title).lineLimit(1)
                                Text(e.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(e.id)
                    }
                }
            }
            if query.isEmpty && history.hasOlder {
                Button("Show Older History") { history.loadOlder() }
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .overlay {
            if groups.isEmpty && pageHits.isEmpty && (query.isEmpty || results != nil) {
                ContentUnavailableView(query.isEmpty ? LocalizedStringKey("No History") : "No Results", systemImage: "clock")
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Open") { open(urls(ids)) }
            Button("Copy Link") { copy(urls(ids)) }
            Divider()
            Button("Delete") { history.remove(ids) }
        } primaryAction: { ids in
            open(urls(ids))
        }
        .onDeleteCommand { history.remove(selection) }
        .searchable(text: $query, placement: .toolbar, prompt: "Search history and what pages said")
        .task(id: "\(query)\u{1}\(history.entries.count)") {
            guard !query.isEmpty else { results = nil; pageHits = []; return }
            // Waits for a pause in typing; a newer keystroke cancels this one.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await history.filterInBackground(query)
            let read = Settings.shared.rememberPageText ? await PageText.shared.search(query, limit: 20) : []
            if !Task.isCancelled {
                results = found
                pageHits = read
            }
        }
        .toolbar {
            Menu("Clear History") {
                Button("Last Hour") { history.clear(since: Date().addingTimeInterval(-3600)) }
                Button("Today") { history.clear(since: Calendar.current.startOfDay(for: Date())) }
                Button("All History") { history.clear() }
            }
        }
        .navigationTitle("History")
    }

    private func urls(_ ids: Set<UUID>) -> [URL] {
        // Search results can include older entries that aren't loaded.
        var seen = Set<UUID>()
        return ((results ?? []) + history.entries).filter { ids.contains($0.id) && seen.insert($0.id).inserted }.map(\.url)
    }

    private func copy(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Bookmarks

struct BookmarkList: View {
    let open: ([URL]) -> Void
    private var bookmarks = Bookmarks.shared
    @State private var selection = Set<UUID>()
    @State private var renaming: Bookmark?
    @State private var newTitle = ""
    @State private var message: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(bookmarks.items) { b in
                HStack(spacing: 10) {
                    Group {
                        if let icon = Favicons.shared.cached(b.url.host) {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                    }
                    .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.title).lineLimit(1)
                        Text(b.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .tag(b.id)
            }
            .onMove { bookmarks.move(from: $0, to: $1) }
        }
        .overlay {
            if bookmarks.items.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "book",
                                       description: Text("Press ⌘D on any page, or import bookmarks from another browser."))
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Open") { open(urls(ids)) }
            if ids.count == 1, let b = bookmarks.items.first(where: { ids.contains($0.id) }) {
                Button("Rename…") { newTitle = b.title; renaming = b }
            }
            Divider()
            Button("Delete") { bookmarks.remove(ids) }
        } primaryAction: { ids in
            open(urls(ids))
        }
        .onDeleteCommand { bookmarks.remove(selection) }
        .toolbar {
            Button("Import…", action: importFile).help("Import bookmarks exported from Safari, Chrome or Firefox (HTML)")
            Button("Export…", action: exportFile)
        }
        .alert("Rename Bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Save") { if let r = renaming { bookmarks.rename(r.id, to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .navigationTitle("Bookmarks")
    }

    private func urls(_ ids: Set<UUID>) -> [URL] {
        bookmarks.items.filter { ids.contains($0.id) }.map(\.url)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let n = bookmarks.importHTML(String(decoding: data, as: UTF8.self))
        message = n == 1 ? L("Imported 1 bookmark.") : String(format: L("Imported %lld bookmarks."), n)
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "Tacet Bookmarks.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try bookmarks.exportHTML().write(to: url, atomically: true, encoding: .utf8) } catch { Dialogs.saveFailed(error, window: NSApp.keyWindow) }
    }
}


// MARK: - Reading list

/// Articles saved from Reader, to read without a connection.
struct ReadingListView: View {
    let openOnline: ([URL]) -> Void
    private var list = ReadingList.shared
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var confirmClear = false
    @Environment(\.openWindow) private var openWindow

    init(openOnline: @escaping ([URL]) -> Void) { self.openOnline = openOnline }

    private var shown: [ReadingList.Article] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? list.items : list.items.filter { ($0.title + " " + $0.site).lowercased().contains(q) }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(shown) { a in
                HStack(spacing: 10) {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).opacity(a.read ? 0 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title).lineLimit(1).fontWeight(a.read ? .regular : .medium)
                        Text(a.site + " · " + a.saved.formatted(date: .abbreviated, time: .omitted) + " · "
                             + ByteCountFormatter.string(fromByteCount: Int64(a.bytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).help("Saved for offline reading")
                }
                .tag(a.id)
            }
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? LocalizedStringKey("No Saved Articles") : "No Results", systemImage: "eyeglasses")
                } description: {
                    if query.isEmpty { Text("Open an article in Reader (⇧⌘R) and choose Save for Offline to read it later, even without a connection.") }
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Open") { open(ids) }
            Button("Open Original Page") { openOnline(articles(ids).map(\.url)) }
            Divider()
            if articles(ids).contains(where: { !$0.read }) {
                Button("Mark as Read") { for a in articles(ids) { list.markRead(a.id) } }
            } else {
                Button("Mark as Unread") { for a in articles(ids) { list.markRead(a.id, false) } }
            }
            Divider()
            Button("Delete") { for id in ids { list.remove(id) } }
        } primaryAction: { ids in
            open(ids)
        }
        .onDeleteCommand { for id in selection { list.remove(id) } }
        .searchable(text: $query, placement: .toolbar, prompt: "Search reading list")
        .toolbar {
            Button("Delete All…") { confirmClear = true }.disabled(list.items.isEmpty)
        }
        .confirmationDialog("Delete all saved articles?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { list.removeAll() }
        } message: {
            Text("This can't be undone.")
        }
        .navigationTitle("Reading List")
    }

    private func articles(_ ids: Set<UUID>) -> [ReadingList.Article] { list.items.filter { ids.contains($0.id) } }

    private func open(_ ids: Set<UUID>) {
        let target = WindowRegistry.shared.lastFocused.flatMap { $0.isPrivate ? nil : $0 }
            ?? WindowRegistry.shared.browsers.first { !$0.isPrivate }
        guard let b = target else { openWindow(id: "main"); return }
        for a in articles(ids) {
            let tab = b.newTab()
            tab.openOffline(a)
        }
        b.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Highlights

/// Every passage you highlighted, with its note and page: search them, open the page at the passage, or take them
/// to a notes app as Markdown.
struct HighlightsList: View {
    let open: ([URL]) -> Void
    private var store = Highlights.shared
    @State private var query = ""
    @State private var selection = Set<UUID>()

    private var shown: [Highlight] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return store.items }
        return store.items.filter { h in
            let hay = (h.quote + " " + h.note + " " + h.title + " " + (h.url.host ?? "")).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        let list = shown
        List(selection: $selection) {
            ForEach(list) { h in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: Highlight.colors[h.color % Highlight.colors.count].swatch)).frame(width: 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(h.plainQuote).lineLimit(4)
                        if !h.note.isEmpty {
                            Label(h.note, systemImage: "note.text").font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Text((h.title.isEmpty ? (h.url.host ?? "") : h.title) + " · " + h.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .tag(h.id)
            }
        }
        .overlay {
            if list.isEmpty {
                ContentUnavailableView(query.isEmpty ? LocalizedStringKey("No Highlights") : "No Results", systemImage: "highlighter",
                                       description: query.isEmpty ? Text("Select text on a page, right-click it and choose Highlight.") : nil)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Open") { open(picked(ids).map(\.linkToPassage)) }
            Button("Copy as Markdown") { copy(store.markdown(picked(ids))) }
            if ids.count == 1, let h = picked(ids).first {
                Button("Edit Note…") { editNote(h) }
                Menu("Colour") {
                    ForEach(Highlight.colors.indices, id: \.self) { i in
                        Button(L(Highlight.colors[i].name)) { store.update(h.id) { $0.color = i } }
                    }
                }
            }
            Divider()
            Button("Delete") { store.remove(ids) }
        } primaryAction: { ids in
            open(picked(ids).map(\.linkToPassage))
        }
        .onDeleteCommand { store.remove(selection) }
        .searchable(text: $query, placement: .toolbar, prompt: "Search highlights and notes")
        .toolbar {
            Button("Export as Markdown…") { export(list) }.disabled(list.isEmpty)
        }
        .navigationTitle("Highlights")
    }

    private func picked(_ ids: Set<UUID>) -> [Highlight] { store.items.filter { ids.contains($0.id) } }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func editNote(_ h: Highlight) {
        Dialogs.prompt(nil, title: L("Note"), message: h.plainQuote.count > 160 ? String(h.plainQuote.prefix(160)) + "…" : h.plainQuote,
                       defaultText: h.note) { text in
            guard let text else { return }
            store.update(h.id) { $0.note = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private func export(_ list: [Highlight]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = L("Highlights") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.markdown(list).write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }
}
