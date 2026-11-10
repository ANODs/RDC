'use strict';
// RDC web viewer: H.264 (WebCodecs) or JPEG → canvas; mouse and keyboard → host.
// Transport: WebSocket to the host that served this page (local network), or, with a link
// from anywhere (#<code>-<key>), a WebRTC data channel to a host found through public MQTT
// brokers. Both carry the same messages (src/core/proto.zig).

const $ = (id) => document.getElementById(id);
const canH264 = typeof VideoDecoder === 'function' && typeof EncodedVideoChunk === 'function';
const localIsMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

const MSG = { MOVE: 1, BUTTON: 2, WHEEL: 3, KEY: 4, RELEASE_ALL: 5, KEYFRAME: 16, AUDIO: 20, CAMERA: 21 };
const FRAME = { H264: 1, JPEG: 2 };

// KeyboardEvent.code → USB HID usage (page 0x07). The host maps them to its own OS codes.
const HID = (() => {
  const t = {};
  'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('').forEach((c, i) => (t['Key' + c] = 0x04 + i));
  '1234567890'.split('').forEach((c, i) => (t['Digit' + c] = 0x1e + i));
  for (let i = 1; i <= 12; i++) t['F' + i] = 0x39 + i;
  for (let i = 13; i <= 24; i++) t['F' + i] = 0x68 + (i - 13);
  '1234567890'.split('').forEach((c, i) => (t['Numpad' + c] = 0x59 + i));
  Object.assign(t, {
    Enter: 0x28, Escape: 0x29, Backspace: 0x2a, Tab: 0x2b, Space: 0x2c, Minus: 0x2d, Equal: 0x2e,
    BracketLeft: 0x2f, BracketRight: 0x30, Backslash: 0x31, Semicolon: 0x33, Quote: 0x34, Backquote: 0x35,
    Comma: 0x36, Period: 0x37, Slash: 0x38, CapsLock: 0x39, PrintScreen: 0x46, ScrollLock: 0x47, Pause: 0x48,
    Insert: 0x49, Home: 0x4a, PageUp: 0x4b, Delete: 0x4c, End: 0x4d, PageDown: 0x4e,
    ArrowRight: 0x4f, ArrowLeft: 0x50, ArrowDown: 0x51, ArrowUp: 0x52, NumLock: 0x53,
    NumpadDivide: 0x54, NumpadMultiply: 0x55, NumpadSubtract: 0x56, NumpadAdd: 0x57, NumpadEnter: 0x58,
    NumpadDecimal: 0x63, IntlBackslash: 0x64, ContextMenu: 0x65, NumpadEqual: 0x67, IntlRo: 0x87, IntlYen: 0x89,
    Lang1: 0x90, Lang2: 0x91,
    ControlLeft: 0xe0, ShiftLeft: 0xe1, AltLeft: 0xe2, MetaLeft: 0xe3,
    ControlRight: 0xe4, ShiftRight: 0xe5, AltRight: 0xe6, MetaRight: 0xe7,
  });
  return t;
})();

const canvas = $('screen');
const ctx2d = canvas.getContext('2d', { alpha: false, desynchronized: true });

let conn = null;               // the current transport: {send(data), close()}
let code = '';
let key = '';                  // the key of a link from anywhere; empty — this network
let perm = false;              // the permanent link: the computer asks for a code from an authenticator app
let otp = '';                  // the code just typed, for one hello
let resume = '';               // lets this tab reconnect without a new code
let host = null;               // {w, h, os, name, codec}
let wantConnected = false;
let forceJpeg = false;
let decoder = null;
let configured = false;
let waitKey = true;
let decodeErrors = 0;
let jpegBusy = false;
let jpegNext = null;
let swapCtrl = false;
const pressed = new Set();
const stats = { frames: 0, bytes: 0, t0: performance.now(), rtt: 0 };

// ---------------------------------------------------------------- connection

function formatCode(s) {
  const d = s.replace(/\D/g, '').slice(0, 9);
  return d.replace(/(\d{3})(?=\d)/g, '$1 ');
}

// The permanent link has "my" where an ordinary one has the code; keep in sync with link_name in src/core/totp.zig.
const PERMANENT = 'my';
const resumeSlot = () => 'rdc.resume.' + key;
function loadResume() { try { return sessionStorage.getItem(resumeSlot()) || ''; } catch (_) { return ''; } }
function saveResume(v) {
  resume = v;
  try { if (v) sessionStorage.setItem(resumeSlot(), v); else sessionStorage.removeItem(resumeSlot()); } catch (_) {}
}

// What the join card asks for: an authenticator code, a link, or the 9-digit code.
function paintJoin() {
  const c = $('code');
  c.classList.toggle('link', !perm && !servedByHost);
  if (perm) {
    $('hint').textContent = 'Enter the 6-digit code from your authenticator app';
    c.placeholder = '123 456';
    c.setAttribute('inputmode', 'numeric');
    c.setAttribute('autocomplete', 'one-time-code');
  } else {
    $('hint').textContent = servedByHost ? 'Enter the code from the RDC window on the computer'
                                         : 'Open the link from the RDC window on the computer, or paste it here';
    c.placeholder = servedByHost ? '123 456 789' : 'Link from the RDC window';
    c.setAttribute('inputmode', servedByHost ? 'numeric' : 'url');
    c.setAttribute('autocomplete', 'off');
  }
}

function showJoin(error) {
  wantConnected = false;
  otp = '';
  if (perm) $('code').value = '';
  paintJoin();
  osk.reset(); // releases held on-screen keys while the connection is still up
  media.stopAll();
  closeConn();
  host = null;
  document.body.classList.remove('live');
  $('stage').style.display = 'none';
  $('join').style.display = 'flex';
  $('err').classList.remove('info');
  $('err').textContent = error || '';
  $('code').focus();
}

// Progress while connecting: on the join card, or on the veil over the last picture.
function progress(text) {
  if (host) { $('veil').textContent = text; $('veil').style.display = 'flex'; return; }
  $('err').classList.add('info');
  $('err').textContent = text;
}

// Damm check digit: the last digit of the code catches typos before connecting.
const DAMM = [
  [0, 3, 1, 7, 5, 9, 8, 6, 4, 2], [7, 0, 9, 2, 1, 5, 4, 8, 6, 3], [4, 2, 0, 6, 8, 7, 1, 3, 5, 9],
  [1, 7, 5, 0, 9, 8, 3, 4, 2, 6], [6, 1, 2, 3, 0, 4, 5, 9, 7, 8], [3, 6, 7, 4, 2, 0, 9, 5, 8, 1],
  [5, 8, 6, 9, 7, 2, 0, 1, 3, 4], [8, 9, 4, 5, 3, 6, 2, 0, 1, 7], [9, 4, 3, 8, 6, 1, 7, 2, 0, 5],
  [2, 5, 8, 1, 4, 3, 6, 7, 9, 0],
];
const dammOk = (digits) => [...digits].reduce((i, d) => DAMM[i][+d], 0) === 0;

// "#123456789-<key>" (from anywhere), "#123456789" (this network), or a whole link pasted into the field.
function parseEntry(text) {
  let s = (text || '').trim();
  const hash = s.lastIndexOf('#');
  if (hash >= 0) s = s.slice(hash + 1);
  s = s.replace(/\s/g, '');
  const p = /^my-([A-Za-z0-9_-]{22})$/.exec(s);
  if (p) return { code: PERMANENT, key: p[1], perm: true };
  const m = /^(\d{9})(?:-([A-Za-z0-9_-]{22}))?$/.exec(s);
  if (m) return { code: m[1], key: m[2] || '' };
  return { code: s.replace(/\D/g, ''), key: '' };
}

// The host serves the viewer only over plain HTTP; on https (GitHub Pages) only a link from anywhere works.
const servedByHost = location.protocol === 'http:';
const canRtc = typeof RTCPeerConnection === 'function' && !!(window.crypto && crypto.subtle) && window.isSecureContext;

// The permanent link: connect at once if this tab has been let in before, otherwise ask for a code.
function startPermanent(k) {
  closeConn();
  resetDecoder();
  media.stopAll();
  host = null;
  document.body.classList.remove('live');
  $('stage').style.display = 'none';
  $('join').style.display = 'flex';
  perm = true;
  code = PERMANENT;
  key = k;
  otp = '';
  resume = loadResume();
  $('code').value = '';
  paintJoin();
  if (!canRtc) {
    perm = false;
    return showJoin(servedByHost ? 'Open the permanent link itself, as the RDC window shows it'
                                 : 'This browser cannot connect from anywhere: it has no WebRTC');
  }
  signaling(code, key).catch(() => {}); // the brokers connect while the code is typed
  if (!resume) return showJoin('');
  progress('Connecting…');
  wantConnected = true;
  connect();
}

// A code typed on the permanent link's card.
function submitOtp(text) {
  const d = text.replace(/\D/g, '');
  if (d.length !== 6) return showJoin('The code is 6 digits');
  otp = d;
  saveResume('');
  progress('Connecting…');
  wantConnected = true;
  connect();
}

function start(raw) {
  const e = parseEntry(raw);
  if (e.perm) return startPermanent(e.key);
  perm = false;
  otp = '';
  resume = '';
  paintJoin();
  code = e.code;
  key = e.key;
  if (code.length !== 9) return showJoin(servedByHost ? 'The code must be 9 digits' : 'Open the link from the RDC window on the computer');
  if (!dammOk(code)) return showJoin('Typo in the code — check the digits');
  if (!key && !servedByHost) {
    return showJoin('This page needs the link from anywhere: copy it from the RDC window on the computer (the code alone works only on the computer\'s network)');
  }
  if (key && !canRtc) {
    if (!servedByHost) return showJoin('This browser cannot connect from anywhere: it has no WebRTC');
    key = ''; // the page came from the host itself: talk to it directly
  }
  // A new target starts from scratch, even if another computer was on screen.
  closeConn();
  resetDecoder();
  media.stopAll();
  host = null;
  document.body.classList.remove('live');
  $('stage').style.display = 'none';
  $('join').style.display = 'flex';
  progress('Connecting…');
  wantConnected = true;
  connect();
}

