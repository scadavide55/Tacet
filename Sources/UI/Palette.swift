import SwiftUI

struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String)
        case image(NSImage)
    }

    let id: String
    let icon: Icon
    let title: String
    let subtitle: String
    let badge: String
    /// Called with true when the user asks for a new tab (⌘↩).
    let run: (Bool) -> Void
}

/// The command bar: address entry, search, open tabs, bookmarks, history and commands in one list.
struct CommandPalette: View {
    @Environment(BrowserState.self) var b
    @Bindable private var s = Settings.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selection = 0
    @State private var suggestions: [String] = []
    @State private var suggestTask: Task<Void, Never>?
    @State private var historyHits: [HistoryEntry] = []
    /// Pages found by what they said.
    @State private var pageHits: [PageText.Hit] = []
    @State private var historyTask: Task<Void, Never>?
    /// The rows, rebuilt only when the query or its async results change, never on hover or page loads.
    @State private var list: [PaletteItem] = []
    /// A quick answer from Tacet Assistant is showing in place of the list.
    @State private var answering = false
    /// The address the typed text completes to, shown in grey after it; Tab or → accepts it.
    @State private var completion: String?
    @State private var completionSites: [String: Int] = [:]
    @State private var typedCount = 0
    @FocusState private var focused: Bool

