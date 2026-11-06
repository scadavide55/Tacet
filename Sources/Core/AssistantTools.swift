import AppKit
import WebKit

/// What the assistant's tools read from pages, the history and bookmarks, beyond the page in the current tab.
enum AssistantSources {
    // MARK: History and bookmarks

    /// Visited pages whose title or address contains every word of `query`, newest first, optionally only from the last `days`.
    static func searchHistory(_ query: String, days: Int?) async -> String {
        var hits = await History.shared.searchInBackground(query, limit: 60)
        if let days, days > 0 {
            let since = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
            hits = hits.filter { $0.date >= since }
        }
        guard !hits.isEmpty else { return "No visited pages match \"\(query)\"." }
        let lines = hits.prefix(20).map { h in
            "- \(h.title.isEmpty ? h.url.absoluteString : h.title) — \(h.url.absoluteString) (last visited \(date(h.date)))"
        }
        return "<history_results query=\"\(attribute(query))\">\n" + lines.joined(separator: "\n") + "\n</history_results>"
    }

    static func searchBookmarks(_ query: String) -> String {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let hits = Bookmarks.shared.items.filter { b in
            let hay = (b.title + " " + b.url.absoluteString).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        guard !hits.isEmpty else { return "No bookmarks match \"\(query)\"." }
        let lines = hits.prefix(30).map { "- \($0.title) — \($0.url.absoluteString)" }
        return "<bookmark_results query=\"\(attribute(query))\">\n" + lines.joined(separator: "\n") + "\n</bookmark_results>"
    }

    private static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return f.string(from: d)
    }

    static func attribute(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }

    // MARK: Other tabs

    /// Gives a hibernated tab back its web view and waits up to 15 seconds for it to load, so it can be read.
    @MainActor
    static func wake(_ tab: Tab) async {
        if tab.webView == nil { tab.ensureWebView() }
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<60 where tab.isLoading { try? await Task.sleep(for: .milliseconds(250)) }
    }

    // MARK: Screenshot

    /// The visible part of a page as JPEG, sized for models to read.
    @MainActor
    static func screenshot(of webView: WKWebView) async -> Data? {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        guard let image = try? await webView.takeSnapshot(configuration: config) else { return nil }
        return AssistantChat.jpeg(image)
    }

    // MARK: YouTube transcripts

    static func isVideo(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        let youtube = host == "youtube.com" || host.hasSuffix(".youtube.com")
        return youtube && (url.path == "/watch" || url.path.hasPrefix("/shorts/") || url.path.hasPrefix("/live/"))
    }

    /// The captions of the YouTube video on the page, read the way the YouTube player reads them. Runs in Tacet's
    /// own script world, so the page can't change what the assistant gets, and asks only youtube.com.
    static let transcriptScript = #"""
    const want = (args.lang || 'en').toLowerCase();
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const id = new URL(location.href).searchParams.get('v') || location.pathname.split('/').filter(Boolean).pop();
    const stamp = (ms) => { const s = Math.floor(ms / 1000); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
    const text = (sel) => (document.querySelector(sel)?.textContent || '').replace(/\s+/g, ' ').trim();
    const head = {
      title: text('h1.ytd-watch-metadata') || document.title.replace(/ - YouTube$/, ''),
      author: text('#owner #channel-name a') || text('ytd-channel-name a'),
      length: text('.ytp-time-duration')
    };
    const fromJSON3 = (j) => (j.events || []).filter(e => e.segs)
      .map(e => '[' + stamp(e.tStartMs || 0) + '] ' + e.segs.map(s => s.utf8).join('').replace(/\s+/g, ' ').trim())
      .filter(l => !/\]\s*$/.test(l));
    // The caption file the player itself downloaded, which carries the tokens YouTube now asks for.
    const playerCaptions = async () => {
      const entries = performance.getEntriesByType('resource').map(e => e.name)
        .filter(n => n.includes('/api/timedtext') && n.includes('v=' + id));
      for (const url of entries.reverse()) {
        try {
          const u = new URL(url);
          u.searchParams.set('fmt', 'json3');
          const r = await fetch(u.toString(), { credentials: 'include' });
          const body = await r.text();
          if (!body) continue;
          const lines = fromJSON3(JSON.parse(body));
          if (lines.length) return Object.assign(head, { language: u.searchParams.get('lang') || '', lines });
        } catch (e) {}
      }
      return null;
    };
    let found = await playerCaptions();
    if (found) return found;

    // Turn captions on for a moment so the player downloads them, then put them back as they were.
    const cc = document.querySelector('.ytp-subtitles-button');
    if (cc && cc.getAttribute('aria-pressed') !== 'true' && getComputedStyle(cc).display !== 'none') {
      cc.click();
      for (let i = 0; i < 25 && !found; i++) { await sleep(200); found = await playerCaptions(); }
      if (cc.getAttribute('aria-pressed') === 'true') cc.click();
      if (found) return found;
    }

    // YouTube's own transcript panel, opened from the description.
    const segments = () => [...document.querySelectorAll('ytd-transcript-segment-renderer')];
    if (!segments().length) {
      document.querySelector('ytd-text-inline-expander #expand, tp-yt-paper-button#expand')?.click();
      await sleep(300);
      const button = document.querySelector('ytd-video-description-transcript-section-renderer button')
        || [...document.querySelectorAll('button')].find(b => /transcript|trascrizione|transcription/i.test(b.getAttribute('aria-label') || b.textContent || ''));
      if (button) {
        button.click();
        for (let i = 0; i < 40 && !segments().length; i++) await sleep(200);
        await sleep(400);
      }
    }
    const segs = segments().map(s => {
      const t = (s.querySelector('.segment-timestamp')?.textContent || '').trim();
      const line = (s.querySelector('.segment-text, yt-formatted-string.segment-text')?.textContent || '').replace(/\s+/g, ' ').trim();
      return line ? '[' + t + '] ' + line : null;
    }).filter(Boolean);
    if (segs.length) {
      // Close the panel again.
      document.querySelector('ytd-engagement-panel-section-list-renderer[target-id*="transcript"] #visibility-button button')?.click();
      return Object.assign(head, { language: '', lines: segs });
    }
    return Object.assign(head, { lines: [], none: !cc });
    """#

    static let transcriptLimit = 150_000

    /// The transcript as text for the model, or why there isn't one.
    @MainActor
    static func transcript(in webView: WKWebView, limit: Int = transcriptLimit) async -> (text: String, ok: Bool) {
        let lang = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(transcriptScript, arguments: ["args": ["lang": lang]], in: nil, contentWorld: .defaultClient)
        } catch {
            return ("The transcript couldn't be read: \(error.localizedDescription)", false)
        }
        guard let d = result as? [String: Any] else { return ("The transcript couldn't be read from this page.", false) }
        let lines = d["lines"] as? [String] ?? []
        let title = d["title"] as? String ?? ""
        guard !lines.isEmpty else {
            return ((d["none"] as? Bool ?? false) ? "This video has no captions, so there is no transcript."
                    : "YouTube didn't return a transcript for this video. It may have none, or it may need the video to be opened once.", false)
        }
        let text = AssistantLimits.clip(lines.joined(separator: "\n"), to: min(limit, transcriptLimit), what: "transcript")
        let meta = [("title", title), ("channel", d["author"] as? String ?? ""), ("length", d["length"] as? String ?? ""),
                    ("language", d["language"] as? String ?? "")].filter { !$0.1.isEmpty }
            .map { "\($0.0)=\"\(attribute($0.1))\"" }.joined(separator: " ")
        return ("<transcript \(meta)>\n\(text)\n</transcript>", true)
    }
}
