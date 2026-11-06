import Observation
import WebKit

extension Notification.Name {
    /// Posted when the set of rule lists a tab should use may have changed.
    static let blockerChanged = Notification.Name("lumen.blockerChanged")
}

/// Owns every compiled WebKit rule list: the built-in list, the third-party cookie
/// list, and optional EasyList / EasyPrivacy lists downloaded and converted at runtime.
@Observable
final class ContentBlocker {
    static let shared = ContentBlocker()

    private(set) var builtInCount = 0
    private(set) var filterCount = 0
    private(set) var updating = false
    private(set) var status = ""
    private(set) var lastUpdated: Date?

    @ObservationIgnored private(set) var isReady = false
    @ObservationIgnored private var readyCallbacks: [() -> Void] = []
    @ObservationIgnored private var builtIn: WKContentRuleList?
    @ObservationIgnored private var cookies: WKContentRuleList?
    @ObservationIgnored private var filters: [WKContentRuleList] = []
    private let store = WKContentRuleListStore.default()!
    private let defaults = UserDefaults.standard

    static let sources: [(key: String, url: URL)] = [
        ("easyList", URL(string: "https://easylist.to/easylist/easylist.txt")!),
        ("easyPrivacy", URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        ("adGuardBase", URL(string: "https://filters.adtidy.org/extension/safari/filters/2.txt")!),
        ("fanboyAnnoyance", URL(string: "https://easylist.to/easylist/fanboy-annoyance.txt")!),
        ("cnameTrackers", URL(string: "https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_disguised_trackers.txt")!),
    ]

    static func isEnabled(_ key: String) -> Bool {
        let s = Settings.shared
        switch key {
        case "easyList": return s.easyList
        case "easyPrivacy": return s.easyPrivacy
        case "adGuardBase": return s.adGuardBase
        case "fanboyAnnoyance": return s.fanboyAnnoyance
        case "cnameTrackers": return s.cnameTrackers
        default: return false
        }
    }

    static var anyListEnabled: Bool { sources.contains { isEnabled($0.key) } }

    /// Trackers hidden behind a site's own subdomain (metrics.example.com pointing at a tracking company), which
    /// blocking by name alone misses. AdGuard's list has one line per subdomain found, including hundreds of
    /// thousands of generated ones under a few sites; those sites are left out and each tracking company's own
    /// domain is blocked whole, which keeps the list small enough to compile.
    static func trimCNAMEList(_ text: String) -> String {
        let hosts = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("||"), line.hasSuffix("^") else { return nil }
            return String(line.dropFirst(2).dropLast())
        }
        var perSite: [String: Int] = [:]
        for h in hosts { perSite[PublicSuffix.registrable(h), default: 0] += 1 }
        let kept = hosts.filter { perSite[PublicSuffix.registrable($0), default: 0] <= 200 }
        return kept.map { "||" + $0 + "^" }.joined(separator: "\n")
    }

    var ruleCount: Int { (Settings.shared.adBlock ? builtInCount + filterCount : 0) }

    func start() {
        builtInCount = BuiltInRules.count
        filterCount = defaults.integer(forKey: "lumen.filterCount")
        lastUpdated = defaults.object(forKey: "lumen.filterDate") as? Date
        let ids = defaults.stringArray(forKey: "lumen.filterIDs") ?? []

        let group = DispatchGroup()
        let json = BuiltInRules.json()
        group.enter()
        compileOrLookUp("lumen-builtin-" + Self.hash(json), json, stalePrefix: "lumen-builtin-") {
            self.builtIn = $0
            group.leave()
        }
        group.enter()
        compileOrLookUp("lumen-cookies-1", BuiltInRules.cookieJSON, stalePrefix: "lumen-cookies-") {
            self.cookies = $0
            group.leave()
        }
        var found: [String: WKContentRuleList] = [:]
        for id in ids {
            group.enter()
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in
                if let list { found[id] = list }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.filters = ids.compactMap { found[$0] }
            if self.filters.count != ids.count { self.filterCount = 0; self.filters = [] }
            self.markReady()
            self.updateIfStale()
        }
        // Never hold page loads hostage to the rule store.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.markReady() }

        NotificationCenter.default.addObserver(forName: .settingChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, let key = note.userInfo?["key"] as? String else { return }
            switch key {
            case "easyList", "easyPrivacy", "adGuardBase", "fanboyAnnoyance", "cnameTrackers": self.updateFilterLists()
            case "adBlock", "thirdPartyCookies", "allowlist":
                NotificationCenter.default.post(name: .blockerChanged, object: nil)
            default: break
            }
        }
    }

