//! RDC — Remote Desktop Control. Entry point.
const std = @import("std");
const host = @import("host.zig");
const mcp = @import("agent/mcp.zig");
const plat = @import("platform.zig");

const usage =
    \\RDC — remote desktop
    \\
    \\  rdc [host] [options]     share this computer by link or code
    \\  rdc mcp [options]        MCP server: AI agents see and control computers that run RDC
    \\  rdc version              print the version
    \\
    \\Host options:
    \\  --port N        port (default 7700)
    \\  --max-width N   image width (default 1920)
    \\  --fps N         frames per second (default 60)
    \\  --no-ui         no window: code and link go to the log
    \\  --web-dir DIR   for development: viewer page from disk (DIR is the web folder)
    \\  --update-url U  for testing: updates from U instead of GitHub releases
    \\  --no-remote     no link from anywhere: no public signaling brokers, no WebRTC
    \\  --remote-url U  for testing: the page the link from anywhere opens (default https://anods.github.io/RDC/)
    \\
    \\MCP options (stdio by default; Claude Code, Codex and Claude Desktop start it this way):
    \\  --name NAME     how the agent is shown on the controlled computer (default: the client's name)
    \\  --http [PORT]   Streamable HTTP on 127.0.0.1:PORT (default 7710) instead of stdio
    \\  --public        with --http: listen on every interface; a token is required or generated
    \\  --token T       with --http: the secret, as the path /mcp/T or Authorization: Bearer T
    \\  --tunnel        with --http: start a Cloudflare quick tunnel and log the public URL
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const eql = std.mem.eql;
    if (args.len > 1 and eql(u8, args[1], "mcp")) return runMcp(init, args[2..]);
    var opts: host.Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(u8, a, "host")) {
            continue;
        } else if (eql(u8, a, "--no-ui")) {
            opts.ui = false;
        } else if (eql(u8, a, "version") or eql(u8, a, "--version")) {
            host.log("RDC {s}", .{host.version});
            return;
        } else if (eql(u8, a, "help") or eql(u8, a, "--help") or eql(u8, a, "-h")) {
            return printUsage();
        } else if (i + 1 < args.len and eql(u8, a, "--port")) {
            i += 1;
            opts.port = std.fmt.parseInt(u16, args[i], 10) catch return printUsage();
        } else if (i + 1 < args.len and eql(u8, a, "--max-width")) {
            i += 1;
            opts.max_width = std.fmt.parseInt(c_int, args[i], 10) catch return printUsage();
        } else if (i + 1 < args.len and eql(u8, a, "--fps")) {
            i += 1;
            opts.fps = std.fmt.parseInt(c_int, args[i], 10) catch return printUsage();
        } else if (i + 1 < args.len and eql(u8, a, "--web-dir")) {
            i += 1;
            opts.web_dir = args[i];
        } else if (i + 1 < args.len and eql(u8, a, "--update-url")) {
            i += 1;
            opts.update_url = args[i];
        } else if (eql(u8, a, "--no-remote")) {
            opts.remote = false;
        } else if (i + 1 < args.len and eql(u8, a, "--remote-url")) {
            i += 1;
            opts.remote_url = args[i];
        } else if (std.mem.startsWith(u8, a, "-psn_")) {
            continue; // Finder sometimes passes a process serial number
        } else {
            return printUsage();
        }
    }
    plat.rdc_init();
    try host.run(init.gpa, init.io, opts);
}

fn runMcp(init: std.process.Init, args: []const [:0]const u8) !void {
    const eql = std.mem.eql;
    var opts: mcp.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (i + 1 < args.len and eql(u8, a, "--name")) {
            i += 1;
            opts.name = args[i];
        } else if (eql(u8, a, "--http")) {
            opts.http_port = mcp.default_http_port;
            if (i + 1 < args.len) {
                if (std.fmt.parseInt(u16, args[i + 1], 10)) |p| {
                    opts.http_port = p;
                    i += 1;
                } else |_| {}
            }
        } else if (eql(u8, a, "--public")) {
            opts.public = true;
        } else if (i + 1 < args.len and eql(u8, a, "--token")) {
            i += 1;
            opts.token = args[i];
        } else if (eql(u8, a, "--tunnel")) {
            opts.tunnel = true;
            if (opts.http_port == null) opts.http_port = mcp.default_http_port;
        } else if (eql(u8, a, "--help") or eql(u8, a, "-h")) {
            return printUsage();
        } else {
            return printUsage();
        }
    }
    if (opts.token == null) {
        if (init.environ_map.get("RDC_MCP_TOKEN")) |t| {
            if (t.len > 0) opts.token = t;
        }
    }
    plat.rdc_init();
    try mcp.run(init.gpa, init.io, opts);
}

fn printUsage() void {
    plat.rdc_log(usage);
}
