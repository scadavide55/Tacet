import Foundation
import SQLite3

/// What the pages you visited said, kept on this Mac only, so you can find a page by something it said rather than its
/// title or address: "that page about cutting an app's memory use". SQLite's full-text index; no AI, no network.
///
/// Never kept: private windows, pages with a password field, sites you exclude, and anything older than the time you
/// chose. Clearing history clears it too.
/// Every use of the database goes through one serial queue, which is what makes it safe to share.
final class PageText: @unchecked Sendable {
    static let shared = PageText(Paths.file("PageText.sqlite"))

    struct Hit: Identifiable {
        var id: String { url.absoluteString }
        let url: URL
        let title: String
        /// The matching passage, with the words found between \u{2} and \u{3}.
        let snippet: String
        let date: Date
        /// The Spaces it was read in.
        let spaces: [UUID]
    }

    /// The most text kept per page: enough for an article, without letting one huge page fill the disk.
    static let charLimit = 12_000

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "lumen.pagetext", qos: .utility)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        // unicode61 with diacritics removed: "perche" finds "perché".
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(url UNINDEXED, title, body, date UNINDEXED, space UNINDEXED, tokenize = 'unicode61 remove_diacritics 2')")
        // The full-text table can't index addresses, so finding a page's row by its address would read every row:
        // this small table points from each address to its row.
        exec("CREATE TABLE IF NOT EXISTS page_rows (url TEXT PRIMARY KEY, rid INTEGER NOT NULL) WITHOUT ROWID")
        queue.async { [self] in rebuildRowsIfNeeded() }
    }

    /// Fills the address table from the pages when they disagree: the first time, or after an older Tacet (which knows
    /// nothing of it) replaced or added pages. Checked once per launch, in the background.
    private func rebuildRowsIfNeeded() {
        var pages = 0, rows = 0, stale = 0, doubled = 0
        query("SELECT count(*) FROM pages", []) { pages = Int(sqlite3_column_int64($0, 0)) }
        query("SELECT count(*) FROM page_rows", []) { rows = Int(sqlite3_column_int64($0, 0)) }
        query("SELECT count(*) FROM page_rows WHERE rid NOT IN (SELECT rowid FROM pages)", []) { stale = Int(sqlite3_column_int64($0, 0)) }
        query("SELECT count(*) - count(DISTINCT url) FROM pages", []) { doubled = Int(sqlite3_column_int64($0, 0)) }
        guard pages != rows || stale > 0 || doubled > 0 else { return }
        transaction {
            // Keeps the newest row of an address kept twice, and drops the others.
            run("DELETE FROM pages WHERE rowid NOT IN (SELECT max(rowid) FROM pages GROUP BY url)", [])
            run("DELETE FROM page_rows", [])
            run("INSERT INTO page_rows (url, rid) SELECT url, rowid FROM pages", [])
        }
    }

    /// The row of an address, if it's kept.
    private func row(of url: String) -> Int64? {
        var rid: Int64?
        query("SELECT rid FROM page_rows WHERE url = ?", [url]) { rid = sqlite3_column_int64($0, 0) }
        return rid
    }

    private func delete(url: String) {
        guard let rid = row(of: url) else { return }
        run("DELETE FROM pages WHERE rowid = ?", [Int(rid)])
        run("DELETE FROM page_rows WHERE url = ?", [url])
    }

    deinit { sqlite3_close(db) }

    // MARK: Keeping

    /// Whether a page's text may be kept at all, before it's read.
    static func mayKeep(_ url: URL, isPrivate: Bool) -> Bool {
        let s = Settings.shared
        guard s.rememberPageText, !isPrivate, ["http", "https"].contains(url.scheme ?? ""), let host = url.host?.lowercased() else { return false }
        return !s.pageTextExcluded.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Replaces what's kept for the address. A page read in several Spaces belongs to all of them.
    func keep(url: URL, title: String, text: String, space: UUID?) {
        let body = String(text.prefix(Self.charLimit))
        guard body.count >= 80 else { return }
        let date = Date().timeIntervalSince1970
        queue.async { [self] in
            let address = url.absoluteString
            var spaces = Set<String>()
            if let rid = row(of: address) {
                query("SELECT space FROM pages WHERE rowid = ?", [Int(rid)]) { s in
                    spaces.formUnion((Self.text(s, 0) ?? "").split(separator: " ").map(String.init))
                }
            }
            if let space { spaces.insert(space.uuidString) }
            transaction {
                delete(url: address)
                run("INSERT INTO pages (url, title, body, date, space) VALUES (?, ?, ?, ?, ?)",
                    [address, title, body, date, spaces.sorted().joined(separator: " ")])
                run("INSERT OR REPLACE INTO page_rows (url, rid) VALUES (?, ?)", [address, Int(sqlite3_last_insert_rowid(db))])
            }
        }
    }

    // MARK: Finding

    /// Pages whose title or text has every word of the query (each word may be the start of a longer one), best first.
    func search(_ query: String, limit: Int = 30, space: UUID? = nil) async -> [Hit] {
        guard let match = Self.matchExpression(query) else { return [] }
        return await withCheckedContinuation { done in
            queue.async { [self] in
                var hits: [Hit] = []
                let sql = "SELECT url, title, snippet(pages, 2, char(2), char(3), '…', 14), date, space FROM pages WHERE pages MATCH ?"
                    + (space == nil ? "" : " AND instr(space, ?) > 0") + " ORDER BY bm25(pages, 0, 4, 1) LIMIT ?"
                var values: [Any] = [match]
                if let space { values.append(space.uuidString) }
                values.append(limit)
                self.query(sql, values) { s in
                    guard let u = Self.text(s, 0).flatMap(URL.init(string:)) else { return }
                    hits.append(Hit(url: u, title: Self.text(s, 1) ?? "", snippet: Self.text(s, 2) ?? "",
                                    date: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                                    spaces: (Self.text(s, 4) ?? "").split(separator: " ").compactMap { UUID(uuidString: String($0)) }))
                }
                done.resume(returning: hits)
            }
        }
    }

    /// "swift memoria" becomes `"swift"* "memoria"*`: every word, each as a prefix, quoted so nothing typed is read as
    /// search syntax.
    static func matchExpression(_ query: String) -> String? {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0 == "\"" }).map(String.init).filter { !$0.isEmpty }.prefix(12)
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }.joined(separator: " ")
    }

    // MARK: Forgetting

    /// Everything since the date, or everything when nil.
    func clear(since date: Date? = nil) {
        queue.async { [self] in
            if let date {
                run("DELETE FROM pages WHERE date >= ?", [date.timeIntervalSince1970])
                run("DELETE FROM page_rows WHERE rid NOT IN (SELECT rowid FROM pages)", [])
            } else {
                run("DELETE FROM pages", [])
                run("DELETE FROM page_rows", [])
            }
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Text older than the time it's kept for.
    func prune(keepingDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        queue.async { [self] in
            transaction {
                run("DELETE FROM pages WHERE date < ?", [cutoff])
                run("DELETE FROM page_rows WHERE rid NOT IN (SELECT rowid FROM pages)", [])
            }
        }
    }

    func forget(urls: [URL]) {
        guard !urls.isEmpty else { return }
        queue.async { [self] in transaction { for u in urls { delete(url: u.absoluteString) } } }
    }

    /// Everything kept from one site and its subdomains.
    func forget(site: String) {
        let site = site.lowercased()
        queue.async { [self] in
            var doomed: [String] = []
            query("SELECT url FROM page_rows", []) { s in
                if let raw = Self.text(s, 0), let host = URL(string: raw)?.host?.lowercased(), host == site || host.hasSuffix("." + site) {
                    doomed.append(raw)
                }
            }
            transaction { for u in doomed { delete(url: u) } }
        }
    }

    /// How many pages are kept.
    func count() async -> Int {
        await withCheckedContinuation { done in
            queue.async { [self] in
                var n = 0
                query("SELECT count(*) FROM pages", []) { n = Int(sqlite3_column_int64($0, 0)) }
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
            NSLog("Tacet: a database write failed and was undone: %@", String(cString: sqlite3_errmsg(db)))
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
            case let d as Double: sqlite3_bind_double(stmt, n, d)
            case let i as Int: sqlite3_bind_int64(stmt, n, Int64(i))
            default: sqlite3_bind_null(stmt, n)
            }
        }
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }
}
