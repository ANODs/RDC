//! Host: the computer's screen → viewers in a browser by link or code.
//! On the local network HTTP serves the viewer page and WebSocket carries frames
//! (H.264 or JPEG) and input. From anywhere the page comes from GitHub Pages, finds
//! the host through public MQTT brokers (net/signal.zig) and connects over a WebRTC
//! data channel (net/webrtc.zig) that carries the same messages.
//! The code is shared by all OSes: network, threads and time come from std.Io, the
//! rest from the platform layer (src/platform.zig).
//!
//! Threads: accepting connections; one per connection (reading); one per WebRTC
//! session; one writer per viewer; one per signaling broker; housekeeping
//! (permissions, status, silence, updates). Frames come from the encoder thread and
//! are handed out to the viewers' queues. A viewer that falls behind skips frames
//! instead of piling up latency.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const plat = @import("platform.zig");
const ws = @import("net/ws.zig");
const http = @import("net/http.zig");
const dtls = @import("net/dtls.zig");
const signal = @import("net/signal.zig");
const totp = @import("core/totp.zig");
const qr = @import("core/qr.zig");
const webrtc = @import("net/webrtc.zig");
const proto = @import("core/proto.zig");
const keymap = @import("core/keymap.zig");
const Code = @import("core/code.zig").Code;
const update = @import("update.zig");
const web = @import("web");

pub const version = update.current_version;
pub const max_viewers = 4;

/// The camera's media source DLL, embedded on Windows (build.zig); empty elsewhere.
const camera_dll: []const u8 = if (builtin.os.tag == .windows) @embedFile("camera_dll") else "";
pub fn cameraDll() ?[*]const u8 {
    return if (camera_dll.len > 0) camera_dll.ptr else null;
}
pub fn cameraDllLen() usize {
    return camera_dll.len;
}
/// WebRTC sessions at once, admitted or still connecting.
const max_rtc = max_viewers + 4;
/// The longest --remote-url: the link adds the code and the key, and the Windows window holds 255 characters.
pub const max_remote_url_len = 200;
const max_remote_link_len = max_remote_url_len + "#123456789-".len + signal.salt_text_len;
/// An offer refused for its clock gets an answer at most this often: it may be a replay.
const clock_reply_every_us: u64 = 5_000_000;
const queue_cap = 16;
const max_frames_queued = 6;
const max_ws_payload = 16 * 1024;
const capture_idle_stop_us: u64 = 10_000_000;
const lockout_us: u64 = 30_000_000;
const silence_us: u64 = 30_000_000; // the viewer pings once a second
/// The H.264 bitrate follows the slowest viewer: down when frames have to be dropped, slowly back up.
const max_bitrate: c_int = 10_000_000;
const min_bitrate: c_int = 800_000;
const os_name = @tagName(builtin.os.tag);

pub const Options = struct {
    port: u16 = 7700,
    max_width: c_int = 1920,
    fps: c_int = 60,
    ui: bool = true,
    /// For development: take the viewer page from disk instead of the binary.
    web_dir: ?[]const u8 = null,
    /// For testing updates: where to get latest.json and the archive instead of GitHub releases.
    update_url: ?[]const u8 = null,
    /// Connections from anywhere: signaling through public MQTT brokers, then WebRTC.
    remote: bool = true,
    /// The page the link from anywhere opens; for testing, any copy of web/ served over https or localhost.
    remote_url: []const u8 = "https://anods.github.io/RDC/",
    /// Started by the OS at login: the window stays hidden (the platform layer reads the flag itself).
    login: bool = false,
};

/// How long a browser that entered an authenticator code may reconnect without a new one.
const resume_us: u64 = 12 * std.time.us_per_hour;
const max_resume = 8;
const Resume = struct { token: [16]u8 = @splat(0), expires_us: u64 = 0 };

/// Where an offer came from: the link with the code, or the permanent link.
const Port = struct { host: *Host, permanent: bool };

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return;
    buf[s.len] = 0;
    plat.rdc_log(buf[0..s.len :0].ptr);
}

pub fn nowUs(io: Io) u64 {
    const t = Io.Clock.awake.now(io);
    return @intCast(@divTrunc(t.nanoseconds, 1000));
}

