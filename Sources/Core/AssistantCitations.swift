import Foundation

/// Checks the links in a reply against what the assistant actually saw: pages it read, search results, and addresses
/// anywhere else in the conversation. A model can write a plausible address it never opened, and a reader trusts a
/// linked source, so links the assistant didn't see are shown as such.
enum AssistantCitations {
    /// The http and https links in a reply, from Markdown links, autolinks and bare addresses, in order and without
    /// repeats. Code isn't checked: it isn't shown as a link.
    static func links(in reply: String) -> [String] {
        var text = reply
        for pattern in [#"(?s)```.*?(```|$)"#, #"(?s)~~~.*?(~~~|$)"#, #"`[^`\n]*`"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        var seen = Set<String>()
        return addresses(in: text).filter { seen.insert($0).inserted }
    }

    /// Every address in some text. One pattern covers Markdown links too: the address in `[title](address)` ends at
    /// the closing parenthesis, which is trimmed like any other unbalanced one.
    static func addresses(in text: String) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { trimmed(ns.substring(with: $0.range)) }
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?://|www\.)[^\s<>"'`\[\]{}|\\^«»“”‘’]+"#)

    /// Drops what ends a sentence or Markdown around an address: punctuation, emphasis, and a closing parenthesis or
    /// bracket that has no opening one in the address (Wikipedia's `Foo_(bar)` keeps its own).
    static func trimmed(_ address: String) -> String {
        var s = Substring(address)
        while let last = s.last {
            if ".,;:!?*_~…".contains(last) {
                s = s.dropLast()
            } else if last == ")", s.filter({ $0 == ")" }).count > s.filter({ $0 == "(" }).count {
                s = s.dropLast()
            } else {
                break
            }
        }
        return String(s)
    }

    /// One form for addresses that lead to the same page: no scheme, no leading `www.`, no fragment, no trailing
    /// slash, no default port and no tracking parameters, with a click-tracking redirect replaced by its target.
    /// Nil for anything that isn't an http or https address.
    static func normalize(_ address: String) -> String? {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("www.") { s = "http://" + s }
        guard let parsed = URL(string: s) ?? s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
        let url = URLCleaner.unwrap(parsed) ?? URLCleaner.clean(parsed) ?? parsed
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), var host = c.host?.lowercased(),
              !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasSuffix(".") { host.removeLast() }
        var out = host
        if let port = c.port, port != 80, port != 443 { out += ":\(port)" }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        out += path
        if let query = c.query, !query.isEmpty { out += "?" + query }
        return out
    }

    /// The normalised links of `reply` that appear neither in `conversation` (the text of the user's messages, the
    /// attached page, tool results and Anthropic's own search and fetch results) nor among `read`.
    static func unverified(in reply: String, conversation: String, read: [URL]) -> Set<String> {
        let cited = links(in: reply).compactMap(normalize)
        guard !cited.isEmpty else { return [] }
        var known = Set(addresses(in: conversation).compactMap(normalize))
        for url in read { if let n = normalize(url.absoluteString) { known.insert(n) } }
        return Set(cited.filter { !known.contains($0) })
    }

    /// The same, for a transcript in the provider's own format.
    static func unverified(in reply: String, transcript: [[String: Any]], read: [URL]) -> Set<String> {
        unverified(in: reply, conversation: WebTools.conversationText(transcript), read: read)
    }

    /// Whether a link shown in a reply is one of its unverified ones.
    static func isUnverified(_ url: URL, in unverified: Set<String>) -> Bool {
        !unverified.isEmpty && normalize(url.absoluteString).map(unverified.contains) == true
    }

    /// The note under a deep research report with links the assistant didn't read.
    static func researchNote(_ count: Int) -> String {
        count == 1 ? L("1 link in this report wasn't among the pages the assistant read.")
            : String(format: L("%d links in this report weren't among the pages the assistant read."), count)
    }
}

extension AssistantChat {
    /// Marks the links in the finished reply that the assistant never saw. The matching runs off the main thread:
    /// a deep research conversation can hold hundreds of thousands of characters of pages.
    @MainActor
    func checkCitations() async {
        guard let i = messages.indices.last, messages[i].role == .assistant, !messages[i].text.isEmpty else { return }
        let id = messages[i].id
        let reply = messages[i].text
        let conversation = WebTools.conversationText(transcript)
        let read = Array(fetched.keys) + messages[i].sources.map(\.url) + [sentPageURL].compactMap { $0 }
        let found = await Task.detached(priority: .userInitiated) {
            AssistantCitations.unverified(in: reply, conversation: conversation, read: read)
        }.value
        guard let n = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[n].unverified = found
        if messages[n].research, !found.isEmpty {
            messages[n].activity.append(AssistantCitations.researchNote(found.count))
        }
    }
}
