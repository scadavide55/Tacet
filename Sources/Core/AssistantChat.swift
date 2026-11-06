import AppKit
import Observation
import Security
import WebKit

// MARK: - Chat

/// One window's conversation with the assistant.
@Observable
final class AssistantChat {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var images: [NSImage] = []
        /// The same images as JPEG, as they were sent, so saving the chat doesn't compress them again.
        var imageData: [Data] = []
        var pageTitle: String?
        /// The start of the selected text the message is about.
        var quote: String?
        /// Notes about how the answer went, such as "Stopped", shown below it.
        var activity: [String] = []
        /// What the assistant did while answering, in order, with real start and end times.
        var steps: [AssistantStep] = []
        /// Asked with Deep research on.
        var research = false
        /// When the answer started and finished, for the time shown next to the activity line.
        var started: Date?
        var finished: Date?
        /// Links the assistant offered with `open_url`.
        var links: [(url: URL, title: String)] = []
        /// Pages the answer drew on, from web searches and fetches.
        var sources: [(url: URL, title: String)] = []
        var error: String?
        /// Links in the reply to pages the assistant never read or saw, normalised by `AssistantCitations`; shown dimmed.
        var unverified: Set<String> = []
        /// Titles of the tabs the user attached with `@`.
        var tabTitles: [String] = []
        /// Tokens the answer's requests used, summed, when the provider reported them.
        var usage: AIClient.Usage?
    }

    struct ImageAttachment: Identifiable {
        let id = UUID()
        let image: NSImage
        let jpeg: Data
    }

    var messages: [Message] = []
    /// This conversation's place in the assistant's history.
    private(set) var id = UUID()
    var draft = ""
    var images: [ImageAttachment] = []
    private(set) var busy = false
    /// Deep research for the next messages of this chat: many searches, pages read in full, facts checked, and a
    /// structured report with its sources. Needs Web access.
    var deepResearch = false
    /// A page where the user allowed the assistant's clicks, until it changes or a new request starts.
    @ObservationIgnored var allowedPage: (tab: UUID, url: URL?)?

    @ObservationIgnored weak var browser: BrowserState?
    /// A chat in a private window: no memories, and personal instructions only if the user allowed them there. A
    /// chat whose window is gone counts as private, so nothing personal goes out by mistake.
    var isPrivate: Bool { browser?.isPrivate ?? true }
    /// The conversation in the provider's own format, including tool calls and their results.
    @ObservationIgnored var transcript: [[String: Any]] = []
    @ObservationIgnored private var transcriptProvider: AIProvider?
    /// The page already sent in this chat, and the one the user chose not to attach; each is attached at most once.
    var sentPageURL: URL?
    private var dismissedPageURL: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var paragraphBreak = false
    /// Screenshots taken by tools in this round, by tool call id, sent with the tool results.
    @ObservationIgnored var toolImages: [String: Data] = [:]

    /// A quick answer from the command bar: web search only, no page, and not saved until it's opened in the chat.
    @ObservationIgnored let quick: Bool

    init(browser: BrowserState, quick: Bool = false) {
        self.browser = browser
        self.quick = quick
    }

    /// Takes over a quick answer, to go on with it in the full chat.
    @MainActor
    func continueFrom(_ other: AssistantChat) {
        newChat()
        messages = other.messages
        transcript = other.transcript
        transcriptProvider = other.transcriptProvider
        appleSession = other.appleSession
        modelChoice = other.modelChoice
        // The page open now wasn't part of the question.
        dismissedPageURL = browser?.current?.url
        other.newChat()
        saveToHistory()
    }

    /// Text selected on the page that the next message is about.
    var selection: String?

    enum SelectionAction: CaseIterable {
        case explain, translate, summarise, ask

        var title: String {
            switch self {
            case .explain: L("Explain")
            case .translate: L("Translate")
            case .summarise: L("Summarise")
            case .ask: L("Ask About It…")
            }
        }
    }

    static func quote(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }

    /// Explains, translates or summarises text selected on the page, or attaches it so the user can ask about it.
    @MainActor
    func act(on text: String, _ action: SelectionAction) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        selection = trimmed
        // The page goes along only if the user asks for it; the selection is what this is about.
        if let u = browser?.current?.url { dismissedPageURL = u }
        switch action {
        case .explain: draft = L("Explain this.")
        case .summarise: draft = L("Summarise this.")
        case .translate:
            let code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
            let language = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
            draft = String(format: L("Translate this into %@."), language)
        case .ask:
            draft = ""
            return
        }
        send()
    }

    /// The page that would be attached to the next message.
    var pageToAttach: Tab? {
        guard !quick, let tab = browser?.current, let url = tab.url, ["http", "https"].contains(url.scheme ?? ""),
              url != sentPageURL, url != dismissedPageURL else { return nil }
        return tab
    }

    func removePageAttachment() {
        dismissedPageURL = browser?.current?.url
    }

    // MARK: Tabs attached with @

    /// Tabs of this window the user chose with `@`, by id, read and sent with the next message.
    var mentionedTabIDs: [UUID] = []

    /// At most this many tabs go with one message, so a few mentions can't fill the model's context.
    static let maxMentionedTabs = 5

    /// The chosen tabs that are still open, in the order they were chosen.
    var mentionedTabs: [Tab] {
        let tabs = browser?.tabs ?? []
        return mentionedTabIDs.compactMap { id in tabs.first { $0.id == id } }
    }

    /// Tabs that can be mentioned: open ones with a page, not already chosen.
    var mentionableTabs: [Tab] {
        (browser?.tabs ?? []).filter { $0.url != nil && !mentionedTabIDs.contains($0.id) }
    }

    /// Attaches a tab and takes the `@query` that found it out of the draft.
    func mention(_ tab: Tab) {
        mentionedTabIDs = Self.adding(tab.id, to: mentionedTabIDs)
        draft = Self.removingMention(from: draft)
    }

    static func adding(_ id: UUID, to ids: [UUID]) -> [UUID] {
        guard !ids.contains(id), ids.count < maxMentionedTabs else { return ids }
        return ids + [id]
    }

    /// What's typed after an `@` at the end of the draft, when the user is picking a tab; nil otherwise. The `@`
    /// must start a word, so an e-mail address doesn't open the list.
    static func mentionQuery(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = draft[draft.index(after: at)...]
        // A space ends the mention: past it, the user is writing the message again.
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return String(query)
    }

    /// The draft without the `@query` being typed at its end.
    static func removingMention(from draft: String) -> String {
        guard let query = mentionQuery(in: draft) else { return draft }
        return String(draft.dropLast(query.count + 1))
    }

    /// The indices of the tabs whose title or address contains `query`, ignoring case and accents, in tab order.
    static func mentionMatches(_ tabs: [(title: String, url: URL?)], query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(tabs.indices) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return tabs.indices.filter { i in
            tabs[i].title.range(of: q, options: options) != nil
                || (tabs[i].url.map { InputResolver.displayHost($0).range(of: q, options: options) != nil } ?? false)
        }
    }

    /// Characters each mentioned tab may send: together at most two pages' worth, each at most one page.
    static func mentionLimit(tabs: Int, pageChars: Int) -> Int {
        guard tabs > 0 else { return 0 }
        return min(pageChars, max(pageChars * 2 / tabs, 500))
    }

    /// The model this chat uses: picked in the chat, or the default from Settings.
    var model: String {
        get {
            if let chosen = modelChoice, chosen.provider == Settings.shared.aiProvider { return chosen.id }
            return quick ? Settings.shared.aiQuickModelName : Settings.shared.aiModelName
        }
        set { modelChoice = (Settings.shared.aiProvider, newValue) }
    }
    private var modelChoice: (provider: AIProvider, id: String)?

    var canAttachImages: Bool { Settings.shared.aiProvider.supportsImages(model) }

    func addImage(_ image: NSImage) {
        guard let jpeg = Self.jpeg(image) else { return }
        images.append(ImageAttachment(image: image, jpeg: jpeg))
    }

    func newChat() {
        stop()
        id = UUID()
        namedTitle = nil
        modelChoice = nil
        messages = []
        transcript = []
        appleSession = nil
        transcriptProvider = nil
        sentPageURL = nil
        dismissedPageURL = nil
        images = []
        draft = ""
        selection = nil
        mentionedTabIDs = []
        deepResearch = false
        fetched = [:]
    }

    func stop() {
        guard let running = task else { return }
        running.cancel()
        task = nil
        busy = false
        // The chat is kept as it is, marked as stopped.
        if let last = messages.last, last.role == .assistant {
            finishSteps(.stopped)
            noteActivity(L("Stopped"))
        }
        // A tool call left without its result would make the next request fail.
        if let last = transcript.last, last["role"] as? String == "assistant", Self.hasToolCalls(last) { transcript.removeLast() }
    }

    private static func hasToolCalls(_ message: [String: Any]) -> Bool {
        if message["tool_calls"] != nil { return true }
        return (message["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "tool_use" } ?? false
    }

    func send() {
        allowedPage = nil
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = pageToAttach
        // The page already attached isn't read a second time because it was also mentioned.
        let tabs = Array(mentionedTabs.filter { $0 !== page }.prefix(Self.maxMentionedTabs))
        guard !busy, !text.isEmpty || !images.isEmpty || !tabs.isEmpty else { return }
        let s = Settings.shared
        let provider = s.aiProvider
        // A conversation can't move between providers: their formats differ.
        if let p = transcriptProvider, p != provider { transcript = []; appleSession = nil }
        transcriptProvider = provider

        let pageURL = page?.url
        let shownImages = images
        let selected = selection
        draft = ""
        images = []
        selection = nil
        mentionedTabIDs = []
        messages.append(Message(role: .user, text: text, images: shownImages.map(\.image), imageData: shownImages.map(\.jpeg), pageTitle: page?.title,
                                quote: selected.map(Self.quote), tabTitles: tabs.map(\.title)))
        startAnswer(provider: provider) { [weak self] in
            guard let self else { return }
            var pageText: String?
            let local = await LocalModels.shared.load(provider, model: self.model)
            let limit = AssistantLimits.of(provider, contextTokens: local?.tokens ?? self.contextTokens(provider)).pageChars
            if let page { pageText = await Self.pageContent(of: page, limit: limit) }
            if let pageURL { self.sentPageURL = pageURL }
            // Mentioned tabs are read as read_tab reads them (a tab not loaded yet is loaded first), sharing a cap.
            let each = Self.mentionLimit(tabs: tabs.count, pageChars: limit)
            for tab in tabs {
                // Stopped: the question still goes into the conversation, as it does when Stop comes during the page.
                if Task.isCancelled { break }
                let step = self.beginStep(.read, tab.title, url: tab.url)
                await AssistantSources.wake(tab)
                let content = await Self.pageContent(of: tab, limit: each)
                self.endStep(step)
                pageText = [pageText, content].compactMap { $0 }.joined(separator: "\n\n")
            }
            if let selected {
                let block = "<selection>\n\(AssistantLimits.clip(selected, to: limit, what: "selection"))\n</selection>"
                pageText = [pageText, block].compactMap { $0 }.joined(separator: "\n\n")
            }
            // Apple's on-device model has a small context, so what goes with the message is shortened for it.
            if provider == .apple { pageText = pageText.map(AppleModel.shorten) }
            self.transcript.append(Self.userMessage(text: text, page: pageText, images: shownImages.map(\.jpeg), provider: provider))
        }
    }

    /// Adds the reply and runs the request for it. `prepare` runs first, inside the same task, so Stop covers it.
    private func startAnswer(provider: AIProvider, prepare: @escaping @MainActor () async -> Void = {}) {
        var reply = Message(role: .assistant, text: "")
        reply.research = deepResearch && Settings.shared.aiWeb && !quick && provider != .apple
        reply.started = Date()
        messages.append(reply)
        busy = true
        fetched = [:]
        searched = [:]
        roundStart = 0

        task = Task { @MainActor [weak self] in
            await prepare()
            guard let self, !Task.isCancelled else { return }
            await self.run(provider: provider)
            // Stopped: stop() has already updated the state, and a newer message may be running now.
            guard !Task.isCancelled else { self.saveToHistory(); return }
            await self.checkCitations()
            guard !Task.isCancelled else { self.saveToHistory(); return }
            self.finishSteps(.done)
            self.busy = false
            self.task = nil
            self.saveToHistory()
        }
    }

    /// Whether the last reply can be asked for again.
    var canRetry: Bool {
        !busy && messages.last?.role == .assistant && transcriptProvider == Settings.shared.aiProvider
            && transcriptProvider != .apple && transcript.contains(where: Self.isRequest)
    }

    /// Asks for the last reply again: it's replaced, and the question is sent as it was.
    func retry() {
        guard canRetry, let provider = transcriptProvider, let request = transcript.lastIndex(where: Self.isRequest) else { return }
        allowedPage = nil
        transcript.removeSubrange((request + 1)...)
        messages.removeLast()
        startAnswer(provider: provider)
    }

    // MARK: History

    /// Saves this chat, except in private windows.
    func saveToHistory() {
        showPendingText()
        guard !quick, let browser, !browser.isPrivate, let first = messages.first(where: { $0.role == .user }),
              let provider = transcriptProvider else { return }
        let saved = messages.map { m in
            AssistantHistory.SavedMessage(user: m.role == .user, text: m.text,
                                          images: m.imageData.count == m.images.count ? m.imageData : m.images.compactMap(Self.jpeg),
                                          pageTitle: m.pageTitle, quote: m.quote, activity: m.activity,
                                          links: m.links.map { .init(url: $0.url, title: $0.title) },
                                          sources: m.sources.map { .init(url: $0.url, title: $0.title) }, error: m.error,
                                          steps: m.steps, research: m.research, started: m.started, finished: m.finished,
                                          unverified: m.unverified.isEmpty ? nil : m.unverified.sorted(),
                                          tabTitles: m.tabTitles.isEmpty ? nil : m.tabTitles, usage: m.usage)
        }
        let title = namedTitle ?? AssistantHistory.title(first.text.isEmpty ? (first.pageTitle ?? first.tabTitles.first ?? L("Image")) : first.text)
        AssistantHistory.shared.save(.init(summary: .init(id: id, title: title, date: Date(), provider: provider.rawValue),
                                           messages: saved, transcript: transcript, model: model))
        nameChat(first: first, provider: provider)
    }

    /// The title the model for small jobs gave this chat, once it answers.
    private var namedTitle: String?
    /// The chat a title was asked for, so it's asked once per chat even if the request fails.
    private var namingID: UUID?

    /// Asks the model for small jobs for a short title, once the first answer is in. Only when the user chose such a
    /// model, so an extra request is never made unasked; without one the title is the start of the first question.
    private func nameChat(first: Message, provider: AIProvider) {
        let s = Settings.shared
        guard namedTitle == nil, namingID != id, s.aiHasSmallModel, provider == s.aiProvider, provider != .apple,
              messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) else { return }
        let chatID = id
        namingID = chatID
        let question = [first.pageTitle.map { "Page: \($0)" }, first.text.isEmpty ? nil : String(first.text.prefix(1_500))]
            .compactMap { $0 }.joined(separator: "\n")
        Task { @MainActor [weak self] in
            let reply = try? await AIClient.smallJob(system: Self.titleSystem, prompt: question, maxTokens: 40)
            guard let self, self.id == chatID, let title = reply.flatMap(Self.cleanTitle) else { return }
            self.namedTitle = title
            self.saveToHistory()
        }
    }

    static let titleSystem = "Write a title of at most six words for a chat that starts with the user's message below. Use the language of the message. Reply with the title only: no quotes, no full stop at the end."

    /// A title as the model wrote it, without quotes, a final full stop or a second line; nil when nothing is left.
    static func cleanTitle(_ raw: String) -> String? {
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var t = line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’«»*#").union(.whitespaces))
        if t.hasSuffix(".") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return AssistantHistory.title(t)
    }

    /// Reopens a saved chat in place of this one.
    func open(_ summary: AssistantHistory.Summary) {
        guard let saved = AssistantHistory.shared.load(summary) else { return }
        newChat()
        id = summary.id
        // A reopened chat keeps the title it has.
        namedTitle = summary.title
        messages = saved.messages.map { m in
            // Chats saved before 1.8 kept each step as a line of text; they become plain steps.
            let steps = m.steps ?? m.activity.filter { $0 != L("Stopped") }.map {
                AssistantStep(kind: .tool, detail: $0, started: Date(timeIntervalSince1970: 0), ended: Date(timeIntervalSince1970: 0), status: .done)
            }
            let notes = m.steps == nil ? m.activity.filter { $0 == L("Stopped") } : m.activity
            return Message(role: m.user ? .user : .assistant, text: m.text, images: m.images.compactMap(NSImage.init(data:)), imageData: m.images,
                           pageTitle: m.pageTitle, quote: m.quote, activity: notes, steps: steps, research: m.research ?? false,
                           started: m.started, finished: m.finished, links: m.links.map { ($0.url, $0.title) },
                           sources: m.sources.map { ($0.url, $0.title) }, error: m.error, unverified: Set(m.unverified ?? []),
                           tabTitles: m.tabTitles ?? [], usage: m.usage)
        }
        transcript = saved.transcript
        transcriptProvider = AIProvider(rawValue: summary.provider)
        if let p = transcriptProvider, let model = saved.model { modelChoice = (p, model) }
    }

    // MARK: Request loop

    @MainActor
    private func run(provider: AIProvider) async {
        if provider == .apple { await runApple(); return }
        let s = Settings.shared
        // Off the main thread: if macOS asks for Keychain access, the window must not freeze while it waits.
        let key = await Task.detached(priority: .userInitiated) { AIKeys.get(provider) }.value
        if Task.isCancelled { return }
        if provider.needsKey && key == nil {
            fail(L("Add your API key in Settings › AI."))
            return
        }
        let model = self.model
        guard !model.isEmpty else { fail(L("Choose a model in Settings › AI.")); return }
        let base = provider.baseURL
        var useTools = true
        // Web access turned off in Settings › AI holds for quick answers too.
        let web = s.aiWeb
        let control = !quick && s.aiControl
        let research = messages.last?.research ?? false
        var retries = 0
        // A model on this Mac: what its server runs it with decides the instructions and how much goes with them.
        let local = await LocalModels.shared.load(provider, model: model)
        let tokens = local?.tokens ?? contextTokens(provider)
        let compact = LocalModels.isCompact(provider, tokens: tokens)
        let numCtx = provider == .ollama ? (local?.tokens ?? LocalModels.ollamaDefault) : nil
        let privateWindow = isPrivate
        let overhead = AssistantPrompt.overhead(provider: provider, model: model, web: web, control: control, quick: quick, research: research,
                                                compact: compact, privateWindow: privateWindow)
        limits = AssistantLimits.of(provider, contextTokens: tokens, overhead: overhead)

        // A deep research with any provider but Anthropic is run step by step by the code (DeepResearch.swift);
        // Anthropic's models keep their research on Anthropic's servers, below.
        if research && web && provider != .anthropic {
            await runResearch(provider: provider, base: base, key: key, model: model, numCtx: numCtx)
            return
        }

        // The model may call tools several times before it answers; each round is one request.
        for _ in 0..<(research ? Self.maxResearchRounds : Self.maxRounds) {
            if Task.isCancelled { return }
            beginRound()
            let result: AIClient.Result
            do {
                result = try await AIClient.stream(provider: provider, base: base, key: key, model: model,
                                                   transcript: Self.fitted(transcript, budget: limits.budget),
                                                   tools: useTools, web: web, control: control, quick: quick, research: research,
                                                   compact: compact, numCtx: numCtx, privateWindow: privateWindow,
                                                   onText: { [weak self] delta in self?.appendToReply(delta) },
                                                   onServerTool: { [weak self] event in self?.serverTool(event) })
                showPendingText()
            } catch AIClient.Failure.toolsUnsupported where useTools {
                useTools = false
                continue
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                // A busy or briefly unreachable service gets two more tries before the error is shown, unless the
                // reply had already started: then the answer on screen would be repeated.
                if retries < 2, AIClient.isTransient(error), !(messages.last.map { !$0.text.isEmpty } ?? false) {
                    retries += 1
                    endThinking()
                    let note = beginStep(.tool, L("The service is busy. Trying again…"))
                    try? await Task.sleep(for: .seconds(Double(retries * 2)))
                    endStep(note)
                    if Task.isCancelled { return }
                    continue
                }
                fail(AIModels.explain(error, provider: provider))
                return
            }
            endThinking()
            transcript.append(result.assistantMessage)
            if let usage = result.usage { addUsage(usage) }
            for source in result.sources { addSource(source.url, source.title) }
            // Anthropic paused a long run of web searches; sending the turn back resumes it.
            if result.stopReason == "pause_turn" { continue }
            if result.stopReason == "refusal" {
                fail(L("The model declined to answer this request."))
                return
            }
            guard !result.toolCalls.isEmpty else {
                if result.stopReason == "max_tokens" || result.stopReason == "length" {
                    noteActivity(L("The answer was cut off because it reached the length limit."))
                }
                return
            }
            toolImages = [:]
            let calls = result.toolCalls
            var outputs: [(call: AIClient.ToolCall, output: String, isError: Bool)] = []
            // Searches and page reads don't touch the window, so a round of them runs at once instead of in turn.
            if calls.count > 1, calls.allSatisfy({ Self.parallelTools.contains($0.name) }) {
                let results = await withTaskGroup(of: (Int, String, Bool).self) { group in
                    for (n, call) in calls.enumerated() {
                        group.addTask { @MainActor [weak self] in
                            guard let self else { return (n, "The chat was closed.", true) }
                            let (output, isError) = await self.perform(call)
                            return (n, output, isError)
                        }
                    }
                    var all: [(Int, String, Bool)] = []
                    for await r in group { all.append(r) }
                    return all.sorted { $0.0 < $1.0 }
                }
                if Task.isCancelled { return }
                outputs = results.map { (calls[$0.0], $0.1, $0.2) }
            } else {
                for call in calls {
                    // Stop means stop: nothing more runs once it's pressed, even calls the model already asked for.
                    if Task.isCancelled { return }
                    let (output, isError) = await perform(call)
                    outputs.append((call, output, isError))
                }
            }
            transcript.append(contentsOf: AIClient.toolResults(outputs, provider: provider, images: toolImages))
            toolImages = [:]
        }
        if !Task.isCancelled {
            fail(String(format: L("Tacet Assistant stopped after %d steps without finishing. Ask it to continue, or split the task."),
                        research ? Self.maxResearchRounds : Self.maxRounds))
        }
    }

    /// Rounds of tool calls in one answer. Browser use takes one per click, so it needs room, but not forever.
    static let maxRounds = 20
    /// A deep research reads many pages, so it gets more rounds.
    static let maxResearchRounds = 40
    /// Tools that can run at the same time as each other.
    static let parallelTools: Set<String> = ["web_search", "web_fetch", "research_stage"]

    // MARK: Steps

    /// The step each running tool call shows, by call id.
    @ObservationIgnored var callSteps: [String: UUID] = [:]
    /// What each tool call came to, set by the tool, shown on its step.
    @ObservationIgnored var callOutcomes: [String: String] = [:]
    /// Where this round's text starts in the reply, as UTF-8 offset; text before a tool is moved into the steps.
    @ObservationIgnored private var roundStart = 0
    /// How much this answer's requests may carry, and how much of one page goes into a tool's result.
    @ObservationIgnored var limits = AssistantLimits.of(.anthropic)
    /// Pages read in this answer, so the same address isn't fetched twice, and searches already made.
    @ObservationIgnored var fetched: [URL: String] = [:]
    @ObservationIgnored var searched: [String: String] = [:]

    private func beginRound() {
        showPendingText()
        roundStart = messages.last?.text.utf8.count ?? 0
        startThinking()
    }

    /// Runs a tool call with its step: the step ends when the tool does, as done or failed.
    private func perform(_ call: AIClient.ToolCall) async -> (String, Bool) {
        let (output, isError) = await runTool(call)
        if let id = callSteps.removeValue(forKey: call.id) {
            endStep(id, isError ? .failed : .done, outcome: callOutcomes.removeValue(forKey: call.id))
        }
        callOutcomes[call.id] = nil
        startThinkingIfIdle()
        return (output, isError)
    }

    @discardableResult
    func beginStep(_ kind: AssistantStep.Kind, _ detail: String, url: URL? = nil, stage: AssistantStep.Stage? = nil,
                           call: String? = nil) -> UUID? {
        showPendingText()
        // A tool that ends after Stop, or after a newer message started, adds nothing.
        guard busy, !Task.isCancelled, let i = messages.indices.last, messages[i].role == .assistant else { return nil }
        if kind != .thinking { endThinking() }
        if [.search, .read, .browse, .tool, .stage].contains(kind) { moveInterimText() }
        let step = AssistantStep(kind: kind, detail: detail, url: url, stage: stage, started: Date())
        messages[i].steps.append(step)
        if let call { callSteps[call] = step.id }
        paragraphBreak = true
        return step.id
    }

    func endStep(_ id: UUID?, _ status: AssistantStep.Status = .done, outcome: String? = nil) {
        guard let id, let i = messages.indices.last, let n = messages[i].steps.firstIndex(where: { $0.id == id }) else { return }
        messages[i].steps[n].finish(status, outcome: outcome)
    }

    /// Ends every running step, when the answer is done or stopped. A moment of thinking isn't kept.
    private func finishSteps(_ status: AssistantStep.Status) {
        guard let i = messages.indices.last, messages[i].role == .assistant else { return }
        let now = Date()
        for n in messages[i].steps.indices {
            let kind = messages[i].steps[n].kind
            messages[i].steps[n].finish(kind == .stage || kind == .thinking ? .done : status, at: now)
        }
        messages[i].steps.removeAll { $0.kind == .thinking && $0.duration(at: now) < AssistantActivity.shortThought }
        if messages[i].finished == nil, status != .failed { messages[i].finished = now }
        callSteps = [:]
        callOutcomes = [:]
    }

    /// Thinking runs from when a request goes out until text or a tool comes back.
    private func startThinking() {
        guard let last = messages.last, last.role == .assistant, !last.steps.contains(where: { $0.kind == .thinking && $0.running }) else { return }
        beginStep(.thinking, "")
    }

    /// After the last of a round's tools, the model works through what they returned.
    private func startThinkingIfIdle() {
        guard let last = messages.last, !last.steps.contains(where: { $0.running && $0.kind != .stage }) else { return }
        startThinking()
    }

    private func endThinking() {
        guard let i = messages.indices.last else { return }
        for n in messages[i].steps.indices where messages[i].steps[n].kind == .thinking { messages[i].steps[n].finish() }
    }

    /// Text the model wrote before using a tool, such as "Let me look that up", goes into the steps, so the reply
    /// holds only the answer. Longer text is more likely part of the answer, so it stays.
    private func moveInterimText() {
        guard let i = messages.indices.last else { return }
        let text = messages[i].text
        guard roundStart <= text.utf8.count else { roundStart = text.utf8.count; return }
        let start = text.utf8.index(text.startIndex, offsetBy: roundStart)
        let interim = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !interim.isEmpty, interim.count <= 600 {
            messages[i].text = String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            messages[i].steps.append(AssistantStep(kind: .note, detail: interim, started: Date(), ended: Date(), status: .done))
        }
        roundStart = messages[i].text.utf8.count
    }

    /// Web searches and fetches that Anthropic runs on its side, as they start and as their results come back.
    private func serverTool(_ event: AIClient.ServerToolEvent) {
        switch event {
        case .started(let id, let name, let input):
            if name == "web_search", let q = input["query"] as? String {
                beginStep(.search, q, call: id)
            } else if name == "web_fetch", let u = (input["url"] as? String).flatMap(URL.init(string:)) {
                beginStep(.read, InputResolver.displayHost(u), url: u, call: id)
            }
        case .finished(let id, let results, let failed):
            guard let step = callSteps.removeValue(forKey: id) else { return }
            let outcome = failed ? L("Couldn't be read") : results.map { $0 == 1 ? L("1 result") : String(format: L("%d results"), $0) }
            endStep(step, failed ? .failed : .done, outcome: outcome)
            startThinkingIfIdle()
        }
    }

    // MARK: Apple's on-device model

    /// The on-device session, kept for the whole chat; typed loosely since it exists only on macOS 26 and later.
    @ObservationIgnored private var appleSession: AnyObject?

    @MainActor
    private func runApple() async {
        guard #available(macOS 26.0, *) else { fail(L("The Apple model needs macOS 26 or later.")); return }
        if let reason = AppleModel.unavailableReason { fail(reason); return }
        let s = Settings.shared
        let privateWindow = isPrivate
        let tools = quick ? AssistantPrompt.tools.filter { $0.name == "tacet_guide" } + (s.aiWeb ? AssistantPrompt.webTools : [])
            : AppleModel.tools(web: s.aiWeb, control: s.aiControl, memory: AssistantPersonal.memoryOn(privateWindow: privateWindow))
        let key = tools.map(\.name).joined(separator: ",")
        let session: AppleChatSession
        // The session's tools are fixed when it's made, so turning Web access or Browser use on or off starts a new one.
        // Its instructions, with the personal ones and the memories, are fixed too: a memory saved in this chat is
        // already in its history, and the session isn't thrown away for it.
        if let existing = appleSession as? AppleChatSession, existing.toolKey == key {
            session = existing
        } else {
            let instructions = AppleModel.instructions(control: !quick && s.aiControl, privateWindow: privateWindow, remember: !quick)
            session = AppleChatSession(tools: tools, instructions: instructions) { [weak self] name, json in
                await self?.runToolForApple(name, json) ?? "The chat was closed."
            }
            appleSession = session
        }
        // The last user message, with its page or selection, is the prompt; the session keeps the earlier turns.
        guard let last = transcript.last, let prompt = last["content"] as? String else { return }
        var reply = ""
        do {
            try await session.respond(to: prompt) { [weak self] delta in
                reply += delta
                self?.appendToReply(delta)
            }
            showPendingText()
            transcript.append(["role": "assistant", "content": reply])
        } catch is CancellationError {
            appleSession = nil
        } catch {
            if Task.isCancelled { return }
            appleSession = nil
            fail(AppleChatSession.message(for: error) ?? error.localizedDescription)
        }
    }

    /// Runs a tool for the on-device model. Results are kept in the transcript too, so open_page and web_fetch
    /// know which addresses came up, and shortened to fit the model.
    @MainActor
    private func runToolForApple(_ name: String, _ json: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let (output, _) = await perform(AIClient.ToolCall(id: UUID().uuidString, name: name, arguments: args ?? [:]))
        transcript.append(["role": "tool", "content": output])
        return AppleModel.shorten(output)
    }

    /// Streamed text waiting to be shown: it's shown about 20 times a second rather than on every word, so the reply
    /// isn't laid out and scrolled again for each one.
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var showScheduled = false

    func appendToReply(_ delta: String) {
        if pendingText.isEmpty { endThinking() }
        pendingText += delta
        guard !showScheduled else { return }
        showScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.showPendingText() }
    }

    func showPendingText() {
        showScheduled = false
        guard !pendingText.isEmpty, let i = messages.indices.last else { pendingText = ""; return }
        let delta = pendingText
        pendingText = ""
        // Text written after a tool starts a new paragraph instead of running on from the text before it.
        if paragraphBreak, !messages[i].text.isEmpty, !messages[i].text.hasSuffix("\n"), !delta.hasPrefix("\n") {
            messages[i].text += "\n\n"
        }
        paragraphBreak = false
        messages[i].text += delta
    }

    private func noteActivity(_ note: String) {
        showPendingText()
        guard let i = messages.indices.last else { return }
        messages[i].activity.append(note)
        paragraphBreak = true
    }

    /// Adds one request's tokens to the reply's total: an answer that uses tools makes several requests.
    private func addUsage(_ usage: AIClient.Usage) {
        guard let i = messages.indices.last, messages[i].role == .assistant else { return }
        messages[i].usage = (messages[i].usage ?? AIClient.Usage()) + usage
    }

    private func fail(_ message: String) {
        showPendingText()
        guard let i = messages.indices.last else { return }
        messages[i].error = message
    }

    // MARK: Building messages

    /// The most of an open page that's sent, for models that take a lot.
    static let pageLimit = 120_000

    /// The current page as plain text, wrapped so the model can tell it apart from the user's words, cut to `limit`
    /// characters (at most `pageLimit`).
    @MainActor
    static func pageContent(of tab: Tab, limit: Int = pageLimit) async -> String {
        let url = tab.url?.absoluteString ?? ""
        var text = ""
        if let wv = tab.webView {
            let js = "(document.body ? document.body.innerText : '')"
            text = ((try? await wv.evaluateJavaScript(js, in: nil, contentWorld: .defaultClient)) as? String) ?? ""
        }
        text = text.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        text = AssistantLimits.clip(text, to: min(limit, pageLimit))
        let title = tab.title.replacingOccurrences(of: "\"", with: "'")
        return "<page url=\"\(url)\" title=\"\(title)\">\n\(text)\n</page>"
    }

    static func userMessage(text: String, page: String?, images: [Data], provider: AIProvider) -> [String: Any] {
        let body = [page, text.isEmpty ? nil : text].compactMap { $0 }.joined(separator: "\n\n")
        if images.isEmpty { return ["role": "user", "content": body] }
        var content: [[String: Any]] = []
        for jpeg in images {
            let b64 = jpeg.base64EncodedString()
            if provider == .anthropic {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]])
            } else {
                content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + b64]])
            }
        }
        content.append(["type": "text", "text": body.isEmpty ? "(image)" : body])
        return ["role": "user", "content": content]
    }

    /// Scales an image to at most 1568 px on its long side, the size models read best, as JPEG.
    static func jpeg(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1568 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
