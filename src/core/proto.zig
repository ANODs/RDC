//! Protocol between the host and a viewer: the same messages over a WebSocket (local
//! network) or a WebRTC data channel (from anywhere, net/webrtc.zig). Over a data channel,
//! host → viewer binary messages travel in pieces of at most 16 KiB, each with a one-byte
//! prefix — 1: more pieces follow, 0: the last one — because browsers cap data-channel
//! messages at 64–256 KiB. Text messages and everything viewer → host go unchanged.
//!
//! Host → viewer, binary message — a frame:
//!   [0] kind (1 — H.264 Annex B, 2 — JPEG), [1] flags (bit 0 — keyframe),
//!   [2..10] host time in µs (u64 LE), then the data.
//! Host → viewer, text — JSON: ok {w, h, os, name, codec, version, text, cx, cy}, size, pong,
//!   err, bye, viewers {n, ai: [names]} (who is connected, sent to everyone on every change).
//! Viewer → host, text — JSON: hello {code, h264, ai}, ping {ts}, stop_ai.
//!   `ai` names the AI agent behind this viewer (rdc mcp); stop_ai disconnects all AI agents.
//! Viewer → host, binary — input (all numbers little-endian):
//!   1 move  f32 x, f32 y (0..1)        2 button u8 btn, u8 down, f32 x, f32 y
//!   3 wheel f32 dx, f32 dy (pixels)    4 key u16 hid, u8 down
//!   5 release_all                      6 text: UTF-8 to type (the rest of the message)
//!   16 keyframe
const std = @import("std");

pub const frame_header_len = 10;

pub const FrameKind = enum(u8) { h264 = 1, jpeg = 2 };

pub fn frameHeader(buf: *[frame_header_len]u8, kind: FrameKind, keyframe: bool, ts_us: u64) void {
    buf[0] = @backingInt(kind);
    buf[1] = if (keyframe) 1 else 0;
    std.mem.writeInt(u64, buf[2..10], ts_us, .little);
}

pub const Input = union(enum) {
    move: struct { x: f32, y: f32 },
    button: struct { button: u8, down: bool, x: f32, y: f32 },
    wheel: struct { dx: f32, dy: f32 },
    key: struct { usage: u16, down: bool },
    release_all,
    /// Valid UTF-8; points into the message.
    text: []const u8,
    keyframe,
};

pub const msg_move: u8 = 1;
pub const msg_button: u8 = 2;
pub const msg_wheel: u8 = 3;
pub const msg_key: u8 = 4;
pub const msg_release_all: u8 = 5;
pub const msg_text: u8 = 6;
pub const msg_keyframe: u8 = 16;

fn writeF32(b: *[4]u8, v: f32) void {
    std.mem.writeInt(u32, b, @bitCast(v), .little);
}

// --- Input encoders, for viewers written in Zig (the agent's client).

pub fn encodeMove(buf: *[9]u8, x: f32, y: f32) []const u8 {
    buf[0] = msg_move;
    writeF32(buf[1..5], x);
    writeF32(buf[5..9], y);
    return buf;
}

pub fn encodeButton(buf: *[11]u8, button: u8, down: bool, x: f32, y: f32) []const u8 {
    buf[0] = msg_button;
    buf[1] = button;
    buf[2] = @intFromBool(down);
    writeF32(buf[3..7], x);
    writeF32(buf[7..11], y);
    return buf;
}

pub fn encodeWheel(buf: *[9]u8, dx: f32, dy: f32) []const u8 {
    buf[0] = msg_wheel;
    writeF32(buf[1..5], dx);
    writeF32(buf[5..9], dy);
    return buf;
}

pub fn encodeKey(buf: *[4]u8, usage: u16, down: bool) []const u8 {
    buf[0] = msg_key;
    std.mem.writeInt(u16, buf[1..3], usage, .little);
    buf[3] = @intFromBool(down);
    return buf;
}

fn readF32(b: *const [4]u8) f32 {
    const v = @as(f32, @bitCast(std.mem.readInt(u32, b, .little)));
    return if (std.math.isFinite(v)) v else 0;
}

pub fn decodeInput(b: []const u8) ?Input {
    if (b.len == 0) return null;
    switch (b[0]) {
        1 => {
            if (b.len < 9) return null;
            return .{ .move = .{ .x = readF32(b[1..5]), .y = readF32(b[5..9]) } };
        },
        2 => {
            if (b.len < 11) return null;
            return .{ .button = .{ .button = b[1], .down = b[2] != 0, .x = readF32(b[3..7]), .y = readF32(b[7..11]) } };
        },
        3 => {
            if (b.len < 9) return null;
            return .{ .wheel = .{ .dx = readF32(b[1..5]), .dy = readF32(b[5..9]) } };
        },
        4 => {
            if (b.len < 4) return null;
            return .{ .key = .{ .usage = std.mem.readInt(u16, b[1..3], .little), .down = b[3] != 0 } };
        },
        5 => return .release_all,
        6 => {
            const t = b[1..];
            if (t.len == 0 or !std.unicode.utf8ValidateSlice(t)) return null;
            return .{ .text = t };
        },
        16 => return .keyframe,
        else => return null,
    }
}

