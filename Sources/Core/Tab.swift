import SwiftUI
import WebKit

/// One browser tab. The web view is created lazily and released when the tab
/// hibernates, keeping its back/forward history in `restoreState`.
@Observable
final class Tab: NSObject, Identifiable {
    let id = UUID()
    @ObservationIgnored weak var browser: BrowserState?

    var title: String
    var url: URL?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var favicon: NSImage?
    var isPinned: Bool {
        didSet {
            // A pinned tab remembers where it was pinned, to go back there.
            if isPinned && !oldValue { pinnedHome = url ?? pendingURL } else if !isPinned { pinnedHome = nil }
        }
    }
    /// The address a pinned tab was pinned at; links to other sites leave it alone (see decidePolicyFor).
    @ObservationIgnored var pinnedHome: URL?
    var groupID: UUID?
    var isPlayingAudio = false
    var isMuted = false
    var hoverURL: String?
    var isReader = false
    var isSecure = false
    var themeColor: NSColor?
    var zoom = 1.0
    var failedURL: URL?
    private(set) var webView: LumenWebView?
    var loginMenu: LoginMenu?
    var pendingSave: PendingLogin?
    var insecureWarning = false
    /// Unsent text from an earlier visit to this page, offered back in a banner.
    var draftOffer: [Draft] = []
    /// The highlight under the pointer, for the right-click menu.
    @ObservationIgnored var hoveredHighlight: UUID?
    /// A site asked for a passkey, which Tacet can't use yet: the banner that offers Safari instead.
    var passkeyHelp: PasskeyHelp?
    /// Picking elements on the page to hide.
    var pickingElements = false
    /// Developer Mode: the screen size the page is shown at (Responsive Design Mode), and turned sideways.
    var device: DevDevice?
    var deviceLandscape = false
    /// Developer Mode: a user agent for this tab only, and JavaScript turned off for it.
    @ObservationIgnored var devUserAgent: String?
    var javaScriptOff = false
    @ObservationIgnored var lastActive = Date()
    /// What the page looked like when it went to sleep, shown over it while it wakes up so there's no white flash.
    var sleepImage: NSImage?
    /// The page as it looked when you last left the tab, as JPEG, and where it was scrolled to.
    @ObservationIgnored private var lastLook: (jpeg: Data, scroll: CGPoint)? {
        // Made once, so the hover preview and the wake-up picture don't decode the JPEG each time they're drawn.
        didSet { lastLookImage = lastLook.flatMap { NSImage(data: $0.jpeg) } }
    }
    @ObservationIgnored private var lastLookImage: NSImage?
    @ObservationIgnored private var waking = false
    /// Page translation: in progress, done (from which language), or why it couldn't be.
    var translating = false
    var translatedFrom: String?
    var translationError: String?
    var readingAloud = false
    /// What Tacet Shield blocked on the page shown now, by site, and how many times.
    var blockedHere: [String: Int] = [:]

    /// The picture of the page from when you last left it, for the preview shown when hovering over the tab.
    var previewImage: NSImage? { isSelected ? nil : lastLookImage }

    @ObservationIgnored private var restoreState: Data?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var appliedLists: String?
    @ObservationIgnored private var upgrade: (host: String, original: URL, at: Date)?
    @ObservationIgnored private var internalLoad = false
    @ObservationIgnored private var internalNavigation: WKNavigation?
    @ObservationIgnored private var readerOrigin: URL?
    @ObservationIgnored private var faviconHost: String?
    /// Pull to refresh state, kept apart so that only the indicator redraws while you pull.
    let pull = PullToRefresh()
    /// Loading progress, kept apart so that only the progress line redraws while a page loads.
    let load = LoadProgress()
    @ObservationIgnored private var mediaPermissions: [String: Bool] = [:]
    @ObservationIgnored private var rememberedUser: (host: String, name: String, at: Date)?
    @ObservationIgnored private var lastCrash: Date?
    /// The error page shows because the Mac was offline: it loads again by itself once the network is back.
    @ObservationIgnored private(set) var failedOffline = false

    /// Saved accounts shown under a focused sign-in field, in page-view coordinates.
    struct LoginMenu: Equatable {
        let origin: CGPoint
        let width: CGFloat
        let logins: [SavedLogin]
        /// A generated password to offer, on sign-up and change-password fields.
        var strongPassword: String?
    }

    struct PendingLogin: Equatable {
        let host: String
        let username: String
        let password: String
        let isUpdate: Bool
    }

    private static let owners = NSMapTable<WKWebView, Tab>.weakToWeakObjects()
    static func owner(of webView: WKWebView) -> Tab? { owners.object(forKey: webView) }

    static let zoomSteps = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    var isHibernated: Bool { webView == nil }
    var isSelected: Bool { browser?.selectedID == id || browser?.splitID == id }
    var isPrivate: Bool { browser?.isPrivate ?? false }
    var host: String? { url?.host?.lowercased() }
    var shieldsUp: Bool { Settings.shared.adBlock && !Settings.shared.isAllowlisted(host) }
    var isStartPage: Bool { url == nil && failedURL == nil && !isLoading }

    init(browser: BrowserState, url: URL? = nil, title: String? = nil, state: Data? = nil, pinned: Bool = false) {
        self.browser = browser
        self.url = url
        self.title = title ?? (url.map { InputResolver.displayHost($0) } ?? L("New Tab"))
        self.isPinned = pinned
        pendingURL = url
        restoreState = state
        super.init()
        if pinned { pinnedHome = url }
        favicon = Favicons.shared.cached(url?.host)
        observeNotifications()
    }