/// Wall-clock milliseconds since 1970, as Date.now() in the browser.
fn realMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// This OS's key code for a HID code from the network.
fn platformKey(usage: u16) ?c_int {
    return switch (builtin.os.tag) {
        .macos => if (keymap.macKeycode(usage)) |k| @intCast(k) else null,
        .windows => if (keymap.winScancode(usage)) |k| @intCast(k) else null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Messages: bytes ready to send (WebSocket header + data) with a reference
// count — one frame goes to every viewer without copying.

const Msg = struct {
    refs: std.atomic.Value(u32),
    bytes: []u8,
    kind: Kind,
    /// The WebSocket header at the start of bytes; a data channel sends only what follows it.
    hdr_len: u8 = 0,
    opcode: ws.Opcode = .binary,

    const Kind = enum { control, h264_key, h264_delta, jpeg };

    fn create(gpa: std.mem.Allocator, kind: Kind, size: usize) ?*Msg {
        const m = gpa.create(Msg) catch return null;
        const bytes = gpa.alloc(u8, size) catch {
            gpa.destroy(m);
            return null;
        };
        m.* = .{ .refs = .init(1), .bytes = bytes, .kind = kind };
        return m;
    }

    fn text(gpa: std.mem.Allocator, opcode: ws.Opcode, data: []const u8) ?*Msg {
        var hdr: [10]u8 = undefined;
        const h = ws.header(&hdr, opcode, data.len);
        const m = create(gpa, .control, h.len + data.len) orelse return null;
        @memcpy(m.bytes[0..h.len], h);
        @memcpy(m.bytes[h.len..], data);
        m.hdr_len = @intCast(h.len);
        m.opcode = opcode;
        return m;
    }

    fn payload(m: *const Msg) []const u8 {
        return m.bytes[m.hdr_len..];
    }

    fn retain(m: *Msg) void {
        _ = m.refs.fetchAdd(1, .monotonic);
    }

    fn release(m: *Msg, gpa: std.mem.Allocator) void {
        if (m.refs.fetchSub(1, .acq_rel) == 1) {
            gpa.free(m.bytes);
            gpa.destroy(m);
        }
    }
};

const Peer = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn fromAddress(addr: net.IpAddress) Peer {
        var p: Peer = .{};
        const full = std.fmt.bufPrint(&p.buf, "{f}", .{addr}) catch return p;
        var s = full;
        // "1.2.3.4:5678" → "1.2.3.4", "[::1]:5678" → "::1"
        if (std.mem.lastIndexOfScalar(u8, s, ':')) |i| s = s[0..i];
        if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') s = s[1 .. s.len - 1];
        std.mem.copyForwards(u8, p.buf[0..s.len], s);
        p.len = s.len;
        return p;
    }

    fn fromText(text: []const u8) Peer {
        var p: Peer = .{};
        p.len = @min(text.len, p.buf.len);
        @memcpy(p.buf[0..p.len], text[0..p.len]);
        return p;
    }

    fn str(p: *const Peer) []const u8 {
        return p.buf[0..p.len];
    }
};

/// How a viewer is connected: WebSocket on the local network or a WebRTC data channel from anywhere.
const Link = union(enum) {
    ws: net.Stream,
    rtc: *webrtc.Session,

    /// Wakes the connection's reader, or ends the session. `graceful` lets queued messages (a "bye") get through.
    fn shutdown(l: Link, io: Io, graceful: bool) void {
        switch (l) {
            .ws => |s| s.shutdown(io, .both) catch {},
            .rtc => |s| if (graceful) s.closeAfter(1000) else s.close(),
        }
    }
};

fn setNoDelay(stream: net.Stream) void {
    if (builtin.os.tag == .windows) return;
    std.posix.setsockopt(stream.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
}

// ---------------------------------------------------------------------------
// Viewer: outgoing message queue and writer thread

const Viewer = struct {
    host: *Host,
    link: Link,
    peer: Peer,
    h264: bool,
    /// Came through the permanent link.
    permanent: bool = false,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: [queue_cap]*Msg = undefined,
    head: usize = 0,
    count: usize = 0,
    frames: usize = 0,
    need_key: bool = true,
    closing: bool = false, // send what is queued, then close
    aborted: bool = false, // close right away
    last_us: std.atomic.Value(u64) = .init(0),
    writer: ?std.Thread = null,
    /// Name of the AI agent behind this viewer (rdc mcp), empty for a person.
    ai_buf: [48]u8 = undefined,
    ai_len: usize = 0,
    /// A JPEG frame from the viewer's camera, put together from pieces on this viewer's thread;
    /// the buffer is allocated on the first piece.
    cam_buf: []u8 = &.{},
    cam: proto.CameraAssembler = .{},

    fn ai(v: *const Viewer) []const u8 {
        return v.ai_buf[0..v.ai_len];
    }

    /// Keeps a safe display name: printable ASCII without quotes and backslashes.
    fn setAi(v: *Viewer, name: []const u8) void {
        v.ai_len = 0;
        for (name) |c| {
            if (v.ai_len == v.ai_buf.len) break;
            if (c < 0x20 or c > 0x7E or c == '"' or c == '\\') continue;
            v.ai_buf[v.ai_len] = c;
            v.ai_len += 1;
        }
        if (v.ai_len == 0 and name.len > 0) {
            const fallback = "AI agent";
            @memcpy(v.ai_buf[0..fallback.len], fallback);
            v.ai_len = fallback.len;
        }
    }

    fn lock(v: *Viewer) void {
        v.mutex.lockUncancelable(v.host.io);
    }
    fn unlock(v: *Viewer) void {
        v.mutex.unlock(v.host.io);
    }

    /// Queues a message; takes over the reference to m.
    fn push(v: *Viewer, m: *Msg) void {
        const gpa = v.host.gpa;
        v.lock();
        defer v.unlock();
        if (v.closing or v.aborted) return m.release(gpa);
        switch (m.kind) {
            .h264_delta => if (v.need_key) return m.release(gpa),
            .h264_key => v.need_key = false,
            else => {},
        }
        const is_frame = m.kind != .control;
        if (is_frame and v.frames >= max_frames_queued) {
            if (m.kind == .jpeg) {
                // JPEG: only the newest frame matters — replace the last JPEG in the queue.
                var i = v.count;
                while (i > 0) {
                    i -= 1;
                    const idx = (v.head + i) % queue_cap;
                    if (v.queue[idx].kind == .jpeg) {
                        v.queue[idx].release(gpa);
                        v.queue[idx] = m;
                        return;
                    }
                }
            }
            // H.264: the viewer is falling behind — skip until the next keyframe.
            v.need_key = true;
            _ = v.host.drops.fetchAdd(1, .monotonic);
            plat.rdc_request_keyframe();
            return m.release(gpa);
        }
        if (v.count == queue_cap) return m.release(gpa);
        v.queue[(v.head + v.count) % queue_cap] = m;
        v.count += 1;
        if (is_frame) v.frames += 1;
        v.cond.signal(v.host.io);
    }

    fn pushText(v: *Viewer, payload: []const u8) void {
        const m = Msg.text(v.host.gpa, .text, payload) orelse return;
        v.push(m);
    }

    /// Which of this viewer's devices the computer takes now, and why not.
    fn pushMedia(v: *Viewer, mic: bool, camera: bool, msg: []const u8) void {
        var esc: [200]u8 = undefined;
        var buf: [320]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"t\":\"media\",\"mic\":{},\"camera\":{},\"msg\":\"{s}\"}}", .{ mic, camera, proto.jsonEscape(&esc, msg) }) catch return;
        v.pushText(json);
    }

    fn pop(v: *Viewer) ?*Msg {
        v.lock();
        defer v.unlock();
        while (v.count == 0 and !v.closing and !v.aborted) v.cond.waitUncancelable(v.host.io, &v.mutex);
        if (v.aborted or v.count == 0) return null;
        const m = v.queue[v.head];
        v.head = (v.head + 1) % queue_cap;
        v.count -= 1;
        if (m.kind != .control) v.frames -= 1;
        return m;
    }

    fn finish(v: *Viewer) void {
        v.lock();
        v.closing = true;
        v.cond.signal(v.host.io);
        v.unlock();
    }

    fn abort(v: *Viewer) void {
        v.lock();
        v.aborted = true;
        v.cond.signal(v.host.io);
        v.unlock();
    }

    fn drain(v: *Viewer) void {
        v.lock();
        defer v.unlock();
        while (v.count > 0) {
            v.queue[v.head].release(v.host.gpa);
            v.head = (v.head + 1) % queue_cap;
            v.count -= 1;
        }
        v.frames = 0;
    }

    fn writerMain(v: *Viewer) void {
        const io = v.host.io;
        switch (v.link) {
            .ws => |stream| {
                var buf: [16 * 1024]u8 = undefined;
                var sw = stream.writer(io, &buf);
                const w = &sw.interface;
                while (v.pop()) |m| {
                    const ok = blk: {
                        w.writeAll(m.bytes) catch break :blk false;
                        w.flush() catch break :blk false;
                        break :blk true;
                    };
                    m.release(v.host.gpa);
                    if (!ok) break;
                }
            },
            .rtc => |session| while (v.pop()) |m| {
                // A WebSocket pong has no meaning on a data channel.
                const ok = m.opcode == .pong or if (session.send(m.opcode == .binary, m.payload())) true else |_| false;
                m.release(v.host.gpa);
                if (!ok) break;
            },
        }
        v.lock();
        const graceful = v.closing and !v.aborted;
        v.aborted = true;
        v.cond.signal(io);
        v.unlock();
        v.link.shutdown(io, graceful); // wakes this connection's reader, or ends the WebRTC session
    }
};

// ---------------------------------------------------------------------------
// Host

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
    mutex: Io.Mutex = .init,
    viewers: [max_viewers]?*Viewer = @splat(null),
    code: Code,
    failed: u32 = 0,
    locked_until_us: u64 = 0,
    frame_w: c_int = 0,
    frame_h: c_int = 0,
    port: u16 = 0,
    server: net.Server = undefined,
    ip: [64]u8 = undefined,
    ip_len: usize = 0,
    name: [128]u8 = undefined,
    name_len: usize = 0,
    capture_mutex: Io.Mutex = .init,
    capturing: bool = false,
    idle_since_us: u64 = 0,
    /// H.264 frames dropped for a slow viewer since the last housekeeping tick.
    drops: std.atomic.Value(u32) = .init(0),
    bitrate: c_int = max_bitrate,
    calm_ticks: u32 = 0,
    updater: update.Updater,
    /// The second half of the link from anywhere; new with every code.
    salt: [signal.salt_len]u8,
    /// The DTLS certificate of this run.
    identity: dtls.Identity = undefined,
    signal: ?*signal.Signal = null,
    rtc: [max_rtc]?*RtcConn = @splat(null),
    /// Offers already taken (the same offer arrives through every broker, and may be replayed)
    /// and when the last sessions started.
    guard: signal.Guard = .{},
    last_clock_reply_us: u64 = 0,
    /// Whether the link from anywhere is shown; only the housekeeping thread uses it.
    remote_shown: bool = false,
    /// Keeps the "from anywhere" part of the window in step when two threads refresh it.
    remote_ui_mutex: Io.Mutex = .init,
    /// The viewer whose microphone and camera this computer uses right now, and which of them (under mutex).
    media_owner: ?*Viewer = null,
    media_mic: bool = false,
    media_cam: bool = false,
    /// Permanent access (core/totp.zig; under mutex): null — off.
    perm: ?totp.Identity = null,
    perm_signal: ?*signal.Signal = null,
    port_code: Port = undefined,
    port_perm: Port = undefined,
    /// The time step of the last authenticator code that let someone in: a code works once.
    otp_last_step: u64 = 0,
    otp_guard: totp.Guard = .{},
    resumes: [max_resume]Resume = @splat(.{}),

    fn lock(h: *Host) void {
        h.mutex.lockUncancelable(h.io);
    }
    fn unlock(h: *Host) void {
        h.mutex.unlock(h.io);
    }

    fn create(gpa: std.mem.Allocator, io: Io, opts: Options) !*Host {
        const h = try gpa.create(Host);
        h.* = .{ .gpa = gpa, .io = io, .opts = opts, .code = newCode(io), .salt = newSalt(io), .updater = update.Updater.init(gpa, io, opts.update_url, opts.ui) };
        h.port_code = .{ .host = h, .permanent = false };
        h.port_perm = .{ .host = h, .permanent = true };
        if (plat.rdc_lan_ipv4(&h.ip, h.ip.len) == 0) {
            h.ip_len = std.mem.indexOfScalar(u8, &h.ip, 0) orelse 0;
        } else {
            const fallback = "127.0.0.1";
            @memcpy(h.ip[0..fallback.len], fallback);
            h.ip_len = fallback.len;
        }
        if (plat.rdc_computer_name(&h.name, h.name.len) == 0) {
            h.name_len = std.mem.indexOfScalar(u8, &h.name, 0) orelse 0;
        } else {
            const fallback = "RDC";
            @memcpy(h.name[0..fallback.len], fallback);
            h.name_len = fallback.len;
        }
        return h;
    }

    fn newCode(io: Io) Code {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        return Code.fromRandom(std.mem.readInt(u64, &bytes, .little));
    }

    fn newSalt(io: Io) [signal.salt_len]u8 {
        var salt: [signal.salt_len]u8 = undefined;
        io.random(&salt);
        return salt;
    }

    /// https://anods.github.io/RDC/#<code>-<key>; under the lock.
    fn remoteLinkLocked(h: *Host, buf: *[max_remote_link_len]u8) []const u8 {
        var key: [signal.salt_text_len]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&key, &h.salt);
        // `run` refuses a --remote-url that would not fit.
        return std.fmt.bufPrint(buf, "{s}#{s}-{s}", .{ h.opts.remote_url, &h.code.digits, &key }) catch unreachable;
    }

    fn lanIp(h: *Host) ?[4]u8 {
        const a = net.Ip4Address.parse(h.ip[0..h.ip_len], 0) catch return null;
        return a.bytes;
    }

    fn listen(h: *Host) !void {
        var port = h.opts.port;
        var attempt: u16 = 0;
        while (attempt < 20) : ({
            attempt += 1;
            port +%= 1;
        }) {
            const addr = net.IpAddress.parse("0.0.0.0", port) catch unreachable;
            h.server = addr.listen(h.io, .{}) catch continue;
            h.port = port;
            return;
        }
        return error.NoFreePort;
    }

    fn serve(h: *Host) void {
        while (true) {
            const stream = h.server.accept(h.io) catch |e| {
                log("accepting connection: {t}", .{e});
                h.io.sleep(.fromMilliseconds(100), .awake) catch {};
                continue;
            };
            const t = std.Thread.spawn(.{}, connectionMain, .{ h, stream }) catch {
                stream.close(h.io);
                continue;
            };
            t.detach();
        }
    }

    fn connectionMain(h: *Host, stream: net.Stream) void {
        const io = h.io;
        defer stream.close(io);
        setNoDelay(stream);
        const peer = Peer.fromAddress(stream.socket.address);
        var rbuf: [64 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        const r = &sr.interface;
        const head_len = while (true) {
            if (std.mem.indexOf(u8, r.buffered(), "\r\n\r\n")) |i| break i + 4;
            if (r.bufferedLen() >= 16 * 1024) return;
            r.fillMore() catch return;
        };
        const req = http.parseHead(r.buffered()[0..head_len]) orelse return;
        const eql = std.mem.eql;
        if (!eql(u8, req.method, "GET")) return h.respond(stream, "405 Method Not Allowed", "text/plain; charset=utf-8", "");
        if (eql(u8, req.path, "/ws")) {
            if (!req.upgrade_websocket) return h.respond(stream, "400 Bad Request", "text/plain; charset=utf-8", "");
            var key_buf: [64]u8 = undefined;
            const key_src = req.websocket_key.?;
            if (key_src.len > key_buf.len) return;
            @memcpy(key_buf[0..key_src.len], key_src);
            r.toss(head_len);
            return h.websocket(stream, r, peer, key_buf[0..key_src.len]);
        }
        if (eql(u8, req.path, "/") or eql(u8, req.path, "/index.html"))
            return h.serveWeb(stream, "index.html", "text/html; charset=utf-8", web.index_html);
        if (eql(u8, req.path, "/viewer.js"))
            return h.serveWeb(stream, "viewer.js", "text/javascript; charset=utf-8", web.viewer_js);
        if (eql(u8, req.path, "/icon.png"))
            return h.serveWeb(stream, "icon.png", "image/png", web.icon_png);
        h.respond(stream, "404 Not Found", "text/plain; charset=utf-8", "Not found");
    }

    fn serveWeb(h: *Host, stream: net.Stream, name: []const u8, content_type: []const u8, embedded: []const u8) void {
        if (h.opts.web_dir) |dir| {
            var path_buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{s}/{s}", .{ dir, name })) |path| {
                path_buf[path.len] = 0;
                var len: usize = 0;
                if (plat.rdc_read_file(path_buf[0..path.len :0].ptr, &len)) |ptr| {
                    defer plat.free(ptr);
                    return h.respond(stream, "200 OK", content_type, ptr[0..len]);
                }
            } else |_| {}
        }
        h.respond(stream, "200 OK", content_type, embedded);
    }

    fn respond(h: *Host, stream: net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
        var buf: [1024]u8 = undefined;
        var sw = stream.writer(h.io, &buf);
        const w = &sw.interface;
        w.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
        w.writeAll(body) catch return;
        w.flush() catch {};
    }

    /// Writes a WebSocket text frame directly — only while the connection has no writer.
    fn sendDirect(h: *Host, stream: net.Stream, text: []const u8) void {
        var buf: [512]u8 = undefined;
        var sw = stream.writer(h.io, &buf);
        const w = &sw.interface;
        var hdr: [10]u8 = undefined;
        w.writeAll(ws.header(&hdr, .text, text.len)) catch return;
        w.writeAll(text) catch return;
        w.flush() catch {};
    }

    /// A fatal error for a connection that has no viewer yet; the connection ends after it.
    fn sendError(h: *Host, link: Link, text: []const u8) void {
        var out: [256]u8 = undefined;
        const json = std.fmt.bufPrint(&out, "{{\"t\":\"err\",\"fatal\":true,\"msg\":\"{s}\"}}", .{text}) catch return;
        switch (link) {
            .ws => |stream| h.sendDirect(stream, json),
            .rtc => |s| {
                s.sendText(json);
                s.closeAfter(1000);
            },
        }
    }

    fn websocket(h: *Host, stream: net.Stream, r: *Io.Reader, peer: Peer, key: []const u8) void {
        var accept_buf: [28]u8 = undefined;
        {
            var buf: [256]u8 = undefined;
            var sw = stream.writer(h.io, &buf);
            const w = &sw.interface;
            w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
                "Connection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{ws.acceptKey(key, &accept_buf)}) catch return;
            w.flush() catch return;
        }

        var viewer: ?*Viewer = null;
        defer if (viewer) |v| h.removeViewer(v);
        while (true) {
            while (true) {
                const parsed = ws.parse(r.buffered(), max_ws_payload) catch return;
                const p = parsed orelse break;
                if (!p.frame.fin or p.frame.opcode == .continuation) return;
                if (!h.onMessage(.{ .ws = stream }, peer, &viewer, p.frame.opcode, p.frame.payload, false)) return;
                r.toss(p.used);
            }
            if (r.bufferedLen() == r.buffer.len) return;
            r.fillMore() catch return;
        }
    }

    /// One message from a viewer, whatever the link. false — end the connection.
    fn onMessage(h: *Host, link: Link, peer: Peer, viewer: *?*Viewer, opcode: ws.Opcode, payload: []const u8, permanent: bool) bool {
        if (viewer.*) |v| v.last_us.store(nowUs(h.io), .monotonic);
        switch (opcode) {
            .text => {
                const msg = payload;
                const t = proto.jsonString(msg, "t") orelse return true;
                if (std.mem.eql(u8, t, "hello")) {
                    if (viewer.* == null) viewer.* = h.admit(link, peer, msg, permanent) orelse return false;
                } else if (std.mem.eql(u8, t, "ping")) {
                    const v = viewer.* orelse return true;
                    var cx: f64 = 0.5;
                    var cy: f64 = 0.5;
                    plat.rdc_cursor_pos(&cx, &cy);
                    var out: [128]u8 = undefined;
                    const pong = std.fmt.bufPrint(&out, "{{\"t\":\"pong\",\"ts\":{s},\"cx\":{d:.4},\"cy\":{d:.4}}}", .{ proto.jsonNumber(msg, "ts") orelse "0", cx, cy }) catch return true;
                    v.pushText(pong);
                } else if (std.mem.eql(u8, t, "stop_ai")) {
                    const v = viewer.* orelse return true;
                    log("viewer {s} stopped the AI agents", .{v.peer.str()});
                    h.stopAi("A viewer stopped the AI agent");
                } else if (std.mem.eql(u8, t, "media")) {
                    const v = viewer.* orelse return true;
                    h.setMedia(v, proto.jsonTrue(msg, "mic"), proto.jsonTrue(msg, "camera"));
                }
                return true;
            },
            .binary => {
                const v = viewer.* orelse return false;
                if (proto.decodeInput(payload)) |in| switch (in) {
                    .audio, .camera => h.onMedia(v, in),
                    else => applyInput(in),
                };
                return true;
            },
            .ping => {
                if (viewer.*) |v| {
                    if (Msg.text(h.gpa, .pong, payload)) |m| v.push(m);
                }
                return true;
            },
            .close => return false,
            else => return true,
        }
    }

    fn admit(h: *Host, link: Link, peer: Peer, hello: []const u8, permanent: bool) ?*Viewer {
        const now = nowUs(h.io);
        var resume_text: [32]u8 = undefined;
        var resume_len: usize = 0;
        h.lock();
        if (permanent) {
            var buf: [96]u8 = undefined;
            if (h.admitPermanentLocked(hello, now, &resume_text, &buf)) |refusal| {
                h.unlock();
                log("permanent link, {s}: {s}", .{ peer.str(), refusal });
                h.sendError(link, refusal);
                return null;
            }
            resume_len = resume_text.len;
        } else if (now < h.locked_until_us) {
            h.unlock();
            h.sendError(link, "Too many wrong attempts — wait half a minute");
            return null;
        }
        if (!permanent and !h.code.matches(proto.jsonString(hello, "code") orelse "")) {
            h.failed += 1;
            if (h.failed >= 5) h.locked_until_us = now + lockout_us;
            h.unlock();
            log("wrong code from {s}", .{peer.str()});
            h.sendError(link, "Wrong code");
            return null;
        }
        if (!permanent) h.failed = 0;
        var slot: ?usize = null;
        for (h.viewers, 0..) |existing, i| {
            if (existing == null) {
                slot = i;
                break;
            }
        }
        const index = slot orelse {
            h.unlock();
            h.sendError(link, "Four viewers are already connected — no more can join");
            return null;
        };
        const v = h.gpa.create(Viewer) catch {
            h.unlock();
            return null;
        };
        const can_h264 = plat.rdc_codec_caps() & 1 != 0;
        v.* = .{ .host = h, .link = link, .peer = peer, .h264 = can_h264 and proto.jsonTrue(hello, "h264"), .permanent = permanent };
        if (proto.jsonString(hello, "ai")) |name| v.setAi(name);
        v.last_us.store(now, .monotonic);
        var name_buf: [160]u8 = undefined;
        var ok_buf: [512]u8 = undefined;
        var cx: f64 = 0.5;
        var cy: f64 = 0.5;
        plat.rdc_cursor_pos(&cx, &cy);
        const media = plat.rdc_media_status();
        const ok = std.fmt.bufPrint(&ok_buf, "{{\"t\":\"ok\",\"w\":{d},\"h\":{d},\"os\":\"{s}\",\"name\":\"{s}\",\"codec\":\"{s}\",\"version\":\"{s}\",\"text\":true,\"cx\":{d:.4},\"cy\":{d:.4},\"mic\":{},\"camera\":{},\"resume\":\"{s}\"}}", .{
            h.frame_w,
            h.frame_h,
            os_name,
            proto.jsonEscape(&name_buf, h.name[0..h.name_len]),
            if (v.h264) "h264" else "jpeg",
            version,
            cx,
            cy,
            media & plat.media_mic != 0,
            media & plat.media_camera != 0,
            resume_text[0..resume_len],
        }) catch "{\"t\":\"ok\"}";
        v.pushText(ok);
        v.writer = std.Thread.spawn(.{}, Viewer.writerMain, .{v}) catch {
            v.drain();
            h.gpa.destroy(v);
            h.unlock();
            return null;
        };
        h.viewers[index] = v;
        h.updateCodecsLocked();
        h.unlock();

        const over: []const u8 = if (permanent) ", WebRTC, permanent link" else if (link == .rtc) ", WebRTC" else "";
        if (v.ai_len > 0) {
            log("AI agent {s} connected from {s}{s}", .{ v.ai(), peer.str(), over });
        } else {
            log("viewer {s} connected ({s}{s})", .{ peer.str(), if (v.h264) "H.264" else "JPEG", over });
        }
        h.ensureCapture();
        plat.rdc_request_keyframe();
        h.updateStatus();
        h.broadcastViewers();
        return v;
    }

    /// The permanent link: the browser shows either an authenticator code or the token an earlier
    /// code gave it. null — let it in, `resume_text` is its token; otherwise why not. Under the lock.
    fn admitPermanentLocked(h: *Host, hello: []const u8, now: u64, resume_text: *[32]u8, buf: *[96]u8) ?[]const u8 {
        const id = h.perm orelse return "Permanent access is off on the computer";
        if (proto.jsonString(hello, "resume")) |text| {
            var token: [16]u8 = undefined;
            if (text.len == 32) {
                if (std.fmt.hexToBytes(&token, text)) |_| {
                    for (&h.resumes) |*r| {
                        if (r.expires_us > now and std.crypto.timing_safe.eql([16]u8, r.token, token)) {
                            resume_text.* = text[0..32].*;
                            return null;
                        }
                    }
                } else |_| {}
            }
            return "Enter a new code from your authenticator app";
        }
        const wait = h.otp_guard.waitUs(now);
        if (wait > 0) {
            const minutes = (wait + 59 * std.time.us_per_s) / std.time.us_per_min;
            if (wait <= totp.Guard.burst_us) return "Too many wrong codes — wait half a minute";
            return std.fmt.bufPrint(buf, "Too many wrong codes — the permanent link is locked for {d} min", .{minutes}) catch "Too many wrong codes";
        }
        switch (totp.verify(&id.secret, proto.jsonString(hello, "otp") orelse "", @divFloor(realMs(h.io), 1000), h.otp_last_step)) {
            .ok => |step| h.otp_last_step = step,
            .used => return "This code was used already — wait for the next one",
            .wrong => {
                h.otp_guard.failed(now);
                return "Wrong code";
            },
        }
        // A token for reconnecting, in place of the oldest one.
        var slot = &h.resumes[0];
        for (&h.resumes) |*r| {
            if (r.expires_us < slot.expires_us) slot = r;
        }
        h.io.random(&slot.token);
        slot.expires_us = now + resume_us;
        resume_text.* = std.fmt.bytesToHex(slot.token, .lower);
        return null;
    }

    fn removeViewer(h: *Host, v: *Viewer) void {
        h.dropMedia(v);
        h.lock();
        var left: usize = 0;
        for (&h.viewers) |*s| {
            if (s.* == v) s.* = null;
            if (s.* != null) left += 1;
        }
        if (left == 0) h.idle_since_us = nowUs(h.io);
        h.updateCodecsLocked();
        h.unlock();

        v.abort();
        if (v.writer) |t| t.join();
        v.drain();
        if (v.cam_buf.len > 0) h.gpa.free(v.cam_buf);
        plat.rdc_release_all();
        if (v.ai_len > 0) {
            log("AI agent {s} ({s}) disconnected", .{ v.ai(), v.peer.str() });
        } else {
            log("viewer {s} disconnected", .{v.peer.str()});
        }
        h.gpa.destroy(v);
        h.updateStatus();
        h.broadcastViewers();
    }

    /// Tells every viewer who is connected, so a person watching sees that an AI agent is in control.
    fn broadcastViewers(h: *Host) void {
        var buf: [400]u8 = undefined;
        var n: usize = 0;
        h.lock();
        defer h.unlock();
        var count: usize = 0;
        for (h.viewers) |maybe| {
            if (maybe != null) count += 1;
        }
        const head = std.fmt.bufPrint(&buf, "{{\"t\":\"viewers\",\"n\":{d},\"ai\":[", .{count}) catch return;
        n = head.len;
        var first = true;
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            if (v.ai_len == 0) continue;
            const part = std.fmt.bufPrint(buf[n..], "{s}\"{s}\"", .{ if (first) "" else ",", v.ai() }) catch break;
            n += part.len;
            first = false;
        }
        const tail = std.fmt.bufPrint(buf[n..], "]}}", .{}) catch return;
        n += tail.len;
        h.broadcastTextLocked(buf[0..n]);
    }

    /// Disconnects the AI agents; people stay connected.
    fn stopAi(h: *Host, reason: []const u8) void {
        var out: [200]u8 = undefined;
        const bye = std.fmt.bufPrint(&out, "{{\"t\":\"bye\",\"msg\":\"{s}\"}}", .{reason}) catch "{\"t\":\"bye\"}";
        h.lock();
        defer h.unlock();
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            if (v.ai_len == 0) continue;
            v.pushText(bye);
            v.finish();
        }
    }

    fn viewerCount(h: *Host) usize {
        h.lock();
        defer h.unlock();
        var n: usize = 0;
        for (h.viewers) |maybe| {
            if (maybe != null) n += 1;
        }
        return n;
    }

    // -----------------------------------------------------------------------
    // The viewer's microphone and camera as this computer's capture devices (docs/PLAN.md, section 6):
    // one viewer at a time, only the devices this OS has.

    /// A viewer asks the computer to take (or drop) its microphone and camera. Answers media {mic, camera, msg}.
    fn setMedia(h: *Host, v: *Viewer, want_mic: bool, want_cam: bool) void {
        const status = plat.rdc_media_status();
        const has_mic = status & plat.media_mic != 0;
        const has_cam = status & plat.media_camera != 0;
        const mac = builtin.os.tag == .macos;
        var reason: []const u8 = "";
        if (want_mic and !has_mic) reason = if (mac)
            "RDC Microphone is not enabled on the computer: in the RDC window there, click Enable phone microphone"
        else
            "A phone microphone is not available on a Windows computer";
        if (want_cam and !has_cam) reason = if (mac)
            "A phone camera is not available on a Mac: it needs Apple's signed camera extension"
        else
            "RDC Camera is not enabled on the computer: in the RDC window there, click Enable phone camera";
        const mic = want_mic and has_mic;
        const cam = want_cam and has_cam;
        h.lock();
        if (h.media_owner) |owner| {
            if (owner != v and (mic or cam)) {
                v.pushMedia(false, false, "Another viewer's microphone or camera is in use on the computer");
                h.unlock();
                return;
            }
        }
        const was_mic = h.media_owner == v and h.media_mic;
        const was_cam = h.media_owner == v and h.media_cam;
        if (h.media_owner == v or mic or cam) {
            h.media_owner = if (mic or cam) v else null;
            h.media_mic = mic;
            h.media_cam = cam;
        }
        v.pushMedia(mic, cam, reason);
        h.unlock();
        if (mic and !was_mic) plat.rdc_mic_start();
        if (!mic and was_mic) plat.rdc_mic_stop();
        if (cam and !was_cam) plat.rdc_camera_start();
        if (!cam and was_cam) plat.rdc_camera_stop();
        if (!cam) v.cam.reset();
        if (mic != was_mic) log("viewer {s}: phone microphone {s}", .{ v.peer.str(), if (mic) "on" else "off" });
        if (cam != was_cam) log("viewer {s}: phone camera {s}", .{ v.peer.str(), if (cam) "on" else "off" });
        h.updateMediaUi();
    }

    /// The viewer that lent its devices is leaving.
    fn dropMedia(h: *Host, v: *Viewer) void {
        h.lock();
        if (h.media_owner != v) {
            h.unlock();
            return;
        }
        const mic = h.media_mic;
        const cam = h.media_cam;
        h.media_owner = null;
        h.media_mic = false;
        h.media_cam = false;
        h.unlock();
        if (mic) plat.rdc_mic_stop();
        if (cam) plat.rdc_camera_stop();
        h.updateMediaUi();
    }

    /// The person at the computer pressed Stop: the viewer hears why.
    fn stopMedia(h: *Host, reason: []const u8) void {
        h.lock();
        const owner = h.media_owner orelse {
            h.unlock();
            return;
        };
        const mic = h.media_mic;
        const cam = h.media_cam;
        h.media_owner = null;
        h.media_mic = false;
        h.media_cam = false;
        owner.pushMedia(false, false, reason);
        h.unlock();
        if (mic) plat.rdc_mic_stop();
        if (cam) plat.rdc_camera_stop();
        log("the host stopped the phone's microphone and camera", .{});
        h.updateMediaUi();
    }

    /// Samples and frames from a viewer: taken only from the viewer whose devices are on.
    fn onMedia(h: *Host, v: *Viewer, in: proto.Input) void {
        h.lock();
        const mine = h.media_owner == v;
        const mic = mine and h.media_mic;
        const cam = mine and h.media_cam;
        h.unlock();
        switch (in) {
            .audio => |a| if (mic) {
                // Little-endian 16-bit samples, copied out of the message so they are aligned.
                var samples: [2400]i16 = undefined; // up to 50 ms at a time
                var off: usize = 0;
                while (off < a.pcm.len) {
                    const take = @min(a.pcm.len - off, samples.len * 2);
                    @memcpy(std.mem.sliceAsBytes(samples[0 .. take / 2]), a.pcm[off .. off + take]);
                    plat.rdc_mic_push(&samples, @intCast(take / 2));
                    off += take;
                }
            },
            .camera => |c| if (cam) h.onCameraPiece(v, c),
            else => {},
        }
    }

    fn onCameraPiece(h: *Host, v: *Viewer, c: proto.CameraPiece) void {
        if (v.cam_buf.len == 0) {
            if (!c.first) return;
            v.cam_buf = h.gpa.alloc(u8, proto.camera_frame_max) catch return;
        }
        if (v.cam.push(v.cam_buf, c)) |f| plat.rdc_camera_push(f.jpeg.ptr, f.jpeg.len, f.width, f.height);
    }

    /// The window's Enable / Remove button for this OS's phone device: the install blocks on the
    /// administrator prompt, so it runs on its own thread.
    fn installMedia(h: *Host, install: bool) void {
        _ = h;
        const t = std.Thread.spawn(.{}, installMediaThread, .{install}) catch return;
        t.detach();
    }

    fn installMediaThread(install: bool) void {
        const status = plat.rdc_media_status();
        const camera = status & plat.media_camera_setup != 0;
        const what: []const u8 = if (camera) "RDC Camera" else "RDC Microphone";
        const rc = if (camera) plat.rdc_camera_install(@intFromBool(install), cameraDll(), cameraDllLen()) else plat.rdc_mic_install(@intFromBool(install));
        if (rc == 0) {
            log("{s} {s}", .{ what, if (install) "installed" else "removed" });
        } else if (rc == 1) {
            log("{s}: cancelled by the person at the computer", .{what});
        } else {
            log("{s}: could not {s} ({d})", .{ what, if (install) "install" else "remove", rc });
        }
    }

    /// The window: what a viewer lends right now, with a Stop button.
    fn updateMediaUi(h: *Host) void {
        if (!h.opts.ui) return;
        var buf: [160]u8 = undefined;
        var n: usize = 0;
        h.lock();
        if (h.media_owner) |o| {
            const what: []const u8 = if (h.media_mic and h.media_cam) "Phone microphone and camera live" else if (h.media_mic) "Phone microphone live" else "Phone camera live";
            if (std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s} — {s}", .{ what, o.peer.str() })) |s| n = s.len else |_| {}
        }
        h.unlock();
        buf[n] = 0;
        plat.rdc_app_set_media(buf[0..n :0].ptr);
    }

    /// Disconnects viewers that have sent nothing for too long.
    fn dropSilent(h: *Host) void {
        const now = nowUs(h.io);
        h.lock();
        defer h.unlock();
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            if (now -| v.last_us.load(.monotonic) > silence_us) {
                log("viewer {s} is silent — disconnecting", .{v.peer.str()});
                v.abort();
                v.link.shutdown(h.io, false);
            }
        }
    }

    fn updateCodecsLocked(h: *Host) void {
        var any_h264 = false;
        var any_jpeg = false;
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            if (v.h264) any_h264 = true else any_jpeg = true;
        }
        plat.rdc_set_codecs(@intFromBool(any_h264), @intFromBool(any_jpeg));
    }

    fn broadcastText(h: *Host, payload: []const u8) void {
        h.lock();
        defer h.unlock();
        h.broadcastTextLocked(payload);
    }

    fn broadcastTextLocked(h: *Host, payload: []const u8) void {
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            v.pushText(payload);
        }
    }

    fn ensureCapture(h: *Host) void {
        h.capture_mutex.lockUncancelable(h.io);
        defer h.capture_mutex.unlock(h.io);
        if (h.capturing) return;
        const rc = plat.rdc_capture_start(h.opts.max_width, h.opts.fps, onFrame, h);
        if (rc == 0) {
            h.capturing = true;
            return;
        }
        log("capture did not start ({d})", .{rc});
        h.broadcastText(if (builtin.os.tag == .macos)
            "{\"t\":\"err\",\"msg\":\"RDC has no Screen Recording permission on the computer\"}"
        else
            "{\"t\":\"err\",\"msg\":\"Could not capture the screen — details in the RDC log\"}");
    }

    fn stopCaptureIfIdle(h: *Host) void {
        h.lock();
        var count: usize = 0;
        for (h.viewers) |maybe| {
            if (maybe != null) count += 1;
        }
        const idle_since = h.idle_since_us;
        h.unlock();
        if (count > 0) return;
        h.capture_mutex.lockUncancelable(h.io);
        defer h.capture_mutex.unlock(h.io);
        if (!h.capturing or nowUs(h.io) -| idle_since < capture_idle_stop_us) return;
        plat.rdc_capture_stop();
        h.capturing = false;
        h.lock();
        h.frame_w = 0;
        h.frame_h = 0;
        h.unlock();
    }

    fn onFrame(ctx: ?*anyopaque, codec: c_int, data: [*]const u8, len: usize, keyframe: c_int, ts_us: u64, w: c_int, hgt: c_int) callconv(.c) void {
        const h: *Host = @ptrCast(@alignCast(ctx orelse return));
        h.distribute(codec, data[0..len], keyframe != 0, ts_us, w, hgt);
    }

    fn distribute(h: *Host, codec: c_int, data: []const u8, key: bool, ts_us: u64, w: c_int, hgt: c_int) void {
        const is_h264 = codec == plat.codec_h264;
        const kind: Msg.Kind = if (!is_h264) .jpeg else if (key) .h264_key else .h264_delta;
        var fh: [proto.frame_header_len]u8 = undefined;
        proto.frameHeader(&fh, if (is_h264) .h264 else .jpeg, key, ts_us);
        var wh_buf: [10]u8 = undefined;
        const wh = ws.header(&wh_buf, .binary, fh.len + data.len);
        const m = Msg.create(h.gpa, kind, wh.len + fh.len + data.len) orelse return;
        m.hdr_len = @intCast(wh.len);
        @memcpy(m.bytes[0..wh.len], wh);
        @memcpy(m.bytes[wh.len..][0..fh.len], &fh);
        @memcpy(m.bytes[wh.len + fh.len ..], data);

        h.lock();
        defer h.unlock();
        if (w != h.frame_w or hgt != h.frame_h) {
            h.frame_w = w;
            h.frame_h = hgt;
            var size_buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&size_buf, "{{\"t\":\"size\",\"w\":{d},\"h\":{d}}}", .{ w, hgt })) |size| {
                h.broadcastTextLocked(size);
            } else |_| {}
        }
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            if (v.h264 != is_h264) continue;
            m.retain();
            v.push(m);
        }
        m.release(h.gpa);
    }

    fn kickAll(h: *Host, reason: []const u8) void {
        var out: [200]u8 = undefined;
        const bye = std.fmt.bufPrint(&out, "{{\"t\":\"bye\",\"msg\":\"{s}\"}}", .{reason}) catch "{\"t\":\"bye\"}";
        h.lock();
        defer h.unlock();
        h.resumes = @splat(.{}); // out means out: the next visit needs a new authenticator code
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            v.pushText(bye);
            v.finish();
        }
    }

    // -----------------------------------------------------------------------
    // Permanent access (docs/PLAN.md, section 6): a link that never changes and asks for a code
    // from an authenticator app. Off until the person turns it on in Settings.

    /// The seed kept between runs, made on first use. null — no place to keep it, or another RDC
    /// on this computer serves the permanent link already.
    fn loadIdentity(h: *Host) ?totp.Identity {
        var seed: [totp.seed_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        const n = plat.rdc_seed_load(&seed, seed.len);
        if (n == -2) {
            log("permanent access: another RDC on this computer serves the permanent link", .{});
            return null;
        }
        if (n != seed.len) return h.newIdentity();
        return totp.Identity.fromSeed(&seed);
    }

    fn newIdentity(h: *Host) ?totp.Identity {
        var seed: [totp.seed_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        h.io.random(&seed);
        if (plat.rdc_seed_save(&seed, seed.len) != 0) {
            log("permanent access is off: its key cannot be saved", .{});
            return null;
        }
        return totp.Identity.fromSeed(&seed);
    }

    /// Turns permanent access on or off, or (fresh) replaces its link and authenticator key.
    fn setPermanent(h: *Host, on: bool, fresh: bool) void {
        const id: ?totp.Identity = if (!on or !h.opts.remote) null else if (fresh) h.newIdentity() else h.loadIdentity();
        h.lock();
        const was_on = h.perm != null;
        h.perm = id;
        if (fresh or id == null) {
            h.resumes = @splat(.{});
            h.otp_last_step = 0;
            h.otp_guard = .{};
        }
        h.unlock();
        // Off: the brokers stay connected, listening where no link leads.
        var nowhere: [signal.salt_len]u8 = undefined;
        h.io.random(&nowhere);
        const keys = signal.derive(totp.link_name, if (id) |i| &i.link_key else &nowhere);
        if (h.perm_signal) |s| {
            s.setKeys(keys);
        } else if (id != null) {
            h.perm_signal = signal.Signal.start(h.gpa, h.io, keys, onSignal, &h.port_perm, logLine) catch |e| blk: {
                log("permanent access is off: {t}", .{e});
                break :blk null;
            };
        }
        if (fresh or id == null) h.kickPermanent(if (id == null) "Permanent access was turned off on the computer" else "The permanent link was replaced on the computer");
        if (was_on != (id != null) or fresh) log("permanent access: {s}", .{if (id == null) "off" else if (fresh) "new link and key" else "on"});
        h.refreshPermanent();
    }

    fn kickPermanent(h: *Host, reason: []const u8) void {
        var out: [200]u8 = undefined;
        const bye = std.fmt.bufPrint(&out, "{{\"t\":\"bye\",\"msg\":\"{s}\"}}", .{reason}) catch "{\"t\":\"bye\"}";
        h.lock();
        defer h.unlock();
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            if (!v.permanent) continue;
            v.pushText(bye);
            v.finish();
        }
    }

    /// Settings: the permanent link, and the two QR codes — the link for the phone's camera, the
    /// key for the authenticator app.
    fn refreshPermanent(h: *Host) void {
        if (!h.opts.ui) return;
        h.lock();
        const maybe = h.perm;
        h.unlock();
        const id = maybe orelse return plat.rdc_app_set_permanent(0, "", null, 0, null, 0, "");
        var link_buf: [max_remote_url_len + 4 + signal.salt_text_len + 1]u8 = undefined;
        var key: [signal.salt_text_len]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&key, &id.link_key);
        const link = std.fmt.bufPrint(link_buf[0 .. link_buf.len - 1], "{s}#{s}-{s}", .{ h.opts.remote_url, totp.link_name, &key }) catch unreachable;
        link_buf[link.len] = 0;
        var uri_buf: [totp.max_uri]u8 = undefined;
        const uri = totp.uri(&uri_buf, &id.secret, h.name[0..h.name_len]);
        var text_buf: [totp.grouped_len + 1]u8 = undefined;
        const text = totp.grouped(text_buf[0..totp.grouped_len], &id.secret);
        text_buf[text.len] = 0;
        const link_qr = qr.encode(link) catch return;
        const auth_qr = qr.encode(uri) catch return;
        plat.rdc_app_set_permanent(1, link_buf[0..link.len :0].ptr, &link_qr.modules, link_qr.size, &auth_qr.modules, auth_qr.size, text_buf[0..text.len :0].ptr);
    }

    fn renewCode(h: *Host) void {
        h.lock();
        h.code = newCode(h.io);
        h.salt = newSalt(h.io);
        h.failed = 0;
        h.locked_until_us = 0;
        const keys = signal.derive(&h.code.digits, &h.salt);
        h.unlock();
        // The old link from anywhere stops working with the old code.
        if (h.signal) |s| s.setKeys(keys);
        h.kickAll("The code has changed — a new one is needed");
        h.refreshUi(false);
    }

    // -----------------------------------------------------------------------
    // Viewers from anywhere: signaling messages → WebRTC sessions → the viewer logic above.

    fn startRemote(h: *Host) void {
        h.identity = dtls.Identity.generate(h.io) catch |e| {
            log("connections from anywhere are off: no DTLS certificate ({t})", .{e});
            return;
        };
        h.signal = signal.Signal.start(h.gpa, h.io, signal.derive(&h.code.digits, &h.salt), onSignal, &h.port_code, logLine) catch |e| {
            log("connections from anywhere are off: {t}", .{e});
            return;
        };
        if (plat.rdc_pref_bool("permanent", 0) != 0) h.setPermanent(true, false);
    }

    fn logLine(msg: []const u8) void {
        log("{s}", .{msg});
    }

    /// A message from a browser through a broker (on a broker thread): an offer or a late candidate.
    /// Its timestamp must be within a minute of our clock: a recorded message sent again is refused.
    fn onSignal(ctx: *anyopaque, text: []const u8) void {
        const port: *Port = @ptrCast(@alignCast(ctx));
        const h = port.host;
        const SignalMsg = struct { t: []const u8 = "", id: []const u8 = "", ts: i64 = 0, sdp: []const u8 = "", c: []const u8 = "" };
        const parsed = std.json.parseFromSlice(SignalMsg, h.gpa, text, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const m = parsed.value;
        if (m.id.len == 0 or m.id.len > signal.max_id_len) return;
        for (m.id) |c| if (!std.ascii.isAlphanumeric(c)) return;
        const is_offer = std.mem.eql(u8, m.t, "offer");
        // Our own answers come back too: everything but offers and candidates is ignored.
        if (!is_offer and !std.mem.eql(u8, m.t, "cand")) return;
        const skew = signal.skewMs(m.ts, realMs(h.io));
        if (!signal.fresh(skew)) {
            if (is_offer) h.onStaleOffer(port, m.id, m.ts, skew);
            return;
        }
        if (is_offer) return h.onOffer(port, m.id, m.ts, m.sdp);
        h.lock();
        defer h.unlock();
        for (h.rtc) |maybe| {
            const c = maybe orelse continue;
            if (c.permanent == port.permanent and std.mem.eql(u8, c.id(), m.id)) c.session.addCandidate(m.c);
        }
    }

    /// An offer whose clock is more than a minute off ours: a replay, or a device set to the wrong
    /// time. A replay of an offer we took stays unanswered; otherwise the browser hears why, now and then.
    fn onStaleOffer(h: *Host, port: *const Port, id: []const u8, ts: i64, skew_ms: i64) void {
        const now = nowUs(h.io);
        h.lock();
        const reply = !h.guard.seen(id) and now -| h.last_clock_reply_us >= clock_reply_every_us;
        if (reply) h.last_clock_reply_us = now;
        h.unlock();
        if (!reply) return;
        if (ts == 0) return h.signalError(port.permanent, id, ts, "This page is out of date — reload it");
        const minutes = (@abs(skew_ms) + 30_000) / 60_000;
        const side: []const u8 = if (skew_ms > 0) "behind" else "ahead of";
        log("a browser's offer was refused: its clock is {d} min {s} this computer's", .{ minutes, side });
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "The clock on this device is {d} min {s} the computer's — turn on automatic date and time on both", .{ minutes, side }) catch return;
        h.signalError(port.permanent, id, ts, msg);
    }

    fn onOffer(h: *Host, port: *const Port, id: []const u8, ts: i64, offer: []const u8) void {
        // The reply to a refused offer goes out after the lock: publishing is network I/O.
        const refusal = h.startSession(port.permanent, id, ts, offer) orelse return;
        h.signalError(port.permanent, id, ts, refusal);
    }

    fn signalFor(h: *Host, permanent: bool) ?*signal.Signal {
        return if (permanent) h.perm_signal else h.signal;
    }

    /// null — started or a repeat; otherwise why the offer was refused.
    fn startSession(h: *Host, permanent: bool, id: []const u8, ts: i64, offer: []const u8) ?[]const u8 {
        const now = nowUs(h.io);
        h.lock();
        defer h.unlock();
        if (!h.guard.remember(id)) return null; // through the other broker, or replayed
        const slot = for (h.rtc, 0..) |c, i| {
            if (c == null) break i;
        } else return "The computer has too many connections — try again in a minute";
        if (!h.guard.allowStart(now)) return "Too many connection attempts — try again in a few seconds";
        const conn = h.gpa.create(RtcConn) catch return null;
        conn.* = .{ .host = h, .session = undefined, .id_buf = @splat(0), .id_len = id.len, .offer_ts = ts, .permanent = permanent };
        @memcpy(conn.id_buf[0..id.len], id);
        // The session thread may call back at once; its callbacks wait for this lock.
        conn.session = webrtc.Session.start(h.gpa, h.io, &h.identity, offer, h.lanIp(), .{
            .ctx = conn,
            .answer = rtcAnswer,
            .message = rtcMessage,
            .closed = rtcClosed,
        }) catch |e| {
            h.gpa.destroy(conn);
            log("a browser's offer was refused: {t}", .{e});
            return "RDC on the computer cannot use this browser's offer";
        };
        h.rtc[slot] = conn;
        return null;
    }

    /// `ts` — the offer's own timestamp: every reply carries it back.
    fn signalError(h: *Host, permanent: bool, id: []const u8, ts: i64, msg: []const u8) void {
        const s = h.signalFor(permanent) orelse return;
        var buf: [320]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"t\":\"err\",\"id\":\"{s}\",\"ts\":{d},\"msg\":\"{s}\"}}", .{ id, ts, msg }) catch return;
        s.send(json);
    }

    fn rtcAnswer(ctx: *anyopaque, s: *webrtc.Session, sdp_text: []const u8) void {
        _ = s;
        const c: *RtcConn = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{{\"t\":\"answer\",\"id\":\"{s}\",\"ts\":{d},\"sdp\":\"", .{ c.id(), c.offer_ts }) catch return;
        for (sdp_text) |ch| switch (ch) {
            '\r' => w.writeAll("\\r") catch return,
            '\n' => w.writeAll("\\n") catch return,
            '"', '\\' => w.print("\\{c}", .{ch}) catch return,
            0...0x09, 0x0b, 0x0c, 0x0e...0x1f => {},
            else => w.writeByte(ch) catch return,
        };
        w.writeAll("\"}") catch return;
        if (c.host.signalFor(c.permanent)) |sig| sig.send(w.buffered());
    }

    fn rtcMessage(ctx: *anyopaque, s: *webrtc.Session, binary: bool, data: []const u8) void {
        const c: *RtcConn = @ptrCast(@alignCast(ctx));
        if (!c.host.onMessage(.{ .rtc = s }, Peer.fromText(s.peer()), &c.viewer, if (binary) .binary else .text, data, c.permanent)) {
            s.closeAfter(1000);
        }
    }

    fn rtcClosed(ctx: *anyopaque, s: *webrtc.Session, reason: []const u8) void {
        const c: *RtcConn = @ptrCast(@alignCast(ctx));
        const h = c.host;
        if (c.viewer) |v| {
            h.removeViewer(v);
        } else {
            log("a browser from anywhere did not connect{s}{s}: {s}", .{ if (s.peer().len > 0) " from " else "", s.peer(), reason });
        }
        h.lock();
        for (&h.rtc) |*slot| {
            if (slot.* == c) slot.* = null;
        }
        h.unlock();
        h.gpa.destroy(c);
    }

    fn refreshUi(h: *Host, prompt: bool) void {
        if (!h.opts.ui) return;
        var code_buf: [12]u8 = undefined;
        var link_buf: [160]u8 = undefined;
        h.lock();
        const shown = h.code.display(code_buf[0..11]);
        const digits = h.code.digits;
        h.unlock();
        code_buf[shown.len] = 0;
        const link = std.fmt.bufPrint(link_buf[0 .. link_buf.len - 1], "http://{s}:{d}/#{s}", .{ h.ip[0..h.ip_len], h.port, &digits }) catch return;
        link_buf[link.len] = 0;
        plat.rdc_app_set_info(code_buf[0..shown.len :0].ptr, link_buf[0..link.len :0].ptr);
        h.refreshRemote();
        const p: c_int = @intFromBool(prompt);
        plat.rdc_app_set_permissions(plat.rdc_screen_access(p), plat.rdc_input_access(p));
        h.updateStatus();
    }

    /// The "from anywhere" part of the window: the link only while a broker is connected, since
    /// before that no browser can find this computer.
    fn refreshRemote(h: *Host) void {
        if (!h.opts.ui) return;
        h.remote_ui_mutex.lockUncancelable(h.io);
        defer h.remote_ui_mutex.unlock(h.io);
        const s = h.signal orelse return plat.rdc_app_set_remote("Connections from anywhere are off", "");
        if (s.connected() == 0) return plat.rdc_app_set_remote("From anywhere — connecting to the public servers…", "");
        var buf: [max_remote_link_len + 1]u8 = undefined;
        h.lock();
        const link = h.remoteLinkLocked(buf[0..max_remote_link_len]);
        h.unlock();
        buf[link.len] = 0;
        plat.rdc_app_set_remote("From anywhere — a phone on mobile data, another network", buf[0..link.len :0].ptr);
    }

    /// Called every second: the link from anywhere appears once a broker is connected and goes
    /// away while none is.
    fn watchRemote(h: *Host) void {
        const s = h.signal orelse return;
        const up = s.connected() > 0;
        if (up == h.remote_shown) return;
        h.remote_shown = up;
        if (h.opts.ui) return h.refreshRemote();
        if (!up) return;
        // The link holds the key: into the log only when there is no window to copy it from.
        var buf: [max_remote_link_len]u8 = undefined;
        h.lock();
        const link = h.remoteLinkLocked(&buf);
        h.unlock();
        log("from anywhere: {s}", .{link});
    }

    fn updateStatus(h: *Host) void {
        if (!h.opts.ui) return;
        var buf: [320]u8 = undefined;
        var n: usize = 0;
        var ai_active = false;
        h.lock();
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            const prefix: []const u8 = if (n == 0) "Connected: " else ", ";
            const part = if (v.ai_len > 0)
                std.fmt.bufPrint(buf[n .. buf.len - 1], "{s}AI agent {s} ({s})", .{ prefix, v.ai(), v.peer.str() }) catch break
            else
                std.fmt.bufPrint(buf[n .. buf.len - 1], "{s}{s}", .{ prefix, v.peer.str() }) catch break;
            n += part.len;
            if (v.ai_len > 0) ai_active = true;
        }
        h.unlock();
        if (n == 0) {
            const idle = "Waiting for a connection by link or code";
            @memcpy(buf[0..idle.len], idle);
            n = idle.len;
        }
        buf[n] = 0;
        plat.rdc_app_set_status(buf[0..n :0].ptr);
        plat.rdc_app_set_ai(@intFromBool(ai_active));
    }

    /// A viewer on a slow network (mobile data) makes frames pile up and get dropped: lower the
    /// bitrate at once, raise it again after a few calm seconds. With no viewers, start over.
    fn adaptBitrate(h: *Host) void {
        const drops = h.drops.swap(0, .monotonic);
        var next = h.bitrate;
        if (h.viewerCount() == 0) {
            next = max_bitrate;
            h.calm_ticks = 0;
        } else if (drops > 0) {
            next = @max(min_bitrate, @divTrunc(h.bitrate * 6, 10));
            h.calm_ticks = 0;
        } else {
            h.calm_ticks += 1;
            if (h.calm_ticks >= 4) {
                h.calm_ticks = 0;
                next = @min(max_bitrate, @divTrunc(h.bitrate * 23, 20));
            }
        }
        if (next == h.bitrate) return;
        if (next < h.bitrate) log("video: {d} kbit/s — a viewer cannot keep up", .{@divTrunc(next, 1000)});
        h.bitrate = next;
        plat.rdc_set_bitrate(next);
    }

    fn housekeeping(h: *Host) void {
        var tick: u32 = 0;
        while (true) : (tick +%= 1) {
            h.io.sleep(.fromMilliseconds(1000), .awake) catch {};
            h.stopCaptureIfIdle();
            h.adaptBitrate();
            h.dropSilent();
            if (h.opts.ui and tick % 2 == 0) {
                plat.rdc_app_set_permissions(plat.rdc_screen_access(0), plat.rdc_input_access(0));
            }
            if (h.signal) |s| s.keepalive();
            if (h.perm_signal) |s| s.keepalive();
            h.watchRemote();
            h.updater.tick(h.viewerCount());
        }
    }
};

