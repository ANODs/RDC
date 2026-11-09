//! Keys: the network carries USB HID usage codes (page 0x07), the same on every OS.
//! Here: HID → macOS virtual key codes (kVK_*).
const std = @import("std");

pub const none: u8 = 0xFF;

pub const hid_to_mac: [256]u8 = blk: {
    var t: [256]u8 = @splat(none);
    // A..Z: HID 0x04..0x1D
    const letters = [26]u8{
        0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
        0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06,
    };
    for (letters, 0..) |k, i| t[0x04 + i] = k;
    // 1..9, 0: HID 0x1E..0x27
    const digits = [10]u8{ 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D };
    for (digits, 0..) |k, i| t[0x1E + i] = k;
    // F1..F12: HID 0x3A..0x45
    const fkeys = [12]u8{ 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F };
    for (fkeys, 0..) |k, i| t[0x3A + i] = k;
    // F13..F20: HID 0x68..0x6F
    const fkeys2 = [8]u8{ 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A };
    for (fkeys2, 0..) |k, i| t[0x68 + i] = k;
    // Keypad 1..9: HID 0x59..0x61
    const pad = [9]u8{ 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C };
    for (pad, 0..) |k, i| t[0x59 + i] = k;

    const pairs = [_][2]u8{
        .{ 0x28, 0x24 }, // Enter → Return
        .{ 0x29, 0x35 }, // Escape
        .{ 0x2A, 0x33 }, // Backspace → Delete
        .{ 0x2B, 0x30 }, // Tab
        .{ 0x2C, 0x31 }, // Space
        .{ 0x2D, 0x1B }, // -
        .{ 0x2E, 0x18 }, // =
        .{ 0x2F, 0x21 }, // [
        .{ 0x30, 0x1E }, // ]
        .{ 0x31, 0x2A }, // \
        .{ 0x32, 0x2A }, // # (non-US)
        .{ 0x33, 0x29 }, // ;
        .{ 0x34, 0x27 }, // '
        .{ 0x35, 0x32 }, // `
        .{ 0x36, 0x2B }, // ,
        .{ 0x37, 0x2F }, // .
        .{ 0x38, 0x2C }, // /
        .{ 0x39, 0x39 }, // Caps Lock
        .{ 0x46, 0x69 }, // Print Screen → F13
        .{ 0x47, 0x6B }, // Scroll Lock → F14
        .{ 0x48, 0x71 }, // Pause → F15
        .{ 0x49, 0x72 }, // Insert → Help
        .{ 0x4A, 0x73 }, // Home
        .{ 0x4B, 0x74 }, // Page Up
        .{ 0x4C, 0x75 }, // Delete → Forward Delete
        .{ 0x4D, 0x77 }, // End
        .{ 0x4E, 0x79 }, // Page Down
        .{ 0x4F, 0x7C }, // →
        .{ 0x50, 0x7B }, // ←
        .{ 0x51, 0x7D }, // ↓
        .{ 0x52, 0x7E }, // ↑
        .{ 0x53, 0x47 }, // Num Lock → Clear
        .{ 0x54, 0x4B }, // KP /
        .{ 0x55, 0x43 }, // KP *
        .{ 0x56, 0x4E }, // KP -
        .{ 0x57, 0x45 }, // KP +
        .{ 0x58, 0x4C }, // KP Enter
        .{ 0x62, 0x52 }, // KP 0
        .{ 0x63, 0x41 }, // KP .
        .{ 0x64, 0x0A }, // ISO § (IntlBackslash)
        .{ 0x67, 0x51 }, // KP =
        .{ 0x87, 0x5E }, // JIS _ (IntlRo)
        .{ 0x89, 0x5D }, // JIS ¥
        .{ 0x90, 0x68 }, // Kana
        .{ 0x91, 0x66 }, // Eisu
        .{ 0xE0, 0x3B }, // Left Control
        .{ 0xE1, 0x38 }, // Left Shift
        .{ 0xE2, 0x3A }, // Left Option
        .{ 0xE3, 0x37 }, // Left Command
        .{ 0xE4, 0x3E }, // Right Control
        .{ 0xE5, 0x3C }, // Right Shift
        .{ 0xE6, 0x3D }, // Right Option
        .{ 0xE7, 0x36 }, // Right Command
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

/// macOS key code for a HID code, or null if the Mac has no such key.
pub fn macKeycode(usage: u16) ?u8 {
    if (usage > 0xFF) return null;
    const k = hid_to_mac[usage];
    return if (k == none) null else k;
}

/// HID → Windows scan code (set 1). 0xE0xx is an extended key (KEYEVENTF_EXTENDEDKEY).
pub const hid_to_win: [256]u16 = blk: {
    var t: [256]u16 = @splat(0);
    // A..Z: HID 0x04..0x1D
    const letters = [26]u16{
        0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
        0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C,
    };
    for (letters, 0..) |k, i| t[0x04 + i] = k;
    // 1..9, 0: HID 0x1E..0x27 → 0x02..0x0B
    for (0..10) |i| t[0x1E + i] = 0x02 + i;
    // F1..F10: HID 0x3A..0x43 → 0x3B..0x44
    for (0..10) |i| t[0x3A + i] = 0x3B + i;
    // F13..F23: HID 0x68..0x72 → 0x64..0x6E, F24 — 0x76
    for (0..11) |i| t[0x68 + i] = 0x64 + i;
    t[0x73] = 0x76;
    const pairs = [_][2]u16{
        .{ 0x28, 0x1C }, // Enter
        .{ 0x29, 0x01 }, // Escape
        .{ 0x2A, 0x0E }, // Backspace
        .{ 0x2B, 0x0F }, // Tab
        .{ 0x2C, 0x39 }, // Space
        .{ 0x2D, 0x0C }, // -
        .{ 0x2E, 0x0D }, // =
        .{ 0x2F, 0x1A }, // [
        .{ 0x30, 0x1B }, // ]
        .{ 0x31, 0x2B }, // \
        .{ 0x32, 0x2B }, // # (non-US)
        .{ 0x33, 0x27 }, // ;
        .{ 0x34, 0x28 }, // '
        .{ 0x35, 0x29 }, // `
        .{ 0x36, 0x33 }, // ,
        .{ 0x37, 0x34 }, // .
        .{ 0x38, 0x35 }, // /
        .{ 0x39, 0x3A }, // Caps Lock
        .{ 0x44, 0x57 }, // F11
        .{ 0x45, 0x58 }, // F12
        .{ 0x46, 0xE037 }, // Print Screen
        .{ 0x47, 0x46 }, // Scroll Lock
        .{ 0x49, 0xE052 }, // Insert
        .{ 0x4A, 0xE047 }, // Home
        .{ 0x4B, 0xE049 }, // Page Up
        .{ 0x4C, 0xE053 }, // Delete
        .{ 0x4D, 0xE04F }, // End
        .{ 0x4E, 0xE051 }, // Page Down
        .{ 0x4F, 0xE04D }, // →
        .{ 0x50, 0xE04B }, // ←
        .{ 0x51, 0xE050 }, // ↓
        .{ 0x52, 0xE048 }, // ↑
        .{ 0x53, 0x45 }, // Num Lock
        .{ 0x54, 0xE035 }, // KP /
        .{ 0x55, 0x37 }, // KP *
        .{ 0x56, 0x4A }, // KP -
        .{ 0x57, 0x4E }, // KP +
        .{ 0x58, 0xE01C }, // KP Enter
        .{ 0x59, 0x4F }, // KP 1
        .{ 0x5A, 0x50 }, // KP 2
        .{ 0x5B, 0x51 }, // KP 3
        .{ 0x5C, 0x4B }, // KP 4
        .{ 0x5D, 0x4C }, // KP 5
        .{ 0x5E, 0x4D }, // KP 6
        .{ 0x5F, 0x47 }, // KP 7
        .{ 0x60, 0x48 }, // KP 8
        .{ 0x61, 0x49 }, // KP 9
        .{ 0x62, 0x52 }, // KP 0
        .{ 0x63, 0x53 }, // KP .
        .{ 0x64, 0x56 }, // ISO \ (IntlBackslash)
        .{ 0x65, 0xE05D }, // Menu
        .{ 0x67, 0x59 }, // KP =
        .{ 0x87, 0x73 }, // IntlRo
        .{ 0x89, 0x7D }, // IntlYen
        .{ 0xE0, 0x1D }, // Left Ctrl
        .{ 0xE1, 0x2A }, // Left Shift
        .{ 0xE2, 0x38 }, // Left Alt
        .{ 0xE3, 0xE05B }, // Left Win
        .{ 0xE4, 0xE01D }, // Right Ctrl
        .{ 0xE5, 0x36 }, // Right Shift
        .{ 0xE6, 0xE038 }, // Right Alt
        .{ 0xE7, 0xE05C }, // Right Win
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

/// Windows scan code for a HID code, or null.
pub fn winScancode(usage: u16) ?u16 {
    if (usage > 0xFF) return null;
    const k = hid_to_win[usage];
    return if (k == 0) null else k;
}

test "keymap: Windows scan codes" {
    try std.testing.expectEqual(@as(?u16, 0x1E), winScancode(0x04)); // A
    try std.testing.expectEqual(@as(?u16, 0x2C), winScancode(0x1D)); // Z
    try std.testing.expectEqual(@as(?u16, 0x02), winScancode(0x1E)); // 1
    try std.testing.expectEqual(@as(?u16, 0x0B), winScancode(0x27)); // 0
    try std.testing.expectEqual(@as(?u16, 0x3B), winScancode(0x3A)); // F1
    try std.testing.expectEqual(@as(?u16, 0x58), winScancode(0x45)); // F12
    try std.testing.expectEqual(@as(?u16, 0xE048), winScancode(0x52)); // ↑ — extended
    try std.testing.expectEqual(@as(?u16, 0xE05B), winScancode(0xE3)); // Win
    try std.testing.expectEqual(@as(?u16, 0x1D), winScancode(0xE0)); // Ctrl
    try std.testing.expectEqual(@as(?u16, null), winScancode(0x48)); // Pause — special
}

test "keymap: letters, digits, modifiers" {
    try std.testing.expectEqual(@as(?u8, 0x00), macKeycode(0x04)); // A
    try std.testing.expectEqual(@as(?u8, 0x06), macKeycode(0x1D)); // Z
    try std.testing.expectEqual(@as(?u8, 0x12), macKeycode(0x1E)); // 1
    try std.testing.expectEqual(@as(?u8, 0x1D), macKeycode(0x27)); // 0
    try std.testing.expectEqual(@as(?u8, 0x7A), macKeycode(0x3A)); // F1
    try std.testing.expectEqual(@as(?u8, 0x37), macKeycode(0xE3)); // Command
    try std.testing.expectEqual(@as(?u8, 0x7E), macKeycode(0x52)); // ↑
    try std.testing.expectEqual(@as(?u8, null), macKeycode(0x65)); // Menu — none on Mac
    try std.testing.expectEqual(@as(?u8, null), macKeycode(0x1234));
}
