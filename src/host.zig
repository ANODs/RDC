//! Хост M1: экран Mac → зрители в браузере по ссылке или коду (локальная сеть).
//! HTTP отдаёт страницу зрителя, WebSocket несёт кадры (H.264 или JPEG) и ввод.
//!
//! Потоки: приём соединений; по потоку на соединение (чтение); по потоку-писателю
//! на зрителя; обслуживание (разрешения, статус, остановка захвата без зрителей).
//! Кадры приходят из потока VideoToolbox и раздаются в очереди зрителей. Кто не
//! успевает, тот пропускает кадры, а не копит задержку.
const std = @import("std");
const c = std.c;
const mac = @import("platform/macos.zig");
const ws = @import("net/ws.zig");
const http = @import("net/http.zig");
const proto = @import("core/proto.zig");
const keymap = @import("core/keymap.zig");
const Code = @import("core/code.zig").Code;
const update = @import("update.zig");
const web = @import("web");

pub const version = update.current_version;
pub const max_viewers = 4;
const queue_cap = 16;
const max_frames_queued = 6;
const max_ws_payload = 16 * 1024;
const capture_idle_stop_us: u64 = 10_000_000;
const lockout_us: u64 = 30_000_000;

pub const Options = struct {
    port: u16 = 7700,
    max_width: c_int = 1920,
    fps: c_int = 60,
    ui: bool = true,
    /// Для разработки: брать страницу зрителя с диска, а не из бинарника.
    web_dir: ?[]const u8 = null,
    /// Для проверки обновлений: откуда брать latest.json и архив вместо релизов GitHub.
    update_url: ?[]const u8 = null,
};

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return;
    buf[s.len] = 0;
    mac.rdc_mac_log(buf[0..s.len :0].ptr);
}

// ---------------------------------------------------------------------------
// Синхронизация (pthread из libc: работает и из потоков VideoToolbox)

const Mutex = struct {
    m: c.pthread_mutex_t = .{},
    fn lock(self: *Mutex) void {
        _ = c.pthread_mutex_lock(&self.m);
    }
    fn unlock(self: *Mutex) void {
        _ = c.pthread_mutex_unlock(&self.m);
    }
};

const Cond = struct {
    cv: c.pthread_cond_t = .{},
    fn wait(self: *Cond, m: *Mutex) void {
        _ = c.pthread_cond_wait(&self.cv, &m.m);
    }
    fn signal(self: *Cond) void {
        _ = c.pthread_cond_signal(&self.cv);
    }
};

// ---------------------------------------------------------------------------
// Сообщения: готовые к отправке байты (заголовок WebSocket + данные) со счётчиком
// ссылок — один кадр уходит всем зрителям без копирования.

