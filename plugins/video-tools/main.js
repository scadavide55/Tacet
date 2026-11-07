const toast = (text) => {
  const t = document.createElement('div');
  t.textContent = text;
  t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:2147483647;background:rgba(20,20,28,.92);color:#fff;font:13px -apple-system,sans-serif;padding:8px 14px;border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,.3);pointer-events:none;transition:opacity .3s';
  document.documentElement.appendChild(t);
  setTimeout(() => { t.style.opacity = '0'; }, 1000);
  setTimeout(() => t.remove(), 1400);
};
const video = () => [...document.querySelectorAll('video')].filter((v) => v.offsetWidth > 0).sort((a, b) => b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight)[0];
const fmt = (s) => { s = Math.max(0, Math.floor(s)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
const typing = (e) => { const el = e.target; return el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)); };
document.addEventListener('keydown', (e) => {
  if (!(e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey) || typing(e)) return;
  const keys = { ArrowLeft: 'back', ArrowRight: 'forward', ArrowUp: 'loop', Comma: 'frame-', Period: 'frame+' };
  const what = keys[e.code];
  if (!what) return;
  const v = video();
  if (!v) return;
  e.preventDefault(); e.stopPropagation();
  if (what === 'back' || what === 'forward') {
    v.currentTime = Math.max(0, Math.min(v.duration || Infinity, v.currentTime + (what === 'back' ? -10 : 10)));
    toast((what === 'back' ? '−10 s' : '+10 s') + ' · ' + fmt(v.currentTime));
  } else if (what === 'loop') {
    v.loop = !v.loop;
    toast('Loop ' + (v.loop ? 'on' : 'off'));
  } else {
    v.pause();
    v.currentTime = Math.max(0, v.currentTime + (what === 'frame-' ? -1 : 1) / 30);
    toast('Frame ' + (what === 'frame-' ? '−1' : '+1') + ' · ' + v.currentTime.toFixed(2) + ' s');
  }
}, true);
