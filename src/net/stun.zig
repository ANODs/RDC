//! STUN (RFC 8489) for ICE (RFC 8445): Binding requests and responses with short-term
//! credentials, XOR-MAPPED-ADDRESS, MESSAGE-INTEGRITY (HMAC-SHA1) and FINGERPRINT.
//! Pure logic over bytes — no sockets here.
const std = @import("std");
const net = std.Io.net;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

pub const magic_cookie: u32 = 0x2112A442;
pub const header_len = 20;

pub const binding_request: u16 = 0x0001;
pub const binding_success: u16 = 0x0101;
pub const binding_error: u16 = 0x0111;
pub const binding_indication: u16 = 0x0011;

pub const attr_mapped_address: u16 = 0x0001;
pub const attr_username: u16 = 0x0006;
pub const attr_message_integrity: u16 = 0x0008;
pub const attr_error_code: u16 = 0x0009;
pub const attr_xor_mapped_address: u16 = 0x0020;
pub const attr_priority: u16 = 0x0024;
pub const attr_use_candidate: u16 = 0x0025;
pub const attr_fingerprint: u16 = 0x8028;
pub const attr_ice_controlled: u16 = 0x8029;
pub const attr_ice_controlling: u16 = 0x802A;

const fingerprint_xor: u32 = 0x5354554e;

/// True if the datagram looks like STUN (RFC 7983: the first byte is 0–3, and the magic cookie).
pub fn isStun(data: []const u8) bool {
    return data.len >= header_len and data[0] < 4 and std.mem.readInt(u32, data[4..8], .big) == magic_cookie;
}

/// Builds a message into a caller's buffer (large enough: 512 bytes fit any message we send).
pub const Builder = struct {
    buf: []u8,
    len: usize,

    pub fn init(buf: []u8, msg_type: u16, tid: [12]u8) Builder {
        std.debug.assert(buf.len >= 256);
        std.mem.writeInt(u16, buf[0..2], msg_type, .big);
        std.mem.writeInt(u16, buf[2..4], 0, .big);
        std.mem.writeInt(u32, buf[4..8], magic_cookie, .big);
        @memcpy(buf[8..20], &tid);
        return .{ .buf = buf, .len = header_len };
    }

    fn setLength(b: *Builder, attrs_len: usize) void {
        std.mem.writeInt(u16, b.buf[2..4], @intCast(attrs_len), .big);
    }

    pub fn add(b: *Builder, attr_type: u16, value: []const u8) void {
        const padded = (value.len + 3) & ~@as(usize, 3);
        std.debug.assert(b.len + 4 + padded <= b.buf.len);
        std.mem.writeInt(u16, b.buf[b.len..][0..2], attr_type, .big);
        std.mem.writeInt(u16, b.buf[b.len + 2 ..][0..2], @intCast(value.len), .big);
        @memcpy(b.buf[b.len + 4 ..][0..value.len], value);
        @memset(b.buf[b.len + 4 + value.len ..][0 .. padded - value.len], 0);
        b.len += 4 + padded;
        b.setLength(b.len - header_len);
    }

    pub fn addU32(b: *Builder, attr_type: u16, v: u32) void {
        var x: [4]u8 = undefined;
        std.mem.writeInt(u32, &x, v, .big);
        b.add(attr_type, &x);
    }

    pub fn addU64(b: *Builder, attr_type: u16, v: u64) void {
        var x: [8]u8 = undefined;
        std.mem.writeInt(u64, &x, v, .big);
        b.add(attr_type, &x);
    }

    pub fn addXorAddress(b: *Builder, addr: net.IpAddress) void {
        var v: [20]u8 = undefined;
        const tid = b.buf[8..20];
        v[0] = 0;
        switch (addr) {
            .ip4 => |a| {
                v[1] = 1;
                std.mem.writeInt(u16, v[2..4], a.port ^ @as(u16, magic_cookie >> 16), .big);
                var cookie: [4]u8 = undefined;
                std.mem.writeInt(u32, &cookie, magic_cookie, .big);
                for (0..4) |i| v[4 + i] = a.bytes[i] ^ cookie[i];
                b.add(attr_xor_mapped_address, v[0..8]);
            },
            .ip6 => |a| {
                v[1] = 2;
                std.mem.writeInt(u16, v[2..4], a.port ^ @as(u16, magic_cookie >> 16), .big);
                var mask: [16]u8 = undefined;
                std.mem.writeInt(u32, mask[0..4], magic_cookie, .big);
                @memcpy(mask[4..16], tid);
                for (0..16) |i| v[4 + i] = a.bytes[i] ^ mask[i];
                b.add(attr_xor_mapped_address, v[0..20]);
            },
        }
    }

    /// MESSAGE-INTEGRITY: HMAC-SHA1 over everything before it, with the length as if it ended the message.
    pub fn addIntegrity(b: *Builder, key: []const u8) void {
        b.setLength(b.len - header_len + 24);
        var mac: [HmacSha1.mac_length]u8 = undefined;
        HmacSha1.create(&mac, b.buf[0..b.len], key);
        b.add(attr_message_integrity, &mac);
    }

    /// FINGERPRINT: CRC-32 of everything before it, XOR 0x5354554e. Always the last attribute.
    pub fn addFingerprint(b: *Builder) void {
        b.setLength(b.len - header_len + 8);
        const crc = std.hash.Crc32.hash(b.buf[0..b.len]) ^ fingerprint_xor;
        b.addU32(attr_fingerprint, crc);
    }

    pub fn bytes(b: *const Builder) []const u8 {
        return b.buf[0..b.len];
    }
};

