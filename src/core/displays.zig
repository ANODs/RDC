//! Several displays (docs/PLAN.md, section 6 "Multiple displays"): the host shows one display at
//! a time and follows the pointer. The geometry lives here, free of any OS, so it can be tested.
//!
//! Desktop coordinates are the one space all displays share, as the OS lays them out: macOS
//! points (CGDisplayBounds), Windows virtual-screen pixels, X11 root-window pixels. A viewer's
//! input is normalized to the display it shows (0..1 inside it); values outside 0..1 — a drag
//! that runs past the picture's edge — go on through desktop coordinates onto whatever display
//! lies there, and stop at the edge of the union of displays.
const std = @import("std");

pub const max = 8;
pub const max_name = 64;

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    /// Whether p is on this display: the last pixel is x + w - 1.
    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.y >= r.y and p.x <= r.x + r.w - 1 and p.y <= r.y + r.h - 1;
    }

    /// The nearest point of the display.
    pub fn clamp(r: Rect, p: Point) Point {
        return .{
            .x = std.math.clamp(p.x, r.x, r.x + @max(0, r.w - 1)),
            .y = std.math.clamp(p.y, r.y, r.y + @max(0, r.h - 1)),
        };
    }

    /// How far p is outside the display: 0 inside, otherwise the longer of the two gaps.
    pub fn distance(r: Rect, p: Point) f64 {
        const c = r.clamp(p);
        return @max(@abs(p.x - c.x), @abs(p.y - c.y));
    }

    pub fn centre(r: Rect) Point {
        return .{ .x = r.x + (r.w - 1) / 2, .y = r.y + (r.h - 1) / 2 };
    }
};

pub const Point = struct { x: f64, y: f64 };

pub const Display = struct {
    id: u32 = 0,
    rect: Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    /// Size in pixels (differs from rect on a Retina display).
    pw: u32 = 0,
    ph: u32 = 0,
    primary: bool = false,
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,

    pub fn name(d: *const Display) []const u8 {
        return d.name_buf[0..d.name_len];
    }

    pub fn setName(d: *Display, s: []const u8) void {
        // Cut at a character boundary.
        var n = @min(s.len, d.name_buf.len);
        while (n > 0 and n < s.len and s[n] & 0xC0 == 0x80) n -= 1;
        @memcpy(d.name_buf[0..n], s[0..n]);
        d.name_len = n;
    }

    /// Same place, size and role (the name may be looked up differently from call to call).
    pub fn same(a: *const Display, b: *const Display) bool {
        return a.id == b.id and a.primary == b.primary and a.pw == b.pw and a.ph == b.ph and
            std.meta.eql(a.rect, b.rect);
    }
};

/// A viewer's coordinate, normalized to the display `shown`, in desktop coordinates. The same
/// mapping the hosts used before several displays: 0 — the first pixel, 1 — the last.
pub fn toDesktop(shown: Rect, nx: f64, ny: f64) Point {
    return .{ .x = shown.x + nx * (shown.w - 1), .y = shown.y + ny * (shown.h - 1) };
}

/// A desktop point as a viewer of `shown` sees it, clamped to 0..1.
pub fn toNormalized(shown: Rect, p: Point) Point {
    return .{
        .x = if (shown.w > 1) std.math.clamp((p.x - shown.x) / (shown.w - 1), 0, 1) else 0.5,
        .y = if (shown.h > 1) std.math.clamp((p.y - shown.y) / (shown.h - 1), 0, 1) else 0.5,
    };
}

/// Index of the display under p, or null.
pub fn at(list: []const Display, p: Point) ?usize {
    for (list, 0..) |d, i| {
        if (d.rect.contains(p)) return i;
    }
    return null;
}

/// p if it is on a display, otherwise the nearest point of the nearest display: the pointer
/// stops at the outer edges of the desktop, and in the gaps between displays of different sizes.
pub fn clampToUnion(list: []const Display, p: Point) Point {
    if (list.len == 0 or at(list, p) != null) return p;
    var best = list[0].rect.clamp(p);
    var best_d = dist2(best, p);
    for (list[1..]) |d| {
        const c = d.rect.clamp(p);
        const dd = dist2(c, p);
        if (dd < best_d) {
            best = c;
            best_d = dd;
        }
    }
    return best;
}

