import Foundation

// MARK: - How much a request may carry

/// How much of a conversation one request may carry, and how much of one page goes into it. A model on this Mac with
/// an 8,000-token context can't take what a hosted model with 200,000 can: sent too much, a local server quietly drops
/// the start of the conversation, which is where the instructions are.
struct AssistantLimits: Equatable {
    /// Bytes of conversation (JSON, pictures included) per request, beside the instructions and the tools.
    var budget: Int
    /// Characters of one page, transcript or document that go into an attached page or a tool's result.
    var pageChars: Int
    /// The model's context in tokens, when its server says so.
    var contextTokens: Int?

    /// A token is about four characters of English; the same rough rule is used both ways.
    static let charsPerToken = 4

    /// Room kept for the reply itself, in tokens.
    static func replyReserve(_ contextTokens: Int) -> Int { min(4_096, contextTokens / 4) }

    /// The limits for a provider. `contextTokens` is the model's context when it's known, and `overhead` the bytes of
    /// instructions and tool descriptions sent with every request, which take their share of that context.
    static func of(_ provider: AIProvider, contextTokens: Int? = nil, overhead: Int = 0) -> AssistantLimits {
        let base = AssistantChat.contextBudget(provider)
        let pages: Int
        switch provider {
        case .ollama, .lmStudio, .apple: pages = 6_000
        case .deepSeek: pages = 25_000
        default: pages = WebTools.textLimit
        }
        guard let tokens = contextTokens, tokens > 0 else { return AssistantLimits(budget: base, pageChars: pages) }
        let room = (tokens - replyReserve(tokens)) * charsPerToken - overhead
        let budget = min(max(room, 4_000), provider.isLocal ? Int.max : base)
        // One page may take about a quarter of what's left, so an answer can read a few of them.
        let page = min(max(budget / 4, 1_500), WebTools.textLimit)
        return AssistantLimits(budget: budget, pageChars: provider.isLocal ? page : min(page, pages), contextTokens: tokens)
    }

    /// `text` cut to `limit` characters, saying how much of it is included.
    static func clip(_ text: String, to limit: Int, what: String = "page") -> String {
        let count = text.count
        guard count > limit else { return text }
        let percent = max(1, limit * 100 / count)
        return String(text.prefix(limit))
            + "\n[The \(what) is longer: only the first \(limit) of its \(count) characters (\(percent)%) are included.]"
    }
}

extension AssistantChat {
    /// The context of the model this chat uses, in tokens, when its server has said: a model on this Mac runs with
    /// what Ollama or LM Studio gives it, often far less than it was trained for.
    func contextTokens(_ provider: AIProvider) -> Int? { LocalModels.shared.context(provider, model: model)?.tokens }

    // MARK: Fitting the conversation

    /// Roughly how much conversation (in bytes of JSON, pictures included) a request carries when nothing more is
    /// known about the model: models on this Mac take far less than the big hosted ones.
    static func contextBudget(_ provider: AIProvider) -> Int {
        switch provider {
        case .ollama, .lmStudio, .apple: 32_000
        case .deepSeek: 250_000
        default: 600_000
        }
    }

