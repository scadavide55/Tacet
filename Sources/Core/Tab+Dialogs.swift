import SwiftUI
import UniformTypeIdentifiers
import WebKit

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

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        // The field's `accept`, from the click that opened it a moment ago.
        if let accept = fileAccept, Date().timeIntervalSince(accept.at) < 3, !parameters.allowsDirectories {
            let types = FileAccept.types(accept.value)
            if !types.isEmpty { panel.allowedContentTypes = types }
        }
        fileAccept = nil
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

/// A file field's `accept` attribute ("image/*,.pdf") as the types an open panel offers.
enum FileAccept {
    /// Empty when there's nothing to limit, or when any part isn't understood: then every file is offered rather
    /// than hiding one the site would take.
    static func types(_ accept: String) -> [UTType] {
        var out: [UTType] = []
        for raw in accept.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !token.isEmpty else { continue }
            let type: UTType?
            switch token {
            case "image/*": type = .image
            case "audio/*": type = .audio
            case "video/*": type = .movie
            default:
                if token.hasPrefix(".") {
                    type = UTType(filenameExtension: String(token.dropFirst()))
                } else if token.contains("/"), !token.hasSuffix("/*") {
                    type = UTType(mimeType: token)
                } else {
                    type = nil
                }
            }
            guard let type else { return [] }
            if !out.contains(type) { out.append(type) }
        }
        return out
    }
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

    /// A file the user asked to save couldn't be written (a full disk, a folder without permission).
    static func saveFailed(_ error: Error, window: NSWindow?) {
        DispatchQueue.main.async {
            alert(window, title: L("The file couldn't be saved"), message: error.localizedDescription) {}
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
