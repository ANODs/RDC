//! The relay: the way through when a browser cannot reach this computer directly (both sides
//! behind strict NAT — mobile data, VPNs). Both connect by WebSocket to a room on a Cloudflare
//! Worker (`relay/worker.js`) that hands every message of one to the other.
//!
//! The browser picks 16 random bytes `r` and asks for the relay through signaling. Both derive
//! from the link's secret and `r` (HKDF-SHA256, info "rdc relay v1" ‖ r) 48 bytes: the room
//! `/r/<32 hex>` and an AES-256-GCM key. Every message is sealed: counter (8, big-endian) ‖
//! ciphertext ‖ tag (16), the nonce is direction ‖ 0 0 0 ‖ counter, the room is the associated
//! data. Counters only go up by one, so the worker cannot drop, repeat or reorder messages
//! unnoticed, and it reads nothing.
//!
//! Inside, the first byte of the plaintext says what it is: 't' — a text message (JSON), 'b' — a
//! piece of a binary message with more to follow, 'e' — its last piece. The worker itself sends
//! two text frames: "ready" when both ends are in the room, "gone" when one has left.
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const tls = std.crypto.tls;
const ws = @import("ws.zig");
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const token_len = 16;
pub const max_url = 200;
/// Binary messages are cut into pieces of at most this much: the worker takes up to 256 KB.
pub const piece_len = 60 * 1024;
const max_message = 4 * 1024 * 1024;
/// Keep in sync with relayLink in web/viewer.js.
pub const dir_browser: u8 = 0;
pub const dir_host: u8 = 1;

pub const Keys = struct {
    room: [32]u8,
    key: [32]u8,
};

/// `secret` and `salt` are what the signaling keys come from (the code and the link's key, or
/// "my" and the permanent link's key); `token` — the browser's 16 random bytes.
pub fn derive(secret: []const u8, salt: []const u8, token: *const [token_len]u8) Keys {
    const prk = HkdfSha256.extract(salt, secret);
    var info: ["rdc relay v1".len + token_len]u8 = undefined;
    @memcpy(info[0.."rdc relay v1".len], "rdc relay v1");
    @memcpy(info["rdc relay v1".len..], token);
    var okm: [48]u8 = undefined;
    HkdfSha256.expand(&okm, &info, prk);
    const k: Keys = .{ .room = std.fmt.bytesToHex(okm[0..16], .lower), .key = okm[16..48].* };
    std.crypto.secureZero(u8, &okm);
    return k;
}

fn nonce(dir: u8, counter: u64) [12]u8 {
    var n: [12]u8 = @splat(0);
    n[0] = dir;
    std.mem.writeInt(u64, n[4..12], counter, .big);
    return n;
}

pub fn sealedLen(plain_len: usize) usize {
    return 8 + plain_len + 16;
}

pub fn seal(out: []u8, k: *const Keys, dir: u8, counter: u64, plain: []const u8) []u8 {
    std.mem.writeInt(u64, out[0..8], counter, .big);
    var tag: [16]u8 = undefined;
    Aes256Gcm.encrypt(out[8..][0..plain.len], &tag, plain, &k.room, nonce(dir, counter), k.key);
    @memcpy(out[8 + plain.len ..][0..16], &tag);
    return out[0 .. 8 + plain.len + 16];
}

/// The plaintext of the message numbered `counter`, or null: another counter, damaged, forged.
pub fn open(out: []u8, k: *const Keys, dir: u8, counter: u64, msg: []const u8) ?[]u8 {
    if (msg.len < 24 or msg.len - 24 > out.len) return null;
    if (std.mem.readInt(u64, msg[0..8], .big) != counter) return null;
    const plain = out[0 .. msg.len - 24];
    Aes256Gcm.decrypt(plain, msg[8 .. msg.len - 16], msg[msg.len - 16 ..][0..16].*, &k.room, nonce(dir, counter), k.key) catch return null;
    return plain;
}