    private static let suggestSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 4
        return URLSession(configuration: c)
    }()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Search, enter an address, or run a command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
                        .overlay(alignment: .leading) { completionGhost }
                        .onKeyPress(.downArrow) { move(1, list.count); return .handled }
                        .onKeyPress(.upArrow) { move(-1, list.count); return .handled }
                        .onKeyPress(.tab) { acceptCompletion() ? .handled : .ignored }
                        .onKeyPress(.rightArrow) { acceptCompletion() ? .handled : .ignored }
                        .onKeyPress(.escape) {
                            if completion != nil { completion = nil } else if answering { closeAnswer() } else { close() }
                            return .handled
                        }
                        .onKeyPress(keys: [.return]) { press in
                            if let done = completion, selection == 0, let url = URL(string: "https://" + done) {
                                close()
                                navigate(url, newTab: press.modifiers.contains(.command))
                                return .handled
                            }
                            run(list, newTab: press.modifiers.contains(.command))
                            return .handled
                        }
                        .onSubmit { run(list, newTab: false) }
                        .onExitCommand { answering ? closeAnswer() : close() }
                    if b.isPrivate {
                        Image(systemName: "eyeglasses").foregroundStyle(.purple).help("Private window")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 54)

                if answering {
                    Divider()
                    QuickAnswer(chat: b.quickAnswer, close: closeAnswer, expand: expandAnswer)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if !list.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                                    PaletteRow(item: item, selected: i == selection)
                                        .equatable()
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selection = i
                                            run(list, newTab: NSEvent.modifierFlags.contains(.command))
                                        }
                                        .onHover { if $0 { selection = i } }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 400)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: selection) { _, v in
                            if list.indices.contains(v) { proxy.scrollTo(list[v].id) }
                        }
                    }
                }
                HStack(spacing: 14) {
                    hint("↩", "Open")
                    hint("⌘↩", "New tab")
                    hint("↑↓", "Select")
                    hint("esc", "Close")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Color.primary.opacity(0.03))
            }
            .frame(width: 640)
            .background(VisualEffect(material: .popover, blending: .withinWindow))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
            .padding(.top, 84)
        }
        .onAppear {
            query = b.palettePrefill
            typedCount = query.count
            loadCompletionSites()
            selection = 0
            refresh()
            fetchHistory(query)
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear {
            // The rows' actions hold on to this view's state, which holds the rows: emptying the list lets both go.
            list = []
            suggestTask?.cancel()
            historyTask?.cancel()
        }
        .animation(.easeOut(duration: 0.22), value: answering)
        .onChange(of: query) { _, q in
            if answering { closeAnswer() }
            // Only while typing forward: deleting removes the completion instead of bringing it back.
            let grew = q.count > typedCount
            typedCount = q.count
            let next = grew ? InlineCompletion.complete(q.trimmingCharacters(in: .whitespaces), candidates: completionSites) : nil
            if completion != next { completion = next }
            selection = 0
            refresh()
            fetchHistory(q)
            fetchSuggestions(q)
            // Several words that aren't an address may become a question: the assistant's connection opens now.
            let typed = q.trimmingCharacters(in: .whitespaces)
            if typed.contains(" "), URL(string: typed)?.scheme == nil, InputResolver.addressURL(typed) == nil { AIClient.warm() }
        }
        .onChange(of: suggestions) { _, _ in refresh() }
        .onChange(of: historyHits.map(\.id)) { _, _ in refresh() }
        .onChange(of: pageHits.map(\.id)) { _, _ in refresh() }
    }

    /// The rest of the completed address, in grey right after what was typed.
    @ViewBuilder private var completionGhost: some View {
        if let done = completion, let rest = InlineCompletion.suffix(of: done, typed: query) {
            HStack(spacing: 0) {
                Text(query).hidden()
                Text(rest).foregroundStyle(.secondary)
            }
            .font(.system(size: 18))
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func acceptCompletion() -> Bool {
        guard let done = completion, InlineCompletion.suffix(of: done, typed: query) != nil else { return false }
        completion = nil
        typedCount = done.count
        query = done
        return true
    }

    /// Sites to complete from, worked out once per opening from the history in memory. Never in private windows.
    private func loadCompletionSites() {
        guard !b.isPrivate, Settings.shared.inlineCompletion else { completionSites = [:]; return }
        let entries = History.shared.entries
        Task {
            let sites = await Task.detached(priority: .userInitiated) { InlineCompletion.candidates(entries) }.value
            completionSites = sites
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            // A String label isn't looked up by Text, so it's translated here.
            Text(L(label)).font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Behaviour

    private func move(_ step: Int, _ count: Int) {
        guard count > 0 else { return }
        selection = (selection + step + count) % count
    }

    private func close() {
        suggestTask?.cancel()
        historyTask?.cancel()
        if answering { closeAnswer() }
        b.paletteVisible = false
    }

    // MARK: Quick answers

    private func ask(_ question: String) {
        let chat = b.quickAnswer
        chat.newChat()
        chat.draft = question
        chat.send()
        answering = true
    }

    private func closeAnswer() {
        b.quickAnswer.newChat()
        answering = false
    }

    /// Goes on with the question in the full chat.
    private func expandAnswer() {
        b.assistant.continueFrom(b.quickAnswer)
        answering = false
        b.assistantVisible = true
        b.assistantExpanded = true
        close()
    }

    private func run(_ list: [PaletteItem], newTab: Bool) {
        guard b.paletteVisible else { return }
        if list.indices.contains(selection) {
            let item = list[selection]
            // Asking keeps the command bar open: the answer shows in it.
            if item.id == "ask" {
                ask(query.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            close()
            item.run(newTab)
        } else {
            close()
        }
    }

    private func navigate(_ url: URL, newTab: Bool) {
        if url.scheme?.lowercased() == "view-source" {
            if let inner = URL(string: String(url.absoluteString.dropFirst("view-source:".count))) { DevTools.viewSource(of: inner) }
            return
        }
        if OpeningRules.route(url, from: b) { return }
        if newTab || b.current == nil {
            b.newTab(url: url).typedLoad = true
        } else {
            b.current?.typedLoad = true
            b.current?.load(url)
        }
    }

    private func fetchSuggestions(_ q: String) {
        suggestTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard s.suggestions, !b.isPrivate, trimmed.count >= 2, InputResolver.addressURL(trimmed) == nil,
              URL(string: trimmed)?.scheme == nil,
              let template = s.engine.suggestTemplate, let url = InputResolver.fill(template, trimmed) else {
            suggestions = []
            return
        }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let (data, _) = try? await Self.suggestSession.data(from: url) else { return }
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
            let list = parsed?.dropFirst().first as? [String] ?? []
            if !Task.isCancelled { suggestions = Array(list.prefix(5)) }
        }
    }

    private func fetchHistory(_ q: String) {
        historyTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            historyHits = []
            pageHits = []
            return
        }
        historyTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let hits = await History.shared.searchInBackground(trimmed, limit: 6)
            // Only from three letters on: shorter words match nearly every page.
            let read = trimmed.count >= 3 && Settings.shared.rememberPageText && !b.isPrivate ? await PageText.shared.search(trimmed, limit: 4) : []
            if !Task.isCancelled {
                historyHits = hits
                pageHits = read
            }
        }
    }

    // MARK: Results

    private func refresh() { list = items }

    private var items: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [PaletteItem] = []

        if q.isEmpty || q == b.current?.url?.absoluteString {
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !clip.isEmpty, clip.count < 2000, !clip.contains("\n"), let url = InputResolver.resolve(clip) {
                let isAddress = URL(string: clip)?.scheme != nil || InputResolver.addressURL(clip) != nil
                out.append(PaletteItem(id: "paste", icon: .symbol("doc.on.clipboard"),
                                       title: isAddress ? L("Paste and Go") : L("Paste and Search"),
                                       subtitle: clip, badge: "↩", run: { navigate(url, newTab: $0) }))
            }
            out += b.tabs.filter { $0.id != b.selectedID }
                .sorted { $0.lastActive > $1.lastActive }
                .prefix(6).map(tabItem)
            out += commands.prefix(4)
            return out
        }

        if let url = InputResolver.resolve(q) {
            let shortcut = q.split(separator: " ", maxSplits: 1).count == 2
                ? s.shortcuts.first { $0.keyword.lowercased() == q.split(separator: " ")[0].lowercased() } : nil
            let isAddress = shortcut == nil && (URL(string: q)?.scheme != nil || InputResolver.addressURL(q) != nil)
            out.append(PaletteItem(
                id: "go",
                icon: .symbol(isAddress ? "arrow.up.right.circle.fill" : "magnifyingglass.circle.fill"),
                title: isAddress ? url.absoluteString : q,
                subtitle: isAddress ? L("Open address") : String(format: L("Search %@"), shortcut?.name ?? s.engine.name),
                badge: "↩",
                run: { navigate(url, newTab: $0) }))
            // The address is already open in another tab: going there comes first.
            if isAddress, let open = b.tabs.first(where: { $0.id != b.selectedID && InlineCompletion.sameAddress($0.url, url) }) {
                out.insert(tabItem(open), at: 0)
            }
        }

        // A sum is worked out on the spot, just below: ↓ ↩ copies the result, and ↩ alone still searches.
        if let value = Calculator.evaluate(q) {
            let result = Calculator.format(value)
            out.append(PaletteItem(id: "calc", icon: .symbol("equal.circle.fill"), title: "= " + result,
                                   subtitle: L("Copy the result"), badge: "↩", run: { _ in
                                       NSPasteboard.general.clearContents()
                                       NSPasteboard.general.setString(result, forType: .string)
                                   }))
        }

        if let converted = UnitConversion.convert(q) {
            let result = UnitConversion.format(converted)
            out.append(PaletteItem(id: "units", icon: .symbol("arrow.left.arrow.right.circle.fill"), title: "= " + result,
                                   subtitle: L("Copy the result"), badge: "↩", run: { _ in
                                       NSPasteboard.general.clearContents()
                                       NSPasteboard.general.setString(result, forType: .string)
                                   }))
        }

        if s.aiEnabled, InputResolver.addressURL(q) == nil, URL(string: q)?.scheme == nil {
            out.append(PaletteItem(id: "ask", icon: .symbol("sparkles"), title: String(format: L("Ask Tacet Assistant: %@"), q),
                                   subtitle: s.aiWeb ? L("A quick answer here, searching the web if needed") : L("A quick answer here"), badge: "↩", run: { _ in }))
        }

        let lower = q.lowercased()
        let matches: (String, URL?) -> Bool = { title, url in
            title.lowercased().contains(lower) || (url?.absoluteString.lowercased().contains(lower) ?? false)
        }
        out += b.tabs.filter { $0.id != b.selectedID && matches($0.title, $0.url) }.prefix(4).map(tabItem)

        var shown = Set(b.tabs.compactMap(\.url))
        let marks = Bookmarks.shared.items.filter { matches($0.title, $0.url) && !shown.contains($0.url) }.prefix(4)
        out += marks.map { bm in
            PaletteItem(id: "b" + bm.id.uuidString, icon: favicon(bm.url, fallback: "star.fill"), title: bm.title,
                        subtitle: InputResolver.displayHost(bm.url), badge: "Bookmark",
                        run: { navigate(bm.url, newTab: $0) })
        }
        shown.formUnion(marks.map(\.url))

        if !b.isPrivate {
            out += ReadingList.shared.items.filter { matches($0.title, $0.url) }.prefix(3).map { a in
                PaletteItem(id: "r" + a.id.uuidString, icon: .symbol("eyeglasses"), title: a.title, subtitle: a.site,
                            badge: "Offline", run: { newTab in
                                let tab = newTab || b.current == nil ? b.newTab() : b.current!
                                tab.openOffline(a)
                            })
            }
        }

        // Earlier hits that still match stay visible until the background search for this query lands.
        let words = lower.split(separator: " ").map(String.init)
        let hits = historyHits.filter { h in
            let hay = (h.title + " " + h.url.absoluteString).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        out += hits.filter { !shown.contains($0.url) }.map { h in
            PaletteItem(id: "h" + h.id.uuidString, icon: favicon(h.url, fallback: "clock"),
                        title: h.title.isEmpty ? h.url.absoluteString : h.title,
                        subtitle: h.url.absoluteString, badge: "History",
                        run: { navigate(h.url, newTab: $0) })
        }

        out += pageHits.filter { hit in !shown.contains(hit.url) && !hits.contains { $0.url == hit.url } }.map { hit in
            PaletteItem(id: "p" + hit.url.absoluteString, icon: favicon(hit.url, fallback: "doc.text.magnifyingglass"),
                        title: hit.title.isEmpty ? hit.url.absoluteString : hit.title,
                        subtitle: plainSnippet(hit.snippet), badge: "Read",
                        run: { navigate(hit.url, newTab: $0) })
        }

        out += commands.filter { $0.title.lowercased().contains(lower) || $0.subtitle.lowercased().contains(lower) }.prefix(5)

        out += suggestions.filter { $0.lowercased() != lower }.map { text in
            PaletteItem(id: "s" + text, icon: .symbol("magnifyingglass"), title: text,
                        subtitle: String(format: L("Search %@"), s.engine.name), badge: "Suggestion",
                        run: { nt in if let u = InputResolver.searchURL(text) { navigate(u, newTab: nt) } })
        }
        return out
    }

    private func favicon(_ url: URL, fallback: String) -> PaletteItem.Icon {
        Favicons.shared.cached(url.host).map { .image($0) } ?? .symbol(fallback)
    }

    private func tabItem(_ t: Tab) -> PaletteItem {
        PaletteItem(id: "t" + t.id.uuidString, icon: t.favicon.map { .image($0) } ?? .symbol("square.on.square"),
                    title: t.title, subtitle: t.url.map { InputResolver.displayHost($0) } ?? L("Start page"),
                    badge: "Switch to Tab", run: { _ in b.select(t) })
    }

    private func command(_ title: String, _ symbol: String, _ detail: String = "", _ action: @escaping () -> Void) -> PaletteItem {
        PaletteItem(id: "c" + title, icon: .symbol(symbol), title: L(title), subtitle: L(detail), badge: "Command", run: { _ in action() })
    }

    private var commands: [PaletteItem] {
        let tab = b.current
        var list = [
            command("New Tab", "plus.square", "⌘T") { b.newTab() },
            command("New Window", "macwindow", "⌘N") { openWindow(id: "main") },
            command("New Private Window", "eyeglasses", "⇧⌘N") { openWindow(id: "private") },
            command("Reopen Closed Tab", "arrow.uturn.backward", "⇧⌘T") { b.reopenLastClosed() },
            command("Tacet Plugins", "puzzlepiece.extension", "⇧⌘P") { openWindow(id: "plugins") },
            command("Toggle Sidebar", "sidebar.left", "⌘S") { b.sidebarVisible.toggle() },
            command("Split View with New Tab", "rectangle.split.2x1", "Show two pages side by side") { b.splitWithNewTab() },
            command("Show History", "clock", "⌘Y") { LibraryView.requestedSection = .history; openWindow(id: "library") },
            command("Show Bookmarks", "book", "⌥⌘B") { LibraryView.requestedSection = .bookmarks; openWindow(id: "library") },
            command("Show Downloads", "arrow.down.circle", "⌥⌘L") { LibraryView.requestedSection = .downloads; openWindow(id: "library") },
            command("Show Reading List", "eyeglasses", "Articles saved for offline reading") { LibraryView.requestedSection = .readingList; openWindow(id: "library") },
            command("Settings", "gearshape", "⌘,") { openSettings() },
            command("Import from Another Browser", "square.and.arrow.down", "Safari, Chrome, Firefox, Opera…") { openWindow(id: "import") },
            command("Welcome Tour", "sparkles", "Setup and how Tacet works") { b.showOnboarding = true },
            command("Keyboard Shortcuts", "keyboard", "Every shortcut in one place") { openWindow(id: "shortcuts") },
            command("Check for Updates", "arrow.down.app", "Looks for a newer Tacet on GitHub") { UpdateChecker.shared.check(force: true) { openWindow(id: "update") } },
            command(s.adBlock ? "Turn Off Ad Blocker" : "Turn On Ad Blocker", "shield.lefthalf.filled", "⇧⌘B") { s.adBlock.toggle() },
            command("Lock Window with Touch ID", "lock", "⌃⌘L") { b.lock() },
            command("New Space", "square.stack", "A set of tabs to leave and come back to") { SpaceActions.askNew(in: b) },
            command("Turn Off Spaces", "square.stack.3d.down.forward", "Every Space becomes a tab group in this window") { SpaceActions.askTurnOff(in: b) },
            command("Hibernate Other Tabs", "moon.zzz", "Free memory used by background tabs") { b.hibernateOthers() },
            command("Close Duplicate Tabs", "square.on.square.dashed", "Keeps one tab per address") { b.closeDuplicates() },
            command("Group Tabs by Site", "square.grid.3x1.folder.badge.plus", "Groups tabs from the same site now") { b.groupBySiteNow() },
            command("Sort Tabs by Site", "arrow.up.arrow.down", "Sort Tabs") { b.sortTabs(by: .site) },
            command("Sort Tabs by Title", "arrow.up.arrow.down", "Sort Tabs") { b.sortTabs(by: .title) },
            command("Sort Tabs by Last Opened", "arrow.up.arrow.down", "Sort Tabs") { b.sortTabs(by: .recent) },
            command("Dark Appearance", "moon", "Appearance") { s.theme = .dark },
            command("Light Appearance", "sun.max", "Appearance") { s.theme = .light },
            command("System Appearance", "circle.lefthalf.filled", "Appearance") { s.theme = .system },
            command(s.tabLayout == .vertical ? "Use Top Tabs" : "Use Sidebar Tabs", "rectangle.topthird.inset.filled", "Layout") {
                s.tabLayout = s.tabLayout == .vertical ? .horizontal : .vertical
            },
        ]
        if s.developer {
            list += [
                command("Show Web Inspector", "hammer", "⌥⌘I") { DevTools.showInspector(tab) },
                command("Show JavaScript Console", "terminal", "⌥⌘C") { DevTools.showConsole(tab) },
                command("Inspect Element", "scope", "⌥⇧⌘C") { DevTools.pickElement(tab) },
                command("View Page Source", "chevron.left.forwardslash.chevron.right", "⌥⌘U") { DevTools.viewSource(tab) },
                command("Page Info", "info.circle", "Load times, size and contents of the page") { DevTools.pageInfo(tab) },
                command(tab?.device == nil ? "Responsive Design Mode" : "Exit Responsive Design Mode", "iphone", "Develop") {
                    DevTools.setDevice(tab?.device == nil ? DevDevice.all[1] : nil, on: tab)
                },
                command(tab?.javaScriptOff == true ? "Enable JavaScript" : "Disable JavaScript", "curlybraces", "Develop") { DevTools.toggleJavaScript(tab) },
                command("Empty Caches", "trash", "⌥⌘E") { DevTools.emptyCaches(tab) },
                command("Turn Off Developer Mode", "hammer", "Hides the Develop menu") { s.developer = false },
            ]
        } else {
            list.append(command("Turn On Developer Mode", "hammer", "Web Inspector, page source and more") { s.developer = true })
        }
        for a in s.automations where !a.steps.isEmpty {
            list.append(PaletteItem(id: "auto" + a.id.uuidString, icon: .symbol("bolt"), title: a.name,
                                    subtitle: a.shortcutLabel ?? a.steps.map(\.label).joined(separator: " · "), badge: "Automation",
                                    run: { _ in Task { @MainActor in await AutomationRunner.run(a, in: b) } }))
        }
        if !b.isPrivate {
            for space in Spaces.shared.items(for: b.profileID) where space.id != b.spaceID {
                list.append(PaletteItem(id: "space" + space.id.uuidString, icon: .symbol(space.symbol),
                                        title: String(format: L("Switch to %@"), space.name),
                                        subtitle: space.note.isEmpty ? L("Space") : space.note, badge: "Command",
                                        run: { _ in b.switchSpace(to: space.id) }))
            }
        }
        if let tab, tab.url != nil {
            list.insert(contentsOf: [
                command(tab.isReader ? "Exit Reader" : "Reader", "doc.plaintext", "⇧⌘R") { tab.toggleReader() },
                command("Find on Page", "text.magnifyingglass", "⌘F") { b.showFind() },
                command("Save for Offline", "arrow.down.circle", "Reading List") { tab.saveForOffline() },
                command("Site Information", "lock", "Certificate, permissions, zoom, pop-ups, Tacet Shield") { b.showSiteInfo = true },
                command("Customize This Site", "paintbrush", "Colours, fonts, hidden elements, CSS and JavaScript") { b.customizingSite = true },
                command("Pick Elements to Hide", "cursorarrow.rays", "Click parts of the page to hide them on this site") { tab.startPickingElements() },
                command(Bookmarks.shared.contains(tab.url) ? "Remove Bookmark" : "Bookmark This Page", "star", "⌘D") {
                    Bookmarks.shared.toggle(url: tab.url, title: tab.title)
                },
                command("Copy Link", "link", "⇧⌘C") { copy(tab.url) },
                command("Copy Link as Markdown", "text.badge.plus", "[Title](address)") {
                    let url = tab.url.map { URLCleaner.clean($0) ?? $0 }?.absoluteString ?? ""
                    let title = tab.title.replacingOccurrences(of: "]", with: "\\]")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("[\(title)](\(url))", forType: .string)
                },
                command("Copy Link Without Tracking", "link.badge.plus", "Removes utm_ and similar parameters") {
                    copy(tab.url.map { URLCleaner.clean($0) ?? $0 })
                },
                command(tab.isPinned ? "Unpin Tab" : "Pin Tab", "pin", "") { b.togglePin(tab) },
                command("Duplicate Tab", "plus.square.on.square", "") { b.duplicate(tab) },
                command(tab.isMuted ? "Unmute Tab" : "Mute Tab", "speaker.slash", "") { tab.setMuted(!tab.isMuted) },
                command("Zoom In", "plus.magnifyingglass", "⌘+") { tab.zoom(1) },
                command("Zoom Out", "minus.magnifyingglass", "⌘−") { tab.zoom(-1) },
                command("Actual Size", "1.magnifyingglass", "⌘0") { tab.zoom(0) },
                command("Print", "printer", "⌘P") { tab.printPage() },
                command("Export as PDF", "doc.richtext", "⇧⌘E") { tab.exportPDF() },
                command("Install as App", "app.badge.checkmark", "Its own window and Dock icon") { b.showInstallApp = true },
                command("Take Screenshot of Page", "camera.viewfinder", "⇧⌘S") { tab.screenshot() },
                command("Take Screenshot of Whole Page", "camera.viewfinder", "⌥⇧⌘S") { tab.screenshotFullPage() },
                command("Take Screenshot of Element", "viewfinder", "") { tab.startPickingScreenshot() },
            ], at: 1)
        }
        list += groupCommands
        // Apps from Tacet Plugins, such as Cutout.
        for item in PluginStore.shared.installed.values where item.enabled {
            if let start = item.plugin.startURL {
                list.append(command(String(format: L("Open %@"), L(item.plugin.name)), item.plugin.icon ?? "puzzlepiece.extension", L("Tacet Plugins")) { b.newTab(url: start) })
            }
        }
        return list
    }

    /// Moving the current tab (or the picked ones) into a group, and the group commands.
    private var groupCommands: [PaletteItem] {
        guard let tab = b.current else { return [] }
        let targets = b.marked.count > 1 ? b.orderedTabs.filter { b.marked.contains($0.id) } : [tab]
        var out: [PaletteItem] = []
        for g in b.groups where targets.contains(where: { $0.groupID != g.id }) {
            out.append(PaletteItem(id: "mg" + g.id.uuidString, icon: .symbol("folder"),
                                   title: String(format: L("Move to Group “%@”"), g.name), subtitle: L("Move to Group…"),
                                   badge: "Command", run: { _ in b.move(targets, toGroup: g.id) }))
        }
        out.append(command("Move to New Group", "folder.badge.plus", "Move to Group…") { b.group(targets) })
        if let gid = tab.groupID, let g = b.groups.first(where: { $0.id == gid }) {
            out.append(command("New Tab in Group", "plus.square", g.name) { b.newTab(inGroup: gid) })
            if !b.isPrivate {
                out.append(PaletteItem(id: "sg" + g.id.uuidString, icon: .symbol("archivebox"),
                                       title: String(format: L("Save and Close “%@”"), g.name), subtitle: L("Saved Groups"),
                                       badge: "Command", run: { _ in b.saveAndClose(gid) }))
            }
        }
        if !b.isPrivate {
            for saved in SavedGroups.shared.items {
                out.append(PaletteItem(id: "og" + saved.id.uuidString, icon: .symbol("folder.fill"),
                                       title: String(format: L("Open Saved Group “%@”"), saved.name),
                                       subtitle: String(format: L("%d Tabs"), saved.tabs.count),
                                       badge: "Command", run: { _ in b.open(saved) }))
            }
        }
        return out
    }

    private func copy(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

struct PaletteRow: View, Equatable {
    let item: PaletteItem
    let selected: Bool

    static func == (a: PaletteRow, b: PaletteRow) -> Bool {
        a.selected == b.selected && a.item.id == b.item.id && a.item.title == b.item.title
            && a.item.subtitle == b.item.subtitle && a.item.badge == b.item.badge
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch item.icon {
                case .image(let img):
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                case .symbol(let name):
                    Image(systemName: name).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)))

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(verbatim: item.subtitle).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
                }
            }
            Spacer(minLength: 8)
            Text(L(item.badge)).font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        }
        .foregroundStyle(selected ? Color.white : .primary)
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
    }
}

/// Tacet Assistant's answer inside the command bar, as it arrives. ✕ closes it; the arrows open it in the full chat.
struct QuickAnswer: View {
    var chat: AssistantChat
    let close: () -> Void
    let expand: () -> Void
    @Environment(BrowserState.self) var b

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Tacet Assistant").font(.system(size: 12, weight: .semibold))
                Text(chat.model).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if chat.busy { ProgressView().controlSize(.small) }
                Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help("Continue in the chat")
                    .disabled(chat.messages.isEmpty)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close the answer (esc)")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let answer = chat.messages.last(where: { $0.role == .assistant }) {
                            AssistantBubble(message: answer, thinking: chat.busy)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: chat.messages.last?.text.count)
    }
}
