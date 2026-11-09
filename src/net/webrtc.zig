//! One browser viewer over WebRTC: a UDP socket, ICE (RFC 8445: host and
//! server-reflexive candidates, the host is the controlled agent and also sends checks
//! so its NAT opens toward the browser), DTLS 1.2 (dtls.zig) and SCTP (sctp.zig) with
//! one data channel.
//!
//! Threads: the session's own thread receives datagrams and runs the timers; the
//! viewer's writer thread calls `send`, which blocks while SCTP has no room. Messages
//! from the browser reach the callbacks on the session thread, outside the session lock.
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const stun = @import("stun.zig");
const sdp = @import("sdp.zig");
const dtls = @import("dtls.zig");
const sctp = @import("sctp.zig");

pub const StunServer = struct { host: []const u8, port: u16 };

/// Keep in sync with STUN in web/viewer.js.
pub const stun_servers = [_]StunServer{
    .{ .host = "stun.l.google.com", .port = 19302 },
    .{ .host = "stun.cloudflare.com", .port = 3478 },
};

/// Host → viewer binary messages travel in pieces of at most this size, each with a
/// one-byte prefix: 1 — more pieces follow, 0 — the last one (see core/proto.zig).
pub const piece_len = 16 * 1024;
/// SCTP slots a writer may fill before it waits: bounds the latency a slow network adds.
const max_buffered_slots = 220;
const connect_timeout_us: u64 = 20_000_000;
const idle_timeout_us: u64 = 30_000_000;
const tick_ms = 20;

pub const Callbacks = struct {
    ctx: *anyopaque,
    /// The SDP answer is ready: send it to the browser.
    answer: *const fn (ctx: *anyopaque, s: *Session, sdp_text: []const u8) void,
    /// A message from the browser: JSON text or binary input.
    message: *const fn (ctx: *anyopaque, s: *Session, binary: bool, data: []const u8) void,
    /// The session is over. The session is freed right after this returns.
    closed: *const fn (ctx: *anyopaque, s: *Session, reason: []const u8) void,
};

const Check = struct { tid: [12]u8, to: net.IpAddress };

