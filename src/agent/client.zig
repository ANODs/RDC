//! A connection to an RDC host as a viewer: the AI agent's eyes and hands.
//! WebSocket to http://host:port/ws with the 9-digit code; JPEG frames come in, input goes out.
//! A reader thread keeps the latest frame and the cursor position; a pinger keeps the session
//! alive (the host drops viewers that are silent for 30 s) and asks where the cursor is.
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const ws = @import("../net/ws.zig");
const proto = @import("../core/proto.zig");

pub const default_port: u16 = 7700;
const max_frame_bytes = 32 * 1024 * 1024;
const max_text_bytes = 32 * 1024;
/// The host accepts at most 16 KB per message; text goes in pieces well below that.
pub const text_chunk = 4000;

pub const Error = error{
    BadAddress,
    ConnectFailed,
    HandshakeFailed,
    Rejected,
    Timeout,
    Closed,
    OutOfMemory,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    stream: net.Stream,

    // Filled from the host's "ok": what this computer is.
    host_name_buf: [128]u8 = undefined,
    host_name_len: usize = 0,
    os_buf: [16]u8 = undefined,
    os_len: usize = 0,
    version_buf: [24]u8 = undefined,
    version_len: usize = 0,
    /// The host understands text input (RDC 0.3+); older hosts get US-layout key presses.
    can_text: bool = false,
    address_buf: [160]u8 = undefined,
    address_len: usize = 0,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// The latest JPEG frame, owned.
    frame: ?[]u8 = null,
    /// Size of the host's frames.
    frame_w: u32 = 0,
    frame_h: u32 = 0,
    frame_seq: u64 = 0,
    cursor_x: f64 = 0.5,
    cursor_y: f64 = 0.5,
    ok: bool = false,
    closed: bool = false,
    reason_buf: [200]u8 = undefined,
    reason_len: usize = 0,
    /// The host's latest non-fatal complaint (no Screen Recording permission, ...).
    warn_buf: [200]u8 = undefined,
    warn_len: usize = 0,

    write_mutex: Io.Mutex = .init,
    reader: ?std.Thread = null,
    pinger: ?std.Thread = null,

    pub fn hostName(s: *const Session) []const u8 {
        return s.host_name_buf[0..s.host_name_len];
    }
    pub fn os(s: *const Session) []const u8 {
        return s.os_buf[0..s.os_len];
    }
    pub fn version(s: *const Session) []const u8 {
        return s.version_buf[0..s.version_len];
    }
    pub fn address(s: *const Session) []const u8 {
        return s.address_buf[0..s.address_len];
    }

    fn lock(s: *Session) void {
        s.mutex.lockUncancelable(s.io);
    }
    fn unlock(s: *Session) void {
        s.mutex.unlock(s.io);
    }

    /// What the host last complained about, or null.
    pub fn warning(s: *Session, out: []u8) ?[]const u8 {
        s.lock();
        defer s.unlock();
        if (s.warn_len == 0) return null;
        const n = @min(out.len, s.warn_len);
        @memcpy(out[0..n], s.warn_buf[0..n]);
        return out[0..n];
    }

    /// Why the session ended, or null while it is alive.
    pub fn closedReason(s: *Session, out: []u8) ?[]const u8 {
        s.lock();
        defer s.unlock();
        if (!s.closed) return null;
        const n = @min(out.len, s.reason_len);
        @memcpy(out[0..n], s.reason_buf[0..n]);
        return out[0..n];
    }

    fn setClosed(s: *Session, reason: []const u8) void {
        s.lock();
        defer s.unlock();
        if (!s.closed) {
            s.closed = true;
            const n = @min(reason.len, s.reason_buf.len);
            @memcpy(s.reason_buf[0..n], reason[0..n]);
            s.reason_len = n;
        }
        s.cond.broadcast(s.io);
    }

    // --- Sending

    fn send(s: *Session, opcode: ws.Opcode, payload: []const u8) Error!void {
        var mask: [4]u8 = undefined;
        s.io.random(&mask);
        var hb: [14]u8 = undefined;
        const head = ws.clientHeader(&hb, opcode, payload.len, mask);
        var masked: [4096]u8 = undefined;
        s.write_mutex.lockUncancelable(s.io);
        defer s.write_mutex.unlock(s.io);
        var wbuf: [4096]u8 = undefined;
        var sw = s.stream.writer(s.io, &wbuf);
        const w = &sw.interface;
        w.writeAll(head) catch return error.Closed;
        var off: usize = 0;
        while (off < payload.len) {
            const n = @min(masked.len, payload.len - off);
            @memcpy(masked[0..n], payload[off..][0..n]);
            // The mask continues across pieces: XOR by the absolute offset.
            for (masked[0..n], 0..) |*b, i| b.* ^= mask[(off + i) & 3];
            w.writeAll(masked[0..n]) catch return error.Closed;
            off += n;
        }
        w.flush() catch return error.Closed;
    }

    pub fn sendText(s: *Session, payload: []const u8) Error!void {
        return s.send(.text, payload);
    }

    pub fn move(s: *Session, x: f32, y: f32) Error!void {
        var b: [9]u8 = undefined;
        return s.send(.binary, proto.encodeMove(&b, x, y));
    }

    pub fn button(s: *Session, which: u8, down: bool, x: f32, y: f32) Error!void {
        var b: [11]u8 = undefined;
        return s.send(.binary, proto.encodeButton(&b, which, down, x, y));
    }

    pub fn wheel(s: *Session, dx: f32, dy: f32) Error!void {
        var b: [9]u8 = undefined;
        return s.send(.binary, proto.encodeWheel(&b, dx, dy));
    }

    pub fn key(s: *Session, usage: u16, down: bool) Error!void {
        var b: [4]u8 = undefined;
        return s.send(.binary, proto.encodeKey(&b, usage, down));
    }

    pub fn releaseAll(s: *Session) Error!void {
        return s.send(.binary, &.{proto.msg_release_all});
    }

    pub fn requestKeyframe(s: *Session) Error!void {
        return s.send(.binary, &.{proto.msg_keyframe});
    }

    /// Unicode text to type. Valid UTF-8, split at character boundaries into host-sized pieces.
    pub fn text(s: *Session, utf8: []const u8) Error!void {
        var rest = utf8;
        var buf: [text_chunk + 1]u8 = undefined;
        while (rest.len > 0) {
            var n = @min(rest.len, text_chunk);
            // Do not cut a character in two.
            while (n < rest.len and n > 0 and rest[n] & 0xC0 == 0x80) n -= 1;
            if (n == 0) return;
            buf[0] = proto.msg_text;
            @memcpy(buf[1..][0..n], rest[0..n]);
            try s.send(.binary, buf[0 .. n + 1]);
            rest = rest[n..];
        }
    }

    // --- Frames

    pub const Snapshot = struct {
        jpeg: []u8,
        w: u32,
        h: u32,
        seq: u64,
    };

    /// A copy of the latest frame (free with gpa), waiting up to timeout_ms for the first one.
    pub fn snapshot(s: *Session, timeout_ms: i64) Error!Snapshot {
        s.lock();
        defer s.unlock();
        const deadline = deadlineIn(s.io, timeout_ms);
        while (s.frame == null and !s.closed) {
            s.cond.waitTimeout(s.io, &s.mutex, deadline) catch return error.Timeout;
        }
        const f = s.frame orelse return error.Closed;
        const copy = s.gpa.dupe(u8, f) catch return error.OutOfMemory;
        return .{ .jpeg = copy, .w = s.frame_w, .h = s.frame_h, .seq = s.frame_seq };
    }

    pub fn frameSeq(s: *Session) u64 {
        s.lock();
        defer s.unlock();
        return s.frame_seq;
    }

    pub fn cursor(s: *Session) [2]f64 {
        s.lock();
        defer s.unlock();
        return .{ s.cursor_x, s.cursor_y };
    }

    /// After an action: waits for the screen to react and settle. Returns as soon as no frame
    /// came for `quiet_ms` after the first change, or when nothing changed for `first_ms`;
    /// never longer than `max_ms` (a playing video never settles).
    pub fn settle(s: *Session, since_seq: u64, first_ms: i64, quiet_ms: i64, max_ms: i64) void {
        s.lock();
        defer s.unlock();
        const hard_ns = nowNs(s.io) + @as(i96, max_ms) * std.time.ns_per_ms;
        // The first change.
        const first = deadlineIn(s.io, first_ms);
        while (s.frame_seq == since_seq and !s.closed) {
            s.cond.waitTimeout(s.io, &s.mutex, first) catch return;
        }
        // Then quiet: no new frame for quiet_ms, but no longer than max_ms in all.
        while (!s.closed) {
            const seen = s.frame_seq;
            const left_ms: i64 = @intCast(@divTrunc(hard_ns - nowNs(s.io), std.time.ns_per_ms));
            if (left_ms <= 0) return;
            const wait = deadlineIn(s.io, @min(quiet_ms, left_ms));
            while (s.frame_seq == seen and !s.closed) {
                s.cond.waitTimeout(s.io, &s.mutex, wait) catch return; // quiet long enough, or out of time
            }
        }
    }

    /// Waits for `ms` or until the session ends.
    pub fn sleep(s: *Session, ms: i64) void {
        s.lock();
        defer s.unlock();
        const deadline = deadlineIn(s.io, ms);
        while (!s.closed) {
            s.cond.waitTimeout(s.io, &s.mutex, deadline) catch return;
        }
    }

    // --- Threads

    fn readerMain(s: *Session) void {
        var buf: [64 * 1024]u8 = undefined;
        var sr = s.stream.reader(s.io, &buf);
        const r = &sr.interface;
        var reason: []const u8 = "the connection to the computer was lost";
        loop: while (true) {
            const head = blk: {
                var need: usize = 2;
                while (true) {
                    const avail = r.peek(need) catch break :loop;
                    const h = ws.parseServerHeader(avail) catch break :loop;
                    if (h) |hdr| break :blk hdr;
                    need += if (need < 4) 2 else 6;
                    if (need > 10) break :loop;
                }
            };
            r.toss(head.used);
            if (head.len > max_frame_bytes) break;
            const len: usize = @intCast(head.len);
            switch (head.opcode) {
                .binary => {
                    if (len < proto.frame_header_len) {
                        r.discardAll(len) catch break;
                        continue;
                    }
                    const fh = r.take(proto.frame_header_len) catch break;
                    const kind = fh[0];
                    const data_len = len - proto.frame_header_len;
                    if (kind != @backingInt(proto.FrameKind.jpeg)) {
                        r.discardAll(data_len) catch break;
                        continue;
                    }
                    const data = s.gpa.alloc(u8, data_len) catch {
                        r.discardAll(data_len) catch break;
                        continue;
                    };
                    r.readSliceAll(data) catch {
                        s.gpa.free(data);
                        break;
                    };
                    s.lock();
                    const old = s.frame;
                    s.frame = data;
                    s.frame_seq += 1;
                    s.cond.broadcast(s.io);
                    s.unlock();
                    if (old) |o| s.gpa.free(o);
                },
                .text => {
                    if (len > max_text_bytes) {
                        r.discardAll(len) catch break;
                        continue;
                    }
                    const msg = r.take(len) catch break;
                    if (s.onText(msg)) |why| {
                        reason = why;
                        break;
                    }
                },
                .close => {
                    r.discardAll(len) catch {};
                    reason = "the computer closed the connection";
                    break;
                },
                else => r.discardAll(len) catch break,
            }
        }
        s.setClosed(reason);
    }

    /// Handles a text message; returns the reason if the host ends the session.
    fn onText(s: *Session, msg: []const u8) ?[]const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, s.gpa, msg, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const o = parsed.value.object;
        const t = str(o, "t") orelse return null;
        if (std.mem.eql(u8, t, "ok")) {
            s.lock();
            defer s.unlock();
            copyInto(&s.host_name_buf, &s.host_name_len, str(o, "name") orelse "computer");
            copyInto(&s.os_buf, &s.os_len, str(o, "os") orelse "unknown");
            copyInto(&s.version_buf, &s.version_len, str(o, "version") orelse "?");
            s.can_text = if (o.get("text")) |v| v == .bool and v.bool else false;
            if (num(o, "w")) |w| s.frame_w = @intFromFloat(@max(0, w));
            if (num(o, "h")) |h| s.frame_h = @intFromFloat(@max(0, h));
            if (num(o, "cx")) |x| s.cursor_x = x;
            if (num(o, "cy")) |y| s.cursor_y = y;
            s.ok = true;
            s.cond.broadcast(s.io);
        } else if (std.mem.eql(u8, t, "size")) {
            s.lock();
            defer s.unlock();
            if (num(o, "w")) |w| s.frame_w = @intFromFloat(@max(0, w));
            if (num(o, "h")) |h| s.frame_h = @intFromFloat(@max(0, h));
        } else if (std.mem.eql(u8, t, "pong")) {
            s.lock();
            defer s.unlock();
            if (num(o, "cx")) |x| s.cursor_x = x;
            if (num(o, "cy")) |y| s.cursor_y = y;
        } else if (std.mem.eql(u8, t, "err")) {
            const fatal = if (o.get("fatal")) |v| v == .bool and v.bool else false;
            s.lock();
            defer s.unlock();
            if (fatal) {
                copyInto(&s.reason_buf, &s.reason_len, str(o, "msg") orelse "the computer refused the connection");
                s.closed = true;
                s.cond.broadcast(s.io);
                return "refused";
            }
            copyInto(&s.warn_buf, &s.warn_len, str(o, "msg") orelse "");
        } else if (std.mem.eql(u8, t, "bye")) {
            s.lock();
            defer s.unlock();
            copyInto(&s.reason_buf, &s.reason_len, str(o, "msg") orelse "the computer ended the session");
            s.closed = true;
            s.cond.broadcast(s.io);
            return "bye";
        }
        return null;
    }

    fn pingMain(s: *Session) void {
        while (true) {
            {
                s.lock();
                defer s.unlock();
                const deadline = deadlineIn(s.io, 1000);
                while (!s.closed) {
                    s.cond.waitTimeout(s.io, &s.mutex, deadline) catch break;
                }
                if (s.closed) return;
            }
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{{\"t\":\"ping\",\"ts\":{d}}}", .{Io.Clock.real.now(s.io).toMilliseconds()}) catch continue;
            s.sendText(msg) catch {
                s.setClosed("the connection to the computer was lost");
                return;
            };
        }
    }

    /// Ends the session and frees it.
    pub fn close(s: *Session) void {
        s.setClosed("disconnected");
        s.stream.shutdown(s.io, .both) catch {};
        if (s.reader) |t| t.join();
        if (s.pinger) |t| t.join();
        s.stream.close(s.io);
        if (s.frame) |f| s.gpa.free(f);
        s.gpa.destroy(s);
    }
};

