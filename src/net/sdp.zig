//! SDP for a WebRTC data channel (RFC 8866, RFC 8841): reads the browser's offer and
//! writes the host's answer. Only what one data channel over UDP/DTLS/SCTP needs.
const std = @import("std");
const net = std.Io.net;

pub const max_candidates = 16;

pub const Setup = enum { actpass, active, passive };

pub const Offer = struct {
    /// Slices point into the SDP text.
    ufrag: []const u8,
    pwd: []const u8,
    /// SHA-256 fingerprint of the browser's DTLS certificate.
    fingerprint: [32]u8,
    setup: Setup,
    mid: []const u8,
    sctp_port: u16,
    max_message_size: u32,
    candidates: [max_candidates]net.IpAddress = undefined,
    candidate_count: usize = 0,

    pub fn addCandidate(o: *Offer, addr: net.IpAddress) void {
        for (o.candidates[0..o.candidate_count]) |*c| if (c.eql(&addr)) return;
        if (o.candidate_count == max_candidates) return;
        o.candidates[o.candidate_count] = addr;
        o.candidate_count += 1;
    }
};

pub const Error = error{ NoDataChannel, NoIceCredentials, NoFingerprint, DtlsRoleUnsupported };

fn lines(sdp: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, sdp, '\n');
}

fn attr(line: []const u8, comptime name: []const u8) ?[]const u8 {
    const prefix = "a=" ++ name ++ ":";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return std.mem.trim(u8, line[prefix.len..], " \t");
}

pub fn parseOffer(sdp: []const u8) Error!Offer {
    var ufrag: ?[]const u8 = null;
    var pwd: ?[]const u8 = null;
    var fingerprint: ?[32]u8 = null;
    var setup: Setup = .actpass;
    var mid: []const u8 = "0";
    var sctp_port: u16 = 5000;
    var max_message_size: u32 = 65536;
    var in_media = false; // inside the m=application section
    var seen_media = false;
    var offer: Offer = .{ .ufrag = "", .pwd = "", .fingerprint = undefined, .setup = .actpass, .mid = "", .sctp_port = 0, .max_message_size = 0 };

    var it = lines(sdp);
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "m=")) {
            // Only the first data channel section counts; audio and video are ignored.
            in_media = !seen_media and std.mem.startsWith(u8, line, "m=application ") and
                std.mem.find(u8, line, "webrtc-datachannel") != null;
            if (in_media) seen_media = true;
            continue;
        }
        // ICE and DTLS attributes may sit at the session level (Firefox) or in the section (Chrome).
        if (seen_media and !in_media) continue;
        if (attr(line, "ice-ufrag")) |v| ufrag = v;
        if (attr(line, "ice-pwd")) |v| pwd = v;
        if (attr(line, "fingerprint")) |v| {
            if (parseFingerprint(v)) |f| fingerprint = f;
        }
        if (attr(line, "setup")) |v| {
            if (std.mem.eql(u8, v, "active")) setup = .active else if (std.mem.eql(u8, v, "passive")) setup = .passive else setup = .actpass;
        }
        if (!in_media) continue;
        if (attr(line, "mid")) |v| mid = v;
        if (attr(line, "sctp-port")) |v| sctp_port = std.fmt.parseInt(u16, v, 10) catch 5000;
        if (attr(line, "max-message-size")) |v| max_message_size = std.fmt.parseInt(u32, v, 10) catch 65536;
        if (attr(line, "candidate")) |v| {
            if (parseCandidate(v)) |c| offer.addCandidate(c);
        }
    }
    if (!seen_media) return error.NoDataChannel;
    offer.ufrag = ufrag orelse return error.NoIceCredentials;
    offer.pwd = pwd orelse return error.NoIceCredentials;
    if (offer.ufrag.len == 0 or offer.pwd.len == 0) return error.NoIceCredentials;
    offer.fingerprint = fingerprint orelse return error.NoFingerprint;
    // The host is always the DTLS server: the browser must be able to be the client.
    if (setup == .passive) return error.DtlsRoleUnsupported;
    offer.setup = setup;
    offer.mid = mid;
    offer.sctp_port = sctp_port;
    offer.max_message_size = if (max_message_size == 0) 1 << 30 else max_message_size; // 0 — no limit
    return offer;
}

