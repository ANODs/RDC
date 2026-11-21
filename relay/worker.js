// RDC relay: a Cloudflare Worker that passes messages between a computer running RDC and a
// browser when the two cannot connect directly (both behind strict NAT: mobile data, VPNs).
//
// Each session is a room, /r/<32 hex>: a Durable Object that holds at most two WebSockets and
// hands every message of one to the other. Both sides derive the room and the AES-GCM key from
// the link (src/net/relay.zig, web/viewer.js), so the worker sees only a random room name and
// sealed bytes — it cannot read the picture or the input, and cannot forge either.
//
// Deploy your own: see relay/README.md (one command, or the Deploy to Cloudflare button).
import { DurableObject } from 'cloudflare:workers';

const MAX_MESSAGE = 256 * 1024;

export class Room extends DurableObject {
  async fetch() {
    const open = this.ctx.getWebSockets();
    if (open.length >= 2) return new Response('This session already has two ends', { status: 429 });
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server); // between messages the room hibernates and costs nothing
    if (open.length === 1) {
      // Both ends are here: from now on whatever one sends reaches the other.
      for (const ws of [open[0], server]) { try { ws.send('ready'); } catch (_) {} }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    if (typeof message === 'string' || message.byteLength > MAX_MESSAGE) return;
    for (const other of this.ctx.getWebSockets()) {
      if (other !== ws) { try { other.send(message); } catch (_) {} }
    }
  }

  webSocketClose(ws) { this.leave(ws); }
  webSocketError(ws) { this.leave(ws); }

  // One end left: the session is over for the other too.
  leave(ws) {
    for (const other of this.ctx.getWebSockets()) {
      if (other === ws) continue;
      try { other.send('gone'); other.close(1000, 'gone'); } catch (_) {}
    }
    try { ws.close(1000, 'bye'); } catch (_) {}
  }
}

// Pages allowed to use this relay from a browser; RDC itself connects without an Origin.
// ORIGINS (a variable in wrangler.toml or the dashboard) replaces the list: space-separated origins.
function originAllowed(origin, env) {
  if (!origin) return true;
  const list = (env.ORIGINS || 'https://anods.github.io').split(/\s+/).filter(Boolean);
  if (list.includes(origin)) return true;
  return /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const room = /^\/r\/([0-9a-f]{32})$/.exec(path);
    if (room) {
      if (request.headers.get('upgrade') !== 'websocket') return new Response('WebSocket only', { status: 426 });
      if (!originAllowed(request.headers.get('origin'), env)) return new Response('Origin not allowed', { status: 403 });
      return env.ROOMS.get(env.ROOMS.idFromName(room[1])).fetch(request);
    }
    if (path === '/') {
      // RDC's Settings checks a relay address by this answer.
      return new Response(JSON.stringify({ rdc_relay: 1 }), {
        headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'cache-control': 'no-store' },
      });
    }
    return new Response('Not found', { status: 404 });
  },
};