pub const Target = struct {
    host: []const u8,
    port: u16 = default_port,
    code: []const u8,
};

/// "http://192.168.1.20:7700/#123456789" → host, port and code.
pub fn parseLink(link: []const u8) ?Target {
    var s = std.mem.trim(u8, link, " \t\r\n");
    if (std.mem.startsWith(u8, s, "http://")) s = s["http://".len..];
    if (std.mem.startsWith(u8, s, "https://")) return null; // the host speaks plain HTTP in the LAN
    const hash = std.mem.findScalar(u8, s, '#') orelse return null;
    const code = s[hash + 1 ..];
    var hostport = s[0..hash];
    if (std.mem.findScalar(u8, hostport, '/')) |i| hostport = hostport[0..i];
    var t = parseAddress(hostport) orelse return null;
    t.code = code;
    return t;
}

/// "my-pc.local", "192.168.1.20:7701", "[fe80::1]:7700" → host and port.
pub fn parseAddress(text: []const u8) ?Target {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, s, "http://")) s = s["http://".len..];
    if (std.mem.findScalar(u8, s, '/')) |i| s = s[0..i];
    if (s.len == 0) return null;
    if (s[0] == '[') {
        const end = std.mem.findScalar(u8, s, ']') orelse return null;
        const host = s[1..end];
        const rest = s[end + 1 ..];
        if (rest.len == 0) return .{ .host = host, .code = "" };
        if (rest[0] != ':') return null;
        return .{ .host = host, .port = std.fmt.parseInt(u16, rest[1..], 10) catch return null, .code = "" };
    }
    const colon = std.mem.findScalar(u8, s, ':');
    if (colon) |c| {
        // More than one colon and no brackets: a bare IPv6 address without a port.
        if (std.mem.findScalarPos(u8, s, c + 1, ':') != null) return .{ .host = s, .code = "" };
        return .{ .host = s[0..c], .port = std.fmt.parseInt(u16, s[c + 1 ..], 10) catch return null, .code = "" };
    }
    return .{ .host = s, .code = "" };
}