    /// Keeps a conversation within the model's reach, in this order until it fits: older pages, tool results and
    /// pictures are shortened; the oldest turns go; then the earlier rounds of the answer in progress have their tool
    /// results shortened, oldest first; and only if the last round alone is too big are its results cut to share what
    /// room is left. A tool call never loses its result, and the chat on screen keeps everything.
    static func fitted(_ transcript: [[String: Any]], budget: Int) -> [[String: Any]] {
        func size(_ m: [String: Any]) -> Int { (try? JSONSerialization.data(withJSONObject: m))?.count ?? 0 }
        var out = transcript
        var total = out.reduce(0) { $0 + size($1) }
        guard total > budget, let current = out.lastIndex(where: isRequest) else { return out }
        var protect = current
        for i in 0..<protect where total > budget {
            let before = size(out[i])
            out[i] = shortened(out[i])
            total += size(out[i]) - before
        }
        // Whole turns go, oldest first, so a tool call is never left without its result.
        while total > budget, let next = out.indices.dropFirst().first(where: { $0 < protect && isRequest(out[$0]) }) {
            total -= out[0..<next].reduce(0) { $0 + size($1) }
            out.removeSubrange(0..<next)
            protect -= next
        }
        guard total > budget else { return out }
        // The answer in progress: a deep research can read ten long pages in as many rounds. What the model read in
        // earlier rounds is shortened, oldest first; the last round, which it hasn't seen yet, stays whole.
        let lastRound = out.lastIndex { $0["role"] as? String == "assistant" } ?? out.count
        for i in out.indices where i > protect && i < lastRound && total > budget && isToolResult(out[i]) {
            let before = size(out[i])
            out[i] = shortened(out[i], keep: 1_000, note: earlierNote)
            total += size(out[i]) - before
        }
        guard total > budget, lastRound < out.count else { return out }
        // Last resort: the last round alone doesn't fit, so its results share the room that's left.
        let results = out.indices.filter { $0 > lastRound && isToolResult(out[$0]) }
        guard !results.isEmpty else { return out }
        let theirs = results.reduce(0) { $0 + size(out[$1]) }
        let room = max(budget - (total - theirs), 0)
        // Anthropic sends a round's results as blocks of one message, so they're counted one by one.
        let pieces = results.reduce(0) { n, i in
            n + max(1, (out[i]["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "tool_result" }.count ?? 1)
        }
        let share = max(room / pieces - 300, 600)
        for i in results {
            let before = size(out[i])
            out[i] = shortened(out[i], keep: share, images: false)
            total += size(out[i]) - before
        }
        return out
    }

    /// A message the user typed, as opposed to a tool's result sent back in a user message, or the screenshot that
    /// follows tool results for APIs that only take text in them.
    static func isRequest(_ m: [String: Any]) -> Bool {
        guard m["role"] as? String == "user" else { return false }
        if m["content"] is String { return true }
        let blocks = m["content"] as? [[String: Any]] ?? []
        if blocks.first?["text"] as? String == AIClient.screenshotNote { return false }
        return !blocks.contains { $0["type"] as? String == "tool_result" }
    }

    /// What tools sent back: Anthropic's user turn of tool results, an OpenAI tool message, or the screenshot after them.
    static func isToolResult(_ m: [String: Any]) -> Bool {
        if m["role"] as? String == "tool" { return true }
        return m["role"] as? String == "user" && !isRequest(m)
    }

    private static let shortNote = "\n[Shortened to fit the model's limit.]"
    private static let earlierNote = "\n[Shortened to fit the model's limit; you read all of it earlier in this answer.]"

    /// A message with its long text cut to `keep` characters and, unless `images` is false, its pictures left out. A
    /// request keeps the user's own words after the page or selection attached to it.
    static func shortened(_ m: [String: Any], keep: Int = 1_500, note: String = shortNote, images: Bool = true) -> [String: Any] {
        func cut(_ s: String) -> String {
            guard s.count > keep else { return s }
            var tail = ""
            for tag in ["</page>", "</selection>"] {
                if let r = s.range(of: tag, options: .backwards), s.distance(from: s.startIndex, to: r.lowerBound) > keep {
                    tail = String(s[r.lowerBound...])
                    break
                }
            }
            if tail.count > keep { tail = "" }
            return String(s.prefix(keep)) + note + (tail.isEmpty ? "" : "\n" + tail)
        }
        func block(_ b: [String: Any]) -> [String: Any] {
            var b = b
            switch b["type"] as? String {
            case "image", "image_url": return images ? ["type": "text", "text": "[A picture was here.]"] : b
            case "text": if let t = b["text"] as? String { b["text"] = cut(t) }
            case "tool_result":
                if let t = b["content"] as? String { b["content"] = cut(t) }
                if let parts = b["content"] as? [[String: Any]] { b["content"] = parts.map(block) }
            default: break
            }
            return b
        }
        var m = m
        if let s = m["content"] as? String { m["content"] = cut(s) }
        if let parts = m["content"] as? [[String: Any]] { m["content"] = parts.map(block) }
        return m
    }
}