pub const Url = struct {
    secure: bool,
    host: []const u8,
    port: u16,

    /// "https://name.workers.dev" (or http://localhost:8787 for `wrangler dev`); a trailing slash is fine.
    pub fn parse(text: []const u8) ?Url {
        var s = std.mem.trim(u8, text, " \t\r\n");
        const secure = std.mem.startsWith(u8, s, "https://");
        if (secure) s = s["https://".len..] else if (std.mem.startsWith(u8, s, "http://")) s = s["http://".len..] else return null;
        while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
        if (s.len == 0 or std.mem.indexOfAny(u8, s, "/?#@ ") != null) return null;
        var host = s;
        var port: u16 = if (secure) 443 else 80;
        if (std.mem.lastIndexOfScalar(u8, s, ':')) |c| {
            host = s[0..c];
            port = std.fmt.parseInt(u16, s[c + 1 ..], 10) catch return null;
        }
        if (host.len == 0) return null;
        // Plain http only to this computer: anything else would let the network watch who connects.
        if (!secure and !std.mem.eql(u8, host, "localhost") and !std.mem.eql(u8, host, "127.0.0.1")) return null;
        return .{ .secure = secure, .host = host, .port = port };
    }
};

pub const Callbacks = struct {
    ctx: *anyopaque,
    /// A whole message from the browser, on the session's thread.
    message: *const fn (ctx: *anyopaque, s: *Session, binary: bool, data: []const u8) void,
    /// The session has ended; after this returns the session is freed.
    closed: *const fn (ctx: *anyopaque, s: *Session, reason: []const u8) void,
};

/// The root certificates relay connections are checked against: read once, on first use.
pub const Trust = struct {
    lock: Io.RwLock = .init,
    bundle: std.crypto.Certificate.Bundle = .empty,
    loaded: bool = false,
    load_mutex: Io.Mutex = .init,

    fn ensure(t: *Trust, gpa: std.mem.Allocator, io: Io) !void {
        t.load_mutex.lockUncancelable(io);
        defer t.load_mutex.unlock(io);
        if (t.loaded) return;
        try t.bundle.rescan(gpa, io, Io.Clock.real.now(io));
        t.loaded = true;
    }
};

const Conn = struct {
    sr: net.Stream.Reader,
    sw: net.Stream.Writer,
    tls_client: ?tls.Client = null,

    fn reader(c: *Conn) *Io.Reader {
        return if (c.tls_client) |*t| &t.reader else &c.sr.interface;
    }
    fn writer(c: *Conn) *Io.Writer {
        return if (c.tls_client) |*t| &t.writer else &c.sw.interface;
    }
    fn flush(c: *Conn) !void {
        if (c.tls_client) |*t| try t.writer.flush();
        try c.sw.interface.flush();
    }
};