fn dist2(a: Point, b: Point) f64 {
    return (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y);
}

/// How far (in desktop units) the pointer must be past the shown display's edge before the
/// picture follows it: no flicker when it rests on the border.
pub const follow_margin: f64 = 16;

/// The display the picture should switch to with the pointer at p, or null to stay on `shown`
/// (an index into list, or null when the shown display is gone).
pub fn follow(list: []const Display, shown: ?usize, p: Point, margin: f64) ?usize {
    const other = at(list, p) orelse return null;
    const cur = shown orelse return other;
    if (cur >= list.len) return other;
    if (other == cur or list[cur].rect.distance(p) < margin) return null;
    return other;
}

/// The display to fall back to: the primary one, else the first.
pub fn primary(list: []const Display) ?usize {
    for (list, 0..) |d, i| {
        if (d.primary) return i;
    }
    return if (list.len > 0) 0 else null;
}

pub fn indexOf(list: []const Display, id: u32) ?usize {
    for (list, 0..) |d, i| {
        if (d.id == id) return i;
    }
    return null;
}

pub fn sameList(a: []const Display, b: []const Display) bool {
    if (a.len != b.len) return false;
    for (a, b) |*x, *y| {
        if (!x.same(y)) return false;
    }
    return true;
}

/// The list as JSON for viewers: [{"id","name","x","y","w","h","pw","ph","primary"}], where
/// x, y, w, h are desktop coordinates and pw, ph pixels. Truncated displays are left out.
pub fn writeJson(list: []const Display, out: []u8) []const u8 {
    var n: usize = 0;
    out[0] = '[';
    n = 1;
    for (list, 0..) |*d, i| {
        var esc: [max_name * 2]u8 = undefined;
        const item = std.fmt.bufPrint(out[n..], "{s}{{\"id\":{d},\"name\":\"{s}\",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"pw\":{d},\"ph\":{d},\"primary\":{}}}", .{
            if (i == 0) "" else ",",
            d.id,
            jsonEscape(&esc, d.name()),
            @as(i64, @intFromFloat(d.rect.x)),
            @as(i64, @intFromFloat(d.rect.y)),
            @as(i64, @intFromFloat(d.rect.w)),
            @as(i64, @intFromFloat(d.rect.h)),
            d.pw,
            d.ph,
            d.primary,
        }) catch break;
        if (n + item.len + 1 > out.len) break;
        n += item.len;
    }
    out[n] = ']';
    return out[0 .. n + 1];
}

fn jsonEscape(out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c < 0x20) continue;
        const need: usize = if (c == '"' or c == '\\') 2 else 1;
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

// ---------------------------------------------------------------------------
// Tests

fn disp(id: u32, x: f64, y: f64, w: f64, h: f64, is_primary: bool) Display {
    var d: Display = .{ .id = id, .rect = .{ .x = x, .y = y, .w = w, .h = h }, .pw = @intFromFloat(w), .ph = @intFromFloat(h), .primary = is_primary };
    d.setName("Display");
    return d;
}

// A laptop (1512×982 points) with a 1920×1080 display to its right, tops aligned.
const pair = [_]Display{ disp(1, 0, 0, 1512, 982, true), disp(2, 1512, 0, 1920, 1080, false) };

test "normalized → desktop is the old single-display mapping" {
    const r = pair[0].rect;
    try std.testing.expectEqual(Point{ .x = 0, .y = 0 }, toDesktop(r, 0, 0));
    try std.testing.expectEqual(Point{ .x = 1511, .y = 981 }, toDesktop(r, 1, 1));
    const n = toNormalized(r, toDesktop(r, 0.25, 0.75));
    try std.testing.expectApproxEqAbs(0.25, n.x, 1e-9);
    try std.testing.expectApproxEqAbs(0.75, n.y, 1e-9);
    // The second display has its own origin.
    try std.testing.expectEqual(Point{ .x = 1512, .y = 0 }, toDesktop(pair[1].rect, 0, 0));
}

test "past the right edge lands on the next display" {
    const p = toDesktop(pair[0].rect, 1.02, 0.5);
    try std.testing.expectEqual(@as(?usize, 1), at(&pair, p));
    try std.testing.expectEqual(p, clampToUnion(&pair, p));
    // Normalized to the second display, as its viewer would see it.
    const n = toNormalized(pair[1].rect, p);
    try std.testing.expect(n.x > 0 and n.x < 0.05);
}

