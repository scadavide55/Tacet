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

    private init() {
        chats = (index.load() ?? []).sorted { $0.date > $1.date }
    }

    private func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    func save(_ chat: Saved) {
        let url = file(chat.summary.id)
        // Encoding a long chat with its pictures takes a moment, so it happens on the history's own queue.
        queue.async {
            var body: [String: Any] = ["transcript": chat.transcript]
            if let model = chat.model { body["model"] = model }
            if let data = try? JSONEncoder().encode(chat.messages), let messages = try? JSONSerialization.jsonObject(with: data) {
                body["messages"] = messages
            }
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
        chats.removeAll { $0.id == chat.summary.id }
        chats.insert(chat.summary, at: 0)
        // Written at once, so a chat saved just before quitting stays listed.
        index.saveNow(chats)
    }

    func load(_ summary: Summary) -> Saved? {
        guard let data = try? Data(contentsOf: file(summary.id)),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let messagesData = (body["messages"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let messages = messagesData.flatMap { try? JSONDecoder().decode([SavedMessage].self, from: $0) } ?? []
        return Saved(summary: summary, messages: messages, transcript: body["transcript"] as? [[String: Any]] ?? [],
                     model: body["model"] as? String)
    }

    /// Waits for chats still being written, before Tacet quits.
    func flush() { queue.sync {} }

    func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        index.saveNow(chats)
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
}
