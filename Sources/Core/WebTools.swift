import Foundation
import PDFKit

/// The assistant's web tools for providers that don't have their own: the search engines in `SearchEngines.swift`
/// (DuckDuckGo unless the user set up others), and a plain fetch
/// from this Mac with no cookies, no saved logins and no cache. Anthropic models use Anthropic's own tools instead.
enum WebTools {
    struct SearchResult: Equatable, Sendable {
        let title: String
        let url: String
        let snippet: String
    }

    struct Page {
        /// Where the text came from: the page as downloaded, the page after its scripts ran, or a PDF.
        enum Kind { case web, rendered, pdf }

        let url: URL
        let title: String
        let text: String
        let links: [(text: String, url: String)]
        var kind: Kind = .web
        /// For a PDF: how many pages it has, and where each page that was read starts in `text`, in characters,
        /// so a cut can say which page the text reaches.
        var pageCount = 0
        var pageStarts: [Int] = []
    }

    enum Failure: LocalizedError {
        case notAllowed(String)
        case http(Int)
        case notText(String)
        /// DuckDuckGo showed its check for bots, or a page without results that isn't its "No results" page.
        case blocked
        /// What a search engine said went wrong, in words for the model.
        case engine(String)
        /// Every engine failed: each one's name and reason.
        case searchFailed([(engine: String, reason: String)])
        case pdfTooLarge
        case unreadablePDF

        var errorDescription: String? {
            switch self {
            case .notAllowed(let why): why
            case .http(let code): "The server answered with error \(code)."
            case .notText(let type): "This address isn't a web page (\(type))."
            case .blocked: "DuckDuckGo is refusing automated searches for now. Wait a little, or set up another search engine in Settings › AI."
            case .engine(let why): why
            case .searchFailed(let all):
                if all.isEmpty { "No search engine is set up." }
                else if all.count == 1 { all[0].reason }
                else { all.map { "\($0.engine): \($0.reason)" }.joined(separator: " ") }
            case .pdfTooLarge: "This PDF is larger than \(WebTools.pdfByteLimit / 1_000_000) MB, too large to read."
            case .unreadablePDF: "This PDF couldn't be opened (it may be damaged or protected by a password)."
            }
        }
    }

