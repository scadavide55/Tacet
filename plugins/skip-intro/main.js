// Buttons are found by what they are called by the services (a data attribute) or by what they say, in the player only.
// Next episode is never pressed: only the intro, the recap, and "still watching?".
const selectors = [
  '[data-uia="player-skip-intro"]', '[data-uia="player-skip-recap"]', '[data-uia="interrupt-autoplay-continue"]',
  '.atvwebplayersdk-skipelement-button', '.atvwebplayersdk-skipintro-button',
  '[data-testid="skip-intro"]', 'button[data-gv2elementkey="skipIntro"]',
].join(', ');
const words = /^(skip (the )?(intro|recap|opening|previously)|salta (l'?intro(duzione)?|(il )?riepilogo|sigla)|passer l'?intro|ignorer l'?intro|passer le résumé|continue watching|continua a guardare|continuer à regarder|continuar viendo)$/i;

const click = (el) => {
  if (el.dataset.tacetPressed || el.getClientRects().length === 0 || el.disabled) return;
  el.dataset.tacetPressed = '1';
  el.click();
};

const sweep = () => {
  for (const el of document.querySelectorAll(selectors)) click(el);
  for (const el of document.querySelectorAll('button, [role="button"]')) {
    const text = (el.textContent || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
    if (text.length < 40 && words.test(text)) click(el);
  }
};
let timer = 0;
const later = () => { clearTimeout(timer); timer = setTimeout(sweep, 250); };
sweep();
new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true });