pub const Message = struct {
    msg_type: u16,
    tid: [12]u8,
    raw: []const u8,
    username: ?[]const u8 = null,
    priority: ?u32 = null,
    use_candidate: bool = false,
    controlling: ?u64 = null,
    controlled: ?u64 = null,
    xor_mapped: ?net.IpAddress = null,
    error_code: ?u16 = null,
    /// Offsets of the MESSAGE-INTEGRITY and FINGERPRINT attributes in raw.
    integrity_at: ?usize = null,
    fingerprint_at: ?usize = null,

    /// MESSAGE-INTEGRITY with the short-term key (the ICE password).
    pub fn checkIntegrity(m: *const Message, key: []const u8) bool {
        const at = m.integrity_at orelse return false;
        var head: [4]u8 = undefined;
        std.mem.writeInt(u16, head[0..2], m.msg_type, .big);
        std.mem.writeInt(u16, head[2..4], @intCast(at - header_len + 24), .big);
        var h = HmacSha1.init(key);
        h.update(&head);
        h.update(m.raw[4..at]);
        var mac: [HmacSha1.mac_length]u8 = undefined;
        h.final(&mac);
        return std.crypto.timing_safe.eql([20]u8, mac, m.raw[at + 4 ..][0..20].*);
    }

    pub fn checkFingerprint(m: *const Message) bool {
        const at = m.fingerprint_at orelse return false;
        const want = std.mem.readInt(u32, m.raw[at + 4 ..][0..4], .big);
        return (std.hash.Crc32.hash(m.raw[0..at]) ^ fingerprint_xor) == want;
    }
};

pub fn parse(data: []const u8) ?Message {
    if (!isStun(data)) return null;
    const attrs_len = std.mem.readInt(u16, data[2..4], .big);
    const total: usize = header_len + @as(usize, attrs_len); // not u16: 0xFFFC + 20 would wrap
    if (attrs_len % 4 != 0 or total > data.len) return null;
    const raw = data[0..total];
    var m: Message = .{ .msg_type = std.mem.readInt(u16, raw[0..2], .big), .tid = raw[8..20].*, .raw = raw };
    var pos: usize = header_len;
    while (pos + 4 <= raw.len) {
        const t = std.mem.readInt(u16, raw[pos..][0..2], .big);
        const len = std.mem.readInt(u16, raw[pos + 2 ..][0..2], .big);
        const v_start = pos + 4;
        if (v_start + len > raw.len) return null;
        const v = raw[v_start .. v_start + len];
        // After MESSAGE-INTEGRITY only FINGERPRINT counts; after FINGERPRINT nothing does.
        if (m.fingerprint_at != null) break;
        if (m.integrity_at != null and t != attr_fingerprint) {
            pos = v_start + ((len + 3) & ~@as(usize, 3));
            continue;
        }
        switch (t) {
            attr_username => m.username = v,
            attr_priority => if (len == 4) {
                m.priority = std.mem.readInt(u32, v[0..4], .big);
            },
            attr_use_candidate => m.use_candidate = true,
            attr_ice_controlling => if (len == 8) {
                m.controlling = std.mem.readInt(u64, v[0..8], .big);
            },
            attr_ice_controlled => if (len == 8) {
                m.controlled = std.mem.readInt(u64, v[0..8], .big);
            },
            attr_xor_mapped_address => m.xor_mapped = parseXorAddress(v, raw[8..20]),
            attr_error_code => if (len >= 4) {
                m.error_code = @as(u16, v[2] & 7) * 100 + v[3];
            },
            attr_message_integrity => if (len == 20) {
                m.integrity_at = pos;
            },
            attr_fingerprint => if (len == 4) {
                m.fingerprint_at = pos;
            },
            else => {},
        }
        pos = v_start + ((len + 3) & ~@as(usize, 3));
    }
    return m;
}

fn parseXorAddress(v: []const u8, tid: []const u8) ?net.IpAddress {
    if (v.len < 8) return null;
    const port = std.mem.readInt(u16, v[2..4], .big) ^ @as(u16, magic_cookie >> 16);
    var cookie: [4]u8 = undefined;
    std.mem.writeInt(u32, &cookie, magic_cookie, .big);
    switch (v[1]) {
        1 => {
            var b: [4]u8 = undefined;
            for (0..4) |i| b[i] = v[4 + i] ^ cookie[i];
            return .{ .ip4 = .{ .bytes = b, .port = port } };
        },
        2 => {
            if (v.len < 20) return null;
            var mask: [16]u8 = undefined;
            @memcpy(mask[0..4], &cookie);
            @memcpy(mask[4..16], tid[0..12]);
            var b: [16]u8 = undefined;
            for (0..16) |i| b[i] = v[4 + i] ^ mask[i];
            return .{ .ip6 = .{ .bytes = b, .port = port } };
        },
        else => return null,
    }
}