/// "sha-256 AB:CD:…" → 32 bytes; other hash functions are not accepted.
pub fn parseFingerprint(v: []const u8) ?[32]u8 {
    const sp = std.mem.findScalar(u8, v, ' ') orelse return null;
    if (!std.ascii.eqlIgnoreCase(v[0..sp], "sha-256")) return null;
    const hex = std.mem.trim(u8, v[sp + 1 ..], " ");
    if (hex.len != 32 * 3 - 1) return null;
    var out: [32]u8 = undefined;
    for (0..32) |i| {
        if (i > 0 and hex[i * 3 - 1] != ':') return null;
        out[i] = std.fmt.parseInt(u8, hex[i * 3 ..][0..2], 16) catch return null;
    }
    return out;
}

/// A UDP candidate of component 1 with a literal IP address: "candidate:…" or what follows "a=candidate:".
/// mDNS names (….local) and TCP candidates are skipped: the host cannot use them.
pub fn parseCandidate(text: []const u8) ?net.IpAddress {
    var s = std.mem.trim(u8, text, " \r\n");
    if (std.mem.startsWith(u8, s, "a=")) s = s[2..];
    if (std.mem.startsWith(u8, s, "candidate:")) s = s["candidate:".len..];
    var f = std.mem.tokenizeScalar(u8, s, ' ');
    _ = f.next() orelse return null; // foundation
    const component = f.next() orelse return null;
    const transport = f.next() orelse return null;
    _ = f.next() orelse return null; // priority
    const ip = f.next() orelse return null;
    const port_s = f.next() orelse return null;
    if (!std.mem.eql(u8, component, "1") or !std.ascii.eqlIgnoreCase(transport, "udp")) return null;
    const port = std.fmt.parseInt(u16, port_s, 10) catch return null;
    if (port == 0) return null;
    const addr = net.IpAddress.parse(ip, port) catch return null;
    return addr;
}

/// IP address without the port, as SDP wants it: "192.0.2.1", "2001:db8::1".
pub fn formatIp(buf: *[64]u8, addr: net.IpAddress) []const u8 {
    switch (addr) {
        .ip4 => |a| return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch unreachable,
        .ip6 => |a| {
            var plain = a;
            plain.port = 0;
            plain.interface = .none;
            const s = std.fmt.bufPrint(buf, "{f}", .{net.IpAddress{ .ip6 = plain }}) catch return "::";
            // "[2001:db8::1]:0" → "2001:db8::1"
            const close = std.mem.findScalar(u8, s, ']') orelse return s;
            return s[1..close];
        },
    }
}

pub const Candidate = struct {
    addr: net.IpAddress,
    kind: enum { host, srflx },
};

pub const Answer = struct {
    session_id: u64,
    ufrag: []const u8,
    pwd: []const u8,
    fingerprint: [32]u8,
    mid: []const u8,
    max_message_size: u32,
    candidates: []const Candidate,
};

pub fn writeAnswer(buf: []u8, a: Answer) error{NoSpaceLeft}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("v=0\r\no=- {d} 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE {s}\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\n" ++
        "a=ice-ufrag:{s}\r\na=ice-pwd:{s}\r\na=ice-options:trickle\r\na=fingerprint:sha-256 ", .{ a.session_id, a.mid, a.ufrag, a.pwd }) catch return error.NoSpaceLeft;
    for (a.fingerprint, 0..) |byte, i| w.print("{s}{X:0>2}", .{ if (i == 0) "" else ":", byte }) catch return error.NoSpaceLeft;
    w.print("\r\na=setup:passive\r\na=mid:{s}\r\na=sctp-port:5000\r\na=max-message-size:{d}\r\n", .{ a.mid, a.max_message_size }) catch return error.NoSpaceLeft;
    for (a.candidates, 0..) |c, i| {
        var ip_buf: [64]u8 = undefined;
        const ip = formatIp(&ip_buf, c.addr);
        const local_pref: u32 = @intCast(65535 - @min(i, 65535));
        switch (c.kind) {
            .host => w.print("a=candidate:{d} 1 udp {d} {s} {d} typ host\r\n", .{ i + 1, priority(126, local_pref), ip, c.addr.getPort() }) catch return error.NoSpaceLeft,
            .srflx => w.print("a=candidate:{d} 1 udp {d} {s} {d} typ srflx raddr {s} rport 0\r\n", .{
                i + 1,
                priority(100, local_pref),
                ip,
                c.addr.getPort(),
                if (c.addr == .ip4) "0.0.0.0" else "::",
            }) catch return error.NoSpaceLeft,
        }
    }
    w.writeAll("a=end-of-candidates\r\n") catch return error.NoSpaceLeft;
    return w.buffered();
}