/// Why connect failed, in words for the agent (the host's own message when it refused).
pub const Failure = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn text(f: *const Failure) []const u8 {
        return f.buf[0..f.len];
    }
};

/// Connects, logs in with the code and waits for the host's "ok".
/// `agent` names the AI agent on the host's screen ("Claude Code").
pub fn connect(gpa: std.mem.Allocator, io: Io, target: Target, agent: []const u8, failure: *Failure) Error!*Session {
    const stream = try openStream(gpa, io, target);
    handshake(io, stream, target) catch |e| {
        stream.close(io);
        return e;
    };

    const s = gpa.create(Session) catch {
        stream.close(io);
        return error.OutOfMemory;
    };
    s.* = .{ .gpa = gpa, .io = io, .stream = stream };
    const printed = std.fmt.bufPrint(&s.address_buf, "{s}:{d}", .{ target.host, target.port }) catch s.address_buf[0..0];
    s.address_len = printed.len;
    s.reader = std.Thread.spawn(.{}, Session.readerMain, .{s}) catch {
        stream.close(io);
        gpa.destroy(s);
        return error.OutOfMemory;
    };

    var digits: [9]u8 = undefined;
    var nd: usize = 0;
    for (target.code) |c| {
        if (c >= '0' and c <= '9' and nd < digits.len) {
            digits[nd] = c;
            nd += 1;
        }
    }
    var label_buf: [64]u8 = undefined;
    var hello_buf: [256]u8 = undefined;
    const hello = std.fmt.bufPrint(&hello_buf, "{{\"t\":\"hello\",\"code\":\"{s}\",\"h264\":false,\"ai\":\"{s}\",\"agent\":\"RDC MCP\"}}", .{
        digits[0..nd],
        proto.jsonEscape(&label_buf, agent),
    }) catch unreachable;
    s.sendText(hello) catch {
        s.close();
        return error.ConnectFailed;
    };

    // The host answers "ok" (and then sends the current screen) or a refusal.
    {
        s.lock();
        defer s.unlock();
        const deadline = deadlineIn(io, 8000);
        while (!s.ok and !s.closed) {
            s.cond.waitTimeout(io, &s.mutex, deadline) catch break;
        }
    }
    if (!s.ok) {
        var why: [200]u8 = undefined;
        const reason = s.closedReason(&why);
        s.close();
        if (reason) |r| {
            failure.len = @min(r.len, failure.buf.len);
            @memcpy(failure.buf[0..failure.len], r[0..failure.len]);
            return error.Rejected;
        }
        return error.Timeout;
    }
    s.pinger = std.Thread.spawn(.{}, Session.pingMain, .{s}) catch null;
    return s;
}

