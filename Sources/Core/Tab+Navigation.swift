import SwiftUI
import WebKit

extension Tab {
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
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true { typedLoad = false }
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
            // A cleaned address has to be loaded again: WebKit gives no way to change the request it's deciding on.
            if fresh, s.stripTracking, let clean = URLCleaner.unwrap(url) ?? URLCleaner.clean(url) {
                decisionHandler(.cancel, preferences)
                webView.load(URLRequest(url: clean))
                return
            }
            // Tacet upgrades to HTTPS itself rather than with preferredHTTPSNavigationPolicy (macOS 15.2): its own way
            // never falls back to HTTP after a certificate error, shows Tacet's page for HTTPS-Only, and remembers
            // the sites that have no HTTPS; WebKit's policy can't be told any of that.
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
        // A new page has no element picker in it.
        pickingScreenshot = false
        let host = webView.url?.host?.lowercased()
        let z = host.flatMap { Settings.shared.siteZoom[$0] } ?? Settings.shared.defaultZoom
        if abs(webView.pageZoom - z) > 0.001 { webView.pageZoom = z }
        if zoom != z { zoom = z }
        if host != faviconHost {
            faviconHost = nil
            favicon = Favicons.shared.cached(host)
        }
        if isPlayingAudio { isPlayingAudio = false }
        mediaFrames = [:]
        loginFrame = nil
        if blockedPopup != nil { blockedPopup = nil }
        // Left the site, or Shield came back on: nothing to ask about any more.
        if askKeepShieldOff && !ShieldTrial.shared.isOff(host) { askKeepShieldOff = false }
        // Sites you allowed may open pop-ups without a click.
        let popupsAllowed = host.map { Settings.shared.popupSites.contains(PasswordStore.site($0)) } ?? false
        if webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically != popupsAllowed {
            webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = popupsAllowed
        }
        // Dialogs belong to the page they came from; the new page may show its own again.
        dialogs.reset()
        browser?.tabDidNavigate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if waking { finishWaking(restoreScroll: true) }
        // The passkey banner belongs to the site that asked; signing in may move between its pages.
        if let help = passkeyHelp, help.site != host.map(PasswordStore.site) { passkeyHelp = nil }
        guard navigation !== internalNavigation, !isPrivate, !isReader, let u = webView.url else { return }
        History.shared.record(url: u, title: webView.title ?? "", typed: typedLoad)
        typedLoad = false
        keepPageText(of: u, in: webView)
        applyHighlights()
        offerDrafts()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleError(error, in: webView)
    }

    /// A page that failed after it had started showing (the connection dropped while it loaded, say).
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleError(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Diagnostics.log(.webProcess, "content process ended", site: url ?? webView.url, isSelected ? "visible tab" : "background tab", level: .error)
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
        let host = challenge.protectionSpace.host.lowercased()
        // A login saved for this very host goes in first, after Touch ID; if the site turns it down, Tacet asks.
        if challenge.previousFailureCount == 0, Settings.shared.autofillPasswords, !isPrivate,
           let saved = PasswordStore.shared.logins(for: host).first(where: { $0.host.lowercased() == host }) {
            PasswordStore.shared.password(for: saved, reason: String(format: L("sign in to %@"), host)) { [weak self] password in
                DispatchQueue.main.async {
                    if let password {
                        completionHandler(.useCredential, URLCredential(user: saved.username, password: password, persistence: .forSession))
                    } else {
                        self?.askCredentials(challenge, in: webView, completionHandler: completionHandler)
                    }
                }
            }
            return
        }
        askCredentials(challenge, in: webView, completionHandler: completionHandler)
    }

    private func askCredentials(_ challenge: URLAuthenticationChallenge, in webView: WKWebView,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host.lowercased()
        Dialogs.credentials(webView.window, host: host, realm: challenge.protectionSpace.realm) { [weak self] result in
            if let (user, pass) = result {
                completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .forSession))
                // Offered for saving like any sign-in, with the same Never for This Site.
                self?.offerToSave(username: user, password: pass, site: host)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
