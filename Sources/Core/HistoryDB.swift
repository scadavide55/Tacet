import Foundation
import SQLite3

/// History on disk as SQLite, so a visit writes one row instead of rewriting the whole history.
/// Writes go through a serial queue in the background; `flush` waits for them.
final class HistoryDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "lumen.history", qos: .utility)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The schema this Tacet writes. 1 added the full-text index on titles and addresses, and counts of typed visits.
    static let schemaVersion = 1
    /// Whether the full-text index is there; without it searches fall back to reading every row.
    private(set) var hasIndex = false

    init?(_ url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        // INSERT OR REPLACE removes the old row before adding the new one; with this on, that removal runs the
        // trigger that takes the old row out of the full-text index too.
        exec("PRAGMA recursive_triggers=ON")
        exec("CREATE TABLE IF NOT EXISTS visits (id TEXT PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL, date REAL NOT NULL, visits INTEGER NOT NULL)")
        exec("CREATE INDEX IF NOT EXISTS visits_date ON visits(date)")
        hasIndex = migrate()
        if hasIndex { queue.async { [self] in repairIndexIfNeeded() } }
    }

    /// Brings an older history up to `schemaVersion`, all at once or not at all: if any step fails, the history stays
    /// exactly as it was and searches read it the old way.
    private func migrate() -> Bool {
        var version = 0
        query("PRAGMA user_version", []) { version = Int(sqlite3_column_int64($0, 0)) }
        if version >= Self.schemaVersion { return tableExists("visits_fts") }
        var hasTyped = false
        query("PRAGMA table_info(visits)", []) { if Self.text($0, 1) == "typed" { hasTyped = true } }
        transaction {
            if !hasTyped { run("ALTER TABLE visits ADD COLUMN typed INTEGER NOT NULL DEFAULT 0", []) }
            // The index reads titles and addresses from `visits` itself, so nothing is stored twice. unicode61 with
            // diacritics removed, as for page text: "perche" finds "perché"; the prefix tables make typing fast.
            run("CREATE VIRTUAL TABLE IF NOT EXISTS visits_fts USING fts5(title, url, content='visits', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2', prefix='2 3')", [])
            run("CREATE TRIGGER IF NOT EXISTS visits_fts_add AFTER INSERT ON visits BEGIN INSERT INTO visits_fts(rowid, title, url) VALUES (new.rowid, new.title, new.url); END", [])
            run("CREATE TRIGGER IF NOT EXISTS visits_fts_remove AFTER DELETE ON visits BEGIN INSERT INTO visits_fts(visits_fts, rowid, title, url) VALUES ('delete', old.rowid, old.title, old.url); END", [])
            run("CREATE TRIGGER IF NOT EXISTS visits_fts_change AFTER UPDATE OF title, url ON visits BEGIN INSERT INTO visits_fts(visits_fts, rowid, title, url) VALUES ('delete', old.rowid, old.title, old.url); INSERT INTO visits_fts(rowid, title, url) VALUES (new.rowid, new.title, new.url); END", [])
            run("INSERT INTO visits_fts(visits_fts) VALUES ('rebuild')", [])
            run("PRAGMA user_version = \(Self.schemaVersion)", [])
        }
        return !failed && tableExists("visits_fts")
    }

    /// An older Tacet writes without `recursive_triggers`, so a page it replaced can stay in the index: when the
    /// index and the history disagree on how many pages there are, the index is built again. Once per launch, in the
    /// background.
    private func repairIndexIfNeeded() {
        var rows = 0, indexed = 0
        query("SELECT count(*) FROM visits", []) { rows = Int(sqlite3_column_int64($0, 0)) }
        query("SELECT count(*) FROM visits_fts_docsize", []) { indexed = Int(sqlite3_column_int64($0, 0)) }
        guard rows != indexed else { return }
        transaction { run("INSERT INTO visits_fts(visits_fts) VALUES ('rebuild')", []) }
    }

    private func tableExists(_ name: String) -> Bool {
        var found = false
        query("SELECT 1 FROM sqlite_master WHERE name = ?", [name]) { _ in found = true }
        return found
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

    /// Entries whose title or address has every word of the query (each word may be the start of a longer one), from
    /// the whole history. Best first by frecency: how often and how recently a page was visited, typed visits counting
    /// more than followed links, and a page whose site starts with the first word coming before the rest. With
    /// `newestFirst`, the newest come first instead. Waits for writes already queued, so a visit just made is found.
    func search(_ query: String, limit: Int, newestFirst: Bool = false, now: Date = Date()) -> [HistoryEntry] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).prefix(12)
        guard let first = words.first, limit > 0 else { return [] }
        var values: [Any] = []
        let filter: String
        if hasIndex, let match = PageText.matchExpression(query) {
            filter = "rowid IN (SELECT rowid FROM visits_fts WHERE visits_fts MATCH ?)"
            values.append(match)
        } else {
            filter = words.map { _ in "(title || ' ' || url) LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            values += words.map { "%" + Self.escapeLike($0) + "%" }
        }
        let order: String
        if newestFirst {
            order = "date DESC"
        } else {
            // Visits weigh by age as in Firefox's frecency: the last four days count ten times more than three months ago.
            let age = "(? - date)"
            let recency = "CASE WHEN \(age) < 345600 THEN 100 WHEN \(age) < 1209600 THEN 70 WHEN \(age) < 2678400 THEN 50 WHEN \(age) < 7776000 THEN 30 ELSE 10 END"
            let host = Self.escapeLike(first)
            let siteMatch = ["http://", "https://", "http://www.", "https://www."].map { _ in "url LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            // The site bonus outweighs any number of visits: typing "git" means github.com before a busy page about it.
            order = "(CASE WHEN \(siteMatch) THEN 1 ELSE 0 END) DESC, (visits + 2.0 * typed) * \(recency) DESC, date DESC"
            values += ["http://", "https://", "http://www.", "https://www."].map { $0 + host + "%" }
            values += Array(repeating: now.timeIntervalSince1970, count: 4)
        }
        values.append(min(limit, Int(Int32.max)))
        let typed = hasIndex ? "typed" : "0 AS typed"
        return queue.sync {
            rows("SELECT id, url, title, date, visits FROM (SELECT id, url, title, date, visits, \(typed) FROM visits WHERE \(filter)) ORDER BY \(order) LIMIT ?", values)
        }
    }

    /// `search` away from the caller's thread, so typing on the main thread never waits for it.
    func searchInBackground(_ query: String, limit: Int, newestFirst: Bool = false) async -> [HistoryEntry] {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                done.resume(returning: search(query, limit: limit, newestFirst: newestFirst))
            }
        }
    }

    /// How many visits to an address were typed or chosen rather than followed from a link.
    func typedVisits(_ url: URL) -> Int {
        guard hasIndex else { return 0 }
        return queue.sync {
            var n = 0
            query("SELECT typed FROM visits WHERE url = ?", [url.absoluteString]) { n = Int(sqlite3_column_int64($0, 0)) }
            return n
        }
    }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
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

    /// Inserts or replaces entries; an entry replaces any row with the same id or URL, keeping its count of typed
    /// visits. `typed` adds one typed visit to each.
    func save(_ entries: [HistoryEntry], typed: Bool = false) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in
            transaction {
                for e in entries {
                    if hasIndex {
                        run("INSERT OR REPLACE INTO visits (id, url, title, date, visits, typed) VALUES (?, ?, ?, ?, ?, coalesce((SELECT typed FROM visits WHERE url = ?), 0) + ?)",
                            [e.id.uuidString, e.url.absoluteString, e.title, e.date.timeIntervalSince1970, e.visits, e.url.absoluteString, typed ? 1 : 0])
                    } else {
                        run("INSERT OR REPLACE INTO visits (id, url, title, date, visits) VALUES (?, ?, ?, ?, ?)",
                            [e.id.uuidString, e.url.absoluteString, e.title, e.date.timeIntervalSince1970, e.visits])
                    }
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
