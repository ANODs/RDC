// The site's only backend (site/, tools/site.py): a Cloudflare Worker with one D1 database.
// Deploy: site/worker/README.md.
//
// On the site's domain these are under /api; every other path is the site — the viewer and the
// landing page — passed on from GitHub Pages (PAGES_ORIGIN).
//
//   POST /hit        a page view or a download click, sent by the page with sendBeacon
//   GET  /releases   the latest release, its files and the download counts, from GitHub (cached 5 min)
//   GET  /stats      the aggregates the page's statistics block draws (open; a STATS_KEY secret would lock it)
//
// What is kept: counters per day (views, visitors, country, page language, system, device,
// referrer host, downloads). What is not: addresses, user agents, cookies, anything per person.
// A visitor is told apart for one day by sha256(day salt + address + user agent); the salt is
// random, lives for that day only, and is deleted with the hashes by the nightly cron.

const LANGS = ['en', 'ru', 'zh'];
// a release's files by system; keep in sync with tools/site.py and site/src/app.js
const SYSTEMS = { mac: /-macos-arm64\.zip$/, win: /^RDC\.exe$/, linux: /^rdc-linux-x86_64$/, mcp: /^rdc-mcp\.mcpb$/ };
const OS = ['mac', 'win', 'linux', 'ios', 'android', 'other'];
const BOT = /bot|crawl|spider|slurp|preview|headless|lighthouse|monitor|curl|wget|python|scrapy/i;
const TOP = ['country', 'lang', 'os', 'device', 'ref', 'dl'];

const day = (offset = 0) => new Date(Date.now() - offset * 864e5).toISOString().slice(0, 10);

function origins(env) {
  return (env.ALLOWED_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean);
}
function allowed(req, env) {
  const o = req.headers.get('Origin') || '';
  return origins(env).includes(o) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o) ? o : '';
}
function cors(req, env) {
  const o = allowed(req, env);
  return o ? { 'Access-Control-Allow-Origin': o, 'Access-Control-Allow-Headers': 'Authorization', Vary: 'Origin' } : {};
}
const json = (body, status, headers) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', ...headers } });

let saltCache = { day: '', value: '' };
async function salt(env, today) {
  if (saltCache.day === today) return saltCache.value;
  const fresh = crypto.randomUUID() + crypto.randomUUID();
  await env.DB.prepare('INSERT OR IGNORE INTO salts(day, v) VALUES(?, ?)').bind(today, fresh).run();
  const row = await env.DB.prepare('SELECT v FROM salts WHERE day = ?').bind(today).first();
  saltCache = { day: today, value: row.v };
  return row.v;
}
async function sha(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf).slice(0, 12), b => b.toString(16).padStart(2, '0')).join('');
}

async function hit(req, env) {
  if (!allowed(req, env)) return new Response(null, { status: 403 });
  const ua = req.headers.get('User-Agent') || '';
  if (!ua || BOT.test(ua)) return new Response(null, { status: 204 });
  let e;
  try { e = JSON.parse((await req.text()).slice(0, 1024)); } catch (err) { return new Response(null, { status: 400 }); }
  const lang = LANGS.includes(e.l) ? e.l : 'en';
  const os = OS.includes(e.o) ? e.o : 'other';
  const today = day();
  const bump = (dim, key) =>
    env.DB.prepare('INSERT INTO counts(day, dim, key, n) VALUES(?, ?, ?, 1) ON CONFLICT(day, dim, key) DO UPDATE SET n = n + 1')
      .bind(today, dim, key);

  if (e.t === 'dl') {
    if (!(os in SYSTEMS)) return new Response(null, { status: 204 });
    await env.DB.batch([bump('dl', os), bump('dl_lang', lang), bump('dls', 'all')]);
    return new Response(null, { status: 204 });
  }
  if (e.t !== 'view') return new Response(null, { status: 400 });

  const page = typeof e.p === 'string' && /^\/[\w\-/]{0,40}$/.test(e.p) ? e.p : '/';
  const ref = typeof e.r === 'string' && /^[a-z0-9.\-]{1,64}$/i.test(e.r) ? e.r.toLowerCase().replace(/^www\./, '') : '';
  const country = (req.cf && req.cf.country) || 'XX';
  const device = /Mobi|Android|iPhone|iPad/i.test(ua) ? 'mobile' : 'desktop';

  const h = await sha((await salt(env, today)) + '|' + (req.headers.get('CF-Connecting-IP') || '') + '|' + ua);
  const seen = await env.DB.prepare('INSERT OR IGNORE INTO seen(day, h) VALUES(?, ?)').bind(today, h).run();
  const batch = [bump('views', 'all'), bump('page', page), bump('lang', lang), bump('os', os), bump('device', device), bump('country', country)];
  if (ref) batch.push(bump('ref', ref));
  if (seen.meta.changes === 1) batch.push(bump('uniques', 'all'));
  await env.DB.batch(batch);
  return new Response(null, { status: 204 });
}

