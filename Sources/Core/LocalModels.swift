import Foundation
import Observation

// MARK: - How much a model on this Mac can take

/// The context of the models that run on this Mac, read from their own servers. Sent more than it can take, a local
/// server drops the start of the conversation, which is where the instructions are; so the assistant needs to know.
@Observable
final class LocalModels {
    static let shared = LocalModels()

    /// Ollama's own default when nothing sets the context (its FAQ: "a context window size of 4096 tokens").
    static let ollamaDefault = 4_096
    /// What Tacet asks Ollama for when the model allows it: enough for the instructions, the tools and a few pages,
    /// and still light on memory.
    static let ollamaPreferred = 16_384
    /// Below this, the assistant uses its short instructions and fewer tools.
    static let compactBelow = 16_000
    /// Below this, a deep research can't read enough pages to be worth it.
    static let researchMinimum = 16_000

    struct Context: Equatable {
        /// The most the model was trained for, when its server says.
        var max: Int?
        /// The context the model runs with, or will run with for Tacet's requests.
        var tokens: Int
        /// True for Ollama, where Tacet sets the context with each request.
        var setByTacet: Bool
    }

    private var known: [String: Context] = [:]
    private var loading: Set<String> = []

    private static func key(_ p: AIProvider, _ model: String) -> String { p.rawValue + "/" + model }

    /// The context for `model`, if it was read; starts reading it otherwise.
    func context(_ p: AIProvider, model: String) -> Context? {
        guard p.isLocal, !model.isEmpty else { return nil }
        let k = Self.key(p, model)
        if let c = known[k] { return c }
        refresh(p, model: model)
        return nil
    }

    /// Reads the context again, after the user picks another model or loads it differently.
    func refresh(_ p: AIProvider, model: String, force: Bool = false) {
        let k = Self.key(p, model)
        guard p.isLocal, !model.isEmpty, force || known[k] == nil, !loading.contains(k) else { return }
        loading.insert(k)
        let root = Self.host(p.baseURL)
        Task { @MainActor in
            defer { self.loading.remove(k) }
            if let c = await (p == .ollama ? Self.readOllama(root, model: model) : Self.readLMStudio(root, model: model)) {
                self.known[k] = c
            }
        }
    }

    /// Waits for the context when it isn't known yet: a request to a small model shouldn't go out sized for a big one.
    @MainActor
    func load(_ p: AIProvider, model: String) async -> Context? {
        guard p.isLocal, !model.isEmpty else { return nil }
        let k = Self.key(p, model)
        if let c = known[k] { return c }
        let root = Self.host(p.baseURL)
        let c = await (p == .ollama ? Self.readOllama(root, model: model) : Self.readLMStudio(root, model: model))
        if let c { known[k] = c }
        return c
    }

    /// The server's address without the OpenAI-compatible "/v1".
    static func host(_ base: String) -> String {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return root.hasSuffix("/v1") ? String(root.dropLast(3)) : root
    }

    // MARK: Ollama

    private static func readOllama(_ root: String, model: String) async -> Context? {
        guard let url = URL(string: root + "/api/show") else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 5
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await URLSession.shared.data(for: r), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ollamaContext(json)
    }

    /// From /api/show: the model's trained context ("<arch>.context_length" in model_info) and a num_ctx its
    /// Modelfile sets. A num_ctx the user set is kept; otherwise Tacet asks for up to `ollamaPreferred`.
    static func ollamaContext(_ show: [String: Any]) -> Context {
        let info = show["model_info"] as? [String: Any] ?? [:]
        let max = info.first { $0.key.hasSuffix(".context_length") }.flatMap { ($0.value as? NSNumber)?.intValue }
        let set = numCtx(show["parameters"] as? String ?? "")
        let tokens = set ?? min(max ?? ollamaDefault, ollamaPreferred)
        return Context(max: max, tokens: tokens, setByTacet: true)
    }

    /// num_ctx in /api/show's parameters, one "name value" pair per line.
    static func numCtx(_ parameters: String) -> Int? {
        for line in parameters.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "num_ctx", let n = Int(parts[1]), n > 0 { return n }
        }
        return nil
    }

    // MARK: LM Studio

    private static func readLMStudio(_ root: String, model: String) async -> Context? {
        guard let url = URL(string: root + "/api/v1/models") else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: r), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return lmStudioContext(json, model: model)
    }

    /// From LM Studio's /api/v1/models (0.4 and later): the context the loaded instance runs with
    /// (loaded_instances[].config.context_length), which is what counts; nil when the model isn't loaded, since
    /// LM Studio then picks the context when it loads it.
    static func lmStudioContext(_ json: [String: Any], model: String) -> Context? {
        let list = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) ?? []
        guard let m = list.first(where: { ($0["key"] as? String) == model || ($0["id"] as? String) == model }) else { return nil }
        let max = (m["max_context_length"] as? NSNumber)?.intValue
        let loaded = (m["loaded_instances"] as? [[String: Any]])?.compactMap {
            (($0["config"] as? [String: Any])?["context_length"] as? NSNumber)?.intValue
        }.first
        guard let loaded else { return nil }
        return Context(max: max, tokens: loaded, setByTacet: false)
    }

    // MARK: Profiles

    /// Short instructions and fewer tools, for a model whose context can't hold the full ones next to a page.
    static func isCompact(_ p: AIProvider, tokens: Int?) -> Bool {
        guard p.isLocal else { return false }
        return (tokens ?? AssistantChat.contextBudget(p) / AssistantLimits.charsPerToken) < compactBelow
    }
}
