//! WebSocket (RFC 6455): handshake and frames for the server (host.zig) and the client
//! (the agent's viewer, agent/client.zig). Only pure logic over bytes — no sockets here.
const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Sec-WebSocket-Accept value for the client's key.
pub fn acceptKey(key: []const u8, out: *[28]u8) []const u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(guid);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// Header of a server → client frame (unmasked). Returns the used part of buf.
pub fn header(buf: *[10]u8, opcode: Opcode, payload_len: usize) []const u8 {
    buf[0] = 0x80 | @as(u8, @backingInt(opcode));
    if (payload_len < 126) {
        buf[1] = @intCast(payload_len);
        return buf[0..2];
    }
    if (payload_len <= 0xFFFF) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(payload_len), .big);
        return buf[0..4];
    }
    buf[1] = 127;
    std.mem.writeInt(u64, buf[2..10], payload_len, .big);
    return buf[0..10];
}

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
};

pub const Parsed = struct {
    frame: Frame,
    used: usize,
};

pub const ParseError = error{ TooLarge, NotMasked };

/// Parses one client → server frame from the start of buf. null: not enough data yet.
/// The payload is unmasked in place.
pub fn parse(buf: []u8, max_payload: usize) ParseError!?Parsed {
    if (buf.len < 2) return null;
    const fin = buf[0] & 0x80 != 0;
    const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(buf[0]))));
    if (buf[1] & 0x80 == 0) return error.NotMasked;
    var pos: usize = 2;
    var n: u64 = buf[1] & 0x7F;
    if (n == 126) {
        if (buf.len < 4) return null;
        n = std.mem.readInt(u16, buf[2..4], .big);
        pos = 4;
    } else if (n == 127) {
        if (buf.len < 10) return null;
        n = std.mem.readInt(u64, buf[2..10], .big);
        pos = 10;
    }
    if (n > max_payload) return error.TooLarge;
    const size: usize = @intCast(n);
    if (buf.len < pos + 4 + size) return null;
    const mask = buf[pos..][0..4].*;
    pos += 4;
    const payload = buf[pos .. pos + size];
    for (payload, 0..) |*b, i| b.* ^= mask[i & 3];
    return .{ .frame = .{ .fin = fin, .opcode = opcode, .payload = payload }, .used = pos + size };
}

/// Header of a client → server frame: always masked (RFC 6455, 5.3). Returns the used part of buf.
pub fn clientHeader(buf: *[14]u8, opcode: Opcode, payload_len: usize, mask: [4]u8) []const u8 {
    buf[0] = 0x80 | @as(u8, @backingInt(opcode));
    var pos: usize = 2;
    if (payload_len < 126) {
        buf[1] = 0x80 | @as(u8, @intCast(payload_len));
    } else if (payload_len <= 0xFFFF) {
        buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(payload_len), .big);
        pos = 4;
    } else {
        buf[1] = 0x80 | 127;
        std.mem.writeInt(u64, buf[2..10], payload_len, .big);
        pos = 10;
    }
    @memcpy(buf[pos..][0..4], &mask);
    return buf[0 .. pos + 4];
}

/// Masks or unmasks data in place (the same XOR both ways).
pub fn applyMask(data: []u8, mask: [4]u8) void {
    for (data, 0..) |*b, i| b.* ^= mask[i & 3];
}

pub const ServerHeader = struct {
    fin: bool,
    opcode: Opcode,
    /// Payload length.
    len: u64,
    /// Header length.
    used: usize,
};

/// Header of a server → client frame from the start of buf. null: not enough data yet.
/// The payload is read separately: frames from the host can be large.
pub fn parseServerHeader(buf: []const u8) error{Masked}!?ServerHeader {
    if (buf.len < 2) return null;
    if (buf[1] & 0x80 != 0) return error.Masked; // a server never masks
    var pos: usize = 2;
    var n: u64 = buf[1] & 0x7F;
    if (n == 126) {
        if (buf.len < 4) return null;
        n = std.mem.readInt(u16, buf[2..4], .big);
        pos = 4;
    } else if (n == 127) {
        if (buf.len < 10) return null;
        n = std.mem.readInt(u64, buf[2..10], .big);
        pos = 10;
    }
    return .{ .fin = buf[0] & 0x80 != 0, .opcode = @fromBackingInt(@intCast(@as(u4, @truncate(buf[0])))), .len = n, .used = pos };
}

test "ws: client frame round trip" {
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    var hb: [14]u8 = undefined;
    var msg: [5 + 14]u8 = undefined;
    const h = clientHeader(&hb, .text, 5, mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d }, h);
    @memcpy(msg[0..h.len], h);
    @memcpy(msg[h.len..][0..5], "Hello");
    applyMask(msg[h.len..][0..5], mask);
    const r = (try parse(msg[0 .. h.len + 5], 1024)).?;
    try std.testing.expectEqualStrings("Hello", r.frame.payload);
    try std.testing.expectEqual(@as(usize, 14), clientHeader(&hb, .binary, 70_000, mask).len);
}

test "ws: server frame header" {
    var b: [10]u8 = undefined;
    const s = (try parseServerHeader(header(&b, .binary, 70_000))).?;
    try std.testing.expectEqual(Opcode.binary, s.opcode);
    try std.testing.expectEqual(@as(u64, 70_000), s.len);
    try std.testing.expectEqual(@as(usize, 10), s.used);
    try std.testing.expect(s.fin);
    try std.testing.expectEqual(@as(?ServerHeader, null), try parseServerHeader(&.{0x82}));
    try std.testing.expectError(error.Masked, parseServerHeader(&.{ 0x81, 0x85 }));
}

test "ws: key from RFC 6455" {
    var out: [28]u8 = undefined;
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out));
}

test "ws: headers of different lengths" {
    var b: [10]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 5 }, header(&b, .binary, 5));
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 126, 0x01, 0x00 }, header(&b, .text, 256));
    try std.testing.expectEqual(@as(usize, 10), header(&b, .binary, 70_000).len);
}

test "ws: masked client frame" {
    // "Hello" from RFC 6455, section 5.7.
    var buf = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58, 0xAA };
    const r = (try parse(&buf, 1024)).?;
    try std.testing.expect(r.frame.fin);
    try std.testing.expectEqual(Opcode.text, r.frame.opcode);
    try std.testing.expectEqualStrings("Hello", r.frame.payload);
    try std.testing.expectEqual(@as(usize, 11), r.used);
    try std.testing.expectEqual(@as(?Parsed, null), try parse(buf[0..6], 1024));
}
