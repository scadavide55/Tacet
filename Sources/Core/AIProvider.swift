import AppKit
import Observation
import Security
import WebKit

// MARK: - Providers

/// Where the assistant's answers come from. The user brings their own key.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic, openAI, openRouter, deepSeek, ollama, lmStudio, custom, apple
    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .deepSeek: "DeepSeek"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: L("OpenAI-compatible")
        case .apple: L("Apple (on this Mac)")
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openAI: "gpt-5"
        case .openRouter: "openrouter/auto"
        case .deepSeek: "deepseek-chat"
        case .ollama, .lmStudio, .custom: ""
        case .apple: AppleModel.modelID
        }
    }

    /// A faster model for answers in the command bar, where the provider has one.
    var fastModel: String? {
        switch self {
        case .anthropic: "claude-haiku-5-5"
        case .openAI: "gpt-5-mini"
        default: nil
        }
    }

    /// Anthropic models that accept `output_config.effort`.
    static func takesEffort(_ model: String) -> Bool {
        let m = model.lowercased()
        return ["opus-4-5", "opus-4-6", "opus-4-7", "opus-4-8", "opus-5", "sonnet-4-6", "sonnet-5", "haiku-5", "fable", "mythos"].contains { m.contains($0) }
    }

    /// OpenAI models that accept `reasoning_effort`.
    static func takesReasoningEffort(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .deepSeek: "https://api.deepseek.com"
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        case .custom: "http://localhost:11434/v1"
        case .apple: ""
        }
    }

    /// Models running on this Mac (or the local network), with no account and no key.
    var isLocal: Bool { self == .ollama || self == .lmStudio }

    /// The address requests go to: the one set in Settings for local servers, else the provider's own.
    var baseURL: String {
        switch self {
        case .custom: return Settings.shared.aiBaseURL
        case .ollama, .lmStudio:
            let set = Settings.shared.aiLocalURLs[rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return set.isEmpty ? defaultBaseURL : set
        default: return defaultBaseURL
        }
    }

    /// Ollama, LM Studio and other local servers don't need a key, and Apple's model runs on the Mac.
    var needsKey: Bool { self != .custom && self != .apple && !isLocal }

    /// Where to get the app that runs the models, for local providers.
    var appURL: URL? {
        switch self {
        case .ollama: URL(string: "https://ollama.com/download")
        case .lmStudio: URL(string: "https://lmstudio.ai")
        default: nil
        }
    }

    /// Whether `model` can read images: the user's choice if they made one, else what the provider's
    /// model list says, else a guess from the model's name.
    func supportsImages(_ model: String) -> Bool {
        if self == .apple { return false }
        if let choice = Settings.shared.aiVision[visionKey(model)] { return choice }
        if let listed = AIModels.shared.models(for: self).first(where: { $0.id == model })?.vision { return listed }
        return guessesImages(model)
    }

    func visionKey(_ model: String) -> String { rawValue + "/" + model }

    func guessesImages(_ model: String) -> Bool {
        let m = model.lowercased()
        switch self {
        case .anthropic: return m.hasPrefix("claude") && !m.hasPrefix("claude-2") && !m.hasPrefix("claude-instant")
        case .openAI:
            if m.contains("audio") || m.contains("realtime") || m.hasPrefix("o1-mini") || m.hasPrefix("o3-mini") || m.hasPrefix("gpt-3") { return false }
            return m.hasPrefix("gpt-4o") || m.hasPrefix("gpt-4.1") || m.hasPrefix("gpt-4-turbo") || m.hasPrefix("gpt-5")
                || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.hasPrefix("chatgpt-4o")
        case .deepSeek: return m.contains("flash") || m.contains("vl")
        case .openRouter:
            // Ids look like "vendor/model"; the router itself picks a model that fits the request.
            return m == "openrouter/auto" || ["claude", "gpt-4o", "gpt-4.1", "gpt-5", "gemini", "vision", "-vl", "pixtral", "grok-4", "llama-4"].contains { m.contains($0) }
        case .custom, .ollama, .lmStudio:
            return ["vision", "-vl", "vl-", "llava", "gpt-4o", "gemma3", "gemma-3", "pixtral", "minicpm-v", "claude", "qwen2.5vl", "qwen2.5-vl",
                    "llama3.2-vision", "moondream", "granite3.2-vision", "mistral-small3"].contains { m.contains($0) }
        case .apple:
            return false
        }
    }
}

