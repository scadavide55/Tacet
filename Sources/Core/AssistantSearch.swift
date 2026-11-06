import Foundation
import SQLite3

/// What was said in the saved assistant chats, so a chat can be found by something in it and not only by its title:
/// "the chat where it explained WAL mode". SQLite's full-text index, on this Mac only; no AI, no network.
///
/// It holds only chats that are saved, so never anything from a private window. Deleting a chat removes it here too,
/// and the index is rebuilt from the saved chats whenever the two disagree: the first time (chats saved before the index
/// existed), after a restore from a backup, or if the index file is lost.
/// Every use of the database goes through one serial queue, which is what makes it safe to share.
final class AssistantSearch: @unchecked Sendable {
    static let shared: AssistantSearch = {
        let folder = Paths.folder("Assistant")
        return AssistantSearch(database: folder.appendingPathComponent("Search.sqlite"), chats: folder)
    }()

    struct Hit: Equatable {
        let id: UUID
        /// The matching passage of the chat, with the words found between \u{2} and \u{3}; no marks when only the title
        /// matched.
        let snippet: String
    }

    /// The most text kept per chat: a long Deep research answer fits, a chat of hundreds of turns doesn't fill the disk.
    static let charLimit = 100_000

    private var db: OpaquePointer?
    /// The folder of saved chats, one `<id>.json` each, read when the index has to be rebuilt.
    private let folder: URL
    private let queue = DispatchQueue(label: "lumen.assistant-search", qos: .utility)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Paths are given, rather than taken from the data folder, so the tests never touch real chats.
    init(database: URL, chats folder: URL) {
        self.folder = folder
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 3000)
        // Deleted chats are overwritten in the file rather than left in its free pages: what was deleted is gone.
        exec("PRAGMA secure_delete=ON")
        // unicode61 with diacritics removed: "perche" finds "perché".
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS chats USING fts5(id UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2')")
    }

    deinit { sqlite3_close(db) }

    // MARK: Keeping

    /// The searchable text of a chat: what was asked and answered, the pages and passages it was about, the titles of its
    /// sources.
    static func body(_ messages: [AssistantHistory.SavedMessage]) -> String {
        var parts: [String] = []
        for m in messages {
            if let page = m.pageTitle, !page.isEmpty { parts.append(page) }
            if let quote = m.quote, !quote.isEmpty { parts.append(quote) }
            if !m.text.isEmpty { parts.append(m.text) }
            parts += (m.links + m.sources).map(\.title).filter { !$0.isEmpty }
        }
        return String(parts.joined(separator: "\n").prefix(charLimit))
    }

    /// Replaces what's kept for the chat.
    func index(id: UUID, title: String, messages: [AssistantHistory.SavedMessage]) {
        queue.async { [self] in
            let text = Self.body(messages)
            transaction { put(id: id, title: title, body: text) }
        }
    }

    func remove(_ id: UUID) {
        queue.async { [self] in run("DELETE FROM chats WHERE id = ?", [id.uuidString]) }
    }

    func removeAll() {
        queue.async { [self] in run("DELETE FROM chats", []) }
    }

    /// Makes the index hold exactly the saved chats: chats it lacks are read from their files, chats no longer saved
    /// are dropped. Nothing to do, and nothing read, when they already agree, which is every launch but the first.
    func sync(with chats: [(id: UUID, title: String)]) {
        queue.async { [self] in
            var indexed: [String] = []
            query("SELECT id FROM chats", []) { indexed.append(Self.text($0, 0) ?? "") }
            let saved = Dictionary(chats.map { ($0.id.uuidString, $0.title) }, uniquingKeysWith: { a, _ in a })
            let have = Set(indexed)
            guard have != Set(saved.keys) || indexed.count != have.count else { return }
            transaction {
                // A chat in the index twice (which shouldn't happen) is read again, once.
                var counts: [String: Int] = [:]
                for id in indexed { counts[id, default: 0] += 1 }
                let doubled = Set(counts.filter { $0.value > 1 }.keys)
                for id in have where saved[id] == nil || doubled.contains(id) { run("DELETE FROM chats WHERE id = ?", [id]) }
                for (id, title) in saved where !have.contains(id) || doubled.contains(id) {
                    autoreleasepool {
                        let file = folder.appendingPathComponent(id + ".json")
                        // A chat whose file can't be read is still kept by its title, so the next launch doesn't try again.
                        let messages = (try? Data(contentsOf: file)).map { AssistantHistory.contents(of: $0).messages } ?? []
                        put(id: UUID(uuidString: id), title: title, body: Self.body(messages))
                    }
                }
            }
        }
    }

    private func put(id: UUID?, title: String, body: String) {
        guard let id else { return }
        run("DELETE FROM chats WHERE id = ?", [id.uuidString])
        run("INSERT INTO chats (id, title, body) VALUES (?, ?, ?)", [id.uuidString, title, body])
    }

    // MARK: Finding

    /// Chats whose title or text has every word of the query (each word may be the start of a longer one), best first.
    func search(_ query: String, limit: Int = 200) async -> [Hit] {
        guard let match = PageText.matchExpression(query) else { return [] }
        return await withCheckedContinuation { done in
            queue.async { [self] in
                var hits: [Hit] = []
                self.query("SELECT id, snippet(chats, 2, char(2), char(3), '…', 14) FROM chats WHERE chats MATCH ? ORDER BY bm25(chats, 0, 4, 1) LIMIT ?",
                           [match, limit]) { s in
                    guard let id = Self.text(s, 0).flatMap(UUID.init(uuidString:)) else { return }
                    hits.append(Hit(id: id, snippet: Self.text(s, 1) ?? ""))
                }
                done.resume(returning: hits)
            }
        }
    }

    /// How many chats are kept.
    func count() async -> Int {
        await withCheckedContinuation { done in
            queue.async { [self] in
                var n = 0
                query("SELECT count(*) FROM chats", []) { n = Int(sqlite3_column_int64($0, 0)) }
                done.resume(returning: n)
            }
        }
    }

    /// Waits for writes still under way.
    func flush() { queue.sync {} }

    // MARK: SQLite

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    /// Runs the writes as one: if any of them fails, none of them is kept.
    private func transaction(_ body: () -> Void) {
        failed = false
        exec("BEGIN")
        body()
        if failed {
            exec("ROLLBACK")
            NSLog("Tacet: a chat search index write failed and was undone: %@", String(cString: sqlite3_errmsg(db)))
        } else {
            exec("COMMIT")
        }
    }

    /// Set when a write in the current transaction fails.
    private var failed = false

    private func run(_ sql: String, _ values: [Any]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { failed = true; return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        if sqlite3_step(stmt) != SQLITE_DONE { failed = true }
    }

    private func query(_ sql: String, _ values: [Any], _ row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func bind(_ stmt: OpaquePointer, _ values: [Any]) {
        for (i, v) in values.enumerated() {
            let n = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case let i as Int: sqlite3_bind_int64(stmt, n, Int64(i))
            default: sqlite3_bind_null(stmt, n)
            }
        }
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }
}
