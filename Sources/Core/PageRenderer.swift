import WebKit

/// Reads a page for the assistant the way a browser shows it, after its scripts have run: for pages that build their
/// text with JavaScript and arrive nearly empty from a plain download. The page loads in a hidden web view with no
/// cookies, no saved data and Tacet Shield's rules, runs only its own scripts plus the one that reads the text, and is
/// thrown away as soon as it's read, after at most `timeout`. Like the plain fetch, it only opens public addresses.
@MainActor
final class PageRenderer: NSObject, WKNavigationDelegate {
    static let timeout: Duration = .seconds(12)
    /// A few pages at a time at most: each one is a whole web page with its scripts running.
    static let maxAtOnce = 2
    private static var running = 0

    private let host: String
    private var webView: WKWebView?
    private var loaded = false
    private var failed = false

    private init(host: String) {
        self.host = host.lowercased()
    }

    /// The text of the page at `url` after its scripts ran, or nil when it can't be read that way: not a public
    /// address, JavaScript turned off in Settings, a page that failed, or Stop.
    static func render(_ url: URL) async -> WebTools.Page? {
        guard Settings.shared.javaScript, WebTools.isPublic(url), let host = url.host,
              await WebTools.resolvesPublic(host) else { return nil }
        return await rendered(host: host) { $0.load(URLRequest(url: url)) }
    }

    /// The same for a page given as HTML, as if it came from `baseURL`. The tests use it, with no network.
    static func render(html: String, baseURL: URL) async -> WebTools.Page? {
        guard WebTools.isPublic(baseURL), let host = baseURL.host else { return nil }
        return await rendered(host: host) { $0.loadHTMLString(html, baseURL: baseURL) }
    }

    private static func rendered(host: String, start: (WKWebView) -> Void) async -> WebTools.Page? {
        // Waits for a free place rather than skipping: parallel reads of several such pages each get their turn.
        let wait = ContinuousClock.now + .seconds(30)
        while running >= maxAtOnce {
            if Task.isCancelled || ContinuousClock.now > wait { return nil }
            try? await Task.sleep(for: .milliseconds(150))
        }
        running += 1
        defer { running -= 1 }
        guard !Task.isCancelled, let privateRules = await privateAddressRules() else { return nil }
        return await PageRenderer(host: host).run(privateRules, start: start)
    }

    private func run(_ privateRules: WKContentRuleList, start: (WKWebView) -> Void) async -> WebTools.Page? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // A web view that isn't in a window would otherwise have its timers slowed, and some pages wouldn't finish.
        config.preferences.inactiveSchedulingPolicy = .none
        let content = config.userContentController
        content.add(privateRules)
        ContentBlocker.shared.lists(for: host).forEach(content.add)
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        wv.customUserAgent = WebTools.userAgent
        wv.navigationDelegate = self
        webView = wv
        defer { release() }

