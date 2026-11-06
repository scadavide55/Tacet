import AppKit
import WebKit

/// The assistant's own tools, run for the model: what each one does, and the steps it shows.
extension AssistantChat {
    // MARK: Tacet Plugins

    @MainActor
    private func usePlugin(_ args: [String: Any], call: String) async -> (String, Bool) {
        let wanted = ((args["plugin"] as? String) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let installed = PluginStore.shared.installed.values
        guard let item = installed.first(where: { $0.plugin.id == wanted || $0.plugin.name.lowercased() == wanted }) else {
            let names = installed.map { "\($0.plugin.id) (\($0.plugin.name))" }.sorted().joined(separator: ", ")
            return ("The plugin \"\(wanted)\" isn't installed. Installed: \(names.isEmpty ? "none" : names). Others are in Tacet Plugins (⇧⌘P).", true)
        }
        let p = item.plugin
        guard item.enabled else { return ("\(p.name) is turned off. The user can turn it on from the puzzle button in the toolbar.", true) }
        guard let browser else { return ("The browser window is closed.", true) }
        beginStep(.tool, String(format: L("Using %@"), L(p.name)), call: call)
        switch p.behaviour {
        case "app":
            if p.handoff != nil, let tab = browser.current, tab.url != nil {
                var src = (args["image_url"] as? String)?.trimmingCharacters(in: .whitespaces)
                if src?.isEmpty != false, let wv = tab.webView {
                    // The biggest picture showing on the page.
                    let js = "(() => { const imgs = [...document.images].filter(i => i.naturalWidth >= 120 && i.getBoundingClientRect().width > 60);"
                        + " imgs.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight);"
                        + " return imgs[0] ? (imgs[0].currentSrc || imgs[0].src) : null; })()"
                    src = (try? await wv.evaluateJavaScript(js, in: nil, contentWorld: .defaultClient)) as? String
                }
                if let src, let url = URL(string: src) {
                    let ok = await PluginBridge.send(imageAt: url, to: p, from: tab)
                    return (ok ? "Opened \(p.name) in a new tab with the picture \(src) in it; the user picks an engine there and it runs on their Mac."
                               : "The picture at \(src) couldn't be read (it may not be on a public address).", !ok)
                }
            }
            guard let url = p.startURL else { return ("\(p.name) has nothing to open.", true) }
            browser.newTab(url: url)
            return ("Opened \(p.name) in a new tab.", false)
        case "action":
            let before = NSPasteboard.general.changeCount
            await PluginStore.shared.runAction(p, in: browser.current)
            let copied = NSPasteboard.general.changeCount != before
            return ("Ran \(p.action ?? p.name) on the current page" + (copied ? "; the result is on the clipboard." : "."), false)
        case "toggle":
            return ("\(p.name) is on and works by itself on its sites; there's nothing to run. It can be turned off from the puzzle button.", false)
        default:
            return ("\(p.name) works with its keys: \(p.shortcut ?? "see its description"). \(p.description)", false)
        }
    }

    enum Approval { case allow, allowPage, deny }

    /// Asks before a click Tacet can't tell is harmless. "Allow on This Page" covers the other controls on the same
    /// page until it changes; never sending, buying, deleting or publishing.
    @MainActor
    private func confirmPageAction(_ label: String, on tab: Tab, risky: Bool) async -> Approval {
        let alert = NSAlert()
        alert.messageText = String(format: L("Tacet Assistant wants to click “%@” on %@."),
                                   label.isEmpty ? L("a button") : label, InputResolver.displayHost(tab.url))
        alert.informativeText = risky ? L("This could send, buy, delete or publish something. Allow it only if it's what you asked for.")
            : L("Tacet can't tell what this button does on this site. Allow it if it's part of what you asked for.")
        alert.addButton(withTitle: L("Allow"))
        if !risky { alert.addButton(withTitle: L("Allow on This Page")) }
        alert.addButton(withTitle: L("Don't Allow"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        let pick: (NSApplication.ModalResponse) -> Approval = { r in
            switch r {
            case .alertFirstButtonReturn: .allow
            case .alertSecondButtonReturn where !risky: .allowPage
            default: .deny
            }
        }
        guard let window = tab.webView?.window ?? NSApp.keyWindow else { return pick(alert.runModal()) }
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: pick($0)) }
        }
    }