function closeConn() {
  const c = conn;
  conn = null;
  if (c) c.close();
}

function connect() {
  closeConn();
  // The permanent link with nothing to show the computer: ask for a code instead of trying.
  if (perm && !resume && !otp) return showJoin('Enter a new code from your authenticator app');
  let c = null;
  const handlers = {
    open() {
      const hello = { t: 'hello', h264: canH264 && !forceJpeg, agent: navigator.userAgent };
      if (!perm) hello.code = code;
      else if (resume) hello.resume = resume;
      else hello.otp = otp;
      send(JSON.stringify(hello));
    },
    message(data) {
      if (typeof data === 'string') onControl(JSON.parse(data));
      else onFrame(data);
    },
    // why — what went wrong, for the person; fatal — retrying the same way will not help.
    close(why, fatal) {
      if (conn !== c) return;
      conn = null;
      resetDecoder();
      if (!wantConnected) return;
      if (fatal && !host) return showJoin(why);
      if (host) { $('veil').textContent = why || 'Reconnecting…'; $('veil').style.display = 'flex'; }
      setTimeout(() => wantConnected && !conn && connect(), fatal ? 3000 : 1000);
    },
  };
  c = key ? rtcLink(code, key, handlers) : wsLink(handlers);
  conn = c;
}

function send(data) {
  if (conn) conn.send(data);
}

// ---------------------------------------------------------------- transport: this network

function wsLink(h) {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const sock = new WebSocket(`${proto}//${location.host}/ws`);
  sock.binaryType = 'arraybuffer';
  sock.onopen = () => h.open();
  sock.onmessage = (ev) => h.message(ev.data);
  sock.onclose = () => h.close('', false);
  return {
    send(d) { if (sock.readyState === WebSocket.OPEN) sock.send(d); },
    buffered() { return sock.bufferedAmount; },
    close() { sock.onclose = null; sock.close(); },
  };
}

// ---------------------------------------------------------------- transport: from anywhere
// The page finds the host through public MQTT brokers: both sides derive the topic and an
// AES-GCM key from the code and the key in the link (HKDF), so a broker sees only noise.
// Then a WebRTC data channel connects them directly (keep in sync with src/net/signal.zig
// and src/net/webrtc.zig). Anyone can record a sealed message and send it again, so every
// message carries a timestamp: the host refuses ours when it is more than a minute off its
// clock, and its replies carry our offer's timestamp back, which we check on our own clock.

const BROKERS = ['wss://broker.emqx.io:8084/mqtt', 'wss://broker.hivemq.com:8884/mqtt'];
const ICE_SERVERS = [{ urls: ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478'] }];
const NO_BROKER = 'Could not reach the public servers that find the computer — check the internet connection';
const NO_ANSWER = 'The computer does not answer. Is RDC running there? The link changes with every new code.';
const NO_PATH = 'Could not connect directly: the networks on both sides do not allow it (RDC has no relay). Try another network, for example Wi-Fi instead of mobile data.';
const MAX_AGE_MS = 60000; // keep in sync with max_skew_ms in src/net/signal.zig

const te = new TextEncoder();
const td = new TextDecoder();
const hex = (b) => [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
const randomHex = (n) => hex(crypto.getRandomValues(new Uint8Array(n)));

function b64urlBytes(s) {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(bin, (ch) => ch.charCodeAt(0));
}

async function deriveSignal(code, key) {
  const ikm = await crypto.subtle.importKey('raw', te.encode(code), 'HKDF', false, ['deriveBits']);
  const bits = new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: b64urlBytes(key), info: te.encode('rdc signal v1') }, ikm, 48 * 8));
  const topic = 'rdc/' + hex(bits.subarray(0, 16));
  const aes = await crypto.subtle.importKey('raw', bits.slice(16, 48), 'AES-GCM', false, ['encrypt', 'decrypt']);
  return { topic, aes, ad: te.encode(topic) };
}

async function seal(k, obj) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: k.ad }, k.aes, te.encode(JSON.stringify(obj))));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv);
  out.set(ct, 12);
  return out;
}

async function unseal(k, bytes) {
  if (bytes.length < 28) return null;
  try {
    const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.subarray(0, 12), additionalData: k.ad }, k.aes, bytes.subarray(12));
    return JSON.parse(td.decode(pt));
  } catch (_) { return null; } // not ours
}

// MQTT 3.1.1 over WebSocket: CONNECT, SUBSCRIBE and PUBLISH at QoS 0 — all the signaling needs.
function mqttPacket(first, parts) {
  const n = parts.reduce((s, p) => s + p.length, 0);
  const len = [];
  let x = n;
  do { let b = x % 128; x = Math.floor(x / 128); if (x > 0) b |= 128; len.push(b); } while (x > 0);
  const out = new Uint8Array(1 + len.length + n);
  out[0] = first;
  out.set(len, 1);
  let o = 1 + len.length;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

function mqttStr(s) {
  const b = te.encode(s);
  return Uint8Array.of(b.length >> 8, b.length & 255, ...b);
}

function mqttClient(url, topic, onPayload) {
  let sock;
  try { sock = new WebSocket(url, ['mqtt']); } catch (_) { return null; }
  sock.binaryType = 'arraybuffer';
  let buf = new Uint8Array(0);
  let drop = 0; // bytes of an oversized packet still to discard
  let ping = 0;
  const cl = { ready: false, closed: false, onready: null };
  sock.onopen = () => {
    sock.send(mqttPacket(0x10, [mqttStr('MQTT'), Uint8Array.of(4, 2, 0, 60), mqttStr('rdcv-' + randomHex(6))]));
    ping = setInterval(() => sock.readyState === WebSocket.OPEN && sock.send(Uint8Array.of(0xc0, 0)), 30000);
  };
  sock.onmessage = (ev) => {
    let add = new Uint8Array(ev.data);
    if (drop > 0) {
      const d = Math.min(drop, add.length);
      drop -= d;
      add = add.subarray(d);
      if (!add.length) return;
    }
    const joined = new Uint8Array(buf.length + add.length);
    joined.set(buf);
    joined.set(add, buf.length);
    buf = joined;
    for (;;) {
      let i = 1, n = 0, mult = 1;
      for (; i < buf.length && i <= 4; i++) { n += (buf[i] & 127) * mult; mult *= 128; if (!(buf[i] & 128)) break; }
      if (i >= buf.length) return;
      const total = i + 1 + n;
      if (n > 1 << 18) {
        // Anyone can publish to a public topic: skip what we would never keep, keep the connection.
        if (buf.length >= total) { buf = buf.slice(total); continue; }
        drop = total - buf.length;
        buf = new Uint8Array(0);
        return;
      }
      if (buf.length < total) return;
      const type = buf[0] >> 4, qos = (buf[0] >> 1) & 3, body = buf.subarray(i + 1, total);
      buf = buf.slice(total);
      if (type === 2 && body[1] === 0) sock.send(mqttPacket(0x82, [Uint8Array.of(0, 1), mqttStr(topic), Uint8Array.of(0)]));
      else if (type === 9) { cl.ready = true; if (cl.onready) cl.onready(); }
      else if (type === 3 && body.length >= 2) {
        const tl = (body[0] << 8) | body[1];
        if (td.decode(body.subarray(2, 2 + tl)) === topic) onPayload(body.slice(2 + tl + (qos ? 2 : 0)));
      }
    }
  };
  sock.onclose = () => { cl.closed = true; cl.ready = false; clearInterval(ping); };
  cl.publish = (payload) => { if (cl.ready && sock.readyState === WebSocket.OPEN) sock.send(mqttPacket(0x30, [mqttStr(topic), payload])); };
  cl.close = () => { sock.onclose = null; clearInterval(ping); sock.close(); cl.closed = true; };
  return cl;
}

// Broker connections for the current code and key, shared by reconnects.
let sigCache = null;

function signaling(code, key) {
  const name = code + '-' + key;
  if (sigCache && sigCache.name === name && sigCache.alive()) return sigCache.promise;
  if (sigCache) sigCache.close();
  const listeners = new Set();
  let clients = [];
  const entry = {
    name,
    alive: () => clients.length === 0 || clients.some((c) => !c.closed),
    close: () => { for (const c of clients) c.close(); clients = []; },
  };
  entry.promise = (async () => {
    const k = await deriveSignal(code, key);
    clients = BROKERS.map((url) => mqttClient(url, k.topic, async (payload) => {
      const m = await unseal(k, payload);
      if (m) for (const fn of [...listeners]) fn(m);
    })).filter(Boolean);
    // Ready when the first broker has subscribed; the others join as they come.
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(NO_BROKER)), 8000);
      const done = () => { clearTimeout(t); resolve(); };
      for (const c of clients) c.onready = done;
    });
    let order = Promise.resolve(); // messages leave in the order they were sent: the offer before its candidates
    return {
      send(obj) {
        order = order.then(async () => {
          const bytes = await seal(k, obj);
          for (const c of clients) c.publish(bytes);
        }).catch(() => {});
        return order;
      },
      on(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    };
  })();
  entry.promise.catch(() => { if (sigCache === entry) { entry.close(); sigCache = null; } });
  sigCache = entry;
  return entry.promise;
}

