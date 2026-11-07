// Only on pages that read like an article (several paragraphs): an app page, like mail or a document editor, depends on
// its fixed bars, so those are never touched.
const paragraphs = () => document.querySelectorAll('p').length;
const asks = /subscribe|newsletter|sign up|sign in|create (a free )?account|get the app|iscriviti|newsletter|abbonati|registrati|inscrivez|abonnez|accept (all )?cookies/i;

const hide = (el, why) => {
  el.style.setProperty('display', 'none', 'important');
  el.dataset.tacetHidden = why;
};

const sweep = () => {
  if (paragraphs() < 6) return;
  const vw = innerWidth, vh = innerHeight;
  for (const el of document.querySelectorAll('body *')) {
    if (el.dataset.tacetChecked || el.dataset.tacetHidden) continue;
    const tag = el.tagName;
    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'VIDEO' || tag === 'IFRAME') continue;
    const cs = getComputedStyle(el);
    if (cs.position !== 'fixed' && cs.position !== 'sticky') continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    // A player, an editor or a form you are using stays.
    if (el.querySelector('video, audio, textarea, [contenteditable="true"]') || el.contains(document.activeElement)) { el.dataset.tacetChecked = '1'; continue; }
    const wide = r.width >= vw * 0.6;
    const atTop = r.top <= 1 && r.height < 160;
    const atBottom = r.bottom >= vh - 1 && r.height < 200;
    const modal = el.getAttribute('role') === 'dialog' || el.getAttribute('aria-modal') === 'true' || (wide && r.height >= vh * 0.35 && cs.position === 'fixed');
    if (modal && asks.test(el.textContent || '')) { hide(el, 'sticky-hider:popup'); continue; }
    if (wide && (atTop || atBottom) && cs.position === 'fixed') { hide(el, 'sticky-hider:bar'); continue; }
    // A sticky header only gets in the way once it has scrolled with you; it is hidden when it sticks to the top.
    if (wide && cs.position === 'sticky' && atTop && scrollY > 200) { hide(el, 'sticky-hider:bar'); continue; }
    el.dataset.tacetChecked = '1';
  }
  // A pop-up that locked the page's scrolling is gone, so the page may scroll again.
  if (document.querySelector('[data-tacet-hidden="sticky-hider:popup"]')) {
    for (const el of [document.documentElement, document.body]) {
      if (el && getComputedStyle(el).overflow === 'hidden') el.style.setProperty('overflow', 'auto', 'important');
    }
  }
};

let timer = 0;
const later = () => { clearTimeout(timer); timer = setTimeout(sweep, 200); };
sweep();
addEventListener('scroll', later, { passive: true });
addEventListener('resize', later, { passive: true });
new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true });
