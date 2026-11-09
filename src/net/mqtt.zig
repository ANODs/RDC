//! MQTT 3.1.1 packets for signaling through public brokers: CONNECT, SUBSCRIBE,
//! UNSUBSCRIBE, PUBLISH (QoS 0), PINGREQ, DISCONNECT out; CONNACK, SUBACK, PUBLISH,
//! PINGRESP in. Pure logic over bytes — no sockets here.
const std = @import("std");

pub const connect_type: u8 = 1;
pub const connack_type: u8 = 2;
pub const publish_type: u8 = 3;
pub const suback_type: u8 = 9;
pub const unsuback_type: u8 = 11;
pub const pingresp_type: u8 = 13;

pub const pingreq = [_]u8{ 0xC0, 0x00 };
pub const disconnect = [_]u8{ 0xE0, 0x00 };

/// The fixed header: type and flags, then the remaining length (1–4 bytes).
fn fixedHeader(out: []u8, first: u8, remaining: usize) usize {
    out[0] = first;
    var n: usize = 1;
    var x = remaining;
    while (true) {
        var byte: u8 = @intCast(x % 128);
        x /= 128;
        if (x > 0) byte |= 0x80;
        out[n] = byte;
        n += 1;
        if (x == 0) break;
    }
    return n;
}

fn str(out: []u8, s: []const u8) usize {
    std.mem.writeInt(u16, out[0..2], @intCast(s.len), .big);
    @memcpy(out[2..][0..s.len], s);
    return 2 + s.len;
}

pub fn connect(out: []u8, client_id: []const u8, keepalive_s: u16) []const u8 {
    const remaining = 10 + 2 + client_id.len;
    var n = fixedHeader(out, 0x10, remaining);
    n += str(out[n..], "MQTT");
    out[n] = 4; // protocol level 3.1.1
    out[n + 1] = 0x02; // clean session
    std.mem.writeInt(u16, out[n + 2 ..][0..2], keepalive_s, .big);
    n += 4;
    n += str(out[n..], client_id);
    return out[0..n];
}

pub fn subscribe(out: []u8, packet_id: u16, topic: []const u8) []const u8 {
    var n = fixedHeader(out, 0x82, 2 + 2 + topic.len + 1);
    std.mem.writeInt(u16, out[n..][0..2], packet_id, .big);
    n += 2;
    n += str(out[n..], topic);
    out[n] = 0; // QoS 0
    return out[0 .. n + 1];
}

pub fn unsubscribe(out: []u8, packet_id: u16, topic: []const u8) []const u8 {
    var n = fixedHeader(out, 0xA2, 2 + 2 + topic.len);
    std.mem.writeInt(u16, out[n..][0..2], packet_id, .big);
    n += 2;
    n += str(out[n..], topic);
    return out[0..n];
}

/// PUBLISH at QoS 0, not retained.
pub fn publish(out: []u8, topic: []const u8, payload: []const u8) []const u8 {
    var n = fixedHeader(out, 0x30, 2 + topic.len + payload.len);
    n += str(out[n..], topic);
    @memcpy(out[n..][0..payload.len], payload);
    return out[0 .. n + payload.len];
}

pub fn publishSize(topic: []const u8, payload_len: usize) usize {
    return 5 + 2 + topic.len + payload_len;
}

pub const Packet = struct {
    kind: u8,
    flags: u8,
    body: []const u8,
    /// Bytes this packet takes in the buffer.
    used: usize,
};

/// One packet from the start of buf; null — not enough data yet.
pub fn parse(buf: []const u8, max_len: usize) error{TooLarge}!?Packet {
    if (buf.len < 2) return null;
    var remaining: usize = 0;
    var mult: usize = 1;
    var i: usize = 1;
    while (true) : (i += 1) {
        if (i >= buf.len) return null;
        if (i > 4) return error.TooLarge;
        remaining += @as(usize, buf[i] & 0x7F) * mult;
        if (buf[i] & 0x80 == 0) break;
        mult *= 128;
    }
    if (remaining > max_len) return error.TooLarge;
    const start = i + 1;
    if (buf.len < start + remaining) return null;
    return .{ .kind = buf[0] >> 4, .flags = buf[0] & 0x0F, .body = buf[start .. start + remaining], .used = start + remaining };
}

