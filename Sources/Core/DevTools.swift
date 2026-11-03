import AppKit
import WebKit

/// A screen size for Responsive Design Mode, and the browser it pretends to be.
struct DevDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let width: CGFloat
    let height: CGFloat
    /// Nil keeps Tacet's own user agent.
    let userAgent: String?

    // Safari on iPhone and iPad gives a frozen system version and the Safari version, which matches the Mac's Safari.
    private static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(UserAgent.safariVersion) Mobile/15E148 Safari/604.1"
    private static let iPadUA = "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(UserAgent.safariVersion) Mobile/15E148 Safari/604.1"
    // Chrome sends a reduced user agent: a fixed Android version and device, and only its major version.
    private static let androidUA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(DevUserAgent.chrome).0.0.0 Mobile Safari/537.36"

    static let all: [DevDevice] = [
        DevDevice(id: "iphone-se", name: "iPhone SE", width: 375, height: 667, userAgent: iPhoneUA),
        DevDevice(id: "iphone", name: "iPhone 16", width: 393, height: 852, userAgent: iPhoneUA),
        DevDevice(id: "iphone-max", name: "iPhone 16 Pro Max", width: 440, height: 956, userAgent: iPhoneUA),
        DevDevice(id: "pixel", name: "Pixel 9", width: 412, height: 915, userAgent: androidUA),
        DevDevice(id: "ipad-mini", name: "iPad mini", width: 744, height: 1133, userAgent: iPadUA),
        DevDevice(id: "ipad", name: "iPad Air", width: 820, height: 1180, userAgent: iPadUA),
        DevDevice(id: "laptop", name: L("Small laptop"), width: 1280, height: 800, userAgent: nil),
        DevDevice(id: "desktop", name: L("Desktop"), width: 1440, height: 900, userAgent: nil),
    ]
}

/// User agents a developer can switch a tab to.
enum DevUserAgent: String, CaseIterable, Identifiable {
    case safariMac, safariiPhone, safariiPad, chromeMac, chromeAndroid, firefoxMac, edgeWindows
    var id: String { rawValue }

    /// Versions current in late 2026, so sites don't take the page for an old browser; worth raising each year.
    static let chrome = 142
    static let firefox = 145

    var name: String {
        switch self {
        case .safariMac: "Safari — macOS"
        case .safariiPhone: "Safari — iPhone"
        case .safariiPad: "Safari — iPad"
        case .chromeMac: "Chrome — macOS"
        case .chromeAndroid: "Chrome — Android"
        case .firefoxMac: "Firefox — macOS"
        case .edgeWindows: "Edge — Windows"
        }
    }

    var value: String {
        switch self {
        case .safariMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(UserAgent.safariVersion) Safari/605.1.15"
        case .safariiPhone: DevDevice.all[1].userAgent ?? ""
        case .safariiPad: DevDevice.all[5].userAgent ?? ""
        case .chromeMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chrome).0.0.0 Safari/537.36"
        case .chromeAndroid: DevDevice.all[3].userAgent ?? ""
        case .firefoxMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(Self.firefox).0) Gecko/20100101 Firefox/\(Self.firefox).0"
        case .edgeWindows: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chrome).0.0.0 Safari/537.36 Edg/\(Self.chrome).0.0.0"
        }
    }
}

/// Developer Mode: the Web Inspector and the tools in the Develop menu.
enum DevTools {
    static var enabled: Bool { Settings.shared.developer }

    /// Makes a web view inspectable, with Inspect Element in its right-click menu, while Developer Mode is on. The
    /// copy `configuration` returns shares the web view's own preferences, so this reaches pages already open.
    static func apply(to wv: WKWebView) {
        let on = enabled
        wv.isInspectable = on
        wv.configuration.preferences.setValue(on, forKey: "developerExtrasEnabled")
    }

    // MARK: Web Inspector

