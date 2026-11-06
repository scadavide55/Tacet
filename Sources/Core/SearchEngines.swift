import Foundation
import Security

/// A web search service the assistant can ask. Several can be set up in Settings › AI; they're tried in the user's
/// order, so one that is down or blocks Tacet doesn't leave the assistant without results.
protocol WebSearchEngine: Sendable {
    /// Shown in the activity timeline, as in "8 results · Brave". A brand name, so it isn't translated.
    var name: String { get }
    func search(_ query: String) async throws -> [WebTools.SearchResult]
}

/// The engines the user can put in order. The raw values are what Settings saves, so they must not change.
enum SearchEngineKind: String, CaseIterable, Identifiable {
    case searxng, brave, duckDuckGo = "duckduckgo"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .searxng: "SearXNG"
        case .brave: "Brave Search"
        case .duckDuckGo: "DuckDuckGo"
        }
    }

    /// DuckDuckGo last: it needs no setup, but it is the one most likely to stop answering automated searches.
    static let defaultOrder = allCases.map(\.rawValue)

    /// The saved order without names this version doesn't know, and with engines it doesn't mention added at the end,
    /// so an engine added in a later version still shows up.
    static func ordered(_ saved: [String]) -> [SearchEngineKind] {
        var out: [SearchEngineKind] = []
        for raw in saved { if let k = SearchEngineKind(rawValue: raw), !out.contains(k) { out.append(k) } }
        for k in allCases where !out.contains(k) { out.append(k) }
        return out
    }
}

enum SearchEngines {
    /// The engines to try, in the user's order, leaving out the ones that aren't set up: SearXNG needs an address and
    /// Brave a key. DuckDuckGo needs nothing, so with nothing set up searches go to DuckDuckGo as they always have.
    static func configured(order: [String], searxURL: String, braveKey: String?) -> [any WebSearchEngine] {
        SearchEngineKind.ordered(order).compactMap { kind -> (any WebSearchEngine)? in
            switch kind {
            case .searxng: SearXNG(address: searxURL)
            case .brave: braveKey.flatMap { BraveSearch(key: $0) }
            case .duckDuckGo: DuckDuckGo()
            }
        }
    }

    /// The engines from Settings. The Brave key is read off the main thread, since the Keychain can be slow.
    @MainActor
    static func fromSettings() async -> [any WebSearchEngine] {
        let s = Settings.shared
        let order = s.aiSearchOrder, address = s.aiSearXNGURL
        let wantsBrave = SearchEngineKind.ordered(order).contains(.brave)
        let key = wantsBrave ? await Task.detached(priority: .userInitiated) { BraveKey.get() }.value : nil
        return configured(order: order, searxURL: address, braveKey: key)
    }
}

/// At most `limit` searches at once. A deep research can ask for many at the same moment, and a burst like that is
/// what makes search engines take Tacet for a bot.
actor SearchGate {
    static let shared = SearchGate(limit: 3)

    let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func enter() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the place straight to the next search waiting, so the count stays right.
    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    nonisolated func run<T>(_ body: () async throws -> T) async throws -> T {
        await enter()
        do {
            // Stop may have been pressed while this search waited for its turn.
            try Task.checkCancellation()
            let value = try await body()
            await leave()
            return value
        } catch {
            await leave()
            throw error
        }
    }
}

// MARK: - SearXNG

/// A SearXNG server chosen by the user, asked through its JSON API. It may be on the user's own Mac or network: that
/// address was typed by the user, so it is allowed here. The results it returns still go through the usual checks
/// before the assistant can read them, so they can't lead it into the local network.
struct SearXNG: WebSearchEngine {
    let endpoint: URL
    var name: String { "SearXNG" }

    /// Takes the server's address, with or without /search at the end; nil if it isn't an http or https address.
    init?(address: String) {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host, !host.isEmpty else { return nil }
        c.query = nil
        c.fragment = nil
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/search") { path += "/search" }
        c.path = path
        guard let url = c.url else { return nil }
        endpoint = url
    }

    func requestURL(_ query: String) -> URL {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
        return c.url!
    }

