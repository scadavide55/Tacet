const ID = 'tacet-select-search';
const engines = [
  ['Search', 'https://duckduckgo.com/?q='],
  ['Wikipedia', 'https://wikipedia.org/w/index.php?search='],
  ['YouTube', 'https://www.youtube.com/results?search_query='],
];
const remove = () => { const b = document.getElementById(ID); if (b) b.remove(); };
const typingIn = (n) => { const el = n && (n.nodeType === 1 ? n : n.parentElement); return !!el && (el.isContentEditable || !!el.closest('input, textarea, select, [contenteditable="true"]')); };

const show = () => {
  remove();
  const sel = getSelection();
  const text = String(sel || '').replace(/\s+/g, ' ').trim();
  if (!text || text.length < 2 || text.length > 120 || sel.rangeCount === 0 || typingIn(sel.anchorNode)) return;
  const rect = sel.getRangeAt(0).getBoundingClientRect();
  if (!rect.width && !rect.height) return;
  const bar = document.createElement('div');
  bar.id = ID;
  const top = rect.top > 50 ? rect.top - 40 : rect.bottom + 8;
  bar.style.cssText = 'position:fixed;z-index:2147483647;display:flex;gap:2px;padding:4px;border-radius:10px;background:rgba(20,20,28,.94);box-shadow:0 8px 30px rgba(0,0,0,.3);font:12px -apple-system,sans-serif;' +
    'top:' + Math.max(6, top) + 'px;left:' + Math.max(6, Math.min(innerWidth - 230, rect.left)) + 'px';
  for (const [label, base] of engines) {
    const a = document.createElement('a');
    a.textContent = label;
    a.href = base + encodeURIComponent(text);
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    a.style.cssText = 'color:#fff;text-decoration:none;padding:4px 9px;border-radius:7px;cursor:pointer';
    a.onmouseenter = () => { a.style.background = 'rgba(255,255,255,.16)'; };
    a.onmouseleave = () => { a.style.background = ''; };
    a.onmousedown = (e) => e.preventDefault();
    a.onclick = () => setTimeout(remove, 50);
    bar.appendChild(a);
  }
  document.documentElement.appendChild(bar);
};
document.addEventListener('mouseup', (e) => { if (e.target.closest && e.target.closest('#' + ID)) return; setTimeout(show, 10); }, true);
document.addEventListener('mousedown', (e) => { if (!(e.target.closest && e.target.closest('#' + ID))) remove(); }, true);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') remove(); }, true);
addEventListener('scroll', remove, { passive: true });