// Resolves when ICE gathering is complete, or soon after the first public candidate, or after max_ms.
function gathered(pc, max_ms) {
  return new Promise((resolve) => {
    let soon = 0;
    const done = () => {
      clearTimeout(cap);
      clearTimeout(soon);
      pc.removeEventListener('icegatheringstatechange', onState);
      pc.removeEventListener('icecandidate', onCand);
      resolve();
    };
    const onState = () => pc.iceGatheringState === 'complete' && done();
    const onCand = (e) => { if (e.candidate && / typ srflx /.test(e.candidate.candidate) && !soon) soon = setTimeout(done, 300); };
    const cap = setTimeout(done, max_ms);
    pc.addEventListener('icegatheringstatechange', onState);
    pc.addEventListener('icecandidate', onCand);
    onState();
  });
}

function rtcLink(code, key, h) {
  let pc = null, dc = null, off = null, timer = 0, ended = false;
  let parts = [];
  const id = randomHex(8);
  const end = () => {
    ended = true;
    clearTimeout(timer);
    if (off) off();
    if (dc) { dc.onclose = null; dc.onmessage = null; try { dc.close(); } catch (_) {} }
    if (pc) { pc.onconnectionstatechange = null; try { pc.close(); } catch (_) {} }
  };
  const fail = (why, fatal) => { if (ended) return; end(); h.close(why, fatal); };

  (async () => {
    progress(host ? 'Reconnecting…' : 'Looking for the computer…');
    // The brokers connect while the browser gathers its candidates.
    const sigReady = signaling(code, key);
    sigReady.catch(() => {});
    pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
    dc = pc.createDataChannel('rdc', { negotiated: true, id: 0, ordered: true });
    dc.binaryType = 'arraybuffer';
    dc.onopen = () => { clearTimeout(timer); h.open(); };
    dc.onclose = () => fail('', false);
    dc.onmessage = (ev) => {
      if (typeof ev.data === 'string') return h.message(ev.data);
      // Binary messages from the host come in pieces: [1] — more follow, [0] — the last one.
      const b = new Uint8Array(ev.data);
      if (b.length === 0) return;
      parts.push(b.subarray(1));
      if (b[0] === 1) return;
      const n = parts.reduce((s, p) => s + p.length, 0);
      const msg = new Uint8Array(n);
      let o = 0;
      for (const p of parts) { msg.set(p, o); o += p.length; }
      parts = [];
      h.message(msg.buffer);
    };
    pc.onconnectionstatechange = () => { if (pc.connectionState === 'failed') fail(NO_PATH, true); };
    let offered = false;
    let sig = null;
    pc.addEventListener('icecandidate', (e) => {
      if (offered && e.candidate && e.candidate.candidate) sig.send({ t: 'cand', id, ts: Date.now(), c: e.candidate.candidate });
    });
    await pc.setLocalDescription(await pc.createOffer());
    await gathered(pc, 2000);
    sig = await sigReady;
    if (ended) return;
    let answered = false;
    off = sig.on(async (m) => {
      if (m.id !== id || ended) return;
      // The host's replies carry our offer's timestamp: an older one is a recording played back.
      if (typeof m.ts !== 'number' || Math.abs(Date.now() - m.ts) > MAX_AGE_MS) return;
      if (m.t === 'err') return fail(m.msg || NO_ANSWER, true);
      if (m.t !== 'answer' || answered) return;
      answered = true;
      clearTimeout(timer);
      progress(host ? 'Reconnecting…' : 'Connecting directly…');
      try { await pc.setRemoteDescription({ type: 'answer', sdp: m.sdp }); } catch (e) { return fail(String(e.message || e), true); }
      timer = setTimeout(() => fail(NO_PATH, true), 15000);
    });
    offered = true; // candidates found from now on follow the offer
    await sig.send({ t: 'offer', id, ts: Date.now(), sdp: pc.localDescription.sdp });
    timer = setTimeout(() => fail(NO_ANSWER, true), 10000);
  })().catch((e) => fail(String((e && e.message) || e), true));

  return {
    send(d) { if (dc && dc.readyState === 'open') dc.send(d); },
    buffered() { return dc ? dc.bufferedAmount : 0; },
    close() { if (!ended) end(); },
  };
}

function onControl(m) {
  switch (m.t) {
    case 'ok':
      host = m;
      otp = '';
      if (perm && m.resume) saveResume(m.resume);
      $('join').style.display = 'none';
      $('stage').style.display = 'flex';
      $('veil').style.display = 'none';
      $('who').textContent = m.name || 'RDC';
      // Ctrl and ⌘ swap places when the modifier layout differs: PC to Mac and Mac to PC.
      swapCtrl = m.os === 'macos' ? !localIsMac : localIsMac;
      $('swap').style.display = swapCtrl ? '' : 'none';
      $('swap').textContent = m.os === 'macos' ? 'Ctrl → ⌘' : '⌘ → Ctrl';
      $('swap').title = m.os === 'macos' ? 'Ctrl on this computer acts as ⌘ on the Mac'
                                         : '⌘ on this Mac acts as Ctrl on the computer';
      $('swap').classList.toggle('on', swapCtrl);
      setSize(m.w, m.h);
      tp.lastLocal = 0;
      syncCursor(m);
      document.body.classList.add('live');
      osk.setOS(m.os);
      media.setHost(m);
      canvas.focus();
      break;
    case 'media':
      media.onHost(m);
      break;
    case 'size':
      setSize(m.w, m.h);
      break;
    case 'pong':
      stats.rtt = performance.now() - m.ts;
      syncCursor(m);
      break;
    case 'err':
      if (m.fatal) {
        closeConn();
        host = null;
        if (perm) saveResume(''); // whatever let this tab in no longer does
        showJoin(m.msg);
        break;
      }
      $('veil').textContent = m.msg;
      $('veil').style.display = 'flex';
      gotFrame = false;
      break;
    case 'bye':
      closeConn();
      host = null;
      if (perm) saveResume('');
      showJoin(m.msg || 'The host ended the session');
      break;
    case 'viewers': {
      // An AI agent is connected: say so, and offer to stop it.
      const ai = m.ai || [];
      $('ai-who').textContent = ai.length === 1 ? `AI agent ${ai[0]} is controlling this computer`
                                                 : `${ai.length} AI agents are controlling this computer`;
      $('ai').style.display = ai.length ? 'flex' : 'none';
      break;
    }
  }
}

$('ai-stop').onclick = () => { send(JSON.stringify({ t: 'stop_ai' })); $('ai').style.display = 'none'; };

// ---------------------------------------------------------------- picture

function setSize(w, h) {
  if (w && h && (canvas.width !== w || canvas.height !== h)) { canvas.width = w; canvas.height = h; }
  fit();
}

function fit() {
  if (!canvas.width) return;
  const stage = $('stage');
  const vw = stage.clientWidth || window.innerWidth, vh = stage.clientHeight || window.innerHeight;
  const s = Math.min(vw / canvas.width, vh / canvas.height);
  canvas.style.width = Math.floor(canvas.width * s) + 'px';
  canvas.style.height = Math.floor(canvas.height * s) + 'px';
}

let gotFrame = false;

function draw(img, w, h) {
  if (canvas.width !== w || canvas.height !== h) setSize(w, h);
  ctx2d.drawImage(img, 0, 0);
  stats.frames++;
  if (!gotFrame) { gotFrame = true; $('veil').style.display = 'none'; $('veil').textContent = 'Reconnecting…'; }
}

function onFrame(buf) {
  stats.bytes += buf.byteLength;
  if (buf.byteLength < 10) return;
  const dv = new DataView(buf);
  const kind = dv.getUint8(0);
  const key = (dv.getUint8(1) & 1) !== 0;
  const ts = Number(dv.getBigUint64(2, true));
  const data = new Uint8Array(buf, 10);
  if (kind === FRAME.H264) decodeH264(data, key, ts);
  else if (kind === FRAME.JPEG) drawJpeg(data);
}

function avcCodec(data) {
  for (let i = 0; i + 7 < data.length; i++) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1 && (data[i + 3] & 0x1f) === 7) {
      const hex = (b) => b.toString(16).padStart(2, '0');
      return 'avc1.' + hex(data[i + 4]) + hex(data[i + 5]) + hex(data[i + 6]);
    }
  }
  return 'avc1.640028';
}

function resetDecoder() {
  if (decoder && decoder.state !== 'closed') { try { decoder.close(); } catch (_) {} }
  decoder = null;
  configured = false;
  waitKey = true;
}

function decodeH264(data, key, ts) {
  if (!decoder) {
    decoder = new VideoDecoder({
      output: (frame) => { draw(frame, frame.displayWidth, frame.displayHeight); frame.close(); decodeErrors = 0; },
      error: (e) => {
        console.warn('decoder', e);
        resetDecoder();
        if (++decodeErrors >= 3) { forceJpeg = true; connect(); } else send(new Uint8Array([MSG.KEYFRAME]));
      },
    });
  }
  if (!configured) {
    if (!key) return send(new Uint8Array([MSG.KEYFRAME]));
    // 'prefer-hardware' in Chrome means "hardware only" and fails where there is none;
    // 'no-preference' picks the hardware decoder on its own when it is available.
    decoder.configure({ codec: avcCodec(data), optimizeForLatency: true, hardwareAcceleration: 'no-preference' });
    configured = true;
  }
  if (waitKey && !key) return;
  if (decoder.decodeQueueSize > 4) {
    // Falling behind: drop until the next keyframe instead of piling up latency.
    waitKey = true;
    return send(new Uint8Array([MSG.KEYFRAME]));
  }
  waitKey = false;
  decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: ts, data }));
}