// GitHub's release list -> {version, files[system], downloads}. Same shape as tools/site.py.
function normalize(releases) {
  const downloads = { total: 0, mac: 0, win: 0, linux: 0, mcp: 0 };
  const newer = (a, b) => { const x = a.split('.').map(Number), y = b.split('.').map(Number); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i]; return false; };
  let best = null, files = {};
  for (const rel of releases) {
    const m = /^v(\d+\.\d+\.\d+)$/.exec(rel.tag_name || '');
    if (!m || rel.draft || rel.prerelease) continue;
    for (const asset of rel.assets || []) {
      const system = Object.keys(SYSTEMS).find(s => SYSTEMS[s].test(asset.name));
      if (!system) continue;
      downloads[system] += asset.download_count || 0;
      if (system !== 'mcp') downloads.total += asset.download_count || 0;
      if (best === null || newer(m[1], best)) { best = m[1]; files = {}; }
      if (m[1] === best) files[system] = { url: asset.browser_download_url, size: asset.size };
    }
  }
  if (best === null || !files.mac || !files.win || !files.linux) return null;
  return { version: best, files, downloads };
}

// the normalized releases as JSON text, from the cache or from GitHub; null when GitHub has none
async function releasesBody(req, env, ctx) {
  const cacheKey = new Request(new URL('/releases', req.url).toString());
  const cache = caches.default;
  // the last good answer, kept for a week: GitHub limits requests without a token per
  // address, and Cloudflare's addresses are shared, so a refused request is not rare
  const staleKey = new Request(new URL('/releases-stale', req.url).toString());
  let body = await cache.match(cacheKey).then(r => r && r.text());
  if (!body) {
    const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'site-worker' };
    if (env.GITHUB_TOKEN) headers.Authorization = 'Bearer ' + env.GITHUB_TOKEN;
    const r = await fetch(`https://api.github.com/repos/${env.REPO}/releases?per_page=100`, { headers }).catch(() => null);
    const data = r && r.ok ? normalize(await r.json()) : null;
    if (!data) return await cache.match(staleKey).then(s => s && s.text());
    body = JSON.stringify(data);
    ctx.waitUntil(Promise.all([
      cache.put(cacheKey, new Response(body, { headers: { 'Cache-Control': 'public, max-age=600' } })),
      cache.put(staleKey, new Response(body, { headers: { 'Cache-Control': 'public, max-age=604800' } })),
    ]));
  }
  return body;
}
async function releases(req, env, ctx) {
  const body = await releasesBody(req, env, ctx);
  if (!body) return json({ error: 'no releases' }, 502, cors(req, env));
  return new Response(body, { headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'public, max-age=300', ...cors(req, env) } });
}

