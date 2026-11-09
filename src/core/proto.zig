//! Protocol between the host and a viewer: the same messages over a WebSocket (local
//! network) or a WebRTC data channel (from anywhere, net/webrtc.zig). Over a data channel,
//! host → viewer binary messages travel in pieces of at most 16 KiB, each with a one-byte
//! prefix — 1: more pieces follow, 0: the last one — because browsers cap data-channel
//! messages at 64–256 KiB. Text messages and everything viewer → host go unchanged.
//!
//! Host → viewer, binary message — a frame:
//!   [0] kind (1 — H.264 Annex B, 2 — JPEG), [1] flags (bit 0 — keyframe),
//!   [2..10] host time in µs (u64 LE), then the data.
//! Host → viewer, text — JSON: ok {w, h, os, name, codec, version, text, cx, cy, mic, camera}, size,
//!   pong, err, bye, viewers {n, ai: [names]} (who is connected, sent to everyone on every change),
//!   media {mic, camera, msg} — which of the viewer's devices the host takes now, and why not.
//!   `mic` and `camera` in ok say whether this computer has the capture devices for them.
//! Viewer → host, text — JSON: hello {code, h264, ai}, ping {ts}, stop_ai, media {mic, camera}.
//!   `ai` names the AI agent behind this viewer (rdc mcp); stop_ai disconnects all AI agents;
//!   media asks the host to take (or drop) this viewer's microphone and camera.
//! Viewer → host, binary — input (all numbers little-endian):
//!   1 move  f32 x, f32 y (0..1)        2 button u8 btn, u8 down, f32 x, f32 y
//!   3 wheel f32 dx, f32 dy (pixels)    4 key u16 hid, u8 down
//!   5 release_all                      6 text: UTF-8 to type (the rest of the message)
//!   16 keyframe
//! Viewer → host, binary — the viewer's microphone and camera (docs/PLAN.md, section 6):
//!   20 audio: u8 format (1 — 16-bit PCM, 48 kHz, mono), u16 seq, u64 viewer time in µs, then
//!      the samples (about 20 ms at a time)
//!   21 camera piece: u8 flags (bit 0 — first piece of a frame, bit 1 — last), then bytes of a
//!      JPEG frame cut into pieces of at most 15 KiB; a first piece carries u16 width, u16 height
//!      and u64 viewer time in µs before its bytes
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
    /// The viewer's microphone: 16-bit PCM, 48 kHz, mono; points into the message.
    audio: Audio,
    /// A piece of a JPEG frame from the viewer's camera; a first piece carries the frame's size.
    camera: CameraPiece,
};

pub const Audio = struct { seq: u16, ts_us: u64, pcm: []const u8 };
pub const CameraPiece = struct { first: bool, last: bool, width: u16, height: u16, ts_us: u64, data: []const u8 };

pub const msg_move: u8 = 1;
pub const msg_button: u8 = 2;
pub const msg_wheel: u8 = 3;
pub const msg_key: u8 = 4;
pub const msg_release_all: u8 = 5;
pub const msg_text: u8 = 6;
pub const msg_keyframe: u8 = 16;
pub const msg_audio: u8 = 20;
pub const msg_camera: u8 = 21;
pub const audio_pcm16_48k: u8 = 1;
pub const audio_header_len = 12;
pub const camera_piece_first: u8 = 1;
pub const camera_piece_last: u8 = 2;
/// A first piece: kind, flags, width, height, time.
pub const camera_first_header_len = 14;
pub const camera_piece_header_len = 2;
/// Pieces of a camera frame: each fits a 16 KiB WebSocket message with room for its header.
pub const camera_piece_max = 15 * 1024;
/// A JPEG frame from a phone camera is 50–150 KB; anything bigger is dropped.
pub const camera_frame_max = 1024 * 1024;

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
        20 => {
            if (b.len < audio_header_len or b[1] != audio_pcm16_48k) return null;
            const pcm = b[audio_header_len..];
            if (pcm.len == 0 or pcm.len % 2 != 0) return null;
            return .{ .audio = .{ .seq = std.mem.readInt(u16, b[2..4], .little), .ts_us = std.mem.readInt(u64, b[4..12], .little), .pcm = pcm } };
        },
        21 => {
            if (b.len < camera_piece_header_len) return null;
            const first = b[1] & camera_piece_first != 0;
            const last = b[1] & camera_piece_last != 0;
            if (!first) return .{ .camera = .{ .first = false, .last = last, .width = 0, .height = 0, .ts_us = 0, .data = b[2..] } };
            if (b.len < camera_first_header_len) return null;
            return .{ .camera = .{
                .first = true,
                .last = last,
                .width = std.mem.readInt(u16, b[2..4], .little),
                .height = std.mem.readInt(u16, b[4..6], .little),
                .ts_us = std.mem.readInt(u64, b[6..14], .little),
                .data = b[14..],
            } };
        },
        else => return null,
    }
}