    /// WebKit's inspector object for a web view. It's WebKit's own, not public API, so every call is checked first.
    private static func inspector(_ tab: Tab?) -> NSObject? {
        guard let wv = tab?.webView else { return nil }
        wv.isInspectable = true
        let sel = NSSelectorFromString("_inspector")
        guard wv.responds(to: sel) else { return nil }
        return wv.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    /// Opens the inspector in a window of its own, then runs `name` in it. WebKit docks a new inspector inside the
    /// page's own view, where Tacet's layout would cover it, so it's moved to its own window as soon as it connects.
    private static func call(_ name: String?, on tab: Tab?) {
        guard let inspector = inspector(tab) else {
            Dialogs.alert(NSApp.keyWindow, title: L("The Web Inspector isn't available"),
                          message: L("Right-click the page and choose Inspect Element.")) {}
            return
        }
        let wasOpen = isConnected(inspector)
        inspector.perform(NSSelectorFromString("show"))
        whenConnected(inspector) {
            if !wasOpen { inspector.perform(NSSelectorFromString("detach")) }
            if let name, inspector.responds(to: NSSelectorFromString(name)) { inspector.perform(NSSelectorFromString(name)) }
        }
    }

    private static func isConnected(_ inspector: NSObject) -> Bool {
        (inspector.value(forKey: "isConnected") as? Bool) == true
    }

    /// Runs `then` once the inspector has connected to the page and is on screen, waiting up to three seconds.
    /// WebKit ignores `detach` while the inspector is still being set up, so it waits a moment more.
    private static func whenConnected(_ inspector: NSObject, tries: Int = 0, then: @escaping () -> Void) {
        let ready = isConnected(inspector) && (inspector.value(forKey: "isVisible") as? Bool) == true
        guard ready || tries > 60 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { whenConnected(inspector, tries: tries + 1, then: then) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: then)
    }

    static func isInspectorOpen(_ tab: Tab?) -> Bool {
        guard let wv = tab?.webView, wv.responds(to: NSSelectorFromString("_inspector")),
              let inspector = wv.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject else { return false }
        return isConnected(inspector)
    }

    /// Watches for a second after a menu closes: if WebKit's own Inspect Element opened an inspector, it's moved to a
    /// window of its own. If nothing opens, nothing happens.
    static func detachIfItOpens(_ tab: Tab, tries: Int = 0) {
        guard tries < 20 else { return }
        if isInspectorOpen(tab), let inspector = inspector(tab) {
            whenConnected(inspector) { inspector.perform(NSSelectorFromString("detach")) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { detachIfItOpens(tab, tries: tries + 1) }
    }

    /// ⌥⌘I opens the inspector, or closes it when it's already open, as in Safari.
    static func showInspector(_ tab: Tab?) {
        if let inspector = inspector(tab), isConnected(inspector), (inspector.value(forKey: "isVisible") as? Bool) == true {
            inspector.perform(NSSelectorFromString("close"))
            return
        }
        call(nil, on: tab)
    }
    static func showConsole(_ tab: Tab?) { call("showConsole", on: tab) }
    static func showResources(_ tab: Tab?) { call("showResources", on: tab) }

    /// Picks an element on the page with the pointer, then shows it in the Web Inspector.
    static func pickElement(_ tab: Tab?) {
        guard let inspector = inspector(tab) else { call(nil, on: tab); return }
        if (inspector.value(forKey: "isElementSelectionActive") as? Bool) == true { return }
        call("toggleElementSelection", on: tab)
    }

    // MARK: Page source

    static func viewSource(_ tab: Tab?) {
        guard let tab, let wv = tab.webView, let url = tab.url else { return }
        let js = """
        try {
          const r = await fetch(location.href, {cache: 'force-cache', credentials: 'include'});
          if (r.ok) return await r.text();
        } catch (e) {}
        const d = document.doctype ? new XMLSerializer().serializeToString(document.doctype) + '\\n' : '';
        return d + document.documentElement.outerHTML;
        """
        wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { result in
            let text = (try? result.get()) as? String ?? ""
            SourceWindow.show(text, url: url)
        }
    }

    /// No cookies and no cache, shared by every view-source: request rather than one session (never released) each.
    private static let sourceSession = URLSession(configuration: .ephemeral)

    /// "view-source:https://example.com" typed as an address: that page's HTML, fetched without cookies.
    static func viewSource(of url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor in
            var request = URLRequest(url: url)
            request.setValue(UserAgent.custom ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(UserAgent.applicationName)",
                             forHTTPHeaderField: "User-Agent")
            let data = (try? await sourceSession.data(for: request))?.0 ?? Data()
            SourceWindow.show(String(decoding: data, as: UTF8.self), url: url)
        }
    }

    // MARK: Page tools

    private static func run(_ js: String, on tab: Tab?) {
        tab?.webView?.evaluateJavaScript(js, in: nil, in: .page) { _ in }
    }

    /// Lets you type anywhere on the page, to try out text and layouts.
    static func toggleEditing(_ tab: Tab?) {
        run("document.designMode = document.designMode === 'on' ? 'off' : 'on'", on: tab)
    }

    /// Draws an outline around every element.
    static func toggleOutlines(_ tab: Tab?) {
        run("""
        (() => { const id = 'tacet-dev-outlines'; const old = document.getElementById(id);
          if (old) { old.remove(); return; }
          const s = document.createElement('style'); s.id = id;
          s.textContent = '* { outline: 1px solid rgba(255, 80, 60, .45) !important; outline-offset: -1px !important; }';
          document.documentElement.appendChild(s); })()
        """, on: tab)
    }

    /// Turns the page's style sheets off and on again.
    static func toggleStyles(_ tab: Tab?) {
        run("""
        (() => { const off = !document.documentElement.hasAttribute('data-tacet-nostyle');
          document.documentElement.toggleAttribute('data-tacet-nostyle', off);
          for (const s of document.styleSheets) { try { s.disabled = off; } catch (e) {} }
          for (const e of document.querySelectorAll('[style]')) {
            if (off) { e.dataset.tacetStyle = e.getAttribute('style'); e.removeAttribute('style'); }
            else if (e.dataset.tacetStyle !== undefined) { e.setAttribute('style', e.dataset.tacetStyle); delete e.dataset.tacetStyle; }
          } })()
        """, on: tab)
    }

    static func toggleJavaScript(_ tab: Tab?) {
        guard let tab else { return }
        tab.javaScriptOff.toggle()
        tab.webView?.reload()
    }

    static func setDevice(_ device: DevDevice?, on tab: Tab?) {
        guard let tab else { return }
        let uaChanged = tab.device?.userAgent != device?.userAgent
        tab.device = device
        tab.deviceLandscape = false
        if uaChanged {
            tab.devUserAgent = device?.userAgent
            tab.applyUserAgent()
            tab.webView?.reload()
        }
    }

    /// A size of your own, typed as "390 × 844" (or 390x844, 390 844).
    static func askCustomDevice(_ tab: Tab?) {
        guard let tab else { return }
        let current = tab.device.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "390 × 844"
        Dialogs.prompt(NSApp.keyWindow, title: L("Custom Size"), message: L("Width and height in points, such as 390 × 844."),
                       defaultText: current) { text in
            guard let text, let size = parseSize(text) else { return }
            setDevice(DevDevice(id: "custom-\(Int(size.width))x\(Int(size.height))", name: L("Custom"), width: size.width,
                                height: size.height, userAgent: tab.devUserAgent), on: tab)
        }
    }

    static func parseSize(_ text: String) -> CGSize? {
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count == 2, (100...4000).contains(numbers[0]), (100...4000).contains(numbers[1]) else { return nil }
        return CGSize(width: numbers[0], height: numbers[1])
    }

    static func setUserAgent(_ ua: DevUserAgent?, on tab: Tab?) {
        guard let tab else { return }
        tab.devUserAgent = ua?.value
        tab.applyUserAgent()
        tab.webView?.reload()
    }

    /// Clears what the page's data store has cached, so the next load comes from the network.
    static func emptyCaches(_ tab: Tab?) {
        let store = tab?.webView?.configuration.websiteDataStore ?? .default()
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        store.removeData(ofTypes: types, modifiedSince: .distantPast) { tab?.hardReload() }
    }

    /// Removes cookies, storage and caches of the current site only, after asking.
    static func clearSiteData(_ tab: Tab?) {
        guard let tab, let host = tab.host, let store = tab.webView?.configuration.websiteDataStore else { return }
        let site = PublicSuffix.registrable(host)
        Dialogs.confirm(NSApp.keyWindow, title: String(format: L("Clear all data for %@?"), site),
                        message: L("Cookies, storage and caches for this site are removed, and you're signed out of it."),
                        ok: L("Clear"), cancel: L("Cancel")) { ok in
            guard ok else { return }
            DataCleaner.clearSite(site, store: store) { tab.hardReload() }
        }
    }

    /// Load times, size and contents of the page, from the page's own performance records.
    static func pageInfo(_ tab: Tab?) {
        guard let wv = tab?.webView else { return }
        let js = """
        const n = performance.getEntriesByType('navigation')[0] || {};
        const res = performance.getEntriesByType('resource');
        let bytes = n.transferSize || 0; for (const r of res) bytes += r.transferSize || 0;
        let storage = 0; try { storage = localStorage.length; } catch (e) {}
        return {
          protocol: n.nextHopProtocol || '', ttfb: Math.round((n.responseStart || 0) - (n.requestStart || 0)),
          dom: Math.round(n.domContentLoadedEventEnd || 0), load: Math.round(n.loadEventEnd || 0),
          requests: res.length + 1, bytes, nodes: document.getElementsByTagName('*').length,
          scripts: document.scripts.length, styles: document.styleSheets.length, images: document.images.length,
          iframes: document.getElementsByTagName('iframe').length, cookies: document.cookie ? document.cookie.split(';').length : 0,
          storage, mode: document.compatMode, charset: document.characterSet, lang: document.documentElement.lang || '',
          viewport: innerWidth + ' × ' + innerHeight, dpr: devicePixelRatio
        };
        """
        wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { result in
            guard let d = (try? result.get()) as? [String: Any] else { return }
            func n(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
            func t(_ k: String) -> String { d[k] as? String ?? "" }
            let size = ByteCountFormatter.string(fromByteCount: Int64(n("bytes")), countStyle: .file)
            let lines = [
                String(format: L("First byte: %d ms"), n("ttfb")),
                String(format: L("Content loaded: %d ms"), n("dom")),
                String(format: L("Fully loaded: %d ms"), n("load")),
                String(format: L("Requests: %d (%@)"), n("requests"), size),
                t("protocol").isEmpty ? nil : String(format: L("Protocol: %@"), t("protocol")),
                "",
                String(format: L("Elements: %d"), n("nodes")),
                String(format: L("Scripts: %d · Style sheets: %d · Images: %d · Frames: %d"), n("scripts"), n("styles"), n("images"), n("iframes")),
                String(format: L("Cookies: %d · Local storage keys: %d"), n("cookies"), n("storage")),
                "",
                String(format: L("Viewport: %@ at %@x"), t("viewport"), "\((d["dpr"] as? NSNumber)?.stringValue ?? "1")"),
                String(format: L("Mode: %@ · Encoding: %@"), t("mode"), t("charset")),
            ].compactMap { $0 }
            let title = (tab?.title).flatMap { $0.isEmpty ? nil : $0 } ?? L("Page Info")
            Dialogs.alert(NSApp.keyWindow, title: title,
                          message: lines.joined(separator: "\n")) {}
        }
    }

    /// Other browsers on this Mac that can open the page. Menus are drawn often, so the list is looked up once.
    static func browsers(for url: URL?) -> [URL] {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return [] }
        return installedBrowsers
    }

    private static let installedBrowsers: [URL] = {
        guard let probe = URL(string: "https://example.com") else { return [] }
        let mine = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).filter { Bundle(url: $0)?.bundleIdentifier != mine }
    }()

    static func open(_ url: URL?, with app: URL) {
        guard let url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Source window

/// The page's HTML in a window of its own, coloured, with ⌘F to search it.
final class SourceWindow: NSWindowController, NSWindowDelegate {
    private static var open: [SourceWindow] = []

    static func show(_ html: String, url: URL) {
        let controller = SourceWindow(html: html, url: url)
        open.append(controller)
        controller.showWindow(nil)
    }

    private init(html: String, url: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = String(format: L("Source of %@"), url.host ?? url.absoluteString)
        window.subtitle = url.absoluteString
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isRichText = false
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.backgroundColor = .textBackgroundColor
        window.contentView = scroll
        // Plain at once, coloured a moment later: colouring a long page happens off the main thread.
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textStorage?.setAttributedString(NSAttributedString(string: html, attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        DispatchQueue.global(qos: .userInitiated).async { [weak text] in
            let coloured = Self.highlighted(html)
            DispatchQueue.main.async { text?.textStorage?.setAttributedString(coloured) }
        }
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    /// HTML with tags, attributes, strings and comments in colour; very long pages stay plain so they open quickly.
    static func highlighted(_ html: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString(string: html, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        guard html.utf16.count < 800_000 else { return out }
        let ns = html as NSString
        let all = NSRange(location: 0, length: ns.length)
        func paint(_ pattern: String, _ color: NSColor) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: html, range: all) {
                out.addAttribute(.foregroundColor, value: color, range: m.range(at: m.numberOfRanges > 1 ? 1 : 0))
            }
        }
        paint("</?[A-Za-z][\\w:-]*|/?>", .systemPink)
        paint("\\s([A-Za-z_:@][\\w:.-]*)(?=\\s*=)", .systemOrange)
        paint("=\\s*(\"[^\"]*\"|'[^']*')", .systemTeal)
        paint("<!DOCTYPE[^>]*>", .systemGray)
        paint("<!--[\\s\\S]*?-->", .systemGray)
        return out
    }
}
