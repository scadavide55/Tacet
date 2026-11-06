import Foundation

// MARK: - Network

/// Streams one reply from Anthropic's Messages API or an OpenAI-compatible Chat Completions API.
enum AIClient {
    struct ToolCall {
        let id: String
        let name: String
        /// Nil when the model's input wasn't valid JSON.
        let arguments: [String: Any]?
    }

    /// Anthropic's own tools, which run on its servers during a reply: when one starts, and when its result arrives
    /// (how many results a search found, or that it failed).
    enum ServerToolEvent {
        case started(id: String, name: String, input: [String: Any])
        case finished(id: String, results: Int?, failed: Bool)
    }

    /// Errors worth trying again after a moment: a busy or overloaded service, or a dropped connection.
    static func isTransient(_ error: Error) -> Bool {
        if case Failure.http(let code, _) = error { return code == 429 || code == 500 || code == 502 || code == 503 || code == 504 || code == 529 }
        if let e = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(e.code)
        }
        return false
    }

    struct Result {
        /// The assistant turn exactly as the provider expects it back on the next request.
        let assistantMessage: [String: Any]
        let toolCalls: [ToolCall]
        let stopReason: String?
        /// Pages cited in the answer.
        var sources: [(url: URL, title: String)] = []
        /// Tokens this request used, when the provider said so.
        var usage: Usage?
    }

    /// Tokens one request (or, summed, one answer) used, as the provider reported them. Shown under the reply so
    /// people who pay per token can see what an answer took; no price is shown, since prices change and differ by
    /// account, and a wrong cost is worse than none.
    struct Usage: Codable, Equatable {
        /// Tokens the model read, those it found in the provider's cache included.
        var input = 0
        var output = 0
        /// Of `input`, those read from the cache, which cost less and arrive sooner.
        var cached = 0
        /// Of `input`, those written to the cache for the next request (Anthropic only).
        var cacheWrite = 0

        static func + (a: Usage, b: Usage) -> Usage {
            Usage(input: a.input + b.input, output: a.output + b.output, cached: a.cached + b.cached,
                  cacheWrite: a.cacheWrite + b.cacheWrite)
        }

        /// Anthropic counts cache reads and writes apart from `input_tokens`; they are added in, so "in" means the
        /// same with every provider.
        static func anthropic(_ raw: [String: Any]) -> Usage? {
            func n(_ k: String) -> Int { (raw[k] as? NSNumber)?.intValue ?? 0 }
            guard raw["input_tokens"] is NSNumber || raw["output_tokens"] is NSNumber else { return nil }
            let read = n("cache_read_input_tokens"), write = n("cache_creation_input_tokens")
            return Usage(input: n("input_tokens") + read + write, output: n("output_tokens"), cached: read, cacheWrite: write)
        }

        /// OpenAI's `prompt_tokens` already include the cached ones. DeepSeek reports them as `prompt_cache_hit_tokens`.
        static func openAI(_ raw: [String: Any]) -> Usage? {
            guard let prompt = raw["prompt_tokens"] as? NSNumber else { return nil }
            let details = raw["prompt_tokens_details"] as? [String: Any]
            let cached = (details?["cached_tokens"] as? NSNumber) ?? (raw["prompt_cache_hit_tokens"] as? NSNumber)
            return Usage(input: prompt.intValue, output: (raw["completion_tokens"] as? NSNumber)?.intValue ?? 0,
                         cached: cached?.intValue ?? 0)
        }

        /// "1,234 in · 567 out · 900 cached", in the user's number format.
        func summary(locale: Locale = .current) -> String {
            func f(_ n: Int) -> String { n.formatted(.number.locale(locale)) }
            var parts = [String(format: L("%@ in"), f(input)), String(format: L("%@ out"), f(output))]
            if cached > 0 { parts.append(String(format: L("%@ cached"), f(cached))) }
            return parts.joined(separator: " · ")
        }
    }

    /// Providers known to accept `stream_options`, which asks for the token counts at the end of a stream. Other
    /// OpenAI-compatible servers may reject a field they don't know, so they aren't sent it.
    static func reportsStreamUsage(_ provider: AIProvider) -> Bool {
        [.openAI, .openRouter, .deepSeek].contains(provider)
    }

    enum Failure: LocalizedError {
        case http(Int, String)
        case toolsUnsupported
        case badURL

        var errorDescription: String? {
            switch self {
            case .http(401, _), .http(403, _): L("The API key was refused. Check it in Settings › AI.")
            case .http(429, _): L("Too many requests, or the account has no credit left. Try again in a moment.")
            case .http(let code, let message): message.isEmpty ? String(format: L("The service answered with error %d."), code) : message
            case .toolsUnsupported: nil
            case .badURL: L("The server address isn't valid. Check it in Settings › AI.")
            }
        }
    }

    static let anthropicVersion = "2026-10-21"
    /// Opens the user message that carries screenshots after OpenAI-style tool results, so it isn't taken for a request.
    static let screenshotNote = "The screenshot from take_screenshot:"
    /// Models that accept server-side fallbacks, which re-run a declined request on another model.
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 900
        return URLSession(configuration: c)
    }()

    private static var warmed = Date.distantPast

    /// Opens the connection to the provider ahead of a question, so the answer doesn't wait for it.
    @MainActor
    static func warm() {
        let s = Settings.shared
        let p = s.aiProvider
        guard s.aiEnabled, p != .apple, !p.isLocal, Date().timeIntervalSince(warmed) > 60,
              let url = URL(string: p.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))) else { return }
        warmed = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        session.dataTask(with: request).resume()
    }

    /// `privateWindow` is set for chats in private windows, whose prompt leaves out the user's memories and, unless
    /// they allowed it, their personal instructions.
    @MainActor
    static func stream(provider: AIProvider, base: String, key: String?, model: String, transcript: [[String: Any]],
                       tools: Bool, web: Bool, control: Bool, quick: Bool = false, research: Bool = false,
                       compact: Bool = false, numCtx: Int? = nil, privateWindow: Bool = false,
                       systemOverride: String? = nil,
                       onText: @escaping (String) -> Void,
                       onServerTool: @escaping (ServerToolEvent) -> Void) async throws -> Result {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Ollama gets its own API, the only one that takes the context the model should run with.
        let native = provider == .ollama && numCtx != nil
        let path = provider == .anthropic ? "/messages" : native ? "/api/chat" : "/chat/completions"
        guard let url = URL(string: (native ? LocalModels.host(trimmed) : trimmed) + path), ["http", "https"].contains(url.scheme ?? "") else { throw Failure.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let vision = provider.supportsImages(model)
        var body: [String: Any] = ["model": model, "stream": true]
        if provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = quick ? 8000 : 64000
            body["system"] = AssistantPrompt.system(web: web && tools, control: control && tools, vision: vision && tools, quick: quick,
                                                    research: research && web && tools, privateWindow: privateWindow)
            body["messages"] = transcript
            // The conversation so far is cached, so each new message starts answering sooner.
            body["cache_control"] = ["type": "ephemeral"]
            // Less thinking before a quick answer.
            if quick, AIProvider.takesEffort(model) { body["output_config"] = ["effort": "low"] }
            // A deep research thinks as much as it needs between searches, and plans and checks with more care.
            if research, AIProvider.takesEffort(model) {
                body["output_config"] = ["effort": "high"]
                body["thinking"] = ["type": "adaptive"]
            }
            if tools {
                body["tools"] = AssistantPrompt.clientTools(provider: provider, web: web, control: control, vision: vision, quick: quick,
                                                            research: research, privateWindow: privateWindow).map {
                    ["name": $0.name, "description": $0.description, "input_schema": AssistantPrompt.schema($0), "eager_input_streaming": true] as [String: Any]
                } + (web ? AssistantPrompt.anthropicWebTools(model: model, quick: quick, research: research) : [])
            }
            if fallbackModels.contains(model) {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        } else {
            if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            if provider == .openRouter {
                // OpenRouter's optional app attribution.
                request.setValue("https://scadavide55.github.io/Tacet/", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("Tacet", forHTTPHeaderField: "X-Title")
            }
            let system = compact && !quick ? AssistantPrompt.compactSystem(web: web && tools, control: control && tools, privateWindow: privateWindow)
                : AssistantPrompt.system(web: web && tools, control: control && tools, vision: vision && tools, quick: quick,
                                         research: research && web && tools, privateWindow: privateWindow)
            body["messages"] = [["role": "system", "content": systemOverride ?? system]] + transcript
            if reportsStreamUsage(provider) { body["stream_options"] = ["include_usage": true] }
            // OpenAI's reasoning models think less before a quick answer, and more for a deep research.
            if provider == .openAI, AIProvider.takesReasoningEffort(model), quick || research { body["reasoning_effort"] = research ? "high" : "low" }
            if tools {
                let list = AssistantPrompt.clientTools(provider: provider, web: web, control: control, vision: vision, quick: quick,
                                                       research: research, privateWindow: privateWindow)
                body["tools"] = (compact && !quick ? AssistantPrompt.compactTools(list) : list).map {
                    ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": AssistantPrompt.schema($0)]] as [String: Any]
                }
            }
            if native, let numCtx {
                body["messages"] = ollamaMessages(body["messages"] as? [[String: Any]] ?? [])
                body["options"] = ["num_ctx": numCtx]
                request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
            let message = errorMessage(data)
            if status == 400, tools, message.lowercased().contains("tool") { throw Failure.toolsUnsupported }
            throw Failure.http(status, message)
        }
        if native { return try await readOllama(lines(bytes), onText: onText) }
        return provider == .anthropic ? try await readAnthropic(bytes, onText: onText, onServerTool: onServerTool)
            : try await readOpenAI(bytes, onText: onText)
    }

    private static func errorMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let e = json["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = json["error"] as? String { return m }
        return (json["message"] as? String) ?? ""
    }

    private static func events(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let t = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                            continuation.yield(json)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in t.cancel() }
        }
    }

    // MARK: Anthropic

    @MainActor
    private static func readAnthropic(_ bytes: URLSession.AsyncBytes, onText: (String) -> Void,
                                      onServerTool: (ServerToolEvent) -> Void) async throws -> Result {
        // Content blocks are kept whole (thinking signatures included) because they must be sent back unchanged.
        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var stopReason: String?
        // Counts arrive at the start and again, as running totals, at the end; later values replace earlier ones.
        var usage: [String: Any] = [:]
        for try await e in events(bytes) {
            try Task.checkCancellation()
            switch e["type"] as? String {
            case "message_start":
                if let u = (e["message"] as? [String: Any])?["usage"] as? [String: Any] { usage.merge(u.filter { $0.value is NSNumber }) { $1 } }
            case "content_block_start":
                guard let i = e["index"] as? Int, var block = e["content_block"] as? [String: Any] else { continue }
                if ["tool_use", "server_tool_use"].contains(block["type"] as? String) { block["input"] = [String: Any]() }
                if let type = block["type"] as? String, type.hasSuffix("_tool_result"), let id = block["tool_use_id"] as? String {
                    onServerTool(.finished(id: id, results: (block["content"] as? [Any])?.count, failed: Self.serverToolFailed(block)))
                }
                blocks[i] = block
            case "content_block_delta":
                guard let i = e["index"] as? Int, let d = e["delta"] as? [String: Any], var block = blocks[i] else { continue }
                switch d["type"] as? String {
                case "text_delta":
                    let t = d["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + t
                    onText(t)
                case "thinking_delta": block["thinking"] = (block["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
                case "signature_delta": block["signature"] = d["signature"]
                case "input_json_delta": partialJSON[i, default: ""] += d["partial_json"] as? String ?? ""
                case "citations_delta":
                    if let c = d["citation"] { block["citations"] = (block["citations"] as? [Any] ?? []) + [c] }
                default: break
                }
                blocks[i] = block
            case "content_block_stop":
                guard let i = e["index"] as? Int, var block = blocks[i] else { continue }
                if let json = partialJSON[i] {
                    block["input"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [String: Any]()
                    block["lumenInvalid"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) == nil && !json.isEmpty
                    blocks[i] = block
                }
                if block["type"] as? String == "server_tool_use", let name = block["name"] as? String, let id = block["id"] as? String {
                    onServerTool(.started(id: id, name: name, input: block["input"] as? [String: Any] ?? [:]))
                }
            case "message_delta":
                if let d = e["delta"] as? [String: Any], let r = d["stop_reason"] as? String { stopReason = r }
                if let u = e["usage"] as? [String: Any] { usage.merge(u.filter { $0.value is NSNumber }) { $1 } }
            case "error":
                let m = (e["error"] as? [String: Any])?["message"] as? String ?? ""
                throw Failure.http(500, m)
            default: break
            }
        }
        var content: [[String: Any]] = []
        var calls: [ToolCall] = []
        for i in blocks.keys.sorted() {
            guard var block = blocks[i] else { continue }
            let invalid = block.removeValue(forKey: "lumenInvalid") as? Bool ?? false
            if block["type"] as? String == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                calls.append(ToolCall(id: id, name: name, arguments: invalid ? nil : block["input"] as? [String: Any]))
            }
            content.append(block)
        }
        // A reply cut off by the length limit or declined can't have its tool calls run.
        if stopReason == "max_tokens" || stopReason == "refusal" { calls = [] }
        return Result(assistantMessage: ["role": "assistant", "content": content], toolCalls: calls, stopReason: stopReason,
                      sources: citedSources(content), usage: Usage.anthropic(usage))
    }

    /// Whether a server tool's result is an error, such as a page that couldn't be fetched.
    static func serverToolFailed(_ block: [String: Any]) -> Bool {
        guard let content = block["content"] as? [String: Any] else { return false }
        return (content["type"] as? String)?.hasSuffix("_error") ?? false
    }

    /// The web pages cited in an answer, in order, once each.
    static func citedSources(_ content: [[String: Any]]) -> [(url: URL, title: String)] {
        var out: [(url: URL, title: String)] = []
        for block in content where block["type"] as? String == "text" {
            for c in block["citations"] as? [[String: Any]] ?? [] {
                guard let url = (c["url"] as? String).flatMap(URL.init(string:)), !out.contains(where: { $0.url == url }) else { continue }
                out.append((url, (c["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? InputResolver.displayHost(url)))
            }
        }
        return out
    }

    // MARK: OpenAI-compatible

    @MainActor
    private static func readOpenAI(_ bytes: URLSession.AsyncBytes, onText: (String) -> Void) async throws -> Result {
        var text = ""
        var calls: [Int: (id: String, name: String, args: String)] = [:]
        var finish: String?
        var usage: Usage?
        for try await e in events(bytes) {
            try Task.checkCancellation()
            if let err = e["error"] as? [String: Any] { throw Failure.http(500, err["message"] as? String ?? "") }
            // The counts come in a last chunk of their own, with no choices; other chunks may carry `"usage": null`.
            if let u = e["usage"] as? [String: Any], let parsed = Usage.openAI(u) { usage = parsed }
            guard let choice = (e["choices"] as? [[String: Any]])?.first else { continue }
            if let f = choice["finish_reason"] as? String { finish = f }
            guard let d = choice["delta"] as? [String: Any] else { continue }
            if let t = d["content"] as? String, !t.isEmpty {
                text += t
                onText(t)
            }
            for c in d["tool_calls"] as? [[String: Any]] ?? [] {
                let i = c["index"] as? Int ?? 0
                var entry = calls[i] ?? ("", "", "")
                if let id = c["id"] as? String, !id.isEmpty { entry.id = id }
                if let f = c["function"] as? [String: Any] {
                    if let n = f["name"] as? String, !n.isEmpty { entry.name = n }
                    entry.args += f["arguments"] as? String ?? ""
                }
                calls[i] = entry
            }
        }
        var message: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
        let ordered = calls.keys.sorted().compactMap { calls[$0] }.filter { !$0.name.isEmpty }
        if finish == "length" { return Result(assistantMessage: message, toolCalls: [], stopReason: finish, usage: usage) }
        if !ordered.isEmpty {
            message["tool_calls"] = ordered.enumerated().map { n, c in
                ["id": c.id.isEmpty ? "call_\(n)" : c.id, "type": "function", "function": ["name": c.name, "arguments": c.args.isEmpty ? "{}" : c.args]] as [String: Any]
            }
        }
        let toolCalls = ordered.enumerated().map { n, c -> ToolCall in
            let json = c.args.isEmpty ? "{}" : c.args
            return ToolCall(id: c.id.isEmpty ? "call_\(n)" : c.id, name: c.name,
                            arguments: (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])
        }
        return Result(assistantMessage: message, toolCalls: toolCalls, stopReason: finish, usage: usage)
    }

    // MARK: One short answer

    /// One short request without tools or streaming, for small jobs done behind the scenes such as a title or a
    /// note: the reply's text, trimmed. Not for Apple's on-device model, which has no server.
    @MainActor
    static func complete(provider: AIProvider, base: String, key: String?, model: String, system: String, prompt: String,
                         maxTokens: Int = 1_000) async throws -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = provider == .anthropic ? "/messages" : "/chat/completions"
        guard provider != .apple, let url = URL(string: trimmed + path), ["http", "https"].contains(url.scheme ?? "") else {
            throw Failure.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model]
        if provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = maxTokens
            body["system"] = system
            body["messages"] = [["role": "user", "content": prompt]]
        } else {
            if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            if provider == .openRouter {
                request.setValue("https://scadavide55.github.io/Tacet/", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("Tacet", forHTTPHeaderField: "X-Title")
            }
            // OpenAI's newer models take only `max_completion_tokens`; other servers know the older name.
            body[provider == .openAI ? "max_completion_tokens" : "max_tokens"] = maxTokens
            body["messages"] = [["role": "system", "content": system], ["role": "user", "content": prompt]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status, errorMessage(data)) }
        return completionText(data, provider: provider)
    }

    /// A small job with the model chosen for small jobs in Settings › AI, or the default model when none is: the
    /// provider, address and key are the ones the chat uses. For Deep Research notes, choosing sources, titles.
    @MainActor
    static func smallJob(system: String, prompt: String, maxTokens: Int = 1_000) async throws -> String {
        let s = Settings.shared
        let p = s.aiProvider
        let key = await Task.detached(priority: .userInitiated) { AIKeys.get(p) }.value
        return try await complete(provider: p, base: p.baseURL, key: key, model: s.aiSmallModelName, system: system,
                                  prompt: prompt, maxTokens: maxTokens)
    }

    /// The text of a reply that wasn't streamed, in either format.
    static func completionText(_ data: Data, provider: AIProvider) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let text: String
        if provider == .anthropic {
            text = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
        } else {
            let message = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
            text = message?["content"] as? String ?? ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tool results in the shape each provider expects: one user turn for Anthropic, one message per call otherwise.
    /// Screenshots go inside Anthropic's tool results; other APIs only take text there, so they follow in a user message.
    static func toolResults(_ outputs: [(call: ToolCall, output: String, isError: Bool)], provider: AIProvider,
                            images: [String: Data] = [:]) -> [[String: Any]] {
        if provider == .anthropic {
            let blocks = outputs.map { o -> [String: Any] in
                var content: Any = o.output
                if let jpeg = images[o.call.id] {
                    content = [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                               ["type": "text", "text": o.output]]
                }
                var b: [String: Any] = ["type": "tool_result", "tool_use_id": o.call.id, "content": content]
                if o.isError { b["is_error"] = true }
                return b
            }
            return [["role": "user", "content": blocks]]
        }
        var messages = outputs.map { ["role": "tool", "tool_call_id": $0.call.id, "content": $0.output] as [String: Any] }
        let shots = outputs.compactMap { images[$0.call.id] }
        if !shots.isEmpty {
            let parts: [[String: Any]] = [["type": "text", "text": screenshotNote]]
                + shots.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]] }
            messages.append(["role": "user", "content": parts])
        }
        return messages
    }
}