const Msg = struct {
    refs: std.atomic.Value(u32),
    bytes: []u8,
    kind: Kind,

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

    fn text(gpa: std.mem.Allocator, opcode: ws.Opcode, payload: []const u8) ?*Msg {
        var hdr: [10]u8 = undefined;
        const h = ws.header(&hdr, opcode, payload.len);
        const m = create(gpa, .control, h.len + payload.len) orelse return null;
        @memcpy(m.bytes[0..h.len], h);
        @memcpy(m.bytes[h.len..], payload);
        return m;
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

fn sendAll(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.send(fd, data[off..].ptr, data.len - off, 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

const Peer = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,

    fn fromAddr(addr: u32) Peer {
        var p: Peer = .{};
        const b = std.mem.asBytes(&addr);
        const s = std.fmt.bufPrint(&p.buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch return p;
        p.len = s.len;
        return p;
    }

    fn str(p: *const Peer) []const u8 {
        return p.buf[0..p.len];
    }
};

// ---------------------------------------------------------------------------
// Зритель: очередь исходящих сообщений и поток-писатель

const Viewer = struct {
    host: *Host,
    fd: c_int,
    peer: Peer,
    h264: bool,
    mutex: Mutex = .{},
    cond: Cond = .{},
    queue: [queue_cap]*Msg = undefined,
    head: usize = 0,
    count: usize = 0,
    frames: usize = 0,
    need_key: bool = true,
    closing: bool = false, // дослать очередь и закрыть
    aborted: bool = false, // закрыть сразу
    writer: ?std.Thread = null,

    /// Ставит сообщение в очередь; забирает ссылку на m.
    fn push(v: *Viewer, m: *Msg) void {
        const gpa = v.host.gpa;
        v.mutex.lock();
        defer v.mutex.unlock();
        if (v.closing or v.aborted) return m.release(gpa);
        switch (m.kind) {
            .h264_delta => if (v.need_key) return m.release(gpa),
            .h264_key => v.need_key = false,
            else => {},
        }
        const is_frame = m.kind != .control;
        if (is_frame and v.frames >= max_frames_queued) {
            if (m.kind == .jpeg) {
                // JPEG: важен только свежий кадр — подменяем последний JPEG в очереди.
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
            // H.264: зритель не успевает — пропускаем до следующего ключевого кадра.
            v.need_key = true;
            mac.rdc_mac_request_keyframe();
            return m.release(gpa);
        }
        if (v.count == queue_cap) return m.release(gpa);
        v.queue[(v.head + v.count) % queue_cap] = m;
        v.count += 1;
        if (is_frame) v.frames += 1;
        v.cond.signal();
    }

    fn pushText(v: *Viewer, payload: []const u8) void {
        const m = Msg.text(v.host.gpa, .text, payload) orelse return;
        v.push(m);
    }

    fn pop(v: *Viewer) ?*Msg {
        v.mutex.lock();
        defer v.mutex.unlock();
        while (v.count == 0 and !v.closing and !v.aborted) v.cond.wait(&v.mutex);
        if (v.aborted or v.count == 0) return null;
        const m = v.queue[v.head];
        v.head = (v.head + 1) % queue_cap;
        v.count -= 1;
        if (m.kind != .control) v.frames -= 1;
        return m;
    }

    fn finish(v: *Viewer) void {
        v.mutex.lock();
        v.closing = true;
        v.cond.signal();
        v.mutex.unlock();
    }

    fn abort(v: *Viewer) void {
        v.mutex.lock();
        v.aborted = true;
        v.cond.signal();
        v.mutex.unlock();
    }

    fn drain(v: *Viewer) void {
        v.mutex.lock();
        defer v.mutex.unlock();
        while (v.count > 0) {
            v.queue[v.head].release(v.host.gpa);
            v.head = (v.head + 1) % queue_cap;
            v.count -= 1;
        }
        v.frames = 0;
    }

    fn writerMain(v: *Viewer) void {
        while (v.pop()) |m| {
            const ok = sendAll(v.fd, m.bytes);
            m.release(v.host.gpa);
            if (!ok) break;
        }
        v.abort();
        _ = c.shutdown(v.fd, 2); // будит поток чтения этого соединения
    }
};

// ---------------------------------------------------------------------------
// Хост

pub const Host = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    mutex: Mutex = .{},
    viewers: [max_viewers]?*Viewer = @splat(null),
    code: Code,
    failed: u32 = 0,
    locked_until_us: u64 = 0,
    frame_w: c_int = 0,
    frame_h: c_int = 0,
    port: u16 = 0,
    listen_fd: c_int = -1,
    ip: [64]u8 = undefined,
    ip_len: usize = 0,
    name: [128]u8 = undefined,
    name_len: usize = 0,
    capture_mutex: Mutex = .{},
    capturing: bool = false,
    idle_since_us: u64 = 0,
    updater: update.Updater,

    fn create(gpa: std.mem.Allocator, opts: Options) !*Host {
        const h = try gpa.create(Host);
        h.* = .{ .gpa = gpa, .opts = opts, .code = newCode(), .updater = update.Updater.init(gpa, opts.update_url, opts.ui) };
        if (mac.rdc_mac_lan_ipv4(&h.ip, h.ip.len) == 0) {
            h.ip_len = std.mem.indexOfScalar(u8, &h.ip, 0) orelse 0;
        } else {
            const fallback = "127.0.0.1";
            @memcpy(h.ip[0..fallback.len], fallback);
            h.ip_len = fallback.len;
        }
        if (mac.rdc_mac_computer_name(&h.name, h.name.len) == 0) {
            h.name_len = std.mem.indexOfScalar(u8, &h.name, 0) orelse 0;
        } else {
            const fallback = "Mac";
            @memcpy(h.name[0..fallback.len], fallback);
            h.name_len = fallback.len;
        }
        return h;
    }

    fn newCode() Code {
        var r: u64 = undefined;
        c.arc4random_buf(@ptrCast(&r), @sizeOf(u64));
        return Code.fromRandom(r);
    }

    fn listen(h: *Host) !void {
        var port = h.opts.port;
        var attempt: u16 = 0;
        while (attempt < 20) : ({
            attempt += 1;
            port +%= 1;
        }) {
            const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
            if (fd < 0) return error.SocketFailed;
            var one: c_int = 1;
            _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
            var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
            if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0 or c.listen(fd, 64) != 0) {
                _ = c.close(fd);
                continue;
            }
            h.listen_fd = fd;
            h.port = port;
            return;
        }
        return error.NoFreePort;
    }

    fn serve(h: *Host) void {
        while (true) {
            var addr: c.sockaddr.in = undefined;
            var alen: c.socklen_t = @sizeOf(c.sockaddr.in);
            const fd = c.accept(h.listen_fd, @ptrCast(&addr), &alen);
            if (fd < 0) continue;
            const peer = Peer.fromAddr(addr.addr);
            const t = std.Thread.spawn(.{}, connectionMain, .{ h, fd, peer }) catch {
                _ = c.close(fd);
                continue;
            };
            t.detach();
        }
    }

    fn setSocketOptions(fd: c_int) void {
        var one: c_int = 1;
        _ = c.setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, &one, @sizeOf(c_int));
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
        var rcv: c.timeval = .{ .sec = 30, .usec = 0 }; // зритель пингует раз в секунду
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &rcv, @sizeOf(c.timeval));
        var snd: c.timeval = .{ .sec = 5, .usec = 0 };
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, &snd, @sizeOf(c.timeval));
        var sndbuf: c_int = 4 * 1024 * 1024;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDBUF, &sndbuf, @sizeOf(c_int));
    }

    fn connectionMain(h: *Host, fd: c_int, peer: Peer) void {
        defer _ = c.close(fd);
        setSocketOptions(fd);
        var buf: [16 * 1024]u8 = undefined;
        var n: usize = 0;
        const head_end = while (true) {
            if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n")) |i| break i + 4;
            if (n == buf.len) return;
            const r = c.recv(fd, buf[n..].ptr, buf.len - n, 0);
            if (r <= 0) return;
            n += @intCast(r);
        };
        const req = http.parseHead(buf[0..head_end]) orelse return;
        const eql = std.mem.eql;
        if (!eql(u8, req.method, "GET")) return respond(fd, "405 Method Not Allowed", "text/plain; charset=utf-8", "");
        if (eql(u8, req.path, "/ws")) {
            if (!req.upgrade_websocket) return respond(fd, "400 Bad Request", "text/plain; charset=utf-8", "");
            return h.websocket(fd, peer, req.websocket_key.?, buf[head_end..n]);
        }
        if (eql(u8, req.path, "/") or eql(u8, req.path, "/index.html"))
            return h.serveWeb(fd, "index.html", "text/html; charset=utf-8", web.index_html);
        if (eql(u8, req.path, "/viewer.js"))
            return h.serveWeb(fd, "viewer.js", "text/javascript; charset=utf-8", web.viewer_js);
        respond(fd, "404 Not Found", "text/plain; charset=utf-8", "Не найдено");
    }

    fn serveWeb(h: *Host, fd: c_int, name: []const u8, content_type: []const u8, embedded: []const u8) void {
        if (h.opts.web_dir) |dir| {
            var path_buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{s}/{s}", .{ dir, name })) |path| {
                path_buf[path.len] = 0;
                var len: usize = 0;
                if (mac.rdc_mac_read_file(path_buf[0..path.len :0].ptr, &len)) |ptr| {
                    defer c.free(ptr);
                    return respond(fd, "200 OK", content_type, ptr[0..len]);
                }
            } else |_| {}
        }
        respond(fd, "200 OK", content_type, embedded);
    }

    fn respond(fd: c_int, status: []const u8, content_type: []const u8, body: []const u8) void {
        var head: [512]u8 = undefined;
        const hdr = std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
        if (sendAll(fd, hdr)) _ = sendAll(fd, body);
    }

    fn websocket(h: *Host, fd: c_int, peer: Peer, key: []const u8, leftover: []const u8) void {
        var accept_buf: [28]u8 = undefined;
        var resp: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{ws.acceptKey(key, &accept_buf)}) catch return;
        if (!sendAll(fd, head)) return;

        var rb: [64 * 1024]u8 = undefined;
        var len: usize = leftover.len;
        @memcpy(rb[0..len], leftover);
        var viewer: ?*Viewer = null;
        defer if (viewer) |v| h.removeViewer(v);
        while (true) {
            while (true) {
                const parsed = ws.parse(rb[0..len], max_ws_payload) catch return;
                const p = parsed orelse break;
                if (!p.frame.fin or p.frame.opcode == .continuation) return;
                if (!h.onMessage(fd, peer, &viewer, p.frame)) return;
                std.mem.copyForwards(u8, rb[0 .. len - p.used], rb[p.used..len]);
                len -= p.used;
            }
            if (len == rb.len) return;
            const r = c.recv(fd, rb[len..].ptr, rb.len - len, 0);
            if (r <= 0) return;
            len += @intCast(r);
        }
    }

    fn onMessage(h: *Host, fd: c_int, peer: Peer, viewer: *?*Viewer, f: ws.Frame) bool {
        switch (f.opcode) {
            .text => {
                const msg = f.payload;
                const t = proto.jsonString(msg, "t") orelse return true;
                if (std.mem.eql(u8, t, "hello")) {
                    if (viewer.* == null) viewer.* = h.admit(fd, peer, msg) orelse return false;
                } else if (std.mem.eql(u8, t, "ping")) {
                    const v = viewer.* orelse return true;
                    var cx: f64 = 0.5;
                    var cy: f64 = 0.5;
                    mac.rdc_mac_cursor_pos(&cx, &cy);
                    var out: [128]u8 = undefined;
                    const pong = std.fmt.bufPrint(&out, "{{\"t\":\"pong\",\"ts\":{s},\"cx\":{d:.4},\"cy\":{d:.4}}}", .{ proto.jsonNumber(msg, "ts") orelse "0", cx, cy }) catch return true;
                    v.pushText(pong);
                }
                return true;
            },
            .binary => {
                if (viewer.* == null) return false;
                if (proto.decodeInput(f.payload)) |in| applyInput(in);
                return true;
            },
            .ping => {
                if (viewer.*) |v| {
                    if (Msg.text(h.gpa, .pong, f.payload)) |m| v.push(m);
                }
                return true;
            },
            .close => return false,
            else => return true,
        }
    }

    fn sendError(fd: c_int, text: []const u8) void {
        var out: [256]u8 = undefined;
        const json = std.fmt.bufPrint(&out, "{{\"t\":\"err\",\"fatal\":true,\"msg\":\"{s}\"}}", .{text}) catch return;
        var hdr: [10]u8 = undefined;
        if (sendAll(fd, ws.header(&hdr, .text, json.len))) _ = sendAll(fd, json);
    }

    fn admit(h: *Host, fd: c_int, peer: Peer, hello: []const u8) ?*Viewer {
        const now = mac.rdc_mac_now_us();
        h.mutex.lock();
        if (now < h.locked_until_us) {
            h.mutex.unlock();
            sendError(fd, "Слишком много неверных попыток — подождите полминуты");
            return null;
        }
        if (!h.code.matches(proto.jsonString(hello, "code") orelse "")) {
            h.failed += 1;
            if (h.failed >= 5) h.locked_until_us = now + lockout_us;
            h.mutex.unlock();
            log("неверный код с {s}", .{peer.str()});
            sendError(fd, "Неверный код");
            return null;
        }
        h.failed = 0;
        var slot: ?usize = null;
        for (h.viewers, 0..) |existing, i| {
            if (existing == null) {
                slot = i;
                break;
            }
        }
        const index = slot orelse {
            h.mutex.unlock();
            sendError(fd, "Уже подключено четыре зрителя — больше нельзя");
            return null;
        };
        const v = h.gpa.create(Viewer) catch {
            h.mutex.unlock();
            return null;
        };
        v.* = .{ .host = h, .fd = fd, .peer = peer, .h264 = proto.jsonTrue(hello, "h264") };
        var name_buf: [160]u8 = undefined;
        var ok_buf: [384]u8 = undefined;
        var cx: f64 = 0.5;
        var cy: f64 = 0.5;
        mac.rdc_mac_cursor_pos(&cx, &cy);
        const ok = std.fmt.bufPrint(&ok_buf, "{{\"t\":\"ok\",\"w\":{d},\"h\":{d},\"os\":\"macos\",\"name\":\"{s}\",\"codec\":\"{s}\",\"version\":\"{s}\",\"cx\":{d:.4},\"cy\":{d:.4}}}", .{
            h.frame_w,
            h.frame_h,
            proto.jsonEscape(&name_buf, h.name[0..h.name_len]),
            if (v.h264) "h264" else "jpeg",
            version,
            cx,
            cy,
        }) catch "{\"t\":\"ok\"}";
        v.pushText(ok);
        v.writer = std.Thread.spawn(.{}, Viewer.writerMain, .{v}) catch {
            v.drain();
            h.gpa.destroy(v);
            h.mutex.unlock();
            return null;
        };
        h.viewers[index] = v;
        h.updateCodecsLocked();
        h.mutex.unlock();

        log("подключился зритель {s} ({s})", .{ peer.str(), if (v.h264) "H.264" else "JPEG" });
        h.ensureCapture();
        mac.rdc_mac_request_keyframe();
        h.updateStatus();
        return v;
    }

    fn removeViewer(h: *Host, v: *Viewer) void {
        h.mutex.lock();
        var left: usize = 0;
        for (&h.viewers) |*s| {
            if (s.* == v) s.* = null;
            if (s.* != null) left += 1;
        }
        if (left == 0) h.idle_since_us = mac.rdc_mac_now_us();
        h.updateCodecsLocked();
        h.mutex.unlock();

        v.abort();
        if (v.writer) |t| t.join();
        v.drain();
        mac.rdc_mac_release_all();
        log("зритель {s} отключился", .{v.peer.str()});
        h.gpa.destroy(v);
        h.updateStatus();
    }

    fn viewerCount(h: *Host) usize {
        h.mutex.lock();
        defer h.mutex.unlock();
        var n: usize = 0;
        for (h.viewers) |maybe| {
            if (maybe != null) n += 1;
        }
        return n;
    }

    fn updateCodecsLocked(h: *Host) void {
        var any_h264 = false;
        var any_jpeg = false;
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            if (v.h264) any_h264 = true else any_jpeg = true;
        }
        mac.rdc_mac_set_codecs(@intFromBool(any_h264), @intFromBool(any_jpeg));
    }

    fn broadcastText(h: *Host, payload: []const u8) void {
        h.mutex.lock();
        defer h.mutex.unlock();
        h.broadcastTextLocked(payload);
    }

    fn broadcastTextLocked(h: *Host, payload: []const u8) void {
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            v.pushText(payload);
        }
    }

    fn ensureCapture(h: *Host) void {
        h.capture_mutex.lock();
        defer h.capture_mutex.unlock();
        if (h.capturing) return;
        const rc = mac.rdc_mac_capture_start(h.opts.max_width, h.opts.fps, onFrame, h);
        if (rc == 0) {
            h.capturing = true;
            return;
        }
        log("захват не запустился ({d})", .{rc});
        h.broadcastText("{\"t\":\"err\",\"msg\":\"На компьютере нет разрешения «Запись экрана» для RDC\"}");
    }

    fn stopCaptureIfIdle(h: *Host) void {
        h.mutex.lock();
        var count: usize = 0;
        for (h.viewers) |maybe| {
            if (maybe != null) count += 1;
        }
        const idle_since = h.idle_since_us;
        h.mutex.unlock();
        if (count > 0) return;
        h.capture_mutex.lock();
        defer h.capture_mutex.unlock();
        if (!h.capturing or mac.rdc_mac_now_us() - idle_since < capture_idle_stop_us) return;
        mac.rdc_mac_capture_stop();
        h.capturing = false;
        h.mutex.lock();
        h.frame_w = 0;
        h.frame_h = 0;
        h.mutex.unlock();
    }

    fn onFrame(ctx: ?*anyopaque, codec: c_int, data: [*]const u8, len: usize, keyframe: c_int, ts_us: u64, w: c_int, hgt: c_int) callconv(.c) void {
        const h: *Host = @ptrCast(@alignCast(ctx orelse return));
        h.distribute(codec, data[0..len], keyframe != 0, ts_us, w, hgt);
    }

    fn distribute(h: *Host, codec: c_int, data: []const u8, key: bool, ts_us: u64, w: c_int, hgt: c_int) void {
        const is_h264 = codec == mac.codec_h264;
        const kind: Msg.Kind = if (!is_h264) .jpeg else if (key) .h264_key else .h264_delta;
        var fh: [proto.frame_header_len]u8 = undefined;
        proto.frameHeader(&fh, if (is_h264) .h264 else .jpeg, key, ts_us);
        var wh_buf: [10]u8 = undefined;
        const wh = ws.header(&wh_buf, .binary, fh.len + data.len);
        const m = Msg.create(h.gpa, kind, wh.len + fh.len + data.len) orelse return;
        @memcpy(m.bytes[0..wh.len], wh);
        @memcpy(m.bytes[wh.len..][0..fh.len], &fh);
        @memcpy(m.bytes[wh.len + fh.len ..], data);

        h.mutex.lock();
        defer h.mutex.unlock();
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
        h.mutex.lock();
        defer h.mutex.unlock();
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            v.pushText(bye);
            v.finish();
        }
    }

    fn renewCode(h: *Host) void {
        h.mutex.lock();
        h.code = newCode();
        h.failed = 0;
        h.locked_until_us = 0;
        h.mutex.unlock();
        h.kickAll("Код сменился — нужен новый");
        h.refreshUi(false);
    }

    fn refreshUi(h: *Host, prompt: bool) void {
        if (!h.opts.ui) return;
        var code_buf: [12]u8 = undefined;
        var link_buf: [160]u8 = undefined;
        h.mutex.lock();
        const shown = h.code.display(code_buf[0..11]);
        const digits = h.code.digits;
        h.mutex.unlock();
        code_buf[shown.len] = 0;
        const link = std.fmt.bufPrint(link_buf[0 .. link_buf.len - 1], "http://{s}:{d}/#{s}", .{ h.ip[0..h.ip_len], h.port, &digits }) catch return;
        link_buf[link.len] = 0;
        mac.rdc_mac_app_set_info(code_buf[0..shown.len :0].ptr, link_buf[0..link.len :0].ptr);
        const p: c_int = @intFromBool(prompt);
        mac.rdc_mac_app_set_permissions(mac.rdc_mac_screen_access(p), mac.rdc_mac_input_access(p));
        h.updateStatus();
    }

    fn updateStatus(h: *Host) void {
        if (!h.opts.ui) return;
        var buf: [256]u8 = undefined;
        var n: usize = 0;
        h.mutex.lock();
        for (h.viewers) |maybe| {
            const v = maybe orelse continue;
            const prefix: []const u8 = if (n == 0) "Подключено: " else ", ";
            const part = std.fmt.bufPrint(buf[n .. buf.len - 1], "{s}{s}", .{ prefix, v.peer.str() }) catch break;
            n += part.len;
        }
        h.mutex.unlock();
        if (n == 0) {
            const idle = "Ждём подключения по ссылке или коду";
            @memcpy(buf[0..idle.len], idle);
            n = idle.len;
        }
        buf[n] = 0;
        mac.rdc_mac_app_set_status(buf[0..n :0].ptr);
    }

    fn housekeeping(h: *Host) void {
        var tick: u32 = 0;
        while (true) : (tick +%= 1) {
            var ts: c.timespec = .{ .sec = 1, .nsec = 0 };
            _ = c.nanosleep(&ts, null);
            h.stopCaptureIfIdle();
            if (h.opts.ui and tick % 2 == 0) {
                mac.rdc_mac_app_set_permissions(mac.rdc_mac_screen_access(0), mac.rdc_mac_input_access(0));
            }
            h.updater.tick(h.viewerCount());
        }
    }
};