/// Puts a camera frame back together from its pieces. The buffer is the caller's and sets the
/// largest frame; a piece without its frame's start and a frame that does not fit are dropped.
pub const CameraAssembler = struct {
    len: usize = 0,
    /// 0 between frames.
    width: u16 = 0,
    height: u16 = 0,
    ts_us: u64 = 0,

    pub const Frame = struct { jpeg: []const u8, width: u16, height: u16, ts_us: u64 };

    /// Takes one piece; returns the whole frame, in buf, when the piece was its last.
    pub fn push(a: *CameraAssembler, buf: []u8, p: CameraPiece) ?Frame {
        if (p.first) {
            a.len = 0;
            a.width = p.width;
            a.height = p.height;
            a.ts_us = p.ts_us;
        }
        if (a.width == 0 or a.height == 0 or p.data.len > buf.len - a.len) {
            a.width = 0;
            return null;
        }
        @memcpy(buf[a.len..][0..p.data.len], p.data);
        a.len += p.data.len;
        if (!p.last) return null;
        const frame: Frame = .{ .jpeg = buf[0..a.len], .width = a.width, .height = a.height, .ts_us = a.ts_us };
        a.width = 0;
        return if (frame.jpeg.len > 0) frame else null;
    }

    pub fn reset(a: *CameraAssembler) void {
        a.* = .{};
    }
};

/// Header of an audio message; the PCM samples follow it.
pub fn encodeAudioHeader(buf: *[audio_header_len]u8, seq: u16, ts_us: u64) []const u8 {
    buf[0] = msg_audio;
    buf[1] = audio_pcm16_48k;
    std.mem.writeInt(u16, buf[2..4], seq, .little);
    std.mem.writeInt(u64, buf[4..12], ts_us, .little);
    return buf;
}

/// Header of a camera piece; the frame bytes follow it. A first piece carries the frame's size.
pub fn encodeCameraHeader(buf: *[camera_first_header_len]u8, first: bool, last: bool, width: u16, height: u16, ts_us: u64) []const u8 {
    buf[0] = msg_camera;
    buf[1] = (if (first) camera_piece_first else 0) | (if (last) camera_piece_last else 0);
    if (!first) return buf[0..camera_piece_header_len];
    std.mem.writeInt(u16, buf[2..4], width, .little);
    std.mem.writeInt(u16, buf[4..6], height, .little);
    std.mem.writeInt(u64, buf[6..14], ts_us, .little);
    return buf;
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

test "proto: viewer media" {
    var hdr: [audio_header_len]u8 = undefined;
    var msg: [audio_header_len + 4]u8 = undefined;
    @memcpy(msg[0..audio_header_len], encodeAudioHeader(&hdr, 7, 123_456));
    msg[12..16].* = .{ 0x01, 0x02, 0x03, 0x04 };
    const a = decodeInput(&msg).?.audio;
    try std.testing.expectEqual(@as(u16, 7), a.seq);
    try std.testing.expectEqual(@as(u64, 123_456), a.ts_us);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, a.pcm);
    try std.testing.expectEqual(@as(?Input, null), decodeInput(msg[0..audio_header_len])); // no samples
    try std.testing.expectEqual(@as(?Input, null), decodeInput(msg[0 .. audio_header_len + 3])); // half a sample
    msg[1] = 2;
    try std.testing.expectEqual(@as(?Input, null), decodeInput(&msg)); // unknown format

    var ch: [camera_first_header_len]u8 = undefined;
    var piece: [camera_first_header_len + 2]u8 = undefined;
    @memcpy(piece[0..camera_first_header_len], encodeCameraHeader(&ch, true, false, 1280, 720, 99));
    piece[14..16].* = .{ 0xFF, 0xD8 };
    const c = decodeInput(&piece).?.camera;
    try std.testing.expect(c.first and !c.last);
    try std.testing.expectEqual(@as(u16, 1280), c.width);
    try std.testing.expectEqual(@as(u16, 720), c.height);
    try std.testing.expectEqual(@as(u64, 99), c.ts_us);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8 }, c.data);
    const tail = encodeCameraHeader(&ch, false, true, 0, 0, 0);
    try std.testing.expectEqual(@as(usize, camera_piece_header_len), tail.len);
    var last: [3]u8 = undefined;
    @memcpy(last[0..2], tail);
    last[2] = 0xD9;
    const l = decodeInput(&last).?.camera;
    try std.testing.expect(!l.first and l.last);
    try std.testing.expectEqualSlices(u8, &.{0xD9}, l.data);
    try std.testing.expectEqual(@as(?Input, null), decodeInput(&.{ 21, 1, 0, 0 })); // a first piece without its size
}