test "clamped to the union of displays" {
    // Past the far right edge: stops at the second display's last column.
    const far = clampToUnion(&pair, toDesktop(pair[1].rect, 1.5, 0.5));
    try std.testing.expectEqual(@as(f64, 1512 + 1919), far.x);
    // Left of the laptop: its first column.
    try std.testing.expectEqual(@as(f64, 0), clampToUnion(&pair, .{ .x = -40, .y = 100 }).x);
    // Under the laptop but beside the taller display: onto the laptop's bottom row, the nearest.
    const gap = clampToUnion(&pair, .{ .x = 1400, .y = 1050 });
    try std.testing.expectEqual(Point{ .x = 1400, .y = 981 }, gap);
    // Single display: as before, clamped to it.
    const one = [_]Display{pair[0]};
    try std.testing.expectEqual(Point{ .x = 1511, .y = 0 }, clampToUnion(&one, .{ .x = 5000, .y = -3 }));
}

test "following: hysteresis at the edge" {
    // Resting on the border, a few points over: stays.
    try std.testing.expectEqual(@as(?usize, null), follow(&pair, 0, .{ .x = 1512 + 5, .y = 300 }, follow_margin));
    // Clearly inside the other display: switches.
    try std.testing.expectEqual(@as(?usize, 1), follow(&pair, 0, .{ .x = 1512 + 40, .y = 300 }, follow_margin));
    // Back: needs the same margin the other way.
    try std.testing.expectEqual(@as(?usize, null), follow(&pair, 1, .{ .x = 1505, .y = 300 }, follow_margin));
    try std.testing.expectEqual(@as(?usize, 0), follow(&pair, 1, .{ .x = 1400, .y = 300 }, follow_margin));
    // On the shown display: stays.
    try std.testing.expectEqual(@as(?usize, null), follow(&pair, 1, .{ .x = 2000, .y = 300 }, follow_margin));
    // Nothing shown (the display went away): whatever is under the pointer.
    try std.testing.expectEqual(@as(?usize, 1), follow(&pair, null, .{ .x = 2000, .y = 300 }, follow_margin));
    // Pointer nowhere (between displays of different heights): stays.
    try std.testing.expectEqual(@as(?usize, null), follow(&pair, 1, .{ .x = 1400, .y = 1050 }, follow_margin));
}

test "a display below another, negative coordinates" {
    const stack = [_]Display{ disp(7, 0, 0, 1920, 1080, true), disp(9, 200, -1440, 2560, 1440, false) };
    const up = toDesktop(stack[0].rect, 0.5, -0.1);
    try std.testing.expectEqual(@as(?usize, 1), at(&stack, up));
    try std.testing.expectEqual(@as(?usize, 1), follow(&stack, 0, up, follow_margin));
    try std.testing.expectEqual(@as(?usize, 0), primary(&stack));
    try std.testing.expectEqual(@as(?usize, 1), indexOf(&stack, 9));
}

test "lists and JSON" {
    var a = pair;
    var b = pair;
    try std.testing.expect(sameList(&a, &b));
    b[1].rect.x = 1600;
    try std.testing.expect(!sameList(&a, &b));
    a[0].setName("Built-in \"Retina\" Display");
    var buf: [512]u8 = undefined;
    const json = writeJson(a[0..2], &buf);
    try std.testing.expectEqualStrings(
        "[{\"id\":1,\"name\":\"Built-in \\\"Retina\\\" Display\",\"x\":0,\"y\":0,\"w\":1512,\"h\":982,\"pw\":1512,\"ph\":982,\"primary\":true}," ++
            "{\"id\":2,\"name\":\"Display\",\"x\":1512,\"y\":0,\"w\":1920,\"h\":1080,\"pw\":1920,\"ph\":1080,\"primary\":false}]",
        json,
    );
    var small: [40]u8 = undefined;
    try std.testing.expectEqualStrings("[]", writeJson(a[0..2], &small));
    // A name cut inside a character keeps the character whole.
    var d: Display = .{};
    d.setName("Монитор Монитор Монитор Монитор Монитор Монитор");
    try std.testing.expect(std.unicode.utf8ValidateSlice(d.name()));
}
