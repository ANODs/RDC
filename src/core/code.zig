//! Connection code: 9 digits — 8 random ones and a Damm check digit.
//! The check digit catches any single-digit error and any swap of adjacent digits.
const std = @import("std");

pub const len = 9;

const damm = [10][10]u8{
    .{ 0, 3, 1, 7, 5, 9, 8, 6, 4, 2 },
    .{ 7, 0, 9, 2, 1, 5, 4, 8, 6, 3 },
    .{ 4, 2, 0, 6, 8, 7, 1, 3, 5, 9 },
    .{ 1, 7, 5, 0, 9, 8, 3, 4, 2, 6 },
    .{ 6, 1, 2, 3, 0, 4, 5, 9, 7, 8 },
    .{ 3, 6, 7, 4, 2, 0, 9, 5, 8, 1 },
    .{ 5, 8, 6, 9, 7, 2, 0, 1, 3, 4 },
    .{ 8, 9, 4, 5, 3, 6, 2, 0, 1, 7 },
    .{ 9, 4, 3, 8, 6, 1, 7, 2, 0, 5 },
    .{ 2, 5, 8, 1, 4, 3, 6, 7, 9, 0 },
};

/// Damm interim digit for ASCII digits. 0 means a string with its check digit is valid.
pub fn dammDigit(digits: []const u8) u8 {
    var interim: u8 = 0;
    for (digits) |d| interim = damm[interim][d - '0'];
    return interim;
}

pub const Code = struct {
    digits: [len]u8,

    /// Code from a random number: its low 8 decimal digits + the check digit.
    pub fn fromRandom(r: u64) Code {
        var c: Code = undefined;
        var v = r % 100_000_000;
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            c.digits[i] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
        }
        c.digits[8] = '0' + dammDigit(c.digits[0..8]);
        return c;
    }

    /// "123 456 789".
    pub fn display(self: *const Code, buf: *[11]u8) []const u8 {
        @memcpy(buf[0..3], self.digits[0..3]);
        buf[3] = ' ';
        @memcpy(buf[4..7], self.digits[3..6]);
        buf[7] = ' ';
        @memcpy(buf[8..11], self.digits[6..9]);
        return buf;
    }

    /// Constant-time comparison with an entered code; spaces and other non-digits are ignored.
    pub fn matches(self: *const Code, input: []const u8) bool {
        var got: [len]u8 = undefined;
        var n: usize = 0;
        for (input) |ch| {
            if (ch < '0' or ch > '9') continue;
            if (n == len) return false;
            got[n] = ch;
            n += 1;
        }
        if (n != len) return false;
        var acc: u8 = 0;
        for (got, self.digits) |a, b| acc |= a ^ b;
        return acc == 0;
    }
};

test "damm: example from the algorithm description" {
    try std.testing.expectEqual(@as(u8, 4), dammDigit("572"));
    try std.testing.expectEqual(@as(u8, 0), dammDigit("5724"));
}

test "code: check digit and format" {
    const c = Code.fromRandom(12_345_678);
    try std.testing.expectEqualStrings("12345678", c.digits[0..8]);
    try std.testing.expectEqual(@as(u8, 0), dammDigit(&c.digits));
    var buf: [11]u8 = undefined;
    const shown = c.display(&buf);
    try std.testing.expectEqual(@as(usize, 11), shown.len);
    try std.testing.expect(c.matches(shown));
    try std.testing.expect(c.matches(&c.digits));
}

test "code: typos are rejected" {
    const c = Code.fromRandom(98_765_432);
    var wrong = c.digits;
    wrong[3] = if (wrong[3] == '9') '0' else wrong[3] + 1;
    try std.testing.expect(!c.matches(&wrong));
    try std.testing.expect(dammDigit(&wrong) != 0);
    var swapped = c.digits;
    if (swapped[1] != swapped[2]) {
        std.mem.swap(u8, &swapped[1], &swapped[2]);
        try std.testing.expect(dammDigit(&swapped) != 0);
    }
    try std.testing.expect(!c.matches(c.digits[0..8]));
    try std.testing.expect(!c.matches("1234567890"));
}
