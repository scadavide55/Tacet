const ID = 'tacet-page-outline';
const toast = (text) => {
  const t = document.createElement('div');
  t.textContent = text;
  t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:2147483647;background:rgba(20,20,28,.92);color:#fff;font:13px -apple-system,sans-serif;padding:8px 14px;border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,.3);pointer-events:none;transition:opacity .3s';
  document.documentElement.appendChild(t);
  setTimeout(() => { t.style.opacity = '0'; }, 1200);
  setTimeout(() => t.remove(), 1600);
};
const close = () => { const p = document.getElementById(ID); if (p) { p.remove(); return true; } return false; };

const headings = () => {
  const root = document.querySelector('article, main, [role="main"]') || document.body;
  let list = [...root.querySelectorAll('h1, h2, h3, h4')];
  if (list.length < 2) list = [...document.querySelectorAll('h1, h2, h3, h4')];
  return list.filter((h) => h.getClientRects().length > 0 && (h.textContent || '').trim().length > 0 && !h.closest('#' + ID));
};

const outline = () => {
  if (close()) return;
  const list = headings();
  if (!list.length) { toast('No headings on this page'); return; }
  const top = Math.min(...list.map((h) => +h.tagName[1]));
  const panel = document.createElement('div');
  panel.id = ID;
  panel.style.cssText = 'position:fixed;top:16px;right:16px;bottom:16px;width:320px;max-width:80vw;z-index:2147483647;overflow:auto;' +
    'background:rgba(250,250,252,.97);color:#15162a;border-radius:14px;box-shadow:0 12px 50px rgba(0,0,0,.35);font:13px/1.35 -apple-system,sans-serif;padding:10px 6px';
  const title = document.createElement('div');
  title.textContent = 'Outline · ' + list.length + ' headings';
  title.style.cssText = 'font-weight:600;padding:4px 12px 8px;color:#5b5e78';
  panel.appendChild(title);
  for (const h of list) {
    const row = document.createElement('a');
    row.textContent = (h.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 120);
    row.href = '#';
    row.style.cssText = 'display:block;padding:5px 12px 5px ' + (12 + (+h.tagName[1] - top) * 14) + 'px;color:inherit;text-decoration:none;border-radius:8px;' +
      (h.tagName === 'H1' ? 'font-weight:600;' : '');
    row.onmouseenter = () => { row.style.background = 'rgba(80,90,200,.12)'; };
    row.onmouseleave = () => { row.style.background = ''; };
    row.onclick = (e) => { e.preventDefault(); h.scrollIntoView({ behavior: 'smooth', block: 'start' }); close(); };
    panel.appendChild(row);
  }
  document.documentElement.appendChild(panel);
};
globalThis.tacetAction = outline;
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && close()) return;
  if (e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyO') { e.preventDefault(); outline(); }
}, true);
