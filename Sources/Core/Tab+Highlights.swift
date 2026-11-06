import SwiftUI
import WebKit

extension Tab {
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