const Inbox = struct {
    buf: [32 * 1024]u8 = undefined,
    used: usize = 0,
    items: [64]struct { off: u32, len: u32, binary: bool } = undefined,
    count: usize = 0,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cb: Callbacks,
    sock: net.Socket,
    /// The socket is IPv6 with IPv4 mapped in; false — IPv4 only.
    dual: bool,
    lan_ip: ?[4]u8,

    local_ufrag: [8]u8,
    local_pwd: [24]u8,
    remote_ufrag_buf: [256]u8 = undefined,
    remote_ufrag_len: usize = 0,
    remote_pwd_buf: [256]u8 = undefined,
    remote_pwd_len: usize = 0,
    max_message: u32,
    tie_breaker: u64,

    mutex: Io.Mutex = .init,
    room: Io.Condition = .init,
    remote: [sdp.max_candidates]net.IpAddress = undefined,
    remote_count: usize = 0,
    /// Addresses that proved they know the ICE password; DTLS is accepted only from them.
    valid: [8]net.IpAddress = undefined,
    valid_count: usize = 0,
    selected: ?net.IpAddress = null,
    /// The last checks sent, so their answers can be recognized; the first `check_count` are filled.
    checks: [32]Check = undefined,
    check_next: usize = 0,
    check_count: usize = 0,
    next_check_us: u64 = 0,
    stun_pending: [8]Check = undefined,
    stun_pending_count: usize = 0,
    stun_answered: [8]net.IpAddress = undefined,
    stun_answered_count: usize = 0,
    srflx: [4]net.IpAddress = undefined,
    srflx_count: usize = 0,

    tls: dtls.Server,
    assoc: sctp.Association,
    stream_id: u16 = 0,
    inbox: Inbox = .{},
    piece: [piece_len + 1]u8 = undefined,

    started_us: u64 = 0,
    last_rx_us: u64 = 0,
    closing: std.atomic.Value(bool) = .init(false),
    close_at_us: std.atomic.Value(u64) = .init(0),
    reason: []const u8 = "",
    /// Shown in the log and the window: the browser's address once ICE has picked a path.
    peer_buf: [64]u8 = undefined,
    peer_len: usize = 0,

    /// Parses the offer and starts the session thread, which gathers candidates and calls `answer`.
    pub fn start(gpa: std.mem.Allocator, io: Io, identity: *const dtls.Identity, offer_text: []const u8, lan_ip: ?[4]u8, cb: Callbacks) !*Session {
        const offer = try sdp.parseOffer(offer_text);
        if (offer.ufrag.len > 255 or offer.pwd.len > 255) return error.BadOffer;
        var sock: net.Socket = undefined;
        var dual = true;
        const any6 = net.IpAddress.parse("::", 0) catch unreachable;
        if (any6.bind(io, .{ .mode = .dgram, .ip6_only = false })) |s6| {
            sock = s6;
        } else |_| {
            const any4 = net.IpAddress.parse("0.0.0.0", 0) catch unreachable;
            sock = try any4.bind(io, .{ .mode = .dgram });
            dual = false;
        }
        errdefer sock.close(io);

        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .cb = cb,
            .sock = sock,
            .dual = dual,
            .lan_ip = lan_ip,
            .local_ufrag = undefined,
            .local_pwd = undefined,
            .max_message = offer.max_message_size,
            .tie_breaker = std.mem.readInt(u64, &rnd, .little),
            .tls = undefined,
            .assoc = undefined,
        };
        s.tls.init(io, identity, offer.fingerprint);
        s.assoc.init(io);
        randomIceChars(io, &s.local_ufrag);
        randomIceChars(io, &s.local_pwd);
        @memcpy(s.remote_ufrag_buf[0..offer.ufrag.len], offer.ufrag);
        s.remote_ufrag_len = offer.ufrag.len;
        @memcpy(s.remote_pwd_buf[0..offer.pwd.len], offer.pwd);
        s.remote_pwd_len = offer.pwd.len;
        for (offer.candidates[0..offer.candidate_count]) |c| _ = s.addRemoteLocked(c);
        s.started_us = s.now();
        s.last_rx_us = s.started_us;

        const mid = offer.mid;
        if (mid.len > 32) return error.BadOffer;
        var mid_buf: [32]u8 = undefined;
        @memcpy(mid_buf[0..mid.len], mid);
        const t = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, run, .{ s, mid_buf, mid.len });
        t.detach();
        return s;
    }

    fn now(s: *Session) u64 {
        return @intCast(@divTrunc(Io.Clock.awake.now(s.io).nanoseconds, 1000));
    }

    fn remoteUfrag(s: *const Session) []const u8 {
        return s.remote_ufrag_buf[0..s.remote_ufrag_len];
    }

    fn remotePwd(s: *const Session) []const u8 {
        return s.remote_pwd_buf[0..s.remote_pwd_len];
    }

    pub fn peer(s: *const Session) []const u8 {
        return s.peer_buf[0..s.peer_len];
    }

    // ------------------------------------------------------------------ API for the host

    /// Sends one protocol message; binary ones go in pieces. Blocks while the network is slower than the data.
    pub fn send(s: *Session, binary: bool, data: []const u8) error{Closed}!void {
        if (!binary) return s.queue(sctp.ppid_string, data, true);
        // Pieces stay within what the browser accepts (its a=max-message-size).
        const max_piece = @min(piece_len, s.max_message -| 1);
        if (max_piece == 0) return;
        var off: usize = 0;
        while (true) {
            const take = @min(max_piece, data.len - off);
            const last = off + take == data.len;
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            try s.waitRoomLocked(take + 1);
            s.piece[0] = if (last) 0 else 1;
            @memcpy(s.piece[1..][0..take], data[off..][0..take]);
            s.assoc.queueMessage(s.stream_id, sctp.ppid_binary, s.piece[0 .. take + 1]) catch return error.Closed;
            s.assoc.flush(s.now(), s.sctpSink());
            off += take;
            if (last) return;
        }
    }

    fn queue(s: *Session, ppid: u32, data: []const u8, wait: bool) error{Closed}!void {
        if (data.len > s.max_message) return; // the browser would refuse it
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (wait) try s.waitRoomLocked(data.len);
        s.assoc.queueMessage(s.stream_id, ppid, data) catch |e| switch (e) {
            error.Full => return, // only when not waiting: the message is dropped
            error.Closed => return error.Closed,
        };
        s.assoc.flush(s.now(), s.sctpSink());
    }

    fn waitRoomLocked(s: *Session, len: usize) error{Closed}!void {
        const need = sctp.Association.slotsFor(len);
        while (true) {
            if (s.closing.load(.acquire) or s.assoc.state == .closed) return error.Closed;
            if (s.assoc.state == .established and s.assoc.usedSlots() + need <= max_buffered_slots) return;
            const deadline: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } };
            s.room.waitTimeout(s.io, &s.mutex, deadline.toDeadline(s.io)) catch {};
        }
    }

    /// Best effort, never blocks: for error messages before a viewer is admitted.
    pub fn sendText(s: *Session, text: []const u8) void {
        s.queue(sctp.ppid_string, text, false) catch {};
    }

    /// Ends the session from the host's side; `closed` follows on the session thread.
    pub fn close(s: *Session) void {
        s.closing.store(true, .release);
        s.room.broadcast(s.io);
    }

    /// Ends the session after a delay, so the last messages still get through.
    pub fn closeAfter(s: *Session, ms: u64) void {
        const at = s.now() + ms * 1000;
        const cur = s.close_at_us.load(.monotonic);
        if (cur == 0 or at < cur) s.close_at_us.store(at, .monotonic);
    }

    /// A candidate the browser found after its offer (trickle ICE). Only a new address is checked
    /// right away: a candidate that comes again (through the other broker, or replayed) changes nothing.
    pub fn addCandidate(s: *Session, line: []const u8) void {
        const addr = sdp.parseCandidate(line) orelse return;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.addRemoteLocked(addr)) s.next_check_us = 0;
    }

    /// false — not usable, already known, or no room.
    fn addRemoteLocked(s: *Session, addr_in: net.IpAddress) bool {
        const addr = normalize(addr_in);
        if (addr == .ip6 and !s.dual) return false;
        if (!routable(addr)) return false;
        for (s.remote[0..s.remote_count]) |*c| if (c.eql(&addr)) return false;
        if (s.remote_count == s.remote.len) return false;
        s.remote[s.remote_count] = addr;
        s.remote_count += 1;
        return true;
    }

    // ------------------------------------------------------------------ the session thread

    fn run(s: *Session, mid_buf: [32]u8, mid_len: usize) void {
        var answer: [2048]u8 = undefined;
        s.gather();
        s.sendAnswer(&answer, mid_buf[0..mid_len]);
        var buf: [2048]u8 = undefined;
        while (true) {
            const t = s.now();
            if (s.closing.load(.acquire)) break;
            const close_at = s.close_at_us.load(.monotonic);
            if (close_at != 0 and t >= close_at) break;
            if (!s.tls.established() and t -| s.started_us > connect_timeout_us) {
                s.reason = "no direct path to the browser (ICE)";
                break;
            }
            if (t -| s.last_rx_us > idle_timeout_us) {
                s.reason = "the browser went silent";
                break;
            }
            if (s.tls.state == .failed) {
                s.reason = s.tls.reason;
                break;
            }
            if (s.tls.state == .closed or s.assoc.state == .closed) {
                if (s.reason.len == 0) s.reason = "the browser closed the connection";
                break;
            }
            s.timers(t);
            const msg = s.sock.receiveTimeout(s.io, &buf, .{ .duration = .{ .raw = .fromMilliseconds(tick_ms), .clock = .awake } }) catch |e| switch (e) {
                error.Timeout => continue,
                error.Canceled => break,
                else => {
                    // ICMP errors from a candidate that does not answer come back here; keep going.
                    s.io.sleep(.fromMilliseconds(5), .awake) catch {};
                    continue;
                },
            };
            s.onDatagram(normalize(msg.from), msg.data);
            s.dispatch();
        }
        s.mutex.lockUncancelable(s.io);
        s.closing.store(true, .release);
        s.assoc.abort(s.sctpSink());
        s.tls.close(s.dtlsSink());
        s.room.broadcast(s.io);
        s.mutex.unlock(s.io);
        s.cb.closed(s.cb.ctx, s, if (s.reason.len > 0) s.reason else "closed");
        s.sock.close(s.io);
        s.gpa.destroy(s);
    }

    /// Server-reflexive candidates: ask the STUN servers what our address looks like from outside.
    fn gather(s: *Session) void {
        var targets: [8]net.IpAddress = undefined;
        var n: usize = 0;
        for (stun_servers) |srv| {
            const host_name = net.HostName.init(srv.host) catch continue;
            var results: [16]net.HostName.LookupResult = undefined;
            var q: Io.Queue(net.HostName.LookupResult) = .init(&results);
            host_name.lookup(s.io, &q, .{ .port = srv.port }) catch continue;
            var v4 = false;
            var v6 = false;
            while (q.getOne(s.io)) |r| switch (r) {
                .address => |a| {
                    // One address of each family per server is enough.
                    if (n == targets.len or (a == .ip4 and v4) or (a == .ip6 and (v6 or !s.dual))) continue;
                    if (a == .ip4) v4 = true else v6 = true;
                    targets[n] = a;
                    n += 1;
                },
                .canonical_name => {},
            } else |_| {}
        }
        // Ask every server (one retry for the silent ones) until all that could be reached have answered.
        const deadline = s.now() + 700_000;
        var round: usize = 0;
        var next_send: u64 = 0;
        var buf: [1500]u8 = undefined;
        while (s.now() < deadline) {
            if (s.now() >= next_send and round < 3) {
                round += 1;
                next_send = s.now() + 250_000;
                s.mutex.lockUncancelable(s.io);
                s.stun_pending_count = 0;
                for (targets[0..n]) |to| {
                    if (round > 1 and s.answered(to)) continue;
                    var tid: [12]u8 = undefined;
                    s.io.random(&tid);
                    var b: [512]u8 = undefined;
                    var m = stun.Builder.init(&b, stun.binding_request, tid);
                    m.addFingerprint();
                    if (!s.sendToOk(to, m.bytes())) continue; // no route (IPv6 without IPv6): don't wait for it
                    if (s.stun_pending_count < s.stun_pending.len) {
                        s.stun_pending[s.stun_pending_count] = .{ .tid = tid, .to = to };
                        s.stun_pending_count += 1;
                    }
                }
                const waiting = s.stun_pending_count;
                s.mutex.unlock(s.io);
                if (waiting == 0) break;
            }
            const msg = s.sock.receiveTimeout(s.io, &buf, .{ .duration = .{ .raw = .fromMilliseconds(tick_ms), .clock = .awake } }) catch continue;
            s.onDatagram(normalize(msg.from), msg.data);
            s.mutex.lockUncancelable(s.io);
            const left = s.stun_pending_count;
            s.mutex.unlock(s.io);
            if (left == 0) break;
        }
        s.mutex.lockUncancelable(s.io);
        s.stun_pending_count = 0;
        s.mutex.unlock(s.io);
    }

    fn answered(s: *const Session, to: net.IpAddress) bool {
        for (s.stun_answered[0..s.stun_answered_count]) |*a| if (a.eql(&to)) return true;
        return false;
    }

    fn sendAnswer(s: *Session, out: *[2048]u8, mid: []const u8) void {
        var cands: [8]sdp.Candidate = undefined;
        var n: usize = 0;
        const port = s.sock.address.getPort();
        if (s.lan_ip) |ip| {
            if (!(ip[0] == 127)) {
                cands[n] = .{ .addr = .{ .ip4 = .{ .bytes = ip, .port = port } }, .kind = .host };
                n += 1;
            }
        }
        s.mutex.lockUncancelable(s.io);
        for (s.srflx[0..s.srflx_count]) |a| {
            if (n == cands.len) break;
            cands[n] = .{ .addr = a, .kind = .srflx };
            n += 1;
        }
        s.mutex.unlock(s.io);
        var session_id: [8]u8 = undefined;
        s.io.random(&session_id);
        const text = sdp.writeAnswer(out, .{
            .session_id = std.mem.readInt(u64, &session_id, .little) >> 2,
            .ufrag = &s.local_ufrag,
            .pwd = &s.local_pwd,
            .fingerprint = s.tls.identity.fingerprint,
            .mid = mid,
            .max_message_size = 64 * 1024,
            .candidates = cands[0..n],
        }) catch return;
        s.cb.answer(s.cb.ctx, s, text);
        s.next_check_us = 0;
    }

    fn timers(s: *Session, t: u64) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (!s.tls.established() and t >= s.next_check_us) {
            // Checks open our NAT toward every browser candidate: fast at first, then slower.
            s.next_check_us = t + if (t -| s.started_us < 3_000_000) @as(u64, 100_000) else 400_000;
            for (s.remote[0..s.remote_count]) |to| s.sendCheck(to);
        }
        s.tls.tick(t, s.dtlsSink());
        s.assoc.tick(t, s.sctpSink());
        if (s.assoc.freed) {
            s.assoc.freed = false;
            s.room.broadcast(s.io);
        }
    }

    fn sendCheck(s: *Session, to: net.IpAddress) void {
        var tid: [12]u8 = undefined;
        s.io.random(&tid);
        var b: [512]u8 = undefined;
        var m = stun.Builder.init(&b, stun.binding_request, tid);
        var user: [256 + 1 + 8]u8 = undefined;
        const u = std.fmt.bufPrint(&user, "{s}:{s}", .{ s.remoteUfrag(), &s.local_ufrag }) catch return;
        m.add(stun.attr_username, u);
        m.addU64(stun.attr_ice_controlled, s.tie_breaker);
        m.addU32(stun.attr_priority, stun.priority(110, 65535));
        m.addIntegrity(s.remotePwd());
        m.addFingerprint();
        s.checks[s.check_next] = .{ .tid = tid, .to = to };
        s.check_next = (s.check_next + 1) % s.checks.len;
        s.check_count = @min(s.check_count + 1, s.checks.len);
        s.sendTo(to, m.bytes());
    }

    fn sendTo(s: *Session, to: net.IpAddress, data: []const u8) void {
        _ = s.sendToOk(to, data);
    }

    fn sendToOk(s: *Session, to: net.IpAddress, data: []const u8) bool {
        var dest = to;
        if (s.dual and to == .ip4) dest = mapped(to.ip4);
        s.sock.send(s.io, &dest, data) catch return false;
        return true;
    }

    fn onDatagram(s: *Session, from: net.IpAddress, data: []u8) void {
        if (data.len == 0) return;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const t = s.now();
        if (stun.isStun(data)) {
            s.onStun(from, data);
            return;
        }
        if (data[0] < 20 or data[0] > 63) return; // RTP and others: not ours (RFC 7983)
        if (!s.isValid(from)) return;
        if (s.selected == null or !s.selected.?.eql(&from)) s.select(from);
        s.last_rx_us = t;
        s.tls.handle(data, t, s.dtlsSink());
        if (s.assoc.freed) {
            s.assoc.freed = false;
            s.room.broadcast(s.io);
        }
    }

    fn onStun(s: *Session, from: net.IpAddress, data: []const u8) void {
        const m = stun.parse(data) orelse return;
        switch (m.msg_type) {
            stun.binding_request => {
                const user = m.username orelse return;
                if (user.len <= s.local_ufrag.len or !std.mem.startsWith(u8, user, &s.local_ufrag) or user[s.local_ufrag.len] != ':') return;
                if (!m.checkIntegrity(&s.local_pwd)) return;
                if (m.fingerprint_at != null and !m.checkFingerprint()) return;
                var b: [512]u8 = undefined;
                var r = stun.Builder.init(&b, stun.binding_success, m.tid);
                r.addXorAddress(from);
                r.addIntegrity(&s.local_pwd);
                r.addFingerprint();
                s.sendTo(from, r.bytes());
                s.last_rx_us = s.now();
                const known = s.isValid(from);
                s.markValid(from);
                if (!known) {
                    // A new path (peer-reflexive): check it back right away.
                    _ = s.addRemoteLocked(from);
                    if (!s.tls.established()) s.sendCheck(from);
                }
                if (m.use_candidate or s.selected == null) s.select(from);
            },
            stun.binding_success => {
                for (s.checks[0..s.check_count]) |c| {
                    if (!std.mem.eql(u8, &c.tid, &m.tid)) continue;
                    if (!m.checkIntegrity(s.remotePwd())) return;
                    s.markValid(c.to);
                    if (s.selected == null) s.select(c.to);
                    return;
                }
                for (s.stun_pending[0..s.stun_pending_count], 0..) |c, i| {
                    if (!std.mem.eql(u8, &c.tid, &m.tid)) continue;
                    s.stun_pending[i] = s.stun_pending[s.stun_pending_count - 1];
                    s.stun_pending_count -= 1;
                    if (s.stun_answered_count < s.stun_answered.len) {
                        s.stun_answered[s.stun_answered_count] = c.to;
                        s.stun_answered_count += 1;
                    }
                    const mapped_addr = normalize(m.xor_mapped orelse return);
                    for (s.srflx[0..s.srflx_count]) |*x| if (x.eql(&mapped_addr)) return;
                    if (s.srflx_count < s.srflx.len) {
                        s.srflx[s.srflx_count] = mapped_addr;
                        s.srflx_count += 1;
                    }
                    return;
                }
            },
            else => {},
        }
    }

    fn isValid(s: *const Session, a: net.IpAddress) bool {
        for (s.valid[0..s.valid_count]) |*v| if (v.eql(&a)) return true;
        return false;
    }

    fn markValid(s: *Session, a: net.IpAddress) void {
        if (s.isValid(a)) return;
        if (s.valid_count == s.valid.len) {
            std.mem.copyForwards(net.IpAddress, s.valid[0 .. s.valid.len - 1], s.valid[1..]);
            s.valid_count -= 1;
        }
        s.valid[s.valid_count] = a;
        s.valid_count += 1;
    }

    fn select(s: *Session, a: net.IpAddress) void {
        s.selected = a;
        var ip_buf: [64]u8 = undefined;
        const ip = sdp.formatIp(&ip_buf, a);
        @memcpy(s.peer_buf[0..ip.len], ip);
        s.peer_len = ip.len;
    }

    fn dispatch(s: *Session) void {
        // The inbox is filled under the lock by this thread only; read it without the lock.
        for (s.inbox.items[0..s.inbox.count]) |it| {
            s.cb.message(s.cb.ctx, s, it.binary, s.inbox.buf[it.off..][0..it.len]);
        }
        s.inbox.count = 0;
        s.inbox.used = 0;
    }

    // ------------------------------------------------------------------ glue

    fn dtlsSink(s: *Session) dtls.Sink {
        return .{ .ctx = s, .send = dtlsSend, .data = dtlsData };
    }

    fn dtlsSend(ctx: *anyopaque, datagram: []const u8) void {
        const s: *Session = @ptrCast(@alignCast(ctx));
        const to = s.selected orelse return;
        s.sendTo(to, datagram);
    }

    fn dtlsData(ctx: *anyopaque, plaintext: []u8) void {
        const s: *Session = @ptrCast(@alignCast(ctx));
        s.assoc.handlePacket(plaintext, s.now(), s.sctpSink());
    }

    fn sctpSink(s: *Session) sctp.Sink {
        return .{ .ctx = s, .send = sctpSend, .message = sctpMessage };
    }

    fn sctpSend(ctx: *anyopaque, packet: []const u8) void {
        const s: *Session = @ptrCast(@alignCast(ctx));
        s.tls.sendData(packet, s.dtlsSink());
    }

    fn sctpMessage(ctx: *anyopaque, sid: u16, ppid: u32, data: []const u8) void {
        const s: *Session = @ptrCast(@alignCast(ctx));
        if (ppid != sctp.ppid_string and ppid != sctp.ppid_binary) return;
        s.stream_id = sid; // answer on the stream the browser uses
        const ib = &s.inbox;
        if (ib.count == ib.items.len or ib.used + data.len > ib.buf.len) return;
        @memcpy(ib.buf[ib.used..][0..data.len], data);
        ib.items[ib.count] = .{ .off = @intCast(ib.used), .len = @intCast(data.len), .binary = ppid == sctp.ppid_binary };
        ib.count += 1;
        ib.used += data.len;
    }
};