async function drawJpeg(data) {
  if (jpegBusy) { jpegNext = data; return; }
  jpegBusy = true;
  try {
    const bmp = await createImageBitmap(new Blob([data], { type: 'image/jpeg' }));
    draw(bmp, bmp.width, bmp.height);
    bmp.close();
  } catch (e) { console.warn('jpeg', e); }
  jpegBusy = false;
  if (jpegNext) { const next = jpegNext; jpegNext = null; drawJpeg(next); }
}

// ---------------------------------------------------------------- input

let movePending = null;
let wheelX = 0, wheelY = 0;

function norm(e) {
  const r = canvas.getBoundingClientRect();
  return [(e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height];
}

function sendMove(x, y) {
  const b = new DataView(new ArrayBuffer(9));
  b.setUint8(0, MSG.MOVE); b.setFloat32(1, x, true); b.setFloat32(5, y, true);
  send(b.buffer);
}

function sendButton(btn, down, x, y) {
  const b = new DataView(new ArrayBuffer(11));
  b.setUint8(0, MSG.BUTTON); b.setUint8(1, btn); b.setUint8(2, down ? 1 : 0);
  b.setFloat32(3, x, true); b.setFloat32(7, y, true);
  send(b.buffer);
}

function sendKey(usage, down) {
  const b = new DataView(new ArrayBuffer(4));
  b.setUint8(0, MSG.KEY); b.setUint16(1, usage, true); b.setUint8(3, down ? 1 : 0);
  send(b.buffer);
}

function releaseAll() {
  pressed.clear();
  osk.reset();
  send(new Uint8Array([MSG.RELEASE_ALL]));
}

function tick() {
  if (movePending) { sendMove(movePending[0], movePending[1]); movePending = null; }
  if (wheelX || wheelY) {
    const b = new DataView(new ArrayBuffer(9));
    b.setUint8(0, MSG.WHEEL); b.setFloat32(1, wheelX, true); b.setFloat32(5, wheelY, true);
    send(b.buffer);
    wheelX = wheelY = 0;
  }
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);

const buttonOf = (e) => (e.button === 2 ? 2 : e.button === 1 ? 1 : 0);

// ---------------------------------------------------------------- touch: touchpad mode
// The cursor stays put and moves with the finger, like on a laptop touchpad.
// Tap — left click at the cursor; double tap — right click; two fingers — scroll.
const TAP_MS = 300;          // longer is not a tap
const TAP_SLOP = 10;         // CSS pixels: farther is a move
const DOUBLE_TAP_MS = 250;   // window for the second tap
const tp = { x: 0.5, y: 0.5, lastLocal: 0, touches: new Map(), mode: 'none', start: null, moved: false, pendingTap: false, tapTimer: 0, scrollAt: null };

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);

function click(btn) {
  sendMove(tp.x, tp.y);
  sendButton(btn, true, tp.x, tp.y);
  sendButton(btn, false, tp.x, tp.y);
}

function flushPendingTap() {
  if (!tp.pendingTap) return;
  clearTimeout(tp.tapTimer);
  tp.pendingTap = false;
  click(0);
}

function centroid() {
  let x = 0, y = 0;
  for (const p of tp.touches.values()) { x += p.x; y += p.y; }
  const n = tp.touches.size || 1;
  return [x / n, y / n];
}

function touchDown(e) {
  tp.touches.set(e.pointerId, { x: e.clientX, y: e.clientY, t: e.timeStamp });
  if (tp.touches.size === 1) {
    tp.mode = 'move';
    tp.start = { x: e.clientX, y: e.clientY, t: e.timeStamp };
    tp.moved = false;
  } else if (tp.touches.size === 2) {
    flushPendingTap();
    tp.mode = 'scroll';
    tp.scrollAt = centroid();
  }
}

function touchMove(e) {
  const p = tp.touches.get(e.pointerId);
  if (!p) return;
  const dx = e.clientX - p.x, dy = e.clientY - p.y;
  const dt = Math.max(1, e.timeStamp - p.t);
  p.x = e.clientX; p.y = e.clientY; p.t = e.timeStamp;
  const r = canvas.getBoundingClientRect();
  if (tp.mode === 'move') {
    if (!tp.moved && Math.hypot(e.clientX - tp.start.x, e.clientY - tp.start.y) > TAP_SLOP) {
      tp.moved = true;
      flushPendingTap();
    }
    if (!tp.moved) return;
    // Slow is more precise, fast goes farther: like pointer acceleration on a touchpad.
    const speed = Math.hypot(dx, dy) / dt;
    const gain = Math.min(2.6, Math.max(0.6, 0.6 + speed * 1.2));
    tp.x = clamp01(tp.x + (dx * gain) / r.width);
    tp.y = clamp01(tp.y + (dy * gain) / r.height);
    tp.lastLocal = performance.now();
    movePending = [tp.x, tp.y];
  } else if (tp.mode === 'scroll') {
    const [cx, cy] = centroid();
    const k = canvas.width / r.width; // into remote screen pixels
    wheelX -= (cx - tp.scrollAt[0]) * k;
    wheelY -= (cy - tp.scrollAt[1]) * k;
    tp.scrollAt = [cx, cy];
  }
}

function touchUp(e) {
  if (!tp.touches.delete(e.pointerId)) return;
  if (tp.touches.size > 0) {
    if (tp.mode === 'scroll') tp.mode = 'none'; // the remaining finger doesn't move the cursor
    return;
  }
  const wasTap = tp.mode === 'move' && !tp.moved && e.timeStamp - tp.start.t < TAP_MS;
  tp.mode = 'none';
  if (!wasTap) return;
  if (tp.pendingTap) {
    clearTimeout(tp.tapTimer);
    tp.pendingTap = false;
    click(2); // double tap — right button
  } else {
    tp.pendingTap = true;
    tp.tapTimer = setTimeout(() => { tp.pendingTap = false; click(0); }, DOUBLE_TAP_MS);
  }
}

function syncCursor(m) {
  // The host cursor may have moved on its own — pick it up while no finger is on the screen.
  if (typeof m.cx !== 'number' || tp.touches.size > 0 || performance.now() - tp.lastLocal < 1000) return;
  tp.x = clamp01(m.cx);
  tp.y = clamp01(m.cy);
}

// A finger is a touchpad, so it works on the whole page, the bars around the picture included;
// the mouse acts only over the picture, where its place has a meaning. The toolbar, its handle
// and the AI banner keep their own taps.
const stage = $('stage');
const onUi = (e) => !!(e.target.closest && e.target.closest('#bar, #handle, #ai, #media'));
stage.addEventListener('pointermove', (e) => {
  if (e.pointerType === 'touch') return touchMove(e);
  if (e.target !== canvas) return;
  movePending = norm(e);
});
stage.addEventListener('pointerdown', (e) => {
  if (onUi(e)) return;
  if (e.pointerType !== 'touch' && e.target !== canvas) return;
  e.preventDefault();
  canvas.focus();
  try { canvas.setPointerCapture(e.pointerId); } catch (_) {} // later events of this pointer target the picture
  if (e.pointerType === 'touch') return touchDown(e);
  const [x, y] = norm(e);
  movePending = null;
  sendMove(x, y);
  sendButton(buttonOf(e), true, x, y);
});
stage.addEventListener('pointerup', (e) => {
  if (e.pointerType === 'touch') return touchUp(e);
  if (e.target !== canvas) return;
  e.preventDefault();
  const [x, y] = norm(e);
  sendButton(buttonOf(e), false, x, y);
});
stage.addEventListener('pointercancel', (e) => {
  if (e.pointerType !== 'touch') return;
  tp.touches.delete(e.pointerId);
  if (tp.touches.size === 0) tp.mode = 'none';
});
stage.addEventListener('contextmenu', (e) => e.preventDefault());
stage.addEventListener('wheel', (e) => {
  e.preventDefault();
  const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
  wheelX += e.deltaX * k;
  wheelY += e.deltaY * k;
}, { passive: false });

function mapKey(e) {
  let u = HID[e.code];
  if (u === undefined) return undefined;
  if (swapCtrl) {
    if (u === 0xe0) u = 0xe3; else if (u === 0xe3) u = 0xe0;
    else if (u === 0xe4) u = 0xe7; else if (u === 0xe7) u = 0xe4;
  }
  return u;
}

window.addEventListener('keydown', (e) => {
  if (!host || $('stage').style.display === 'none') return;
  // Esc on this device's keyboard ends the session; the Esc of the on-screen keyboard is the one
  // that goes to the computer.
  if (e.code === 'Escape') {
    if (e.target.closest && e.target.closest('select, input')) return; // closes a list, nothing more
    e.preventDefault();
    if (!e.repeat) leave();
    return;
  }
  const u = mapKey(e);
  if (u === undefined) return;
  e.preventDefault();
  pressed.add(u);
  sendKey(u, true);
});
window.addEventListener('keyup', (e) => {
  if (!host || $('stage').style.display === 'none') return;
  const u = mapKey(e);
  if (u === undefined) return;
  e.preventDefault();
  pressed.delete(u);
  sendKey(u, false);
});
window.addEventListener('blur', releaseAll);
document.addEventListener('visibilitychange', () => document.hidden && releaseAll());

// ---------------------------------------------------------------- UI

let barTimer = 0;
function showBar() {
  $('bar').classList.add('show');
  clearTimeout(barTimer);
  barTimer = setTimeout(() => $('bar').classList.remove('show'), 2500);
}
window.addEventListener('mousemove', (e) => { if (e.clientY < 48) showBar(); });
$('bar').addEventListener('mouseenter', () => { $('bar').classList.add('show'); clearTimeout(barTimer); });
$('bar').addEventListener('mouseleave', showBar);
// On a phone the toolbar opens and closes with the corner button.
$('handle').addEventListener('click', () => { clearTimeout(barTimer); $('bar').classList.toggle('show'); });

