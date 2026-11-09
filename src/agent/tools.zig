//! What an AI agent can do through RDC: connect to a computer by its link or code, see the
//! screen, point, click, scroll, type and press keys. Every action answers with a fresh
//! screenshot, so the agent always acts on what the screen shows now.
//!
//! Coordinates are pixels of the latest full screenshot of that computer. The screenshot is the
//! host's frame shrunk to fit `shot_max_w` × `shot_max_h`, so the model sees it unscaled and the
//! pixel it reads off the picture is the pixel it gets.
const std = @import("std");
const Io = std.Io;
const client = @import("client.zig");
const keys = @import("keys.zig");
const plat = @import("../platform.zig");

pub const max_devices = 4;
pub const shot_max_w = 1280;
pub const shot_max_h = 800;
const shot_quality = 80;
const zoom_quality = 90;
const wheel_notch_px: f32 = 100; // what browsers report for one notch; the host converts
const key_gap_ms = 20;

pub const Part = union(enum) {
    text: []const u8,
    jpeg: []const u8,
};

/// A tool result, allocated in the request's arena.
pub const Result = struct {
    arena: std.mem.Allocator,
    parts: std.ArrayList(Part) = .empty,
    is_error: bool = false,

    pub fn say(r: *Result, comptime fmt: []const u8, args: anytype) void {
        const s = r.arena.print(fmt, args) catch return;
        r.parts.append(r.arena, .{ .text = s }) catch {};
    }

    pub fn fail(r: *Result, comptime fmt: []const u8, args: anytype) void {
        r.is_error = true;
        r.say(fmt, args);
    }

    fn image(r: *Result, jpeg: []const u8) void {
        r.parts.append(r.arena, .{ .jpeg = jpeg }) catch {};
    }
};

