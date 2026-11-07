const toast = (text) => {
  const t = document.createElement('div');
  t.textContent = text;
  t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:2147483647;background:rgba(20,20,28,.92);color:#fff;font:13px -apple-system,sans-serif;padding:8px 14px;border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,.3);pointer-events:none;transition:opacity .3s';
  document.documentElement.appendChild(t);
  setTimeout(() => { t.style.opacity = '0'; }, 1200);
  setTimeout(() => t.remove(), 1600);
};
const MARK = 'tacetBionic';
let on = false;

const emphasise = (text) => text.replace(/[\p{L}\p{N}]+/gu, (w) => {
  if (w.length < 2) return w;
  const n = Math.ceil(w.length * 0.5);
  return '\u0001' + w.slice(0, n) + '\u0002' + w.slice(n);
});

const apply = () => {
  const root = document.querySelector('article, main, [role="main"]') || document.body;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => {
      const p = n.parentElement;
      if (!p || !n.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
      if (p.closest('script, style, noscript, code, pre, textarea, input, select, button, nav, header, footer, svg, [contenteditable="true"]')) return NodeFilter.FILTER_REJECT;
      if (!p.closest('p, li, blockquote, dd, figcaption, td')) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  const nodes = [];
  while (walker.nextNode() && nodes.length < 8000) nodes.push(walker.currentNode);
  for (const node of nodes) {
    const marked = emphasise(node.nodeValue);
    if (marked === node.nodeValue) continue;
    const span = document.createElement('span');
    span.dataset[MARK] = node.nodeValue;
    for (const [i, part] of marked.split('\u0001').entries()) {
      if (i === 0) { span.appendChild(document.createTextNode(part)); continue; }
      const [bold, rest] = part.split('\u0002');
      const b = document.createElement('b');
      b.textContent = bold;
      span.append(b, document.createTextNode(rest));
    }
    node.replaceWith(span);
  }
  return nodes.length;
};
const undo = () => {
  for (const span of document.querySelectorAll('span[data-tacet-bionic]')) span.replaceWith(document.createTextNode(span.dataset[MARK]));
};
const toggle = () => {
  on = !on;
  if (on) { const n = apply(); if (!n) { on = false; toast('No text to change here'); return; } toast('Bionic Reading on'); }
  else { undo(); toast('Bionic Reading off'); }
};
globalThis.tacetAction = toggle;
document.addEventListener('keydown', (e) => {
  if (e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyB') { e.preventDefault(); toggle(); }
}, true);