/// Addresses a check can reach: not unspecified, multicast, broadcast or IPv6 link-local
/// (sending there fails with EINVAL, which debug builds treat as a bug).
fn routable(a: net.IpAddress) bool {
    switch (a) {
        .ip4 => |v| return v.bytes[0] != 0 and v.bytes[0] < 224 and v.port != 0,
        .ip6 => |v| {
            if (v.port == 0 or v.bytes[0] == 0xff) return false;
            if (v.bytes[0] == 0xfe and v.bytes[1] & 0xc0 == 0x80) return false; // fe80::/10
            for (v.bytes) |byte| if (byte != 0) return true;
            return false; // ::
        },
    }
}

/// IPv4 inside IPv6 (::ffff:a.b.c.d) → plain IPv4, so addresses compare equal however they arrive.
fn normalize(a: net.IpAddress) net.IpAddress {
    switch (a) {
        .ip4 => return a,
        .ip6 => |v| {
            const prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            if (std.mem.eql(u8, v.bytes[0..12], &prefix)) return .{ .ip4 = .{ .bytes = v.bytes[12..16].*, .port = v.port } };
            return .{ .ip6 = .{ .bytes = v.bytes, .port = v.port } };
        },
    }
}

fn mapped(a: net.Ip4Address) net.IpAddress {
    var b: [16]u8 = @splat(0);
    b[10] = 0xff;
    b[11] = 0xff;
    @memcpy(b[12..16], &a.bytes);
    return .{ .ip6 = .{ .bytes = b, .port = a.port } };
}

