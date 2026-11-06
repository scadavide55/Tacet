import AppKit
import WebKit

/// A small separate window for pop-ups (sign-in dialogs, payment pages) when tabs aren't wanted.
final class PopupWindow: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var observations: [NSKeyValueObservation] = []
    private let onClose: (PopupWindow) -> Void
    /// The window that opened the pop-up; links it opens go there, so a private window's stay private.
    private weak var opener: BrowserState?
    /// The page's alert, confirm and prompt dialogs, as sheets on the pop-up, one at a time.
    private lazy var dialogs: PageDialogs = {
        let d = PageDialogs()
        d.host = { [weak self] in self?.window }
        return d
    }()

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, opener: BrowserState?, onClose: @escaping (PopupWindow) -> Void) {
        self.onClose = onClose
        self.opener = opener
        let parent = opener?.window
        let width = features.width.map { CGFloat($0.doubleValue) } ?? 620
        let height = features.height.map { CGFloat($0.doubleValue) } ?? 720
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // The address is always shown, so a fake sign-in pop-up can't pass for the real site.
        observations = [
            webView.observe(\.title, options: .initial) { [weak self] w, _ in
                self?.window.title = w.title?.isEmpty == false ? w.title! : (w.url?.host ?? "")
            },
            webView.observe(\.url, options: .initial) { [weak self] w, _ in self?.updateSubtitle(w) },
            webView.observe(\.hasOnlySecureContent) { [weak self] w, _ in self?.updateSubtitle(w) },
        ]
        if let parent {
            let f = parent.frame
            window.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func updateSubtitle(_ w: WKWebView) {
        guard let url = w.url, let host = url.host else { window.subtitle = ""; return }
        let secure = url.scheme == "https" && w.hasOnlySecureContent
        window.subtitle = (secure ? "🔒 " : "⚠️ ") + host
    }

    func webViewDidClose(_ webView: WKWebView) { window.close() }

    // MARK: Navigation: other apps' links and downloads, as in a tab

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel, preferences); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "data", "blob"].contains(scheme) {
            // Another app's link (zoommtg:, mailto:...) opens only after the user says so, as in a tab.
            decisionHandler(.cancel, preferences)
            guard action.targetFrame?.isMainFrame == true || action.navigationType == .linkActivated,
                  let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
            let name = FileManager.default.displayName(atPath: app.path)
            Dialogs.confirm(window, title: String(format: L("Open “%@”?"), name),
                            message: String(format: L("%@ wants to open a “%@” link in %@."), InputResolver.displayHost(webView.url), scheme, name),
                            ok: L("Open")) { if $0 { NSWorkspace.shared.open(url) } }
            return
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
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

    /// A pop-up opened just for a file would stay an empty window; it closes once the download has started.
    private func closeIfOnlyDownloading(_ webView: WKWebView) {
        guard webView.backForwardList.currentItem == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.window.close() }
    }

    /// A site's own sign-in box (HTTP Basic or Digest), as in a tab.
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
        Dialogs.credentials(window, host: challenge.protectionSpace.host, realm: challenge.protectionSpace.realm) { result in
            if let (user, pass) = result {
                completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        observations = []
        dialogs.reset()
        onClose(self)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if let opener {
            opener.newTab(url: url)
            opener.window?.makeKeyAndOrderFront(nil)
        } else {
            WindowRegistry.shared.open([url])
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        dialogs.alert(title: frame.securityOrigin.host, message: message, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        dialogs.confirm(title: frame.securityOrigin.host, message: message, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        dialogs.prompt(title: frame.securityOrigin.host, message: prompt, defaultText: defaultText ?? "", done: completionHandler)
    }

    /// File fields in a pop-up (an upload or a document check during a payment, say) work as they do in a tab.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}
