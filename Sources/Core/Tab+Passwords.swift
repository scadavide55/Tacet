import SwiftUI
import WebKit

extension Tab {
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

    /// A sign-in form inside an embedded frame. Only an HTTPS frame is offered logins, and only those saved for its
    /// own site. Where its field sits in the page can't be known reliably, so the menu opens at the top of the page.
    func frameLogin(_ type: String, _ body: [String: Any], frame: WKFrameInfo) {
        let origin = frame.securityOrigin
        let frameHost = origin.host.lowercased()
        guard origin.protocol.lowercased() == "https", !frameHost.isEmpty else { return }
        switch type {
        case "loginFocus":
            guard Settings.shared.autofillPasswords, !(body["newPassword"] as? Bool ?? false) else { return }
            let saved = PasswordStore.shared.logins(for: frameHost).filter {
                PasswordStore.frameMayFill(scheme: origin.protocol, frameHost: frameHost, savedHost: $0.host)
            }
            guard !saved.isEmpty else { return }
            loginFrame = (frame, frameHost)
            loginMenu = LoginMenu(origin: CGPoint(x: 16, y: 8), width: 280, logins: saved, strongPassword: nil)
        case "loginBlur":
            if loginMenu != nil { loginMenu = nil }
        case "loginUsername":
            if let name = body["username"] as? String, !name.isEmpty { rememberedUser = (frameHost, name, Date()) }
        case "loginSubmit":
            if loginMenu != nil { loginMenu = nil }
            offerToSave(username: body["username"] as? String ?? "", password: body["password"] as? String ?? "", site: frameHost)
        default:
            break
        }
    }

    func offerToSave(username raw: String, password: String, site siteHost: String? = nil) {
        let s = Settings.shared
        guard s.savePasswords, s.passwordManager.isEmpty, !isPrivate, !password.isEmpty, let host = siteHost ?? host,
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
        if let lf = loginFrame, PasswordStore.frameMayFill(scheme: lf.frame.securityOrigin.protocol, frameHost: lf.host, savedHost: login.host) {
            guard let asked = webView else { return }
            PasswordStore.shared.password(for: login, reason: reason) { [weak self] password in
                guard let self, let password, let wv = self.webView, wv === asked else { return }
                wv.window?.makeFirstResponder(wv)
                // The frame checks its own address again: it may have moved on while Touch ID was up.
                wv.callAsyncJavaScript("const h = location.hostname.toLowerCase(); if (location.protocol !== 'https:' || (h !== s && !h.endsWith('.' + s))) return false; return window.__lumenFill && window.__lumenFill(u, p)",
                                       arguments: ["u": login.username, "p": password, "s": site], in: lf.frame, in: .defaultClient) { _ in }
            }
            return
        }
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
}
