// The Autoplay switch in the player's controls; on when its aria-checked is "true". It is clicked once per video page.
const turnOff = () => {
  const toggle = document.querySelector('.ytp-autonav-toggle-button[aria-checked="true"]');
  if (toggle) toggle.click();
};
let timer = 0;
const later = () => { clearTimeout(timer); timer = setTimeout(turnOff, 400); };
turnOff();
document.addEventListener('yt-navigate-finish', later, true);
new MutationObserver(later).observe(document.body || document.documentElement, { childList: true, subtree: true });
