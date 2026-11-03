import Foundation
import SQLite3

/// History on disk as SQLite, so a visit writes one row instead of rewriting the whole history.
/// Writes go through a serial queue in the background; `flush` waits for them.
final class HistoryDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "lumen.history", qos: .utility)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(_ url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("CREATE TABLE IF NOT EXISTS visits (id TEXT PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL, date REAL NOT NULL, visits INTEGER NOT NULL)")
        exec("CREATE INDEX IF NOT EXISTS visits_date ON visits(date)")
    }

    deinit { sqlite3_close(db) }

    /// Newest first: a page of `limit` entries after the first `offset` ones.
    func load(limit: Int = .max, offset: Int = 0) -> [HistoryEntry] {
        rows("SELECT id, url, title, date, visits FROM visits ORDER BY date DESC LIMIT ? OFFSET ?", [min(limit, Int(Int32.max)), offset])
    }

    /// How many entries there are.
    func count() -> Int {
        queue.sync {
            var n = 0
            query("SELECT count(*) FROM visits", []) { n = Int(sqlite3_column_int64($0, 0)) }
            return n
        }
    }

    /// The entry for an address, if there is one.
    func entry(for url: URL) -> HistoryEntry? {
        queue.sync { rows("SELECT id, url, title, date, visits FROM visits WHERE url = ?", [url.absoluteString]).first }
    }

    func entries(_ ids: Set<UUID>) -> [HistoryEntry] {
        guard !ids.isEmpty else { return [] }
        return queue.sync { ids.flatMap { rows("SELECT id, url, title, date, visits FROM visits WHERE id = ?", [$0.uuidString]) } }
    }

    /// Entries older than `date` whose title or address has every word, newest first: the part of the history that
    /// isn't kept in memory.
    func search(_ words: [String], before date: Date, limit: Int) -> [HistoryEntry] {
        guard !words.isEmpty else { return [] }
        let like = words.map { _ in "(title || ' ' || url) LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        let patterns = words.map { "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%" }
        return queue.sync {
            rows("SELECT id, url, title, date, visits FROM visits WHERE date < ? AND \(like) ORDER BY date DESC LIMIT ?",
                 [date.timeIntervalSince1970] + patterns + [limit])
        }
    }

    private func rows(_ sql: String, _ values: [Any]) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        query(sql, values) { s in
            guard let idText = Self.text(s, 0), let id = UUID(uuidString: idText),
                  let urlText = Self.text(s, 1), let url = URL(string: urlText) else { return }
            out.append(HistoryEntry(id: id, url: url, title: Self.text(s, 2) ?? "",
                                    date: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                                    visits: Int(sqlite3_column_int64(s, 4))))
        }
        return out
    }

    var isEmpty: Bool {
        var empty = true
        query("SELECT 1 FROM visits LIMIT 1", []) { _ in empty = false }
        return empty
    }

    /// Inserts or replaces entries; an entry replaces any row with the same id or URL.
    func save(_ entries: [HistoryEntry]) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in
            transaction {
                for e in entries {
                    run("INSERT OR REPLACE INTO visits (id, url, title, date, visits) VALUES (?, ?, ?, ?, ?)",
                        [e.id.uuidString, e.url.absoluteString, e.title, e.date.timeIntervalSince1970, e.visits])
                }
            }
        }
    }

    /// Adds entries whose address isn't in the history yet; addresses already there keep their own row. Waits, and
    /// says whether it worked.
    func insertMissing(_ entries: [HistoryEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        return queue.sync {
            transaction {
                for e in entries {
                    run("INSERT OR IGNORE INTO visits (id, url, title, date, visits) VALUES (?, ?, ?, ?, ?)",
                        [e.id.uuidString, e.url.absoluteString, e.title, e.date.timeIntervalSince1970, e.visits])
                }
            }
            return !failed
        }
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        queue.async { [self] in
            transaction { for id in ids { run("DELETE FROM visits WHERE id = ?", [id.uuidString]) } }
        }
    }

    /// Clears everything, or what was visited since `date`. Waits until it's done, so nothing is left behind if Tacet quits.
    func clear(since date: Date?) {
        queue.sync {
            if let date { run("DELETE FROM visits WHERE date >= ?", [date.timeIntervalSince1970]) } else { run("DELETE FROM visits", []) }
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Waits for pending writes.
    func flush() { queue.sync {} }

    /// Folds the write-ahead log back into the database and empties it, so it doesn't keep growing.
    func checkpoint() { queue.sync { exec("PRAGMA wal_checkpoint(TRUNCATE)") } }

    // MARK: SQLite helpers

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    /// Runs the writes as one: if any of them fails, none of them is kept.
    private func transaction(_ body: () -> Void) {
        failed = false
        exec("BEGIN")
        body()
        if failed {
            exec("ROLLBACK")
            NSLog("Tacet: a database write failed and was undone: %@", String(cString: sqlite3_errmsg(db)))
        } else {
            exec("COMMIT")
        }
    }

    private func bind(_ stmt: OpaquePointer, _ values: [Any]) {
        for (i, v) in values.enumerated() {
            let n = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case let d as Double: sqlite3_bind_double(stmt, n, d)
            case let i as Int: sqlite3_bind_int64(stmt, n, Int64(i))
            default: sqlite3_bind_null(stmt, n)
            }
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

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }
}