// --- JSON: small messages from our own client, parsed without allocations.

/// Value of the string field "key":"..." (no escape handling — our fields contain none).
pub fn jsonString(msg: []const u8, comptime key: []const u8) ?[]const u8 {
    const pat = "\"" ++ key ++ "\":\"";
    const i = std.mem.indexOf(u8, msg, pat) orelse return null;
    const start = i + pat.len;
    const end = std.mem.indexOfScalarPos(u8, msg, start, '"') orelse return null;
    return msg[start..end];
}

/// true if the message contains "key":true.
pub fn jsonTrue(msg: []const u8, comptime key: []const u8) bool {
    return std.mem.indexOf(u8, msg, "\"" ++ key ++ "\":true") != null;
}

/// Raw numeric value of the field "key":123.45 — for echoing back (ping → pong).
pub fn jsonNumber(msg: []const u8, comptime key: []const u8) ?[]const u8 {
    const pat = "\"" ++ key ++ "\":";
    const i = std.mem.indexOf(u8, msg, pat) orelse return null;
    const start = i + pat.len;
    var end = start;
    while (end < msg.len and (std.ascii.isDigit(msg[end]) or msg[end] == '.' or msg[end] == '-' or msg[end] == 'e' or msg[end] == 'E' or msg[end] == '+')) end += 1;
    return if (end > start) msg[start..end] else null;
}

/// Copies s into out, escaped for a JSON string. Truncates if it does not fit.
pub fn jsonEscape(out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        const need: usize = if (c == '"' or c == '\\') 2 else if (c < 0x20) 0 else 1;
        if (need == 0) continue;
        if (n + need > out.len) break;
        if (need == 2) {
            out[n] = '\\';
            n += 1;
        }
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

test "proto: input" {
    var b: [11]u8 = undefined;
    b[0] = 2;
    b[1] = 0;
    b[2] = 1;
    std.mem.writeInt(u32, b[3..7], @as(u32, @bitCast(@as(f32, 0.25))), .little);
    std.mem.writeInt(u32, b[7..11], @as(u32, @bitCast(@as(f32, 0.75))), .little);
    const in = decodeInput(&b).?;
    try std.testing.expectEqual(@as(f32, 0.25), in.button.x);
    try std.testing.expectEqual(@as(f32, 0.75), in.button.y);
    try std.testing.expect(in.button.down);
    try std.testing.expectEqual(@as(?Input, null), decodeInput(b[0..5]));
    const k = decodeInput(&.{ 4, 0xE3, 0, 1 }).?;
    try std.testing.expectEqual(@as(u16, 0xE3), k.key.usage);
    try std.testing.expect(decodeInput(&.{5}).? == .release_all);
    try std.testing.expectEqualStrings("Grüße ✓", decodeInput("\x06Grüße ✓").?.text);
    try std.testing.expectEqual(@as(?Input, null), decodeInput(&.{ 6, 0xFF, 0xFE }));
    try std.testing.expectEqual(@as(?Input, null), decodeInput(&.{6}));
}

test "proto: input encoders" {
    var m: [9]u8 = undefined;
    try std.testing.expectEqual(@as(f32, 0.5), decodeInput(encodeMove(&m, 0.5, 0.25)).?.move.x);
    var b: [11]u8 = undefined;
    const btn = decodeInput(encodeButton(&b, 2, true, 0.1, 0.9)).?.button;
    try std.testing.expectEqual(@as(u8, 2), btn.button);
    try std.testing.expect(btn.down);
    try std.testing.expectEqual(@as(f32, 0.9), btn.y);
    var w: [9]u8 = undefined;
    try std.testing.expectEqual(@as(f32, -300), decodeInput(encodeWheel(&w, 0, -300)).?.wheel.dy);
    var k: [4]u8 = undefined;
    const key = decodeInput(encodeKey(&k, 0x28, false)).?.key;
    try std.testing.expectEqual(@as(u16, 0x28), key.usage);
    try std.testing.expect(!key.down);
}

test "proto: json" {
    const m = "{\"t\":\"hello\",\"code\":\"123456789\",\"h264\":true,\"ts\":1234.5}";
    try std.testing.expectEqualStrings("hello", jsonString(m, "t").?);
    try std.testing.expectEqualStrings("123456789", jsonString(m, "code").?);
    try std.testing.expect(jsonTrue(m, "h264"));
    try std.testing.expectEqualStrings("1234.5", jsonNumber(m, "ts").?);
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a\\\"b", jsonEscape(&out, "a\"b"));
}

test "proto: frame header" {
    var h: [frame_header_len]u8 = undefined;
    frameHeader(&h, .h264, true, 0x0102);
    try std.testing.expectEqual(@as(u8, 1), h[0]);
    try std.testing.expectEqual(@as(u8, 1), h[1]);
    try std.testing.expectEqual(@as(u64, 0x0102), std.mem.readInt(u64, h[2..10], .little));
}