/// ICE ufrag and password characters (RFC 8839: ice-char = ALPHA / DIGIT / "+" / "/").
fn randomIceChars(io: Io, out: []u8) void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var r: [64]u8 = undefined;
    io.random(r[0..out.len]);
    for (out, 0..) |*c, i| c.* = alphabet[r[i] & 63];
}

test "webrtc: address normalization" {
    const m = mapped(.{ .bytes = .{ 203, 0, 113, 5 }, .port = 4000 });
    const n = normalize(m);
    try std.testing.expectEqualSlices(u8, &.{ 203, 0, 113, 5 }, &n.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 4000), n.ip4.port);
    const v6 = try net.IpAddress.parse("2001:db8::1", 9);
    try std.testing.expect(normalize(v6).eql(&v6));
    try std.testing.expect(routable(v6));
    try std.testing.expect(routable(n));
    try std.testing.expect(!routable(try net.IpAddress.parse("fe80::1", 9)));
    try std.testing.expect(!routable(try net.IpAddress.parse("ff02::1", 9)));
    try std.testing.expect(!routable(try net.IpAddress.parse("::", 9)));
    try std.testing.expect(!routable(try net.IpAddress.parse("239.1.2.3", 9)));
    try std.testing.expect(!routable(try net.IpAddress.parse("0.0.0.0", 9)));
}

