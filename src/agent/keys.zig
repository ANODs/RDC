//! Keys for AI agents: names and combinations like "enter", "f5", "ctrl+shift+t", "cmd+space"
//! become USB HID usages (page 0x07), the codes RDC sends over the network.
//! Also a US-layout table for typing ASCII on hosts that predate text input.
const std = @import("std");

pub const usage_ctrl: u16 = 0xE0;
pub const usage_shift: u16 = 0xE1;
pub const usage_alt: u16 = 0xE2;
pub const usage_meta: u16 = 0xE3;
pub const usage_enter: u16 = 0x28;
pub const usage_tab: u16 = 0x2B;

pub const max_mods = 4;

/// One press: modifiers held while `key` goes down and up.
pub const Combo = struct {
    mods: [max_mods]u16 = @splat(0),
    mod_count: usize = 0,
    key: u16,

    pub fn modifiers(c: *const Combo) []const u16 {
        return c.mods[0..c.mod_count];
    }
};

pub const ParseError = error{ UnknownKey, TooManyModifiers, EmptyKey };

const Named = struct { []const u8, u16 };

const named_keys = [_]Named{
    .{ "enter", 0x28 },         .{ "return", 0x28 },       .{ "esc", 0x29 },         .{ "escape", 0x29 },
    .{ "backspace", 0x2A },     .{ "tab", 0x2B },          .{ "space", 0x2C },       .{ "spacebar", 0x2C },
    .{ "minus", 0x2D },         .{ "equal", 0x2E },        .{ "equals", 0x2E },      .{ "plus", 0x2E },
    .{ "bracketleft", 0x2F },   .{ "bracketright", 0x30 }, .{ "backslash", 0x31 },   .{ "semicolon", 0x33 },
    .{ "quote", 0x34 },         .{ "apostrophe", 0x34 },   .{ "backquote", 0x35 },   .{ "grave", 0x35 },
    .{ "comma", 0x36 },         .{ "period", 0x37 },       .{ "dot", 0x37 },         .{ "slash", 0x38 },
    .{ "capslock", 0x39 },      .{ "printscreen", 0x46 },  .{ "print", 0x46 },       .{ "scrolllock", 0x47 },
    .{ "pause", 0x48 },         .{ "insert", 0x49 },       .{ "ins", 0x49 },         .{ "home", 0x4A },
    .{ "pageup", 0x4B },        .{ "pgup", 0x4B },         .{ "delete", 0x4C },      .{ "del", 0x4C },
    .{ "forwarddelete", 0x4C }, .{ "end", 0x4D },          .{ "pagedown", 0x4E },    .{ "pgdn", 0x4E },
    .{ "right", 0x4F },         .{ "arrowright", 0x4F },   .{ "left", 0x50 },        .{ "arrowleft", 0x50 },
    .{ "down", 0x51 },          .{ "arrowdown", 0x51 },    .{ "up", 0x52 },          .{ "arrowup", 0x52 },
    .{ "numlock", 0x53 },       .{ "menu", 0x65 },         .{ "contextmenu", 0x65 }, .{ "apps", 0x65 },
    .{ "ctrl", 0xE0 },          .{ "control", 0xE0 },      .{ "shift", 0xE1 },       .{ "alt", 0xE2 },
    .{ "option", 0xE2 },        .{ "opt", 0xE2 },          .{ "cmd", 0xE3 },         .{ "command", 0xE3 },
    .{ "meta", 0xE3 },          .{ "win", 0xE3 },          .{ "windows", 0xE3 },     .{ "super", 0xE3 },
    .{ "rctrl", 0xE4 },         .{ "rshift", 0xE5 },       .{ "ralt", 0xE6 },        .{ "altgr", 0xE6 },
    .{ "rcmd", 0xE7 },
};

fn isModifier(usage: u16) bool {
    return usage >= 0xE0 and usage <= 0xE7;
}

