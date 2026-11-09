//! Signaling through public MQTT brokers: how a browser that has the link finds this host.
//!
//! The link carries the code and a random 16-byte key. HKDF-SHA256 (salt — the key,
//! input — the code, info "rdc signal v1") gives 48 bytes: the topic `rdc/<32 hex>` and
//! an AES-256-GCM key. Every message is JSON sealed as nonce (12) ‖ ciphertext ‖ tag (16)
//! with the topic as associated data, so a broker sees only a random topic and noise.
//! The host keeps plain MQTT 3.1.1 connections (TCP 1883) to every broker in `brokers`;
//! the browser reaches the same brokers over WebSocket (`web/viewer.js`).
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const mqtt = @import("mqtt.zig");
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const Broker = struct { host: []const u8, port: u16 };

/// Keep in sync with BROKERS in web/viewer.js (the same brokers over wss).
pub const brokers = [_]Broker{
    .{ .host = "broker.emqx.io", .port = 1883 },
    .{ .host = "broker.hivemq.com", .port = 1883 },
};

pub const salt_len = 16;
/// The key in the link: base64url without padding.
pub const salt_text_len = std.base64.url_safe_no_pad.Encoder.calcSize(salt_len);
pub const max_message = 32 * 1024;
const keepalive_s = 60;
const ping_every_us: u64 = 25_000_000;
const dead_after_us: u64 = 80_000_000;

pub const Keys = struct {
    topic_buf: [4 + 32]u8,
    key: [32]u8,

    pub fn topic(k: *const Keys) []const u8 {
        return &k.topic_buf;
    }
};

pub fn derive(code: []const u8, salt: *const [salt_len]u8) Keys {
    const prk = HkdfSha256.extract(salt, code);
    var okm: [48]u8 = undefined;
    HkdfSha256.expand(&okm, "rdc signal v1", prk);
    var k: Keys = .{ .topic_buf = undefined, .key = okm[16..48].* };
    @memcpy(k.topic_buf[0..4], "rdc/");
    const hex = std.fmt.bytesToHex(okm[0..16], .lower);
    @memcpy(k.topic_buf[4..], &hex);
    std.crypto.secureZero(u8, &okm);
    return k;
}

pub fn sealedLen(plain_len: usize) usize {
    return 12 + plain_len + 16;
}

pub fn seal(out: []u8, k: *const Keys, nonce: [12]u8, plain: []const u8) []u8 {
    @memcpy(out[0..12], &nonce);
    var tag: [16]u8 = undefined;
    Aes256Gcm.encrypt(out[12..][0..plain.len], &tag, plain, k.topic(), nonce, k.key);
    @memcpy(out[12 + plain.len ..][0..16], &tag);
    return out[0 .. 12 + plain.len + 16];
}

/// The plaintext, or null when the message is not ours (another key, damaged, forged).
pub fn open(out: []u8, k: *const Keys, msg: []const u8) ?[]u8 {
    if (msg.len < 28 or msg.len - 28 > out.len) return null;
    const plain = out[0 .. msg.len - 28];
    Aes256Gcm.decrypt(plain, msg[12 .. msg.len - 16], msg[msg.len - 16 ..][0..16].*, k.topic(), msg[0..12].*, k.key) catch return null;
    return plain;
}

// ---------------------------------------------------------------------------
// Broker connections.

pub const Handler = *const fn (ctx: *anyopaque, plaintext: []const u8) void;
pub const LogFn = *const fn (msg: []const u8) void;

const Conn = struct {
    stream: ?net.Stream = null,
    write_mutex: Io.Mutex = .init,
    topic: [36]u8 = undefined,
    subscribed: bool = false,
    packet_id: u16 = 1,
    last_rx_us: std.atomic.Value(u64) = .init(0),
    last_ping_us: u64 = 0,
};

