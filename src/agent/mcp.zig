//! `rdc mcp` — an MCP server that gives AI agents the tools in tools.zig.
//!
//! JSON-RPC 2.0 over stdio (one message per line; Claude Code, Codex, Claude Desktop start it
//! as a plugin) or over Streamable HTTP (`--http`: POST /mcp; cloud agents reach it through a
//! tunnel). Dual-era: a client that opens with `initialize` (protocol 2025-11-25 and earlier)
//! gets the handshake, a client that puts the protocol version in every request's `_meta`
//! (2026-07-28) gets stateless answers and `server/discover`.
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const http = @import("../net/http.zig");
const tools = @import("tools.zig");
const plat = @import("../platform.zig");
const update = @import("../update.zig");

pub const default_http_port: u16 = 7710;
pub const protocol_versions = [_][]const u8{ "2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26" };
const legacy_default = "2025-06-18";
const max_body = 4 * 1024 * 1024;
const meta_version = "io.modelcontextprotocol/protocolVersion";
const meta_client = "io.modelcontextprotocol/clientInfo";
const meta_server = "io.modelcontextprotocol/serverInfo";

pub const Options = struct {
    /// How the AI agent is named on the host's screen; default: the MCP client's name.
    name: ?[]const u8 = null,
    /// Streamable HTTP on this port instead of stdio.
    http_port: ?u16 = null,
    /// Listen on every interface, not just loopback (LAN or a tunnel). Needs a token.
    public: bool = false,
    /// Bearer token or path secret for HTTP; generated when public and not given.
    token: ?[]const u8 = null,
    /// Start a Cloudflare quick tunnel and print the public URL.
    tunnel: bool = false,
};

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return;
    buf[s.len] = 0;
    plat.rdc_log(buf[0..s.len :0].ptr);
}

const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    tools: tools.Tools,
    token: []const u8 = "",
    public: bool = false,
    label_set: bool = false,

    /// What the client calls itself, in the words the person at the computer knows.
    fn noteClient(s: *Server, name: ?[]const u8) void {
        if (s.label_set) return;
        const raw = name orelse return;
        s.label_set = true;
        s.tools.setAgent(clientLabel(raw), false);
    }
};

/// "claude-code" → "Claude Code" and so on; anything else as the client says it.
pub fn clientLabel(name: []const u8) []const u8 {
    const known = [_][2][]const u8{
        .{ "claude-code", "Claude Code" },       .{ "claude code", "Claude Code" }, .{ "claude-ai", "Claude" },
        .{ "claude-desktop", "Claude Desktop" }, .{ "claude", "Claude" },           .{ "codex", "Codex" },
        .{ "codex-cli", "Codex" },               .{ "codex_cli", "Codex" },         .{ "openai-mcp", "ChatGPT" },
        .{ "chatgpt", "ChatGPT" },               .{ "cursor", "Cursor" },           .{ "windsurf", "Windsurf" },
        .{ "mcp-inspector", "MCP Inspector" },   .{ "gemini-cli", "Gemini CLI" },
    };
    for (known) |k| {
        if (std.ascii.eqlIgnoreCase(k[0], name)) return k[1];
    }
    return name;
}

// ---------------------------------------------------------------------------
// One message in, one answer out

const Era = enum { legacy, modern };

const Outcome = enum { response, notification, invalid };

const Reply = struct {
    outcome: Outcome,
    /// For HTTP: which status fits the JSON-RPC answer.
    status: u16 = 200,
    era: Era = .legacy,
};