fn priority(type_pref: u32, local_pref: u32) u32 {
    return (type_pref << 24) | (local_pref << 8) | (256 - 1);
}

const chrome_offer =
    "v=0\r\n" ++
    "o=- 4215775240449105457 2 IN IP4 127.0.0.1\r\n" ++
    "s=-\r\n" ++
    "t=0 0\r\n" ++
    "a=group:BUNDLE 0\r\n" ++
    "a=extmap-allow-mixed\r\n" ++
    "a=msid-semantic: WMS\r\n" ++
    "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
    "c=IN IP4 0.0.0.0\r\n" ++
    "a=candidate:3442447574 1 udp 2122260223 192.168.0.170 54805 typ host generation 0 network-id 1 network-cost 10\r\n" ++
    "a=candidate:842163049 1 udp 1686052607 203.0.113.7 54805 typ srflx raddr 192.168.0.170 rport 54805 generation 0 network-id 1\r\n" ++
    "a=candidate:2489145183 1 udp 2122194687 9d5e5a5c-36f1-4c9a-9a1f-0a2b3c4d5e6f.local 61234 typ host generation 0 network-id 2\r\n" ++
    "a=candidate:1 1 tcp 1518280447 192.168.0.170 9 typ host tcptype active generation 0\r\n" ++
    "a=candidate:7 1 udp 1686052607 2001:db8::5 50000 typ srflx raddr :: rport 0 generation 0\r\n" ++
    "a=ice-ufrag:Yqcd\r\n" ++
    "a=ice-pwd:lI3jhCV3uq0ab5tmhDnbn/VS\r\n" ++
    "a=ice-options:trickle\r\n" ++
    "a=fingerprint:sha-256 5B:4E:A1:E9:6B:82:20:A0:5D:C7:6B:9E:CF:3D:0B:4D:47:47:6F:23:7B:2A:2C:27:3D:98:2B:7A:66:9E:82:05\r\n" ++
    "a=setup:actpass\r\n" ++
    "a=mid:0\r\n" ++
    "a=sctp-port:5000\r\n" ++
    "a=max-message-size:262144\r\n";

test "sdp: Chrome offer" {
    const o = try parseOffer(chrome_offer);
    try std.testing.expectEqualStrings("Yqcd", o.ufrag);
    try std.testing.expectEqualStrings("lI3jhCV3uq0ab5tmhDnbn/VS", o.pwd);
    try std.testing.expectEqual(@as(u8, 0x5B), o.fingerprint[0]);
    try std.testing.expectEqual(@as(u8, 0x05), o.fingerprint[31]);
    try std.testing.expectEqual(Setup.actpass, o.setup);
    try std.testing.expectEqualStrings("0", o.mid);
    try std.testing.expectEqual(@as(u32, 262144), o.max_message_size);
    // host + srflx IPv4 + srflx IPv6; the mDNS name and the TCP candidate are skipped.
    try std.testing.expectEqual(@as(usize, 3), o.candidate_count);
    try std.testing.expectEqualSlices(u8, &.{ 203, 0, 113, 7 }, &o.candidates[1].ip4.bytes);
    try std.testing.expectEqual(@as(u16, 50000), o.candidates[2].getPort());
}