const connect_timeout_ms = 6000;

/// A blocking connect on its own thread, so the agent gets an answer in 6 s even when the
/// address is a black hole (the OS would wait over a minute). An abandoned attempt closes its
/// own socket when it finally returns.
const Attempt = struct {
    io: Io,
    gpa: std.mem.Allocator,
    host_buf: [256]u8 = undefined,
    host_len: usize = 0,
    port: u16,
    mutex: Io.Mutex = .init,
    done: Io.Event = .unset,
    result: ?(Error!net.Stream) = null,
    abandoned: bool = false,
    refs: std.atomic.Value(u32) = .init(2),

    fn release(a: *Attempt) void {
        if (a.refs.fetchSub(1, .acq_rel) == 1) a.gpa.destroy(a);
    }

    fn main(a: *Attempt) void {
        defer a.release();
        const host = a.host_buf[0..a.host_len];
        const result: Error!net.Stream = blk: {
            if (net.IpAddress.parse(host, a.port)) |addr| {
                break :blk addr.connect(a.io, .{ .mode = .stream }) catch error.ConnectFailed;
            } else |_| {}
            const name = net.HostName.init(host) catch break :blk error.BadAddress;
            break :blk name.connect(a.io, a.port, .{ .mode = .stream }) catch error.ConnectFailed;
        };
        a.mutex.lockUncancelable(a.io);
        const abandoned = a.abandoned;
        if (!abandoned) a.result = result;
        a.mutex.unlock(a.io);
        if (abandoned) {
            if (result) |stream| stream.close(a.io) else |_| {}
        } else {
            a.done.set(a.io);
        }
    }
};