/// Handles one JSON-RPC message; the answer (if any) is written to `out`.
fn handle(s: *Server, arena: std.mem.Allocator, msg: []const u8, headers: ?[]const u8, out: *std.Io.Writer) Reply {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, msg, .{}) catch {
        writeError(out, null, -32700, "Parse error", null);
        return .{ .outcome = .response, .status = 400 };
    };
    if (parsed != .object) {
        writeError(out, null, -32600, "Invalid Request: a single JSON-RPC object is expected", null);
        return .{ .outcome = .response, .status = 400 };
    }
    const o = parsed.object;
    const method = str(o, "method") orelse {
        // A response from the client (to a request we never send) or junk.
        writeError(out, o.get("id"), -32600, "Invalid Request: no method", null);
        return .{ .outcome = .response, .status = 400 };
    };
    const id = o.get("id");
    const params: ?std.json.ObjectMap = if (o.get("params")) |p| (if (p == .object) p.object else null) else null;
    const meta: ?std.json.ObjectMap = if (params) |p| (if (p.get("_meta")) |m| (if (m == .object) m.object else null) else null) else null;
    const requested: ?[]const u8 = if (meta) |m| str(m, meta_version) else null;
    const era: Era = if (requested != null) .modern else .legacy;

    if (requested) |v| {
        if (!supported(v)) {
            if (id) |i| {
                writeUnsupported(out, i, v);
                return .{ .outcome = .response, .status = 400, .era = .modern };
            }
            return .{ .outcome = .notification, .era = .modern };
        }
        if (headers) |h| {
            if (http.headerValue(h, "mcp-protocol-version")) |hv| {
                if (!std.mem.eql(u8, hv, v)) {
                    writeError(out, id, -32020, "Header mismatch: MCP-Protocol-Version does not match _meta", null);
                    return .{ .outcome = .response, .status = 400, .era = .modern };
                }
            }
            if (http.headerValue(h, "mcp-method")) |hm| {
                if (!std.mem.eql(u8, hm, method)) {
                    writeError(out, id, -32020, "Header mismatch: Mcp-Method does not match method", null);
                    return .{ .outcome = .response, .status = 400, .era = .modern };
                }
            }
        }
        if (meta) |m| {
            if (m.get(meta_client)) |ci| {
                if (ci == .object) s.noteClient(str(ci.object, "name"));
            }
        }
    }

    if (std.mem.startsWith(u8, method, "notifications/")) return .{ .outcome = .notification, .era = era };
    const rid = id orelse return .{ .outcome = .notification, .era = era }; // a notification by another name

    if (std.mem.eql(u8, method, "initialize")) {
        var version: []const u8 = legacy_default;
        if (params) |p| {
            if (str(p, "protocolVersion")) |v| {
                if (supported(v)) version = v;
            }
            if (p.get("clientInfo")) |ci| {
                if (ci == .object) s.noteClient(str(ci.object, "name"));
            }
        }
        beginResult(out, rid);
        out.print("{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":", .{version}) catch {};
        writeServerInfo(out);
        out.writeAll(",\"instructions\":") catch {};
        jsonString(out, tools.instructions);
        out.writeAll("}}") catch {};
        return .{ .outcome = .response, .era = .legacy };
    }
    if (std.mem.eql(u8, method, "server/discover")) {
        beginResult(out, rid);
        out.writeAll("{\"resultType\":\"complete\",\"supportedVersions\":[") catch {};
        for (protocol_versions, 0..) |v, i| out.print("{s}\"{s}\"", .{ if (i == 0) "" else ",", v }) catch {};
        out.writeAll("],\"capabilities\":{\"tools\":{}},\"_meta\":{\"" ++ meta_server ++ "\":") catch {};
        writeServerInfo(out);
        out.writeAll("},\"instructions\":") catch {};
        jsonString(out, tools.instructions);
        out.writeAll(",\"ttlMs\":3600000,\"cacheScope\":\"public\"}}") catch {};
        return .{ .outcome = .response, .era = era };
    }
    if (std.mem.eql(u8, method, "ping") or std.mem.eql(u8, method, "logging/setLevel")) {
        beginResult(out, rid);
        out.writeAll(if (era == .modern) "{\"resultType\":\"complete\"}}" else "{}}") catch {};
        return .{ .outcome = .response, .era = era };
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        beginResult(out, rid);
        out.writeAll("{\"tools\":" ++ tools.definitions) catch {};
        if (era == .modern) {
            out.writeAll(",\"resultType\":\"complete\",\"ttlMs\":3600000,\"cacheScope\":\"public\",\"_meta\":{\"" ++ meta_server ++ "\":") catch {};
            writeServerInfo(out);
            out.writeAll("}") catch {};
        }
        out.writeAll("}}") catch {};
        return .{ .outcome = .response, .era = era };
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const p = params orelse {
            writeError(out, rid, -32602, "Invalid params: name is required", null);
            return .{ .outcome = .response, .era = era };
        };
        const name = str(p, "name") orelse {
            writeError(out, rid, -32602, "Invalid params: name is required", null);
            return .{ .outcome = .response, .era = era };
        };
        if (headers) |h| {
            if (http.headerValue(h, "mcp-name")) |hn| {
                var dec_buf: [256]u8 = undefined;
                if (!std.mem.eql(u8, decodeHeaderValue(hn, &dec_buf), name)) {
                    writeError(out, rid, -32020, "Header mismatch: Mcp-Name does not match params.name", null);
                    return .{ .outcome = .response, .status = 400, .era = .modern };
                }
            }
        }
        const args: tools.Args = .{ .map = if (p.get("arguments")) |a| (if (a == .object) a.object else null) else null };
        var result: tools.Result = .{ .arena = arena };
        if (!s.tools.call(name, args, &result)) {
            var buf: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "Unknown tool: {s}", .{name}) catch "Unknown tool";
            writeError(out, rid, -32602, text, null);
            return .{ .outcome = .response, .era = era };
        }
        beginResult(out, rid);
        out.writeAll("{\"content\":[") catch {};
        for (result.parts.items, 0..) |part, i| {
            if (i > 0) out.writeAll(",") catch {};
            switch (part) {
                .text => |t| {
                    out.writeAll("{\"type\":\"text\",\"text\":") catch {};
                    jsonString(out, t);
                    out.writeAll("}") catch {};
                },
                .jpeg => |j| {
                    out.writeAll("{\"type\":\"image\",\"mimeType\":\"image/jpeg\",\"data\":\"") catch {};
                    std.base64.standard.Encoder.encodeWriter(out, j) catch {};
                    out.writeAll("\"}") catch {};
                },
            }
        }
        out.print("],\"isError\":{s}", .{if (result.is_error) "true" else "false"}) catch {};
        if (era == .modern) out.writeAll(",\"resultType\":\"complete\"") catch {};
        out.writeAll("}}") catch {};
        return .{ .outcome = .response, .era = era };
    }
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Method not found: {s}", .{method}) catch "Method not found";
    writeError(out, rid, -32601, text, null);
    return .{ .outcome = .response, .status = if (era == .modern) 404 else 200, .era = era };
}