test "sdp: Firefox puts the fingerprint at the session level" {
    const ff = "v=0\r\no=mozilla...THIS_IS_SDPARTA-99.0 1 0 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\n" ++
        "a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r\n" ++
        "a=group:BUNDLE 0\r\na=ice-options:trickle\r\na=msid-semantic:WMS *\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\n" ++
        "a=candidate:0 1 UDP 2122252543 10.0.0.5 53519 typ host\r\n" ++
        "a=sendrecv\r\na=ice-pwd:f7a6d3b0c4c3a3e0e6a52e6e1a2b3c4d\r\na=ice-ufrag:9d1e6b2c\r\na=mid:0\r\na=setup:actpass\r\n" ++
        "a=sctp-port:5000\r\na=max-message-size:1073741823\r\n";
    const o = try parseOffer(ff);
    try std.testing.expectEqual(@as(u8, 0xFF), o.fingerprint[31]);
    try std.testing.expectEqualStrings("9d1e6b2c", o.ufrag);
    try std.testing.expectEqual(@as(usize, 1), o.candidate_count);
    try std.testing.expectEqual(@as(u32, 1073741823), o.max_message_size);
}

test "sdp: bad offers" {
    try std.testing.expectError(error.NoDataChannel, parseOffer("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"));
    try std.testing.expectError(error.NoFingerprint, parseOffer("v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=ice-ufrag:a\r\na=ice-pwd:b\r\n"));
    try std.testing.expectError(error.NoIceCredentials, parseOffer("v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"));
    const passive = "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=ice-ufrag:a\r\na=ice-pwd:b\r\n" ++
        "a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r\na=setup:passive\r\n";
    try std.testing.expectError(error.DtlsRoleUnsupported, parseOffer(passive));
    try std.testing.expectEqual(@as(?[32]u8, null), parseFingerprint("sha-1 00:11"));
}

test "sdp: trickled candidates" {
    const c = parseCandidate("candidate:842163049 1 udp 1677729535 198.51.100.4 60000 typ srflx raddr 0.0.0.0 rport 0 generation 0 ufrag Yqcd network-cost 999").?;
    try std.testing.expectEqualSlices(u8, &.{ 198, 51, 100, 4 }, &c.ip4.bytes);
    try std.testing.expectEqual(@as(?net.IpAddress, null), parseCandidate("candidate:1 2 udp 1 198.51.100.4 60000 typ host"));
    try std.testing.expectEqual(@as(?net.IpAddress, null), parseCandidate(""));
}

test "sdp: answer" {
    var buf: [2048]u8 = undefined;
    const cands = [_]Candidate{
        .{ .addr = .{ .ip4 = .{ .bytes = .{ 192, 168, 1, 10 }, .port = 40000 } }, .kind = .host },
        .{ .addr = .{ .ip4 = .{ .bytes = .{ 203, 0, 113, 9 }, .port = 41000 } }, .kind = .srflx },
        .{ .addr = try net.IpAddress.parse("2001:db8::7", 40000), .kind = .srflx },
    };
    var fp: [32]u8 = undefined;
    for (&fp, 0..) |*b, i| b.* = @intCast(i);
    const s = try writeAnswer(&buf, .{ .session_id = 42, .ufrag = "abcd", .pwd = "0123456789abcdefghijklmn", .fingerprint = fp, .mid = "0", .max_message_size = 65536, .candidates = &cands });
    try std.testing.expect(std.mem.find(u8, s, "a=setup:passive\r\n") != null);
    try std.testing.expect(std.mem.find(u8, s, "a=fingerprint:sha-256 00:01:02:03:") != null);
    try std.testing.expect(std.mem.find(u8, s, " 192.168.1.10 40000 typ host\r\n") != null);
    try std.testing.expect(std.mem.find(u8, s, " 203.0.113.9 41000 typ srflx raddr 0.0.0.0 rport 0\r\n") != null);
    try std.testing.expect(std.mem.find(u8, s, " 2001:db8::7 40000 typ srflx raddr :: rport 0\r\n") != null);
    // Our own candidate lines read back.
    var n: usize = 0;
    var it = lines(s);
    while (it.next()) |line| {
        if (attr(std.mem.trimEnd(u8, line, "\r"), "candidate")) |v| {
            const c = parseCandidate(v).?;
            try std.testing.expect(c.eql(&cands[n].addr));
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(error.DtlsRoleUnsupported, parseOffer(s));
}