/// A session without a socket or a thread: enough for the ICE bookkeeping.
fn testSession(io: Io) !*Session {
    const s = try std.testing.allocator.create(Session);
    s.* = .{
        .gpa = std.testing.allocator,
        .io = io,
        .cb = undefined,
        .sock = undefined,
        .dual = true,
        .lan_ip = null,
        .local_ufrag = @splat('u'),
        .local_pwd = @splat('p'),
        .max_message = 64 * 1024,
        .tie_breaker = 1,
        .tls = undefined,
        .assoc = undefined,
    };
    const pwd = "the-browsers-ice-password";
    @memcpy(s.remote_pwd_buf[0..pwd.len], pwd);
    s.remote_pwd_len = pwd.len;
    return s;
}

test "webrtc: a STUN answer counts only for a check that was sent" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const s = try testSession(threaded.io());
    defer std.testing.allocator.destroy(s);
    const browser = try net.IpAddress.parse("203.0.113.5", 5000);
    const Answer = struct {
        fn send(sess: *Session, from: net.IpAddress, tid: [12]u8) void {
            var b: [256]u8 = undefined;
            var m = stun.Builder.init(&b, stun.binding_success, tid);
            m.addXorAddress(from);
            m.addIntegrity(sess.remotePwd());
            m.addFingerprint();
            sess.onStun(from, m.bytes());
        }
    };
    // No check sent yet: an answer with the bytes an unfilled slot holds in safe builds matches nothing.
    Answer.send(s, browser, @splat(0xaa));
    Answer.send(s, browser, @splat(0));
    try std.testing.expectEqual(@as(usize, 0), s.valid_count);
    try std.testing.expectEqual(@as(?net.IpAddress, null), s.selected);
    // The answer to a check that went out makes its address valid and selected.
    s.checks[0] = .{ .tid = @splat(7), .to = browser };
    s.check_count = 1;
    Answer.send(s, browser, @splat(7));
    try std.testing.expectEqual(@as(usize, 1), s.valid_count);
    try std.testing.expect(s.selected.?.eql(&browser));
}

test "webrtc: a candidate that comes again does not start another round of checks" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const s = try testSession(threaded.io());
    defer std.testing.allocator.destroy(s);
    const line = "candidate:1 1 udp 2122260223 203.0.113.5 5000 typ host";
    s.next_check_us = 123;
    s.addCandidate(line);
    try std.testing.expectEqual(@as(usize, 1), s.remote_count);
    try std.testing.expectEqual(@as(u64, 0), s.next_check_us); // a new address: checked at once
    s.next_check_us = 123;
    s.addCandidate(line);
    s.addCandidate("a=candidate:9 1 UDP 1 203.0.113.5 5000 typ srflx raddr 0.0.0.0 rport 0");
    try std.testing.expectEqual(@as(usize, 1), s.remote_count);
    try std.testing.expectEqual(@as(u64, 123), s.next_check_us);
}