fn supported(v: []const u8) bool {
    for (protocol_versions) |p| {
        if (std.mem.eql(u8, p, v)) return true;
    }
    return false;
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn jsonString(out: *std.Io.Writer, s: []const u8) void {
    std.json.Stringify.encodeJsonString(s, .{}, out) catch {};
}

fn writeId(out: *std.Io.Writer, id: ?std.json.Value) void {
    if (id) |v| {
        std.json.Stringify.value(v, .{}, out) catch {};
    } else {
        out.writeAll("null") catch {};
    }
}

fn beginResult(out: *std.Io.Writer, id: std.json.Value) void {
    out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch {};
    writeId(out, id);
    out.writeAll(",\"result\":") catch {};
}

fn writeServerInfo(out: *std.Io.Writer) void {
    out.print("{{\"name\":\"rdc\",\"title\":\"RDC — Remote Desktop Control\",\"version\":\"{s}\"}}", .{update.current_version}) catch {};
}

fn writeError(out: *std.Io.Writer, id: ?std.json.Value, code: i32, message: []const u8, data: ?[]const u8) void {
    out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch {};
    writeId(out, id);
    out.print(",\"error\":{{\"code\":{d},\"message\":", .{code}) catch {};
    jsonString(out, message);
    if (data) |d| out.print(",\"data\":{s}", .{d}) catch {};
    out.writeAll("}}") catch {};
}

fn writeUnsupported(out: *std.Io.Writer, id: std.json.Value, requested: []const u8) void {
    out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch {};
    writeId(out, id);
    out.writeAll(",\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[") catch {};
    for (protocol_versions, 0..) |v, i| out.print("{s}\"{s}\"", .{ if (i == 0) "" else ",", v }) catch {};
    out.writeAll("],\"requested\":") catch {};
    jsonString(out, requested);
    out.writeAll("}}}") catch {};
}

/// "=?base64?SGk=?=" → "Hi"; anything else as is.
pub fn decodeHeaderValue(v: []const u8, buf: []u8) []const u8 {
    const pre = "=?base64?";
    if (!std.mem.startsWith(u8, v, pre) or !std.mem.endsWith(u8, v, "?=") or v.len < pre.len + 2) return v;
    const inner = v[pre.len .. v.len - 2];
    const n = std.base64.standard.Decoder.calcSizeForSlice(inner) catch return v;
    if (n > buf.len) return v;
    std.base64.standard.Decoder.decode(buf[0..n], inner) catch return v;
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// stdio

fn runStdio(s: *Server) void {
    const io = s.io;
    const in_buf = s.gpa.alloc(u8, 4 * 1024 * 1024) catch return;
    defer s.gpa.free(in_buf);
    var reader = Io.File.stdin().readerStreaming(io, in_buf);
    const r = &reader.interface;
    var out_buf: [64 * 1024]u8 = undefined;
    var writer = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &writer.interface;
    log("MCP server ready on stdio", .{});
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => break,
            error.StreamTooLong => {
                log("MCP: a message over 4 MB was dropped", .{});
                _ = r.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            error.ReadFailed => break,
        };
        const msg = std.mem.trim(u8, line, " \t\r\n");
        if (msg.len == 0) continue;
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var answer: Io.Writer.Allocating = .init(arena);
        const reply = handle(s, arena, msg, null, &answer.writer);
        if (reply.outcome == .response) {
            w.writeAll(answer.written()) catch break;
            w.writeAll("\n") catch break;
            w.flush() catch break;
        }
    }
    log("MCP client went away — exiting", .{});
}

// ---------------------------------------------------------------------------
// Streamable HTTP

fn runHttp(s: *Server, port: u16, opts: Options) !void {
    const io = s.io;
    const bind = if (s.public) "0.0.0.0" else "127.0.0.1";
    const addr = net.IpAddress.parse(bind, port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        log("MCP: cannot listen on {s}:{d} ({t})", .{ bind, port, e });
        return e;
    };
    if (s.token.len > 0) {
        log("MCP server: http://{s}:{d}/mcp/{s}", .{ if (s.public) "<this computer>" else "127.0.0.1", port, s.token });
        log("MCP: the secret is the path (or Authorization: Bearer {s})", .{s.token});
    } else {
        log("MCP server: http://127.0.0.1:{d}/mcp (loopback only, no token)", .{port});
    }
    var tunnel: ?std.process.Child = null;
    if (opts.tunnel) tunnel = startTunnel(s, port);
    defer if (tunnel) |*t| t.kill(io);
    while (true) {
        const stream = server.accept(io) catch |e| {
            log("MCP: accept failed ({t})", .{e});
            io.sleep(.fromMilliseconds(100), .awake) catch {};
            continue;
        };
        const t = std.Thread.spawn(.{}, connection, .{ s, stream }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

fn connection(s: *Server, stream: net.Stream) void {
    const io = s.io;
    defer stream.close(io);
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;
    const head_len = while (true) {
        if (std.mem.indexOf(u8, r.buffered(), "\r\n\r\n")) |i| break i + 4;
        if (r.bufferedLen() >= 32 * 1024) return;
        r.fillMore() catch return;
    };
    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = arena.dupe(u8, r.buffered()[0..head_len]) catch return;
    r.toss(head_len);
    const req = http.parseHead(head) orelse return respond(s, stream, 400, "text/plain", "Bad request", null);
    const path = http.pathOnly(req.path);

    const is_mcp = std.mem.eql(u8, path, "/mcp") or std.mem.startsWith(u8, path, "/mcp/");
    if (!is_mcp) {
        if (std.mem.eql(u8, req.method, "GET") and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/health"))) {
            var body: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&body, "RDC MCP server {s}. POST JSON-RPC to /mcp.\n", .{update.current_version}) catch "RDC MCP server\n";
            return respond(s, stream, 200, "text/plain; charset=utf-8", text, null);
        }
        return respond(s, stream, 404, "text/plain", "Not found", null);
    }

    // Authentication: the token in the path or as a bearer; without a token, loopback only.
    if (s.token.len > 0) {
        var ok = false;
        if (std.mem.startsWith(u8, path, "/mcp/")) ok = constEql(path["/mcp/".len..], s.token);
        if (!ok) {
            if (http.headerValue(head, "authorization")) |auth| {
                if (std.mem.startsWith(u8, auth, "Bearer ")) ok = constEql(std.mem.trim(u8, auth["Bearer ".len..], " "), s.token);
            }
        }
        if (!ok) return respond(s, stream, 401, "application/json", "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"Unauthorized: wrong or missing token\"}}", "WWW-Authenticate: Bearer realm=\"rdc\"\r\n");
    } else if (http.headerValue(head, "origin")) |origin| {
        if (!loopbackOrigin(origin)) return respond(s, stream, 403, "application/json", "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Forbidden origin\"}}", null);
    }

    if (std.mem.eql(u8, req.method, "GET") or std.mem.eql(u8, req.method, "DELETE")) {
        // No standalone SSE stream and no sessions: everything happens in POST responses.
        return respond(s, stream, 405, "text/plain", "Method Not Allowed", "Allow: POST\r\n");
    }
    if (!std.mem.eql(u8, req.method, "POST")) return respond(s, stream, 405, "text/plain", "Method Not Allowed", "Allow: POST\r\n");

    const len_text = http.headerValue(head, "content-length") orelse return respond(s, stream, 411, "text/plain", "Length Required", null);
    const len = std.fmt.parseInt(usize, len_text, 10) catch return respond(s, stream, 400, "text/plain", "Bad Content-Length", null);
    if (len > max_body) return respond(s, stream, 413, "text/plain", "Payload Too Large", null);
    const body = arena.alloc(u8, len) catch return;
    r.readSliceAll(body) catch return;

    var answer: Io.Writer.Allocating = .init(arena);
    const reply = handle(s, arena, body, head, &answer.writer);
    switch (reply.outcome) {
        .notification => respond(s, stream, 202, "text/plain", "", null),
        .response, .invalid => respond(s, stream, reply.status, "application/json", answer.written(), null),
    }
}

fn respond(s: *Server, stream: net.Stream, status: u16, content_type: []const u8, body: []const u8, extra: ?[]const u8) void {
    var buf: [2048]u8 = undefined;
    var sw = stream.writer(s.io, &buf);
    const w = &sw.interface;
    const reason: []const u8 = switch (status) {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        411 => "Length Required",
        413 => "Payload Too Large",
        else => "Error",
    };
    w.print("HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}" ++
        "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ status, reason, content_type, body.len, extra orelse "" }) catch return;
    w.writeAll(body) catch return;
    w.flush() catch {};
}

fn constEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    return std.crypto.timing_safe.compare(u8, a, b, .big) == .eq;
}

/// http://localhost:1234, http://127.0.0.1, http://[::1]:8 — a page on this computer.
pub fn loopbackOrigin(origin: []const u8) bool {
    var s = origin;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfScalar(u8, s, '/')) |i| s = s[0..i];
    if (std.mem.startsWith(u8, s, "[::1]")) return true;
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |i| s = s[0..i];
    return std.mem.eql(u8, s, "localhost") or std.mem.eql(u8, s, "127.0.0.1") or std.mem.endsWith(u8, s, ".localhost");
}

/// `cloudflared tunnel --url http://127.0.0.1:port`: a free public HTTPS address for the time
/// the process runs. The URL is read from cloudflared's output and logged with the token.
fn startTunnel(s: *Server, port: u16) ?std.process.Child {
    const io = s.io;
    var url_buf: [64]u8 = undefined;
    const local = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{port}) catch unreachable;
    const child = std.process.spawn(io, .{
        .argv = &.{ "cloudflared", "tunnel", "--no-autoupdate", "--url", local },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |e| {
        log("MCP: cannot start cloudflared ({t}). Install it (brew install cloudflared, winget install Cloudflare.cloudflared) or use another tunnel to http://127.0.0.1:{d}", .{ e, port });
        return null;
    };
    const t = std.Thread.spawn(.{}, tunnelReader, .{ s, child.stderr.?, port }) catch return child;
    t.detach();
    return child;
}

fn tunnelReader(s: *Server, pipe: Io.File, port: u16) void {
    var buf: [8192]u8 = undefined;
    var fr = pipe.readerStreaming(s.io, &buf);
    const r = &fr.interface;
    var announced = false;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                _ = r.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            else => return,
        };
        if (announced) continue;
        const i = std.mem.indexOf(u8, line, "https://") orelse continue;
        var end = i;
        while (end < line.len and line[end] != ' ' and line[end] != '|' and line[end] != '\r' and line[end] != '\n') end += 1;
        const url = line[i..end];
        if (!std.mem.endsWith(u8, url, ".trycloudflare.com")) continue;
        announced = true;
        if (s.token.len > 0) {
            log("MCP tunnel: {s}/mcp/{s}  ← add this as a connector (claude.ai, ChatGPT); it works while rdc mcp runs", .{ url, s.token });
        } else {
            log("MCP tunnel: {s}/mcp (local port {d})", .{ url, port });
        }
    }
}

// ---------------------------------------------------------------------------

pub fn run(gpa: std.mem.Allocator, io: Io, opts: Options) !void {
    var s: Server = .{ .gpa = gpa, .io = io, .tools = tools.Tools.init(gpa, io), .public = opts.public or opts.tunnel };
    defer s.tools.deinit();
    if (opts.name) |n| {
        s.tools.setAgent(n, true);
        s.label_set = true;
    }
    const port = opts.http_port orelse {
        if (opts.public or opts.tunnel or opts.token != null) log("MCP: --public, --tunnel and --token apply to --http only", .{});
        return runStdio(&s);
    };
    var token_buf: [40]u8 = undefined;
    if (opts.token) |t| {
        s.token = t;
    } else if (s.public) {
        var raw: [24]u8 = undefined;
        io.random(&raw);
        s.token = std.base64.url_safe_no_pad.Encoder.encode(&token_buf, &raw);
    }
    try runHttp(&s, port, opts);
}

test "mcp: client labels" {
    try std.testing.expectEqualStrings("Claude Code", clientLabel("claude-code"));
    try std.testing.expectEqualStrings("Codex", clientLabel("Codex"));
    try std.testing.expectEqualStrings("my-agent", clientLabel("my-agent"));
}

test "mcp: header value decoding" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Hi", decodeHeaderValue("=?base64?SGk=?=", &buf));
    try std.testing.expectEqualStrings("click", decodeHeaderValue("click", &buf));
}

test "mcp: loopback origins" {
    try std.testing.expect(loopbackOrigin("http://localhost:6274"));
    try std.testing.expect(loopbackOrigin("http://127.0.0.1"));
    try std.testing.expect(loopbackOrigin("http://[::1]:8080"));
    try std.testing.expect(!loopbackOrigin("https://evil.example"));
    try std.testing.expect(!loopbackOrigin("http://localhost.evil.example"));
}