/// HID usage for a key name ("enter", "f5", "a", "7", "/"), case-insensitive.
pub fn keyUsage(name: []const u8) ?u16 {
    if (name.len == 1) {
        if (usChar(name[0])) |s| return s.usage;
        return null;
    }
    var lower_buf: [24]u8 = undefined;
    if (name.len > lower_buf.len) return null;
    const lower = std.ascii.lowerString(&lower_buf, name);
    for (named_keys) |k| {
        if (std.mem.eql(u8, k[0], lower)) return k[1];
    }
    // F1..F24
    if (lower[0] == 'f' and lower.len <= 3) {
        const n = std.fmt.parseInt(u8, lower[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return 0x3A + @as(u16, n) - 1;
        if (n >= 13 and n <= 24) return 0x68 + @as(u16, n) - 13;
    }
    return null;
}

/// "ctrl+shift+t" → modifiers ctrl, shift and the key t. A lone modifier ("shift") is a key itself.
pub fn parseCombo(text: []const u8) ParseError!Combo {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len == 0) return error.EmptyKey;
    // The last part is the key. "ctrl++" and "cmd+=" name the key itself.
    var key_start: usize = 0;
    if (s.len >= 2 and s[s.len - 1] == '+' and s[s.len - 2] == '+') {
        key_start = s.len - 1;
    } else if (std.mem.findScalarLast(u8, s, '+')) |i| {
        key_start = if (i + 1 == s.len) i else i + 1;
    }
    const key_name = s[key_start..];
    var combo: Combo = .{ .key = keyUsage(key_name) orelse return error.UnknownKey };
    if (key_start == 0) return combo;
    const mod_part = s[0 .. key_start - 1];
    var it = std.mem.splitScalar(u8, mod_part, '+');
    while (it.next()) |raw| {
        const m = std.mem.trim(u8, raw, " \t");
        if (m.len == 0) return error.EmptyKey;
        const usage = keyUsage(m) orelse return error.UnknownKey;
        if (!isModifier(usage)) return error.UnknownKey;
        if (combo.mod_count == max_mods) return error.TooManyModifiers;
        combo.mods[combo.mod_count] = usage;
        combo.mod_count += 1;
    }
    return combo;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Splits "ctrl+a delete", "down, down, enter" or "ctrl + c" into single combos.
pub const Sequence = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,

    /// Copies the text with the spaces around "+" removed. Longer text is cut at 256 bytes.
    pub fn init(text: []const u8) Sequence {
        var s: Sequence = .{};
        for (text) |c| {
            if (s.len == s.buf.len) break;
            if (c == '+') {
                while (s.len > 0 and isSpace(s.buf[s.len - 1])) s.len -= 1;
            } else if (isSpace(c) and s.len > 0 and s.buf[s.len - 1] == '+') {
                // A space after a joining "+" goes; after the "+" key itself ("ctrl++ enter") it separates.
                if (!(s.len >= 2 and s.buf[s.len - 2] == '+')) continue;
            }
            s.buf[s.len] = c;
            s.len += 1;
        }
        return s;
    }

    /// The next combo, or null at the end.
    pub fn next(s: *Sequence) ?[]const u8 {
        while (s.pos < s.len and (isSpace(s.buf[s.pos]) or s.buf[s.pos] == ',')) s.pos += 1;
        if (s.pos == s.len) return null;
        const start = s.pos;
        while (s.pos < s.len) : (s.pos += 1) {
            const c = s.buf[s.pos];
            if (isSpace(c)) break;
            // "ctrl+," names the comma key; any other comma separates.
            if (c == ',' and s.pos > start and s.buf[s.pos - 1] != '+') break;
        }
        return s.buf[start..s.pos];
    }
};

pub const Stroke = struct { usage: u16, shift: bool = false };

/// A character on a US keyboard: which key and whether Shift is held. ASCII only.
pub fn usChar(c: u8) ?Stroke {
    switch (c) {
        'a'...'z' => return .{ .usage = 0x04 + @as(u16, c - 'a') },
        'A'...'Z' => return .{ .usage = 0x04 + @as(u16, c - 'A'), .shift = true },
        '1'...'9' => return .{ .usage = 0x1E + @as(u16, c - '1') },
        '0' => return .{ .usage = 0x27 },
        '\n' => return .{ .usage = 0x28 },
        '\t' => return .{ .usage = 0x2B },
        ' ' => return .{ .usage = 0x2C },
        else => {},
    }
    const table = [_]struct { u8, u16, bool }{
        .{ '-', 0x2D, false },  .{ '_', 0x2D, true }, .{ '=', 0x2E, false }, .{ '+', 0x2E, true },
        .{ '[', 0x2F, false },  .{ '{', 0x2F, true }, .{ ']', 0x30, false }, .{ '}', 0x30, true },
        .{ '\\', 0x31, false }, .{ '|', 0x31, true }, .{ ';', 0x33, false }, .{ ':', 0x33, true },
        .{ '\'', 0x34, false }, .{ '"', 0x34, true }, .{ '`', 0x35, false }, .{ '~', 0x35, true },
        .{ ',', 0x36, false },  .{ '<', 0x36, true }, .{ '.', 0x37, false }, .{ '>', 0x37, true },
        .{ '/', 0x38, false },  .{ '?', 0x38, true }, .{ '!', 0x1E, true },  .{ '@', 0x1F, true },
        .{ '#', 0x20, true },   .{ '$', 0x21, true }, .{ '%', 0x22, true },  .{ '^', 0x23, true },
        .{ '&', 0x24, true },   .{ '*', 0x25, true }, .{ '(', 0x26, true },  .{ ')', 0x27, true },
    };
    for (table) |t| {
        if (t[0] == c) return .{ .usage = t[1], .shift = t[2] };
    }
    return null;
}

test "keys: names" {
    try std.testing.expectEqual(@as(?u16, 0x28), keyUsage("Enter"));
    try std.testing.expectEqual(@as(?u16, 0x04), keyUsage("a"));
    try std.testing.expectEqual(@as(?u16, 0x04), keyUsage("A"));
    try std.testing.expectEqual(@as(?u16, 0x27), keyUsage("0"));
    try std.testing.expectEqual(@as(?u16, 0x3A), keyUsage("f1"));
    try std.testing.expectEqual(@as(?u16, 0x45), keyUsage("F12"));
    try std.testing.expectEqual(@as(?u16, 0x68), keyUsage("f13"));
    try std.testing.expectEqual(@as(?u16, 0x73), keyUsage("f24"));
    try std.testing.expectEqual(@as(?u16, null), keyUsage("f25"));
    try std.testing.expectEqual(@as(?u16, 0x38), keyUsage("/"));
    try std.testing.expectEqual(@as(?u16, null), keyUsage("nope"));
}

test "keys: combos" {
    const c = try parseCombo("ctrl+shift+t");
    try std.testing.expectEqualSlices(u16, &.{ usage_ctrl, usage_shift }, c.modifiers());
    try std.testing.expectEqual(@as(u16, 0x17), c.key);
    const w = try parseCombo("Cmd+Space");
    try std.testing.expectEqualSlices(u16, &.{usage_meta}, w.modifiers());
    try std.testing.expectEqual(@as(u16, 0x2C), w.key);
    const plus = try parseCombo("ctrl++");
    try std.testing.expectEqualSlices(u16, &.{usage_ctrl}, plus.modifiers());
    try std.testing.expectEqual(@as(u16, 0x2E), plus.key);
    const lone = try parseCombo("shift");
    try std.testing.expectEqual(@as(usize, 0), lone.mod_count);
    try std.testing.expectEqual(usage_shift, lone.key);
    try std.testing.expectError(error.UnknownKey, parseCombo("hyper+x"));
    try std.testing.expectError(error.UnknownKey, parseCombo("a+b"));
    try std.testing.expectError(error.EmptyKey, parseCombo(" "));
}

test "keys: sequences" {
    var seq = Sequence.init("ctrl+a delete, down  enter");
    try std.testing.expectEqualStrings("ctrl+a", seq.next().?);
    try std.testing.expectEqualStrings("delete", seq.next().?);
    try std.testing.expectEqualStrings("down", seq.next().?);
    try std.testing.expectEqualStrings("enter", seq.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), seq.next());
    var spaced = Sequence.init("ctrl + shift + esc");
    try std.testing.expectEqualStrings("ctrl+shift+esc", spaced.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), spaced.next());
    var plus = Sequence.init("ctrl++ enter ctrl+,");
    try std.testing.expectEqualStrings("ctrl++", plus.next().?);
    try std.testing.expectEqualStrings("enter", plus.next().?);
    try std.testing.expectEqualStrings("ctrl+,", plus.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), plus.next());
}

test "keys: US layout" {
    try std.testing.expectEqual(Stroke{ .usage = 0x04, .shift = true }, usChar('A').?);
    try std.testing.expectEqual(Stroke{ .usage = 0x1F, .shift = true }, usChar('@').?);
    try std.testing.expectEqual(Stroke{ .usage = 0x38 }, usChar('/').?);
    try std.testing.expectEqual(@as(?Stroke, null), usChar(0x7F));
}