$('swap').addEventListener('click', () => { swapCtrl = !swapCtrl; $('swap').classList.toggle('on', swapCtrl); releaseAll(); canvas.focus(); });
$('kbd').addEventListener('click', () => osk.toggle());
$('full').addEventListener('click', async () => {
  if (document.fullscreenElement) { await document.exitFullscreen(); return; }
  await document.documentElement.requestFullscreen().catch(() => {});
  if (navigator.keyboard && navigator.keyboard.lock) navigator.keyboard.lock().catch(() => {});
  canvas.focus();
});
// Ends the session from this side: held keys are released on the computer, the picture and this
// device's microphone and camera stop, the connection closes.
function leave() {
  releaseAll();
  wantConnected = false;
  host = null;
  closeConn();
  resetDecoder();
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  showJoin('');
}
$('leave').addEventListener('click', leave);
document.addEventListener('fullscreenchange', () => {
  $('full').textContent = document.fullscreenElement ? 'Exit full screen' : 'Full screen';
  fit();
});
window.addEventListener('resize', fit);

setInterval(() => {
  const now = performance.now();
  const dt = (now - stats.t0) / 1000;
  const fps = Math.round(stats.frames / dt);
  const mbps = (stats.bytes * 8 / dt / 1e6).toFixed(1);
  stats.frames = 0; stats.bytes = 0; stats.t0 = now;
  const codec = host ? (host.codec === 'h264' ? 'H.264' : 'JPEG') : '';
  const via = key ? ' · WebRTC' : '';
  $('stat').textContent = host ? `${codec} · ${fps} fps · ${mbps} Mbps · ${Math.round(stats.rtt)} ms${via}` : '';
  send(JSON.stringify({ t: 'ping', ts: now }));
}, 1000);