fn openStream(gpa: std.mem.Allocator, io: Io, target: Target) Error!net.Stream {
    if (target.host.len == 0 or target.host.len > 255) return error.BadAddress;
    const a = gpa.create(Attempt) catch return error.OutOfMemory;
    a.* = .{ .io = io, .gpa = gpa, .port = target.port };
    @memcpy(a.host_buf[0..target.host.len], target.host);
    a.host_len = target.host.len;
    const t = std.Thread.spawn(.{}, Attempt.main, .{a}) catch {
        gpa.destroy(a);
        return error.ConnectFailed;
    };
    t.detach();
    defer a.release();
    a.done.waitTimeout(io, deadlineIn(io, connect_timeout_ms)) catch {};
    a.mutex.lockUncancelable(io);
    defer a.mutex.unlock(io);
    if (a.result) |r| return r;
    a.abandoned = true;
    return error.Timeout;
}

fn handshake(io: Io, stream: net.Stream, target: Target) Error!void {
    var key_raw: [16]u8 = undefined;
    io.random(&key_raw);
    var key_buf: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, &key_raw);
    {
        var wbuf: [512]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        const w = &sw.interface;
        const bracket = std.mem.findScalar(u8, target.host, ':') != null;
        w.print("GET /ws HTTP/1.1\r\nHost: {s}{s}{s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: RDC-MCP\r\n\r\n", .{
            if (bracket) "[" else "",
            target.host,
            if (bracket) "]" else "",
            target.port,
            key,
        }) catch return error.HandshakeFailed;
        w.flush() catch return error.HandshakeFailed;
    }
    // Read the response head byte by byte: nothing of the WebSocket stream may be swallowed
    // by a buffer that goes away with this function.
    var head: [2048]u8 = undefined;
    var n: usize = 0;
    var rbuf: [1]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;
    while (n < head.len) {
        head[n] = r.takeByte() catch return error.HandshakeFailed;
        n += 1;
        if (n >= 4 and std.mem.eql(u8, head[n - 4 .. n], "\r\n\r\n")) break;
    } else return error.HandshakeFailed;
    const resp = head[0..n];
    if (!std.mem.startsWith(u8, resp, "HTTP/1.1 101")) return error.HandshakeFailed;
    var expect_buf: [28]u8 = undefined;
    const expect = ws.acceptKey(key, &expect_buf);
    var lines = std.mem.splitSequence(u8, resp, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "sec-websocket-accept")) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), expect)) return;
        return error.HandshakeFailed;
    }
    return error.HandshakeFailed;
}