    func search(_ query: String) async throws -> [WebTools.SearchResult] {
        var request = URLRequest(url: requestURL(query))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await WebTools.download(request, localAllowed: true)
            return try Self.parse(data)
        } catch WebTools.Failure.http(403) {
            // SearXNG answers 403 when its json format is turned off, which is how it comes by default.
            throw WebTools.Failure.engine("This SearXNG server doesn't give JSON answers: add json to the formats in its settings.yml.")
        }
    }

    /// The results of a SearXNG JSON answer: `results[]` with `title`, `url` and `content`.
    static func parse(_ data: Data) throws -> [WebTools.SearchResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw WebTools.Failure.engine("The SearXNG server's answer isn't a search result list.")
        }
        return WebTools.searchResults(results.map { ($0["title"] as? String, $0["url"] as? String, $0["content"] as? String) })
    }
}

// MARK: - Brave Search

/// Brave's Search API, with the user's own key (free keys exist with a monthly limit).
struct BraveSearch: WebSearchEngine {
    static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!
    let key: String
    var name: String { "Brave" }

    init?(key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }
        self.key = k
    }

    func request(_ query: String) -> URLRequest {
        var c = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "10")]
        var r = URLRequest(url: c.url!)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        return r
    }

    func search(_ query: String) async throws -> [WebTools.SearchResult] {
        do {
            let (data, _) = try await WebTools.download(request(query))
            return try Self.parse(data)
        } catch WebTools.Failure.http(let code) where [401, 403, 422].contains(code) {
            throw WebTools.Failure.engine("Brave Search didn't accept the API key (error \(code)).")
        } catch WebTools.Failure.http(429) {
            throw WebTools.Failure.engine("Brave Search's limit for this key was reached. Try again later.")
        }
    }

    /// The web results of a Brave answer: `web.results[]` with `title`, `url` and `description`. The description can
    /// hold <strong> around the words searched for, which is taken out.
    static func parse(_ data: Data) throws -> [WebTools.SearchResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebTools.Failure.engine("Brave Search's answer isn't a search result list.")
        }
        // An answer without a web section, such as for a query with only news, simply has no web results.
        let results = (json["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return WebTools.searchResults(results.map { ($0["title"] as? String, $0["url"] as? String, $0["description"] as? String) })
    }
}

/// The Brave Search API key, in the Keychain under the same service as the AI keys, with an account of its own.
enum BraveKey {
    /// Named before Lumen became Tacet; shared with `AIKeys`, whose accounts are provider names, so this can't clash.
    private static let service = "Lumen AI key"
    private static let account = "brave-search"
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: service, kSecAttrAccount as String: account]
    private static var cache: String?
    private static var loaded = false
    private static let lock = NSLock()

    /// Can block while macOS asks for Keychain access, so it is read off the main thread. Read once per session.
    static func get() -> String? {
        lock.lock()
        if loaded { defer { lock.unlock() }; return cache }
        lock.unlock()
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var key: String?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            let s = String(decoding: data, as: UTF8.self)
            key = s.isEmpty ? nil : s
        }
        lock.lock()
        cache = key
        loaded = true
        lock.unlock()
        return key
    }

    static func set(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        cache = key.isEmpty ? nil : key
        loaded = true
        lock.unlock()
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - DuckDuckGo

/// DuckDuckGo's HTML page, the engine that needs no setup. When it shows its check for bots instead of results, it
/// is asked once more after a pause, which is often enough.
struct DuckDuckGo: WebSearchEngine {
    var name: String { "DuckDuckGo" }
    var retryDelay: Duration = .seconds(2)
    /// Downloads a results page. Tests replace it, so nothing leaves the Mac.
    var load: @Sendable (URL) async throws -> String = { url in
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, _) = try await WebTools.download(request)
        return String(decoding: data, as: UTF8.self)
    }

    func search(_ query: String) async throws -> [WebTools.SearchResult] {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        for attempt in 0..<2 {
            switch WebTools.readDuckDuckGo(try await load(c.url!)) {
            case .results(let results): return results
            case .noResults: return []
            case .blocked: if attempt == 0 { try await Task.sleep(for: retryDelay) }
            }
        }
        throw WebTools.Failure.blocked
    }
}
