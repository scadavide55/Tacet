import AppKit
import Observation

/// Past conversations with the assistant, saved on this Mac only. Chats in private windows are never saved.
@Observable
final class AssistantHistory {
    static let shared = AssistantHistory()

    struct Summary: Codable, Identifiable, Equatable {
        let id: UUID
        var title: String
        var date: Date
        var provider: String
        /// Kept at the top of the list. Since 1.8; nil (not pinned) in chats saved earlier and in chats never pinned.
        var pinned: Bool?
    }

    /// A saved message, with images as JPEG.
    struct SavedMessage: Codable {
        var user: Bool
        var text: String
        var images: [Data]
        var pageTitle: String?
        var quote: String?
        var activity: [String]
        var links: [SavedLink]
        var sources: [SavedLink]
        var error: String?
        /// Since 1.8; nil in chats saved earlier, whose `activity` held the steps as text.
        var steps: [AssistantStep]?
        var research: Bool?
        var started: Date?
        var finished: Date?
        /// Normalised links the assistant hadn't read, since 1.8; nil in older chats and when every link was checked.
        var unverified: [String]? = nil
        /// Nil in chats saved before they existed: tabs attached with `@`, and the tokens an answer used.
        var tabTitles: [String]?
        var usage: AIClient.Usage?
    }

    struct SavedLink: Codable {
        var url: URL
        var title: String
    }

    struct Saved {
        var summary: Summary
        var messages: [SavedMessage]
        /// The conversation in the provider's format, as JSON.
        var transcript: [[String: Any]]
        var model: String?
    }

    private(set) var chats: [Summary] = []
    @ObservationIgnored private let folder = Paths.folder("Assistant")
    @ObservationIgnored private let index = StoredFile<[Summary]>("Assistant/index.json")
    @ObservationIgnored private let queue = DispatchQueue(label: "lumen.assistant-history", qos: .utility)
    @ObservationIgnored private let search = AssistantSearch.shared

    private init() {
        chats = (index.load() ?? []).sorted { $0.date > $1.date }
        // Chats saved before the search index existed are added to it once, in the background.
        search.sync(with: chats.map { ($0.id, $0.title) })
    }

    private func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    /// Pinned chats first, then the others; newest first in each.
    var ordered: [Summary] { Self.ordered(chats) }

    static func ordered(_ chats: [Summary]) -> [Summary] {
        let sorted = chats.sorted { $0.date > $1.date }
        return sorted.filter { $0.pinned == true } + sorted.filter { $0.pinned != true }
    }

    /// The chats a search shows: those whose title has the words typed, and those the full-text index found.
    static func matching(_ chats: [Summary], query: String, found: [UUID: String]) -> [Summary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ordered(chats) }
        return ordered(chats.filter { $0.title.localizedCaseInsensitiveContains(q) || found[$0.id] != nil })
    }

    func save(_ chat: Saved) {
        var summary = chat.summary
        // The chat saves itself after each answer without knowing it was pinned; it stays pinned.
        if summary.pinned == nil { summary.pinned = chats.first { $0.id == summary.id }?.pinned }
        let url = file(summary.id)
        // Encoding a long chat with its pictures takes a moment, so it happens on the history's own queue.
        queue.async {
            guard let data = Self.fileData(chat) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
        search.index(id: summary.id, title: summary.title, messages: chat.messages)
        chats.removeAll { $0.id == summary.id }
        chats.insert(summary, at: 0)
        // Written at once, so a chat saved just before quitting stays listed.
        index.saveNow(chats)
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].pinned = pinned ? true : nil
        index.saveNow(chats)
    }

    func load(_ summary: Summary) -> Saved? {
        guard let data = try? Data(contentsOf: file(summary.id)) else { return nil }
        let c = Self.contents(of: data)
        guard c.valid else { return nil }
        return Saved(summary: summary, messages: c.messages, transcript: c.transcript, model: c.model)
    }

    /// A chat's file: the transcript in the provider's format as it was, with the messages as shown.
    static func fileData(_ chat: Saved) -> Data? {
        var body: [String: Any] = ["transcript": chat.transcript]
        if let model = chat.model { body["model"] = model }
        if let data = try? JSONEncoder().encode(chat.messages), let messages = try? JSONSerialization.jsonObject(with: data) {
            body["messages"] = messages
        }
        guard JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// What a chat's file holds; `valid` is false when it isn't a chat file at all.
    static func contents(of data: Data) -> (valid: Bool, messages: [SavedMessage], transcript: [[String: Any]], model: String?) {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, [], [], nil) }
        let messagesData = (body["messages"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let messages = messagesData.flatMap { try? JSONDecoder().decode([SavedMessage].self, from: $0) } ?? []
        return (true, messages, body["transcript"] as? [[String: Any]] ?? [], body["model"] as? String)
    }

    /// Waits for chats still being written, before Tacet quits.
    func flush() { queue.sync {} }

    func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        index.saveNow(chats)
        search.remove(id)
        let url = file(id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Deletes the chats last used since `date`, or all of them.
    func clear(since date: Date? = nil) {
        for c in chats where date == nil || c.date >= date! { delete(c.id) }
    }

    /// A title from the first thing the user asked.
    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 70 ? String(t.prefix(70)) + "…" : t
    }

    // MARK: Export

    /// The chat as a Markdown document: its title and date, each message under who said it, then every page it linked
    /// to or drew on, once each.
    static func markdown(_ saved: Saved) -> String {
        let title = saved.summary.title.isEmpty ? L("Untitled chat") : saved.summary.title
        var out = "# " + title + "\n\n" + saved.summary.date.formatted(date: .long, time: .shortened) + "\n"
        for m in saved.messages {
            out += "\n**" + (m.user ? L("You") : L("Tacet Assistant")) + ":**\n\n"
            if let page = m.pageTitle, !page.isEmpty { out += "_" + L("Page") + ": " + page + "_\n\n" }
            if let quote = m.quote, !quote.isEmpty {
                out += quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            }
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out += text + "\n" }
            if let error = m.error, !error.isEmpty { out += "\n_" + error + "_\n" }
        }
        var seen = Set<URL>()
        let links = saved.messages.flatMap { $0.links + $0.sources }.filter { seen.insert($0.url).inserted }
        if !links.isEmpty {
            out += "\n---\n\n## " + L("Sources") + "\n\n"
            for l in links {
                let name = (l.title.isEmpty ? l.url.absoluteString : l.title)
                    .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                out += "- [" + name + "](" + l.url.absoluteString + ")\n"
            }
        }
        return out
    }
}
