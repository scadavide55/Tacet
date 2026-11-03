import Foundation
import WebKit

/// What a plugin can ask Tacet to do for it, beyond its own page. Only plugins whose signed plugin.json names a
/// `handoff` page get it: they can send an image to that page (Cutout, say), which Tacet opens in a new tab with
/// the image already in it. Tacet downloads the image itself, so it works with images from any site, but only from
/// public addresses, and only to the page the plugin's signed manifest names.
final class PluginBridge: NSObject, WKScriptMessageHandler {
    static let shared = PluginBridge()
    static let name = "tacetPlugin"
    static let maxBytes = 30_000_000

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView, let tab = Tab.owner(of: webView),
              let worldName = message.world.name, worldName.hasPrefix("TacetPlugin-"),
              let item = PluginStore.shared.installed[String(worldName.dropFirst("TacetPlugin-".count))], item.enabled,
              let handoff = item.plugin.handoff.flatMap(URL.init),
              handoff.scheme == "https" || (handoff.scheme == PluginAppScheme.scheme && handoff.host == item.plugin.id),
              let body = message.body as? [String: Any], body["action"] as? String == "handoffImage" else { return }
        let name = (body["name"] as? String).map { String($0.prefix(120)) } ?? "image"
        let referer = webView.url
        Task { @MainActor in
            guard let (data, type) = await Self.image(from: body, referer: referer) else {
                NSSound.beep()
                return
            }
            Self.open(handoff, with: data, type: type, name: name, from: tab)
        }
    }

    /// The installed, turned-on plugin whose app takes pictures (Cutout), if there is one.
    static var imageHandoffPlugin: PluginStore.Plugin? {
        PluginStore.shared.installed.values.first { $0.enabled && $0.plugin.handoff != nil && $0.plugin.app != nil }?.plugin
    }

    /// Sends a picture to a plugin's app from Tacet itself: the right-click menu and Tacet Assistant use this.
    @MainActor
    static func send(imageAt url: URL, to plugin: PluginStore.Plugin, from tab: Tab) async -> Bool {
        // A picture inside the page's own code (data:) is read from the address itself.
        var body: [String: Any] = ["url": url.absoluteString]
        let raw = url.absoluteString
        if url.scheme == "data", let comma = raw.firstIndex(of: ","), raw[..<comma].hasSuffix(";base64") {
            body = ["data": String(raw[raw.index(after: comma)...]), "type": String(raw.dropFirst(5).prefix { $0 != ";" })]
        }
        guard let page = plugin.handoff.flatMap(URL.init), let (data, type) = await image(from: body, referer: tab.url) else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        open(page, with: data, type: type, name: name.isEmpty ? "image" : name, from: tab)
        return true
    }

    /// The image the plugin sent, read in the page (base64), or downloaded here from a public address.
    private static func image(from body: [String: Any], referer: URL?) async -> (Data, String)? {
        if let b64 = body["data"] as? String, let data = Data(base64Encoded: b64), data.count <= maxBytes {
            let type = (body["type"] as? String).flatMap { $0.hasPrefix("image/") ? $0 : nil } ?? "image/png"
            return (data, type)
        }
        guard let raw = body["url"] as? String, let url = URL(string: raw), WebTools.isPublic(url),
              let host = url.host, await WebTools.resolvesPublic(host) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let referer, ["http", "https"].contains(referer.scheme ?? "") { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let session = URLSession(configuration: .ephemeral)
        // A session is kept by the system until it's let go of.
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request, delegate: WebTools.PublicRedirects.shared),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxBytes,
              let type = response.mimeType?.lowercased(), type.hasPrefix("image/"), type != "image/svg+xml" else { return nil }
        return (data, type)
    }

    /// Opens the plugin's page next to the tab and drops the image into it once the page is ready.
    @MainActor
    private static func open(_ page: URL, with data: Data, type: String, name: String, from tab: Tab) {
        guard let browser = tab.browser else { return }
        let target = browser.newTab(url: page, after: tab)
        Task { @MainActor in
            // The page may reload itself once while it starts (Cutout does, to turn on its faster engine).
            var stable = 0
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(400))
                guard let wv = target.webView, !target.isLoading, wv.url?.host == page.host else { stable = 0; continue }
                let ready = (try? await wv.evaluateJavaScript(readyScript, in: nil, contentWorld: .defaultClient)) as? Bool ?? false
                stable = ready ? stable + 1 : 0
                if stable >= 2 {
                    _ = try? await wv.callAsyncJavaScript(dropScript, arguments: ["b64": data.base64EncodedString(), "type": type, "name": name],
                                                          in: nil, contentWorld: .defaultClient)
                    return
                }
            }
        }
    }

    private static let readyScript = """
    document.readyState === 'complete' && !!document.body &&
      (location.protocol === 'tacet-plugin:' || window.crossOriginIsolated || !('serviceWorker' in navigator) || sessionStorage.getItem('cutout.coi') === '1' ||
       performance.now() > 4000)
    """

    /// The same as dropping the file on the page.
    private static let dropScript = """
    const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
    const ext = (type.split('/')[1] || 'png').replace('jpeg', 'jpg').replace(/[^a-z0-9]/g, '');
    const file = new File([bytes], name.replace(/[\\\\/:]/g, '-').replace(/\\.[a-z0-9]+$/i, '') + '.' + ext, { type });
    const dt = new DataTransfer();
    dt.items.add(file);
    window.dispatchEvent(new DragEvent('dragenter', { dataTransfer: dt, bubbles: true, cancelable: true }));
    window.dispatchEvent(new DragEvent('drop', { dataTransfer: dt, bubbles: true, cancelable: true }));
    return true;
    """
}
