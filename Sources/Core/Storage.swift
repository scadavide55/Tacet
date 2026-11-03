import AppKit
import SwiftUI
import WebKit

// MARK: - Files

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Still "Lumen", Tacet's former name, so everything saved before the rename stays where it is.
        var url = base.appendingPathComponent("Lumen", isDirectory: true)
        // Installed web apps keep their own history and settings apart from the browser.
        if WebApp.isActive { url = url.appendingPathComponent("WebApps/" + (Bundle.main.bundleIdentifier ?? "app"), isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    static func folder(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Every StoredFile, so Tacet can write all pending changes before it quits.
enum StoredFiles {
    fileprivate static let all = NSHashTable<AnyObject>.weakObjects()
    fileprivate static let lock = NSLock()

    /// Writes every change still waiting for its delay. Called when Tacet quits, so nothing made just before is lost.
    static func flushAll() {
        lock.lock()
        let files = all.allObjects.compactMap { $0 as? Flushable }
        lock.unlock()
        files.forEach { $0.flush() }
    }
}

protocol Flushable: AnyObject { func flush() }

/// A document on disk, as JSON or a binary property list, with debounced background writes.
final class StoredFile<T: Codable>: Flushable {
    enum Format { case json, binaryPlist }

    let url: URL
    private let format: Format
    private var pending: DispatchWorkItem?
    /// The write waiting for its delay, run at once by `flush`.
    private var pendingWrite: (() -> Void)?
    private let queue = DispatchQueue(label: "lumen.storage", qos: .utility)

    init(_ name: String, format: Format = .json) {
        url = Paths.file(name)
        self.format = format
        register()
    }

    /// A file anywhere, for the tests.
    init(at url: URL, format: Format = .json) {
        self.url = url
        self.format = format
        register()
    }

    private func register() {
        StoredFiles.lock.lock()
        StoredFiles.all.add(self)
        StoredFiles.lock.unlock()
    }

    /// Writes a change still waiting for its delay, now.
    func flush() {
        pending?.cancel()
        pending = nil
        if let write = pendingWrite { queue.sync(execute: write) }
        pendingWrite = nil
    }

    func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        switch format {
        case .json:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try? decoder.decode(T.self, from: data)
        case .binaryPlist:
            return try? PropertyListDecoder().decode(T.self, from: data)
        }
    }

    func save(_ value: T, delay: TimeInterval = 1) {
        pending?.cancel()
        let write = { [url, format] in Self.write(value, to: url, format: format) }
        pendingWrite = write
        let item = DispatchWorkItem(block: write)
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Waits for a write already under way, so an older value can never land after this one.
    func saveNow(_ value: T) {
        pending?.cancel()
        pendingWrite = nil
        queue.sync { Self.write(value, to: url, format: format) }
    }

    func delete() {
        pending?.cancel()
        pendingWrite = nil
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    private static func write(_ value: T, to url: URL, format: Format) {
        let data: Data?
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            data = try? encoder.encode(value)
        case .binaryPlist:
            // Tab histories are raw bytes, which a binary plist stores as-is instead of as base64 text.
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            data = try? encoder.encode(value)
        }
        if let data { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Bookmarks

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    var added = Date()
}

@Observable
final class Bookmarks {
    static let shared = Bookmarks()
    private(set) var items: [Bookmark] {
        didSet { urls = Set(items.map(\.url)) }
    }
    /// For `contains`, which the address bar asks on every redraw.
    @ObservationIgnored private var urls: Set<URL>
    private let file = StoredFile<[Bookmark]>("bookmarks.json")

    private init() {
        let loaded = file.load() ?? []
        items = loaded
        urls = Set(loaded.map(\.url))
    }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return urls.contains(url)
    }

    func toggle(url: URL?, title: String) {
        guard let url else { return }
        if contains(url) { items.removeAll { $0.url == url } } else { items.append(Bookmark(title: title, url: url)) }
        persist()
    }

    func add(url: URL, title: String) {
        guard !contains(url) else { return }
        items.append(Bookmark(title: title, url: url))
        persist()
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Adds bookmarks from another browser, skipping URLs already saved. Returns how many were added.
    func importItems(_ list: [(String, URL)]) -> Int {
        var known = urls
        var new: [Bookmark] = []
        for (title, url) in list where known.insert(url).inserted {
            new.append(Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url))
        }
        guard !new.isEmpty else { return 0 }
        items += new
        persist()
        return new.count
    }

    /// Imports a Netscape bookmark file (the format Safari, Chrome and Firefox export).
    func importHTML(_ html: String) -> Int {
        let pattern = #"<A[^>]*HREF="([^"]+)"[^>]*>(.*?)</A>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return 0 }
        let ns = html as NSString
        var known = urls
        var new: [Bookmark] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            let title = Self.unescape(ns.substring(with: m.range(at: 2)))
            guard let url = URL(string: href), ["http", "https"].contains(url.scheme ?? ""), known.insert(url).inserted else { continue }
            new.append(Bookmark(title: title.isEmpty ? (url.host ?? href) : title, url: url))
        }
        items += new
        persist()
        return new.count
    }

    func exportHTML() -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        for b in items {
            let t = b.title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            out += "    <DT><A HREF=\"\(b.url.absoluteString)\" ADD_DATE=\"\(Int(b.added.timeIntervalSince1970))\">\(t)</A>\n"
        }
        return out + "</DL><p>\n"
    }

    private static func unescape(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persist() { file.save(items) }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var date: Date
    var visits: Int = 1
}

@Observable
final class History {
    static let shared = History()
    /// How many of the newest entries are kept in memory; older ones stay on disk, where searches still find them.
    static let memoryLimit = 5000
    /// The newest entries, newest first, one per URL.
    private(set) var entries: [HistoryEntry] {
        didSet { haystacks = nil }
    }
    /// Whether older entries are on disk, beyond `entries`.
    private(set) var hasOlder = false
    /// Lowercased "title url" per entry, built once and reused by every search until the history changes.
    @ObservationIgnored private var haystacks: [String]?
    private let db = HistoryDB(Paths.file("history.sqlite"))

    private init() {
        // History used to be one JSON file rewritten after every visit; it moves into the database once.
        let legacy = StoredFile<[HistoryEntry]>("history.json")
        if let db, FileManager.default.fileExists(atPath: legacy.url.path) {
            // A copy left by an older Tacet: what it has that the database doesn't comes in, newer rows stay. It's
            // deleted only once that worked (or if it can't be read at all).
            if let old = legacy.load() {
                if db.insertMissing(old) { legacy.delete() }
            } else {
                legacy.delete()
            }
        }
        entries = db?.load(limit: Self.memoryLimit) ?? []
        hasOlder = entries.count == Self.memoryLimit && (db?.count() ?? 0) > Self.memoryLimit
    }

    func record(url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme ?? "") else { return }
        var entry = HistoryEntry(url: url, title: title, date: Date())
        if let i = entries.firstIndex(where: { $0.url == url }) {
            entry = entries.remove(at: i)
        } else if hasOlder, let old = db?.entry(for: url) {
            // An old page visited again: its count carries on.
            entry = old
        } else {
            entry.visits = 0
        }
        entry.date = Date()
        entry.visits += 1
        if !title.isEmpty { entry.title = title }
        entries.insert(entry, at: 0)
        db?.save([entry])
        // Memory keeps the newest; the rest is on disk.
        if entries.count > Self.memoryLimit + 500 {
            entries.removeLast(entries.count - Self.memoryLimit)
            hasOlder = true
        }
    }

    /// Another page of older entries, for the History list.
    func loadOlder() {
        guard hasOlder, let more = db?.load(limit: Self.memoryLimit, offset: entries.count) else { return }
        let known = Set(entries.map(\.url))
        entries += more.filter { !known.contains($0.url) }
        hasOlder = more.count == Self.memoryLimit
    }

    /// Merges history from another browser, keeping the newest visit per URL. Returns how many entries were new.
    func importEntries(_ list: [HistoryEntry]) -> Int {
        guard !list.isEmpty else { return 0 }
        var byURL = Dictionary(entries.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var added = 0
        var changed: Set<URL> = []
        for e in list where ["http", "https"].contains(e.url.scheme ?? "") {
            if var old = byURL[e.url] {
                old.visits += e.visits
                if e.date > old.date { old.date = e.date }
                if old.title.isEmpty { old.title = e.title }
                byURL[e.url] = old
            } else {
                byURL[e.url] = e
                added += 1
            }
            changed.insert(e.url)
        }
        var merged = byURL.values.sorted { $0.date > $1.date }
        // Only the imported rows are written; the rest of the history is already on disk.
        db?.save(changed.compactMap { byURL[$0] })
        // A big import stays on disk too; memory keeps the newest, as after any visit.
        if merged.count > Self.memoryLimit {
            merged.removeLast(merged.count - Self.memoryLimit)
            hasOlder = true
        }
        entries = merged
        return added
    }

    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, let i = entries.prefix(20).firstIndex(where: { $0.url == url }),
              entries[i].title != title else { return }
        entries[i].title = title
        db?.save([entries[i]])
    }

    func remove(_ ids: Set<UUID>) {
        // What those pages said goes with them; some may only be on disk.
        let inMemory = entries.filter { ids.contains($0.id) }
        let onDisk = ids.count > inMemory.count ? (db?.entries(ids.subtracting(inMemory.map(\.id))) ?? []) : []
        PageText.shared.forget(urls: (inMemory + onDisk).map(\.url))
        entries.removeAll { ids.contains($0.id) }
        db?.delete(ids)
    }

    func clear(since date: Date? = nil) {
        if let date { entries.removeAll { $0.date >= date } } else { entries.removeAll() }
        db?.clear(since: date)
        PageText.shared.clear(since: date)
        // The downloads list goes with it, as in Safari; the files stay.
        DownloadManager.shared.clearList(since: date)
    }

    /// Waits for history writes still in progress, before Tacet quits.
    func flush() {
        db?.flush()
        db?.checkpoint()
    }

    /// `search` on a background thread, so typing never waits for a large history.
    @MainActor
    func searchInBackground(_ query: String, limit: Int = 8) async -> [HistoryEntry] {
        let recent = await inBackground { entries, hay in History.search(query, entries: entries, haystacks: hay, limit: limit) }
        return recent.count >= limit ? recent : recent + (await older(query, limit: limit - recent.count, excluding: recent))
    }

    /// Matches among the entries kept only on disk.
    @MainActor
    private func older(_ query: String, limit: Int, excluding shown: [HistoryEntry]) async -> [HistoryEntry] {
        guard hasOlder, limit > 0, let db, let oldest = entries.last?.date else { return [] }
        let words = query.lowercased().split(separator: " ").map(String.init)
        let seen = Set(shown.map(\.url))
        let found = await Task.detached(priority: .userInitiated) { db.search(words, before: oldest, limit: limit) }.value
        return found.filter { !seen.contains($0.url) }
    }

    /// Entries containing every word of `query`, newest first, found on a background thread.
    @MainActor
    func filterInBackground(_ query: String, limit: Int = 500) async -> [HistoryEntry] {
        let recent = await inBackground { entries, hay in
            let words = query.lowercased().split(separator: " ").map(String.init)
            return Array(entries.indices.lazy.filter { i in words.allSatisfy { hay[i].contains($0) } }.prefix(limit).map { entries[$0] })
        }
        return recent.count >= limit ? recent : recent + (await older(query, limit: limit - recent.count, excluding: recent))
    }

    /// Runs `work` off the main thread with the history and its lowercase index, building the index if needed.
    /// The rest stays on the main thread, where the history changes.
    @MainActor
    private func inBackground(_ work: @escaping @Sendable ([HistoryEntry], [String]) -> [HistoryEntry]) async -> [HistoryEntry] {
        let entries = entries
        let cached = haystacks
        let (hits, built) = await Task.detached(priority: .userInitiated) {
            let hay = cached ?? History.haystacks(for: entries)
            return (work(entries, hay), hay)
        }.value
        // Keep the index only if the history didn't change while it was being built.
        if cached == nil, built.count == self.entries.count, self.entries.first?.id == entries.first?.id { haystacks = built }
        return hits
    }

    private static func haystacks(for entries: [HistoryEntry]) -> [String] {
        entries.map { ($0.title + " " + $0.url.absoluteString).lowercased() }
    }

    private static func search(_ query: String, entries: [HistoryEntry], haystacks: [String], limit: Int) -> [HistoryEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let now = Date()
        return entries.indices.lazy
            .filter { i in words.allSatisfy { haystacks[i].contains($0) } }
            .map { entries[$0] }
            .prefix(200)
            .map { e -> (HistoryEntry, Double) in
                let age = now.timeIntervalSince(e.date) / 86_400
                var score = Double(e.visits) / (1 + age)
                if e.url.host?.lowercased().hasPrefix(words[0]) == true || e.url.host?.lowercased().hasPrefix("www." + words[0]) == true { score += 10 }
                return (e, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

}

// MARK: - Session

struct TabSnapshot: Codable {
    var url: URL?
    var title: String
    var pinned: Bool
    var state: Data?
    var group: UUID?
    var lastActive: Date?
    /// Where a pinned tab was pinned, to go back to.
    var home: URL?
}

struct WindowSnapshot: Codable {
    var tabs: [TabSnapshot]
    var selected: Int
    var groups: [TabGroup]?
    var profile: UUID?
    /// Index of the tab shown beside the selected one.
    var split: Int?
    /// The Space the window was showing.
    var space: UUID?
}

struct TabGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var collapsed = false
    var color = 0
    /// Set for groups Tacet made by site; nil for groups you made.
    var site: String?

    static let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .yellow, .gray]
    var tint: Color { Self.colors[color % Self.colors.count] }
}

final class Session {
    static let shared = Session()
    private let file = StoredFile<[WindowSnapshot]>("session.plist", format: .binaryPlist)
    private var pending: [WindowSnapshot] = []
    private var pendingSave: DispatchWorkItem?

    private init() {
        // Sessions used to be JSON, where each tab's history took a third more space as base64.
        let legacy = StoredFile<[WindowSnapshot]>("session.json")
        if let old = legacy.load() {
            file.saveNow(old)
            legacy.delete()
        }
        if Settings.shared.restoreSession && !WebApp.isActive { pending = file.load() ?? [] }
    }

    func takePending() -> WindowSnapshot? { pending.isEmpty ? nil : pending.removeFirst() }

    /// A closed window to open again: the next new window takes it, as it would a saved one at launch.
    func reopen(_ snap: WindowSnapshot) { pending.insert(snap, at: 0) }

    /// Whether saved windows are still waiting to be reopened at launch.
    var hasPendingWindows: Bool { !pending.isEmpty }

    /// The windows to save: the open ones, and saved ones that haven't reopened yet, which would be lost otherwise.
    private func snapshots() -> [WindowSnapshot] {
        WindowRegistry.shared.browsers.filter { !$0.isPrivate && !$0.isClosed }.map { $0.snapshot() } + pending
    }

    /// Waits for things to settle before taking snapshots: reading every tab's back/forward
    /// history is too costly to repeat on each navigation.
    func scheduleSave() {
        guard !WebApp.isActive else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            let snaps = self.snapshots()
            guard !snaps.isEmpty else { return }
            self.file.save(snaps, delay: 0)
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    func saveNow() {
        guard !WebApp.isActive else { return }
        pendingSave?.cancel()
        pendingSave = nil
        let snaps = snapshots()
        guard !snaps.isEmpty else { return }
        file.saveNow(snaps)
    }
}

// MARK: - Window registry

final class WindowRegistry {
    static let shared = WindowRegistry()
    private let table = NSHashTable<BrowserState>.weakObjects()
    weak var lastFocused: BrowserState?
    private(set) var pendingURLs: [URL] = []

    /// Open windows; a closed window's state that hasn't gone away yet isn't one.
    var browsers: [BrowserState] { table.allObjects.filter { !$0.isClosed } }

    func add(_ b: BrowserState) { table.add(b) }

    /// Windows closed since Tacet opened, newest last, for History › Reopen Closed Window.
    private(set) var closedWindows: [WindowSnapshot] = []

    func rememberClosed(_ snap: WindowSnapshot) {
        closedWindows.append(snap)
        if closedWindows.count > 10 { closedWindows.removeFirst() }
    }

    /// The last window closed, without its Space when that Space is open in another window now.
    func takeClosedWindow() -> WindowSnapshot? {
        guard var snap = closedWindows.popLast() else { return nil }
        if let space = snap.space, browsers.contains(where: { $0.spaceID == space }) { snap.space = nil }
        return snap
    }

    func takePendingURLs() -> [URL] {
        defer { pendingURLs = [] }
        return pendingURLs
    }

    /// Opens a window; set by the first window's view, which can open windows.
    var openWindow: ((_ id: String, _ profile: UUID?) -> Void)?
    private var routed: [(url: URL, privately: Bool, profile: UUID?)] = []

    /// Opens a new private or profile window for a link an opening rule sends there.
    func openRouted(_ url: URL, privately: Bool, profile: UUID?) {
        routed.append((url, privately, profile))
        openWindow?(privately ? "private" : (profile == nil ? "main" : "profile"), profile)
    }

    /// The links waiting for a window like this one.
    func takeRouted(privately: Bool, profile: UUID?) -> [URL] {
        let mine = routed.filter { $0.privately == privately && (privately || $0.profile == profile) }
        routed.removeAll { $0.privately == privately && (privately || $0.profile == profile) }
        return mine.map(\.url)
    }

    /// Opens URLs in the frontmost normal window, or where an opening rule sends them. Returns false when no window
    /// exists yet.
    @discardableResult
    func open(_ urls: [URL]) -> Bool {
        let target = (lastFocused.flatMap { $0.isPrivate ? nil : $0 }) ?? browsers.first { !$0.isPrivate }
        guard let b = target else {
            pendingURLs += urls
            return false
        }
        for u in urls where !OpeningRules.route(u, from: b) { b.newTab(url: u) }
        b.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

// MARK: - Favicons

final class Favicons {
    static let shared = Favicons()
    /// Icons in memory; the cache lets go of them on its own when memory runs short.
    private let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()
    /// Hosts with no icon on disk, so lists that redraw don't hit the disk again for them.
    private var missing: Set<String> = []
    private var waiting: [String: [(NSImage) -> Void]] = [:]
    private let folder = Paths.folder("Favicons")
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 10
        // An icon's address was checked before the request; its redirects are checked the same way.
        return URLSession(configuration: c, delegate: WebTools.PublicRedirects.shared, delegateQueue: nil)
    }()

    func cached(_ host: String?) -> NSImage? {
        guard let host = host?.lowercased() else { return nil }
        if let img = memory.object(forKey: host as NSString) { return img }
        guard !missing.contains(host) else { return nil }
        let file = folder.appendingPathComponent(host + ".icon")
        if let data = try? Data(contentsOf: file), let img = NSImage(data: data) {
            memory.setObject(img, forKey: host as NSString)
            // Marks it as used, so pruning keeps it.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return img
        }
        missing.insert(host)
        return nil
    }

    /// A page names its own icon, so it could point it anywhere: at the local network, or at a file on this Mac.
    /// Only icons inside the page, on a public address, or on the page's own host (a router's page, say) are fetched.
    static func mayFetch(_ url: URL, forPageHost pageHost: String) async -> Bool {
        switch url.scheme?.lowercased() {
        case "data": return true
        case "http", "https":
            guard let host = url.host?.lowercased() else { return false }
            if host == pageHost.lowercased() { return true }
            // A public name can still lead to a local address, so where it resolves is checked too.
            guard WebTools.isPublic(url) else { return false }
            return await WebTools.resolvesPublic(host)
        default: return false
        }
    }

    func fetch(_ url: URL, host: String, persist: Bool, done: @escaping (NSImage) -> Void) {
        let key = host.lowercased()
        // Tabs asking for the same host while it loads all get the icon, not just the first.
        if waiting[key] != nil { waiting[key]?.append(done); return }
        waiting[key] = [done]
        session.dataTask(with: url) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let callbacks = self.waiting.removeValue(forKey: key) ?? []
                guard let data, data.count < 1_000_000,
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                      let img = NSImage(data: data), img.isValid else { return }
                self.memory.setObject(img, forKey: key as NSString)
                self.missing.remove(key)
                if persist { try? data.write(to: self.folder.appendingPathComponent(key + ".icon"), options: .atomic) }
                callbacks.forEach { $0(img) }
            }
        }.resume()
    }

    /// Icons of sites not seen for six months go, and only the newest 3,000 are kept, so the folder can't grow forever.
    func prune() {
        let folder = self.folder
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
            let cutoff = Date().addingTimeInterval(-180 * 86_400)
            for (n, (file, date)) in dated.enumerated() where n >= 3_000 || date < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    func trimMemory() {
        memory.removeAllObjects()
        missing.removeAll()
    }

    func clearDisk() {
        trimMemory()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
