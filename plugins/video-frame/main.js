const toast = (text) => {
  const t = document.createElement('div');
  t.textContent = text;
  t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:2147483647;background:rgba(20,20,28,.92);color:#fff;font:13px -apple-system,sans-serif;padding:8px 14px;border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,.3);pointer-events:none;transition:opacity .3s';
  document.documentElement.appendChild(t);
  setTimeout(() => { t.style.opacity = '0'; }, 1400);
  setTimeout(() => t.remove(), 1800);
};
const video = () => [...document.querySelectorAll('video')].filter((v) => v.offsetWidth > 0 && v.videoWidth > 0).sort((a, b) => b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight)[0];
const save = () => {
  const v = video();
  if (!v) { toast('No video on this page'); return; }
  try {
    const c = document.createElement('canvas');
    c.width = v.videoWidth; c.height = v.videoHeight;
    c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
    c.toBlob((blob) => {
      if (!blob) { toast('This video can\u2019t be captured'); return; }
      const name = (document.title || 'video').replace(/[\\/:*?"<>|]+/g, ' ').trim().slice(0, 60) + ' ' + Math.floor(v.currentTime / 60) + '-' + String(Math.floor(v.currentTime % 60)).padStart(2, '0') + '.png';
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = name;
      document.documentElement.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 10000);
      toast('Frame saved');
    }, 'image/png');
  } catch (e) {
    // A video from another site, without permission to be copied, taints the picture.
    toast('This site doesn\u2019t allow saving its frames');
  }
};
globalThis.tacetAction = save;
document.addEventListener('keydown', (e) => {
  if (e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyV') { e.preventDefault(); save(); }
}, true);