/// Arguments of a call: a JSON object, read by name with defaults.
pub const Args = struct {
    map: ?std.json.ObjectMap,

    pub fn str(a: Args, key: []const u8) ?[]const u8 {
        const m = a.map orelse return null;
        const v = m.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    pub fn num(a: Args, key: []const u8) ?f64 {
        const m = a.map orelse return null;
        const v = m.get(key) orelse return null;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    pub fn boolean(a: Args, key: []const u8, default: bool) bool {
        const m = a.map orelse return default;
        const v = m.get(key) orelse return default;
        return if (v == .bool) v.bool else default;
    }

    pub fn object(a: Args, key: []const u8) Args {
        const m = a.map orelse return .{ .map = null };
        const v = m.get(key) orelse return .{ .map = null };
        return .{ .map = if (v == .object) v.object else null };
    }
};

const Device = struct {
    name_buf: [48]u8 = undefined,
    name_len: usize = 0,
    session: *client.Session,
    /// Size of the latest full screenshot: the agent's coordinate space for this computer.
    shot_w: u32 = 0,
    shot_h: u32 = 0,

    fn name(d: *const Device) []const u8 {
        return d.name_buf[0..d.name_len];
    }
};

pub const Tools = struct {
    gpa: std.mem.Allocator,
    io: Io,
    devices: [max_devices]?Device = @splat(null),
    current: ?usize = null,
    agent_buf: [64]u8 = undefined,
    agent_len: usize = 0,
    agent_fixed: bool = false,
    mutex: Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: Io) Tools {
        var t: Tools = .{ .gpa = gpa, .io = io };
        t.setAgent("AI agent", false);
        return t;
    }

    /// The label the host shows next to the Stop button. `fixed` comes from --name and wins
    /// over what the MCP client calls itself.
    pub fn setAgent(t: *Tools, label: []const u8, fixed: bool) void {
        if (t.agent_fixed and !fixed) return;
        const n = @min(label.len, t.agent_buf.len);
        @memcpy(t.agent_buf[0..n], label[0..n]);
        t.agent_len = n;
        if (fixed) t.agent_fixed = true;
    }

    pub fn deinit(t: *Tools) void {
        for (&t.devices) |*slot| {
            if (slot.*) |d| d.session.close();
            slot.* = null;
        }
    }

    /// Runs the named tool. false: unknown tool.
    pub fn call(t: *Tools, name: []const u8, args: Args, res: *Result) bool {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const handlers = .{
            .{ "connect", connect },       .{ "devices", listDevices }, .{ "disconnect", disconnect },
            .{ "screenshot", screenshot }, .{ "click", click },         .{ "move", movePointer },
            .{ "drag", drag },             .{ "scroll", scroll },       .{ "type", typeText },
            .{ "key", pressKeys },         .{ "wait", wait },
        };
        inline for (handlers) |h| {
            if (std.mem.eql(u8, name, h[0])) {
                h[1](t, args, res);
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------ devices

    fn pick(t: *Tools, args: Args, res: *Result) ?*Device {
        if (args.str("device")) |want| {
            for (&t.devices) |*slot| {
                if (slot.*) |*d| {
                    if (std.ascii.eqlIgnoreCase(d.name(), want)) return d;
                }
            }
            res.fail("No connected computer is named \"{s}\". Call devices to see the names.", .{want});
            return null;
        }
        if (t.current) |i| {
            if (t.devices[i]) |*d| return d;
        }
        res.fail("Not connected to any computer. Call connect with the link from the RDC window first.", .{});
        return null;
    }

    /// Drops a device whose session ended; tells the agent why.
    fn alive(t: *Tools, d: *Device, res: *Result) bool {
        var why: [200]u8 = undefined;
        const reason = d.session.closedReason(&why) orelse return true;
        res.fail("The connection to {s} ended: {s}. Connect again with a fresh link from the RDC window.", .{ d.name(), reason });
        t.forget(d);
        return false;
    }

    fn forget(t: *Tools, d: *Device) void {
        for (&t.devices, 0..) |*slot, i| {
            if (slot.*) |*x| {
                if (x == d) {
                    x.session.close();
                    slot.* = null;
                    if (t.current == i) t.current = null;
                }
            }
        }
        if (t.current == null) {
            for (t.devices, 0..) |slot, i| {
                if (slot != null) {
                    t.current = i;
                    break;
                }
            }
        }
    }

    fn connect(t: *Tools, args: Args, res: *Result) void {
        var target: client.Target = undefined;
        if (args.str("link")) |link| {
            target = client.parseLink(link) orelse
                return res.fail("Not an RDC link: {s}. It looks like http://192.168.1.20:7700/#123456789 and comes from \"Copy link\" in the RDC window on that computer.", .{link});
        } else if (args.str("address")) |addr| {
            target = client.parseAddress(addr) orelse return res.fail("Not a valid address: {s}", .{addr});
            target.code = args.str("code") orelse return res.fail("Pass the 9-digit code from the RDC window along with the address.", .{});
        } else return res.fail("Pass link (from the RDC window on that computer), or address and code.", .{});

        var digits: usize = 0;
        for (target.code) |c| {
            if (std.ascii.isDigit(c)) digits += 1;
        }
        if (digits != 9) return res.fail("The code has 9 digits, got \"{s}\".", .{target.code});

        const slot = for (t.devices, 0..) |d, i| {
            if (d == null) break i;
        } else return res.fail("{d} computers are connected already — disconnect one first.", .{max_devices});

        var failure: client.Failure = .{};
        const session = client.connect(t.gpa, t.io, target, t.agent_buf[0..t.agent_len], &failure) catch |e| switch (e) {
            error.Rejected => return res.fail("{s}:{d} refused: {s}", .{ target.host, target.port, failure.text() }),
            error.BadAddress => return res.fail("Cannot resolve \"{s}\".", .{target.host}),
            error.ConnectFailed => return res.fail("Nothing answers at {s}:{d}. RDC must be running on that computer and reachable from this one (same network, or a tunnel).", .{ target.host, target.port }),
            error.HandshakeFailed => return res.fail("{s}:{d} is not an RDC host.", .{ target.host, target.port }),
            error.Timeout => return res.fail("{s}:{d} did not answer in time.", .{ target.host, target.port }),
            error.Closed => return res.fail("{s}:{d} closed the connection.", .{ target.host, target.port }),
            error.OutOfMemory => return res.fail("Out of memory.", .{}),
        };

        var d: Device = .{ .session = session };
        t.nameDevice(&d, args.str("name") orelse session.hostName());
        t.devices[slot] = d;
        t.current = slot;
        const dev = &t.devices[slot].?;
        res.say("Connected to {s} ({s}, RDC {s} at {s}). It is now the current device.", .{ dev.name(), session.os(), session.version(), session.address() });
        t.shoot(dev, null, res);
    }

    /// A unique, plain name: letters, digits, dot, dash and underscore.
    fn nameDevice(t: *Tools, d: *Device, wanted: []const u8) void {
        var base: [40]u8 = undefined;
        var n: usize = 0;
        for (wanted) |c| {
            if (n == base.len) break;
            if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') {
                base[n] = c;
                n += 1;
            } else if (c == ' ' and n > 0 and base[n - 1] != '-') {
                base[n] = '-';
                n += 1;
            }
        }
        if (n == 0) {
            @memcpy(base[0..8], "computer");
            n = 8;
        }
        var suffix: u32 = 1;
        while (true) : (suffix += 1) {
            const candidate = if (suffix == 1)
                std.fmt.bufPrint(&d.name_buf, "{s}", .{base[0..n]}) catch unreachable
            else
                std.fmt.bufPrint(&d.name_buf, "{s}-{d}", .{ base[0..n], suffix }) catch unreachable;
            d.name_len = candidate.len;
            const taken = for (t.devices) |slot| {
                if (slot) |x| {
                    if (std.ascii.eqlIgnoreCase(x.name(), candidate)) break true;
                }
            } else false;
            if (!taken) return;
        }
    }

    fn listDevices(t: *Tools, args: Args, res: *Result) void {
        _ = args;
        var any = false;
        for (t.devices, 0..) |slot, i| {
            const d = slot orelse continue;
            any = true;
            var why: [200]u8 = undefined;
            if (d.session.closedReason(&why)) |reason| {
                res.say("{s} — disconnected ({s})", .{ d.name(), reason });
            } else {
                res.say("{s}{s} — {s}, RDC {s}, {s}, screen {d}×{d}", .{
                    d.name(),
                    if (t.current == i) " (current)" else "",
                    d.session.os(),
                    d.session.version(),
                    d.session.address(),
                    d.session.frame_w,
                    d.session.frame_h,
                });
            }
        }
        if (!any) res.say("No computers connected. Use connect with the link from the RDC window.", .{});
    }

    fn disconnect(t: *Tools, args: Args, res: *Result) void {
        const d = t.pick(args, res) orelse return;
        var name_copy: [48]u8 = undefined;
        const n = d.name_len;
        @memcpy(name_copy[0..n], d.name());
        t.forget(d);
        res.say("Disconnected from {s}.", .{name_copy[0..n]});
    }

    // ------------------------------------------------------------ seeing

    const Region = struct { x: i32, y: i32, w: i32, h: i32 };

    /// Takes a screenshot and appends it to the result. A region (in screenshot pixels) comes
    /// back enlarged for a closer look; the full picture also updates the coordinate space.
    fn shoot(t: *Tools, d: *Device, region: ?Region, res: *Result) void {
        _ = t;
        const snap = d.session.snapshot(3000) catch |e| switch (e) {
            error.Timeout => {
                var warn: [200]u8 = undefined;
                if (d.session.warning(&warn)) |w| return res.fail("No picture from {s}. The computer says: {s}", .{ d.name(), w });
                return res.fail("No picture from {s} yet — the computer may be asleep or RDC has no Screen Recording permission there.", .{d.name()});
            },
            else => return res.fail("No picture from {s}: the connection ended.", .{d.name()}),
        };
        defer d.session.gpa.free(snap.jpeg);
        var crop: Region = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        var quality: c_int = shot_quality;
        if (region) |r| {
            if (d.shot_w == 0 or d.shot_h == 0) return res.fail("Take a full screenshot first.", .{});
            // Screenshot pixels → frame pixels.
            const sx = @as(f64, @floatFromInt(snap.w)) / @as(f64, @floatFromInt(d.shot_w));
            const sy = @as(f64, @floatFromInt(snap.h)) / @as(f64, @floatFromInt(d.shot_h));
            crop = .{
                .x = @intFromFloat(@floor(@as(f64, @floatFromInt(r.x)) * sx)),
                .y = @intFromFloat(@floor(@as(f64, @floatFromInt(r.y)) * sy)),
                .w = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.w)) * sx)),
                .h = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.h)) * sy)),
            };
            if (crop.w <= 0 or crop.h <= 0) return res.fail("The region must have a positive width and height.", .{});
            quality = zoom_quality;
        }
        var out_len: usize = 0;
        var out_w: c_int = 0;
        var out_h: c_int = 0;
        const scaled = plat.rdc_jpeg_scale(snap.jpeg.ptr, snap.jpeg.len, crop.x, crop.y, crop.w, crop.h, shot_max_w, shot_max_h, quality, &out_len, &out_w, &out_h) orelse
            return res.fail("Could not decode the picture from {s}.", .{d.name()});
        defer plat.free(scaled);
        const copy = res.arena.dupe(u8, scaled[0..out_len]) catch return res.fail("Out of memory.", .{});
        if (region) |r| {
            res.say("Zoomed view of the region x={d} y={d} w={d} h={d} of {s}, shown at {d}×{d}. Coordinates for actions stay those of the full {d}×{d} screenshot.", .{ r.x, r.y, r.w, r.h, d.name(), out_w, out_h, d.shot_w, d.shot_h });
        } else {
            d.shot_w = @intCast(out_w);
            d.shot_h = @intCast(out_h);
            const cur = d.session.cursor();
            res.say("Screenshot of {s}, {d}×{d} (the screen is {d}×{d}). Pointer at ({d}, {d}).", .{
                d.name(),                                                         out_w,
                out_h,                                                            d.session.frame_w,
                d.session.frame_h,                                                @as(i32, @intFromFloat(cur[0] * @as(f64, @floatFromInt(out_w)))),
                @as(i32, @intFromFloat(cur[1] * @as(f64, @floatFromInt(out_h)))),
            });
        }
        res.image(copy);
    }

    fn screenshot(t: *Tools, args: Args, res: *Result) void {
        const d = t.pick(args, res) orelse return;
        if (!t.alive(d, res)) return;
        const reg = args.object("region");
        if (reg.map != null) {
            const r: Region = .{
                .x = @intFromFloat(reg.num("x") orelse 0),
                .y = @intFromFloat(reg.num("y") orelse 0),
                .w = @intFromFloat(reg.num("width") orelse reg.num("w") orelse 0),
                .h = @intFromFloat(reg.num("height") orelse reg.num("h") orelse 0),
            };
            // Make sure the coordinate space is current, then zoom.
            if (d.shot_w == 0) t.shoot(d, null, res);
            if (res.is_error) return;
            if (d.shot_w > 0) res.parts.clearRetainingCapacity();
            return t.shoot(d, r, res);
        }
        t.shoot(d, null, res);
    }

    /// Waits for the screen to react to an action, then appends a screenshot.
    fn afterAction(t: *Tools, d: *Device, since: u64, res: *Result) void {
        d.session.settle(since, 400, 150, 1500);
        if (!t.alive(d, res)) return;
        t.shoot(d, null, res);
    }

    // ------------------------------------------------------------ pointing

    const Point = struct { nx: f32, ny: f32, px: i32, py: i32 };

    /// Screenshot pixels → the host's 0..1 space. The pixel centre, so (0,0) is the corner pixel.
    fn point(d: *Device, x: f64, y: f64, res: *Result) ?Point {
        if (d.shot_w == 0 or d.shot_h == 0) {
            res.fail("Take a screenshot first so there is a coordinate space.", .{});
            return null;
        }
        const w: f64 = @floatFromInt(d.shot_w);
        const h: f64 = @floatFromInt(d.shot_h);
        if (x < 0 or y < 0 or x >= w or y >= h) {
            res.fail("({d}, {d}) is outside the {d}×{d} screenshot.", .{ @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), d.shot_w, d.shot_h });
            return null;
        }
        return .{
            .nx = @floatCast((x + 0.5) / w),
            .ny = @floatCast((y + 0.5) / h),
            .px = @intFromFloat(x),
            .py = @intFromFloat(y),
        };
    }

    fn xy(args: Args, res: *Result, xk: []const u8, yk: []const u8) ?[2]f64 {
        const x = args.num(xk) orelse {
            res.fail("{s} and {s} are required.", .{ xk, yk });
            return null;
        };
        const y = args.num(yk) orelse {
            res.fail("{s} and {s} are required.", .{ xk, yk });
            return null;
        };
        return .{ x, y };
    }

    fn buttonCode(args: Args, res: *Result) ?u8 {
        const b = args.str("button") orelse "left";
        if (std.ascii.eqlIgnoreCase(b, "left")) return 0;
        if (std.ascii.eqlIgnoreCase(b, "middle")) return 1;
        if (std.ascii.eqlIgnoreCase(b, "right")) return 2;
        res.fail("button must be left, right or middle.", .{});
        return null;
    }

    const Mods = struct { list: [keys.max_mods]u16 = @splat(0), n: usize = 0 };

    fn modifiers(args: Args, res: *Result) ?Mods {
        var m: Mods = .{};
        const text = args.str("modifiers") orelse return m;
        var it = std.mem.splitScalar(u8, text, '+');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) continue;
            const usage = keys.keyUsage(name) orelse {
                res.fail("Unknown modifier \"{s}\". Use ctrl, shift, alt (option), cmd (win), joined with +.", .{name});
                return null;
            };
            if (usage < 0xE0 or usage > 0xE7) {
                res.fail("\"{s}\" is not a modifier. Use ctrl, shift, alt (option), cmd (win).", .{name});
                return null;
            }
            if (m.n == m.list.len) break;
            m.list[m.n] = usage;
            m.n += 1;
        }
        return m;
    }

    fn holdMods(s: *client.Session, m: Mods, down: bool) client.Error!void {
        var i: usize = 0;
        while (i < m.n) : (i += 1) {
            const idx = if (down) i else m.n - 1 - i;
            try s.key(m.list[idx], down);
        }
    }

    fn movePointer(t: *Tools, args: Args, res: *Result) void {
        const d = t.pick(args, res) orelse return;
        if (!t.alive(d, res)) return;
        const c = xy(args, res, "x", "y") orelse return;
        const p = point(d, c[0], c[1], res) orelse return;
        const since = d.session.frameSeq();
        d.session.move(p.nx, p.ny) catch return t.lost(d, res);
        res.say("Moved the pointer to ({d}, {d}) on {s}.", .{ p.px, p.py, d.name() });
        t.afterAction(d, since, res);
    }

    fn click(t: *Tools, args: Args, res: *Result) void {
        const d = t.pick(args, res) orelse return;
        if (!t.alive(d, res)) return;
        const c = xy(args, res, "x", "y") orelse return;
        const p = point(d, c[0], c[1], res) orelse return;
        const btn = buttonCode(args, res) orelse return;
        const mods = modifiers(args, res) orelse return;
        var count: u32 = @intFromFloat(@max(1, @min(3, args.num("count") orelse 1)));
        if (args.boolean("double", false)) count = 2;
        const s = d.session;
        const since = s.frameSeq();
        const ok = blk: {
            s.move(p.nx, p.ny) catch break :blk false;
            holdMods(s, mods, true) catch break :blk false;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                if (i > 0) s.sleep(60);
                s.button(btn, true, p.nx, p.ny) catch break :blk false;
                s.button(btn, false, p.nx, p.ny) catch break :blk false;
            }
            holdMods(s, mods, false) catch break :blk false;
            break :blk true;
        };
        if (!ok) return t.lost(d, res);
        const what: []const u8 = switch (count) {
            1 => "Clicked",
            2 => "Double-clicked",
            else => "Triple-clicked",
        };
        res.say("{s} {s} at ({d}, {d}) on {s}{s}{s}.", .{ what, args.str("button") orelse "left", p.px, p.py, d.name(), if (mods.n > 0) " holding " else "", args.str("modifiers") orelse "" });
        t.afterAction(d, since, res);
    }

    fn drag(t: *Tools, args: Args, res: *Result) void {
        const d = t.pick(args, res) orelse return;
        if (!t.alive(d, res)) return;
        const from = xy(args, res, "from_x", "from_y") orelse return;
        const to = xy(args, res, "to_x", "to_y") orelse return;
        const a = point(d, from[0], from[1], res) orelse return;
        const b = point(d, to[0], to[1], res) orelse return;
        const btn = buttonCode(args, res) orelse return;
        const mods = modifiers(args, res) orelse return;
        const s = d.session;
        const since = s.frameSeq();
        const ok = blk: {
            s.move(a.nx, a.ny) catch break :blk false;
            holdMods(s, mods, true) catch break :blk false;
            s.sleep(40);
            s.button(btn, true, a.nx, a.ny) catch break :blk false;
            s.sleep(80);
            // Apps notice a drag only once the pointer travels a little, step by step.
            const steps: u32 = 12;
            var i: u32 = 1;
            while (i <= steps) : (i += 1) {
                const f: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                s.move(a.nx + (b.nx - a.nx) * f, a.ny + (b.ny - a.ny) * f) catch break :blk false;
                s.sleep(16);
            }
            s.sleep(80);
            s.button(btn, false, b.nx, b.ny) catch break :blk false;
            holdMods(s, mods, false) catch break :blk false;
            break :blk true;
        };
        if (!ok) return t.lost(d, res);
        res.say("Dragged from ({d}, {d}) to ({d}, {d}) on {s}.", .{ a.px, a.py, b.px, b.py, d.name() });
        t.afterAction(d, since, res);
    }

    fn scroll(t: *Tools, args: Args, res: *Result) void {
        const d = t.pick(args, res) orelse return;
        if (!t.alive(d, res)) return;
        const s = d.session;
        const since = s.frameSeq();
        var at: ?Point = null;
        if (args.num("x") != null or args.num("y") != null) {
            const c = xy(args, res, "x", "y") orelse return;
            at = point(d, c[0], c[1], res) orelse return;
        }
        var dx: f32 = @floatCast(args.num("right") orelse 0);
        var dy: f32 = @floatCast(args.num("down") orelse 0);
        if (args.str("direction")) |dir| {
            const amount: f32 = @floatCast(args.num("amount") orelse 3);
            if (std.ascii.eqlIgnoreCase(dir, "down")) dy = amount else if (std.ascii.eqlIgnoreCase(dir, "up")) dy = -amount else if (std.ascii.eqlIgnoreCase(dir, "right")) dx = amount else if (std.ascii.eqlIgnoreCase(dir, "left")) dx = -amount else return res.fail("direction must be up, down, left or right.", .{});
        }
        if (dx == 0 and dy == 0) return res.fail("Say how far: direction and amount (in wheel notches), or down/right as numbers.", .{});
        const ok = blk: {
            if (at) |p| s.move(p.nx, p.ny) catch break :blk false;
            // One notch per message, as a wheel does: apps with "smooth" scrolling expect it.
            var left_x = dx;
            var left_y = dy;
            while (@abs(left_x) > 0.01 or @abs(left_y) > 0.01) {
                const step_x = std.math.clamp(left_x, -1, 1);
                const step_y = std.math.clamp(left_y, -1, 1);
                s.wheel(step_x * wheel_notch_px, step_y * wheel_notch_px) catch break :blk false;
                left_x -= step_x;
                left_y -= step_y;
                s.sleep(25);
            }
            break :blk true;
        };
        if (!ok) return t.lost(d, res);
        if (at) |p| {
            res.say("Scrolled {d:.0} down, {d:.0} right at ({d}, {d}) on {s}.", .{ dy, dx, p.px, p.py, d.name() });
        } else {
            res.say("Scrolled {d:.0} down, {d:.0} right on {s}.", .{ dy, dx, d.name() });
        }
        t.afterAction(d, since, res);
    }

    // ------------------------------------------------------------ typing

    fn typeText(t: *Tools, args: Args, res: *Result) void {
        const d = t.pick(args, res) orelse return;
        if (!t.alive(d, res)) return;
        const text = args.str("text") orelse return res.fail("text is required.", .{});
        if (text.len == 0) return res.fail("text is empty.", .{});
        if (text.len > 64 * 1024) return res.fail("Type at most 64 KB at a time.", .{});
        const s = d.session;
        const since = s.frameSeq();
        const ok = blk: {
            if (s.can_text) {
                s.text(text) catch break :blk false;
            } else {
                // An older host: US-layout key presses, ASCII only.
                for (text) |c| {
                    const stroke = keys.usChar(c) orelse continue;
                    if (stroke.shift) s.key(keys.usage_shift, true) catch break :blk false;
                    s.key(stroke.usage, true) catch break :blk false;
                    s.key(stroke.usage, false) catch break :blk false;
                    if (stroke.shift) s.key(keys.usage_shift, false) catch break :blk false;
                    s.sleep(8);
                }
            }
            break :blk true;
        };
        if (!ok) return t.lost(d, res);
        var preview_buf: [64]u8 = undefined;
        res.say("Typed {d} characters on {s}: \"{s}{s}\".", .{ std.unicode.utf8CountCodepoints(text) catch text.len, d.name(), preview(text, &preview_buf), if (text.len > preview_buf.len) "…" else "" });
        if (args.boolean("enter", false)) {
            s.key(keys.usage_enter, true) catch return t.lost(d, res);
            s.key(keys.usage_enter, false) catch return t.lost(d, res);
            res.say("Then pressed Enter.", .{});
        }
        t.afterAction(d, since, res);
    }

    fn preview(text: []const u8, buf: []u8) []const u8 {
        var n: usize = @min(text.len, buf.len);
        while (n > 0 and n < text.len and text[n] & 0xC0 == 0x80) n -= 1;
        var out: usize = 0;
        for (text[0..n]) |c| {
            buf[out] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
            out += 1;
        }
        return buf[0..out];
    }

    fn pressKeys(t: *Tools, args: Args, res: *Result) void {
        const d = t.pick(args, res) orelse return;
        if (!t.alive(d, res)) return;
        const text = args.str("keys") orelse args.str("key") orelse return res.fail("keys is required, e.g. \"ctrl+s\" or \"down down enter\".", .{});
        var count: u32 = @intFromFloat(@max(1, @min(50, args.num("repeat") orelse 1)));
        var seq = keys.Sequence.init(text);
        var combos: [32]keys.Combo = undefined;
        var n: usize = 0;
        while (seq.next()) |part| {
            if (n == combos.len) return res.fail("At most {d} key presses per call.", .{combos.len});
            combos[n] = keys.parseCombo(part) catch |e| switch (e) {
                error.UnknownKey => return res.fail("Unknown key \"{s}\". Use names like enter, tab, esc, backspace, delete, up, f5, a, 1, and combos like ctrl+shift+t or cmd+space.", .{part}),
                error.TooManyModifiers => return res.fail("Too many modifiers in \"{s}\".", .{part}),
                error.EmptyKey => continue,
            };
            n += 1;
        }
        if (n == 0) return res.fail("keys is empty.", .{});
        const s = d.session;
        const since = s.frameSeq();
        const ok = blk: {
            while (count > 0) : (count -= 1) {
                for (combos[0..n]) |c| {
                    for (c.modifiers()) |m| s.key(m, true) catch break :blk false;
                    s.key(c.key, true) catch break :blk false;
                    s.key(c.key, false) catch break :blk false;
                    var i = c.mod_count;
                    while (i > 0) {
                        i -= 1;
                        s.key(c.mods[i], false) catch break :blk false;
                    }
                    s.sleep(key_gap_ms);
                }
            }
            break :blk true;
        };
        if (!ok) return t.lost(d, res);
        res.say("Pressed {s} on {s}.", .{ text, d.name() });
        t.afterAction(d, since, res);
    }

    fn wait(t: *Tools, args: Args, res: *Result) void {
        const d = t.pick(args, res) orelse return;
        if (!t.alive(d, res)) return;
        const seconds = @max(0.1, @min(30, args.num("seconds") orelse 1));
        d.session.sleep(@intFromFloat(seconds * 1000));
        if (!t.alive(d, res)) return;
        res.say("Waited {d:.1} s.", .{seconds});
        t.shoot(d, null, res);
    }

    fn lost(t: *Tools, d: *Device, res: *Result) void {
        if (t.alive(d, res)) {
            res.fail("Could not send the action to {s}.", .{d.name()});
        }
    }
};

