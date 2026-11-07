// Google changes its class names all the time, but the headings of these blocks are text people read, so the blocks
// are found by that heading: climb from it to the block that holds it and holds no result of its own, and hide it.
if (location.pathname === '/search') {
  const titles = new Set([
    // AI Overview
    'ai overview', 'ai overviews', 'panoramica ai', 'panoramiche ai', 'panoramica creata dall\'ai', 'aperçu ia', 'aperçu généré par l\'ia',
    'ki-übersicht', 'übersicht mit ki', 'información general creada por ia', 'descripción general creada por la ia',
    'ai-overzicht', 'visão geral criada por ia', 'visão geral de ia',
    // People also ask
    'people also ask', 'altre domande', 'le persone hanno chiesto anche', 'autres questions posées', 'autres questions',
    'weitere fragen', 'otras preguntas de los usuarios', 'anderen vroegen ook', 'as pessoas também perguntam',
  ]);
  const stops = new Set(['BODY', 'HTML', 'MAIN']);
  const stopIds = new Set(['rso', 'center_col', 'main', 'cnt', 'search', 'res', 'rcnt', 'cnt']);
  // A block that holds an ordinary result (a link with a title inside) is the whole results column, not our block.
  const holdsResults = (el) => el.querySelector('a[href] h3');
  const norm = (s) => s.replace(/\s+/g, ' ').replace(/[.:…]+$/, '').trim().toLowerCase();

  const blockOf = (heading) => {
    let el = heading;
    for (let i = 0; i < 18; i++) {
      const parent = el.parentElement;
      if (!parent || stops.has(parent.tagName) || stopIds.has(parent.id) || holdsResults(parent)) break;
      el = parent;
    }
    return el;
  };

  const sweep = () => {
    for (const h of document.querySelectorAll('h1, h2, h3, h4, [role="heading"]')) {
      if (h.closest('a[href]') || h.dataset.tacetChecked) continue;
      if (!titles.has(norm(h.textContent || ''))) continue;
      h.dataset.tacetChecked = '1';
      const block = blockOf(h);
      if (block === h && !h.parentElement) continue;
      block.style.setProperty('display', 'none', 'important');
      block.dataset.tacetHidden = 'google-no-ai-overview';
    }
  };

  let queued = false;
  const later = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; sweep(); });
  };
  sweep();
  new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true });
}