/// Which end of the room this is: the host, or a viewer (the browser, or RDC's own agent).
pub const Side = enum {
    host,
    viewer,

    fn out(side: Side) u8 {
        return if (side == .host) dir_host else dir_browser;
    }
    fn in(side: Side) u8 {
        return if (side == .host) dir_browser else dir_host;
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    side: Side = .host,
    keys: Keys,
    cb: Callbacks,
    trust: *Trust,
    url_buf: [max_url]u8,
    url_len: usize,

    /// Guards writing and the counter going out.
    write_mutex: Io.Mutex = .init,
    conn: ?*Conn = null,
    stream: ?net.Stream = null,
    out_counter: u64 = 0,
    closing: std.atomic.Value(bool) = .init(false),
    /// Messages waiting for the session's thread to write them: up to the moment the room is ready.
    ready: std.atomic.Value(bool) = .init(false),
    seal_buf: []u8 = &.{},

    /// Connects to the room on a thread of its own. `url` is the relay's address as parsed by Url.
    pub fn start(gpa: std.mem.Allocator, io: Io, trust: *Trust, url: []const u8, keys: Keys, cb: Callbacks) !*Session {
        return startAs(gpa, io, .host, trust, url, keys, cb);
    }

    pub fn startAs(gpa: std.mem.Allocator, io: Io, side: Side, trust: *Trust, url: []const u8, keys: Keys, cb: Callbacks) !*Session {
        if (url.len > max_url or Url.parse(url) == null) return error.BadUrl;
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .io = io, .side = side, .keys = keys, .cb = cb, .trust = trust, .url_buf = undefined, .url_len = url.len };
        @memcpy(s.url_buf[0..url.len], url);
        s.seal_buf = try gpa.alloc(u8, sealedLen(piece_len + 1));
        errdefer gpa.free(s.seal_buf);
        const t = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, main, .{s}); // TLS with P-256 needs room in Debug builds
        t.detach();
        return s;
    }

    /// Both ends are in the room: what is sent now reaches the other end.
    pub fn isReady(s: *const Session) bool {
        return s.ready.load(.acquire);
    }

    pub fn peer(_: *const Session) []const u8 {
        return "relay";
    }

    /// A whole message to the browser: text as it is, binary cut into pieces. Blocks while the
    /// network is slow — that is the viewer's back-pressure.
    pub fn send(s: *Session, binary: bool, data: []const u8) error{Closed}!void {
        if (!binary) return s.sendPiece('t', data);
        var off: usize = 0;
        while (true) {
            const take = @min(piece_len, data.len - off);
            const last = off + take == data.len;
            try s.sendPiece(if (last) 'e' else 'b', data[off..][0..take]);
            off += take;
            if (last) return;
        }
    }

    pub fn sendText(s: *Session, text: []const u8) void {
        s.send(false, text) catch {};
    }

    fn sendPiece(s: *Session, kind: u8, data: []const u8) error{Closed}!void {
        if (data.len > piece_len) return error.Closed;
        s.write_mutex.lockUncancelable(s.io);
        defer s.write_mutex.unlock(s.io);
        if (s.closing.load(.acquire)) return error.Closed;
        const c = s.conn orelse return error.Closed;
        var plain: [piece_len + 1]u8 = undefined;
        plain[0] = kind;
        @memcpy(plain[1..][0..data.len], data);
        const sealed = seal(s.seal_buf, &s.keys, s.side.out(), s.out_counter, plain[0 .. data.len + 1]);
        s.out_counter += 1;
        writeFrame(s.io, c, .binary, sealed) catch return error.Closed;
        c.flush() catch return error.Closed;
    }

    /// Ends the session; `closed` follows on the session's thread.
    pub fn close(s: *Session) void {
        s.closing.store(true, .release);
        s.write_mutex.lockUncancelable(s.io);
        const stream = s.stream;
        s.write_mutex.unlock(s.io);
        if (stream) |st| st.shutdown(s.io, .both) catch {};
    }

    /// Ends the session after a delay, so the last messages still get through.
    pub fn closeAfter(s: *Session, ms: u64) void {
        const t = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, closeLater, .{ s, ms }) catch return s.close();
        t.detach();
    }

    fn closeLater(s: *Session, ms: u64) void {
        s.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
        s.close();
    }

    fn main(s: *Session) void {
        var reason: []const u8 = "the relay closed the connection";
        s.run() catch |e| {
            reason = switch (e) {
                error.Rejected => "the relay refused the connection",
                error.BadHandshake => "the address does not look like an RDC relay",
                error.NoRootCertificates => "this computer's root certificates could not be read",
                error.Forged => "a message through the relay was damaged or forged",
                else => @errorName(e),
            };
        };
        // From here no writer touches the connection.
        s.write_mutex.lockUncancelable(s.io);
        s.closing.store(true, .release);
        s.conn = null;
        s.stream = null;
        s.write_mutex.unlock(s.io);
        s.cb.closed(s.cb.ctx, s, reason);
        s.gpa.free(s.seal_buf);
        s.gpa.destroy(s);
    }

    fn run(s: *Session) !void {
        const io = s.io;
        const gpa = s.gpa;
        const url = Url.parse(s.url_buf[0..s.url_len]).?;
        if (url.secure) s.trust.ensure(gpa, io) catch return error.NoRootCertificates;
        const host_name = try net.HostName.init(url.host);
        // No connect timeout: Io.Threaded in Zig 0.17.1 panics on one; the host's watchdog closes a session that never starts.
        const stream = try host_name.connect(io, url.port, .{ .mode = .stream });
        defer stream.close(io);
        s.write_mutex.lockUncancelable(io);
        s.stream = stream;
        const closed_early = s.closing.load(.acquire);
        s.write_mutex.unlock(io);
        if (closed_early) return error.ConnectionClosed;

        const record = tls.Client.min_buffer_len;
        // Whatever reads WebSocket frames (TLS, or the socket itself without it) must hold a whole
        // frame: a piece of a video frame is up to 60 KB, plus a TLS record of room to refill.
        const frame_room = sealedLen(piece_len + 1) + 16 + record;
        const bufs = try gpa.alloc(u8, frame_room + record + frame_room + record);
        defer gpa.free(bufs);
        const c = try gpa.create(Conn);
        defer gpa.destroy(c);
        const sock_read = if (url.secure) bufs[0..record] else bufs[0..frame_room];
        c.* = .{ .sr = stream.reader(io, sock_read), .sw = stream.writer(io, bufs[frame_room..][0..record]) };
        if (url.secure) {
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            c.tls_client = tls.Client.init(&c.sr.interface, &c.sw.interface, .{
                .host = .{ .explicit = url.host },
                .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &s.trust.lock, .bundle = &s.trust.bundle } },
                .read_buffer = bufs[frame_room + record ..][0..frame_room],
                .write_buffer = bufs[frame_room + record + frame_room ..],
                .entropy = &entropy,
                .realtime_now = Io.Clock.real.now(io),
            }) catch |e| switch (e) {
                error.ReadFailed, error.WriteFailed => return error.ConnectionClosed,
                else => return e,
            };
        }
        try s.upgrade(c, url);

        s.write_mutex.lockUncancelable(io);
        s.conn = c;
        s.write_mutex.unlock(io);
        defer {
            s.write_mutex.lockUncancelable(io);
            s.conn = null;
            s.write_mutex.unlock(io);
        }

        const payload = try gpa.alloc(u8, sealedLen(piece_len + 1));
        defer gpa.free(payload);
        const plain = try gpa.alloc(u8, piece_len + 1);
        defer gpa.free(plain);
        const whole = try gpa.alloc(u8, max_message);
        defer gpa.free(whole);
        var whole_len: usize = 0;
        var in_counter: u64 = 0;
        const r = c.reader();
        while (true) {
            const h = while (true) {
                if (ws.parseServerHeader(r.buffered()) catch return error.BadFrame) |h| break h;
                r.fillMore() catch return error.ConnectionClosed;
            };
            r.toss(h.used);
            if (!h.fin) return error.BadFrame; // the worker never fragments
            if (h.len > payload.len) return error.BadFrame;
            const n: usize = @intCast(h.len);
            while (r.bufferedLen() < n) r.fillMore() catch return error.ConnectionClosed;
            const body = r.buffered()[0..n];
            switch (h.opcode) {
                .text => {
                    if (std.mem.eql(u8, body, "gone")) return error.ConnectionClosed;
                    if (std.mem.eql(u8, body, "ready")) s.ready.store(true, .release);
                },
                .binary => {
                    const p = open(plain, &s.keys, s.side.in(), in_counter, body) orelse return error.Forged;
                    in_counter += 1;
                    if (p.len == 0) return error.Forged;
                    const data = p[1..];
                    switch (p[0]) {
                        't' => s.cb.message(s.cb.ctx, s, false, data),
                        'b', 'e' => {
                            if (whole_len + data.len > whole.len) return error.TooLarge;
                            @memcpy(whole[whole_len..][0..data.len], data);
                            whole_len += data.len;
                            if (p[0] == 'e') {
                                s.cb.message(s.cb.ctx, s, true, whole[0..whole_len]);
                                whole_len = 0;
                            }
                        },
                        else => return error.Forged,
                    }
                },
                .ping => {
                    var pong: [125]u8 = undefined;
                    const len = @min(n, pong.len);
                    @memcpy(pong[0..len], body[0..len]);
                    r.toss(n);
                    s.write_mutex.lockUncancelable(io);
                    defer s.write_mutex.unlock(io);
                    writeFrame(io, c, .pong, pong[0..len]) catch {};
                    c.flush() catch {};
                    continue;
                },
                .close => return error.ConnectionClosed,
                else => {},
            }
            r.toss(n);
        }
    }

    /// The WebSocket handshake for /r/<room>: 101 and the right Sec-WebSocket-Accept.
    fn upgrade(s: *Session, c: *Conn, url: Url) !void {
        var key_raw: [16]u8 = undefined;
        s.io.random(&key_raw);
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &key_raw);
        const w = c.writer();
        w.print("GET /r/{s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: RDC\r\n\r\n", .{ &s.keys.room, url.host, key }) catch return error.ConnectionClosed;
        c.flush() catch return error.ConnectionClosed;
        const r = c.reader();
        const head_len = while (true) {
            if (std.mem.find(u8, r.buffered(), "\r\n\r\n")) |at| break at + 4;
            if (r.bufferedLen() >= 8192) return error.BadHandshake;
            r.fillMore() catch return error.ConnectionClosed;
        };
        const head = r.buffered()[0..head_len];
        if (std.mem.startsWith(u8, head, "HTTP/1.1 429") or std.mem.startsWith(u8, head, "HTTP/1.1 403")) return error.Rejected;
        if (!std.mem.startsWith(u8, head, "HTTP/1.1 101")) return error.BadHandshake;
        var accept_buf: [28]u8 = undefined;
        const want = ws.acceptKey(key, &accept_buf);
        var ok = false;
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "sec-websocket-accept")) continue;
            ok = std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), want);
        }
        if (!ok) return error.BadHandshake;
        r.toss(head_len);
    }
};

