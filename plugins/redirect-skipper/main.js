// The pages that exist only to pass you on: the real address is in the link, so Tacet goes there itself.
const rules = [
  { host: /(^|\.)google\.[a-z.]+$/, path: /^\/url$/, params: ['q', 'url'] },
  { host: /(^|\.)facebook\.com$/, path: /^\/l\.php$/, params: ['u'] },
  { host: /(^|\.)linkedin\.com$/, path: /^\/safety\/go/, params: ['url'] },
  { host: /(^|\.)youtube\.com$/, path: /^\/redirect$/, params: ['q'] },
  { host: /(^|\.)steamcommunity\.com$/, path: /^\/linkfilter/, params: ['url', 'u'] },
  { host: /(^|\.)reddit\.com$/, path: /^\/(out|r\/[^/]+\/out)/, params: ['url'] },
  { host: /(^|\.)slack-redir\.net$/, path: /^\/link/, params: ['url'] },
  { host: /(^|\.)instagram\.com$/, path: /^\/linkshim|^\/l\.php/, params: ['u'] },
  { host: /(^|\.)discord\.com$/, path: /^\/(linkfilter|link)/, params: ['url'] },
];
const here = location.hostname.toLowerCase();
const rule = rules.find((r) => r.host.test(here) && r.path.test(location.pathname));
if (rule) {
  const query = new URLSearchParams(location.search);
  for (const name of rule.params) {
    const value = query.get(name);
    if (!value) continue;
    let target;
    try { target = new URL(value); } catch (e) { continue; }
    // Only to a real web address on another site, never back to the same page or to a script.
    if ((target.protocol === 'http:' || target.protocol === 'https:') && target.hostname.toLowerCase() !== here) {
      location.replace(target.href);
      break;
    }
  }
}