// --- Helpers

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn num(o: std.json.ObjectMap, k: []const u8) ?f64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn copyInto(buf: []u8, len: *usize, src: []const u8) void {
    const n = @min(buf.len, src.len);
    @memcpy(buf[0..n], src[0..n]);
    len.* = n;
}

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn deadlineIn(io: Io, ms: i64) Io.Timeout {
    return (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }).toDeadline(io);
}

test "client: links and addresses" {
    const t = parseLink("http://192.168.0.233:7795/#391378076").?;
    try std.testing.expectEqualStrings("192.168.0.233", t.host);
    try std.testing.expectEqual(@as(u16, 7795), t.port);
    try std.testing.expectEqualStrings("391378076", t.code);
    const d = parseLink("my-pc.local/#123456789").?;
    try std.testing.expectEqualStrings("my-pc.local", d.host);
    try std.testing.expectEqual(default_port, d.port);
    try std.testing.expectEqual(@as(?Target, null), parseLink("http://10.0.0.2:7700/"));
    const a = parseAddress("[fe80::1]:7701").?;
    try std.testing.expectEqualStrings("fe80::1", a.host);
    try std.testing.expectEqual(@as(u16, 7701), a.port);
    try std.testing.expectEqualStrings("fe80::1", parseAddress("fe80::1").?.host);
    try std.testing.expectEqual(@as(u16, 7700), parseAddress("10.0.0.5").?.port);
    try std.testing.expectEqual(@as(?Target, null), parseAddress("10.0.0.5:http"));
}