async function statsData(env, n) {
  const from = day(n - 1);
  const [dailyRows, topRows] = await env.DB.batch([
    env.DB.prepare("SELECT day, dim, SUM(n) AS n FROM counts WHERE day >= ? AND dim IN ('views', 'uniques', 'dls') GROUP BY day, dim").bind(from),
    env.DB.prepare(`SELECT dim, key, SUM(n) AS n FROM counts WHERE day >= ? AND dim IN (${TOP.map(() => '?').join(',')}) GROUP BY dim, key ORDER BY n DESC`).bind(from, ...TOP),
  ]);
  const byDay = {};
  for (let i = n - 1; i >= 0; i--) byDay[day(i)] = { day: day(i), views: 0, uniques: 0, dl: 0 };
  for (const r of dailyRows.results) if (byDay[r.day]) byDay[r.day][r.dim === 'dls' ? 'dl' : r.dim] = r.n;
  const daily = Object.values(byDay);
  const top = Object.fromEntries(TOP.map(d => [d, []]));
  for (const r of topRows.results) if (top[r.dim].length < 12) top[r.dim].push([r.key, r.n]);
  const sum = k => daily.reduce((a, d) => a + d[k], 0);
  return { days: n, daily, top, totals: { views: sum('views'), uniques: sum('uniques'), dl: sum('dl') } };
}
async function stats(req, env) {
  if (env.STATS_KEY && req.headers.get('Authorization') !== 'Bearer ' + env.STATS_KEY) return json({ error: 'key' }, 401, cors(req, env));
  const n = Math.min(365, Math.max(1, parseInt(new URL(req.url).searchParams.get('days'), 10) || 30));
  return json(await statsData(env, n), 200, { 'Cache-Control': env.STATS_KEY ? 'no-store' : 'public, max-age=120', ...cors(req, env) });
}

// The site is built and published by GitHub Pages; this hands it out under the site's own
// domain. Redirects GitHub answers with (a missing trailing slash) are pointed back here.
//
// Pages are regenerated here, at most once in PAGE_TTL seconds: the static HTML gets the
// current release, download count and statistics written into it (the numbers themselves,
// the page's data and the schema.org description), so a crawler that runs no scripts reads
// the same figures a visitor sees. Everything else passes through untouched.
const PAGE_TTL = 300;
async function pages(req, env, url, ctx) {
  if (req.method !== 'GET' && req.method !== 'HEAD') return new Response('method not allowed', { status: 405 });
  const origin = env.PAGES_ORIGIN.replace(/\/$/, ''), prefix = new URL(origin).pathname;
  const isPage = req.method === 'GET' && url.pathname.endsWith('/');
  const pageKey = new Request(url.origin + url.pathname);
  if (isPage) {
    const cached = await caches.default.match(pageKey);
    if (cached) return cached;
  }
  const headers = {};
  for (const k of isPage ? ['Accept', 'User-Agent'] : ['Accept', 'Accept-Language', 'If-None-Match', 'If-Modified-Since', 'Range', 'User-Agent']) {
    const v = req.headers.get(k);
    if (v) headers[k] = v;
  }
  const r = await fetch(origin + url.pathname + url.search, { method: req.method, headers, redirect: 'manual' });
  const out = new Headers(r.headers);
  const loc = out.get('Location');
  if (loc) out.set('Location', loc.startsWith(origin) ? url.origin + loc.slice(origin.length) : loc.startsWith(prefix + '/') ? loc.slice(prefix.length) : loc);
  if (!isPage || r.status !== 200 || !(out.get('Content-Type') || '').includes('text/html')) {
    return new Response(r.body, { status: r.status, headers: out });
  }
  for (const k of ['ETag', 'Last-Modified', 'Content-Length', 'Age', 'Expires']) out.delete(k);
  out.set('Cache-Control', `public, max-age=${PAGE_TTL}`);
  const page = new Response(await (await regenerate(r, req, env, ctx)).arrayBuffer(), { status: 200, headers: out });
  ctx.waitUntil(caches.default.put(pageKey, page.clone()));
  return page;
}