/// ICE candidate priority (RFC 8445, 5.1.2.1): type preference, local preference, component 1.
pub fn priority(type_pref: u32, local_pref: u32) u32 {
    return (type_pref << 24) | (local_pref << 8) | (256 - 1);
}

// ---------------------------------------------------------------------------
// RFC 5769 test vectors.

const tv_tid = [12]u8{ 0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae };
const tv_password = "VOkJxbRl1RmTxUk/WvJxBt";

fn hexBytes(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "stun: RFC 5769 sample request" {
    const req = hexBytes("000100582112a442b7e7a701bc34d686fa87dfae" ++
        "80220010" ++ "5354554e207465737420636c69656e74" ++
        "002400046e0001ff" ++
        "80290008932ff9b151263b36" ++
        "00060009" ++ "6576746a3a68367659202020" ++
        "00080014" ++ "9aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a2" ++
        "80280004e57a3bcf");
    const m = parse(&req).?;
    try std.testing.expectEqual(binding_request, m.msg_type);
    try std.testing.expectEqualStrings("evtj:h6vY", m.username.?);
    try std.testing.expectEqual(@as(u32, 0x6e0001ff), m.priority.?);
    try std.testing.expectEqual(@as(u64, 0x932ff9b151263b36), m.controlled.?);
    try std.testing.expect(m.checkIntegrity(tv_password));
    try std.testing.expect(!m.checkIntegrity("wrong"));
    try std.testing.expect(m.checkFingerprint());

    // The builder makes the same bytes (the sample pads USERNAME with spaces, we pad with zeros).
    var buf: [512]u8 = undefined;
    var b = Builder.init(&buf, binding_request, tv_tid);
    b.add(0x8022, "STUN test client");
    b.addU32(attr_priority, 0x6e0001ff);
    b.addU64(attr_ice_controlled, 0x932ff9b151263b36);
    b.add(attr_username, "evtj:h6vY");
    b.addIntegrity(tv_password);
    b.addFingerprint();
    const out = parse(b.bytes()).?;
    try std.testing.expect(out.checkIntegrity(tv_password));
    try std.testing.expect(out.checkFingerprint());
    try std.testing.expectEqual(req.len, b.len);
}

test "stun: RFC 5769 sample IPv4 response" {
    const resp = hexBytes("0101003c2112a442b7e7a701bc34d686fa87dfae" ++
        "8022000b" ++ "7465737420766563746f7220" ++
        "002000080001a147e112a643" ++
        "00080014" ++ "2b91f599fd9e90c38c7489f92af9ba53f06be7d7" ++
        "80280004c07d4c96");
    const m = parse(&resp).?;
    try std.testing.expectEqual(binding_success, m.msg_type);
    const a = m.xor_mapped.?.ip4;
    try std.testing.expectEqual(@as(u16, 32853), a.port);
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 1 }, &a.bytes);
    try std.testing.expect(m.checkIntegrity(tv_password));
    try std.testing.expect(m.checkFingerprint());

    var buf: [512]u8 = undefined;
    var b = Builder.init(&buf, binding_success, tv_tid);
    b.add(0x8022, "test vector");
    b.addXorAddress(.{ .ip4 = .{ .bytes = .{ 192, 0, 2, 1 }, .port = 32853 } });
    b.addIntegrity(tv_password);
    b.addFingerprint();
    // "test vector" is padded with a zero here and with a space in the sample, so compare the parts that match.
    try std.testing.expectEqualSlices(u8, resp[36..48], b.bytes()[36..48]);
    try std.testing.expect(parse(b.bytes()).?.checkFingerprint());
}

test "stun: IPv6 XOR-MAPPED-ADDRESS round trip and garbage" {
    var buf: [512]u8 = undefined;
    var b = Builder.init(&buf, binding_success, tv_tid);
    const addr: net.IpAddress = .{ .ip6 = .{ .bytes = hexBytes("20010db8123456780011223344556677"), .port = 40000 } };
    b.addXorAddress(addr);
    b.addFingerprint();
    const m = parse(b.bytes()).?;
    try std.testing.expectEqualSlices(u8, &addr.ip6.bytes, &m.xor_mapped.?.ip6.bytes);
    try std.testing.expectEqual(@as(u16, 40000), m.xor_mapped.?.ip6.port);
    try std.testing.expectEqual(@as(?Message, null), parse("hello, this is not stun at all"));
    try std.testing.expect(!isStun(&.{ 22, 254, 253, 0 }));
    // A length that runs past the datagram.
    var bad: [64]u8 = undefined;
    @memcpy(bad[0..b.len], b.bytes());
    std.mem.writeInt(u16, bad[2..4], 400, .big);
    try std.testing.expectEqual(@as(?Message, null), parse(bad[0..b.len]));
}
