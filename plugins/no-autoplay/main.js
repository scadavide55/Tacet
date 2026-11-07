// A video that starts without you having touched the page in the last moments is paused. After a click or a key press
// (yours, on the play button, or a space bar) it is allowed, so playing on purpose is never in the way.
let last = 0;
const mark = () => { last = Date.now(); };
for (const type of ['pointerdown', 'mousedown', 'touchstart', 'keydown']) addEventListener(type, mark, true);

const allowed = () => Date.now() - last < 2000;

// "play" doesn't bubble, but it can be caught on the way down.
document.addEventListener('play', (e) => {
  const media = e.target;
  if (!(media instanceof HTMLMediaElement) || allowed()) return;
  media.pause();
  media.dataset.tacetPaused = '1';
}, true);

// Remove the autoplay flag from videos that are already in the page or come in later, so they don't try at all.
const strip = (root) => {
  for (const m of (root.querySelectorAll ? root.querySelectorAll('video[autoplay], audio[autoplay]') : [])) {
    m.removeAttribute('autoplay');
    m.autoplay = false;
  }
};
document.addEventListener('DOMContentLoaded', () => strip(document));
new MutationObserver((records) => {
  for (const r of records) for (const n of r.addedNodes) if (n.nodeType === 1) {
    if (n.matches && n.matches('video[autoplay], audio[autoplay]')) { n.removeAttribute('autoplay'); n.autoplay = false; }
    strip(n);
  }
}).observe(document, { childList: true, subtree: true });