fn writeFrame(io: Io, c: *Conn, opcode: ws.Opcode, payload: []const u8) !void {
    const w = c.writer();
    var mask: [4]u8 = undefined;
    io.random(&mask);
    var hb: [14]u8 = undefined;
    try w.writeAll(ws.clientHeader(&hb, opcode, payload.len, mask));
    var chunk: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) {
        const n = @min(chunk.len, payload.len - off);
        for (chunk[0..n], payload[off..][0..n], off..) |*d, b, i| d.* = b ^ mask[i & 3];
        try w.writeAll(chunk[0..n]);
        off += n;
    }
}

test "relay: keys, sealing and the counter" {
    const token: [token_len]u8 = @splat(7);
    const a = derive("123456789", "0123456789abcdef", &token);
    const b = derive("123456789", "0123456789abcdef", &token);
    try std.testing.expectEqualSlices(u8, &a.room, &b.room);
    const other: [token_len]u8 = @splat(8);
    try std.testing.expect(!std.mem.eql(u8, &a.room, &derive("123456789", "0123456789abcdef", &other).room));
    for (a.room) |ch| try std.testing.expect(std.ascii.isHex(ch) and !std.ascii.isUpper(ch));

    var buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    const sealed = seal(&buf, &a, dir_host, 5, "thello");
    try std.testing.expectEqualStrings("thello", open(&out, &a, dir_host, 5, sealed).?);
    // Another counter, the other direction, a flipped bit: refused.
    try std.testing.expect(open(&out, &a, dir_host, 6, sealed) == null);
    try std.testing.expect(open(&out, &a, dir_browser, 5, sealed) == null);
    sealed[10] ^= 1;
    try std.testing.expect(open(&out, &a, dir_host, 5, sealed) == null);
}