    func whenReady(_ f: @escaping () -> Void) {
        if isReady { f() } else { readyCallbacks.append(f) }
    }

    /// Rule lists a page on `host` should load with.
    func lists(for host: String?) -> [WKContentRuleList] {
        let s = Settings.shared
        guard !s.isShieldOff(host) else { return [] }
        var out: [WKContentRuleList] = []
        if s.adBlock {
            if let builtIn { out.append(builtIn) }
            out += filters
        }
        if s.blockThirdPartyCookies, let cookies { out.append(cookies) }
        return out
    }

    // MARK: Filter lists

    func updateIfStale() {
        guard Self.anyListEnabled else { return }
        let age = lastUpdated.map { Date().timeIntervalSince($0) } ?? .infinity
        if filters.isEmpty || age > 7 * 86_400 { updateFilterLists() }
    }

    func updateFilterLists() {
        let enabled = Self.sources.filter { Self.isEnabled($0.key) }
        guard !enabled.isEmpty else { removeFilters(); return }
        guard !updating else { return }
        updating = true
        status = L("Downloading filter lists…")

        let group = DispatchGroup()
        var texts = [Data?](repeating: nil, count: enabled.count)
        for (i, src) in enabled.enumerated() {
            group.enter()
            var request = URLRequest(url: src.url)
            request.timeoutInterval = 30
            URLSession.shared.dataTask(with: request) { data, response, _ in
                DispatchQueue.main.async {
                    if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                        texts[i] = data
                    }
                    group.leave()
                }
            }.resume()
        }
        group.notify(queue: .main) {
            // The CNAME list is trimmed off the main thread with the conversion below.
            let keys = enabled.map(\.key)
            let downloaded = texts.compactMap { $0 }
            guard downloaded.count == texts.count else {
                self.updating = false
                Diagnostics.log(.blocking, "filter lists download failed", "\(texts.count - downloaded.count) of \(texts.count)", level: .error)
                self.status = L("Couldn't download the filter lists. Check your connection.")
                return
            }
            self.status = L("Converting rules…")
            DispatchQueue.global(qos: .utility).async {
                // Decoding several megabytes of text happens here too, off the main thread.
                let prepared = zip(keys, downloaded).map { key, data in
                    let text = String(decoding: data, as: UTF8.self)
                    return key == "cnameTrackers" ? Self.trimCNAMEList(text) : text
                }
                let out = FilterConverter.convert(prepared.joined(separator: "\n"))
                let chunks = Self.chunks(out)
                DispatchQueue.main.async { self.compileFilters(chunks, total: out.block.count + out.hide.count, for: keys) }
            }
        }
    }

    private func compileFilters(_ chunks: [[[String: Any]]], total: Int, for keys: [String]) {
        status = String(format: L("Compiling %@ rules…"), total.formatted())
        let stamp = Int(Date().timeIntervalSince1970)
        var lists: [WKContentRuleList] = []
        var compiled = 0

        func next(_ i: Int) {
            guard i < chunks.count else {
                Diagnostics.log(.blocking, "filter lists compiled", "\(compiled) rules in \(lists.count) lists")
                finish(lists, count: compiled, for: keys)
                return
            }
            compileResilient(chunks[i], id: "lumen-filter-\(stamp)-\(i)") { l, n in
                lists += l
                compiled += n
                next(i + 1)
            }
        }
        next(0)
    }

    private func finish(_ lists: [WKContentRuleList], count: Int, for keys: [String]) {
        // The lists were changed while these downloaded: these rules are out of date, so they're dropped and the
        // lists chosen now are fetched instead.
        guard Self.sources.filter({ Self.isEnabled($0.key) }).map(\.key) == keys else {
            for l in lists { store.removeContentRuleList(forIdentifier: l.identifier) { _ in } }
            updating = false
            updateFilterLists()
            return
        }
        let old = filters.map(\.identifier)
        filters = lists
        filterCount = count
        lastUpdated = Date()
        updating = false
        status = lists.isEmpty ? L("No rules could be compiled.") : ""
        defaults.set(lists.map(\.identifier), forKey: "lumen.filterIDs")
        defaults.set(count, forKey: "lumen.filterCount")
        defaults.set(lastUpdated, forKey: "lumen.filterDate")
        for id in old where !lists.contains(where: { $0.identifier == id }) {
            store.removeContentRuleList(forIdentifier: id) { _ in }
        }
        NotificationCenter.default.post(name: .blockerChanged, object: nil)
    }

    private func removeFilters() {
        for l in filters { store.removeContentRuleList(forIdentifier: l.identifier) { _ in } }
        filters = []
        filterCount = 0
        lastUpdated = nil
        status = ""
        defaults.removeObject(forKey: "lumen.filterIDs")
        defaults.removeObject(forKey: "lumen.filterCount")
        defaults.removeObject(forKey: "lumen.filterDate")
        NotificationCenter.default.post(name: .blockerChanged, object: nil)
    }

    /// Splits converted rules under WebKit's per-list limit. Exceptions only affect
    /// rules earlier in the same list, so each network chunk ends with all of them.
    static func chunks(_ out: FilterConverter.Output, size: Int = 45_000) -> [[[String: Any]]] {
        var result: [[[String: Any]]] = []
        var i = 0
        while i < out.block.count {
            result.append(Array(out.block[i..<min(i + size, out.block.count)]) + out.allow)
            i += size
        }
        i = 0
        while i < out.hide.count {
            result.append(Array(out.hide[i..<min(i + size, out.hide.count)]))
            i += size
        }
        return result
    }

    /// Compiles a list; if WebKit rejects it, splits it in half until the bad rules are isolated and dropped.
    private func compileResilient(_ rules: [[String: Any]], id: String, done: @escaping ([WKContentRuleList], Int) -> Void) {
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules) else {
            done([], 0)
            return
        }
        store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: String(decoding: data, as: UTF8.self)) { list, _ in
            if let list { done([list], rules.count); return }
            guard rules.count > 1 else { done([], 0); return }
            let mid = rules.count / 2
            self.compileResilient(Array(rules[..<mid]), id: id + "a") { l1, c1 in
                self.compileResilient(Array(rules[mid...]), id: id + "b") { l2, c2 in done(l1 + l2, c1 + c2) }
            }
        }
    }

    // MARK: Helpers

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        let callbacks = readyCallbacks
        readyCallbacks = []
        callbacks.forEach { $0() }
        NotificationCenter.default.post(name: .blockerChanged, object: nil)
    }

    private func compileOrLookUp(_ id: String, _ json: String, stalePrefix: String, done: @escaping (WKContentRuleList?) -> Void) {
        store.lookUpContentRuleList(forIdentifier: id) { list, _ in
            if let list { done(list); return }
            self.store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let error { Diagnostics.log(.blocking, "rule list \(id) failed to compile", Diagnostics.code(error), level: .error) }
                done(list)
            }
            self.store.getAvailableContentRuleListIdentifiers { ids in
                for old in ids ?? [] where old.hasPrefix(stalePrefix) && old != id {
                    self.store.removeContentRuleList(forIdentifier: old) { _ in }
                }
            }
        }
    }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h, radix: 36)
    }
}
