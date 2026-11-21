(() => {
'use strict';
const d = document;
const $ = (s, p) => (p || d).querySelector(s);
const $$ = (s, p) => Array.from((p || d).querySelectorAll(s));
const RDC = JSON.parse($('#rdc').textContent);
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const ease = t => 1 - Math.pow(1 - t, 3);

/* ---------- language: a manual choice wins on the next visit (the root page reads it) ---------- */
$$('[data-lang]').forEach(a => a.addEventListener('click', () => {
  try { localStorage.setItem('rdc-lang', a.dataset.lang); } catch (e) {}
}));

/* ---------- system ---------- */
const OS = (() => {
  const u = navigator.userAgent;
  const p = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || '';
  if (/Android/i.test(u)) return 'android';
  if (/iPhone|iPad|iPod/i.test(u) || (/Mac/i.test(p) && navigator.maxTouchPoints > 1)) return 'ios';
  if (/Mac/i.test(p)) return 'mac';
  if (/Win/i.test(p)) return 'win';
  if (/Linux|X11/i.test(p)) return 'linux';
  return 'other';
})();
const HOST = OS === 'mac' || OS === 'win' || OS === 'linux';   // systems RDC shares the screen of
const CARD = OS === 'android' || OS === 'ios' ? 'phone' : OS;
const ARCH = { mac: 'Apple Silicon', win: 'Windows x64', linux: 'Linux x64' };

/* ---------- visits and downloads: counted by the worker, without cookies ---------- */
const quiet = navigator.doNotTrack === '1' || navigator.globalPrivacyControl === true;
function beacon(o) {
  if (!RDC.worker || quiet) return;
  try { navigator.sendBeacon(RDC.worker + '/hit', JSON.stringify(o)); } catch (e) {}
}
let ref = '';
try { if (d.referrer) { const h = new URL(d.referrer).hostname; if (h !== location.hostname) ref = h; } } catch (e) {}
beacon({ t: 'view', p: '/', l: RDC.lang, o: OS, r: ref });
d.addEventListener('click', e => {
  const a = e.target.closest && e.target.closest('[data-dl]');
  if (a) beacon({ t: 'dl', l: RDC.lang, o: a.dataset.dl });
});

/* ---------- releases: baked in at build time, refreshed from the worker or from GitHub ---------- */
const nf = new Intl.NumberFormat(RDC.lang);
const mb = (bytes, unit) => bytes ? (bytes / 1e6).toFixed(1) + (unit ? ' ' + unit : '') : '';
let counted = false;

function countUp(el, to) {
  if (reduce || !to) { el.textContent = nf.format(to); return; }
  const t0 = performance.now();
  (function step(now) {
    const k = clamp((now - t0) / 1400, 0, 1);
    el.textContent = nf.format(Math.round(to * ease(k)));
    if (k < 1) requestAnimationFrame(step);
  })(t0);
}

const SYSTEMS = { mac: /-macos-arm64\.zip$/, win: /^RDC\.exe$/, linux: /^rdc-linux-x86_64$/, mcp: /^rdc-mcp\.mcpb$/ };
const cmp = (a, b) => {
  const x = String(a).split('.').map(Number), y = String(b).split('.').map(Number);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
};
// GitHub's release list -> {version, files[system], downloads}; the same shape as tools/site.py and the worker
function normalize(list) {
  const downloads = { total: 0, mac: 0, win: 0, linux: 0, mcp: 0 };
  let best = null, files = {};
  for (const rel of list) {
    const m = /^v(\d+\.\d+\.\d+)$/.exec(rel.tag_name || '');
    if (!m || rel.draft || rel.prerelease) continue;
    for (const asset of rel.assets || []) {
      const s = Object.keys(SYSTEMS).find(k => SYSTEMS[k].test(asset.name));
      if (!s) continue;
      downloads[s] += asset.download_count || 0;
      if (s !== 'mcp') downloads.total += asset.download_count || 0;
      if (best === null || cmp(m[1], best) > 0) { best = m[1]; files = {}; }
      if (m[1] === best) files[s] = { url: asset.browser_download_url, size: asset.size };
    }
  }
  return best && files.mac && files.win && files.linux ? { version: best, files, downloads } : null;
}

function applyReleases(rel) {
  if (!rel || !rel.files) return;
  if (RDC.releases && cmp(rel.version, RDC.releases.version) < 0) return;   // a stale cache never replaces the build's
  const files = rel.files;
  $$('[data-dl]').forEach(a => { if (files[a.dataset.dl]) a.href = files[a.dataset.dl].url; });
  $$('[data-size]').forEach(el => { el.textContent = mb((files[el.dataset.size] || {}).size, 'bare' in el.dataset ? '' : el.dataset.mb); });
  $$('[data-ver]').forEach(el => { el.textContent = 'v' + rel.version; });

  const cta = $('#cta'), meta = $('#cta-meta');
  if (HOST && files[OS]) {
    cta.href = files[OS].url;
    cta.dataset.dl = OS;
    cta.textContent = cta.dataset[OS];
    meta.textContent = ['v' + rel.version, mb(files[OS].size, meta.dataset.mb), ARCH[OS]].filter(Boolean).join(' · ');
    $('#cta-all').hidden = false;
  } else {
    meta.textContent = 'v' + rel.version + ' · macOS · Windows · Linux';
  }

  const dl = rel.downloads, box = $('#count');
  if (dl && dl.total > 0) {
    box.hidden = false;
    $$('[data-count]').forEach(el => {
      const n = dl[el.dataset.count] || 0;
      if (el.id === 'count-n') { el.dataset.to = n; if (counted) el.textContent = nf.format(n); }
      else el.textContent = n ? '↓ ' + nf.format(n) : '';
    });
  }
}
$$('.plat').forEach(el => el.classList.toggle('me', el.dataset.os === CARD));
applyReleases(RDC.releases);
if (!RDC.fresh) {
  (RDC.worker
    ? fetch(RDC.worker + '/releases').then(r => r.ok ? r.json() : null)
    : fetch('https://api.github.com/repos/' + RDC.repo + '/releases?per_page=100', { headers: { Accept: 'application/vnd.github+json' } })
        .then(r => r.ok ? r.json() : null).then(l => l && normalize(l))
  ).then(applyReleases).catch(() => {});
}

/* ---------- copy buttons ---------- */
function copied(btn) {
  const use = $('use', btn), was = use.getAttribute('href');
  use.setAttribute('href', '#i-check'); btn.classList.add('done');
  setTimeout(() => { use.setAttribute('href', was); btn.classList.remove('done'); }, 1200);
}
$$('[data-copy-text]').forEach(b => b.addEventListener('click', () => {
  (navigator.clipboard ? navigator.clipboard.writeText(b.dataset.copyText) : Promise.reject()).then(() => copied(b)).catch(() => {});
}));

/* ---------- AI agents: one tab at a time ---------- */
$$('#ag-tabs button').forEach(b => b.addEventListener('click', () => {
  $$('#ag-tabs button').forEach(o => o.setAttribute('aria-pressed', String(o === b)));
  $$('.ag-p').forEach(p => p.classList.toggle('on', p.dataset.a === b.dataset.a));
}));

/* ---------- the window: the app's own buttons, with a phone that answers ---------- */
(() => {
  const demo = $('#demo'), stage = $('#stage'), label = $('#st-label'), code = $('#demo-code');
  let touched = false, timer = 0;
  // the last digit is a check digit in the app; here the code is only a picture of one
  const fresh = () => Array.from({ length: 3 }, () => String(Math.floor(Math.random() * 1000)).padStart(3, '0')).join(' ');
  function set(live) {
    demo.dataset.state = live ? 'live' : 'idle';
    stage.classList.toggle('live', live);
    label.textContent = live ? label.dataset.live : label.dataset.idle;
  }
  function roll() {
    const to = fresh(), t0 = performance.now();
    if (reduce) { code.textContent = to; return; }
    (function step(now) {
      const k = (now - t0) / 420;
      code.textContent = k >= 1 ? to : fresh();
      if (k < 1) setTimeout(() => requestAnimationFrame(step), 40);
    })(t0);
  }
  $('#demo-new').addEventListener('click', () => { touched = true; set(false); roll(); });
  $('#demo-kick').addEventListener('click', () => { touched = true; set(false); });
  $$('[data-copy]', demo).forEach(b => b.addEventListener('click', () => { touched = true; copied(b); }));
  $$('[data-open]', demo).forEach(b => b.addEventListener('click', () => { touched = true; set(true); }));
  // left alone, the window shows what happens by itself: a phone connects, then leaves
  function auto() {
    if (touched) return;
    set(demo.dataset.state !== 'live');
    timer = setTimeout(auto, demo.dataset.state === 'live' ? 5200 : 2600);
  }
  if (!reduce) timer = setTimeout(auto, 1800); else set(true);
  demo.addEventListener('pointerdown', () => { touched = true; clearTimeout(timer); }, { once: true });
})();

/* ---------- the viewer, over the page ---------- */
(() => {
  const form = $('#connect'), input = $('#join-link'), err = $('#join-err');
  const view = $('#view'), frame = $('#view-frame');
  let watch = 0, wasLive = false;
  // "#123456789-<key>", "#my-<key>", or the whole link; the same rule as parseEntry in web/viewer.js
  function entry(text) {
    let s = String(text || '').trim();
    const h = s.lastIndexOf('#');
    if (h >= 0) s = s.slice(h + 1);
    s = s.replace(/\s/g, '');
    return /^(\d{9}|my)-[A-Za-z0-9_-]{22}$/.test(s) ? s : '';
  }
  function close() {
    clearInterval(watch);
    view.hidden = true; view.classList.remove('live');
    d.body.classList.remove('viewing');
    frame.src = 'about:blank';
    if (location.hash.length > 1 && entry(location.hash)) history.replaceState(null, '', location.pathname);
  }
  function open(e) {
    err.hidden = true;
    wasLive = false;
    frame.src = '../#' + e;
    view.hidden = false;
    d.body.classList.add('viewing');
    frame.focus();
    clearInterval(watch);
    // the viewer's own Disconnect brings the page back
    watch = setInterval(() => {
      let live = false;
      try { live = frame.contentDocument.body.classList.contains('live'); } catch (x) { return; }
      view.classList.toggle('live', live);
      if (live) wasLive = true; else if (wasLive) close();
    }, 300);
  }
  function submit(text) {
    const e = entry(text);
    if (!e) { err.textContent = err.dataset.bad; err.hidden = false; return false; }
    input.value = '';
    open(e);
    return true;
  }
  form.addEventListener('submit', ev => { ev.preventDefault(); submit(input.value); });
  input.addEventListener('paste', ev => {
    const t = (ev.clipboardData || window.clipboardData).getData('text');
    if (entry(t)) { ev.preventDefault(); submit(t); }
  });
  input.addEventListener('input', () => { err.hidden = true; });
  $('#view-x').addEventListener('click', close);
  d.addEventListener('keydown', ev => { if (ev.key === 'Escape' && !view.hidden && !view.classList.contains('live')) close(); });
  $$('a[href="#connect"]').forEach(a => a.addEventListener('click', ev => {
    ev.preventDefault();
    form.scrollIntoView({ block: 'center', behavior: reduce ? 'auto' : 'smooth' });
    input.focus({ preventScroll: true });
  }));
})();

/* ---------- statistics: what the worker counted ---------- */
(() => {
  const sec = $('#stats');
  if (!RDC.worker) return;
  const T = sec.dataset, box = $('#chart');
  const el = (tag, cls, text) => { const e = d.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const svg = (tag, attrs) => { const e = d.createElementNS('http://www.w3.org/2000/svg', tag); for (const k in attrs) e.setAttribute(k, attrs[k]); return e; };
  let regions = null, dayFmt = null;
  try { regions = new Intl.DisplayNames([RDC.lang], { type: 'region' }); } catch (e) {}
  try { dayFmt = new Intl.DateTimeFormat(RDC.lang, { day: 'numeric', month: 'short', timeZone: 'UTC' }); } catch (e) {}
  const date = iso => dayFmt ? dayFmt.format(new Date(iso + 'T00:00:00Z')) : iso.slice(5);
  const SYS = { mac: 'macOS', win: 'Windows', linux: 'Linux', ios: 'iOS', android: 'Android', other: '?' };
  function name(dim, key) {
    if (dim === 'os') return SYS[key] || key;
    if (dim === 'country') { try { return (regions && key !== 'XX' && regions.of(key)) || key; } catch (e) { return key; } }
    return key;
  }
  function rows(list, to) {
    to.textContent = '';
    if (!list || !list.length) { to.append(el('p', 'none', T.empty)); return; }
    const max = list[0][1] || 1;
    list.slice(0, 5).forEach(([key, n]) => {
      const row = el('div', 'row');
      row.style.setProperty('--w', (n / max * 100).toFixed(1) + '%');
      row.append(el('span', '', name(to.dataset.dim, key)), el('b', '', nf.format(n)));
      to.append(row);
    });
  }
  // Views and visitors share one axis: a bar per day, visitors in front of the views they are part of.
  function chart(daily) {
    box.textContent = '';
    const W = Math.max(280, box.clientWidth), H = 230, L = 38, Tp = 8, B = 26;
    const n = daily.length, iw = W - L, ih = H - Tp - B, band = iw / n, bw = Math.max(2, Math.min(30, band * 0.7));
    const raw = Math.max(1, ...daily.map(x => x.views));
    const pow = Math.pow(10, Math.floor(Math.log10(raw)));
    const top = Math.max(4, Math.ceil(raw / pow * 2) / 2 * pow);
    const base = Tp + ih, y = v => base - v / top * ih, cx = i => L + band * (i + 0.5);
    const s = svg('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': T.views + ', ' + T.uniques });
    for (let i = 0; i <= 2; i++) {
      const v = top / 2 * i;
      s.append(svg('rect', { x: L, y: Math.round(y(v)), width: iw, height: 1, fill: 'rgba(255,255,255,.08)' }));
      const t = svg('text', { x: L - 10, y: y(v) + 4, 'text-anchor': 'end' }); t.textContent = nf.format(v); s.append(t);
    }
    [0, Math.floor((n - 1) / 2), n - 1].filter((v, i, a) => a.indexOf(v) === i).forEach(i => {
      const t = svg('text', { x: cx(i), y: H - 6, 'text-anchor': i === 0 && n > 10 ? 'start' : i === n - 1 && n > 10 ? 'end' : 'middle' });
      t.textContent = date(daily[i].day); s.append(t);
    });
    const bar = (i, v, fill) => {
      const h = v / top * ih;
      if (h < 0.5) return;
      const x = cx(i) - bw / 2, r = Math.min(4, bw / 2, h), t = base - h;
      const b = svg('path', { class: 'bar', fill, d: `M${x} ${base}V${t + r}Q${x} ${t} ${x + r} ${t}H${x + bw - r}Q${x + bw} ${t} ${x + bw} ${t + r}V${base}Z` });
      b.style.animationDelay = (reduce ? 0 : i * Math.min(14, 420 / n)) + 'ms';
      s.append(b);
    };
    daily.forEach((p, i) => { bar(i, p.views, '#4a4a54'); bar(i, p.uniques, '#4a8dff'); });
    const tip = el('div', 'tip'), cols = [];
    daily.forEach((p, i) => { const c = svg('rect', { class: 'col', x: L + band * i, y: Tp, width: band, height: ih }); cols.push(c); s.append(c); });
    box.append(s, tip);
    const table = el('table', 'vh'), head = el('tr');
    ['', T.views, T.uniques].forEach(h => head.append(el('th', '', h)));
    table.append(head);
    daily.forEach(p => { const tr = el('tr'); [p.day, p.views, p.uniques].forEach(v => tr.append(el('td', '', v))); table.append(tr); });
    box.append(table);
    let cur = -1;
    const off = () => { if (cur >= 0) cols[cur].classList.remove('on'); cur = -1; tip.classList.remove('show'); };
    s.addEventListener('pointerleave', off);
    s.addEventListener('pointermove', e => {
      const r = s.getBoundingClientRect(), px = (e.clientX - r.left) / r.width * W;
      const i = clamp(Math.floor((px - L) / band), 0, n - 1), p = daily[i];
      if (i === cur) return;
      off(); cur = i; cols[i].classList.add('on');
      tip.textContent = '';
      tip.append(el('b', '', date(p.day)));
      [[T.views, p.views], [T.uniques, p.uniques]].forEach(([k, v]) => { const row = el('div', '', k); row.append(el('i', '', nf.format(v))); tip.append(row); });
      const tx = cx(i) / W * r.width, full = box.clientWidth;
      tip.style.left = clamp(tx > full / 2 ? tx - tip.offsetWidth - 16 : tx + 16, 8, full - tip.offsetWidth - 8) + 'px';
      tip.classList.add('show');
    });
  }
  let data = null, seen = false, days = 30;
  function draw(first) {
    if (!data || !seen) return;
    [['#sx-views', 'views'], ['#sx-uniques', 'uniques'], ['#sx-dl', 'dl']].forEach(([id, k]) => {
      first ? countUp($(id), data.totals[k]) : ($(id).textContent = nf.format(data.totals[k]));
    });
    chart(data.daily);
    $$('.rows', sec).forEach(to => rows(data.top[to.dataset.dim], to));
  }
  function load(first) {
    fetch(RDC.worker + '/stats?days=' + days).then(r => r.ok ? r.json() : null).then(j => {
      if (!j || !j.daily) return;
      data = j;
      sec.hidden = false;
      draw(first);
    }).catch(() => {});
  }
  $$('#period button').forEach(b => b.addEventListener('click', () => {
    days = +b.dataset.d;
    $$('#period button').forEach(o => o.setAttribute('aria-pressed', String(o === b)));
    load(false);
  }));
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver(es => { if (es[0].isIntersecting) { seen = true; io.disconnect(); draw(true); } }, { rootMargin: '0px 0px -10% 0px' });
    io.observe(sec);
  } else seen = true;
  let rz = 0, lastW = innerWidth;
  addEventListener('resize', () => { if (innerWidth === lastW) return; lastW = innerWidth; clearTimeout(rz); rz = setTimeout(() => draw(false), 150); });
  if (RDC.stats) { data = RDC.stats; sec.hidden = false; draw(true); } else load(true);
})();

/* ---------- reveal on scroll ---------- */
if ('IntersectionObserver' in window) {
  const io = new IntersectionObserver(es => es.forEach(e => {
    if (!e.isIntersecting) return;
    e.target.classList.add('in');
    io.unobserve(e.target);
    const n = $('#count-n', e.target);
    if (n) { counted = true; countUp(n, +n.dataset.to || 0); }
  }), { rootMargin: '0px 0px -8% 0px' });
  $$('.rv').forEach(el => io.observe(el));
} else {
  $$('.rv').forEach(el => el.classList.add('in'));
}
})();