    // MARK: Memory

    /// Saves a fact only after the user agrees to the exact text, on this Mac, and never in a private window: the
    /// model's word is not enough, since a page could have put the idea there.
    @MainActor
    private func remember(_ args: [String: Any], call: String, in browser: BrowserState) async -> (String, Bool) {
        let privateWindow = isPrivate
        let fact = (args["fact"] as? String) ?? ""
        let outcome = await AssistantMemory.shared.propose(fact, allowed: AssistantPersonal.memoryOn(privateWindow: privateWindow)) { text in
            beginStep(.tool, L("Asking to remember something"), call: call)
            return await askToRemember(text, in: browser)
        }
        if Task.isCancelled { return ("Stopped.", true) }
        switch outcome {
        case .off:
            return ("Memory is off" + (privateWindow ? " in private windows" : "") + ", so nothing was saved. Don't mention it unless the user asks.", true)
        case .empty:
            return ("The fact is empty.", true)
        case .already:
            return ("This is already remembered.", false)
        case .declined:
            callOutcomes[call] = L("Not saved")
            return ("The user chose not to save this. Don't ask to remember it again.", false)
        case .saved:
            callOutcomes[call] = L("Saved")
            return ("Saved. You'll know this in later chats.", false)
        }
    }

    /// Shows the exact text to the user, as a sheet on the chat's window when there is one.
    @MainActor
    private func askToRemember(_ fact: String, in browser: BrowserState) async -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Tacet Assistant wants to remember this:")
        alert.informativeText = "“\(fact)”\n\n" + L("It's kept on this Mac only and used in later chats, except in private windows. You can change or delete it in Settings › AI.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Don't Save"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        if let window = browser.current?.webView?.window ?? NSApp.keyWindow {
            return await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    func runTool(_ call: AIClient.ToolCall) async -> (String, Bool) {
        guard let args = call.arguments else { return ("INVALID_JSON: the tool input could not be parsed.", true) }
        guard let browser else { return ("The browser window is closed.", true) }
        switch call.name {
        case "get_page_content":
            guard let tab = browser.current, tab.url != nil else { return ("No web page is open in the current tab.", false) }
            beginStep(.read, tab.title, url: tab.url, call: call.id)
            if let u = tab.url { sentPageURL = u }
            return (await Self.pageContent(of: tab, limit: limits.pageChars), false)
        case "get_selection":
            beginStep(.tool, L("Reading the selection"), call: call.id)
            guard let wv = browser.current?.webView else { return ("No web page is open in the current tab.", false) }
            let text = try? await wv.evaluateJavaScript("String(window.getSelection ? window.getSelection() : '')", in: nil, contentWorld: .defaultClient) as? String
            let selection = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (selection.isEmpty ? "Nothing is selected." : selection, false)
        case "list_tabs":
            beginStep(.tool, L("Looking at your tabs"), call: call.id)
            let lines = browser.tabs.enumerated().map { n, t in
                let group = t.groupID.flatMap { g in browser.groups.first { $0.id == g } }.map { " (group: \($0.name))" } ?? ""
                return "\(n + 1). " + (t.id == browser.selectedID ? "[current] " : "") + "\(t.title) — \(t.url?.absoluteString ?? "start page")" + group
            }
            return (lines.joined(separator: "\n"), false)
        case "read_tab":
            let n = Self.number(args["number"])
            guard browser.tabs.indices.contains(n - 1) else { return ("There is no tab \(n). There are \(browser.tabs.count) tabs; call list_tabs.", true) }
            let tab = browser.tabs[n - 1]
            guard tab.url != nil else { return ("Tab \(n) is an empty new tab.", false) }
            beginStep(.read, tab.title, url: tab.url, call: call.id)
            await AssistantSources.wake(tab)
            return (await Self.pageContent(of: tab, limit: limits.pageChars), false)
        case "get_video_transcript":
            let n = Self.number(args["number"])
            guard let tab = n > 0 ? (browser.tabs.indices.contains(n - 1) ? browser.tabs[n - 1] : nil) : browser.current else {
                return ("There is no tab \(n). Call list_tabs.", true)
            }
            guard AssistantSources.isVideo(tab.url) else { return ("That tab isn't showing a YouTube video.", true) }
            beginStep(.read, String(format: L("Transcript of “%@”"), tab.title), url: tab.url, call: call.id)
            await AssistantSources.wake(tab)
            guard let wv = tab.webView else { return ("The video's page couldn't be read.", true) }
            let (text, ok) = await AssistantSources.transcript(in: wv, limit: limits.pageChars * 2)
            return (text, !ok)
        case "search_history":
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return ("The query is empty.", true)
            }
            beginStep(.tool, String(format: L("Searching your history for “%@”"), query), call: call.id)
            let days = Self.number(args["days"])
            return (await AssistantSources.searchHistory(query, days: days > 0 ? days : nil), false)
        case "use_plugin":
            return await usePlugin(args, call: call.id)
        case "remember":
            return await remember(args, call: call.id, in: browser)
        case "research_stage":
            guard let stage = (args["stage"] as? String).flatMap(AssistantStep.Stage.init(rawValue:)) else {
                return ("Unknown stage. Use one of: " + AssistantStep.Stage.allCases.map(\.rawValue).joined(separator: ", ") + ".", true)
            }
            let note = ((args["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // One stage at a time: the one before ends here.
            if let i = messages.indices.last {
                for n in messages[i].steps.indices where messages[i].steps[n].kind == .stage { messages[i].steps[n].finish() }
            }
            beginStep(.stage, String(note.prefix(500)), stage: stage)
            return ("Noted; the user sees this stage. Go on.", false)
        case "tacet_guide":
            let query = (args["query"] as? String) ?? ""
            beginStep(.tool, L("Looking in the Tacet Guide"), call: call.id)
            return (TacetGuide.lookup(query), false)
        case "search_bookmarks":
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return ("The query is empty.", true)
            }
            beginStep(.tool, String(format: L("Searching your bookmarks for “%@”"), query), call: call.id)
            return (AssistantSources.searchBookmarks(query), false)
        case "take_screenshot":
            guard let wv = browser.current?.webView, browser.current?.url != nil else { return ("No web page is open in the current tab.", true) }
            beginStep(.browse, L("Taking a screenshot of the page"), call: call.id)
            guard let jpeg = await AssistantSources.screenshot(of: wv) else { return ("The screenshot couldn't be taken.", true) }
            toolImages[call.id] = jpeg
            return ("Screenshot of the visible part of the page, attached as an image.", false)
        case "open_url":
            guard let raw = args["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return ("The address must be an absolute http or https URL.", true)
            }
            let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? InputResolver.displayHost(url)
            if let i = messages.indices.last { messages[i].links.append((url, title)) }
            return ("The link is shown to the user as a button. It opens only if they click it.", false)
        case "open_page":
            guard let raw = (args["url"] as? String)?.trimmingCharacters(in: .whitespaces), let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                return ("The address must be an absolute http or https URL.", true)
            }
            guard WebTools.mayOpen(raw, in: transcript) else {
                if let i = messages.indices.last { messages[i].links.append((url, InputResolver.displayHost(url))) }
                return ("This address doesn't appear in the conversation, so it wasn't opened. It is shown to the user as a button instead.", false)
            }
            beginStep(.browse, String(format: L("Opening %@"), InputResolver.displayHost(url)), url: url, call: call.id)
            let tab = browser.newTab(url: url)
            return (await Self.loaded(tab), false)
        case "search_in_tab":
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
                  let url = InputResolver.searchURL(query) else { return ("The query is empty.", true) }
            beginStep(.browse, String(format: L("Searching for “%@”"), query), call: call.id)
            let tab = browser.newTab(url: url)
            return (await Self.loaded(tab), false)
        case "new_tab":
            beginStep(.browse, L("Opening a new tab"), call: call.id)
            browser.newTab()
            return ("An empty tab is open and selected.", false)
        case "group_tabs":
            let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let numbers = (args["tabs"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0) } }
            guard !name.isEmpty else { return ("The group needs a name.", true) }
            let picked = numbers.filter { browser.tabs.indices.contains($0 - 1) }.map { browser.tabs[$0 - 1] }
            guard !picked.isEmpty else { return ("None of those tab numbers exist. Call list_tabs to see the tabs.", true) }
            beginStep(.tool, String(format: L("Grouping tabs into “%@”"), name), call: call.id)
            guard let g = browser.group(picked, named: name) else { return ("The tabs couldn't be grouped.", true) }
            let missing = numbers.count - picked.count
            return ("\(picked.count) tabs are now in the group \"\(g.name)\"" + (missing > 0 ? "; \(missing) numbers didn't match a tab." : ".")
                + " Tab numbers have changed; call list_tabs again before using them.", false)
        case "switch_tab":
            let n = (args["number"] as? Int) ?? (args["number"] as? String).flatMap { Int($0) } ?? 0
            guard browser.tabs.indices.contains(n - 1) else { return ("There is no tab \(n). There are \(browser.tabs.count) tabs.", true) }
            let tab = browser.tabs[n - 1]
            beginStep(.browse, String(format: L("Switching to %@"), tab.title), call: call.id)
            browser.select(tab)
            return ("Switched to tab \(n): \(tab.title).", false)
        case "find_elements" where Settings.shared.aiControl, "click" where Settings.shared.aiControl,
             "type" where Settings.shared.aiControl, "scroll" where Settings.shared.aiControl, "drag" where Settings.shared.aiControl:
            guard let tab = browser.current, let wv = tab.webView, tab.url != nil else { return ("No web page is open in the current tab.", true) }
            let before = (tab.url, tab.title)
            let action: PageControl.Action
            switch call.name {
            case "find_elements":
                action = .find
                beginStep(.browse, L("Looking at the page"), call: call.id)
            case "click":
                action = .click
                beginStep(.browse, String(format: L("Clicking “%@”"), await PageControl.label(of: args["ref"], in: wv)), call: call.id)
            case "type":
                action = .type
                beginStep(.browse, String(format: L("Typing in “%@”"), await PageControl.label(of: args["ref"], in: wv)), call: call.id)
            case "scroll":
                action = .scroll
                beginStep(.browse, L("Scrolling the page"), call: call.id)
            default:
                action = .drag
                beginStep(.browse, L("Dragging on the page"), call: call.id)
            }
            // Sending, buying, deleting or publishing needs the user's OK here, not only the model's word for it.
            if action == .click || action == .type && (args["submit"] as? Bool ?? false) {
                let (label, risk) = await PageControl.risk(of: args["ref"], submitting: action == .type, in: wv)
                // A plain link only goes somewhere. Other controls need an OK, unless the user allowed this page (still
                // the same page) for anything but sending, buying, deleting or publishing, which is always asked.
                let pageAllowed = allowedPage.map { $0.tab == tab.id && $0.url == tab.url } ?? false
                if risk == .risky || risk == .unknown && !pageAllowed {
                    let answer = await confirmPageAction(label, on: tab, risky: risk == .risky)
                    guard answer != .deny else {
                        return ("The user didn't allow this. Don't try it another way; ask in the chat what they'd like to do.", true)
                    }
                    if answer == .allowPage { allowedPage = (tab.id, tab.url) }
                    if Task.isCancelled || browser.current !== tab || tab.webView !== wv { return ("Stopped.", true) }
                }
            }
            var (output, isError) = await PageControl.run(action, args: args, in: wv)
            if !isError, [.click, .type, .drag].contains(action) {
                // Give the page a moment to react, and to start loading if the action opened another page.
                try? await Task.sleep(for: .milliseconds(700))
                for _ in 0..<40 where tab.isLoading { try? await Task.sleep(for: .milliseconds(250)) }
                if let current = browser.current, current.id != tab.id {
                    output += "\nA new tab opened and is now current: \(current.title) — \(current.url?.absoluteString ?? "")"
                } else if tab.url != before.0 || tab.title != before.1 {
                    output += "\nThe page is now: \(tab.title) — \(tab.url?.absoluteString ?? "")"
                }
            }
            return (output, isError)
        case "web_search" where Settings.shared.aiWeb:
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return ("The query is empty.", true)
            }
            beginStep(.search, query, call: call.id)
            // The same search again in one answer gets the same results, without asking the search engine again.
            let key = query.lowercased()
            if let earlier = searched[key] {
                callOutcomes[call.id] = L("Already searched")
                return ("You already made this search in this answer; its results are above. Try different words if they weren't enough.\n\n" + earlier, false)
            }
            do {
                let answer = try await WebTools.search(query, engines: await SearchEngines.fromSettings())
                let results = answer.results
                // The engine that answered, as in "8 results · Brave", since a search can move on to the next one.
                let count = results.count == 1 ? L("1 result") : String(format: L("%d results"), results.count)
                callOutcomes[call.id] = count + " · " + answer.engine
                let text = WebTools.format(results, query: query)
                searched[key] = text
                return (text, false)
            } catch {
                callOutcomes[call.id] = L("The search failed")
                return ("The search failed: \(error.localizedDescription)", true)
            }
        case "web_fetch" where Settings.shared.aiWeb:
            guard let raw = (args["url"] as? String)?.trimmingCharacters(in: .whitespaces), let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return ("The address must be an absolute http or https URL.", true)
            }
            guard WebTools.mayOpen(raw, in: transcript) else {
                return ("This address doesn't appear in the conversation, so it can't be fetched. Only addresses from the user's messages, the page or earlier results can be read.", true)
            }
            beginStep(.read, InputResolver.displayHost(url), url: url, call: call.id)
            if fetched[url] != nil {
                callOutcomes[call.id] = L("Already read")
                return ("You already read this page in this answer; its text is above.", false)
            }
            do {
                let step = callSteps[call.id]
                let page = try await WebTools.fetch(url) { [weak self] kind in self?.showReading(kind, step: step) }
                addSource(page.url, page.title)
                let text = WebTools.format(page, limit: limits.pageChars)
                fetched[url] = page.title
                if let id = step, let i = messages.indices.last, let n = messages[i].steps.firstIndex(where: { $0.id == id }) {
                    if !page.title.isEmpty { messages[i].steps[n].detail = page.title }
                    // A rendering that gave nothing better leaves the page as downloaded, and says nothing about it.
                    if page.kind == .web { messages[i].steps[n].outcome = nil }
                }
                callOutcomes[call.id] = Self.readOutcome(page)
                return (text, false)
            } catch {
                callOutcomes[call.id] = L("Couldn't be read")
                return ("The page couldn't be read: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription). Try another source.", true)
            }
        default:
            return ("Unknown tool \(call.name).", true)
        }
    }

    /// Waits up to 15 seconds for a tab to load, and says how it went.
    @MainActor
    private static func loaded(_ tab: Tab) async -> String {
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<60 where tab.isLoading {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let state = tab.isLoading ? "is still loading" : "has loaded"
        return "The page opened in a new tab and \(state): \(tab.title) — \(tab.url?.absoluteString ?? ""). Use get_page_content to read it."
    }

    /// What a read step says while a PDF or a page with scripts is read, which takes longer than a plain page.
    @MainActor
    private func showReading(_ kind: WebTools.Page.Kind, step: UUID?) {
        guard let step, let i = messages.indices.last, let n = messages[i].steps.firstIndex(where: { $0.id == step }),
              messages[i].steps[n].running else { return }
        messages[i].steps[n].outcome = kind == .pdf ? L("Reading PDF") : kind == .rendered ? L("Reading with rendering") : nil
    }

    /// What a read step says once done: "PDF · 34 pages", "Read with rendering", or nothing for a plain page.
    static func readOutcome(_ page: WebTools.Page) -> String? {
        switch page.kind {
        case .pdf: page.pageCount == 1 ? L("PDF · 1 page") : String(format: L("PDF · %d pages"), page.pageCount)
        case .rendered: L("Read with rendering")
        case .web: nil
        }
    }

    func addSource(_ url: URL, _ title: String) {
        guard let i = messages.indices.last, !messages[i].sources.contains(where: { $0.url == url }) else { return }
        messages[i].sources.append((url, title.isEmpty ? InputResolver.displayHost(url) : title))
    }

    /// A whole number from tool input, which models send as a number or a string.
    static func number(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return 0
    }
}