    static let textLimit = 60_000
    private static let byteLimit = 4_000_000
    /// PDFs are often bigger than pages, and can't be read when cut, so they may take more, within reason.
    static let pdfByteLimit = 25_000_000
    /// Text read from a PDF stops here: more than any model takes from one page, so a long book isn't read whole.
    static let pdfTextLimit = 200_000
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 45
        return URLSession(configuration: c)
    }()

    // MARK: Search

    struct SearchAnswer {
        let results: [SearchResult]
        /// The engine that answered, for the activity timeline.
        let engine: String
    }

    /// Asks the engines in order until one has results. One that fails, or finds nothing, lets the next one try; when
    /// none finds anything, the answer is "no results" from the first that answered. At most three searches run at
    /// once (`SearchGate`).
    static func search(_ query: String, engines: [any WebSearchEngine], gate: SearchGate = .shared) async throws -> SearchAnswer {
        try await gate.run {
            var failures: [(engine: String, reason: String)] = []
            var empty: SearchAnswer?
            for engine in engines {
                try Task.checkCancellation()
                do {
                    let results = try await engine.search(query)
                    if !results.isEmpty { return SearchAnswer(results: results, engine: engine.name) }
                    if empty == nil { empty = SearchAnswer(results: [], engine: engine.name) }
                } catch {
                    // Stop stops the search; it doesn't move on to the next engine.
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    failures.append((engine.name, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                }
            }
            if let empty { return empty }
            throw Failure.searchFailed(failures)
        }
    }

    enum DuckDuckGoPage: Equatable {
        case results([SearchResult])
        case noResults
        case blocked
    }

    /// What a DuckDuckGo HTML page holds. Its check for bots comes as a page with a challenge form instead of
    /// results; a page with neither results nor its "No results" notice is taken as the same, since a real results
    /// page always has one of the two.
    static func readDuckDuckGo(_ html: String) -> DuckDuckGoPage {
        let lower = html.lowercased()
        let check = ["anomaly-modal", "anomaly.js", "challenge-form", "bots use duckduckgo"]
        if check.contains(where: lower.contains) { return .blocked }
        let results = parseResults(html)
        if !results.isEmpty { return .results(results) }
        if lower.contains("class=\"no-results") || lower.contains(">no results.<") || lower.contains(">no  results.<") { return .noResults }
        return .blocked
    }

    /// The organic results of a DuckDuckGo HTML page, without ads.
    static func parseResults(_ html: String) -> [SearchResult] {
        html.components(separatedBy: "<div class=\"result ").dropFirst().compactMap { block in
            guard !block.contains("result--ad"),
                  let link = firstMatch(#"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: block),
                  let url = resultURL(decodeEntities(link[0])) else { return nil }
            let snippet = firstMatch(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block)?[0] ?? ""
            return SearchResult(title: inlineText(link[1]), url: url, snippet: inlineText(snippet))
        }
    }

    /// Result links are either direct or wrapped in DuckDuckGo's redirect, whose `uddg` parameter holds the address.
    private static func resultURL(_ href: String) -> String? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let url = URL(string: absolute), let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("duckduckgo.com") {
            guard url.path.hasPrefix("/l"), let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "uddg" })?.value else { return nil }
            return target
        }
        return absolute
    }

    /// Results from an engine's JSON, keeping only http and https addresses, once each, with any markup taken out.
    static func searchResults(_ items: [(title: String?, url: String?, snippet: String?)]) -> [SearchResult] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard let raw = item.url?.trimmingCharacters(in: .whitespaces), let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  seen.insert(raw).inserted else { return nil }
            let title = inlineText(item.title ?? "")
            return SearchResult(title: title.isEmpty ? raw : title, url: raw, snippet: inlineText(item.snippet ?? ""))
        }
    }

    static func format(_ results: [SearchResult], query: String) -> String {
        guard !results.isEmpty else { return "No results for \"\(query)\"." }
        let lines = results.prefix(10).enumerated().map { n, r in "\(n + 1). \(r.title)\n\(r.url)\n\(r.snippet)" }
        return "<search_results query=\"\(query.replacingOccurrences(of: "\"", with: "'"))\">\n"
            + lines.joined(separator: "\n\n") + "\n</search_results>"
    }

    // MARK: Fetch

    private static let textTypes = ["text/", "application/xhtml", "application/json", "application/xml", "application/rss", "application/atom"]

    /// `reading` is told when the page turns out to be a PDF or needs its scripts run, so the step can say so while
    /// it's being read, which takes longer than usual.
    static func fetch(_ url: URL, reading: (@MainActor (Page.Kind) -> Void)? = nil) async throws -> Page {
        let (data, response) = try await get(url)
        let type = response.mimeType?.lowercased() ?? ""
        let finalURL = response.url ?? url
        if isPDF(type: type, url: finalURL, data: data) {
            await reading?(.pdf)
            // Reading every page of a PDF takes a while, so it happens off the main thread.
            return try await Task.detached(priority: .userInitiated) {
                guard let page = pdfPage(data, url: finalURL) else { throw Failure.unreadablePDF }
                return page
            }.value
        }
        guard type.isEmpty || textTypes.contains(where: type.hasPrefix) else { throw Failure.notText(type) }
        let body = decode(data, charset: response.textEncodingName)
        guard type.isEmpty || type.contains("html") else {
            return Page(url: finalURL, title: "", text: body, links: [])
        }
        // Converting a large page takes a moment, so it happens off the main thread.
        let page = await Task.detached(priority: .userInitiated) {
            let (title, text) = plainText(html: body)
            return Page(url: finalURL, title: title, text: text, links: links(in: body, base: finalURL))
        }.value
        // A page that builds its text with JavaScript arrives nearly empty: it's read again as a browser shows it,
        // and that reading is kept only if it gave more text.
        guard needsRendering(text: page.text, html: body), !Task.isCancelled else { return page }
        await reading?(.rendered)
        guard let rendered = await PageRenderer.render(finalURL), rendered.text.count > page.text.count else { return page }
        return rendered
    }

    /// Whether a download is a PDF: by its type or, when the server didn't say what it is, by its name or first bytes.
    static func isPDF(type: String, url: URL, data: Data? = nil) -> Bool {
        if type.contains("pdf") { return true }
        guard !textTypes.contains(where: type.hasPrefix) else { return false }
        return url.pathExtension.lowercased() == "pdf" || data.map { $0.starts(with: Data("%PDF-".utf8)) } ?? false
    }

    /// The text of a PDF, page by page, each marked with its number so the model can say where something is.
    /// Nil when it can't be opened.
    static func pdfPage(_ data: Data, url: URL) -> Page? {
        guard let doc = PDFDocument(data: data), !doc.isLocked else { return nil }
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var text = "", count = 0, starts: [Int] = [], anyText = false
        for i in 0..<doc.pageCount where count < pdfTextLimit {
            let pageText = (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            anyText = anyText || !pageText.isEmpty
            let chunk = (i > 0 ? "\n\n" : "") + "[Page \(i + 1)]\n" + pageText
            starts.append(count)
            text += chunk
            count += chunk.count
        }
        // A PDF of scans has no text layer: it says so instead of sending empty pages.
        return Page(url: url, title: title.isEmpty ? url.lastPathComponent : title, text: anyText ? text : "", links: [],
                    kind: .pdf, pageCount: doc.pageCount, pageStarts: anyText ? starts : [])
    }

    /// Pages with less text than this are probably built by JavaScript, or are a notice asking for it.
    static let renderBelow = 600

    /// Words pages use to ask for JavaScript, in the languages Tacet speaks and a few more.
    static let asksForJavaScript = ["enable javascript", "javascript is disabled", "javascript is required", "requires javascript",
                                    "javascript is not available", "javascript must be enabled", "turn on javascript",
                                    "need javascript", "javascript to run this app", "activate javascript",
                                    "attiva javascript", "abilita javascript", "abilitare javascript", "attivare javascript",
                                    "activer javascript", "activez javascript", "activer le javascript", "javascript aktivieren",
                                    "habilita javascript", "activa javascript", "habilitar javascript"]

    /// Whether a downloaded page should be read again after its scripts run: its text is very short, or a short
    /// page asks for JavaScript. A page without scripts would come out the same, so it never is.
    static func needsRendering(text: String, html: String) -> Bool {
        guard html.range(of: "<script", options: .caseInsensitive) != nil else { return false }
        let length = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if length < renderBelow { return true }
        // A long article that mentions JavaScript is read as it is.
        guard length < 3_000 else { return false }
        let notices = allMatches(#"<noscript\b[^>]*>(.*?)</noscript\s*>"#, in: html).map { inlineText($0[0]) }
        let haystack = ([text] + notices).joined(separator: " ").lowercased()
        return asksForJavaScript.contains(where: haystack.contains)
    }

    /// The page for the model, its text cut to `limit` characters (at most `textLimit`), saying how much is included.
    static func format(_ page: Page, limit: Int = textLimit) -> String {
        let limit = min(limit, textLimit)
        let text = page.kind == .pdf ? pdfText(page, limit: limit) : AssistantLimits.clip(page.text, to: limit)
        var out = "<web_page url=\"\(page.url.absoluteString)\" title=\"\(page.title.replacingOccurrences(of: "\"", with: "'"))\">\n\(text)"
        if !page.links.isEmpty {
            // A small model gets fewer of the links, which would otherwise take much of its room.
            let links = page.links.prefix(limit < 10_000 ? 12 : 40)
            out += "\n\nLinks on the page:\n" + links.map { "- \($0.text): \($0.url)" }.joined(separator: "\n")
        }
        return out + "\n</web_page>"
    }

    /// A PDF's text for the model, cut to `limit` characters. It starts with how many pages the PDF has and, when
    /// cut, up to which page the text goes: a character count alone wouldn't tell the model what it missed.
    static func pdfText(_ page: Page, limit: Int) -> String {
        let pages = page.pageCount == 1 ? "1 page" : "\(page.pageCount) pages"
        guard !page.text.isEmpty else { return "[PDF, \(pages). It has no text to read: its pages may be scanned images.]" }
        let complete = page.pageStarts.count >= page.pageCount
        guard page.text.count > limit || !complete else { return "[PDF, \(pages).]\n\(page.text)" }
        let reached = (page.pageStarts.lastIndex { $0 < limit } ?? 0) + 1
        return "[PDF, \(pages); the text is cut: only up to page \(reached) of \(page.pageCount) is included.]\n"
            + String(page.text.prefix(limit))
    }

    private static func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        return try await download(request)
    }

    /// Downloads at most `byteLimit` bytes, refusing private addresses, also after a redirect. `localAllowed` is only
    /// for a search server whose address the user typed in Settings, which may be on their own network; a redirect
    /// from it still can't go to another local host.
    static func download(_ request: URLRequest, localAllowed: Bool = false) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw Failure.notAllowed("The address is missing.") }
        if localAllowed {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw Failure.notAllowed("The address must be an http or https address.")
            }
        } else {
            guard isPublic(url) else { throw Failure.notAllowed("Tacet doesn't fetch local or private network addresses.") }
            guard let host = url.host, await resolvesPublic(host) else {
                throw Failure.notAllowed("This address points to a local or private network, or couldn't be found.")
            }
        }
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: PublicRedirects.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if (300..<400).contains(status) { throw Failure.notAllowed("The page redirects to a local or private network address.") }
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        // A cut PDF can't be opened, so one over its limit isn't downloaded at all.
        let pdf = isPDF(type: response.mimeType?.lowercased() ?? "", url: response.url ?? url)
        let limit = pdf ? pdfByteLimit : byteLimit
        if pdf && response.expectedContentLength > Int64(limit) { throw Failure.pdfTooLarge }
        var data = Data()
        // The size is usually known: the buffer is made once instead of growing as bytes arrive.
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(min(response.expectedContentLength, Int64(limit)))) }
        for try await b in bytes {
            data.append(b)
            if data.count >= limit {
                if pdf { throw Failure.pdfTooLarge }
                break
            }
        }
        return (data, response)
    }

    /// Follows a redirect only to the same host, or to a public address whose name also resolves to public addresses,
    /// so a public page can't send Tacet's own requests into the local network.
    final class PublicRedirects: NSObject, URLSessionTaskDelegate {
        static let shared = PublicRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, let host = url.host?.lowercased() else { completionHandler(nil); return }
            if host == task.originalRequest?.url?.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                completionHandler(request)
                return
            }
            guard isPublic(url) else { completionHandler(nil); return }
            Task { completionHandler(await WebTools.resolvesPublic(host) ? request : nil) }
        }
    }

    // MARK: Which addresses

    /// Only http and https on public hosts: never localhost, the local network, or a bare IP address in a private range.
    static func isPublic(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") { return false }
        let localSuffixes = [".localhost", ".local", ".internal", ".lan", ".home", ".home.arpa", ".corp", ".intranet"]
        if host == "localhost" || !host.contains(".") || localSuffixes.contains(where: host.hasSuffix) { return false }
        let labels = host.split(separator: ".")
        guard let last = labels.last, last.allSatisfy(\.isNumber) || last.hasPrefix("0x") else { return true }
        // An address written as numbers: only a plain, public IPv4 address.
        let octets = labels.compactMap { UInt8($0) }
        return octets.count == 4 && labels.count == 4 && isPublicIPv4(octets)
    }

    static func isPublicIPv4(_ o: [UInt8]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): false
        case (172, 16...31), (100, 64...127): false
        case (224...255, _): false
        default: true
        }
    }

    /// Whether every address the host resolves to is public, so a name can't lead to the local network.
    static func resolvesPublic(_ host: String) async -> Bool {
        await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
            defer { freeaddrinfo(list) }
            var node: UnsafeMutablePointer<addrinfo>? = first
            while let n = node {
                if let addr = n.pointee.ai_addr {
                    if n.pointee.ai_family == AF_INET {
                        let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                        let b = withUnsafeBytes(of: a) { Array($0) }
                        if !isPublicIPv4(b) { return false }
                    } else if n.pointee.ai_family == AF_INET6 {
                        let b = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
                        let mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
                        if mapped && !isPublicIPv4(Array(b[12..<16])) { return false }
                        // Loopback, link-local, unique local and unspecified addresses.
                        if b[0..<15].allSatisfy({ $0 == 0 }) || b[0] == 0xfe && b[1] & 0xc0 == 0x80 || b[0] & 0xfe == 0xfc { return false }
                    }
                }
                node = n.pointee.ai_next
            }
            return true
        }.value
    }

    /// Whether `address` already appears in the conversation outside the model's own turns: in the user's messages,
    /// an attached page, or a tool result. The model can then only fetch addresses it was given, not ones it made up,
    /// so instructions hidden in a page can't make it send what it read to another site.
    static func appears(_ address: String, in transcript: [[String: Any]]) -> Bool {
        let haystack = conversationText(transcript)
        var candidates = [address]
        if address.hasSuffix("/") { candidates.append(String(address.dropLast())) }
        if let r = address.range(of: "://") {
            let bare = String(address[r.upperBound...])
            candidates += [bare, bare.hasSuffix("/") ? String(bare.dropLast()) : bare]
        }
        return candidates.contains { $0.count > 3 && haystack.contains($0) }
    }

    /// The conversation's text outside the model's own words: the user's messages, an attached page, tool results,
    /// and what Anthropic's own web search and fetch returned. Used to check links in a reply, too.
    static func conversationText(_ transcript: [[String: Any]]) -> String {
        transcript.map { $0["role"] as? String == "assistant" ? serverResults($0) : texts($0) }.joined(separator: "\n")
    }

    /// Addresses the assistant may open or fetch by itself: ones from the conversation, or a site's home page
    /// (https://apple.com), which can't carry anything the model read.
    static func mayOpen(_ address: String, in transcript: [[String: Any]]) -> Bool {
        appears(address, in: transcript) || isHomePage(address)
    }

    static func isHomePage(_ address: String) -> Bool {
        guard let c = URLComponents(string: address), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host?.lowercased(), c.user == nil, c.password == nil, c.port == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare.contains(".") && PublicSuffix.registrable(bare) == bare
    }

    /// What Anthropic's own web search and fetch returned in a model turn: addresses and fetched text, not the model's words.
    private static func serverResults(_ message: [String: Any]) -> String {
        var out: [String] = []
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "web_search_tool_result":
                for r in block["content"] as? [[String: Any]] ?? [] { if let u = r["url"] as? String { out.append(u) } }
            case "web_fetch_tool_result":
                let c = block["content"] as? [String: Any]
                if let u = c?["url"] as? String { out.append(u) }
                if let d = (c?["content"] as? [String: Any])?["source"] as? [String: Any], let text = d["data"] as? String { out.append(text) }
            default: break
            }
        }
        return out.joined(separator: "\n")
    }

    private static func texts(_ message: [String: Any]) -> String {
        if let s = message["content"] as? String { return s }
        return (message["content"] as? [[String: Any]] ?? []).compactMap { block in
            (block["text"] as? String) ?? (block["content"] as? String)
        }.joined(separator: "\n")
    }

    // MARK: HTML to text

    static func plainText(html: String) -> (title: String, text: String) {
        let title = firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html).map { inlineText($0[0]) } ?? ""
        var s = html
        if let body = firstMatch(#"<body[^>]*>(.*)</body>"#, in: s) { s = body[0] }
        s = replace(#"<!--.*?-->"#, in: s, with: "")
        s = replace(#"<(script|style|noscript|svg|template|iframe|select|button|nav|form)\b.*?</\1\s*>"#, in: s, with: " ")
        s = replace(#"<li\b[^>]*>"#, in: s, with: "\n- ")
        s = replace(#"<br\s*/?>|</?(p|div|h[1-6]|tr|section|article|header|footer|main|aside|ul|ol|table|blockquote|pre|figure|dl|dt|dd|hr)\b[^>]*>"#, in: s, with: "\n")
        s = replace(#"</t[dh]\s*>"#, in: s, with: " \t")
        s = replace(#"<[^>]+>"#, in: s, with: "")
        s = decodeEntities(s)
        s = replace(#"[ \t ]+"#, in: s, with: " ")
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        s = lines.joined(separator: "\n")
        s = replace(#"\n{3,}"#, in: s, with: "\n\n")
        return (title, s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Up to 40 distinct http links with their text, so the model can follow them.
    static func links(in html: String, base: URL) -> [(text: String, url: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for m in allMatches(#"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, in: html) {
            let text = inlineText(m[1])
            guard !text.isEmpty, let url = URL(string: decodeEntities(m[0]), relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { continue }
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.fragment = nil
            guard let s = c?.string, s != base.absoluteString, seen.insert(s).inserted else { continue }
            out.append((String(text.prefix(80)), s))
            if out.count == 40 { break }
        }
        return out
    }

    private static func inlineText(_ html: String) -> String {
        decodeEntities(replace(#"<[^>]+>"#, in: html, with: ""))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ndash": "–",
                     "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©",
                     "laquo": "«", "raquo": "»", "middot": "·", "euro": "€", "times": "×"]
        let regex = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")
        var out = ""
        var last = s.startIndex
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s), let nameRange = Range(m.range(at: 1), in: s) else { continue }
            out += s[last..<whole.lowerBound]
            let name = String(s[nameRange])
            var scalar: Unicode.Scalar?
            if name.hasPrefix("#x") || name.hasPrefix("#X") { scalar = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
            else if name.hasPrefix("#") { scalar = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init) }
            if let scalar { out.unicodeScalars.append(scalar) } else { out += named[name] ?? String(s[whole]) }
            last = whole.upperBound
        }
        return out + s[last...]
    }

    private static func decode(_ data: Data, charset: String?) -> String {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Regular expressions

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        allMatches(pattern, in: s, limit: 1).first
    }

    private static func allMatches(_ pattern: String, in s: String, limit: Int = .max) -> [[String]] {
        var out: [[String]] = []
        for m in regex(pattern).matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            out.append((1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" })
            if out.count == limit { break }
        }
        return out
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        regex(pattern).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
