'use strict';
// RDC web viewer: WebSocket → H.264 (WebCodecs) or JPEG → canvas; mouse and keyboard → host.

const $ = (id) => document.getElementById(id);
const canH264 = typeof VideoDecoder === 'function' && typeof EncodedVideoChunk === 'function';
const localIsMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

const MSG = { MOVE: 1, BUTTON: 2, WHEEL: 3, KEY: 4, RELEASE_ALL: 5, KEYFRAME: 16 };
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

let ws = null;
let code = '';
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

function showJoin(error) {
  wantConnected = false;
  document.body.classList.remove('live');
  osk.reset();
  $('stage').style.display = 'none';
  $('join').style.display = 'flex';
  $('err').textContent = error || '';
  $('code').focus();
}

// Damm check digit: the last digit of the code catches typos before connecting.
const DAMM = [
  [0, 3, 1, 7, 5, 9, 8, 6, 4, 2], [7, 0, 9, 2, 1, 5, 4, 8, 6, 3], [4, 2, 0, 6, 8, 7, 1, 3, 5, 9],
  [1, 7, 5, 0, 9, 8, 3, 4, 2, 6], [6, 1, 2, 3, 0, 4, 5, 9, 7, 8], [3, 6, 7, 4, 2, 0, 9, 5, 8, 1],
  [5, 8, 6, 9, 7, 2, 0, 1, 3, 4], [8, 9, 4, 5, 3, 6, 2, 0, 1, 7], [9, 4, 3, 8, 6, 1, 7, 2, 0, 5],
  [2, 5, 8, 1, 4, 3, 6, 7, 9, 0],
];
const dammOk = (digits) => [...digits].reduce((i, d) => DAMM[i][+d], 0) === 0;

function start(raw) {
  code = raw.replace(/\D/g, '');
  if (code.length !== 9) return showJoin('The code must be 9 digits');
  if (!dammOk(code)) return showJoin('Typo in the code — check the digits');
  $('err').textContent = 'Connecting…';
  wantConnected = true;
  connect();
}

function connect() {
  if (ws) { ws.onclose = null; ws.close(); }
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${proto}//${location.host}/ws`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => {
    send(JSON.stringify({ t: 'hello', code, h264: canH264 && !forceJpeg, agent: navigator.userAgent }));
  };
  ws.onmessage = (ev) => {
    if (typeof ev.data === 'string') onControl(JSON.parse(ev.data));
    else onFrame(ev.data);
  };
  ws.onclose = () => {
    ws = null;
    resetDecoder();
    if (!wantConnected) return;
    if (host) $('veil').style.display = 'flex';
    setTimeout(() => wantConnected && connect(), 1000);
  };
}

function send(data) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(data);
}

function onControl(m) {
  switch (m.t) {
    case 'ok':
      host = m;
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
      canvas.focus();
      break;
    case 'size':
      setSize(m.w, m.h);
      break;
    case 'pong':
      stats.rtt = performance.now() - m.ts;
      syncCursor(m);
      break;
    case 'err':
      if (m.fatal) { if (ws) { ws.onclose = null; ws.close(); ws = null; } showJoin(m.msg); break; }
      $('veil').textContent = m.msg;
      $('veil').style.display = 'flex';
      gotFrame = false;
      break;
    case 'bye':
      if (ws) { ws.onclose = null; ws.close(); ws = null; }
      host = null;
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

canvas.addEventListener('pointermove', (e) => {
  if (e.pointerType === 'touch') return touchMove(e);
  movePending = norm(e);
});
canvas.addEventListener('pointerdown', (e) => {
  e.preventDefault();
  canvas.focus();
  try { canvas.setPointerCapture(e.pointerId); } catch (_) {}
  if (e.pointerType === 'touch') return touchDown(e);
  const [x, y] = norm(e);
  movePending = null;
  sendMove(x, y);
  sendButton(buttonOf(e), true, x, y);
});
canvas.addEventListener('pointerup', (e) => {
  e.preventDefault();
  if (e.pointerType === 'touch') return touchUp(e);
  const [x, y] = norm(e);
  sendButton(buttonOf(e), false, x, y);
});
canvas.addEventListener('pointercancel', (e) => {
  if (e.pointerType !== 'touch') return;
  tp.touches.delete(e.pointerId);
  if (tp.touches.size === 0) tp.mode = 'none';
});
canvas.addEventListener('contextmenu', (e) => e.preventDefault());
canvas.addEventListener('wheel', (e) => {
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
$('leave').addEventListener('click', () => {
  releaseAll();
  wantConnected = false;
  host = null;
  if (ws) { ws.onclose = null; ws.close(); ws = null; }
  resetDecoder();
  showJoin('');
});
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
  $('stat').textContent = host ? `${codec} · ${fps} fps · ${mbps} Mbps · ${Math.round(stats.rtt)} ms` : '';
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
    const d = { visible: false, docked: window.innerWidth < 700, ghost: false, w: Math.min(window.innerWidth - 16, 760), x: 8, y: 80 };
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
  function label(code) {
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
    if (RU[spec.code]) { const a = document.createElement('span'); a.className = 'alt'; a.textContent = RU[spec.code]; b.append(a); }
    return b;
  }

  function render(force) {
    if (el.hidden) return;
    const width = el.getBoundingClientRect().width;
    const wide = width >= WIDE;
    const sig = [wide, page, os.title, shiftOn()].join('|');
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
    if (b.dataset.lang) { const [m, code] = os.lang; return combo([m], code); }
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

$('code').addEventListener('input', (e) => { e.target.value = formatCode(e.target.value); });
$('form').addEventListener('submit', (e) => { e.preventDefault(); start($('code').value); });

function startFromHash() {
  const fromLink = location.hash.replace(/\D/g, '');
  if (fromLink.length === 9 && fromLink !== code) { $('code').value = formatCode(fromLink); start(fromLink); }
}
window.addEventListener('hashchange', startFromHash);
startFromHash();
