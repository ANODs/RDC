//! Клавиши: по сети идут коды USB HID (страница 0x07), одинаковые на всех ОС.
//! Здесь — перевод HID → виртуальный код клавиши macOS (kVK_*).
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
    // Цифровой блок 1..9: HID 0x59..0x61
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
        .{ 0x32, 0x2A }, // # (не-US)
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

/// Код macOS для HID-кода или null, если у Mac такой клавиши нет.
pub fn macKeycode(usage: u16) ?u8 {
    if (usage > 0xFF) return null;
    const k = hid_to_mac[usage];
    return if (k == none) null else k;
}

test "keymap: буквы, цифры, модификаторы" {
    try std.testing.expectEqual(@as(?u8, 0x00), macKeycode(0x04)); // A
    try std.testing.expectEqual(@as(?u8, 0x06), macKeycode(0x1D)); // Z
    try std.testing.expectEqual(@as(?u8, 0x12), macKeycode(0x1E)); // 1
    try std.testing.expectEqual(@as(?u8, 0x1D), macKeycode(0x27)); // 0
    try std.testing.expectEqual(@as(?u8, 0x7A), macKeycode(0x3A)); // F1
    try std.testing.expectEqual(@as(?u8, 0x37), macKeycode(0xE3)); // Command
    try std.testing.expectEqual(@as(?u8, 0x7E), macKeycode(0x52)); // ↑
    try std.testing.expectEqual(@as(?u8, null), macKeycode(0x65)); // Menu — на Mac нет
    try std.testing.expectEqual(@as(?u8, null), macKeycode(0x1234));
}