/// Size of the whole packet at the start of buf, from its fixed header alone; null — the header is
/// incomplete or malformed. Lets a reader skip a packet it refuses to keep instead of dropping the connection.
pub fn packetLen(buf: []const u8) ?usize {
    if (buf.len < 2) return null;
    var remaining: usize = 0;
    var mult: usize = 1;
    var i: usize = 1;
    while (true) : (i += 1) {
        if (i >= buf.len or i > 4) return null;
        remaining += @as(usize, buf[i] & 0x7F) * mult;
        if (buf[i] & 0x80 == 0) break;
        mult *= 128;
    }
    return i + 1 + remaining;
}

pub const Publish = struct { topic: []const u8, payload: []const u8 };

pub fn parsePublish(p: Packet) ?Publish {
    if (p.body.len < 2) return null;
    const tlen: usize = std.mem.readInt(u16, p.body[0..2], .big); // usize: a 0xFFFF topic length must not wrap
    var pos: usize = 2 + tlen;
    if (pos > p.body.len) return null;
    if ((p.flags >> 1) & 3 != 0) pos += 2; // QoS 1 or 2: a packet id follows the topic
    if (pos > p.body.len) return null;
    return .{ .topic = p.body[2 .. 2 + tlen], .payload = p.body[pos..] };
}

test "mqtt: packets round trip" {
    var buf: [512]u8 = undefined;
    const c = connect(&buf, "rdc-1234", 60);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 20, 0, 4, 'M', 'Q', 'T', 'T', 4, 2, 0, 60, 0, 8 }, c[0..14]);
    const s = subscribe(&buf, 7, "rdc/abc");
    const sp = (try parse(s, 1024)).?;
    try std.testing.expectEqual(@as(u8, 8), sp.kind);
    try std.testing.expectEqual(@as(u8, 2), sp.flags);
    try std.testing.expectEqual(s.len, sp.used);

    var payload: [300]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    const p = publish(&buf, "rdc/abc", &payload);
    try std.testing.expectEqual(@as(u8, 0x30), p[0]);
    try std.testing.expectEqual(@as(u8, 0x80 | (309 % 128)), p[1]); // 309 = 2 + 7 + 300: two length bytes
    try std.testing.expectEqual(@as(u8, 309 / 128), p[2]);
    try std.testing.expect(publishSize("rdc/abc", payload.len) >= p.len);
    const pp = (try parse(p, 1024)).?;
    try std.testing.expectEqual(publish_type, pp.kind);
    const pub_ = parsePublish(pp).?;
    try std.testing.expectEqualStrings("rdc/abc", pub_.topic);
    try std.testing.expectEqualSlices(u8, &payload, pub_.payload);
    // Incomplete, then too large.
    try std.testing.expectEqual(@as(?Packet, null), try parse(p[0 .. p.len - 1], 1024));
    try std.testing.expectError(error.TooLarge, parse(p, 100));
    try std.testing.expectEqual(@as(?Packet, null), try parse(&.{0x30}, 1024));
}

test "mqtt: broker packets" {
    const connack = [_]u8{ 0x20, 0x02, 0x00, 0x00 };
    const ca = (try parse(&connack, 64)).?;
    try std.testing.expectEqual(connack_type, ca.kind);
    try std.testing.expectEqual(@as(u8, 0), ca.body[1]);
    const ping = [_]u8{ 0xD0, 0x00, 0x90 };
    const pr = (try parse(&ping, 64)).?;
    try std.testing.expectEqual(pingresp_type, pr.kind);
    try std.testing.expectEqual(@as(usize, 2), pr.used);
    // QoS 1 PUBLISH from a broker carries a packet id after the topic.
    const q1 = [_]u8{ 0x32, 0x08, 0x00, 0x01, 't', 0x00, 0x05, 'a', 'b', 'c' };
    const p = parsePublish((try parse(&q1, 64)).?).?;
    try std.testing.expectEqualStrings("t", p.topic);
    try std.testing.expectEqualStrings("abc", p.payload);
}