pub const Signal = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    keys: Keys,
    conns: [brokers.len]Conn = @splat(.{}),
    handler: Handler,
    ctx: *anyopaque,
    log_fn: LogFn,

    pub fn start(gpa: std.mem.Allocator, io: Io, keys: Keys, handler: Handler, ctx: *anyopaque, log_fn: LogFn) !*Signal {
        const s = try gpa.create(Signal);
        s.* = .{ .gpa = gpa, .io = io, .keys = keys, .handler = handler, .ctx = ctx, .log_fn = log_fn };
        for (0..brokers.len) |i| {
            const t = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, brokerMain, .{ s, i });
            t.detach();
        }
        return s;
    }

    fn log(s: *Signal, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        s.log_fn(std.fmt.bufPrint(&buf, fmt, args) catch return);
    }

    fn now(s: *Signal) u64 {
        return @intCast(@divTrunc(Io.Clock.awake.now(s.io).nanoseconds, 1000));
    }

    /// How many brokers we are subscribed on right now.
    pub fn connected(s: *Signal) usize {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var n: usize = 0;
        for (&s.conns) |*c| {
            if (c.stream != null and c.subscribed) n += 1;
        }
        return n;
    }

    /// A new code: leave the old topic and listen on the new one.
    pub fn setKeys(s: *Signal, keys: Keys) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.keys = keys;
        for (&s.conns) |*c| {
            const stream = c.stream orelse continue;
            var buf: [64]u8 = undefined;
            c.write_mutex.lockUncancelable(s.io);
            defer c.write_mutex.unlock(s.io);
            if (c.subscribed) {
                c.packet_id +%= 1;
                writeAll(s.io, stream, mqtt.unsubscribe(&buf, c.packet_id, &c.topic));
            }
            c.packet_id +%= 1;
            @memcpy(&c.topic, keys.topic());
            writeAll(s.io, stream, mqtt.subscribe(&buf, c.packet_id, &c.topic));
            c.subscribed = true;
        }
    }

    /// Seals a message and publishes it on every connected broker.
    pub fn send(s: *Signal, plaintext: []const u8) void {
        if (plaintext.len > max_message) return;
        var nonce: [12]u8 = undefined;
        s.io.random(&nonce);
        const sealed = s.gpa.alloc(u8, sealedLen(plaintext.len)) catch return;
        defer s.gpa.free(sealed);
        s.mutex.lockUncancelable(s.io);
        const keys = s.keys;
        s.mutex.unlock(s.io);
        _ = seal(sealed, &keys, nonce, plaintext);
        const packet = s.gpa.alloc(u8, mqtt.publishSize(keys.topic(), sealed.len)) catch return;
        defer s.gpa.free(packet);
        const p = mqtt.publish(packet, keys.topic(), sealed);
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (&s.conns) |*c| {
            const stream = c.stream orelse continue;
            if (!c.subscribed) continue;
            c.write_mutex.lockUncancelable(s.io);
            defer c.write_mutex.unlock(s.io);
            writeAll(s.io, stream, p);
        }
    }

    /// Called about once a second: pings the brokers and drops connections that went quiet.
    pub fn keepalive(s: *Signal) void {
        const t = s.now();
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (&s.conns) |*c| {
            const stream = c.stream orelse continue;
            if (t -| c.last_rx_us.load(.monotonic) > dead_after_us) {
                stream.shutdown(s.io, .both) catch {}; // wakes the reader thread, which reconnects
                continue;
            }
            if (t -| c.last_ping_us < ping_every_us) continue;
            c.last_ping_us = t;
            c.write_mutex.lockUncancelable(s.io);
            defer c.write_mutex.unlock(s.io);
            writeAll(s.io, stream, &mqtt.pingreq);
        }
    }

    fn brokerMain(s: *Signal, i: usize) void {
        var backoff_ms: u64 = 2_000;
        while (true) {
            const started = s.now();
            s.connection(i) catch |e| s.log("signaling: {s}: {t}", .{ brokers[i].host, e });
            if (s.now() -| started > 120_000_000) backoff_ms = 2_000;
            s.io.sleep(.fromMilliseconds(@intCast(backoff_ms)), .awake) catch {};
            backoff_ms = @min(backoff_ms * 2, 120_000);
        }
    }

    fn connection(s: *Signal, i: usize) !void {
        const io = s.io;
        const b = brokers[i];
        const host_name = try net.HostName.init(b.host);
        // No connect timeout: Io.Threaded in Zig 0.17.1 panics on one ("TODO implement netConnectIpPosix with timeout").
        const stream = try host_name.connect(io, b.port, .{ .mode = .stream });
        defer stream.close(io);
        const c = &s.conns[i];

        var id_bytes: [6]u8 = undefined;
        io.random(&id_bytes);
        var cid_buf: [16]u8 = undefined;
        const cid = std.fmt.bufPrint(&cid_buf, "rdc-{x}", .{&id_bytes}) catch unreachable;
        var out: [64]u8 = undefined;
        writeAll(io, stream, mqtt.connect(&out, cid, keepalive_s));

        const rbuf = try s.gpa.alloc(u8, max_message + 1024);
        defer s.gpa.free(rbuf);
        var sr = stream.reader(io, rbuf);
        const r = &sr.interface;
        const plain = try s.gpa.alloc(u8, max_message);
        defer s.gpa.free(plain);

        defer {
            s.mutex.lockUncancelable(io);
            c.stream = null;
            c.subscribed = false;
            s.mutex.unlock(io);
        }
        var connacked = false;
        while (true) {
            const p = (mqtt.parse(r.buffered(), max_message + 512) catch {
                // Anyone can publish to a public topic: a packet too large to keep is skipped,
                // the connection stays. (Retained, it would otherwise greet every reconnect.)
                const total = mqtt.packetLen(r.buffered()) orelse return error.MessageTooLarge;
                r.discardAll(total) catch return error.ConnectionClosed;
                continue;
            }) orelse {
                if (r.bufferedLen() == r.buffer.len) return error.MessageTooLarge;
                r.fillMore() catch return if (connacked) error.ConnectionClosed else error.NoConnack;
                continue;
            };
            c.last_rx_us.store(s.now(), .monotonic);
            switch (p.kind) {
                mqtt.connack_type => {
                    if (p.body.len < 2 or p.body[1] != 0) return error.Refused;
                    connacked = true;
                    s.mutex.lockUncancelable(io);
                    c.stream = stream;
                    c.last_ping_us = s.now();
                    @memcpy(&c.topic, s.keys.topic());
                    c.write_mutex.lockUncancelable(io);
                    c.packet_id +%= 1;
                    writeAll(io, stream, mqtt.subscribe(&out, c.packet_id, &c.topic));
                    c.subscribed = true;
                    c.write_mutex.unlock(io);
                    s.mutex.unlock(io);
                    s.log("signaling: listening on {s}", .{b.host});
                },
                mqtt.publish_type => if (mqtt.parsePublish(p)) |msg| {
                    s.mutex.lockUncancelable(io);
                    const keys = s.keys;
                    s.mutex.unlock(io);
                    if (std.mem.eql(u8, msg.topic, keys.topic())) {
                        if (open(plain, &keys, msg.payload)) |text| s.handler(s.ctx, text);
                    }
                },
                else => {},
            }
            r.toss(p.used);
        }
    }
};

