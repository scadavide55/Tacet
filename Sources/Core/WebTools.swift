import Foundation

/// The assistant's web tools for providers that don't have their own: DuckDuckGo for searches, and a plain fetch
/// from this Mac with no cookies, no saved logins and no cache. Anthropic models use Anthropic's own tools instead.
enum WebTools {
    struct SearchResult: Equatable {
        let title: String
        let url: String
        let snippet: String
    }

    struct Page {
        let url: URL
        let title: String
        let text: String
        let links: [(text: String, url: String)]
    }

    enum Failure: LocalizedError {
        case notAllowed(String)
        case http(Int)
        case notText(String)

        var errorDescription: String? {
            switch self {
            case .notAllowed(let why): why
            case .http(let code): "The server answered with error \(code)."
            case .notText(let type): "This address isn't a web page (\(type))."
            }
        }
    }

    static let textLimit = 60_000
    private static let byteLimit = 4_000_000
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

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

    static func search(_ query: String) async throws -> [SearchResult] {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, _) = try await get(c.url!)
        return parseResults(String(decoding: data, as: UTF8.self))
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

    static func format(_ results: [SearchResult], query: String) -> String {
        guard !results.isEmpty else { return "No results for \"\(query)\"." }
        let lines = results.prefix(10).enumerated().map { n, r in "\(n + 1). \(r.title)\n\(r.url)\n\(r.snippet)" }
        return "<search_results query=\"\(query.replacingOccurrences(of: "\"", with: "'"))\">\n"
            + lines.joined(separator: "\n\n") + "\n</search_results>"
    }

    // MARK: Fetch

    static func fetch(_ url: URL) async throws -> Page {
        let (data, response) = try await get(url)
        let type = response.mimeType?.lowercased() ?? ""
        let textTypes = ["text/", "application/xhtml", "application/json", "application/xml", "application/rss", "application/atom"]
        guard type.isEmpty || textTypes.contains(where: type.hasPrefix) else { throw Failure.notText(type) }
        let finalURL = response.url ?? url
        let body = decode(data, charset: response.textEncodingName)
        guard type.isEmpty || type.contains("html") else {
            return Page(url: finalURL, title: "", text: body, links: [])
        }
        // Converting a large page takes a moment, so it happens off the main thread.
        return await Task.detached(priority: .userInitiated) {
            let (title, text) = plainText(html: body)
            return Page(url: finalURL, title: title, text: text, links: links(in: body, base: finalURL))
        }.value
    }

    static func format(_ page: Page) -> String {
        var text = page.text
        var note = ""
        if text.count > textLimit {
            text = String(text.prefix(textLimit))
            note = "\n[The page is longer; only the first \(textLimit) characters are included.]"
        }
        var out = "<web_page url=\"\(page.url.absoluteString)\" title=\"\(page.title.replacingOccurrences(of: "\"", with: "'"))\">\n\(text)\(note)"
        if !page.links.isEmpty {
            out += "\n\nLinks on the page:\n" + page.links.map { "- \($0.text): \($0.url)" }.joined(separator: "\n")
        }
        return out + "\n</web_page>"
    }

    /// Downloads at most `byteLimit` bytes, refusing private addresses, also after a redirect.
    private static func get(_ url: URL) async throws -> (Data, URLResponse) {
        guard isPublic(url) else { throw Failure.notAllowed("Tacet doesn't fetch local or private network addresses.") }
        guard let host = url.host, await resolvesPublic(host) else {
            throw Failure.notAllowed("This address points to a local or private network, or couldn't be found.")
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request, delegate: PublicRedirects.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if (300..<400).contains(status) { throw Failure.notAllowed("The page redirects to a local or private network address.") }
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        var data = Data()
        // The size is usually known: the buffer is made once instead of growing as bytes arrive.
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(min(response.expectedContentLength, Int64(byteLimit)))) }
        for try await b in bytes {
            data.append(b)
            if data.count >= byteLimit { break }
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
        let haystack = transcript.map { $0["role"] as? String == "assistant" ? serverResults($0) : texts($0) }.joined(separator: "\n")
        var candidates = [address]
        if address.hasSuffix("/") { candidates.append(String(address.dropLast())) }
        if let r = address.range(of: "://") {
            let bare = String(address[r.upperBound...])
            candidates += [bare, bare.hasSuffix("/") ? String(bare.dropLast()) : bare]
        }
        return candidates.contains { $0.count > 3 && haystack.contains($0) }
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