async function regenerate(r, req, env, ctx) {
  const [relBody, st] = await Promise.all([
    releasesBody(req, env, ctx).catch(() => null),
    env.STATS_KEY ? null : statsData(env, 30).catch(() => null),
  ]);
  const rel = relBody ? JSON.parse(relBody) : null;
  if (!rel && !st) return r;
  let nf = new Intl.NumberFormat('en');
  // a script's text arrives in pieces: collect them, then write the changed JSON once
  const jsonScript = change => {
    let buf = '';
    return {
      text(t) {
        buf += t.text;
        if (!t.lastInTextNode) return t.remove();
        let text = buf;
        try { const d = JSON.parse(buf); change(d); text = JSON.stringify(d).replace(/</g, '\\u003c'); } catch (e) {}
        buf = '';
        t.replace(text, { html: true });
      },
    };
  };
  // the page names the release it was built with (in <head>, so it is read before the body);
  // an older list, from the cache or the copy kept while GitHub refuses, never replaces it
  let baked = null;
  const older = (a, b) => {
    const x = a.split('.').map(Number), y = b.split('.').map(Number);
    for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i];
    return false;
  };
  const useRel = () => rel && !(baked && older(rel.version, baked));
  const number = n => ({ element(e) { if (useRel()) e.setInnerContent(nf.format(n)); } });
  const show = { element(e) { if (useRel()) e.removeAttribute('hidden'); } };
  let rw = new HTMLRewriter()
    .on('html', { element(e) { try { nf = new Intl.NumberFormat(e.getAttribute('lang') || 'en'); } catch (err) {} } })
    .on('meta[name="rdc-version"]', { element(e) { baked = e.getAttribute('content'); } })
    .on('script#rdc', jsonScript(d => { if (useRel()) d.releases = rel; if (st) d.stats = st; d.fresh = true; }))
    .on('script[type="application/ld+json"]', jsonScript(d => {
      if (!useRel()) return;
      d.softwareVersion = rel.version;
      if (rel.downloads.total > 0) {
        d.interactionStatistic = { '@type': 'InteractionCounter', interactionType: 'https://schema.org/DownloadAction', userInteractionCount: rel.downloads.total };
      }
    }));
  if (rel) {
    rw = rw.on('[data-ver]', { element(e) { if (useRel()) e.setInnerContent('v' + rel.version); } });
    if (rel.downloads.total > 0) rw = rw.on('#count', show).on('#count-n', number(rel.downloads.total));
  }
  if (st) {
    rw = rw.on('#stats', show).on('#sx-views', number(st.totals.views)).on('#sx-uniques', number(st.totals.uniques)).on('#sx-dl', number(st.totals.dl));
  }
  return rw.transform(r);
}

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    let pathname = url.pathname;
    try {
      // on the site's own domain the API lives under /api, everything else is the site itself
      if (pathname.startsWith('/api/')) pathname = pathname.slice(4);
      else if (env.PAGES_ORIGIN) return await pages(req, env, url, ctx);
      if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: { ...cors(req, env), 'Access-Control-Max-Age': '86400' } });
      if (pathname === '/hit' && req.method === 'POST') return await hit(req, env);
      if (pathname === '/releases' && req.method === 'GET') return await releases(req, env, ctx);
      if (pathname === '/stats' && req.method === 'GET') return await stats(req, env);
      return new Response('not found', { status: 404 });
    } catch (e) {
      return json({ error: 'internal' }, 500, cors(req, env));
    }
  },
  // nightly: yesterday's visitor hashes and salts are no longer needed
  async scheduled(event, env) {
    const today = day();
    await env.DB.batch([
      env.DB.prepare('DELETE FROM seen WHERE day < ?').bind(today),
      env.DB.prepare('DELETE FROM salts WHERE day < ?').bind(today),
    ]);
  },
};