    /// A tab for a popup WebKit asked us to create; WebKit loads it itself.
    init(browser: BrowserState, configuration: WKWebViewConfiguration) {
        self.browser = browser
        title = L("New Tab")
        isPinned = false
        super.init()
        attach(LumenWebView(frame: .zero, configuration: configuration))
        observeNotifications()
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    static func configuration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        c.applicationNameForUserAgent = UserAgent.applicationName
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Inspect Element in the right-click menu, and the Web Inspector from the Develop menu.
        c.preferences.setValue(Settings.shared.developer, forKey: "developerExtrasEnabled")
        c.allowsAirPlayForMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = Settings.shared.blockAutoplay ? .audio : []
        c.defaultWebpagePreferences.allowsContentJavaScript = Settings.shared.javaScript
        Scripts.install(on: c.userContentController)
        // Apps that come with Tacet Plugins (Cutout, say) run from this Mac at tacet-plugin://.
        c.setURLSchemeHandler(PluginAppScheme.shared, forURLScheme: PluginAppScheme.scheme)
        // Extensions run in normal windows and profiles, never in private windows.
        if #available(macOS 15.4, *), store.isPersistent {
            c.webExtensionController = Extensions.shared.controller
        }
        return c
    }

    // MARK: Web view lifecycle

    func ensureWebView() {
        guard webView == nil, let browser else { return }
        // An extension's own page (its settings, say) needs a web view made for that extension.
        if let target = pendingURL ?? url, target.scheme == "webkit-extension", let config = Extensions.webViewConfiguration(for: target) {
            attach(LumenWebView(frame: .zero, configuration: config))
            pendingURL = nil
            restoreState = nil
            load(target)
            return
        }
        // A tab restoring its history needs a web view that has never loaded anything; a fresh tab can take the spare.
        let spare = restoreState == nil ? browser.takeSpareWebView() : nil
        let wv = spare ?? LumenWebView(frame: .zero, configuration: Tab.configuration(store: browser.dataStore))
        attach(wv)
        let state = restoreState
        let target = pendingURL
        restoreState = nil
        pendingURL = nil
        if state != nil, lastLook != nil, let image = lastLookImage {
            sleepImage = image
            waking = true
            // A page that never finishes loading isn't hidden for long.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishWaking(restoreScroll: false) }
        }
        ContentBlocker.shared.whenReady { [weak self, weak wv] in
            guard let self, let wv, self.webView === wv else { return }
            self.applyBlocking(for: target ?? self.url)
            if let state {
                wv.interactionState = state
            } else if let target {
                self.load(target)
            }
        }
    }

    private func attach(_ wv: LumenWebView) {
        wv.tab = self
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        DevTools.apply(to: wv)
        applyUserAgent()
        Tab.owners.setObject(self, forKey: wv)
        observers = [
            // Each assignment redraws every view watching the tab, so only real changes are passed on.
            wv.observe(\.title) { [weak self] w, _ in
                self?.titleChanged(w.title)
                if let self { ExtensionEvents.changed(self, title: true) }
            },
            wv.observe(\.url) { [weak self] w, _ in
                guard let self, let u = w.url, self.url != u else { return }
                self.url = u
                ExtensionEvents.changed(self, url: true)
            },
            wv.observe(\.isLoading) { [weak self] w, _ in
                guard let self, self.isLoading != w.isLoading else { return }
                self.isLoading = w.isLoading
                ExtensionEvents.changed(self, loading: true)
            },
            wv.observe(\.estimatedProgress) { [weak self] w, _ in
                guard let load = self?.load else { return }
                let p = w.estimatedProgress
                // The bar is 2 pt tall: steps under 4% can't be seen, but each one costs a redraw.
                if abs(p - load.value) >= 0.04 || p == 1 || p < load.value { if p != load.value { load.value = p } }
            },
            wv.observe(\.canGoBack) { [weak self] w, _ in if self?.canGoBack != w.canGoBack { self?.canGoBack = w.canGoBack } },
            wv.observe(\.canGoForward) { [weak self] w, _ in if self?.canGoForward != w.canGoForward { self?.canGoForward = w.canGoForward } },
            wv.observe(\.hasOnlySecureContent) { [weak self] w, _ in
                if self?.isSecure != w.hasOnlySecureContent { self?.isSecure = w.hasOnlySecureContent }
            },
            wv.observe(\.themeColor) { [weak self] w, _ in if self?.themeColor != w.themeColor { self?.themeColor = w.themeColor } },
        ]
        webView = wv
    }

    /// Keeps a small picture of the page and its scroll position as the tab goes to the background, for when it wakes.
    func rememberLook() {
        guard let wv = webView, wv.window != nil, url != nil, !isReader, !isPrivate else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: min(1200, Double(wv.bounds.width)))
        wv.takeSnapshot(with: config) { [weak self] image, _ in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            wv.evaluateJavaScript("[window.scrollX, window.scrollY]", in: nil, in: .defaultClient) { result in
                let xy = (try? result.get()) as? [Double] ?? [0, 0]
                // Compressing the picture takes a moment; it happens off the main thread so switching tabs stays quick.
                DispatchQueue.global(qos: .utility).async {
                    guard let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return }
                    DispatchQueue.main.async { self?.lastLook = (jpeg, CGPoint(x: xy.first ?? 0, y: xy.last ?? 0)) }
                }
            }
        }
    }

    /// The page has loaded after waking: puts it back where it was scrolled to if it didn't do that itself,
    /// then lets the picture fade.
    private func finishWaking(restoreScroll: Bool) {
        guard waking else { return }
        waking = false
        if restoreScroll, let wv = webView, let y = lastLook?.scroll.y, y > 40 {
            let x = lastLook?.scroll.x ?? 0
            wv.evaluateJavaScript("if (Math.abs(window.scrollY - \(y)) > 40) window.scrollTo(\(x), \(y))", in: nil, in: .defaultClient)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.sleepImage = nil }
        }
    }

    /// Releases the web view but keeps enough state to restore the page and its history.
    func hibernate() {
        guard let wv = webView else { return }
        restoreState = wv.interactionState as? Data
        pendingURL = url
        tearDown()
    }

    func close() {
        if readingAloud { MainActor.assumeIsolated { ReadAloud.shared.stop() } }
        tearDown()
    }

    private func tearDown() {
        observers = []
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        appliedLists = nil
        isLoading = false
        load.value = 0
        isPlayingAudio = false
        hoverURL = nil
    }

    func snapshot() -> TabSnapshot {
        TabSnapshot(url: url ?? pendingURL, title: title, pinned: isPinned,
                    state: (webView?.interactionState as? Data) ?? restoreState, group: groupID, lastActive: lastActive,
                    home: pinnedHome)
    }

    private func titleChanged(_ raw: String?) {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = t.isEmpty ? (url.map { InputResolver.displayHost($0) } ?? L("New Tab")) : t
        if browser?.selectedID == id { browser?.window?.title = title }
        if !isPrivate, !isReader, failedURL == nil, let u = url, !t.isEmpty { History.shared.updateTitle(url: u, title: t) }
    }

    // MARK: Actions

    func load(_ url: URL) {
        // WebKit has no view-source: pages; the source opens in a window of its own instead.
        if url.scheme?.lowercased() == "view-source" {
            // Typed in the command bar it always works; reached any other way, only in Developer Mode.
            if DevTools.enabled, let inner = URL(string: String(url.absoluteString.dropFirst("view-source:".count))) { DevTools.viewSource(of: inner) }
            return
        }
        guard let wv = webView else {
            pendingURL = url
            self.url = url
            return
        }
        failedURL = nil
        if url.isFileURL {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            wv.load(URLRequest(url: url))
        }
    }

    func load(input: String) {
        if let u = InputResolver.resolve(input) { load(u) }
    }

    func reload() {
        if let f = failedURL { load(f) } else if isReader, let o = readerOrigin { load(o) } else { webView?.reload() }
    }

    func hardReload() { webView?.reloadFromOrigin() }

    /// The network is back: a page that failed only because the Mac was offline loads again.
    func retryIfOffline() {
        guard failedOffline, webView != nil else { return }
        failedOffline = false
        reload()
    }

    /// The user agent from Settings, unless Developer Mode set one for this tab.
    func applyUserAgent() {
        webView?.customUserAgent = devUserAgent ?? UserAgent.custom
    }
    func stop() { webView?.stopLoading() }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        webView?.evaluateJavaScript("window.__lumenSetMuted && window.__lumenSetMuted(\(muted))", in: nil, in: .defaultClient)
    }

    /// Throws the web view away and makes a new one for the same address, with the right settings for it.
    func remakeWebView() {
        guard let u = url ?? pendingURL else { return }
        tearDown()
        restoreState = nil
        pendingURL = u
        if isSelected { ensureWebView() }
    }

    /// The page Reader shows, while it shows one.
    var readerSource: URL? { isReader ? readerOrigin : nil }

    func toggleReader(completion: ((Bool) -> Void)? = nil) {
        guard let wv = webView else { completion?(false); return }
        if isReader {
            isReader = false
            if let o = readerOrigin { load(o) }
            completion?(false)
            return
        }
        wv.evaluateJavaScript(Scripts.reader, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, case .success(let value) = result, let d = value as? [String: Any],
                  let html = d["html"] as? String, let origin = wv.url else {
                NSSound.beep()
                completion?(false)
                return
            }
            let words = (d["words"] as? Int) ?? (d["words"] as? Double).map(Int.init) ?? 0
            let page = Scripts.readerPage(title: d["title"] as? String ?? self.title,
                                          site: d["site"] as? String ?? "",
                                          byline: d["byline"] as? String ?? "",
                                          html: html, minutes: max(1, words / 230))
            self.showReader(html: page, origin: origin)
            completion?(true)
        }
    }

    // MARK: Site styles

    /// Applies this site's style to the open page without reloading it.
    func applySiteStyleLive() {
        guard let wv = webView, url != nil, !isReader else { return }
        let style = Settings.shared.siteStyle(for: host).flatMap { $0.enabled ? $0 : nil }
        let args: [String: Any] = ["css": style?.effectiveCSS ?? "", "floating": style?.hideFloating ?? false,
                                   "dark": style?.theme == .dark]
        Task { @MainActor in
            _ = try? await wv.callAsyncJavaScript("if (window.__lumenSiteStyle) window.__lumenSiteStyle(css, floating, dark);",
                                                  arguments: args, in: nil, contentWorld: .defaultClient)
        }
    }

    /// Lets the user click elements on the page to hide them on this site; Esc or `stopPickingElements` ends it.
    func startPickingElements() {
        guard let wv = webView, url != nil, !isReader, !pickingElements else { return }
        pickingElements = true
        let tip = L("Click what you want to hide on this site · ↑ for a bigger block · Esc when you're done")
        let data = (try? JSONSerialization.data(withJSONObject: [tip])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        wv.evaluateJavaScript(Scripts.picker.replacingOccurrences(of: "__TIP__", with: data + "[0]"), in: nil, in: .defaultClient)
        wv.window?.makeFirstResponder(wv)
    }

    func stopPickingElements() {
        guard pickingElements else { return }
        pickingElements = false
        webView?.evaluateJavaScript("window.__lumenPicker && window.__lumenPicker.stop()", in: nil, in: .defaultClient)
    }

    /// Shows a Reader page (live or saved offline) in place of `origin`, which Reader's exit goes back to.
    func showReader(html: String, origin: URL) {
        ensureWebView()
        guard let wv = webView else { return }
        readerOrigin = origin
        internalLoad = true
        internalNavigation = wv.loadHTMLString(html, baseURL: origin)
        isReader = true
    }

    func zoom(_ direction: Int) {
        let steps = Tab.zoomSteps
        let next: Double
        if direction == 0 {
            next = Settings.shared.defaultZoom
        } else if direction > 0 {
            next = steps.first { $0 > zoom + 0.001 } ?? steps.last!
        } else {
            next = steps.last { $0 < zoom - 0.001 } ?? steps.first!
        }
        setZoom(next)
    }

    func setZoom(_ z: Double) {
        zoom = z
        webView?.pageZoom = z
        guard !isPrivate, let host else { return }
        var map = Settings.shared.siteZoom
        map[host] = abs(z - Settings.shared.defaultZoom) < 0.01 ? nil : z
        Settings.shared.siteZoom = map
    }

    func find(_ text: String, backwards: Bool, done: @escaping (Bool) -> Void) {
        guard let wv = webView, !text.isEmpty else { done(true); return }
        let c = WKFindConfiguration()
        c.backwards = backwards
        c.caseSensitive = false
        c.wraps = true
        wv.find(text, configuration: c) { done($0.matchFound) }
    }

    func printPage() {
        guard let wv = webView, let window = wv.window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = true
        let op = wv.printOperation(with: info)
        op.view?.frame = wv.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Saves the whole page as a PDF.
    func exportPDF() {
        guard let wv = webView, let window = wv.window else { return }
        wv.createPDF { result in
            guard case .success(let data) = result else { NSSound.beep(); return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = Self.fileName(self.title) + ".pdf"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? data.write(to: url)
            }
        }
    }

    /// Saves what's visible on the page as a PNG where you choose, and copies it to the clipboard.
    func screenshot() {
        guard let wv = webView, let window = wv.window else { return }
        wv.takeSnapshot(with: nil) { image, _ in
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(Self.fileName(self.title)) \(stamp).png"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? png.write(to: url)
            }
        }
    }

    private static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Tacet" : String(cleaned.prefix(80))
    }

    var certificateSummary: String? {
        guard let trust = webView?.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
        let issuer = chain.count > 1 ? ((SecCertificateCopySubjectSummary(chain[1]) as String?) ?? "") : ""
        return issuer.isEmpty ? subject : "\(subject), issued by \(issuer)"
    }

    // MARK: Blocking

    func applyBlocking(for url: URL?) {
        guard let c = webView?.configuration.userContentController else { return }
        let lists = ContentBlocker.shared.lists(for: url?.host)
        let key = lists.map(\.identifier).joined(separator: ",")
        guard key != appliedLists else { return }
        appliedLists = key
        c.removeAllContentRuleLists()
        lists.forEach(c.add)
    }

    private func observeNotifications() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: .blockerChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.webView != nil else { return }
            let before = self.appliedLists
            self.applyBlocking(for: self.url)
            if before != nil, before != self.appliedLists, self.isSelected, self.url != nil { self.webView?.reload() }
        })
        tokens.append(nc.addObserver(forName: .settingChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, let wv = self.webView, let key = note.userInfo?["key"] as? String else { return }
            switch key {
            case "gpc", "cookieBanners", "rejectCookies", "fingerprinting", "plugins", "pluginsQuiet", "youtubeAds", "forceDark", "siteStyles", "adBlock", "allowlist", "recoverDrafts":
                Scripts.install(on: wv.configuration.userContentController)
                if key == "siteStyles" {
                    // The page follows style changes as they're made; your JavaScript waits for the next load.
                    self.applySiteStyleLive()
                } else if ["forceDark", "cookieBanners", "rejectCookies", "fingerprinting", "plugins", "youtubeAds", "gpc"].contains(key), self.isSelected, self.url != nil {
                    wv.reload()
                }
            case "developer":
                DevTools.apply(to: wv)
            case "uaMode", "customUA":
                self.applyUserAgent()
            default:
                break
            }
        })
    }

    // MARK: Messages from the bridge script

    func handleMessage(_ type: String, _ body: [String: Any]) {
        switch type {
        case "pickedElement":
            guard pickingElements, let selector = body["selector"] as? String, !selector.isEmpty, selector.count < 600,
                  let host else { return }
            let s = Settings.shared
            var style = s.siteStyle(for: host) ?? SiteStyle(host: SiteStyle.normalizedHost(host))
            if !style.hidden.contains(selector) { style.hidden.append(selector) }
            style.enabled = true
            s.saveSiteStyle(style)
        case "pickerDone":
            pickingElements = false
        case "favicon":
            guard let href = body["href"] as? String, let iconURL = URL(string: href), let host else { return }
            if faviconHost == host, favicon != nil { return }
            faviconHost = host
            if let cached = Favicons.shared.cached(host) { favicon = cached; return }
            let persist = !isPrivate
            Task { @MainActor [weak self] in
                guard await Favicons.mayFetch(iconURL, forPageHost: host) else { return }
                Favicons.shared.fetch(iconURL, host: host, persist: persist) { [weak self] img in
                    if self?.host == host { self?.favicon = img }
                }
            }
        case "hover":
            let link = body["url"] as? String
            if hoverURL != link { hoverURL = link }
        case "top":
            pull.atTop = body["top"] as? Bool ?? true
        case "media":
            let playing = body["playing"] as? Bool ?? false
            if isPlayingAudio != playing { isPlayingAudio = playing }
        case "loginFocus":
            guard Settings.shared.autofillPasswords else { return }
            let isNew = body["newPassword"] as? Bool ?? false
            let saved = isNew ? [] : PasswordStore.shared.logins(for: host)
            let strong = isNew && Settings.shared.suggestStrongPasswords ? PasswordStore.generate() : nil
            guard !saved.isEmpty || strong != nil || (!isNew && ExternalPasswordManager.current != nil) else { return }
            let x = (body["x"] as? Double) ?? 0, y = (body["y"] as? Double) ?? 0, w = (body["w"] as? Double) ?? 200
            loginMenu = LoginMenu(origin: CGPoint(x: x * zoom, y: y * zoom + 4), width: max(260, w * zoom), logins: saved, strongPassword: strong)
        case "loginBlur":
            if loginMenu != nil { loginMenu = nil }
        case "insecurePassword":
            insecureWarning = true
        case "draft":
            guard Settings.shared.recoverDrafts, !isPrivate, let page = url, let key = body["key"] as? String,
                  let text = body["text"] as? String else { return }
            Drafts.shared.keep(page: page, field: key, label: body["label"] as? String ?? "", text: text)
            draftOffer.removeAll { $0.field == key }
        case "draftDone":
            if let page = url, let key = body["key"] as? String { Drafts.shared.forget(page: page, field: key) }
        case "hlHover":
            hoveredHighlight = (body["id"] as? String).flatMap(UUID.init(uuidString:))
        case "preview":
            if let raw = body["url"] as? String, let u = URL(string: raw), ["http", "https"].contains(u.scheme ?? "") { browser?.openPreview(u) }
        case "passkey":
            guard let host, passkeyHelp == nil || passkeyHelp?.site != PasswordStore.site(host) else { return }
            passkeyHelp = PasskeyHelp(site: PasswordStore.site(host), url: url)
        case "loginUsername":
            if let host, let name = body["username"] as? String, !name.isEmpty { rememberedUser = (host, name, Date()) }
        case "loginSubmit":
            if loginMenu != nil { loginMenu = nil }
            offerToSave(username: body["username"] as? String ?? "", password: body["password"] as? String ?? "")
        default:
            break
        }
    }

    // MARK: Drafts

    /// Offers back what you were writing on this page last time, if it wasn't sent.
    private func offerDrafts() {
        let found = Settings.shared.recoverDrafts && !isPrivate ? Drafts.shared.on(url) : []
        if draftOffer != found { draftOffer = found }
    }

    /// Puts each draft back in its field; any whose field is gone or already filled is copied instead.
    func restoreDrafts() {
        let offer = draftOffer
        draftOffer = []
        guard let wv = webView else { return }
        var leftovers: [String] = []
        let group = DispatchGroup()
        for d in offer {
            group.enter()
            wv.callAsyncJavaScript("return window.__tacetDrafts ? window.__tacetDrafts.restore(k, t) : 'missing'",
                                   arguments: ["k": d.field, "t": d.text], in: nil, in: .defaultClient) { result in
                if ((try? result.get()) as? String) != "ok" { leftovers.append(d.text) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !leftovers.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(leftovers.joined(separator: "\n\n"), forType: .string)
            Dialogs.alert(wv.window, title: L("Your text is on the clipboard"),
                          message: L("The field it was in isn't on the page now, or already has text. Paste it where you want it.")) {}
        }
    }

    func discardDrafts() {
        Drafts.shared.forget(Set(draftOffer.map(\.id)))
        draftOffer = []
    }

    // MARK: Highlights

    /// Puts this page's highlights back, again a little later for pages that fill in as they load.
    func applyHighlights() {
        let list = Highlights.shared.on(url)
        guard !list.isEmpty, !isPrivate else { return }
        let payload = list.map { ["id": $0.id.uuidString, "quote": $0.quote, "prefix": $0.prefix, "suffix": $0.suffix, "css": $0.css, "note": $0.note] }
        // Only into the same web view, still on the same page: a later run must not mark another document.
        guard let wv = webView, let page = url.map(Highlight.pageKey) else { return }
        for delay in [0.0, 1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.webView === wv, wv.url.map(Highlight.pageKey) == page else { return }
                wv.callAsyncJavaScript("return window.__tacetHL && window.__tacetHL.apply(list)", arguments: ["list": payload],
                                                   in: nil, in: .defaultClient) { _ in }
            }
        }
    }

    /// Marks the selected text in a colour, then asks for a note when wanted.
    func highlightSelection(color: Int, askNote: Bool = false) {
        guard !isPrivate, let page = url, let wv = webView else { return }
        let id = UUID()
        let css = Highlight.colors[color % Highlight.colors.count].css
        wv.callAsyncJavaScript("return window.__tacetHL && window.__tacetHL.capture(h)", arguments: ["h": ["id": id.uuidString, "css": css, "note": ""]],
                               in: nil, in: .defaultClient) { [weak self] result in
            guard let self, let found = (try? result.get()) as? [String: Any], let quote = found["quote"] as? String else { return }
            let h = Highlight(id: id, url: Highlight.pageKey(page), title: self.title, quote: quote,
                              prefix: found["prefix"] as? String ?? "", suffix: found["suffix"] as? String ?? "", color: color)
            Highlights.shared.add(h)
            if askNote { self.editHighlightNote(id) }
        }
    }

    func editHighlightNote(_ id: UUID) {
        guard let h = Highlights.shared.items.first(where: { $0.id == id }) else { return }
        Dialogs.prompt(webView?.window, title: L("Note"), message: h.plainQuote.count > 160 ? String(h.plainQuote.prefix(160)) + "…" : h.plainQuote,
                       defaultText: h.note) { [weak self] text in
            guard let text else { return }
            let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Highlights.shared.update(id) { $0.note = note }
            self?.webView?.callAsyncJavaScript("window.__tacetHL && window.__tacetHL.note(i, t)", arguments: ["i": id.uuidString, "t": note],
                                               in: nil, in: .defaultClient) { _ in }
        }
    }

    func removeHighlight(_ id: UUID) {
        Highlights.shared.remove([id])
        webView?.callAsyncJavaScript("window.__tacetHL && window.__tacetHL.remove(i)", arguments: ["i": id.uuidString], in: nil, in: .defaultClient) { _ in }
        if hoveredHighlight == id { hoveredHighlight = nil }
    }

    // MARK: What the page said

    /// A moment after a page loads, its text is kept so the page can be found later by what it said. Pages with a
    /// password field aren't kept: what's on them is often private.
    private func keepPageText(of url: URL, in webView: WKWebView) {
        guard PageText.mayKeep(url, isPrivate: isPrivate) else { return }
        let space = browser?.spaceID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak webView] in
            guard let self, let webView, webView.url == url, !self.isReader else { return }
            let js = "if (document.querySelector('input[type=password]')) return null; const t = (document.body && document.body.innerText) || ''; return t.replace(/\\s+/g, ' ').trim().slice(0, \(PageText.charLimit))"
            webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, let text = try? result.get() as? String, webView.url == url else { return }
                PageText.shared.keep(url: url, title: self.title, text: text, space: space)
            }
        }
    }

    // MARK: Passkeys

    struct PasskeyHelp: Equatable {
        enum Stage: Equatable { case ask, inSafari, importing, failed(String), needsAccess }
        let site: String
        let url: URL?
        var stage = Stage.ask
    }

    /// Opens the page in Safari, where the passkey works, to sign in there.
    func signInWithSafari() {
        guard var help = passkeyHelp, let page = help.url ?? url,
              let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
        NSWorkspace.shared.open([page], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
        help.stage = .inSafari
        passkeyHelp = help
    }

    /// Copies the site's cookies from Safari into this tab's website data and reloads, so the sign-in made there
    /// carries on here.
    func bringSignInFromSafari() {
        guard var help = passkeyHelp, let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        help.stage = .importing
        passkeyHelp = help
        let site = help.site
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try BrowserImporter.safariSignIns(site: site) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.passkeyHelp?.site == site else { return }
                switch result {
                case .failure(BrowserImporter.ImportError.permission):
                    self.passkeyHelp?.stage = .needsAccess
                case .failure(let error):
                    self.passkeyHelp?.stage = .failed(error.localizedDescription)
                case .success(let cookies) where cookies.isEmpty:
                    self.passkeyHelp?.stage = .failed(L("Safari hasn't saved this sign-in yet. Quit Safari, then try again."))
                case .success(let cookies):
                    let group = DispatchGroup()
                    for c in cookies {
                        group.enter()
                        store.setCookie(c) { group.leave() }
                    }
                    group.notify(queue: .main) { [weak self] in
                        guard let self else { return }
                        self.passkeyHelp = nil
                        self.reload()
                    }
                }
            }
        }
    }

    // MARK: Passwords

    private func offerToSave(username raw: String, password: String) {
        let s = Settings.shared
        guard s.savePasswords, s.passwordManager.isEmpty, !isPrivate, !password.isEmpty, let host,
              !s.neverSaveHosts.contains(PasswordStore.site(host)) else { return }
        var username = raw
        if username.isEmpty, let r = rememberedUser, PasswordStore.site(r.host) == PasswordStore.site(host),
           Date().timeIntervalSince(r.at) < 600 {
            username = r.name
        }
        let store = PasswordStore.shared
        let existing = store.logins(for: host).first { $0.username == username }
        let pending = PendingLogin(host: existing?.host ?? host, username: username, password: password, isUpdate: existing != nil)
        let started = Date()
        // Comparing with the saved password reads the Keychain, which can wait on a macOS prompt: never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let unchanged = existing.map { store.matches(host: $0.host, username: username, password: password) } ?? false
            guard !unchanged else { return }
            // Wait for the sign-in to navigate, so the banner doesn't flash on the login page.
            let wait = max(0, 0.8 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self?.pendingSave = pending }
        }
    }

    func savePending() {
        guard let p = pendingSave else { return }
        PasswordStore.shared.save(host: p.host, username: p.username, password: p.password)
        pendingSave = nil
    }

    func neverSavePending() {
        guard let p = pendingSave else { return }
        Settings.shared.neverSaveHosts = Array(Set(Settings.shared.neverSaveHosts + [PasswordStore.site(p.host)])).sorted()
        pendingSave = nil
    }

    func fill(_ login: SavedLogin) {
        loginMenu = nil
        let reason = String(format: L("fill your password for %@"), login.host)
        let site = PasswordStore.site(login.host)
        guard let asked = webView, host.map(PasswordStore.site) == site else { return }
        PasswordStore.shared.password(for: login, reason: reason) { [weak self] password in
            // Touch ID takes a moment, and the page may have moved on meanwhile: the password only goes into the
            // same web view, still on the login's site, over HTTPS (or plain HTTP on the very host it was saved for).
            guard let self, let password, let wv = self.webView, wv === asked, let now = wv.url, let nowHost = now.host?.lowercased(),
                  PasswordStore.site(nowHost) == site, now.scheme == "https" || now.scheme == "http" && nowHost == login.host.lowercased()
            else { return }
            wv.window?.makeFirstResponder(wv)
            // The page checks its own address too, in case a navigation started after the one above.
            wv.callAsyncJavaScript("const h = location.hostname.toLowerCase(); if (h !== s && !h.endsWith('.' + s)) return false; return window.__lumenFill && window.__lumenFill(u, p)",
                                   arguments: ["u": login.username, "p": password, "s": site], in: nil, in: .defaultClient) { _ in }
        }
    }

    /// Puts a generated password into the sign-up form; saving is offered when the form is sent.
    func fillStrong(_ password: String) {
        loginMenu = nil
        guard let wv = webView else { return }
        wv.window?.makeFirstResponder(wv)
        wv.callAsyncJavaScript("return window.__lumenFillNew && window.__lumenFillNew(p)",
                               arguments: ["p": password], in: nil, in: .defaultClient) { _ in }
    }

    private func showHTTPSOnlyPage(_ url: URL, in webView: WKWebView, certificate: Bool = false) {
        failedURL = url
        internalLoad = true
        internalNavigation = webView.loadHTMLString(Scripts.httpsOnlyPage(url: url, certificate: certificate), baseURL: nil)
    }

    private func openExternal(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        if url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path)
        Dialogs.confirm(webView?.window, title: String(format: L("Open “%@”?"), name),
                        message: String(format: L("%@ wants to open a “%@” link in %@."), InputResolver.displayHost(self.url), url.scheme ?? "", name),
                        ok: L("Open")) { if $0 { NSWorkspace.shared.open(url) } }
    }

    private func handleError(_ error: Error, in webView: WKWebView) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        // 102: interrupted by a policy change (downloads, our own redirects). 204: handled by a plug-in.
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return }
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        if let up = upgrade, let f = failing, f.scheme == "https", f.host?.lowercased() == up.host, HTTPSUpgrade.shouldFallBack(e) {
            // A bad certificate doesn't mean the site has no HTTPS: someone on the network may be in the way. The
            // user decides, and the site isn't remembered as HTTP-only.
            let certificate = HTTPSUpgrade.isCertificateError(e)
            if !certificate { HTTPSUpgrade.httpOnly.insert(up.host) }
            upgrade = nil
            if (certificate || Settings.shared.httpsOnly) && !HTTPSUpgrade.userAllowed.contains(up.host) {
                showHTTPSOnlyPage(up.original, in: webView, certificate: certificate)
            } else {
                webView.load(URLRequest(url: up.original))
            }
            return
        }
        guard let f = failing else { return }
        failedURL = f
        failedOffline = e.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                                                         NSURLErrorDataNotAllowed, NSURLErrorCannotFindHost].contains(e.code)
        internalLoad = true
        internalNavigation = webView.loadHTMLString(Scripts.errorPage(url: f, error: e), baseURL: f)
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = Settings.shared.javaScript && !javaScriptOff
        if internalLoad {
            internalLoad = false
            decisionHandler(.allow, preferences)
            return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = action.request.url else {
            decisionHandler(.allow, preferences)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "lumen-continue-http" {
            decisionHandler(.cancel, preferences)
            let raw = String(url.absoluteString.dropFirst("lumen-continue-http:".count))
            // Only Tacet's own "Not Secure" page may lift HTTPS-only, and only for the address it was shown for.
            if let target = URL(string: raw), let h = target.host?.lowercased(), target == failedURL {
                HTTPSUpgrade.userAllowed.insert(h)
                load(target)
            }
            return
        }
        // Extension pages (settings, popups opened in a tab) use their own scheme.
        if !["http", "https", "file", "about", "data", "blob", "javascript", "webkit-extension", PluginAppScheme.scheme].contains(scheme) {
            decisionHandler(.cancel, preferences)
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true { openExternal(url) }
            return
        }
        if action.navigationType == .linkActivated,
           action.modifierFlags.contains(.command) || action.buttonNumber == 2 {
            decisionHandler(.cancel, preferences)
            browser?.openInBackground(url, from: self, select: action.modifierFlags.contains(.shift))
            return
        }
        // A pinned tab stays on its site, as in Arc: a link to another site opens in a new tab next to it.
        if isPinned, Settings.shared.pinnedStayOnSite, action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
           let from = (pinnedHome ?? self.url)?.host, let to = url.host, PasswordStore.site(from) != PasswordStore.site(to) {
            decisionHandler(.cancel, preferences)
            browser?.newTab(url: url, after: self)
            return
        }
        // In an installed web app, links to other sites open in the browser.
        if WebApp.isActive, action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
           let host = url.host, PasswordStore.site(host) != WebApp.site {
            decisionHandler(.cancel, preferences)
            WebApp.openInBrowser(url)
            return
        }
        if action.targetFrame?.isMainFrame == true {
            let s = Settings.shared
            let fresh = action.navigationType != .backForward && action.navigationType != .reload
                && (action.request.httpMethod ?? "GET") == "GET"
            if fresh, s.stripTracking, let clean = URLCleaner.unwrap(url) ?? URLCleaner.clean(url) {
                decisionHandler(.cancel, preferences)
                webView.load(URLRequest(url: clean))
                return
            }
            if fresh, s.httpsUpgrade || s.httpsOnly, HTTPSUpgrade.eligible(url), let host = url.host?.lowercased() {
                if let up = upgrade, up.host == host, Date().timeIntervalSince(up.at) < 5 {
                    // The HTTPS site redirected back to HTTP, so it doesn't want HTTPS.
                    HTTPSUpgrade.httpOnly.insert(host)
                    upgrade = nil
                    if s.httpsOnly && !HTTPSUpgrade.userAllowed.contains(host) {
                        decisionHandler(.cancel, preferences)
                        showHTTPSOnlyPage(url, in: webView)
                        return
                    }
                } else if let https = HTTPSUpgrade.upgraded(url) {
                    upgrade = (host, url, Date())
                    decisionHandler(.cancel, preferences)
                    webView.load(URLRequest(url: https))
                    return
                }
            }
            if s.httpsOnly, url.scheme == "http", let host = url.host?.lowercased(),
               HTTPSUpgrade.httpOnly.contains(host), !HTTPSUpgrade.userAllowed.contains(host) {
                decisionHandler(.cancel, preferences)
                showHTTPSOnlyPage(url, in: webView)
                return
            }
            applyBlocking(for: url)
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse,
           (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
        closeIfOnlyDownloading(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
        closeIfOnlyDownloading(webView)
    }

    /// A tab opened just for a file (a link with a new tab, an address from another app) has nothing to show once
    /// the file starts downloading, so it closes, as in Safari.
    private func closeIfOnlyDownloading(_ webView: WKWebView) {
        guard webView.backForwardList.currentItem == nil, !isPinned, let browser else { return }
        DispatchQueue.main.async { [weak self, weak browser] in
            guard let self, let browser, browser.tabs.contains(where: { $0 === self }) else { return }
            // Not kept among closed tabs: ⇧⌘T would only download the file again.
            self.url = nil
            self.pendingURL = nil
            if browser.tabs.count > 1 {
                browser.close(self)
            } else {
                // The window's only tab goes back to the start page instead of staying blank.
                self.title = L("New Tab")
                self.isLoading = false
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Each assignment redraws the views watching the tab, so only changes are made.
        if hoverURL != nil { hoverURL = nil }
        if loginMenu != nil { loginMenu = nil }
        if insecureWarning { insecureWarning = false }
        if navigation !== internalNavigation {
            if failedURL != nil { failedURL = nil }
            failedOffline = false
            if isReader { isReader = false }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if !blockedHere.isEmpty { blockedHere = [:] }
        // A new page isn't translated, and isn't the one being read aloud.
        if translatedFrom != nil { translatedFrom = nil }
        if translationError != nil { translationError = nil }
        if readingAloud { ReadAloud.shared.stop() }
        let host = webView.url?.host?.lowercased()
        let z = host.flatMap { Settings.shared.siteZoom[$0] } ?? Settings.shared.defaultZoom
        if abs(webView.pageZoom - z) > 0.001 { webView.pageZoom = z }
        if zoom != z { zoom = z }
        if host != faviconHost {
            faviconHost = nil
            favicon = Favicons.shared.cached(host)
        }
        if isPlayingAudio { isPlayingAudio = false }
        browser?.tabDidNavigate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if waking { finishWaking(restoreScroll: true) }
        // The passkey banner belongs to the site that asked; signing in may move between its pages.
        if let help = passkeyHelp, help.site != host.map(PasswordStore.site) { passkeyHelp = nil }
        guard navigation !== internalNavigation, !isPrivate, !isReader, let u = webView.url else { return }
        History.shared.record(url: u, title: webView.title ?? "")
        keepPageText(of: u, in: webView)
        applyHighlights()
        offerDrafts()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleError(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // macOS ends background pages' processes when memory runs short: such a tab sleeps, and loads again only when
        // you come back to it, instead of taking the memory straight back.
        if !isSelected, browser?.preview !== self, webView === self.webView {
            hibernate()
            return
        }
        // A page that keeps crashing its process would otherwise reload forever, using all the CPU.
        if let last = lastCrash, Date().timeIntervalSince(last) < 15, let u = url ?? webView.url {
            lastCrash = nil
            let e = NSError(domain: "WebKitErrorDomain", code: 0, userInfo: [
                NSLocalizedDescriptionKey: L("This page stopped working more than once, so Tacet stopped reloading it."),
            ])
            failedURL = u
            internalLoad = true
            internalNavigation = webView.loadHTMLString(Scripts.errorPage(url: u, error: e), baseURL: u)
            return
        }
        lastCrash = Date()
        webView.reload()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount < 3 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        Dialogs.credentials(webView.window, host: challenge.protectionSpace.host,
                            realm: challenge.protectionSpace.realm) { result in
            if let (user, pass) = result {
                completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

// MARK: - UI

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A link that opens a new tab follows the opening rules; sign-in pop-ups (sized windows) never do.
        if navigationAction.navigationType == .linkActivated, windowFeatures.width == nil, windowFeatures.height == nil,
           let url = navigationAction.request.url, OpeningRules.route(url, from: browser) { return nil }
        return browser?.openPopup(configuration: configuration, from: self, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        Dialogs.alert(webView.window, title: frame.securityOrigin.host, message: message, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        Dialogs.confirm(webView.window, title: frame.securityOrigin.host, message: message, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        Dialogs.prompt(webView.window, title: frame.securityOrigin.host, message: prompt,
                       defaultText: defaultText ?? "", done: completionHandler)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let kind = MediaPermission.Kind(type)
        let key = MediaPermission.key(host: origin.host, kind: kind)
        // Private windows remember a choice only in the tab; other windows remember it for the site.
        if let remembered = isPrivate ? mediaPermissions[key] : Settings.shared.mediaPermissions[key] {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        Dialogs.confirm(webView.window, title: String(format: L("Allow “%@” to use your %@?"), origin.host, kind.label),
                        message: L(isPrivate ? "Tacet remembers your choice until you close this tab."
                                             : "Tacet remembers your choice for this site. You can change it in Settings › Sites."),
                        ok: L("Allow"), cancel: L("Don't Allow")) { [weak self] allowed in
            guard let self else { decisionHandler(.deny); return }
            if self.isPrivate {
                self.mediaPermissions[key] = allowed
            } else {
                Settings.shared.mediaPermissions[key] = allowed
            }
            decisionHandler(allowed ? .grant : .deny)
        }
    }
}

// MARK: - Web view subclass

/// Adds Tacet's items to the page context menu.
final class LumenWebView: WKWebView {
    weak var tab: Tab?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard let tab, Settings.shared.pullToRefresh, tab.url != nil else { return }
        if tab.pull.track(event) { tab.reload() }
    }

    /// Whether the Web Inspector was already open when the right-click menu opened.
    private var inspectorWasOpen = true

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        // Inspect Element opens a new inspector inside the page's view, where Tacet's layout hides it.
        if DevTools.enabled, !inspectorWasOpen, let tab { DevTools.detachIfItOpens(tab) }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        inspectorWasOpen = DevTools.enabled ? DevTools.isInspectorOpen(tab) : true
        let renames = [
            "WKMenuItemIdentifierOpenLinkInNewWindow": L("Open Link in New Tab"),
            "WKMenuItemIdentifierOpenImageInNewWindow": L("Open Image in New Tab"),
            "WKMenuItemIdentifierOpenFrameInNewWindow": L("Open Frame in New Tab"),
            "WKMenuItemIdentifierOpenMediaInNewWindow": L("Open Video in New Tab"),
        ]
        for item in menu.items {
            if let id = item.identifier?.rawValue, let title = renames[id] { item.title = title }
        }
        addAssistantItems(to: menu)
        addHighlightItems(to: menu)
        addCutoutItem(to: menu, at: convert(event.locationInWindow, from: nil))
        addExtensionItems(to: menu)
        addDeveloperItems(to: menu)
        guard let tab, let browser = tab.browser, let link = tab.hoverURL, let url = URL(string: link) else { return }
        let anchor = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }
        var index = (anchor ?? -1) + 1
        let extra = [
            ActionMenuItem(L("Open Link in Preview")) { browser.openPreview(url) },
            ActionMenuItem(L("Open Link in Background Tab")) { browser.openInBackground(url, from: tab) },
            ActionMenuItem(L("Open Link in Split View")) {
                let t = browser.newTab(url: url, select: false, after: tab)
                browser.openSplit(t)
            },
            ActionMenuItem(L("Copy Link Without Tracking")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((URLCleaner.clean(url) ?? url).absoluteString, forType: .string)
            },
        ]
        for item in extra {
            menu.insertItem(item, at: min(index, menu.items.count))
            index += 1
        }
    }
}

extension LumenWebView {
    /// View Page Source and Page Info, next to WebKit's own Inspect Element, in Developer Mode.
    func addDeveloperItems(to menu: NSMenu) {
        guard DevTools.enabled, let tab, tab.url != nil else { return }
        let inspect = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }
        if inspect == nil { menu.addItem(.separator()) }
        var index = inspect ?? menu.items.count
        // WebKit's own item, when there, inspects the element under the pointer; didCloseMenu moves its inspector to a
        // window of its own.
        if inspect == nil { menu.insertItem(ActionMenuItem(L("Inspect Element")) { DevTools.pickElement(tab) }, at: index) }
        index += 1
        for item in [ActionMenuItem(L("View Page Source")) { DevTools.viewSource(tab) },
                     ActionMenuItem(L("Page Info")) { DevTools.pageInfo(tab) }] {
            menu.insertItem(item, at: min(index, menu.items.count))
            index += 1
        }
    }

    /// The items extensions add to the page's right-click menu, at the end.
    func addExtensionItems(to menu: NSMenu) {
        guard #available(macOS 15.4, *), let tab, tab.browser?.isPrivate == false else { return }
        let items = Extensions.shared.loaded.flatMap { $0.context.menuItems(for: tab) }
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach(menu.addItem)
    }

    /// "Remove Background with Cutout" after Copy Image, when Cutout is installed.
    func addCutoutItem(to menu: NSMenu, at point: NSPoint) {
        guard let plugin = PluginBridge.imageHandoffPlugin, let tab,
              let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyImage" }) else { return }
        // Where the click was, in the page's own coordinates.
        let y = isFlipped ? point.y : bounds.height - point.y
        let scale = pageZoom * magnification
        let x = point.x / scale, top = y / scale
        let item = ActionMenuItem(String(format: L("Remove Background with %@"), L(plugin.name))) { [weak self] in
            let js = "(() => { const el = document.elementFromPoint(\(x), \(top)); const img = el && (el.closest('img') || el.querySelector?.('img'));"
                + " return img ? (img.currentSrc || img.src) : null; })()"
            self?.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
                guard case .success(let value) = result, let src = value as? String, let url = URL(string: src) else { NSSound.beep(); return }
                Task { @MainActor in if !(await PluginBridge.send(imageAt: url, to: plugin, from: tab)) { NSSound.beep() } }
            }
        }
        item.image = NSImage(systemSymbolName: plugin.icon ?? "scissors", accessibilityDescription: nil)
        menu.insertItem(item, at: copy + 1)
    }

    /// One quiet item for selected text, after Copy: Tacet Assistant › Explain, Translate, Summarise, Ask About It.
    func addAssistantItems(to menu: NSMenu) {
        guard Settings.shared.aiEnabled, let tab, let browser = tab.browser,
              let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) else { return }
        let sub = NSMenu()
        for action in AssistantChat.SelectionAction.allCases {
            sub.addItem(ActionMenuItem(action.title) { [weak self] in
                self?.evaluateJavaScript("String(window.getSelection ? window.getSelection() : '')", in: nil, in: .defaultClient) { result in
                    guard case .success(let value) = result, let text = value as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    browser.assistantVisible = true
                    browser.assistant.act(on: text, action)
                }
            })
        }
        let item = NSMenuItem(title: L("Tacet Assistant"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        item.submenu = sub
        menu.insertItem(item, at: copy + 1)
    }
}

extension LumenWebView {
    /// Highlight for selected text; note and removal on a highlight.
    func addHighlightItems(to menu: NSMenu) {
        guard let tab, !tab.isPrivate, tab.url != nil else { return }
        if let id = tab.hoveredHighlight, Highlights.shared.items.contains(where: { $0.id == id }) {
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(ActionMenuItem(L("Remove Highlight")) { tab.removeHighlight(id) }, at: 0)
            menu.insertItem(ActionMenuItem(L("Edit Highlight Note…")) { tab.editHighlightNote(id) }, at: 0)
        }
        guard let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) else { return }
        let sub = NSMenu()
        for (i, c) in Highlight.colors.enumerated() {
            let item = ActionMenuItem(L(c.name)) { tab.highlightSelection(color: i) }
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                c.swatch.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            sub.addItem(item)
        }
        sub.addItem(.separator())
        sub.addItem(ActionMenuItem(L("Highlight with Note…")) { tab.highlightSelection(color: 0, askNote: true) })
        let item = NSMenuItem(title: L("Highlight"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
        item.submenu = sub
        menu.insertItem(item, at: copy + 1)
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

// MARK: - Dialogs

enum Dialogs {
    private static func present(_ alert: NSAlert, in window: NSWindow?, done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    static func alert(_ window: NSWindow?, title: String, message: String, done: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = title.isEmpty ? L("This page says") : title
        a.informativeText = message
        a.addButton(withTitle: L("OK"))
        present(a, in: window) { _ in done() }
    }

    static func confirm(_ window: NSWindow?, title: String, message: String, ok: String = L("OK"),
                        cancel: String = L("Cancel"), done: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = title.isEmpty ? L("This page says") : title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: cancel)
        present(a, in: window) { done($0 == .alertFirstButtonReturn) }
    }

    static func prompt(_ window: NSWindow?, title: String, message: String, defaultText: String,
                       done: @escaping (String?) -> Void) {
        let a = NSAlert()
        a.messageText = title.isEmpty ? L("This page says") : title
        a.informativeText = message
        a.addButton(withTitle: L("OK"))
        a.addButton(withTitle: L("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText
        a.accessoryView = field
        a.window.initialFirstResponder = field
        present(a, in: window) { done($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    static func credentials(_ window: NSWindow?, host: String, realm: String?, done: @escaping ((String, String)?) -> Void) {
        let a = NSAlert()
        a.messageText = String(format: L("Sign in to %@"), host)
        a.informativeText = realm.map { String(format: L("The site says: “%@”"), $0) } ?? L("This site requires a username and password.")
        a.addButton(withTitle: L("Sign In"))
        a.addButton(withTitle: L("Cancel"))
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 24))
        user.placeholderString = L("Username")
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        pass.placeholderString = L("Password")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        box.addSubview(user)
        box.addSubview(pass)
        a.accessoryView = box
        a.window.initialFirstResponder = user
        present(a, in: window) { done($0 == .alertFirstButtonReturn ? (user.stringValue, pass.stringValue) : nil) }
    }
}

@Observable
final class LoadProgress {
    var value = 0.0
}

/// Scrolling up past the top of a page with the trackpad reloads it.
@Observable
final class PullToRefresh {
    /// 0 when idle, 1 when letting go reloads the page.
    private(set) var progress: CGFloat = 0
    @ObservationIgnored var atTop = true {
        didSet { if !atTop { reset() } }
    }
    @ObservationIgnored private var pulling = false
    @ObservationIgnored private var distance: CGFloat = 0
    static let threshold: CGFloat = 190

    /// Feeds a scroll event in. Returns true when the gesture ended past the threshold.
    func track(_ e: NSEvent) -> Bool {
        // Momentum after a flick never counts, and neither do mouse wheels, which have no gesture phases.
        guard e.momentumPhase == [], e.hasPreciseScrollingDeltas else { return false }
        switch e.phase {
        case .began:
            // Only a gesture that starts at the top counts, so a long scroll up doesn't reload on arrival.
            pulling = atTop
            distance = 0
        case .changed:
            guard pulling else { return false }
            distance = max(0, distance + e.scrollingDeltaY)
            let p = min(1, distance / Self.threshold)
            if abs(p - progress) > 0.02 || (p == 1) != (progress == 1) { progress = p }
        case .ended:
            let fire = pulling && distance >= Self.threshold
            reset()
            return fire
        case .cancelled:
            reset()
        default:
            break
        }
        return false
    }

    private func reset() {
        pulling = false
        distance = 0
        if progress != 0 { progress = 0 }
    }
}

// MARK: - What Tacet Shield blocked

/// Totals since Tacet opened: everything blocked, and per site you visited. Kept in memory only.
@Observable
final class ShieldStats {
    static let shared = ShieldStats()
    private(set) var session = 0
    private(set) var bySite: [String: Int] = [:]

    func note(on site: String?) {
        session += 1
        if let site { bySite[site, default: 0] += 1 }
    }
}

extension Tab {
    /// WebKit tells its own browser about every request a content rule list blocked; it isn't public API, so the
    /// name is matched exactly and nothing breaks if a WebKit version stops calling it.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func contentRuleList(_ webView: WKWebView, identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard webView === self.webView, action.responds(to: NSSelectorFromString("blockedLoad")),
              (action.value(forKey: "blockedLoad") as? Bool) == true else { return }
        let site = url.host.map { PasswordStore.site($0) } ?? url.absoluteString
        blockedHere[site, default: 0] += 1
        ShieldStats.shared.note(on: host.map(PasswordStore.site))
    }

    var blockedCount: Int { blockedHere.values.reduce(0, +) }
}