// ---------------------------------------------------------------- on-screen keyboard
// Sends the same HID codes as a physical keyboard. Layout and shortcuts follow the host OS.
// Modifier: tap — for one keypress, double tap — lock, another tap — release.
const osk = (() => {
  const el = $('osk'), keysEl = $('osk-keys'), cutsEl = $('osk-cuts'), head = $('osk-head');
  const sizeEl = $('osk-size'), kbtn = $('kbtn'), bubble = $('osk-bubble');
  const MOD = { ctrl: 0xe0, shift: 0xe1, alt: 0xe2, meta: 0xe3 };
  const STORE = 'rdc.osk.v1';
  const WIDE = 620; // wider gets the full layout

  const RU = {
    KeyQ: 'й', KeyW: 'ц', KeyE: 'у', KeyR: 'к', KeyT: 'е', KeyY: 'н', KeyU: 'г', KeyI: 'ш', KeyO: 'щ', KeyP: 'з',
    BracketLeft: 'х', BracketRight: 'ъ', KeyA: 'ф', KeyS: 'ы', KeyD: 'в', KeyF: 'а', KeyG: 'п', KeyH: 'р',
    KeyJ: 'о', KeyK: 'л', KeyL: 'д', Semicolon: 'ж', Quote: 'э', KeyZ: 'я', KeyX: 'ч', KeyC: 'с', KeyV: 'м',
    KeyB: 'и', KeyN: 'т', KeyM: 'ь', Comma: 'б', Period: 'ю', Backquote: 'ё',
  };
  const PLAIN = { Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']', Backslash: '\\', Semicolon: ';', Quote: "'", Backquote: '`', Comma: ',', Period: '.', Slash: '/' };
  const SHIFTED = {
    Digit1: '!', Digit2: '@', Digit3: '#', Digit4: '$', Digit5: '%', Digit6: '^', Digit7: '&', Digit8: '*', Digit9: '(', Digit0: ')',
    Minus: '_', Equal: '+', BracketLeft: '{', BracketRight: '}', Backslash: '|', Semicolon: ':', Quote: '"', Backquote: '~', Comma: '<', Period: '>', Slash: '?',
  };
  const NAMES = {
    Escape: 'Esc', Tab: 'Tab ⇥', Backspace: '⌫', Enter: '⏎', Space: '', Delete: 'Del', Insert: 'Ins', Home: 'Home', End: 'End',
    PageUp: 'PgUp', PageDown: 'PgDn', ArrowLeft: '←', ArrowRight: '→', ArrowUp: '↑', ArrowDown: '↓',
  };
  const OS = {
    macos: {
      title: 'macOS', label: { ctrl: '⌃', alt: '⌥', meta: '⌘', shift: '⇧' }, sub: { ctrl: 'control', alt: 'option', meta: 'command' },
      left: ['ctrl', 'alt', 'meta'], right: ['meta', 'alt'], lang: ['ctrl', 'Space'],
      cuts: [
        ['⌘C', 'Copy', ['meta'], 'KeyC'], ['⌘V', 'Paste', ['meta'], 'KeyV'], ['⌘X', 'Cut', ['meta'], 'KeyX'],
        ['⌘Z', 'Undo', ['meta'], 'KeyZ'], ['⇧⌘Z', 'Redo', ['shift', 'meta'], 'KeyZ'], ['⌘A', 'Select all', ['meta'], 'KeyA'],
        ['⌘F', 'Find', ['meta'], 'KeyF'], ['⌘S', 'Save', ['meta'], 'KeyS'], ['⌘Tab', 'Apps', ['meta'], 'Tab'],
        ['⌘Space', 'Spotlight', ['meta'], 'Space'], ['⌃↑', 'Mission Control', ['ctrl'], 'ArrowUp'], ['⌘W', 'Close', ['meta'], 'KeyW'],
        ['⌘Q', 'Quit', ['meta'], 'KeyQ'], ['⇧⌘4', 'Screenshot', ['shift', 'meta'], 'Digit4'],
      ],
    },
    windows: {
      title: 'Windows', label: { ctrl: 'Ctrl', alt: 'Alt', meta: '⊞', shift: '⇧' }, sub: {},
      left: ['ctrl', 'meta', 'alt'], right: ['alt', 'ctrl'], lang: ['meta', 'Space'],
      cuts: [
        ['Ctrl+C', 'Copy', ['ctrl'], 'KeyC'], ['Ctrl+V', 'Paste', ['ctrl'], 'KeyV'], ['Ctrl+X', 'Cut', ['ctrl'], 'KeyX'],
        ['Ctrl+Z', 'Undo', ['ctrl'], 'KeyZ'], ['Ctrl+Y', 'Redo', ['ctrl'], 'KeyY'], ['Ctrl+A', 'Select all', ['ctrl'], 'KeyA'],
        ['Ctrl+F', 'Find', ['ctrl'], 'KeyF'], ['Ctrl+S', 'Save', ['ctrl'], 'KeyS'], ['Alt+Tab', 'Windows', ['alt'], 'Tab'],
        ['⊞', 'Start', [], 'MetaLeft'], ['⊞+D', 'Desktop', ['meta'], 'KeyD'], ['⊞+E', 'Explorer', ['meta'], 'KeyE'],
        ['Alt+F4', 'Close', ['alt'], 'F4'], ['Ctrl+Shift+Esc', 'Task Manager', ['ctrl', 'shift'], 'Escape'],
      ],
    },
    linux: {
      title: 'Linux', label: { ctrl: 'Ctrl', alt: 'Alt', meta: '❖', shift: '⇧' }, sub: {},
      left: ['ctrl', 'meta', 'alt'], right: ['alt', 'ctrl'], lang: ['meta', 'Space'],
      cuts: [
        ['Ctrl+C', 'Copy', ['ctrl'], 'KeyC'], ['Ctrl+V', 'Paste', ['ctrl'], 'KeyV'], ['Ctrl+X', 'Cut', ['ctrl'], 'KeyX'],
        ['Ctrl+Z', 'Undo', ['ctrl'], 'KeyZ'], ['Ctrl+A', 'Select all', ['ctrl'], 'KeyA'], ['Ctrl+F', 'Find', ['ctrl'], 'KeyF'],
        ['Ctrl+S', 'Save', ['ctrl'], 'KeyS'], ['Alt+Tab', 'Windows', ['alt'], 'Tab'], ['❖', 'Overview', [], 'MetaLeft'],
        ['Alt+F4', 'Close', ['alt'], 'F4'], ['Ctrl+Alt+T', 'Terminal', ['ctrl', 'alt'], 'KeyT'],
      ],
    },
  };

  let os = OS.macos;
  let page = 'abc';
  const mods = { ctrl: 0, shift: 0, alt: 0, meta: 0 }; // 0 off, 1 for one keypress, 2 locked
  const lastModTap = {};
  const presses = new Map(); // pointerId → press
  let rendered = '';

  const st = load();

  function load() {
    // ru: the Cyrillic letters are the big labels and the Latin ones the small — for a computer
    // whose layout is Russian right now.
    const d = { visible: false, docked: window.innerWidth < 700, ghost: false, ru: false, w: Math.min(window.innerWidth - 16, 760), x: 8, y: 80 };
    try { return Object.assign(d, JSON.parse(localStorage.getItem(STORE) || '{}')); } catch (_) { return d; }
  }
  function save() { try { localStorage.setItem(STORE, JSON.stringify(st)); } catch (_) {} }
  const vibrate = () => { try { navigator.vibrate && navigator.vibrate(8); } catch (_) {} };

  // --- key definitions
  const k = (code, w = 1) => ({ code, w });
  const sp = (w) => ({ spacer: true, w });
  const mod = (m, w = 1) => ({ mod: m, w });
  const pg = (to, label, w) => ({ page: to, label, w });
  const lang = (w = 1) => ({ lang: true, w });
  const row = (codes) => codes.split(' ').map((c) => k(c));
  const letters = (s) => s.split('').map((c) => k('Key' + c.toUpperCase()));

  function bottomRow(other) {
    return [pg(other, other === 'abc' ? 'abc' : '123', 1.3), pg('fn', 'Fn', 1), lang(1), ...os.left.map((m) => mod(m, 1)), k('Space', 3.2), k('Enter', 1.5)];
  }

  function compact() {
    if (page === '123') return [
      row('Digit1 Digit2 Digit3 Digit4 Digit5 Digit6 Digit7 Digit8 Digit9 Digit0'),
      row('Minus Equal BracketLeft BracketRight Backslash Semicolon Quote Backquote'),
      [mod('shift', 1.5), k('Comma'), k('Period'), k('Slash'), k('Tab', 1.3), k('Escape', 1.2), k('Backspace', 1.5)],
      bottomRow('abc'),
    ];
    if (page === 'fn') return [
      row('Escape F1 F2 F3 F4 F5 F6'),
      row('Tab F7 F8 F9 F10 F11 F12'),
      row('Insert Home PageUp Delete End PageDown'),
      [pg('abc', 'abc', 1.4), k('ArrowLeft'), k('ArrowUp'), k('ArrowDown'), k('ArrowRight'), k('Backspace', 1.4), k('Enter', 1.4)],
    ];
    return [
      letters('qwertyuiop'),
      [sp(0.5), ...letters('asdfghjkl'), sp(0.5)],
      [mod('shift', 1.5), ...letters('zxcvbnm'), k('Backspace', 1.5)],
      bottomRow('123'),
    ];
  }

  function full() {
    return [
      row('Escape F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 Delete').map((x) => ({ ...x, small: true })),
      [...row('Backquote Digit1 Digit2 Digit3 Digit4 Digit5 Digit6 Digit7 Digit8 Digit9 Digit0 Minus Equal'), k('Backspace', 2)],
      [k('Tab', 1.5), ...letters('qwertyuiop'), k('BracketLeft'), k('BracketRight'), k('Backslash', 1.5)],
      [lang(1.75), ...letters('asdfghjkl'), k('Semicolon'), k('Quote'), k('Enter', 2.25)],
      [mod('shift', 2.25), ...letters('zxcvbnm'), k('Comma'), k('Period'), k('Slash'), mod('shift', 1.75), k('ArrowUp')],
      [...os.left.map((m) => mod(m, m === 'meta' ? 1.5 : 1.25)), k('Space', 5.2), ...os.right.map((m) => mod(m, m === 'meta' ? 1.5 : 1.25)), k('ArrowLeft'), k('ArrowDown'), k('ArrowRight')],
    ];
  }

  // --- labels
  const shiftOn = () => mods.shift > 0;
  /// The Latin label of a key that also has a Cyrillic letter, without Shift.
  const latin = (code) => (code.startsWith('Key') ? code.slice(3).toLowerCase() : PLAIN[code]);
  function label(code) {
    if (st.ru && RU[code]) return shiftOn() ? RU[code].toUpperCase() : RU[code];
    if (code.startsWith('Key')) return shiftOn() ? code.slice(3) : code.slice(3).toLowerCase();
    if (code.startsWith('Digit')) return shiftOn() ? SHIFTED[code] : code.slice(5);
    if (PLAIN[code]) return shiftOn() ? SHIFTED[code] : PLAIN[code];
    if (/^F\d+$/.test(code)) return code;
    return NAMES[code] ?? code;
  }

  function keyEl(spec) {
    const b = document.createElement('button');
    b.className = 'osk-key';
    b.style.flexGrow = spec.w || 1;
    b.tabIndex = -1;
    if (spec.spacer) { b.classList.add('sp'); return b; }
    if (spec.mod) {
      b.dataset.mod = spec.mod;
      b.classList.add('fn');
      b.innerHTML = '';
      b.append(os.label[spec.mod]);
      if (os.sub[spec.mod] && (spec.w || 1) >= 1.25) { const s = document.createElement('small'); s.textContent = os.sub[spec.mod]; b.append(s); }
      return b;
    }
    if (spec.page) { b.dataset.page = spec.page; b.classList.add('fn'); b.textContent = spec.label; return b; }
    if (spec.lang) { b.dataset.lang = '1'; b.classList.add('fn'); b.textContent = '🌐'; b.title = 'Switch language on the computer'; return b; }
    b.dataset.code = spec.code;
    const text = label(spec.code);
    b.textContent = spec.code === 'Space' ? 'space' : text;
    if (spec.code === 'Space') b.style.fontSize = 'calc(var(--u) * .3)';
    if (NAMES[spec.code] !== undefined && spec.code !== 'Space' && !/^Arrow/.test(spec.code) && spec.code !== 'Backspace' && spec.code !== 'Enter') b.classList.add('fn');
    if (spec.small || /^F\d+$/.test(spec.code)) b.classList.add('fn');
    // The other alphabet, small: Cyrillic under Latin labels, Latin under Cyrillic ones.
    const alt = RU[spec.code] && (st.ru ? latin(spec.code) : RU[spec.code]);
    if (alt) { const a = document.createElement('span'); a.className = 'alt'; a.textContent = alt; b.append(a); }
    return b;
  }

  function render(force) {
    if (el.hidden) return;
    const width = el.getBoundingClientRect().width;
    const wide = width >= WIDE;
    const sig = [wide, page, os.title, shiftOn(), st.ru].join('|');
    if (force || sig !== rendered) {
      rendered = sig;
      keysEl.textContent = '';
      let units = 0;
      for (const r of wide ? full() : compact()) {
        const rowEl = document.createElement('div');
        rowEl.className = 'osk-row';
        let u = 0;
        for (const spec of r) { rowEl.append(keyEl(spec)); u += spec.w || 1; }
        units = Math.max(units, u);
        keysEl.append(rowEl);
      }
      el.dataset.units = units;
    }
    const units = +el.dataset.units || 10;
    const inner = Math.min(width, st.docked ? 980 : width) - 16;
    // Width sets the key size, but the keyboard is no taller than a share of the screen: docked —
    // up to 46% of the height, floating — up to 62%.
    const rows = keysEl.children.length || 4;
    const maxHeight = window.innerHeight * (st.docked ? 0.46 : 0.62) - 90;
    let u = inner / (units * 1.12);
    u = Math.min(u, maxHeight / (rows * 1.25 + (rows - 1) * 0.14 + 0.25));
    el.style.setProperty('--u', Math.max(26, Math.min(62, u)) + 'px');
    paintMods();
  }

  function paintMods() {
    for (const b of keysEl.querySelectorAll('[data-mod]')) {
      const s = mods[b.dataset.mod];
      b.classList.toggle('armed', s === 1);
      b.classList.toggle('locked', s === 2);
    }
  }

  function renderCuts() {
    cutsEl.textContent = '';
    for (const [keys, name, ms, code] of os.cuts) {
      const b = document.createElement('button');
      b.tabIndex = -1;
      const strong = document.createElement('b');
      strong.textContent = keys;
      b.append(strong, name);
      b.addEventListener('click', () => { combo(ms, code); canvas.focus(); });
      cutsEl.append(b);
    }
  }

  // --- sending
  function combo(ms, code) {
    for (const m of ms) sendKey(MOD[m], true);
    sendKey(HID[code], true);
    sendKey(HID[code], false);
    for (const m of [...ms].reverse()) sendKey(MOD[m], false);
    vibrate();
  }

  function tapMod(m) {
    const now = performance.now();
    if (mods[m] === 2) { mods[m] = 0; sendKey(MOD[m], false); }
    else if (mods[m] === 1 && now - (lastModTap[m] || 0) < 380) { mods[m] = 2; sendKey(MOD[m], true); }
    else mods[m] = mods[m] === 1 ? 0 : 1;
    lastModTap[m] = now;
    vibrate();
    render();
  }

  function showBubble(b, text) {
    if (!text || text.length > 2 || !matchMedia('(pointer: coarse)').matches) return;
    const r = b.getBoundingClientRect();
    bubble.textContent = text;
    bubble.style.display = 'block';
    bubble.style.left = Math.round(r.left + r.width / 2 - bubble.offsetWidth / 2) + 'px';
    bubble.style.top = Math.round(r.top - 60) + 'px';
  }

  function press(b, id) {
    if (b.dataset.mod) return tapMod(b.dataset.mod);
    if (b.dataset.page) { page = b.dataset.page; vibrate(); return render(); }
    if (b.dataset.lang) {
      // The computer switches its layout; the labels follow (most computers have exactly two).
      // The EN/RU button in the header corrects them when they get out of step.
      const [m, code] = os.lang;
      st.ru = !st.ru;
      save();
      apply();
      return combo([m], code);
    }
    const code = b.dataset.code;
    if (!code || HID[code] === undefined) return;
    const usage = HID[code];
    const armed = Object.keys(mods).filter((m) => mods[m] === 1);
    for (const m of armed) sendKey(MOD[m], true);
    sendKey(usage, true);
    b.classList.add('down');
    vibrate();
    showBubble(b, b.firstChild && b.firstChild.nodeType === 3 ? b.firstChild.textContent : '');
    const p = { b, usage, armed, timer: 0, repeat: 0 };
    p.timer = setTimeout(() => { p.repeat = setInterval(() => sendKey(usage, true), 55); }, 450);
    presses.set(id, p);
  }

  function release(id) {
    const p = presses.get(id);
    if (!p) return;
    presses.delete(id);
    clearTimeout(p.timer);
    clearInterval(p.repeat);
    sendKey(p.usage, false);
    for (const m of [...p.armed].reverse()) sendKey(MOD[m], false);
    p.b.classList.remove('down');
    bubble.style.display = 'none';
    let changed = false;
    for (const m of p.armed) if (mods[m] === 1) { mods[m] = 0; changed = true; }
    if (changed) render();
  }

  keysEl.addEventListener('pointerdown', (e) => {
    const b = e.target.closest('.osk-key');
    if (!b || b.classList.contains('sp')) return;
    e.preventDefault();
    try { b.setPointerCapture(e.pointerId); } catch (_) {}
    press(b, e.pointerId);
  });
  keysEl.addEventListener('pointerup', (e) => release(e.pointerId));
  keysEl.addEventListener('pointercancel', (e) => release(e.pointerId));
  keysEl.addEventListener('contextmenu', (e) => e.preventDefault());

  // --- keyboard window: visibility, position, size, docking
  function clamp() {
    const r = el.getBoundingClientRect();
    st.w = Math.max(300, Math.min(st.w, window.innerWidth - 8));
    st.x = Math.max(4, Math.min(st.x, window.innerWidth - r.width - 4));
    st.y = Math.max(4, Math.min(st.y, window.innerHeight - r.height - 4));
  }

  function apply() {
    el.hidden = !st.visible;
    kbtn.classList.toggle('hidden', st.visible);
    $('kbd').classList.toggle('on', st.visible);
    el.classList.toggle('docked', st.docked);
    el.classList.toggle('ghost', st.ghost);
    head.querySelector('[data-act="dock"]').classList.toggle('on', st.docked);
    head.querySelector('[data-act="ghost"]').classList.toggle('on', st.ghost);
    const langBtn = head.querySelector('[data-act="lang"]');
    langBtn.textContent = st.ru ? 'RU' : 'EN';
    langBtn.classList.toggle('on', st.ru);
    if (!st.docked) el.style.width = Math.max(300, Math.min(st.w, window.innerWidth - 8)) + 'px';
    render();
    if (!st.docked) {
      clamp();
      el.style.left = st.x + 'px';
      el.style.top = st.y + 'px';
    }
    // A keyboard docked at the bottom doesn't cover the picture: the screen shrinks above it.
    $('stage').style.bottom = st.visible && st.docked ? el.getBoundingClientRect().height + 'px' : '0px';
    fit();
  }

  function setVisible(v) {
    st.visible = v;
    if (!v) reset();
    save();
    apply();
  }

  let drag = null;
  let lastHeadTap = 0;
  head.addEventListener('pointerdown', (e) => {
    if (e.target.closest('button')) return;
    e.preventDefault();
    const now = performance.now();
    if (now - lastHeadTap < 320) { st.docked = !st.docked; lastHeadTap = 0; save(); return apply(); }
    lastHeadTap = now;
    try { head.setPointerCapture(e.pointerId); } catch (_) {}
    const r = el.getBoundingClientRect();
    drag = { dx: e.clientX - r.left, dy: e.clientY - r.top, undock: st.docked, moved: false };
  });
  head.addEventListener('pointermove', (e) => {
    if (!drag) return;
    if (drag.undock) {
      // Dragging the docked keyboard undocks it right under the finger.
      st.docked = false;
      st.w = Math.min(st.w, window.innerWidth - 8);
      drag.undock = false;
      apply();
      drag.dx = Math.min(drag.dx, el.getBoundingClientRect().width - 20);
    }
    drag.moved = true;
    st.x = e.clientX - drag.dx;
    st.y = e.clientY - drag.dy;
    clamp();
    el.style.left = st.x + 'px';
    el.style.top = st.y + 'px';
  });
  head.addEventListener('pointerup', () => {
    if (!drag) return;
    const moved = drag.moved;
    drag = null;
    if (moved && window.innerHeight - el.getBoundingClientRect().bottom < 24) st.docked = true; // near the bottom edge — dock
    save();
    apply();
  });
  head.addEventListener('click', (e) => {
    const act = e.target.closest('button')?.dataset.act;
    if (act === 'hide') setVisible(false);
    else if (act === 'dock') { st.docked = !st.docked; save(); apply(); }
    else if (act === 'ghost') { st.ghost = !st.ghost; save(); apply(); }
    else if (act === 'lang') { st.ru = !st.ru; save(); apply(); }
  });

  let resize = null;
  sizeEl.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    e.stopPropagation();
    try { sizeEl.setPointerCapture(e.pointerId); } catch (_) {}
    resize = { x: e.clientX, w: el.getBoundingClientRect().width };
  });
  sizeEl.addEventListener('pointermove', (e) => {
    if (!resize) return;
    st.w = Math.max(300, Math.min(resize.w + (e.clientX - resize.x), window.innerWidth - st.x - 4));
    el.style.width = st.w + 'px';
    render();
  });
  sizeEl.addEventListener('pointerup', () => { if (resize) { resize = null; save(); apply(); } });

  kbtn.addEventListener('click', () => setVisible(true));
  window.addEventListener('resize', () => { if (st.visible) apply(); });

  function reset() {
    for (const id of [...presses.keys()]) release(id);
    for (const m of Object.keys(mods)) {
      if (mods[m] === 2) sendKey(MOD[m], false);
      mods[m] = 0;
    }
    if (!el.hidden) render();
  }

  return {
    setOS(name) {
      os = OS[name] || OS.macos;
      $('osk-title').textContent = 'Keyboard · ' + os.title;
      renderCuts();
      rendered = '';
      apply();
    },
    toggle() { setVisible(!st.visible); },
    reset,
  };
})();