/// A WebRTC session and, once the browser has sent the right code, its viewer.
const RtcConn = struct {
    host: *Host,
    session: *webrtc.Session,
    viewer: ?*Viewer = null,
    id_buf: [signal.max_id_len]u8,
    id_len: usize,
    /// The offer's timestamp: the replies carry it back, and the browser checks it on its own clock.
    offer_ts: i64,
    /// The offer came through the permanent link: the browser must show an authenticator code.
    permanent: bool = false,

    fn id(c: *const RtcConn) []const u8 {
        return c.id_buf[0..c.id_len];
    }
};

fn applyInput(in: proto.Input) void {
    switch (in) {
        .move => |m| plat.rdc_mouse_move(m.x, m.y),
        .button => |b| plat.rdc_mouse_button(b.button, @intFromBool(b.down), b.x, b.y),
        .wheel => |w| plat.rdc_scroll(w.dx, w.dy),
        .key => |k| if (platformKey(k.usage)) |kc| plat.rdc_key(kc, @intFromBool(k.down)),
        .release_all => plat.rdc_release_all(),
        .text => |t| plat.rdc_text(t.ptr, t.len),
        .keyframe => plat.rdc_request_keyframe(),
        .audio, .camera => {}, // Host.onMedia takes these
    }
}

fn onReady(ctx: ?*anyopaque) callconv(.c) void {
    const h: *Host = @ptrCast(@alignCast(ctx orelse return));
    h.refreshUi(true);
    h.refreshPermanent();
    h.updater.publish();
}