/// Tool descriptions for tools/list, as the model reads them: one line of JSON (stdio framing
/// is one message per line), built at compile time from the readable form below.
pub const definitions = stripNewlines(definitions_source);

fn stripNewlines(comptime text: []const u8) *const [countKept(text)]u8 {
    comptime {
        @setEvalBranchQuota(text.len * 4);
        var out: [countKept(text)]u8 = undefined;
        var n: usize = 0;
        for (text) |c| {
            if (c == '\n' or c == '\r') continue;
            out[n] = c;
            n += 1;
        }
        const frozen = out;
        return &frozen;
    }
}

fn countKept(comptime text: []const u8) usize {
    @setEvalBranchQuota(text.len * 4);
    var n: usize = 0;
    for (text) |c| {
        if (c != '\n' and c != '\r') n += 1;
    }
    return n;
}

const definitions_source =
    \\[
    \\{"name":"connect","title":"Connect to a computer","description":"Connect to a computer that runs RDC. Ask the user for the link shown in the RDC window on that computer (Copy link gives http://<ip>:7700/#<9-digit code>); or pass its address and the 9-digit code. On success you get a screenshot and the computer becomes the current device. Up to 4 computers at once.","inputSchema":{"type":"object","properties":{"link":{"type":"string","description":"The link from the RDC window, like http://192.168.1.20:7700/#123456789"},"address":{"type":"string","description":"Host or IP with optional port (default 7700), when there is no link"},"code":{"type":"string","description":"The 9-digit code from the RDC window, with address"},"name":{"type":"string","description":"Optional short name for this computer in later calls"}}},"annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":true}},
    \\{"name":"devices","title":"List connected computers","description":"Which computers are connected, their names, OS and screen size. The current device gets every call that does not name one.","inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
    \\{"name":"disconnect","title":"Disconnect","description":"End the session with a computer.","inputSchema":{"type":"object","properties":{"device":{"type":"string","description":"Name from devices; default: the current device"}}},"annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
    \\{"name":"screenshot","title":"Screenshot","description":"The current screen of the computer. Coordinates of every other tool are pixels of this picture. Pass region to zoom into part of it for small text; the zoomed picture does not change the coordinate space.","inputSchema":{"type":"object","properties":{"device":{"type":"string"},"region":{"type":"object","description":"Part of the screenshot to enlarge","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}},"required":["x","y","width","height"]}}},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
    \\{"name":"click","title":"Click","description":"Move the pointer to (x, y) in screenshot pixels and click. Returns a screenshot taken after the screen settled.","inputSchema":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"button":{"type":"string","enum":["left","right","middle"],"default":"left"},"count":{"type":"integer","description":"1 (default), 2 for a double click, 3 for a triple click","minimum":1,"maximum":3},"modifiers":{"type":"string","description":"Keys held during the click, e.g. shift or ctrl+alt"},"device":{"type":"string"}},"required":["x","y"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":false}},
    \\{"name":"move","title":"Move the pointer","description":"Move the pointer to (x, y) without clicking: hover menus, tooltips.","inputSchema":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"device":{"type":"string"}},"required":["x","y"]},"annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
    \\{"name":"drag","title":"Drag","description":"Press the button at (from_x, from_y), move to (to_x, to_y) and release: select text, move windows, drag and drop.","inputSchema":{"type":"object","properties":{"from_x":{"type":"number"},"from_y":{"type":"number"},"to_x":{"type":"number"},"to_y":{"type":"number"},"button":{"type":"string","enum":["left","right","middle"],"default":"left"},"modifiers":{"type":"string"},"device":{"type":"string"}},"required":["from_x","from_y","to_x","to_y"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":false}},
    \\{"name":"scroll","title":"Scroll","description":"Turn the mouse wheel. Give a direction and an amount in notches (3 is about a screenful third), optionally at a point.","inputSchema":{"type":"object","properties":{"direction":{"type":"string","enum":["up","down","left","right"]},"amount":{"type":"number","description":"Wheel notches, default 3"},"x":{"type":"number","description":"Point to scroll at; default: where the pointer is"},"y":{"type":"number"},"device":{"type":"string"}},"required":["direction"]},"annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false}},
    \\{"name":"type","title":"Type text","description":"Type text into the focused field, any language. Click the field first. Set enter to press Enter afterwards.","inputSchema":{"type":"object","properties":{"text":{"type":"string"},"enter":{"type":"boolean","default":false},"device":{"type":"string"}},"required":["text"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":false}},
    \\{"name":"key","title":"Press keys","description":"Press keys and shortcuts in order, separated by spaces: \"enter\", \"ctrl+s\", \"cmd+space\", \"alt+tab\", \"down down enter\", \"shift+tab\". Names: letters, digits, f1-f24, enter, tab, esc, space, backspace, delete, insert, home, end, pageup, pagedown, up, down, left, right, printscreen, menu; modifiers ctrl, shift, alt (option), cmd (win, meta).","inputSchema":{"type":"object","properties":{"keys":{"type":"string"},"repeat":{"type":"integer","description":"Repeat the whole sequence this many times","minimum":1,"maximum":50},"device":{"type":"string"}},"required":["keys"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":false}},
    \\{"name":"wait","title":"Wait","description":"Wait for the screen to change (a page loading, an app starting), then screenshot.","inputSchema":{"type":"object","properties":{"seconds":{"type":"number","default":1,"minimum":0.1,"maximum":30},"device":{"type":"string"}}},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}}
    \\]
;

/// What the model is told about this server.
pub const instructions =
    \\RDC lets you see and control other computers. Each computer runs RDC, which shows a link and a 9-digit code; the person at that computer gives them to you. Workflow: connect(link) → look at the screenshot → act with click, type, key, scroll, drag (coordinates are pixels of the latest screenshot) → every action returns a new screenshot, read it before the next step. Use screenshot with a region to read small text. The person at the computer sees that an AI agent is connected and can stop you at any time; if a call says the connection ended, ask them for a fresh link. Be careful with irreversible actions: confirm with the user before deleting, sending or paying.
;