test "proto: camera frame from pieces" {
    var buf: [10]u8 = undefined;
    var a: CameraAssembler = .{};
    const piece = struct {
        fn of(first: bool, last: bool, data: []const u8) CameraPiece {
            return .{ .first = first, .last = last, .width = if (first) 640 else 0, .height = if (first) 480 else 0, .ts_us = if (first) 5 else 0, .data = data };
        }
    }.of;
    // Three pieces make a frame.
    try std.testing.expectEqual(@as(?CameraAssembler.Frame, null), a.push(&buf, piece(true, false, "abc")));
    try std.testing.expectEqual(@as(?CameraAssembler.Frame, null), a.push(&buf, piece(false, false, "de")));
    const f = a.push(&buf, piece(false, true, "f")).?;
    try std.testing.expectEqualStrings("abcdef", f.jpeg);
    try std.testing.expectEqual(@as(u16, 640), f.width);
    try std.testing.expectEqual(@as(u16, 480), f.height);
    try std.testing.expectEqual(@as(u64, 5), f.ts_us);
    // A frame in one piece.
    try std.testing.expectEqualStrings("xyz", a.push(&buf, piece(true, true, "xyz")).?.jpeg);
    // Pieces without a start are dropped, and so is the end that follows them.
    try std.testing.expectEqual(@as(?CameraAssembler.Frame, null), a.push(&buf, piece(false, false, "zz")));
    try std.testing.expectEqual(@as(?CameraAssembler.Frame, null), a.push(&buf, piece(false, true, "zz")));
    // A frame that does not fit is dropped whole; the next one is fine.
    try std.testing.expectEqual(@as(?CameraAssembler.Frame, null), a.push(&buf, piece(true, false, "12345678")));
    try std.testing.expectEqual(@as(?CameraAssembler.Frame, null), a.push(&buf, piece(false, false, "9ab")));
    try std.testing.expectEqual(@as(?CameraAssembler.Frame, null), a.push(&buf, piece(false, true, "c")));
    try std.testing.expectEqualStrings("ok", a.push(&buf, piece(true, true, "ok")).?.jpeg);
    // A new start abandons an unfinished frame; a frame with no size or no bytes is nothing.
    _ = a.push(&buf, piece(true, false, "old"));
    try std.testing.expectEqualStrings("new", a.push(&buf, piece(true, true, "new")).?.jpeg);
    try std.testing.expectEqual(@as(?CameraAssembler.Frame, null), a.push(&buf, .{ .first = true, .last = true, .width = 0, .height = 480, .ts_us = 0, .data = "q" }));
    try std.testing.expectEqual(@as(?CameraAssembler.Frame, null), a.push(&buf, piece(true, true, "")));
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