// MARK: - Model lists

/// The models each provider offers, fetched from its API so nobody has to type a model name.
@Observable
final class AIModels {
    static let shared = AIModels()

    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
        /// Whether it reads images, when the provider says so.
        let vision: Bool?
    }

    private var lists: [AIProvider: [Model]] = [:]
    private(set) var loading: Set<AIProvider> = []
    private(set) var errors: [AIProvider: String] = [:]

    func models(for p: AIProvider) -> [Model] { lists[p] ?? [] }

    /// Loads the list once per launch, or again when `force` is set (after a new key, say).
    func refresh(_ p: AIProvider, force: Bool = false) {
        if p == .apple {
            lists[p] = [Model(id: AppleModel.modelID, name: L("On-device model"), vision: false)]
            errors[p] = AppleModel.unavailableReason
            return
        }
        guard force || lists[p] == nil, !loading.contains(p) else { return }
        loading.insert(p)
        let base = p.baseURL
        Task { @MainActor in
            let key = await Task.detached(priority: .userInitiated) { AIKeys.get(p) }.value
            if p.needsKey && key == nil {
                self.loading.remove(p)
                self.errors[p] = nil
                self.lists[p] = nil
                return
            }
            do {
                let models = try await Self.fetch(p, base: base, key: key)
                self.lists[p] = models
                self.errors[p] = nil
                // A default that the provider doesn't offer is replaced by its first model.
                let s = Settings.shared
                if s.aiProvider == p, !models.isEmpty, !models.contains(where: { $0.id == s.aiModelName }) {
                    var m = s.aiModels
                    m[p.rawValue] = models.first { $0.id == p.defaultModel }?.id ?? models[0].id
                    s.aiModels = m
                }
            } catch {
                self.errors[p] = Self.explain(error, provider: p)
            }
            self.loading.remove(p)
        }
    }

    /// A local server that isn't running is the usual reason a list doesn't load, so that's said plainly.
    static func explain(_ error: Error, provider p: AIProvider) -> String {
        let code = (error as NSError).code
        if p.isLocal, [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotFindHost].contains(code) {
            return String(format: L("%@ isn't running. Open the %@ app (and in LM Studio, start its server), then try again."), p.name, p.name)
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func fetch(_ p: AIProvider, base: String, key: String?) async throws -> [Model] {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if p == .ollama { return try await fetchOllama(root) }
        if p == .lmStudio, let rich = try? await fetchLMStudio(root) { return rich }
        var out: [Model] = []
        var after: String?
        repeat {
            var path = root + "/models"
            if p == .anthropic { path += "?limit=1000" + (after.map { "&after_id=" + $0 } ?? "") }
            guard let url = URL(string: path), ["http", "https"].contains(url.scheme ?? "") else { throw AIClient.Failure.badURL }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            if p == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue(AIClient.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            } else if let key {
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIClient.Failure.http(status, String(decoding: data.prefix(300), as: UTF8.self))
            }
            for m in json["data"] as? [[String: Any]] ?? [] {
                guard let id = m["id"] as? String, isChatModel(id, provider: p) else { continue }
                let modalities = (m["architecture"] as? [String: Any])?["input_modalities"] as? [String]
                out.append(Model(id: id, name: (m["display_name"] as? String) ?? (m["name"] as? String) ?? id,
                                 vision: modalities.map { $0.contains("image") }))
            }
            after = p == .anthropic && (json["has_more"] as? Bool ?? false) ? json["last_id"] as? String : nil
        } while after != nil
        // Anthropic lists newest first; the others are easier to scan sorted.
        return p == .anthropic ? out : out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Ollama's own list says which models read images, and leaves out embedding models.
    private static func fetchOllama(_ root: String) async throws -> [Model] {
        let host = root.hasSuffix("/v1") ? String(root.dropLast(3)) : root
        guard let url = URL(string: host + "/api/tags") else { throw AIClient.Failure.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIClient.Failure.http(0, "") }
        var out: [Model] = []
        for m in json["models"] as? [[String: Any]] ?? [] {
            guard let id = (m["model"] as? String) ?? (m["name"] as? String) else { continue }
            // What it can do comes from /api/show; older Ollama versions don't say, and the name decides.
            var caps: [String]?
            if let show = URL(string: host + "/api/show") {
                var r = URLRequest(url: show)
                r.httpMethod = "POST"
                r.timeoutInterval = 5
                r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": id])
                if let (d, _) = try? await URLSession.shared.data(for: r),
                   let info = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { caps = info["capabilities"] as? [String] }
            }
            if let caps, !caps.contains("completion") { continue }
            out.append(Model(id: id, name: id, vision: caps.map { $0.contains("vision") }))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// LM Studio's own list says which models read images ("vlm") and leaves out embedding models.
    private static func fetchLMStudio(_ root: String) async throws -> [Model] {
        let host = root.hasSuffix("/v1") ? String(root.dropLast(3)) : root
        guard let url = URL(string: host + "/api/v0/models") else { throw AIClient.Failure.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { throw AIClient.Failure.http(0, "") }
        return list.compactMap { m -> Model? in
            guard let id = m["id"] as? String, (m["type"] as? String) != "embeddings" else { return nil }
            return Model(id: id, name: id, vision: (m["type"] as? String).map { $0 == "vlm" })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// OpenAI's list also has embedding, speech and image models, which can't chat.
    private static func isChatModel(_ id: String, provider: AIProvider) -> Bool {
        guard provider == .openAI else { return true }
        let m = id.lowercased()
        let other = ["embedding", "whisper", "tts", "dall-e", "davinci", "babbage", "moderation", "audio", "realtime",
                     "transcribe", "image", "sora", "computer-use", "codex", "search"]
        return !other.contains { m.contains($0) } && (m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.hasPrefix("chatgpt"))
    }
}

// MARK: - Keys

/// API keys live in the Keychain, never in the preferences file.
enum AIKeys {
    /// Named before Lumen became Tacet; kept so the saved key is still found.
    private static let service = "Lumen AI key"

    private static func query(_ p: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.rawValue]
    }

    /// Keys already read this session. Reading the Keychain can be slow, and can make macOS ask for access, so each
    /// key is read once.
    private static var cache: [AIProvider: String] = [:]
    private static let lock = NSLock()

    /// Can block while macOS asks for Keychain access, so the chat reads it off the main thread.
    static func get(_ p: AIProvider) -> String? {
        lock.lock()
        let cached = cache[p]
        lock.unlock()
        if let cached { return cached }
        var q = query(p)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        guard !key.isEmpty else { return nil }
        lock.lock()
        cache[p] = key
        lock.unlock()
        return key
    }

    /// Whether a key is saved, without reading it (reading can make macOS ask for Keychain access). Views ask this
    /// as they redraw, so a key known to be there isn't looked up again.
    static func has(_ p: AIProvider) -> Bool {
        lock.lock()
        let known = cache[p] != nil || present.contains(p)
        lock.unlock()
        if known { return true }
        var q = query(p)
        q[kSecReturnAttributes as String] = true
        let found = SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
        if found {
            lock.lock()
            present.insert(p)
            lock.unlock()
        }
        return found
    }

    /// Providers whose key is known to be saved, without having read it.
    private static var present: Set<AIProvider> = []

    static func set(_ key: String, for p: AIProvider) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        cache[p] = key.isEmpty ? nil : key
        if key.isEmpty { present.remove(p) }
        lock.unlock()
        SecItemDelete(query(p) as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query(p)
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
