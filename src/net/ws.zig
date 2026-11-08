//! WebSocket (RFC 6455), сторона сервера: рукопожатие и кадры. Только чистая
//! логика над байтами — сокеты живут в host.zig.
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

/// Значение Sec-WebSocket-Accept для ключа клиента.
pub fn acceptKey(key: []const u8, out: *[28]u8) []const u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(guid);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// Заголовок кадра сервер → клиент (без маски). Возвращает занятую часть buf.
pub fn header(buf: *[10]u8, opcode: Opcode, payload_len: usize) []const u8 {
    buf[0] = 0x80 | @as(u8, @intFromEnum(opcode));
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

/// Разбирает один кадр клиент → сервер из начала buf. null — данных пока мало.
/// Полезная нагрузка демаскируется на месте.
pub fn parse(buf: []u8, max_payload: usize) ParseError!?Parsed {
    if (buf.len < 2) return null;
    const fin = buf[0] & 0x80 != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(buf[0])));
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

test "ws: ключ из RFC 6455" {
    var out: [28]u8 = undefined;
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out));
}

test "ws: заголовки разной длины" {
    var b: [10]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 5 }, header(&b, .binary, 5));
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 126, 0x01, 0x00 }, header(&b, .text, 256));
    try std.testing.expectEqual(@as(usize, 10), header(&b, .binary, 70_000).len);
}

test "ws: маскированный кадр клиента" {
    // «Hello» из RFC 6455, раздел 5.7.
    var buf = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58, 0xAA };
    const r = (try parse(&buf, 1024)).?;
    try std.testing.expect(r.frame.fin);
    try std.testing.expectEqual(Opcode.text, r.frame.opcode);
    try std.testing.expectEqualStrings("Hello", r.frame.payload);
    try std.testing.expectEqual(@as(usize, 11), r.used);
    try std.testing.expectEqual(@as(?Parsed, null), try parse(buf[0..6], 1024));
}