test "relay: known answer shared with web/viewer.js" {
    // The same inputs in the browser (deriveRelay in web/viewer.js) give the same room.
    const token: [token_len]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const k = derive("123456789", "AAAAAAAAAAAAAAAA", &token);
    try std.testing.expectEqualStrings("86fda181b28099bb9bac98d9a3f9009f", &k.room);
    try std.testing.expectEqualStrings("126d4972abd6817d1c3a4fbcf083af4dd01396d480b9d7da76e2601d1f397602", &std.fmt.bytesToHex(k.key, .lower));
}

test "relay: addresses" {
    const a = Url.parse("https://rdc-relay.example.workers.dev/").?;
    try std.testing.expect(a.secure);
    try std.testing.expectEqualStrings("rdc-relay.example.workers.dev", a.host);
    try std.testing.expectEqual(@as(u16, 443), a.port);
    const d = Url.parse("http://localhost:8787").?;
    try std.testing.expect(!d.secure);
    try std.testing.expectEqual(@as(u16, 8787), d.port);
    try std.testing.expect(Url.parse("http://relay.example.com") == null);
    try std.testing.expect(Url.parse("ftp://x") == null);
    try std.testing.expect(Url.parse("https://") == null);
    try std.testing.expect(Url.parse("https://a.dev/path") == null);
    try std.testing.expect(Url.parse("https://a.dev:99999") == null);
}