fn onAction(ctx: ?*anyopaque, action: c_int) callconv(.c) void {
    const h: *Host = @ptrCast(@alignCast(ctx orelse return));
    switch (action) {
        plat.action_disconnect_all => h.kickAll("The host ended the session"),
        plat.action_stop_ai => {
            log("the host stopped the AI agents", .{});
            h.stopAi("The person at the computer stopped the AI agent");
        },
        plat.action_stop_media => h.stopMedia("The person at the computer stopped the phone's microphone and camera"),
        plat.action_media_install, plat.action_media_remove => h.installMedia(action == plat.action_media_install),
        plat.action_new_code => h.renewCode(),
        plat.action_permanent_on, plat.action_permanent_off => {
            plat.rdc_set_pref_bool("permanent", @intFromBool(action == plat.action_permanent_on));
            h.setPermanent(action == plat.action_permanent_on, false);
        },
        plat.action_permanent_reset => h.setPermanent(true, true),
        plat.action_check_update => h.updater.checkNow(),
        plat.action_install_update => {
            h.kickAll("The computer is updating RDC — reconnect in a minute");
            h.updater.installNow();
        },
        plat.action_auto_update_on => h.updater.setAuto(true),
        plat.action_auto_update_off => h.updater.setAuto(false),
        else => {},
    }
}

pub fn run(gpa: std.mem.Allocator, io: Io, opts: Options) !void {
    if (opts.remote and opts.remote_url.len > max_remote_url_len) {
        log("--remote-url is too long: {d} characters, at most {d}", .{ opts.remote_url.len, max_remote_url_len });
        return error.RemoteUrlTooLong;
    }
    const h = try Host.create(gpa, io, opts);
    try h.listen();
    if (opts.remote) h.startRemote();
    var code_buf: [11]u8 = undefined;
    log("RDC {s} ({s}): code {s}, link http://{s}:{d}/#{s}", .{ version, os_name, h.code.display(&code_buf), h.ip[0..h.ip_len], h.port, &h.code.digits });
    // The link from anywhere appears once a broker is connected (Host.watchRemote).
    const server = try std.Thread.spawn(.{}, Host.serve, .{h});
    const keeper = try std.Thread.spawn(.{}, Host.housekeeping, .{h});
    keeper.detach();
    if (opts.ui) {
        plat.rdc_app_run(onReady, onAction, h);
    } else {
        server.join();
    }
}