fn applyInput(in: proto.Input) void {
    switch (in) {
        .move => |m| mac.rdc_mac_mouse_move(m.x, m.y),
        .button => |b| mac.rdc_mac_mouse_button(b.button, @intFromBool(b.down), b.x, b.y),
        .wheel => |w| mac.rdc_mac_scroll(w.dx, w.dy),
        .key => |k| if (keymap.macKeycode(k.usage)) |kc| mac.rdc_mac_key(kc, @intFromBool(k.down)),
        .release_all => mac.rdc_mac_release_all(),
        .keyframe => mac.rdc_mac_request_keyframe(),
    }
}

fn onReady(ctx: ?*anyopaque) callconv(.c) void {
    const h: *Host = @ptrCast(@alignCast(ctx orelse return));
    h.refreshUi(true);
    h.updater.publish();
}

fn onAction(ctx: ?*anyopaque, action: c_int) callconv(.c) void {
    const h: *Host = @ptrCast(@alignCast(ctx orelse return));
    switch (action) {
        mac.action_disconnect_all => h.kickAll("Хост завершил сеанс"),
        mac.action_new_code => h.renewCode(),
        mac.action_check_update => h.updater.checkNow(),
        mac.action_install_update => {
            h.kickAll("Компьютер обновляет RDC — подключитесь снова через минуту");
            h.updater.installNow();
        },
        mac.action_auto_update_on => h.updater.setAuto(true),
        mac.action_auto_update_off => h.updater.setAuto(false),
        else => {},
    }
}

pub fn run(gpa: std.mem.Allocator, opts: Options) !void {
    const h = try Host.create(gpa, opts);
    try h.listen();
    var code_buf: [11]u8 = undefined;
    log("RDC {s}: код {s}, ссылка http://{s}:{d}/#{s}", .{ version, h.code.display(&code_buf), h.ip[0..h.ip_len], h.port, &h.code.digits });
    const server = try std.Thread.spawn(.{}, Host.serve, .{h});
    const keeper = try std.Thread.spawn(.{}, Host.housekeeping, .{h});
    keeper.detach();
    if (opts.ui) {
        mac.rdc_mac_app_run(onReady, onAction, h);
    } else {
        server.join();
    }
}
