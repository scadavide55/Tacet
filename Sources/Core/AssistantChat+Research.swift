import Foundation

// MARK: - Deep research run by the code

extension AssistantChat {
    /// Runs a deep research with `DeepResearch`, showing each step in the timeline as it happens, and keeps its notes
    /// in the conversation so the next questions can use them.
    @MainActor
    func runResearch(provider: AIProvider, base: String, key: String?, model: String, numCtx: Int?) async {
        guard let i = messages.indices.last, let question = messages[..<i].last(where: { $0.role == .user })?.text else { return }
        let depth = Settings.shared.aiResearchDepth
        let pageChars = limits.pageChars
        var stageStep: UUID?
        var searchSteps: [String: UUID] = [:]
        var readSteps: [URL: UUID] = [:]
        var pages: [URL: String] = [:]

        let backend = DeepResearch.Backend(
            search: { query in
                let answer = try await WebTools.search(query, engines: await SearchEngines.fromSettings())
                return (answer.results, answer.engine)
            },
            read: { url, limit in
                let page = try await WebTools.fetch(url)
                let text = page.kind == .pdf ? WebTools.pdfText(page, limit: limit) : String(page.text.prefix(limit))
                await MainActor.run { pages[url] = text }
                return (page.title, text)
            },
            ask: { system, prompt in
                try await AIClient.smallJob(system: system, prompt: prompt, maxTokens: 2_000)
            },
            write: { system, prompt, onText in
                let result = try await AIClient.stream(provider: provider, base: base, key: key, model: model,
                                                       transcript: [["role": "user", "content": prompt]],
                                                       tools: false, web: false, control: false, research: true,
                                                       numCtx: numCtx, systemOverride: system,
                                                       onText: onText, onServerTool: { _ in })
                return (result.assistantMessage["content"] as? String) ?? ""
            })

        let research = DeepResearch(question: question, depth: depth, pageChars: pageChars, backend: backend) { [weak self] event in
            guard let self else { return }
            switch event {
            case .stage(let stage, let detail):
                self.endStep(stageStep)
                stageStep = self.beginStep(.stage, detail, stage: stage)
            case .progress(_, let text):
                self.setStepDetail(stageStep, text)
            case .searching(let query):
                searchSteps[query] = self.beginStep(.search, query)
            case .searched(let query, let n, let engine, let failed):
                let count = n == 1 ? L("1 result") : String(format: L("%d results"), n)
                self.endStep(searchSteps[query], failed ? .failed : .done,
                             outcome: failed ? L("The search failed") : count + (engine.isEmpty ? "" : " · " + engine))
            case .reading(let url):
                readSteps[url] = self.beginStep(.read, InputResolver.displayHost(url), url: url)
            case .read(let url, let failed, let outcome):
                self.endStep(readSteps[url], failed ? .failed : .done, outcome: failed ? L("Couldn't be read") : outcome)
            }
        }
        let context = transcript.count > 1 ? WebTools.conversationText(Array(transcript.dropLast())) : nil
        let report = await research.run(context: context?.isEmpty == false ? context : nil) { [weak self] delta in
            self?.appendToReply(delta)
        }
        showPendingText()

        // What was read counts as read for the link check, and as the answer's sources.
        for (url, text) in pages { fetched[url] = text }
        guard let n = messages.indices.last, messages[n].role == .assistant else { return }
        for s in report.sources where !messages[n].sources.contains(where: { $0.url == s.url }) { messages[n].sources.append(s) }
        if report.stopped { messages[n].text = report.text }
        endStep(stageStep)

        // The report and its notes stay in the conversation: a question after it can build on them without
        // searching again. The notes are in a tag the model reads as its own earlier findings.
        let notes = report.notes.map { "[\($0.id)] \($0.fact) — “\($0.quote)” (\($0.url.absoluteString))" }.joined(separator: "\n")
        var content = messages[n].text
        if !notes.isEmpty { content += "\n\n<research_notes>\n\(notes)\n</research_notes>" }
        transcript.append(["role": "assistant", "content": content])
    }

    /// A step's text, changed while it runs: "Reading · 6 of 10 pages".
    func setStepDetail(_ id: UUID?, _ text: String) {
        guard let id, let i = messages.indices.last, let n = messages[i].steps.firstIndex(where: { $0.id == id }) else { return }
        messages[i].steps[n].detail = text
    }
}