        return await withTaskCancellationHandler {
            let deadline = ContinuousClock.now + Self.timeout
            start(wv)
            while !loaded && !failed && !Task.isCancelled && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // After loading, many pages fetch their text and fill it in: it's read until it's long enough and stops
            // changing, or time is up.
            var best: WebTools.Page?
            var last = -1
            while !failed && !Task.isCancelled {
                if let page = await extract(wv) {
                    if page.text.count > best?.text.count ?? -1 { best = page }
                    if loaded && page.text.count >= WebTools.renderBelow && page.text.count == last { break }
                    last = page.text.count
                }
                if ContinuousClock.now >= deadline { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            return failed || Task.isCancelled ? nil : best
        } onCancel: {
            Task { @MainActor in self.webView?.stopLoading() }
        }
    }

    /// Stops the page and lets the web view go, also after Stop or a failure.
    private func release() {
        guard let wv = webView else { return }
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.configuration.userContentController.removeAllContentRuleLists()
        webView = nil
    }

    // MARK: Reading the text

    /// The article as Reader finds it, or else all the visible text, with the page's links. It runs in Tacet's own
    /// script world, so the page's scripts can't change what it reads.
    private static let extraction = """
    (() => {
      let article = null;
      try { article = \(Scripts.reader) } catch (e) {}
      const links = [...document.links].slice(0, 400).map(a => [(a.innerText || '').trim().slice(0, 80), a.href]);
      return { title: document.title || '', article: article ? article.html : '', text: document.body ? document.body.innerText : '', links };
    })()
    """

    private func extract(_ wv: WKWebView) async -> WebTools.Page? {
        guard let result = (try? await wv.evaluateJavaScript(Self.extraction, in: nil, contentWorld: .defaultClient)) as? [String: Any],
              let url = wv.url, WebTools.isPublic(url) else { return nil }
        let article = WebTools.plainText(html: "<body>\(result["article"] as? String ?? "")</body>").text
        let visible = (result["text"] as? String ?? "")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Reader's article leaves out menus and footers; when it found none worth reading, all the text is taken.
        let text = article.count >= WebTools.renderBelow ? article : visible
        var seen = Set<String>()
        var links: [(text: String, url: String)] = []
        for pair in result["links"] as? [[String]] ?? [] where pair.count == 2 && links.count < 40 {
            guard !pair[0].isEmpty, let u = URL(string: pair[1]), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { continue }
            c.fragment = nil
            guard let s = c.string, s != url.absoluteString, seen.insert(s).inserted else { continue }
            links.append((pair[0], s))
        }
        return WebTools.Page(url: url, title: result["title"] as? String ?? "", text: text, links: links, kind: .rendered)
    }

    // MARK: Only public addresses

    /// Whether the page may go to `url`: only public http and https addresses, and for another host only one whose
    /// name resolves to public addresses, as with redirects in the plain fetch. Blank frames are fine.
    private func allows(_ url: URL, mainFrame: Bool) async -> Bool {
        if !mainFrame, url.scheme?.lowercased() == "about" { return true }
        guard WebTools.isPublic(url), let other = url.host?.lowercased() else { return false }
        if other == host { return true }
        return await WebTools.resolvesPublic(other)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // No new windows, no downloads.
        guard let url = action.request.url, let frame = action.targetFrame, !action.shouldPerformDownload else {
            decisionHandler(.cancel)
            return
        }
        Task {
            let ok = await allows(url, mainFrame: frame.isMainFrame)
            if !ok && frame.isMainFrame { failed = true }
            decisionHandler(ok ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Only web pages: a PDF or a file to download isn't read here.
        let type = response.response.mimeType?.lowercased() ?? ""
        let page = response.canShowMIMEType && (type.contains("html") || type.hasPrefix("text/"))
        if !page && response.isForMainFrame { failed = true }
        decisionHandler(page || !response.isForMainFrame ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        Task {
            if await !allows(url, mainFrame: true) {
                failed = true
                webView.stopLoading()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failed = true
    }

    /// A load the page itself replaced with another (a script going to its own next address) isn't a failure.
    private func fail(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }

    // MARK: Private addresses

    private static var privateRules: WKContentRuleList?

    /// Blocks everything a page asks for from this Mac or the local network by address (localhost, 10.x, 192.168.x
    /// and the like, .local names), so a public page read for the assistant can't reach the user's router or
    /// devices. The navigation checks above cover the page itself and its frames; this covers its pictures, scripts
    /// and requests. Without it the page isn't read.
    private static func privateAddressRules() async -> WKContentRuleList? {
        if let privateRules { return privateRules }
        let prefixes = ["localhost[:/]", "[^/]*\\\\.localhost[:/]", "[^/]*\\\\.local[:/]", "[^/]*\\\\.internal[:/]",
                        "[^/]*\\\\.lan[:/]", "[^/]*\\\\.home\\\\.arpa[:/]", "[^./:]+[:/]", "\\\\[",
                        "0\\\\.", "127\\\\.", "10\\\\.", "169\\\\.254\\\\.", "192\\\\.168\\\\.",
                        "172\\\\.1[6-9]\\\\.", "172\\\\.2[0-9]\\\\.", "172\\\\.3[01]\\\\.",
                        "100\\\\.6[4-9]\\\\.", "100\\\\.[7-9][0-9]\\\\.", "100\\\\.1[01][0-9]\\\\.", "100\\\\.12[0-7]\\\\."]
        let rules = prefixes.map { #"{"trigger":{"url-filter":"^[a-z]+://"# + $0 + #""},"action":{"type":"block"}}"# }
        let json = "[" + rules.joined(separator: ",") + "]"
        let list: WKContentRuleList? = await withCheckedContinuation { done in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "tacet-assistant-private-1",
                                                                    encodedContentRuleList: json) { list, error in
                if let error { NSLog("Tacet: the assistant's private address rules failed: \(error)") }
                done.resume(returning: list)
            }
        }
        privateRules = list
        return list
    }
}