// ---------------------------------------------------------------- camera and microphone
// This device's microphone and camera as capture devices on the computer: "RDC Microphone" and
// "RDC Camera". Audio goes as 20 ms chunks of 16-bit PCM at 48 kHz, video as JPEG frames in pieces
// (src/core/proto.zig). getUserMedia needs a secure page: the link from anywhere, localhost or https.
const media = (() => {
  const panel = $('media'), btn = $('media-btn'), micBox = $('media-mic'), camBox = $('media-cam');
  const micSel = $('media-mic-dev'), camSel = $('media-cam-dev'), note = $('media-note');
  const secure = !!(window.isSecureContext && navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  // Encoding JPEG frames is what warms a phone up, and its cost grows with pixels per second.
  // "Light" (the default) asks the camera itself for a small, slow picture: 12 times less work than HD.
  const CAM_MODES = { light: { w: 640, h: 360, fps: 10, q: 0.6 }, hd: { w: 1280, h: 720, fps: 15, q: 0.7 } };
  const camMode = () => CAM_MODES[$('media-cam-q').value] || CAM_MODES.light;
  const PIECE = 15 * 1024, BACKLOG = 1 << 20;
  let can = { mic: false, camera: false, os: 'macos' }; // what the computer can take, from ok
  let on = { mic: false, camera: false };                // what the computer takes now
  let micStream = null, actx = null, seq = 0;
  let camStream = null, video = null, canvas = null, camTimer = 0, encoding = false;

  // Runs in the audio thread: mono, resampled to 48 kHz, 16-bit, 960 frames (20 ms) per message.
  const WORKLET = `
    class RdcMic extends AudioWorkletProcessor {
      constructor() { super(); this.ratio = sampleRate / 48000; this.t = 0; this.prev = 0; this.buf = new Int16Array(960); this.n = 0; }
      push(v) {
        this.buf[this.n++] = v >= 1 ? 32767 : v <= -1 ? -32768 : (v * 32767) | 0;
        if (this.n === 960) { this.port.postMessage(this.buf.buffer, [this.buf.buffer]); this.buf = new Int16Array(960); this.n = 0; }
      }
      process(inputs) {
        const chans = inputs[0];
        if (!chans || !chans.length) return true;
        let x = chans[0];
        if (chans.length > 1) {
          x = new Float32Array(chans[0].length);
          for (const c of chans) for (let i = 0; i < x.length; i++) x[i] += c[i] / chans.length;
        }
        const n = x.length;
        if (this.ratio === 1) { for (let i = 0; i < n; i++) this.push(x[i]); return true; }
        // Linear interpolation; position -1 is the last sample of the previous block.
        let t = this.t;
        while (t + 1 < n) {
          const i = Math.floor(t), f = t - i;
          const a = i < 0 ? this.prev : x[i], b = x[i + 1];
          this.push(a + (b - a) * f);
          t += this.ratio;
        }
        this.t = t - n;
        this.prev = x[n - 1];
        return true;
      }
    }
    registerProcessor('rdc-mic', RdcMic);`;

  const nowUs = () => BigInt(Math.round(performance.now() * 1000));

  function sendAudio(pcm) {
    if (!conn || conn.buffered() > BACKLOG) return;
    const m = new Uint8Array(12 + pcm.byteLength);
    const dv = new DataView(m.buffer);
    m[0] = MSG.AUDIO;
    m[1] = 1; // 16-bit PCM, 48 kHz, mono
    dv.setUint16(2, seq++ & 0xffff, true);
    dv.setBigUint64(4, nowUs(), true);
    m.set(new Uint8Array(pcm), 12);
    send(m.buffer);
  }

  async function startMic() {
    const audio = { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: { ideal: 1 } };
    if (micSel.value) audio.deviceId = { exact: micSel.value };
    micStream = await navigator.mediaDevices.getUserMedia({ audio });
    const AC = window.AudioContext || window.webkitAudioContext;
    let source = null;
    try {
      actx = new AC({ sampleRate: 48000, latencyHint: 'interactive' });
      source = actx.createMediaStreamSource(micStream);
    } catch (_) {
      // Some browsers refuse a context rate other than the microphone's: the worklet resamples instead.
      if (actx) actx.close().catch(() => {});
      actx = new AC({ latencyHint: 'interactive' });
      source = actx.createMediaStreamSource(micStream);
    }
    await actx.resume();
    const url = URL.createObjectURL(new Blob([WORKLET], { type: 'text/javascript' }));
    try { await actx.audioWorklet.addModule(url); } finally { URL.revokeObjectURL(url); }
    const node = new AudioWorkletNode(actx, 'rdc-mic', { numberOfInputs: 1, numberOfOutputs: 0 });
    node.port.onmessage = (e) => sendAudio(e.data);
    source.connect(node);
    micStream.getAudioTracks()[0].onended = () => { if (on.mic) toggle('mic', false); };
  }

  function stopMic() {
    if (micStream) { for (const t of micStream.getTracks()) t.stop(); micStream = null; }
    if (actx) { actx.close().catch(() => {}); actx = null; }
  }

  async function startCam() {
    const mode = camMode();
    // The camera is asked for this size and rate, so the phone does not capture more than is sent.
    const vid = { width: { ideal: mode.w }, height: { ideal: mode.h }, frameRate: { ideal: mode.fps, max: mode.fps } };
    if (camSel.value) vid.deviceId = { exact: camSel.value }; else vid.facingMode = 'user';
    camStream = await navigator.mediaDevices.getUserMedia({ video: vid });
    video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.setAttribute('playsinline', '');
    video.srcObject = camStream;
    await video.play();
    camStream.getVideoTracks()[0].onended = () => { if (on.camera) toggle('camera', false); };
    camTimer = setInterval(sendFrame, 1000 / mode.fps);
  }

  function stopCam() {
    clearInterval(camTimer);
    camTimer = 0;
    if (video) { video.pause(); video.srcObject = null; video = null; }
    if (camStream) { for (const t of camStream.getTracks()) t.stop(); camStream = null; }
  }

  // One frame: drawn at most 1280 pixels on its long side, encoded as JPEG, sent in pieces.
  async function sendFrame() {
    if (encoding || document.hidden || !video || video.readyState < 2 || !conn || conn.buffered() > BACKLOG) return;
    const mode = camMode();
    const vw = video.videoWidth, vh = video.videoHeight;
    if (!vw || !vh) return;
    encoding = true;
    try {
      const k = Math.min(1, mode.w / Math.max(vw, vh));
      const w = Math.round(vw * k) & ~1, h = Math.round(vh * k) & ~1;
      let blob;
      if (typeof OffscreenCanvas === 'function') {
        if (!canvas || canvas.width !== w || canvas.height !== h) canvas = new OffscreenCanvas(w, h);
        canvas.getContext('2d').drawImage(video, 0, 0, w, h);
        blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: mode.q });
      } else {
        if (!canvas) canvas = document.createElement('canvas');
        if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
        canvas.getContext('2d').drawImage(video, 0, 0, w, h);
        blob = await new Promise((r) => canvas.toBlob(r, 'image/jpeg', mode.q));
      }
      if (!blob || !camStream) return;
      const bytes = new Uint8Array(await blob.arrayBuffer());
      const ts = nowUs();
      let off = 0, first = true;
      do {
        const take = Math.min(PIECE, bytes.length - off);
        const last = off + take >= bytes.length;
        const hdr = first ? 14 : 2;
        const m = new Uint8Array(hdr + take);
        m[0] = MSG.CAMERA;
        m[1] = (first ? 1 : 0) | (last ? 2 : 0);
        if (first) {
          const dv = new DataView(m.buffer);
          dv.setUint16(2, w, true);
          dv.setUint16(4, h, true);
          dv.setBigUint64(6, ts, true);
        }
        m.set(bytes.subarray(off, off + take), hdr);
        send(m.buffer);
        off += take;
        first = false;
      } while (off < bytes.length);
    } catch (e) {
      console.warn('camera', e);
    } finally {
      encoding = false;
    }
  }

  // The capture starts in the tap itself (browsers want getUserMedia there), then the computer is asked.
  async function toggle(kind, want) {
    const box = kind === 'mic' ? micBox : camBox;
    if (want) {
      try {
        await (kind === 'mic' ? startMic() : startCam());
      } catch (e) {
        box.checked = false;
        if (kind === 'mic') stopMic(); else stopCam();
        const denied = e && (e.name === 'NotAllowedError' || e.name === 'SecurityError');
        say(denied ? `The browser did not allow access to the ${kind === 'mic' ? 'microphone' : 'camera'}` : String((e && e.message) || e));
        return;
      }
    } else {
      if (kind === 'mic') stopMic(); else stopCam();
      on[kind] = false;
      paint();
    }
    send(JSON.stringify({ t: 'media', mic: kind === 'mic' ? want : on.mic, camera: kind === 'camera' ? want : on.camera }));
  }

  function paint() {
    const live = on.mic || on.camera;
    btn.classList.toggle('on', live);
    btn.textContent = live ? (on.mic && on.camera ? 'Mic and camera on' : on.mic ? 'Mic on' : 'Camera on') : 'Camera and mic';
  }

  function say(text) { note.textContent = text || ''; }

  // Device names show up once the browser has granted access.
  async function fillDevices() {
    if (!secure || !navigator.mediaDevices.enumerateDevices) return;
    let list = [];
    try { list = await navigator.mediaDevices.enumerateDevices(); } catch (_) { return; }
    for (const [sel, kind, name] of [[micSel, 'audioinput', 'Microphone'], [camSel, 'videoinput', 'Camera']]) {
      const cur = sel.value;
      sel.textContent = '';
      let n = 0;
      for (const d of list) {
        if (d.kind !== kind) continue;
        const o = document.createElement('option');
        o.value = d.deviceId;
        o.textContent = d.label || `${name} ${++n}`;
        sel.append(o);
      }
      if (cur) sel.value = cur;
      sel.hidden = sel.options.length < 2;
    }
  }

  // The computer's answer: what it takes now, and why not.
  function onHost(m) {
    on = { mic: !!m.mic, camera: !!m.camera };
    if (!on.mic && micStream) stopMic();
    if (!on.camera && camStream) stopCam();
    micBox.checked = on.mic;
    camBox.checked = on.camera;
    if (m.msg) say(m.msg);
    else if (on.mic || on.camera) say(`Live: on the computer, pick "RDC ${on.mic ? 'Microphone' : 'Camera'}" in any app`);
    else say('');
    paint();
  }

  // What this computer can take, from the host's ok. After a reconnect the devices that were
  // on stay on: the computer is asked again, and its answer settles the switches.
  function setHost(m) {
    can = { mic: !!m.mic, camera: !!m.camera, os: m.os };
    if (micStream && !can.mic) stopMic();
    if (camStream && !can.camera) stopCam();
    const again = { mic: !!micStream, camera: !!camStream };
    on = { mic: false, camera: false };
    micBox.checked = again.mic;
    camBox.checked = again.camera;
    if (again.mic || again.camera) send(JSON.stringify({ t: 'media', mic: again.mic, camera: again.camera }));
    micBox.disabled = !secure || !can.mic;
    camBox.disabled = !secure || !can.camera;
    const mac = m.os === 'macos';
    if (!secure) say('The camera and microphone work only on a secure page: open the link from anywhere (the second link in the RDC window), or http://localhost on the computer itself');
    else if (!can.mic && !can.camera) say(mac ? 'On the computer, click "Enable phone microphone" in the RDC window first. A phone camera is not available on a Mac.'
                                               : 'On the computer, click "Enable phone camera" in the RDC window first. A phone microphone is not available on Windows.');
    else if (!can.mic) say(mac ? 'Microphone: in the RDC window on the computer, click "Enable phone microphone"' : 'A phone microphone is not available on a Windows computer');
    else if (!can.camera) say(mac ? 'A phone camera is not available on a Mac: it needs a signed camera extension' : 'Camera: in the RDC window on the computer, click "Enable phone camera"');
    else say('');
    paint();
  }

  function stopAll() {
    stopMic();
    stopCam();
    on = { mic: false, camera: false };
    micBox.checked = camBox.checked = false;
    panel.hidden = true;
    paint();
  }

  btn.addEventListener('click', () => { panel.hidden = !panel.hidden; if (!panel.hidden) fillDevices(); });
  micBox.addEventListener('change', () => toggle('mic', micBox.checked));
  camBox.addEventListener('change', () => toggle('camera', camBox.checked));
  micSel.addEventListener('change', () => { if (on.mic) { stopMic(); toggle('mic', true); } });
  camSel.addEventListener('change', () => { if (on.camera) { stopCam(); toggle('camera', true); } });
  $('media-cam-q').addEventListener('change', () => { if (on.camera) { stopCam(); toggle('camera', true); } });
  if (navigator.mediaDevices && navigator.mediaDevices.addEventListener) navigator.mediaDevices.addEventListener('devicechange', fillDevices);
  return { setHost, onHost, stopAll };
})();

// Digits get grouped as they are typed; a pasted link stays as it is.
const formatOtp = (s) => s.replace(/\D/g, '').slice(0, 6).replace(/(\d{3})(?=\d)/, '$1 ');
$('code').addEventListener('input', (e) => {
  if (/^[\d ]*$/.test(e.target.value)) e.target.value = perm ? formatOtp(e.target.value) : formatCode(e.target.value);
});
$('form').addEventListener('submit', (e) => {
  e.preventDefault();
  const v = $('code').value;
  // On the permanent link's card digits are a code; anything else is another link.
  if (perm && /^[\d\s]*$/.test(v)) submitOtp(v); else start(v);
});

paintJoin(); // GitHub Pages: only a link from anywhere works there

function startFromHash() {
  const e = parseEntry(location.hash);
  if (e.perm) {
    if (!(perm && e.key === key)) startPermanent(e.key);
    return;
  }
  if (e.code.length !== 9 || (e.code === code && e.key === key && wantConnected)) return;
  $('code').value = e.key ? location.hash.slice(1) : formatCode(e.code);
  start(location.hash);
}
window.addEventListener('hashchange', startFromHash);
startFromHash();
