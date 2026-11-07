// Medium's class names are random and change often, but what these boxes do doesn't: they are dialogs or bars fixed to
// the window that ask you to sign in or become a member. Those are hidden; the page's own top bar is left alone.
const asks = 'a[href*="/m/signin"], a[href*="signup"], a[href*="/m/signup"], a[href*="/membership"], a[href*="/plans"]';
const words = /sign up|sign in|get unlimited access|become a member|open in app|upgrade|iscriviti|accedi|abbonati|inscrivez|connectez|devenez membre/i;

const looksLikeAsk = (el) => el.querySelector(asks) && words.test(el.textContent || '');

const sweep = () => {
  for (const el of document.querySelectorAll('div[role="dialog"], div[role="presentation"], div, aside, section')) {
    if (el.dataset.tacetChecked) continue;
    const cs = getComputedStyle(el);
    const fixed = cs.position === 'fixed' || cs.position === 'sticky';
    const dialog = el.getAttribute('role') === 'dialog';
    if (!fixed && !dialog) continue;
    el.dataset.tacetChecked = '1';
    if (!looksLikeAsk(el)) continue;
    const r = el.getBoundingClientRect();
    // The top bar sits at the top and is short: it stays. A bar at the bottom, a modal or a full cover goes.
    const atTop = r.top <= 1 && r.height < 120 && !dialog;
    if (atTop) continue;
    el.style.setProperty('display', 'none', 'important');
    el.dataset.tacetHidden = 'medium-quiet';
    // A dark layer behind a modal, if it is a sibling that covers the window.
    const back = el.previousElementSibling;
    if (back && getComputedStyle(back).position === 'fixed' && !back.textContent.trim()) back.style.setProperty('display', 'none', 'important');
  }
  // A modal locks the page's scrolling; give it back.
  for (const el of [document.documentElement, document.body]) {
    if (el && getComputedStyle(el).overflow === 'hidden') el.style.setProperty('overflow', 'auto', 'important');
  }
};

let queued = false;
const later = () => {
  if (queued) return;
  queued = true;
  setTimeout(() => { queued = false; sweep(); }, 250);
};
sweep();
new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true });