fn writeAll(io: Io, stream: net.Stream, data: []const u8) void {
    var buf: [512]u8 = undefined;
    var sw = stream.writer(io, &buf);
    sw.interface.writeAll(data) catch return;
    sw.interface.flush() catch {};
}

// Reference values from WebCrypto (Node 22), the same calls web/viewer.js makes.
test "signal: key derivation and sealing match WebCrypto" {
    var salt: [salt_len]u8 = undefined;
    for (&salt, 0..) |*b, i| b.* = @intCast(i);
    const k = derive("123456789", &salt);
    try std.testing.expectEqualStrings("rdc/12905b9c8d307a95214bc48884ebb57f", k.topic());
    var want_key: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want_key, "ad0831f83a28c6d7ee974768a3a05d49ff22798e0a00f235edff65d251e11a8c");
    try std.testing.expectEqual(want_key, k.key);

    var out: [128]u8 = undefined;
    const sealed = seal(&out, &k, @splat(9), "{\"t\":\"offer\"}");
    var want: [41]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "090909090909090909090909d80ef02baacb4af6039a66f88bdcfda012fd9d6180cff5fb4221c26671");
    try std.testing.expectEqualSlices(u8, &want, sealed);

    var plain: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"t\":\"offer\"}", open(&plain, &k, &want).?);
    // Another code, a flipped bit, a short message: not ours.
    const other = derive("123456780", &salt);
    try std.testing.expectEqual(@as(?[]u8, null), open(&plain, &other, &want));
    want[20] ^= 1;
    try std.testing.expectEqual(@as(?[]u8, null), open(&plain, &k, &want));
    try std.testing.expectEqual(@as(?[]u8, null), open(&plain, &k, want[0..20]));

    var text: [salt_text_len]u8 = undefined;
    try std.testing.expectEqualStrings("AAECAwQFBgcICQoLDA0ODw", std.base64.url_safe_no_pad.Encoder.encode(&text, &salt));
}
