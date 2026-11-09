//! Minimal HTTP/1.1: request head parsing. The host only has to serve the viewer
//! page and switch the connection to WebSocket.
const std = @import("std");

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    upgrade_websocket: bool = false,
    websocket_key: ?[]const u8 = null,
};

/// Parses a request head (with or without the trailing empty line).
pub fn parseHead(head: []const u8) ?Request {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const first = lines.next() orelse return null;
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method = parts.next() orelse return null;
    const target = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return null;
    const path = if (std.mem.indexOfAny(u8, target, "?#")) |i| target[0..i] else target;
    var req = Request{ .method = method, .path = path };
    var upgrade = false;
    var connection_upgrade = false;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            connection_upgrade = containsIgnoreCase(value, "upgrade");
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
            req.websocket_key = value;
        }
    }
    req.upgrade_websocket = upgrade and connection_upgrade and req.websocket_key != null;
    return req;
}

/// Value of a header in a request head (case-insensitive name), or null.
pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // the request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// Query string and fragment removed, percent-escapes left alone: "/mcp/abc?x=1" → "/mcp/abc".
pub fn pathOnly(target: []const u8) []const u8 {
    return if (std.mem.indexOfAny(u8, target, "?#")) |i| target[0..i] else target;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "http: plain request" {
    const r = parseHead("GET /viewer.js?v=1 HTTP/1.1\r\nHost: 10.0.0.2:7700\r\n\r\n").?;
    try std.testing.expectEqualStrings("GET", r.method);
    try std.testing.expectEqualStrings("/viewer.js", r.path);
    try std.testing.expect(!r.upgrade_websocket);
}

test "http: WebSocket upgrade" {
    const r = parseHead("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").?;
    try std.testing.expect(r.upgrade_websocket);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", r.websocket_key.?);
}

test "http: header values" {
    const head = "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\nMCP-Protocol-Version:  2026-07-28 \r\n\r\n";
    try std.testing.expectEqualStrings("12", headerValue(head, "content-length").?);
    try std.testing.expectEqualStrings("2026-07-28", headerValue(head, "mcp-protocol-version").?);
    try std.testing.expectEqual(@as(?[]const u8, null), headerValue(head, "origin"));
    try std.testing.expectEqualStrings("/mcp/abc", pathOnly("/mcp/abc?token=1"));
}

test "http: garbage" {
    try std.testing.expectEqual(@as(?Request, null), parseHead("hello"));
}
