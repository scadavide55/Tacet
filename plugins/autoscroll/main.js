const toast = (text, keep) => {
  let t = document.getElementById('tacet-autoscroll-label');
  if (!t) {
    t = document.createElement('div');
    t.id = 'tacet-autoscroll-label';
    t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:2147483647;background:rgba(20,20,28,.92);color:#fff;font:13px -apple-system,sans-serif;padding:8px 14px;border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,.3);pointer-events:none;transition:opacity .3s';
    document.documentElement.appendChild(t);
  }
  t.textContent = text;
  t.style.opacity = '1';
  clearTimeout(t._hide);
  t._hide = setTimeout(() => { t.style.opacity = '0'; }, keep ? 1500 : 1200);
};
let running = false, speed = 60, last = 0, carry = 0;
const step = (now) => {
  if (!running) return;
  const dt = Math.min(100, now - last) / 1000;
  last = now;
  carry += speed * dt;
  const whole = Math.floor(carry);
  if (whole > 0) { scrollBy(0, whole); carry -= whole; }
  if (innerHeight + scrollY >= document.documentElement.scrollHeight - 1) { running = false; toast('End of the page'); return; }
  requestAnimationFrame(step);
};
const start = () => { running = true; last = performance.now(); carry = 0; toast('Autoscroll · ' + speed + ' px/s · ↑ ↓ speed · Esc stops'); requestAnimationFrame(step); };
const stop = () => { running = false; toast('Autoscroll stopped'); };
const toggle = () => (running ? stop() : start());
globalThis.tacetAction = toggle;
const typing = (e) => { const el = e.target; return el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)); };
document.addEventListener('keydown', (e) => {
  if (e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyA') { e.preventDefault(); toggle(); return; }
  if (!running || typing(e) || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.key === 'Escape') { e.preventDefault(); stop(); }
  else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
    e.preventDefault(); e.stopPropagation();
    speed = Math.max(10, Math.min(600, speed + (e.key === 'ArrowDown' ? 20 : -20)));
    toast('Autoscroll · ' + speed + ' px/s', true);
  }
}, true);
