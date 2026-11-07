// A page that is nothing but JSON: the browser shows it as one <pre> of text. Show it as a tree instead.
const body = document.body;
const only = body && body.children.length === 1 && body.firstElementChild.tagName === 'PRE' ? body.firstElementChild : null;
const raw = only ? only.textContent.trim() : (document.contentType === 'application/json' && body ? body.innerText.trim() : '');
let data, ok = false;
if (raw && /^[\[{]/.test(raw)) { try { data = JSON.parse(raw); ok = true; } catch (e) { ok = false; } }
if (ok) {
  document.documentElement.style.cssText = 'color-scheme:light dark';
  const style = document.createElement('style');
  style.textContent = `
    body { margin: 0; padding: 18px 22px; font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; background: Canvas; color: CanvasText; }
    details { margin-left: 18px; } summary { cursor: pointer; list-style: none; margin-left: -14px; }
    summary::before { content: "▸"; display: inline-block; width: 14px; color: GrayText; } details[open] > summary::before { content: "▾"; }
    .k { color: #8a3ffc; } .s { color: #1a7f37; } .n { color: #0a64c8; } .b { color: #c2410c; } .z { color: GrayText; } .c { color: GrayText; }
    @media (prefers-color-scheme: dark) { .k { color: #c4a1ff; } .s { color: #7ee787; } .n { color: #79c0ff; } .b { color: #ffa657; } }
    .bar { position: sticky; top: 0; padding: 0 0 12px; font: 12px -apple-system, sans-serif; color: GrayText; background: Canvas; }
    .bar button { font: inherit; margin-right: 8px; padding: 3px 9px; border-radius: 7px; border: 1px solid GrayText; background: transparent; color: CanvasText; cursor: pointer; }
  `;
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; };
  const render = (value, depth) => {
    if (value === null) return el('span', 'z', 'null');
    if (typeof value === 'string') return el('span', 's', JSON.stringify(value));
    if (typeof value === 'number') return el('span', 'n', String(value));
    if (typeof value === 'boolean') return el('span', 'b', String(value));
    const isArray = Array.isArray(value);
    const keys = isArray ? value.map((_, i) => i) : Object.keys(value);
    const [open, close] = isArray ? ['[', ']'] : ['{', '}'];
    const wrap = document.createDocumentFragment();
    if (!keys.length) { wrap.append(el('span', 'z', open + close)); return wrap; }
    const d = el('details');
    if (depth < 2) d.open = true;
    const s = el('summary');
    s.append(open, el('span', 'c', ' ' + keys.length + (isArray ? ' items ' : ' keys ')));
    d.appendChild(s);
    keys.forEach((key, i) => {
      const line = el('div');
      if (!isArray) { line.append(el('span', 'k', JSON.stringify(key)), ': '); }
      line.append(render(value[key], depth + 1));
      if (i < keys.length - 1) line.append(',');
      d.appendChild(line);
    });
    d.append(close);
    wrap.appendChild(d);
    return wrap;
  };
  const bar = el('div', 'bar');
  const open = el('button', '', 'Open all'), shut = el('button', '', 'Close all'), copy = el('button', '', 'Copy JSON');
  open.onclick = () => document.querySelectorAll('details').forEach((d) => { d.open = true; });
  shut.onclick = () => document.querySelectorAll('details details').forEach((d) => { d.open = false; });
  copy.onclick = () => { navigator.clipboard.writeText(JSON.stringify(data, null, 2)).then(() => { copy.textContent = 'Copied'; setTimeout(() => { copy.textContent = 'Copy JSON'; }, 1200); }, () => {}); };
  bar.append(open, shut, copy);
  const root = el('div');
  root.appendChild(render(data, 0));
  body.replaceChildren(bar, root);
  document.head.appendChild(style);
}
