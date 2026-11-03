import WebKit

/// JavaScript that Tacet injects into pages. Helpers run in an isolated content world so
/// pages cannot see or spoof them; only scripts that must patch page objects run in `.page`.
enum Scripts {
    static func install(on c: WKUserContentController) {
        let s = Settings.shared
        c.removeAllUserScripts()
        c.removeScriptMessageHandler(forName: "lumen", contentWorld: .defaultClient)
        c.add(ScriptBridge.shared, contentWorld: .defaultClient, name: "lumen")

        c.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        c.addUserScript(WKUserScript(source: logins, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        c.addUserScript(WKUserScript(source: highlights, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        if s.recoverDrafts {
            c.addUserScript(WKUserScript(source: drafts, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        if s.gpc {
            c.addUserScript(WKUserScript(source: gpc, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        // Before the page's own scripts, so sites never offer a passkey Tacet can't use.
        c.addUserScript(WKUserScript(source: passkeys, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        let allow = json(s.allowlist)
        if s.adBlock && s.hideCookieBanners {
            c.addUserScript(WKUserScript(source: cookieBanners.replacingOccurrences(of: "__ALLOW__", with: allow),
                                         injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
            if s.rejectCookies {
                c.addUserScript(WKUserScript(source: rejectCookies.replacingOccurrences(of: "__ALLOW__", with: allow),
                                             injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
            }
        }
        if s.adBlock && s.youtubeAds {
            // Not main-frame only: videos embedded on other sites (Reddit, blogs) play in a YouTube frame.
            c.addUserScript(WKUserScript(source: youtube.replacingOccurrences(of: "__ALLOW__", with: allow),
                                         injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        if s.adBlock && s.fingerprintProtection {
            // In the page itself and in every frame, before any of the page's scripts run.
            c.addUserScript(WKUserScript(source: fingerprinting.replacingOccurrences(of: "__ALLOW__", with: allow)
                                            .replacingOccurrences(of: "__SEED__", with: String(sessionSeed)),
                                         injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        if s.forceDark {
            c.addUserScript(WKUserScript(source: forceDark, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }
        // Tacet Plugins the user added, each on its own sites.
        PluginStore.shared.addScripts(to: c)
        // Always installed, so a style made while a page is open applies to it right away.
        let active = s.siteStyles.filter { $0.enabled && !$0.host.isEmpty }
        let styles = active.map { ["host": $0.host.lowercased(), "css": $0.effectiveCSS, "floating": $0.hideFloating,
                                   "dark": $0.theme == .dark] as [String: Any] }
        c.addUserScript(WKUserScript(source: siteStyles.replacingOccurrences(of: "__RULES__", with: json(styles))
                                        .replacingOccurrences(of: "__DARK__", with: json([SiteStyle.darkCSS])),
                                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        // Your own JavaScript runs in the page itself, on its site only, once the page has loaded.
        for style in active where !style.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let source = "(() => { const h = location.hostname.toLowerCase(); const site = \(json([style.host.lowercased()]))[0];\n"
                + "if (h !== site && !h.endsWith('.' + site)) return;\n" + style.js + "\n})();"
            c.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        }
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Bridge: favicon, hovered link, media state, mute

    static let bridge = #"""
    (() => {
      if (window.__lumen) return;
      window.__lumen = true;
      const post = (m) => { try { webkit.messageHandlers.lumen.postMessage(m); } catch (e) {} };

      const icon = () => {
        let best = null, bestScore = -1;
        for (const l of document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')) {
          const href = l.href;
          if (!href) continue;
          const type = (l.type || '').toLowerCase();
          if (type.includes('svg') || /\.svg(\?|$)/i.test(href)) continue;
          const sizes = ((l.sizes && l.sizes.value) || '').split(/\s+/).map(s => parseInt(s, 10) || 0);
          let size = Math.max(0, ...sizes) || (l.rel.includes('apple-touch-icon') ? 180 : 32);
          const score = 1000 - Math.abs(64 - size);
          if (score > bestScore) { best = href; bestScore = score; }
        }
        post({ type: 'favicon', href: best || (location.origin + '/favicon.ico') });
      };
      icon();
      window.addEventListener('load', icon, { once: true });

      let hovered = null;
      const setHover = (href) => { if (href !== hovered) { hovered = href; post({ type: 'hover', url: href }); } };
      // Resting on a link to another site opens the connection to it, so the click loads sooner.
      const warmed = new Set([location.origin]);
      const adHosts = /(^|\.)(doubleclick\.net|googleadservices\.com|googlesyndication\.com|adservice\.google\.[a-z.]+|adnxs\.com|taboola\.com|outbrain\.com|criteo\.(com|net)|amazon-adsystem\.com|adsrvr\.org|clickserve\.dartsearch\.net|ads\.[a-z0-9-]+\.[a-z]+)$/i;
      let warmTimer = 0;
      const warm = (href) => {
        clearTimeout(warmTimer);
        if (!href || !/^https?:/.test(href) || warmed.size > 20) return;
        warmTimer = setTimeout(() => {
          let u; try { u = new URL(href); } catch (e) { return; }
          const origin = u.origin;
          // Never toward ad and tracking networks: pointing at an ad mustn't reach them.
          if (warmed.has(origin) || adHosts.test(u.hostname)) return;
          warmed.add(origin);
          const l = document.createElement('link');
          l.rel = 'preconnect'; l.href = origin;
          (document.head || document.documentElement).appendChild(l);
        }, 80);
      };
      document.addEventListener('mouseover', (e) => {
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        const href = a && a.href && !a.href.startsWith('javascript:') ? a.href : null;
        setHover(href);
        warm(href);
      }, true);
      document.documentElement.addEventListener('mouseleave', () => setHover(null));
      // ⌥-click a link: it opens in a preview over the page instead of leaving it.
      document.addEventListener('click', (e) => {
        if (!e.altKey || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (!a || !/^https?:/.test(a.href)) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        post({ type: 'preview', url: a.href });
      }, true);
      window.addEventListener('blur', () => setHover(null));

      // Whether the page (or the panel last scrolled) is at its top, for pull to refresh.
      let atTop = true, lastScroller = null;
      const checkTop = () => {
        const top = (window.scrollY || 0) <= 0 && (!lastScroller || lastScroller.scrollTop <= 0);
        if (top !== atTop) { atTop = top; post({ type: 'top', top }); }
      };
      document.addEventListener('scroll', (e) => {
        const t = e.target;
        lastScroller = (t && t.nodeType === 1 && t !== document.documentElement && t !== document.body) ? t : null;
        checkTop();
      }, { capture: true, passive: true });

      let playing = false;
      const media = () => {
        const now = [...document.querySelectorAll('video, audio')].some(m =>
          !m.paused && !m.ended && m.readyState > 2 && m.volume > 0 && (!m.muted || window.__lumenMuted));
        if (now !== playing) { playing = now; post({ type: 'media', playing: now }); }
      };
      for (const ev of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) {
        document.addEventListener(ev, (e) => {
          if (window.__lumenMuted && (ev === 'play' || ev === 'playing') && e.target) e.target.muted = true;
          media();
        }, true);
      }
      window.__lumenSetMuted = (m) => {
        window.__lumenMuted = m;
        document.querySelectorAll('video, audio').forEach(v => { v.muted = m; });
        media();
      };
    })();
    """#

    // MARK: Drafts

    /// Tells Tacet what you're writing in a field, a moment after you stop typing, so it can be put back after a reload.
    /// Only text of some length, never in password, card or one-time-code fields; a sent form or an emptied field
    /// clears it.
    static let drafts = #"""
    (() => {
      if (window.__tacetDrafts) return;
      const post = (m) => { try { webkit.messageHandlers.lumen.postMessage(m); } catch (e) {} };
      const fields = () => [...document.querySelectorAll('textarea, input, [contenteditable=""], [contenteditable="true"]')];
      const fieldOf = (t) => {
        let el = null;
        if (t instanceof HTMLTextAreaElement) el = t;
        else if (t instanceof HTMLInputElement && /^(text|email|url|)$/.test(t.type)) el = t;
        else if (t && t.isContentEditable) { el = t; while (el.parentElement && el.parentElement.isContentEditable) el = el.parentElement; }
        if (!el) return null;
        if (el.type === 'password' || /cc-|password|one-time-code/.test(el.getAttribute('autocomplete') || '')) return null;
        const key = el.name ? 'name:' + el.name : el.id ? 'id:' + el.id : el.tagName.toLowerCase() + ':' + fields().indexOf(el);
        const label = (el.labels && el.labels[0] && el.labels[0].textContent) || el.getAttribute('aria-label')
          || el.placeholder || el.getAttribute('data-placeholder') || '';
        return { el, key, label: label.trim().slice(0, 80) };
      };
      const valueOf = (el) => (el.isContentEditable ? el.innerText : el.value) || '';
      const report = (f) => {
        const text = valueOf(f.el);
        if (text.trim().length >= 40) post({ type: 'draft', key: f.key, label: f.label, text: text.slice(0, 20000) });
        else if (!text.trim()) post({ type: 'draftDone', key: f.key });
      };
      const timers = new Map();
      document.addEventListener('input', (e) => {
        const f = fieldOf(e.composedPath ? e.composedPath()[0] : e.target);
        if (!f) return;
        clearTimeout(timers.get(f.key));
        timers.set(f.key, setTimeout(() => report(f), 1200));
      }, true);
      // Chats send with Return and empty the box without an input event: check it a moment later.
      document.addEventListener('keydown', (e) => {
        if (e.key !== 'Enter' || e.shiftKey) return;
        const f = fieldOf(e.composedPath ? e.composedPath()[0] : e.target);
        if (f) setTimeout(() => { if (!valueOf(f.el).trim()) post({ type: 'draftDone', key: f.key }); }, 1500);
      }, true);
      document.addEventListener('submit', (e) => {
        for (const el of e.target.querySelectorAll('textarea, input, [contenteditable]')) { const f = fieldOf(el); if (f) post({ type: 'draftDone', key: f.key }); }
      }, true);
      window.__tacetDrafts = {
        /// Puts the text back in its field if the field is there and empty: 'ok', 'busy' or 'missing'.
        restore(key, text) {
          const el = fields().find((x) => { const f = fieldOf(x); return f && f.key === key; });
          if (!el) return 'missing';
          if (valueOf(el).trim()) return 'busy';
          el.focus();
          if (el.isContentEditable) {
            document.execCommand('insertText', false, text);
          } else {
            const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
            setter ? setter.call(el, text) : (el.value = text);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          return 'ok';
        },
      };
    })();
    """#

    // MARK: Highlights

    /// Marks passages on the page. Each is found by its words and the characters around them, in the page's text as
    /// written (scripts and styles left out), and wrapped piece by piece so it can span links, bold and paragraphs.
    static let highlights = #"""
    (() => {
      if (window.__tacetHL) return;
      const post = (m) => { try { webkit.messageHandlers.lumen.postMessage(m); } catch (e) {} };
      const index = () => {
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
          acceptNode: (n) => n.parentElement && !n.parentElement.closest('script, style, noscript, textarea, title') ? 1 : 2,
        });
        const nodes = [], starts = [];
        let text = '', n;
        while ((n = walker.nextNode())) { nodes.push(n); starts.push(text.length); text += n.data; }
        return { nodes, starts, text };
      };
      const wrap = (idx, start, end, h) => {
        let count = 0;
        for (let i = 0; i < idx.nodes.length; i++) {
          const ns = idx.starts[i], ne = ns + idx.nodes[i].data.length;
          if (ne <= start || ns >= end) continue;
          let node = idx.nodes[i];
          const a = Math.max(start, ns) - ns, b = Math.min(end, ne) - ns;
          if (!node.data.slice(a, b).trim()) continue;
          if (b < node.data.length) node.splitText(b);
          if (a > 0) node = node.splitText(a);
          const m = document.createElement('mark');
          m.className = 'tacet-hl';
          m.dataset.tacetHl = h.id;
          m.style.cssText = 'background:' + h.css + ' !important; color: inherit !important; border-radius: 2px; padding: 0; box-decoration-break: clone';
          if (h.note) m.title = h.note;
          node.parentNode.insertBefore(m, node);
          m.appendChild(node);
          count++;
        }
        return count;
      };
      const marked = (id) => document.querySelector('mark[data-tacet-hl="' + id + '"]');

      window.__tacetHL = {
        /// The selection's words and surroundings, marked at once with the id and colour given.
        capture(h) {
          const sel = getSelection();
          if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
          const r = sel.getRangeAt(0), idx = index();
          let start = -1, end = -1;
          idx.nodes.forEach((n, i) => {
            if (!r.intersectsNode(n)) return;
            if (start < 0) start = idx.starts[i] + (n === r.startContainer ? r.startOffset : 0);
            end = idx.starts[i] + (n === r.endContainer ? r.endOffset : n.data.length);
          });
          if (start < 0 || end <= start || !idx.text.slice(start, end).trim()) return null;
          const out = { quote: idx.text.slice(start, end), prefix: idx.text.slice(Math.max(0, start - 32), start), suffix: idx.text.slice(end, end + 32) };
          wrap(idx, start, end, h);
          sel.removeAllRanges();
          return out;
        },
        /// Puts saved highlights back; returns how many were found.
        apply(list) {
          let found = 0;
          for (const h of list) {
            if (marked(h.id)) { found++; continue; }
            const idx = index();
            let at = idx.text.indexOf(h.prefix + h.quote + h.suffix);
            if (at >= 0) at += h.prefix.length; else at = idx.text.indexOf(h.quote);
            if (at >= 0 && wrap(idx, at, at + h.quote.length, h)) found++;
          }
          return found;
        },
        remove(id) {
          document.querySelectorAll('mark[data-tacet-hl="' + id + '"]').forEach((m) => {
            const parent = m.parentNode;
            while (m.firstChild) parent.insertBefore(m.firstChild, m);
            parent.removeChild(m);
            parent.normalize();
          });
        },
        note(id, text) { document.querySelectorAll('mark[data-tacet-hl="' + id + '"]').forEach((m) => { m.title = text; }); },
      };

      // Which highlight the pointer is on, for the right-click menu.
      let hovered = null;
      document.addEventListener('mouseover', (e) => {
        const m = e.target && e.target.closest ? e.target.closest('mark.tacet-hl') : null;
        const id = m ? m.dataset.tacetHl : null;
        if (id !== hovered) { hovered = id; post({ type: 'hlHover', id }); }
      }, true);
    })();
    """#

    // MARK: Passkeys

    /// Passkeys in an app's web view need a permission Apple gives only to browsers in its developer program, which
    /// Tacet doesn't have yet, so WebKit turns every request down. When a site asks for one, this tells Tacet, so it
    /// can offer to sign in with Safari instead. Sites still see passkeys as available: hiding them makes some
    /// (GitHub) drop the passkey button without asking, and then there'd be no moment to offer Safari.
    static let passkeys = #"""
    (() => {
      if (!window.PublicKeyCredential || window.__tacetPasskeys) return;
      window.__tacetPasskeys = true;
      // On the prototype: WebKit ignores methods set on navigator.credentials itself.
      const proto = window.CredentialsContainer && CredentialsContainer.prototype;
      for (const name of ['get', 'create']) {
        const original = proto && proto[name];
        if (!original) continue;
        Object.defineProperty(proto, name, { configurable: true, writable: true, value: function (options) {
          // Quiet requests made while the page loads (passkey autofill) don't count as asking: WebKit answers them.
          if (!options || !options.publicKey || options.mediation === 'conditional') return original.call(this, options);
          window.dispatchEvent(new CustomEvent('tacet-passkey'));
          return Promise.reject(new DOMException('Passkeys are not available in this browser.', 'NotAllowedError'));
        } });
      }
    })();
    """#

    // MARK: Logins: find sign-in fields, offer saved accounts, fill them, and notice submitted credentials

    static let logins = #"""
    (() => {
      if (window.__lumenLogins) return;
      window.__lumenLogins = true;
      const post = (m) => { try { webkit.messageHandlers.lumen.postMessage(m); } catch (e) {} };
      // The passkeys script runs in the page and can't reach Tacet itself, so it says so with an event.
      window.addEventListener('tacet-passkey', () => post({ type: 'passkey' }));
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
      };
      const textual = (i) => i instanceof HTMLInputElement && /^(text|email|tel|)$/.test(i.type);
      const userish = (i) => textual(i) && (i.type === 'email' ||
        /user|email|e-mail|login|account|identifier|mail|phone/i.test([i.autocomplete, i.name, i.id, i.placeholder, i.getAttribute('aria-label')].join(' ')));
      // Sign-in forms built from web components (Reddit's, for one) keep their fields in shadow roots, which
      // querySelectorAll doesn't enter: walk the open ones too, in page order.
      const deepAll = (root, sel, out = []) => {
        for (const el of root.querySelectorAll('*')) {
          if (el.matches(sel)) out.push(el);
          if (el.shadowRoot) deepAll(el.shadowRoot, sel, out);
        }
        return out;
      };
      // The field itself rather than the component around it, which is what events and activeElement report.
      const inner = (e) => (e.composedPath ? e.composedPath()[0] : e.target);
      const active = () => {
        let a = document.activeElement;
        while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
        return a instanceof HTMLInputElement ? a : null;
      };
      const fields = (anchor) => {
        const scope = (anchor && anchor.form) || document;
        const all = deepAll(scope, 'input').filter(visible);
        const pw = all.find((i) => i.type === 'password') || null;
        let user = all.find((i) => /(^|\s)(username|email)(\s|$)/.test(i.autocomplete || '')) || null;
        if (!user) {
          const inputs = all.filter(textual);
          const before = pw ? inputs.filter((i) => all.indexOf(i) < all.indexOf(pw)) : inputs.filter(userish);
          user = before.reverse().find(userish) || before[0] || null;
        }
        return { user, pw };
      };

      // Only tells Tacet when a menu may be showing, so scrolling doesn't send a message every frame.
      let menuOpen = false;
      document.addEventListener('focusin', (e) => {
        const t = inner(e);
        if (!(t instanceof HTMLInputElement)) return;
        const f = fields(t);
        const isPw = t.type === 'password';
        if (!isPw && !(f.pw && t === f.user) && !(!f.pw && userish(t) && /username|email/.test(t.autocomplete || ''))) return;
        if (isPw && location.protocol === 'http:') post({ type: 'insecurePassword' });
        const r = t.getBoundingClientRect();
        const scope = t.form || document;
        const isNew = isPw && (/new-password/.test(t.autocomplete || '') ||
          deepAll(scope, 'input[type=password]').filter(visible).length > 1 ||
          /sign.?up|register|create|join|iscri|registra|inscri|nuova password|new password|nouveau mot/i.test(
            [scope.action || '', scope.id || '', scope.className || '', t.name, t.id, t.placeholder].join(' ')));
        post({ type: 'loginFocus', x: r.left, y: r.bottom, w: r.width, newPassword: isNew });
        menuOpen = true;
      }, true);
      const hide = () => { if (menuOpen) { menuOpen = false; post({ type: 'loginBlur' }); } };
      document.addEventListener('mousedown', (e) => { if (!(inner(e) instanceof HTMLInputElement)) hide(); }, true);
      window.addEventListener('scroll', hide, { passive: true, capture: true });

      let last = '';
      const capture = (anchor) => {
        const f = fields(anchor);
        if (!f.pw || !f.pw.value) {
          if (f.user && f.user.value && userish(f.user)) post({ type: 'loginUsername', username: f.user.value });
          return;
        }
        const key = (f.user ? f.user.value : '') + '\u0001' + f.pw.value;
        if (key === last) return;
        last = key;
        post({ type: 'loginSubmit', username: f.user ? f.user.value : '', password: f.pw.value });
      };
      document.addEventListener('submit', (e) => capture(e.target.querySelector('input')), true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && inner(e) instanceof HTMLInputElement) capture(inner(e));
      }, true);
      document.addEventListener('click', (e) => {
        const b = e.composedPath().find((el) => el.matches && el.matches('button, input[type=submit], [role=button]'));
        if (!b) return;
        const label = [b.textContent, b.value, b.getAttribute('aria-label')].join(' ');
        if (b.type === 'submit' || /log\s?in|sign\s?in|accedi|entra|connexion|connecter|continu|next|avanti|suivant|submit/i.test(label)) {
          capture(b.form ? b.form.querySelector('input') : active());
        }
      }, true);

      window.__lumenFillNew = (password) => {
        const anchor = active();
        const scope = (anchor && anchor.form) || document;
        const fields = deepAll(scope, 'input[type=password]').filter(visible)
          .filter((p) => !/current-password/.test(p.autocomplete || ''));
        for (const el of fields) {
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, password);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        return fields.length;
      };

      window.__lumenFill = (username, password) => {
        const anchor = active();
        const f = fields(anchor);
        const set = (el, v) => {
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        const user = f.user || (anchor && textual(anchor) ? anchor : null);
        if (user && username) set(user, username);
        if (f.pw) { set(f.pw, password); f.pw.focus(); }
        return !!(f.pw || user);
      };
    })();
    """#

    // MARK: HTTPS-only interstitial

    static func httpsOnlyPage(url: URL, certificate: Bool = false) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let host = url.host ?? url.absoluteString
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(L("Not Secure")))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center;
               font: 15px -apple-system, sans-serif; color: #6e6e73; background: Canvas; }
        .box { max-width: 480px; text-align: center; padding: 24px; }
        .icon { font-size: 44px; margin-bottom: 14px; }
        h1 { color: CanvasText; font-size: 24px; font-weight: 600; margin: 0 0 10px; }
        p { line-height: 1.5; margin: 0 0 24px; }
        a { display: inline-block; padding: 8px 18px; border-radius: 8px; text-decoration: none; font-weight: 500; margin: 0 4px; }
        .back { background: #5e5ce6; color: white; }
        .go { color: #d9534f; }
        </style></head><body><div class="box"><div class="icon">🔒</div>
        <h1>\(esc(certificate ? L("This site's secure connection has a problem") : L("This site doesn't support a secure connection")))</h1>
        <p>\(esc(certificate ? String(format: L("The certificate %@ presented isn't valid. Someone on your network could be in the way. Continuing opens the site over plain HTTP, where what you send can be read."), host)
            : String(format: L("HTTPS-only mode is on. %@ only works over HTTP, so anyone on your network could see or change what you send."), host)))</p>
        <a class="back" href="javascript:history.back()">\(esc(L("Go Back")))</a>
        <a class="go" href="lumen-continue-http:\(esc(url.absoluteString))">\(esc(L("Continue to Site")))</a>
        </div></body></html>
        """
    }

    // MARK: Global Privacy Control

    static let gpc = #"""
    (() => {
      try {
        Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: () => true, configurable: true });
      } catch (e) {}
    })();
    """#

    // MARK: Cookie banners

    static let cookieBanners = #"""
    (() => {
      const allow = __ALLOW__;
      const h = location.hostname;
      if (allow.some(d => h === d || h.endsWith('.' + d))) return;
      const sel = [
        '#onetrust-banner-sdk', '#onetrust-consent-sdk', '.onetrust-pc-dark-filter', '#CybotCookiebotDialog',
        '#CybotCookiebotDialogBodyUnderlay', '#usercentrics-root', '#usercentrics-cmp-ui', '#didomi-host',
        '.qc-cmp2-container', '#qc-cmp2-container', '.fc-consent-root', '#cmpbox', '#cmpbox2', '.cmpboxBG',
        '#truste-consent-track', '#consent_blackbar', '.truste_overlay', '.truste_box_overlay', '.osano-cm-window',
        '.osano-cm-dialog', '#cookie-law-info-bar', '.cli-modal-backdrop', '.cc-window', '.cc-banner',
        '#cookiescript_injected', '#iubenda-cs-banner', '#hs-eu-cookie-confirmation', '#BorlabsCookieBox',
        '#moove_gdpr_cookie_info_bar', '#tarteaucitronRoot', '#axeptio_overlay', '.klaro', '#klaro',
        '[id^="sp_message_container_"]', '#sp-cc', '#gdpr-cookie-message', '#cookie-banner', '.cookie-banner',
        '#cookie-notice', '.cookie-notice', '#cookieConsent', '.cookie-consent', '#cookie-consent',
        '.evidon-banner', '#_evidon_banner', '#termly-code-snippet-support', '.cky-consent-container', '.cky-overlay',
        '#ccc', '.ch2-container', '#cmp-app-container', '.cmp-root', '#gdpr-consent-tool-wrapper',
      ].join(',');
      const style = document.createElement('style');
      style.textContent = sel + '{display:none!important;visibility:hidden!important}';
      (document.head || document.documentElement).appendChild(style);
      const unlock = () => {
        if (!document.querySelector(sel)) return;
        for (const el of [document.documentElement, document.body]) {
          if (!el) continue;
          if (getComputedStyle(el).overflow === 'hidden' || getComputedStyle(el).overflowY === 'hidden') {
            el.style.setProperty('overflow', 'auto', 'important');
          }
          el.classList.remove('didomi-popup-open', 'sp-message-open', 'qc-cmp-ui-showing', 'cmp-open', 'no-scroll');
        }
      };
      document.addEventListener('DOMContentLoaded', unlock);
      window.addEventListener('load', unlock);
      setTimeout(unlock, 1500);
      setTimeout(unlock, 4000);
    })();
    """#

    // MARK: Fingerprinting

    /// New for every launch of Tacet, so a site sees the same readings while you use it, but not tomorrow.
    static let sessionSeed = UInt32.random(in: 1...UInt32.max)

    /// Fingerprinting scripts draw on a canvas, render WebGL or process audio and read back the result, which differs
    /// slightly between Macs. Tacet changes a few of those values by the smallest step, differently for each site
    /// (so sites can't link visits) but the same within a site (so nothing flickers or breaks). It also hides the
    /// exact graphics chip and reports a common number of processor cores.
    static let fingerprinting = #"""
    (() => {
      const allow = __ALLOW__;
      const h = location.hostname;
      if (!h || allow.some(d => h === d || h.endsWith('.' + d))) return;
      // A small random generator seeded from this launch and the site's name.
      let seed = __SEED__ >>> 0;
      for (const c of h.split('.').slice(-2).join('.')) seed = Math.imul(seed ^ c.charCodeAt(0), 2654435761) >>> 0;
      const rand = (n) => { let x = (seed ^ Math.imul(n + 1, 0x9E3779B1)) >>> 0; x ^= x << 13; x ^= x >>> 17; x ^= x << 5; return (x >>> 0) / 4294967296; };

      // Canvas: a handful of pixels, chosen from the seed, move by one step in one colour.
      const noisy = (data, width, height) => {
        const pixels = width * height;
        if (!pixels || pixels > 4000000) return;
        const count = Math.min(20, Math.max(1, pixels >> 10));
        for (let i = 0; i < count; i++) {
          const p = Math.floor(rand(i) * pixels) * 4 + Math.floor(rand(i + 99) * 3);
          data[p] = data[p] ^ 1;
        }
      };
      const Ctx = CanvasRenderingContext2D.prototype;
      const getImageData = Ctx.getImageData;
      Ctx.getImageData = function (...args) {
        const img = getImageData.apply(this, args);
        noisy(img.data, img.width, img.height);
        return img;
      };
      // toDataURL and toBlob read a noisy copy, so the canvas on screen stays as drawn.
      const copy = (canvas) => {
        if (!canvas.width || !canvas.height || canvas.width * canvas.height > 4000000) return null;
        const c = document.createElement('canvas');
        c.width = canvas.width; c.height = canvas.height;
        const ctx = c.getContext('2d');
        try { ctx.drawImage(canvas, 0, 0); } catch (e) { return null; }
        const img = getImageData.call(ctx, 0, 0, c.width, c.height);
        noisy(img.data, img.width, img.height);
        ctx.putImageData(img, 0, 0);
        return c;
      };
      const C = HTMLCanvasElement.prototype;
      const toDataURL = C.toDataURL, toBlob = C.toBlob;
      C.toDataURL = function (...args) { const c = copy(this); return toDataURL.apply(c || this, args); };
      C.toBlob = function (...args) { const c = copy(this); return toBlob.apply(c || this, args); };

      // WebGL: the graphics chip's exact name becomes Apple's generic one.
      for (const GL of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
        if (!GL) continue;
        const getParameter = GL.prototype.getParameter;
        GL.prototype.getParameter = function (p) {
          if (p === 37445) return 'Apple Inc.';
          if (p === 37446) return 'Apple GPU';
          return getParameter.call(this, p);
        };
      }

      // Audio: rendered sound moves by an amount far below hearing, once per buffer.
      if (window.AudioBuffer) {
        const getChannelData = AudioBuffer.prototype.getChannelData;
        const done = new WeakSet();
        AudioBuffer.prototype.getChannelData = function (...args) {
          const data = getChannelData.apply(this, args);
          if (!done.has(data)) {
            done.add(data);
            for (let i = 0; i < data.length; i += 100) data[i] += (rand(i) - 0.5) * 1e-7;
          }
          return data;
        };
      }

      // A common core count instead of this Mac's exact one.
      try { Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', { get: () => 8, configurable: true }); } catch (e) {}
    })();
    """#

    // MARK: Rejecting cookies

    /// Presses the "reject" button of the consent tools sites use most, once per page. Only buttons inside a
    /// known consent banner are ever pressed, so nothing else on the page can be clicked by mistake.
    static let rejectCookies = #"""
    (() => {
      const allow = __ALLOW__;
      const h = location.hostname;
      if (allow.some(d => h === d || h.endsWith('.' + d))) return;
      const buttons = [
        '#onetrust-reject-all-handler', '.ot-pc-refuse-all-handler',
        '#CybotCookiebotDialogBodyButtonDecline', '#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll',
        '#didomi-notice-disagree-button', '.didomi-continue-without-agreeing',
        '.iubenda-cs-reject-btn', '.cky-btn-reject', '#cookie_action_close_header_reject', '.cmplz-deny',
        '.osano-cm-denyAll', '.cm-btn-decline', '#axeptio_btn_dismiss', '#truste-consent-required',
        '[data-tid="banner-decline"]', '#cookiescript_reject', '.moove-gdpr-infobar-reject-btn',
        '#tarteaucitronAllDenied2', '.cmpboxbtnno', '.fc-cta-do-not-consent', '#hs-eu-decline-button',
        '[data-testid="uc-deny-all-button"]',
      ];
      const banners = [
        '#onetrust-banner-sdk', '#CybotCookiebotDialog', '#didomi-host', '.qc-cmp2-container', '.fc-consent-root',
        '#cmpbox', '#iubenda-cs-banner', '.cky-consent-container', '#cookie-law-info-bar', '.cmplz-cookiebanner',
        '.osano-cm-dialog', '.klaro', '#axeptio_overlay', '#cookiescript_injected', '#moove_gdpr_cookie_info_bar',
        '#tarteaucitronRoot', '#hs-eu-cookie-confirmation', '#usercentrics-root', '#BorlabsCookieBox', '.cc-window',
      ].join(',');
      // Words for "reject" on a banner's own buttons, for banners whose button has no known name.
      const reject = /^\s*(reject|decline|deny|refuse|disagree|only necessary|necessary only|essential only|rifiuta|nega|solo necessari|refuser|tout refuser|continuer sans accepter|ablehnen|alle ablehnen|nur notwendige|rechazar|recusar|weigeren)\b/i;
      let done = false;
      const press = (el) => { el.click(); done = true; };
      const roots = () => {
        const out = [document];
        const uc = document.querySelector('#usercentrics-root');
        if (uc && uc.shadowRoot) out.push(uc.shadowRoot);
        return out;
      };
      const tryReject = () => {
        if (done) return;
        for (const root of roots()) {
          for (const sel of buttons) {
            const b = root.querySelector(sel);
            if (b) { press(b); return; }
          }
        }
        for (const banner of document.querySelectorAll(banners)) {
          const b = [...banner.querySelectorAll('button, a[role="button"], [role="button"]')]
            .find(x => reject.test((x.innerText || x.textContent || '').trim()));
          if (b) { press(b); return; }
        }
      };
      tryReject();
      if (done) return;
      // Most banners arrive a moment after the page; watch for 15 seconds, then stop.
      let queued = false;
      const watcher = new MutationObserver(() => {
        if (queued) return;
        queued = true;
        setTimeout(() => { queued = false; tryReject(); if (done) watcher.disconnect(); }, 300);
      });
      watcher.observe(document.documentElement, { childList: true, subtree: true });
      setTimeout(() => watcher.disconnect(), 15000);
    })();
    """#

    // MARK: YouTube ads

    static let youtube = #"""
    (() => {
      const h = location.hostname;
      if (!/(^|\.)youtube(-nocookie)?\.com$/.test(h)) return;
      // In a video embedded on another site, Shield being off for that site counts too.
      const origins = location.ancestorOrigins || [];
      const top = origins.length ? new URL(origins[origins.length - 1]).hostname : h;
      const allow = __ALLOW__;
      if ([h, top].some(x => allow.some(d => x === d || x.endsWith('.' + d)))) return;

      const keys = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];
      const strip = (o) => {
        if (!o || typeof o !== 'object') return o;
        for (const k of keys) if (k in o) delete o[k];
        if (o.playerResponse) strip(o.playerResponse);
        return o;
      };
      const parse = JSON.parse;
      JSON.parse = function () { return strip(parse.apply(this, arguments)); };
      const json = Response.prototype.json;
      Response.prototype.json = function () { return json.call(this).then(strip); };
      let ipr;
      try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true, get: () => ipr, set: (v) => { ipr = strip(v); },
        });
      } catch (e) {}

      // Anything that still slips through is fast-forwarded. The player is watched for its
      // 'ad-showing' class instead of polling, so idle and background tabs cost nothing.
      const skip = (player) => {
        if (!player.classList.contains('ad-showing')) return;
        document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button').forEach(b => b.click());
        const v = player.querySelector('video');
        if (v && isFinite(v.duration) && v.duration > 0) v.currentTime = v.duration;
      };
      let current = null;
      const watch = () => {
        if (current && current.isConnected) return;
        const player = document.querySelector('.html5-video-player');
        if (!player || player === current) return;
        current = player;
        new MutationObserver(() => skip(player)).observe(player, { attributes: true, attributeFilter: ['class'] });
        // Skip buttons and the ad's length can arrive after the class does.
        player.addEventListener('loadedmetadata', () => skip(player), true);
        player.addEventListener('timeupdate', () => skip(player), true);
        skip(player);
      };
      new MutationObserver(watch).observe(document, { childList: true, subtree: true });

      const css = [
        'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-banner-promo-renderer',
        'ytd-promoted-sparkles-web-renderer', 'ytd-display-ad-renderer', 'ytd-companion-slot-renderer',
        'ytd-action-companion-ad-renderer', 'ytd-player-legacy-desktop-watch-ads-renderer', '#player-ads',
        '#masthead-ad', '.ytp-ad-overlay-container', 'ytd-statement-banner-renderer',
        'ytd-rich-item-renderer:has(ytd-ad-slot-renderer)', 'ytd-rich-section-renderer:has(ytd-statement-banner-renderer)',
      ].join(',') + '{display:none!important}';
      const add = () => {
        const s = document.createElement('style');
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
      };
      if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add);
    })();
    """#

    // MARK: Force dark

    static let forceDark = #"""
    (() => {
      const s = document.createElement('style');
      s.id = 'lumen-dark';
      s.textContent = 'html{filter:invert(.92) hue-rotate(180deg)!important;background:#fff!important}' +
        'img,video,picture,canvas,iframe,embed,object,[style*="background-image"]{filter:invert(1) hue-rotate(180deg)!important}';
      document.documentElement.appendChild(s);
      const dark = (el) => {
        if (!el) return null;
        const m = getComputedStyle(el).backgroundColor.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?/);
        if (!m || (m[4] !== undefined && parseFloat(m[4]) < 0.5)) return null;
        return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) / 255 < 0.4;
      };
      document.addEventListener('DOMContentLoaded', () => {
        s.disabled = true;
        const meta = document.querySelector('meta[name="color-scheme"]');
        const isDark = dark(document.body) ?? dark(document.documentElement) ?? (meta && /^\s*dark/.test(meta.content));
        if (isDark) s.remove(); else s.disabled = false;
      });
    })();
    """#

    // MARK: Site styles

    static let siteStyles = #"""
    (() => {
      const rules = __RULES__;
      const h = location.hostname.toLowerCase();
      const mine = rules.filter(r => h === r.host || h.endsWith('.' + r.host));
      let style = null, darkStyle = null, floating = false, timer = null, observer = null;
      const darkCSS = __DARK__[0];
      // Pages that are dark already stay as they are; inverting them would make them light.
      const isDark = (el) => {
        if (!el) return null;
        const m = getComputedStyle(el).backgroundColor.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?/);
        if (!m || (m[4] !== undefined && parseFloat(m[4]) < 0.5)) return null;
        return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) / 255 < 0.4;
      };
      const setDark = (on) => {
        if (!on) { if (darkStyle) darkStyle.remove(); darkStyle = null; return; }
        if (!darkStyle) { darkStyle = document.createElement('style'); darkStyle.id = 'lumen-site-dark'; darkStyle.textContent = darkCSS; }
        if (!darkStyle.isConnected) document.documentElement.appendChild(darkStyle);
        const check = () => {
          if (!darkStyle) return;
          darkStyle.disabled = true;
          const meta = document.querySelector('meta[name="color-scheme"]');
          const already = isDark(document.body) ?? isDark(document.documentElement) ?? (meta && /^\s*dark/.test(meta.content));
          darkStyle.disabled = !!already;
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', check, { once: true }); else check();
      };
      const sheet = () => {
        if (!style) { style = document.createElement('style'); style.id = 'lumen-site-style'; }
        if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
        return style;
      };
      // Bars and pop-ups that stay on screen: fixed or sticky boxes that don't take up most of the window.
      const hideFloating = () => {
        if (!floating || !document.body) return;
        for (const el of document.body.querySelectorAll('*')) {
          if (el.hasAttribute('data-lumen-floating')) continue;
          const cs = getComputedStyle(el);
          if (cs.position !== 'fixed' && cs.position !== 'sticky') continue;
          const r = el.getBoundingClientRect();
          if (r.width * r.height > innerWidth * innerHeight * 0.6 && cs.position === 'sticky') continue;
          el.setAttribute('data-lumen-floating', '');
        }
        for (const el of [document.documentElement, document.body]) {
          if (getComputedStyle(el).overflow === 'hidden') el.style.setProperty('overflow', 'auto', 'important');
        }
      };
      const watch = () => {
        if (observer || !floating) return;
        const later = () => { clearTimeout(timer); timer = setTimeout(hideFloating, 700); };
        observer = new MutationObserver(later);
        // Bars often become fixed by a class or style change while you scroll, not only when they're added.
        observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style'] });
        addEventListener('scroll', later, { passive: true });
      };
      const apply = (css, hide, dark) => {
        floating = hide;
        setDark(!!dark);
        sheet().textContent = css + (hide ? '\n[data-lumen-floating]{display:none!important}' : '');
        if (hide) {
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { hideFloating(); watch(); }, { once: true });
          else { hideFloating(); watch(); }
        } else if (observer) { observer.disconnect(); observer = null; }
      };
      // Tacet calls this when you change the style, so the page follows without reloading.
      window.__lumenSiteStyle = apply;
      if (mine.length) apply(mine.map(r => r.css).join('\n'), mine.some(r => r.floating), mine.some(r => r.dark));
    })();
    """#

    /// Highlights what the pointer is over; a click hides it and reports a selector for it. Esc stops.
    static let picker = #"""
    (() => {
      if (window.__lumenPicker) return;
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #5e5ce6;background:rgba(94,92,230,.18);border-radius:3px;transition:all .06s';
      const tip = document.createElement('div');
      tip.style.cssText = 'position:fixed;top:12px;left:50%;transform:translateX(-50%);z-index:2147483647;background:rgba(30,30,32,.92);color:#fff;font:500 13px -apple-system,system-ui;padding:8px 14px;border-radius:18px;pointer-events:none;box-shadow:0 4px 18px rgba(0,0,0,.3)';
      tip.textContent = __TIP__;
      document.documentElement.append(box, tip);
      let target = null;
      const esc = CSS.escape;
      const unstable = c => /^(is-|has-|js-)|active|hover|focus|open|show|visible|selected|\d{4,}/.test(c) || c.length > 40;
      const part = el => {
        if (el.id && !/\d{3,}/.test(el.id) && document.querySelectorAll('#' + esc(el.id)).length === 1) return '#' + esc(el.id);
        let p = el.tagName.toLowerCase();
        const cls = [...el.classList].filter(c => !unstable(c)).slice(0, 3);
        if (cls.length) p += '.' + cls.map(esc).join('.');
        const parent = el.parentElement;
        if (parent) {
          const same = [...parent.children].filter(c => c.tagName === el.tagName);
          if (same.length > 1 && (!cls.length || parent.querySelectorAll(':scope > ' + p).length > 1)) p += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
        }
        return p;
      };
      const selector = el => {
        const path = [];
        for (let cur = el; cur && cur.nodeType === 1 && cur !== document.body && cur !== document.documentElement && path.length < 6; cur = cur.parentElement) {
          const p = part(cur);
          path.unshift(p);
          const s = path.join(' > ');
          try { if (document.querySelectorAll(s).length === 1) return s; } catch (e) {}
          if (p.startsWith('#')) break;
        }
        return path.join(' > ');
      };
      // ↑ picks the block around the highlighted element, ↓ goes back in.
      let trail = [];
      const show = el => {
        target = el;
        const r = el.getBoundingClientRect();
        Object.assign(box.style, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px', display: 'block' });
      };
      const move = e => {
        const el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === box || el === tip || el === document.body || el === document.documentElement) return;
        if (trail.length && trail[0] === el) return;
        trail = [el];
        show(el);
      };
      const stop = (report) => {
        removeEventListener('mousemove', move, true);
        removeEventListener('click', click, true);
        removeEventListener('keydown', key, true);
        presses.forEach(t => removeEventListener(t, swallow, true));
        box.remove(); tip.remove();
        delete window.__lumenPicker;
        if (report) window.webkit.messageHandlers.lumen.postMessage({ type: 'pickerDone' });
      };
      const click = e => {
        e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
        if (!target) return;
        const s = selector(target);
        target.style.setProperty('display', 'none', 'important');
        box.style.display = 'none';
        window.webkit.messageHandlers.lumen.postMessage({ type: 'pickedElement', selector: s });
      };
      const key = e => {
        if (e.key === 'Escape') { e.preventDefault(); stop(true); return; }
        if (!target) return;
        if (e.key === 'ArrowUp') {
          e.preventDefault();
          const up = target.parentElement;
          if (up && up !== document.body && up !== document.documentElement) { trail.push(up); show(up); }
        } else if (e.key === 'ArrowDown' && trail.length > 1) {
          e.preventDefault();
          trail.pop();
          show(trail[trail.length - 1]);
        }
      };
      // The page mustn't react to the clicks that pick elements.
      const swallow = e => { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); };
      const presses = ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'auxclick', 'dblclick', 'contextmenu'];
      presses.forEach(t => addEventListener(t, swallow, true));
      addEventListener('mousemove', move, true);
      addEventListener('click', click, true);
      addEventListener('keydown', key, true);
      window.__lumenPicker = { stop: () => stop(false) };
    })();
    """#

    // MARK: Reader

    /// Extracts the main article; returns {title, site, byline, html, words} or null.
    static let reader = #"""
    (() => {
      const pick = () => {
        // The block holding the most paragraph text.
        let el = null, top = 0;
        for (const c of document.querySelectorAll('div, section')) {
          let n = 0;
          for (const p of c.children) if (p.tagName === 'P') n += p.innerText.length;
          if (n > top) { top = n; el = c; }
        }
        const arts = [...document.querySelectorAll('article, [itemprop="articleBody"], main')];
        const best = arts.sort((a, b) => b.innerText.length - a.innerText.length)[0];
        // A <main> often also holds menus and language lists (Wikipedia): prefer the paragraph block inside it.
        if (best && best.innerText.length > 800) return el && top > 500 && best.contains(el) ? el : best;
        return top > 500 ? el : null;
      };
      const root = pick();
      if (!root) return null;
      const keep = new Set(['P','H1','H2','H3','H4','H5','BLOCKQUOTE','PRE','CODE','UL','OL','LI','FIGURE','FIGCAPTION',
        'IMG','A','EM','STRONG','B','I','U','BR','HR','TABLE','THEAD','TBODY','TR','TD','TH','SUP','SUB','DL','DT','DD']);
      const drop = new Set(['SCRIPT','STYLE','NOSCRIPT','IFRAME','FORM','BUTTON','INPUT','NAV','ASIDE','FOOTER','SVG','CANVAS','VIDEO','AUDIO','SELECT','TEXTAREA']);
      const junk = /(share|social|related|promo|advert|newsletter|comment|subscribe|sidebar|cookie|banner|popup|footer|byline-share|recirc|navbox|catlinks|interlanguage|mw-editsection|language-list)/i;
      const clone = (node) => {
        if (node.nodeType === 3) return document.createTextNode(node.textContent);
        if (node.nodeType !== 1 || drop.has(node.tagName)) return null;
        const id = (typeof node.className === 'string' ? node.className : '') + ' ' + (node.id || '');
        if (junk.test(id) && node !== root) return null;
        if (node.tagName === 'IMG') {
          const src = node.currentSrc || node.src || node.dataset.src || node.dataset.lazySrc;
          if (!src || node.width && node.width < 80) return null;
          const img = document.createElement('img');
          img.src = src;
          img.alt = node.alt || '';
          return img;
        }
        const out = keep.has(node.tagName) ? document.createElement(node.tagName) : document.createDocumentFragment();
        // Only ordinary links: a javascript: link would run on the article's site from the reader page.
        if (node.tagName === 'A' && /^(https?|mailto):/i.test(node.href || '')) out.setAttribute('href', node.href);
        for (const c of node.childNodes) { const k = clone(c); if (k) out.appendChild(k); }
        return out;
      };
      const box = document.createElement('div');
      box.appendChild(clone(root));
      const meta = (n) => { const m = document.querySelector(`meta[property="${n}"], meta[name="${n}"]`); return m ? m.content : ''; };
      let title = meta('og:title') || document.title;
      // The page's own heading is the title; "Tacet - Wikipedia" becomes "Tacet" and isn't shown twice.
      const heading = (document.querySelector('h1') || {}).textContent;
      if (heading && heading.trim() && title.includes(heading.trim())) title = heading.trim();
      const h1 = box.querySelector('h1');
      if (h1 && h1.textContent.trim() === title.trim()) h1.remove();
      return {
        title, byline: meta('author'), site: meta('og:site_name') || location.hostname.replace(/^www\./, ''),
        html: box.innerHTML, words: root.innerText.split(/\s+/).length,
      };
    })();
    """#

    static func readerPage(title: String, site: String, byline: String, html: String, minutes: Int) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let meta = [site, byline, String(format: L("%lld min read"), minutes)].filter { !$0.isEmpty }.map(esc).joined(separator: " · ")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(esc(title))</title>
        <style>
        :root { color-scheme: light dark; --bg: #fbfaf7; --fg: #1d1d1f; --muted: #6e6e73; --link: #3a5bd9; --rule: #e5e2db; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1b1b1d; --fg: #e8e6e3; --muted: #9a9a9f; --link: #8fa8ff; --rule: #333; } }
        html { background: var(--bg); }
        body { margin: 0 auto; max-width: 680px; padding: 72px 28px 120px; color: var(--fg);
               font: 20px/1.7 "New York", ui-serif, Georgia, serif; -webkit-font-smoothing: antialiased; }
        header { margin-bottom: 40px; border-bottom: 1px solid var(--rule); padding-bottom: 24px; }
        h1.title { font: 700 38px/1.2 -apple-system, ui-sans-serif, sans-serif; letter-spacing: -0.02em; margin: 0 0 12px; }
        .meta { font: 14px -apple-system, sans-serif; color: var(--muted); }
        h2, h3, h4 { font-family: -apple-system, ui-sans-serif, sans-serif; line-height: 1.3; margin-top: 1.8em; }
        img { max-width: 100%; height: auto; border-radius: 8px; display: block; margin: 1.5em auto; }
        figcaption { font: 14px -apple-system, sans-serif; color: var(--muted); text-align: center; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        blockquote { margin: 1.5em 0; padding-left: 1.2em; border-left: 3px solid var(--rule); color: var(--muted); }
        pre, code { font: 15px ui-monospace, Menlo, monospace; } pre { overflow-x: auto; padding: 16px; background: rgba(127,127,127,.1); border-radius: 8px; }
        table { border-collapse: collapse; width: 100%; font-size: 16px; } td, th { border: 1px solid var(--rule); padding: 6px 10px; }
        </style></head><body>
        <header><h1 class="title">\(esc(title))</h1><div class="meta">\(meta)</div></header>
        <article>\(html)</article>
        </body></html>
        """
    }

    // MARK: Error page

    static func errorPage(url: URL, error: NSError) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let offline = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed].contains(error.code)
        let title = L(offline ? "You're offline" : (error.code == NSURLErrorCannotFindHost ? "Can't find this site" : "Can't open this page"))
        let host = url.host ?? url.absoluteString
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center;
               font: 15px -apple-system, sans-serif; color: #6e6e73; background: Canvas; }
        .box { max-width: 460px; text-align: center; padding: 24px; }
        .orb { position: relative; width: 56px; height: 56px; border-radius: 50%; margin: 0 auto 24px;
               background: linear-gradient(135deg, #ffc24a, #ff5a2a); box-shadow: 0 0 40px 6px rgba(255, 122, 58, 0.35); }
        .orb::after { content: ""; position: absolute; inset: 0; border-radius: 50%; transform: translate(-8px, 7px);
               background: radial-gradient(circle at 35% 30%, #3b3752, #14121d 90%); }
        h1 { color: CanvasText; font-size: 24px; font-weight: 600; margin: 0 0 10px; }
        p { line-height: 1.5; margin: 0 0 24px; }
        a.btn { display: inline-block; padding: 8px 18px; border-radius: 8px; background: #5e5ce6; color: white; text-decoration: none; font-weight: 500; }
        code { font-size: 12px; opacity: .7; }
        </style></head><body><div class="box"><div class="orb"></div>
        <h1>\(esc(title))</h1>
        <p>\(esc(error.localizedDescription))<br><strong>\(esc(host))</strong></p>
        <a class="btn" href="\(esc(url.absoluteString))">\(esc(L("Try Again")))</a>
        <p><code>\(esc(error.domain)) \(error.code)</code></p>
        </div></body></html>
        """
    }
}

/// Receives messages from the bridge script and routes them to the tab that sent them.
final class ScriptBridge: NSObject, WKScriptMessageHandler {
    static let shared = ScriptBridge()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let tab = Tab.owner(of: webView),
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        // Scripts are only injected into the page itself; a message from an embedded frame (an ad, say)
        // must not be able to touch passwords or the tab.
        guard message.frameInfo.isMainFrame else { return }
        tab.handleMessage(type, body)
    }
}
