import Foundation

/// Completes an address in the command bar as you type it, from sites you visit often: "gi" becomes "github.com".
/// Only from the start of an address (never in the middle of a word), only sites visited at least twice, and nothing
/// is fetched: it works from history already on this Mac.
enum InlineCompletion {
    /// How often a site needs to have been visited before it's offered.
    static let minVisits = 2

    /// Visits per site and per page, from history entries, without "https://" or "www.".
    static func candidates(_ entries: [HistoryEntry]) -> [String: Int] {
        var out: [String: Int] = [:]
        for e in entries {
            guard let host = e.url.host?.lowercased(), ["http", "https"].contains(e.url.scheme?.lowercased() ?? "") else { continue }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            out[bare, default: 0] += e.visits
            let path = e.url.path
            if path.count > 1 { out[bare + path.lowercased(), default: 0] += e.visits }
        }
        return out
    }

    /// What `typed` completes to, or nil. A host is completed while you type its name; once you type a "/", pages
    /// on that site are completed instead.
    static func complete(_ typed: String, candidates: [String: Int]) -> String? {
        var t = typed.lowercased()
        guard !t.isEmpty, !t.contains(" "), t.count <= 200 else { return nil }
        for prefix in ["https://", "http://"] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        guard !t.isEmpty else { return nil }
        let wantsPath = t.contains("/")
        let best = candidates
            .filter { key, visits in
                visits >= minVisits && key.count > t.count && key.hasPrefix(t) && (wantsPath ? key.contains("/") : !key.contains("/"))
            }
            .max { a, b in a.value != b.value ? a.value < b.value : a.key.count > b.key.count }
        return best?.key
    }

    /// The part a completion adds after what was typed, keeping what the user typed as they typed it.
    static func suffix(of completion: String, typed: String) -> String? {
        var t = typed.lowercased()
        for prefix in ["https://", "http://"] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        guard completion.hasPrefix(t), completion.count > t.count else { return nil }
        return String(completion.dropFirst(t.count))
    }
}
