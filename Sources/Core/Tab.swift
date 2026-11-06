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
    /// The page is using the camera or the microphone (paused counts too: a call on mute is still a call), so it's
    /// never put to sleep or closed by itself, and its tab shows it.
    var isCapturing = false
    var cameraOn = false
    var microphoneOn = false
    /// The camera is in use, live or paused.
    var cameraInUse = false
    /// A dialog from the page is waiting for this tab to come to the front.
    var dialogWaiting = false
    /// The page's alert, confirm and prompt dialogs, one at a time on its own window.
    @ObservationIgnored lazy var dialogs: PageDialogs = {
        let d = PageDialogs()
        d.host = { [weak self] in
            guard let self, self.isSelected, let w = self.webView?.window, w.isVisible else { return nil }
            return w
        }
        d.onWaiting = { [weak self] waiting in
            if self?.dialogWaiting != waiting { self?.dialogWaiting = waiting }
        }
        return d
    }()
    /// Frames that reported playing sound, by the id each frame's media script picked, so sound in an embedded
    /// player (a YouTube or Spotify embed) shows on the tab and is muted with it.
    @ObservationIgnored var mediaFrames: [String: (frame: WKFrameInfo?, playing: Bool)] = [:]
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
    /// A pop-up the page tried to open without a click, which was blocked.
    var blockedPopup: URL?
    /// Shield was turned off here from "Site not working?": the banner asks whether to keep it off.
    var askKeepShieldOff = false
    /// Picking elements on the page to hide.
    var pickingElements = false
    /// Waiting for a click on the element to take a screenshot of.
    var pickingScreenshot = false
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
    @ObservationIgnored var waking = false
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
    @ObservationIgnored var pendingURL: URL?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var appliedLists: String?
    @ObservationIgnored var upgrade: (host: String, original: URL, at: Date)?
    @ObservationIgnored var internalLoad = false
    @ObservationIgnored var internalNavigation: WKNavigation?
    @ObservationIgnored private var readerOrigin: URL?
    @ObservationIgnored var faviconHost: String?
    /// The page loading was typed or chosen in the command bar: its visit counts as typed in the history, which ranks
    /// it above pages only reached by links.
    @ObservationIgnored var typedLoad = false
    /// Pull to refresh state, kept apart so that only the indicator redraws while you pull.
    let pull = PullToRefresh()
    /// Loading progress, kept apart so that only the progress line redraws while a page loads.
    let load = LoadProgress()
    @ObservationIgnored var mediaPermissions: [String: Bool] = [:]
    /// What the file field just clicked accepts, and when: the next open panel offers only those files.
    @ObservationIgnored var fileAccept: (value: String, at: Date)?
    @ObservationIgnored var rememberedUser: (host: String, name: String, at: Date)?
    /// The embedded frame whose sign-in field asked for the login menu, and its host.
    @ObservationIgnored var loginFrame: (frame: WKFrameInfo, host: String)?
    @ObservationIgnored var lastCrash: Date?
    /// The error page shows because the Mac was offline: it loads again by itself once the network is back.
    @ObservationIgnored var failedOffline = false

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
    var shieldsUp: Bool { Settings.shared.adBlock && !Settings.shared.isShieldOff(host) }
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
        // Inspect Element in the right-click menu, and the Web Inspector from the Develop menu. The public
        // isInspectable (set in DevTools.apply) only lets Safari's Develop menu attach from outside; the inspector
        // inside Tacet's own window and its right-click item still need this key, which has no public form.
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
            wv.observe(\.cameraCaptureState) { [weak self] _, _ in self?.captureChanged() },
            wv.observe(\.microphoneCaptureState) { [weak self] _, _ in self?.captureChanged() },
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
    func finishWaking(restoreScroll: Bool) {
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
        // WebKit needs an answer to every dialog before the page goes.
        dialogs.reset()
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
        mediaFrames = [:]
        if isCapturing { isCapturing = false; cameraOn = false; microphoneOn = false }
        hoverURL = nil
    }

    private func captureChanged() {
        guard let wv = webView else { return }
        let camera = wv.cameraCaptureState, mic = wv.microphoneCaptureState
        let capturing = camera != .none || mic != .none
        if isCapturing != capturing { isCapturing = capturing }
        if cameraOn != (camera == .active) { cameraOn = camera == .active }
        if microphoneOn != (mic == .active) { microphoneOn = mic == .active }
        if cameraInUse != (camera != .none) { cameraInUse = camera != .none }
    }

    /// Pauses the camera and microphone, or turns them back on, as the red indicator on the tab is clicked.
    func toggleCapture() {
        guard let wv = webView else { return }
        let resume = !cameraOn && !microphoneOn
        if wv.cameraCaptureState != .none { wv.setCameraCaptureState(resume ? .active : .muted) }
        if wv.microphoneCaptureState != .none { wv.setMicrophoneCaptureState(resume ? .active : .muted) }
    }

    /// Ends the page's use of the camera and microphone.
    func stopCapture() {
        webView?.setCameraCaptureState(.none)
        webView?.setMicrophoneCaptureState(.none)
    }

    /// A dialog that was waiting for the tab shows once it's in front.
    func showWaitingDialog() {
        dialogs.showNext()
    }

    /// Sound started or stopped in one of the page's frames.
    func frameMedia(id: String, frame: WKFrameInfo, playing: Bool) {
        mediaFrames[id] = (frame.isMainFrame ? nil : frame, playing)
        // A frame that starts playing in a muted tab is muted at once.
        if playing, isMuted {
            webView?.evaluateJavaScript("window.__lumenSetMuted && window.__lumenSetMuted(true)", in: frame.isMainFrame ? nil : frame, in: .defaultClient)
        }
        let any = mediaFrames.values.contains { $0.playing }
        if isPlayingAudio != any { isPlayingAudio = any }
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
        let js = "window.__lumenSetMuted && window.__lumenSetMuted(\(muted))"
        webView?.evaluateJavaScript(js, in: nil, in: .defaultClient)
        // Embedded players too; a frame that has gone since just doesn't answer.
        for case let frame? in mediaFrames.values.map(\.frame) { webView?.evaluateJavaScript(js, in: frame, in: .defaultClient) }
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
        guard let wv = webView, url != nil, !isReader, !pickingElements, !pickingScreenshot else { return }
        pickingElements = true
        let tip = L("Click what you want to hide on this site · ↑ for a bigger block · Esc when you're done")
        let data = (try? JSONSerialization.data(withJSONObject: [tip])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        wv.evaluateJavaScript(Scripts.picker.replacingOccurrences(of: "__TIP__", with: data + "[0]").replacingOccurrences(of: "__SHOT__", with: "false"),
                              in: nil, in: .defaultClient)
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

    struct FindResult: Equatable {
        var found: Bool
        /// Which match is selected (from 1) and how many the page has; 0 when they can't be counted.
        var index = 0
        var total = 0
    }

    /// Finds `text` on the page. `refine` searches again from the start of the current match, so typing another
    /// letter narrows it instead of jumping to the next one. Whole words are found by Tacet's own script, since
    /// WebKit's search has no such option; then every match is counted and highlighted.
    func find(_ text: String, backwards: Bool, caseSensitive: Bool = false, wholeWord: Bool = false, refine: Bool = false,
              done: @escaping (FindResult) -> Void) {
        guard let wv = webView, !text.isEmpty else { clearFindHighlights(); done(FindResult(found: true)); return }
        let args: [String: Any] = ["q": text, "cs": caseSensitive, "ww": wholeWord, "mode": wholeWord ? (backwards ? "prev" : "next") : "count",
                                   "refine": refine]
        let count = { [weak wv] in
            wv?.callAsyncJavaScript(Scripts.find, arguments: args, in: nil, in: .defaultClient) { result in
                let r = (try? result.get()) as? [String: Any]
                let total = (r?["total"] as? Int) ?? 0, index = (r?["index"] as? Int) ?? 0
                done(FindResult(found: total > 0, index: index, total: total))
            }
        }
        if wholeWord { count(); return }
        let start = refine ? "const s = getSelection(); if (s.rangeCount) s.collapseToStart();" : ""
        wv.evaluateJavaScript(start, in: nil, in: .defaultClient) { _ in
            let c = WKFindConfiguration()
            c.backwards = backwards
            c.caseSensitive = caseSensitive
            c.wraps = true
            wv.find(text, configuration: c) { r in
                guard r.matchFound else { self.clearFindHighlights(); done(FindResult(found: false)); return }
                count()
            }
        }
    }

    /// Opens the blocked pop-up in a new tab.
    func openBlockedPopup() {
        guard let target = blockedPopup else { return }
        blockedPopup = nil
        if target.scheme != "about" { browser?.newTab(url: target) }
    }

    /// Lets this site open pop-ups from now on, and opens the one that was blocked.
    func allowPopups() {
        guard let host else { return }
        let site = PasswordStore.site(host)
        if !Settings.shared.popupSites.contains(site) { Settings.shared.popupSites.append(site) }
        webView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        openBlockedPopup()
    }

    func clearFindHighlights() {
        webView?.evaluateJavaScript("if (window.CSS && CSS.highlights) CSS.highlights.delete('tacet-find')", in: nil, in: .defaultClient)
    }

    /// The selected text, for Use Selection for Find.
    func selectedText(_ done: @escaping (String?) -> Void) {
        guard let wv = webView else { done(nil); return }
        wv.evaluateJavaScript("String(window.getSelection ? window.getSelection() : '')", in: nil, in: .defaultClient) { result in
            let t = ((try? result.get()) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            done(t.isEmpty ? nil : String(t.prefix(200)))
        }
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
                do { try data.write(to: url) } catch { Dialogs.saveFailed(error, window: window) }
            }
        }
    }

    static func fileName(_ title: String) -> String {
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
            case "shieldTrial":
                Scripts.install(on: wv.configuration.userContentController)
                self.applyBlocking(for: self.url)
                // Only pages on the site reload, as for the allowlist; the others get it on their next load.
                if self.isSelected, self.url != nil, ShieldExceptions.covers(note.userInfo?["sites"] as? [String] ?? [], self.host) {
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
            pickingScreenshot = false
        case "pickedShot":
            guard pickingScreenshot else { return }
            pickingScreenshot = false
            let n = { (k: String) in CGFloat((body[k] as? NSNumber)?.doubleValue ?? 0) }
            screenshotElement(CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h")))
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
        case "loginFocus":
            guard Settings.shared.autofillPasswords else { return }
            loginFrame = nil
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
        case "popupBlocked":
            guard let raw = body["url"] as? String else { return }
            let target = raw.isEmpty ? nil : URL(string: raw, relativeTo: url)?.absoluteURL
            guard target == nil || ["http", "https"].contains(target?.scheme?.lowercased() ?? "") else { return }
            blockedPopup = target ?? URL(string: "about:blank")
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
    func offerDrafts() {
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

    // MARK: What the page said

    /// A moment after a page loads, its text is kept so the page can be found later by what it said. Pages with a
    /// password field aren't kept: what's on them is often private.
    func keepPageText(of url: URL, in webView: WKWebView) {
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
