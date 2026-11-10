//! QR Code (ISO/IEC 18004) encoder: byte mode, error correction level M, versions 1–15.
//! Pure computation on fixed buffers: no allocator, no I/O.
const std = @import("std");

pub const max_version = 15;
pub const max_size = 17 + 4 * max_version; // 77 modules per side

/// Codewords (data + error correction) in a version 15 symbol.
const max_codewords = 655;
/// Data codewords in a version 15-M symbol.
const max_data_codewords = 415;
const max_blocks = 10;
const max_ec_per_block = 30;

/// Error correction codewords per block at level M, by version.
const ec_per_block = [max_version]u8{ 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24 };
/// Error correction blocks at level M, by version.
const block_count = [max_version]u8{ 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10 };
/// Centre coordinates of the alignment patterns, by version; 0 — unused.
const alignment_centres = [max_version][4]u8{
    .{ 0, 0, 0, 0 },
    .{ 6, 18, 0, 0 },
    .{ 6, 22, 0, 0 },
    .{ 6, 26, 0, 0 },
    .{ 6, 30, 0, 0 },
    .{ 6, 34, 0, 0 },
    .{ 6, 22, 38, 0 },
    .{ 6, 24, 42, 0 },
    .{ 6, 26, 46, 0 },
    .{ 6, 28, 50, 0 },
    .{ 6, 30, 54, 0 },
    .{ 6, 32, 58, 0 },
    .{ 6, 34, 62, 0 },
    .{ 6, 26, 46, 66 },
    .{ 6, 26, 48, 70 },
};

pub const Code = struct {
    /// Modules per side: 17 + 4 × version.
    size: u8,
    /// Row-major, size × size used; 1 — dark.
    modules: [max_size * max_size]u8,

    pub fn dark(c: *const Code, x: usize, y: usize) bool {
        return c.modules[y * c.size + x] != 0;
    }
};

/// The smallest version that holds `data` in byte mode at level M, with the best mask by the
/// standard's penalty rules. error.TooLong — more than version 15 holds (412 bytes).
pub fn encode(data: []const u8) error{TooLong}!Code {
    const version = try versionFor(data.len);
    var buf: [max_codewords]u8 = undefined;
    const codewords = buildCodewords(data, version, &buf);

    var p: Painter = .{
        .code = .{ .size = @intCast(17 + 4 * version), .modules = @splat(0) },
        .function = @splat(false),
    };
    p.drawFunctionPatterns(version);
    p.drawCodewords(codewords);

    var best_mask: u3 = 0;
    var best_penalty: u32 = std.math.maxInt(u32);
    for (0..8) |m| {
        const mask: u3 = @intCast(m);
        p.applyMask(mask);
        p.drawFormat(mask);
        const score = penalty(&p.code);
        if (score < best_penalty) {
            best_penalty = score;
            best_mask = mask;
        }
        p.applyMask(mask); // XOR again: back to the unmasked symbol
    }
    p.applyMask(best_mask);
    p.drawFormat(best_mask);
    return p.code;
}

/// Bytes of byte-mode payload a version holds at level M.
fn capacity(version: usize) usize {
    // Mode indicator (4 bits) + character count (8 or 16 bits), rounded up to whole bytes.
    const header: usize = if (version < 10) 2 else 3;
    return dataCodewords(version) - header;
}

fn versionFor(len: usize) error{TooLong}!usize {
    for (1..max_version + 1) |version| {
        if (len <= capacity(version)) return version;
    }
    return error.TooLong;
}

/// Modules left for data, error correction and remainder bits after all function patterns.
fn rawModules(version: usize) usize {
    var n = (16 * version + 128) * version + 64;
    if (version >= 2) {
        const side = version / 7 + 2; // alignment pattern centres per axis
        n -= (25 * side - 10) * side - 55;
    }
    if (version >= 7) n -= 36; // two version information blocks
    return n;
}

fn totalCodewords(version: usize) usize {
    return rawModules(version) / 8;
}

fn dataCodewords(version: usize) usize {
    return totalCodewords(version) - @as(usize, ec_per_block[version - 1]) * block_count[version - 1];
}

/// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1 (0x11d).
fn gfMul(a: u8, b: u8) u8 {
    var z: u16 = 0;
    var i: u4 = 8;
    while (i > 0) {
        i -= 1;
        z = (z << 1) ^ ((z >> 7) * 0x11d);
        z ^= ((b >> @intCast(i)) & 1) * @as(u16, a);
    }
    return @intCast(z);
}

/// Reed–Solomon generator polynomial (x − α^0)(x − α^1)…(x − α^(n−1)), n = out.len:
/// coefficients from the highest power down, without the leading 1.
fn rsGenerator(out: []u8) void {
    @memset(out, 0);
    out[out.len - 1] = 1;
    var root: u8 = 1;
    for (0..out.len) |_| {
        for (0..out.len) |j| {
            out[j] = gfMul(out[j], root);
            if (j + 1 < out.len) out[j] ^= out[j + 1];
        }
        root = gfMul(root, 2);
    }
}

/// Error correction codewords: the remainder of data · x^n divided by the generator, n = out.len.
fn rsRemainder(data: []const u8, generator: []const u8, out: []u8) void {
    @memset(out, 0);
    for (data) |byte| {
        const factor = byte ^ out[0];
        std.mem.copyForwards(u8, out[0 .. out.len - 1], out[1..]);
        out[out.len - 1] = 0;
        for (out, generator) |*o, g| o.* ^= gfMul(g, factor);
    }
}

/// Appends the low `count` bits of `value`, most significant first, to a zeroed buffer.
fn putBits(buf: []u8, bit_len: *usize, value: u32, count: u5) void {
    var i: u5 = count;
    while (i > 0) {
        i -= 1;
        if ((value >> i) & 1 != 0) buf[bit_len.* / 8] |= @as(u8, 0x80) >> @intCast(bit_len.* % 8);
        bit_len.* += 1;
    }
}

/// Data codewords of a byte-mode segment: mode, count, payload, terminator, padding.
/// `out.len` is the number of data codewords of the version.
fn buildData(data: []const u8, version: usize, out: []u8) void {
    @memset(out, 0);
    var bits: usize = 0;
    putBits(out, &bits, 0b0100, 4); // byte mode
    putBits(out, &bits, @intCast(data.len), if (version < 10) 8 else 16);
    for (data) |byte| putBits(out, &bits, byte, 8);
    bits = @min(bits + 4, out.len * 8); // terminator, already zero
    var used = (bits + 7) / 8; // zero bits up to the byte boundary
    var pad: u8 = 0xec;
    while (used < out.len) : (used += 1) {
        out[used] = pad;
        pad ^= 0xec ^ 0x11;
    }
}

/// The final codeword sequence of the symbol: data split into blocks, Reed–Solomon codewords
/// for each block, both interleaved.
fn buildCodewords(data: []const u8, version: usize, out: *[max_codewords]u8) []u8 {
    const total = totalCodewords(version);
    const blocks: usize = block_count[version - 1];
    const ec_len: usize = ec_per_block[version - 1];
    const short_blocks = blocks - total % blocks;
    const short_len = total / blocks - ec_len; // data codewords in a short block

    var data_buf: [max_data_codewords]u8 = undefined;
    const data_cw = data_buf[0..dataCodewords(version)];
    buildData(data, version, data_cw);

    var gen_buf: [max_ec_per_block]u8 = undefined;
    const generator = gen_buf[0..ec_len];
    rsGenerator(generator);

    var starts: [max_blocks]usize = undefined;
    var lens: [max_blocks]usize = undefined;
    var ec: [max_blocks][max_ec_per_block]u8 = undefined;
    var offset: usize = 0;
    for (0..blocks) |b| {
        starts[b] = offset;
        lens[b] = short_len + @intFromBool(b >= short_blocks);
        offset += lens[b];
        rsRemainder(data_cw[starts[b]..offset], generator, ec[b][0..ec_len]);
    }
    std.debug.assert(offset == data_cw.len);

    var n: usize = 0;
    for (0..short_len + 1) |i| {
        for (0..blocks) |b| {
            if (i < lens[b]) {
                out[n] = data_cw[starts[b] + i];
                n += 1;
            }
        }
    }
    for (0..ec_len) |i| {
        for (0..blocks) |b| {
            out[n] = ec[b][i];
            n += 1;
        }
    }
    std.debug.assert(n == total);
    return out[0..n];
}

/// The 15 format bits for level M and a mask: BCH(15,5), XOR 0x5412.
fn formatBits(mask: u3) u15 {
    const info: u32 = (0b00 << 3) | @as(u32, mask); // level M is 00
    var rem = info;
    for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return @intCast(((info << 10) | rem) ^ 0x5412);
}

/// The 18 version information bits: BCH(18,6).
fn versionBits(version: usize) u18 {
    var rem: u32 = @intCast(version);
    for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1f25);
    return @intCast((@as(u32, @intCast(version)) << 12) | rem);
}

/// Whether mask pattern `mask` inverts the module at column x, row y.
fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => x * y % 2 + x * y % 3 == 0,
        6 => (x * y % 2 + x * y % 3) % 2 == 0,
        7 => ((x + y) % 2 + x * y % 3) % 2 == 0,
    };
}

/// A symbol under construction: the modules and which of them are function patterns.
const Painter = struct {
    code: Code,
    function: [max_size * max_size]bool,

    /// Sets a function pattern module.
    fn set(p: *Painter, x: usize, y: usize, is_dark: bool) void {
        const i = y * p.code.size + x;
        p.code.modules[i] = @intFromBool(is_dark);
        p.function[i] = true;
    }

    fn drawFunctionPatterns(p: *Painter, version: usize) void {
        const size: usize = p.code.size;
        for (0..size) |i| { // timing patterns
            p.set(6, i, i % 2 == 0);
            p.set(i, 6, i % 2 == 0);
        }
        p.drawFinder(3, 3);
        p.drawFinder(size - 4, 3);
        p.drawFinder(3, size - 4);

        const centres = alignment_centres[version - 1];
        const count: usize = if (version == 1) 0 else version / 7 + 2;
        for (0..count) |i| {
            for (0..count) |j| {
                // The three corners with finder patterns have no alignment pattern.
                const corner = (i == 0 and j == 0) or (i == 0 and j == count - 1) or
                    (i == count - 1 and j == 0);
                if (!corner) p.drawAlignment(centres[i], centres[j]);
            }
        }

        p.drawFormat(0); // reserves the area; the real bits come with the chosen mask
        if (version >= 7) p.drawVersion(version);
    }

    /// A 7×7 finder pattern around (cx, cy) with its light separator.
    fn drawFinder(p: *Painter, cx: usize, cy: usize) void {
        const size: isize = p.code.size;
        var dy: isize = -4;
        while (dy <= 4) : (dy += 1) {
            var dx: isize = -4;
            while (dx <= 4) : (dx += 1) {
                const x = @as(isize, @intCast(cx)) + dx;
                const y = @as(isize, @intCast(cy)) + dy;
                if (x < 0 or x >= size or y < 0 or y >= size) continue;
                const ring = @max(@abs(dx), @abs(dy));
                p.set(@intCast(x), @intCast(y), ring != 2 and ring != 4);
            }
        }
    }

    /// A 5×5 alignment pattern around (cx, cy).
    fn drawAlignment(p: *Painter, cx: usize, cy: usize) void {
        for (0..5) |dy| {
            for (0..5) |dx| {
                const ring = @max(if (dx > 2) dx - 2 else 2 - dx, if (dy > 2) dy - 2 else 2 - dy);
                p.set(cx - 2 + dx, cy - 2 + dy, ring != 1);
            }
        }
    }

    /// Both copies of the format information and the dark module.
    fn drawFormat(p: *Painter, mask: u3) void {
        const size: usize = p.code.size;
        const bits = formatBits(mask);
        for (0..15) |i| {
            const bit = (bits >> @intCast(i)) & 1 != 0;
            // First copy: around the top-left finder, skipping the timing patterns.
            switch (i) {
                0...5 => p.set(8, i, bit),
                6 => p.set(8, 7, bit),
                7 => p.set(8, 8, bit),
                8 => p.set(7, 8, bit),
                else => p.set(14 - i, 8, bit),
            }
            // Second copy: under the top-right finder and beside the bottom-left one.
            if (i < 8) p.set(size - 1 - i, 8, bit) else p.set(8, size - 15 + i, bit);
        }
        p.set(8, size - 8, true); // the dark module
    }

    /// Both copies of the version information (versions 7 and up).
    fn drawVersion(p: *Painter, version: usize) void {
        const size: usize = p.code.size;
        const bits = versionBits(version);
        for (0..18) |i| {
            const bit = (bits >> @intCast(i)) & 1 != 0;
            const a = size - 11 + i % 3;
            const b = i / 3;
            p.set(a, b, bit);
            p.set(b, a, bit);
        }
    }

    /// Places the codeword bits in the zigzag order, two columns at a time from the right.
    /// Modules left over (remainder bits) stay light.
    fn drawCodewords(p: *Painter, codewords: []const u8) void {
        const size: usize = p.code.size;
        var i: usize = 0; // bit index
        var right: usize = size - 1;
        while (true) {
            if (right == 6) right = 5; // the vertical timing pattern takes a whole column
            const upward = (right + 1) & 2 == 0;
            for (0..size) |vert| {
                const y = if (upward) size - 1 - vert else vert;
                for (0..2) |j| {
                    const x = right - j;
                    const at = y * size + x;
                    if (p.function[at] or i >= codewords.len * 8) continue;
                    p.code.modules[at] = (codewords[i / 8] >> @intCast(7 - i % 8)) & 1;
                    i += 1;
                }
            }
            if (right < 2) break;
            right -= 2;
        }
        std.debug.assert(i == codewords.len * 8);
    }

    /// XORs the mask pattern into the data modules; applying it twice undoes it.
    fn applyMask(p: *Painter, mask: u3) void {
        const size: usize = p.code.size;
        for (0..size) |y| {
            for (0..size) |x| {
                const at = y * size + x;
                if (!p.function[at] and maskBit(mask, x, y)) p.code.modules[at] ^= 1;
            }
        }
    }
};

/// Penalty of one row or column: runs of five or more (N1) and finder-like patterns (N3).
fn linePenalty(c: *const Code, line: usize, horizontal: bool) u32 {
    const size: usize = c.size;
    var score: u32 = 0;
    var run: u32 = 0;
    var run_dark = false;
    var window: u11 = 0; // the last 11 modules, the newest in bit 0
    for (0..size) |i| {
        const is_dark = if (horizontal) c.dark(i, line) else c.dark(line, i);
        if (i > 0 and is_dark == run_dark) {
            run += 1;
            if (run == 5) score += 3 else if (run > 5) score += 1;
        } else {
            run = 1;
            run_dark = is_dark;
        }
        window = (window << 1) | @intFromBool(is_dark);
        // 1:1:3:1:1 dark-light-dark-light-dark with four light modules on either side.
        if (i >= 10 and (window == 0b10111010000 or window == 0b00001011101)) score += 40;
    }
    return score;
}

/// The standard's mask penalty: the sum of rules N1–N4; lower is better.
fn penalty(c: *const Code) u32 {
    const size: usize = c.size;
    var score: u32 = 0;
    for (0..size) |i| score += linePenalty(c, i, true) + linePenalty(c, i, false);

    // N2: every 2×2 block of one colour.
    for (0..size - 1) |y| {
        for (0..size - 1) |x| {
            const d = c.dark(x, y);
            if (d == c.dark(x + 1, y) and d == c.dark(x, y + 1) and d == c.dark(x + 1, y + 1)) score += 3;
        }
    }

    // N4: 10 points for every full 5 % the share of dark modules is away from 50 %.
    var dark_count: usize = 0;
    for (c.modules[0 .. size * size]) |m| dark_count += m;
    const total = size * size;
    const twice = dark_count * 2;
    const deviation = if (twice > total) twice - total else total - twice; // 2·|dark − total/2|
    score += @intCast(deviation * 10 / total * 10);
    return score;
}

/// Format bits for level M and masks 0–7, from the standard's table of valid sequences.
const format_table = [8]u15{ 0x5412, 0x5125, 0x5e7c, 0x5b4b, 0x45f9, 0x40ce, 0x4f97, 0x4aa0 };

/// Reads the first copy of the format information back from a finished symbol.
fn readFormat(c: *const Code, second_copy: bool) u15 {
    const size: usize = c.size;
    var bits: u15 = 0;
    for (0..15) |i| {
        const bit = if (second_copy)
            (if (i < 8) c.dark(size - 1 - i, 8) else c.dark(8, size - 15 + i))
        else switch (i) {
            0...5 => c.dark(8, i),
            6 => c.dark(8, 7),
            7 => c.dark(8, 8),
            8 => c.dark(7, 8),
            else => c.dark(14 - i, 8),
        };
        bits |= @as(u15, @intFromBool(bit)) << @intCast(i);
    }
    return bits;
}

fn expectFinder(c: *const Code, left: usize, top: usize) !void {
    for (0..7) |dy| {
        for (0..7) |dx| {
            const ring = @max(if (dx > 3) dx - 3 else 3 - dx, if (dy > 3) dy - 3 else 3 - dy);
            try std.testing.expectEqual(ring != 2, c.dark(left + dx, top + dy));
        }
    }
}

test "qr: capacity and codeword counts match the standard's tables" {
    const bytes_m = [max_version]usize{ 14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362, 412 };
    const total = [max_version]usize{ 26, 44, 70, 100, 134, 172, 196, 242, 292, 346, 404, 466, 532, 581, 655 };
    const data_m = [max_version]usize{ 16, 28, 44, 64, 86, 108, 124, 154, 182, 216, 254, 290, 334, 365, 415 };
    const remainder = [max_version]usize{ 0, 7, 7, 7, 7, 7, 0, 0, 0, 0, 0, 0, 0, 3, 3 };
    for (1..max_version + 1) |v| {
        try std.testing.expectEqual(bytes_m[v - 1], capacity(v));
        try std.testing.expectEqual(total[v - 1], totalCodewords(v));
        try std.testing.expectEqual(data_m[v - 1], dataCodewords(v));
        try std.testing.expectEqual(remainder[v - 1], rawModules(v) % 8);
    }
    try std.testing.expectEqual(@as(usize, max_codewords), totalCodewords(max_version));
    try std.testing.expectEqual(@as(usize, max_data_codewords), dataCodewords(max_version));
}

test "qr: version selection at the capacity boundaries" {
    const long: [413]u8 = @splat('a');
    const cases = [_]struct { len: usize, version: usize }{
        .{ .len = 0, .version = 1 },    .{ .len = 14, .version = 1 },
        .{ .len = 15, .version = 2 },   .{ .len = 106, .version = 6 },
        .{ .len = 107, .version = 7 },  .{ .len = 180, .version = 9 },
        .{ .len = 181, .version = 10 }, .{ .len = 213, .version = 10 },
        .{ .len = 214, .version = 11 }, .{ .len = 412, .version = 15 },
    };
    for (cases) |case| {
        const c = try encode(long[0..case.len]);
        try std.testing.expectEqual(17 + 4 * case.version, @as(usize, c.size));
    }
    try std.testing.expectError(error.TooLong, encode(&long));
}

test "qr: GF(256) arithmetic" {
    try std.testing.expectEqual(@as(u8, 0x1d), gfMul(0x80, 2)); // α^8 = α^4 + α^3 + α^2 + 1
    try std.testing.expectEqual(@as(u8, 0), gfMul(0, 0x53));
    try std.testing.expectEqual(@as(u8, 0x53), gfMul(1, 0x53));
    // α generates the whole multiplicative group: α^255 = 1 and no smaller power is 1.
    var x: u8 = 1;
    for (1..256) |i| {
        x = gfMul(x, 2);
        try std.testing.expectEqual(i == 255, x == 1);
    }
}

test "qr: Reed-Solomon known answer" {
    // The standard's worked example, a 1-M symbol: 16 data codewords, 10 error correction
    // codewords. Reed–Solomon does not depend on the mode the data codewords came from.
    const data = [16]u8{ 0x20, 0x5b, 0x0b, 0x78, 0xd1, 0x72, 0xdc, 0x4d, 0x43, 0x40, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11 };
    const expected = [10]u8{ 0xc4, 0x23, 0x27, 0x77, 0xeb, 0xd7, 0xe7, 0xe2, 0x5d, 0x17 };
    var generator: [10]u8 = undefined;
    rsGenerator(&generator);
    // x^10 + α^251 x^9 + … + α^45: the generator polynomial for 10 codewords from the standard.
    try std.testing.expectEqualSlices(u8, &.{ 216, 194, 159, 111, 199, 94, 95, 113, 157, 193 }, &generator);
    var ec: [10]u8 = undefined;
    rsRemainder(&data, &generator, &ec);
    try std.testing.expectEqualSlices(u8, &expected, &ec);
}

test "qr: every block is a Reed-Solomon codeword (zero syndromes)" {
    // Independent of rsGenerator and rsRemainder: de-interleave the final sequence and evaluate
    // each block as a polynomial at α^0 … α^(ec−1); a valid codeword gives zero everywhere.
    var payload: [412]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i * 37 + 11);
    for (1..max_version + 1) |v| {
        var buf: [max_codewords]u8 = undefined;
        const cw = buildCodewords(payload[0..capacity(v)], v, &buf);
        const blocks: usize = block_count[v - 1];
        const ec_len: usize = ec_per_block[v - 1];
        const short_blocks = blocks - cw.len % blocks;
        const short_len = cw.len / blocks - ec_len;
        const data_len = dataCodewords(v);
        for (0..blocks) |b| {
            const len = short_len + @intFromBool(b >= short_blocks);
            var root: u8 = 1;
            for (0..ec_len) |_| {
                var acc: u8 = 0;
                for (0..len) |i| {
                    // Row i of the interleaved data holds every block, or only the long ones.
                    const at = if (i < short_len) i * blocks + b else short_len * blocks + b - short_blocks;
                    acc = gfMul(acc, root) ^ cw[at];
                }
                for (0..ec_len) |i| acc = gfMul(acc, root) ^ cw[data_len + i * blocks + b];
                try std.testing.expectEqual(@as(u8, 0), acc);
                root = gfMul(root, 2);
            }
        }
    }
}

test "qr: data codewords of a byte-mode segment" {
    // 0100 | 00000010 | 'h' 'i' | 0000 terminator | pad bytes.
    var v1: [16]u8 = undefined;
    buildData("hi", 1, &v1);
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0x26, 0x86, 0x90, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11 }, &v1);
    // Version 10 and up: a 16-bit character count.
    var v10: [216]u8 = undefined;
    buildData("hi", 10, &v10);
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0x00, 0x26, 0x86, 0x90, 0xec, 0x11 }, v10[0..7]);
    // A full symbol: the terminator fills the last half byte, no padding.
    var full: [16]u8 = undefined;
    buildData("0123456789abcd", 1, &full);
    try std.testing.expectEqual(@as(u8, 0x40), full[0]);
    try std.testing.expectEqual(@as(u8, 0xe3), full[1]); // count 14 = 0x0e, then the high half of '0'
    try std.testing.expectEqual(@as(u8, 0x40), full[15]); // the low half of 'd', then 0000
}

test "qr: format and version information known answers" {
    for (format_table, 0..) |bits, mask| try std.testing.expectEqual(bits, formatBits(@intCast(mask)));
    try std.testing.expectEqual(@as(u18, 0x07c94), versionBits(7)); // the standard's example
    try std.testing.expectEqual(@as(u18, 0x085bc), versionBits(8));
    try std.testing.expectEqual(@as(u18, 0x0f928), versionBits(15));
}

test "qr: function patterns in place" {
    const payload: [412]u8 = @splat('x');
    for (1..max_version + 1) |v| {
        const c = try encode(payload[0..capacity(v)]);
        const size: usize = c.size;
        try std.testing.expectEqual(17 + 4 * v, size);

        try expectFinder(&c, 0, 0);
        try expectFinder(&c, size - 7, 0);
        try expectFinder(&c, 0, size - 7);
        for (0..8) |i| { // separators
            try std.testing.expect(!c.dark(7, i) and !c.dark(i, 7));
            try std.testing.expect(!c.dark(size - 8, i) and !c.dark(size - 8 + i, 7));
            try std.testing.expect(!c.dark(i, size - 8) and !c.dark(7, size - 8 + i));
        }
        for (8..size - 8) |i| { // timing
            try std.testing.expectEqual(i % 2 == 0, c.dark(i, 6));
            try std.testing.expectEqual(i % 2 == 0, c.dark(6, i));
        }
        try std.testing.expect(c.dark(8, size - 8)); // the dark module

        if (v >= 2) { // the bottom-right alignment pattern, centre 6 modules from the edges
            for (0..5) |dy| {
                for (0..5) |dx| {
                    const ring = @max(if (dx > 2) dx - 2 else 2 - dx, if (dy > 2) dy - 2 else 2 - dy);
                    try std.testing.expectEqual(ring != 1, c.dark(size - 9 + dx, size - 9 + dy));
                }
            }
            try std.testing.expectEqual(@as(usize, size - 7), alignment_centres[v - 1][v / 7 + 1]);
        }

        // Both copies of the format information agree and are a valid level M sequence.
        const format = readFormat(&c, false);
        try std.testing.expectEqual(format, readFormat(&c, true));
        try std.testing.expect(std.mem.indexOfScalar(u15, &format_table, format) != null);

        if (v >= 7) { // both copies of the version information
            const bits = versionBits(v);
            for (0..18) |i| {
                const bit = (bits >> @intCast(i)) & 1 != 0;
                try std.testing.expectEqual(bit, c.dark(size - 11 + i % 3, i / 3));
                try std.testing.expectEqual(bit, c.dark(i / 3, size - 11 + i % 3));
            }
        }

        // Nothing outside size × size is touched.
        for (c.modules[size * size ..]) |m| try std.testing.expectEqual(@as(u8, 0), m);
        for (c.modules[0 .. size * size]) |m| try std.testing.expect(m <= 1);
    }
}

test "qr: function and data modules add up" {
    for (1..max_version + 1) |v| {
        var p: Painter = .{
            .code = .{ .size = @intCast(17 + 4 * v), .modules = @splat(0) },
            .function = @splat(false),
        };
        p.drawFunctionPatterns(v);
        const size: usize = p.code.size;
        var free: usize = 0;
        for (p.function[0 .. size * size]) |f| free += @intFromBool(!f);
        try std.testing.expectEqual(rawModules(v), free);
    }
}

test "qr: the chosen mask has the lowest penalty" {
    const text = "https://anods.github.io/RDC/#my-AbCdEfGhIjKlMnOpQrStUv";
    const c = try encode(text);
    const chosen = std.mem.indexOfScalar(u15, &format_table, readFormat(&c, false)).?;
    const chosen_penalty = penalty(&c);

    var buf: [max_codewords]u8 = undefined;
    const version = try versionFor(text.len);
    var p: Painter = .{ .code = .{ .size = c.size, .modules = @splat(0) }, .function = @splat(false) };
    p.drawFunctionPatterns(version);
    p.drawCodewords(buildCodewords(text, version, &buf));
    for (0..8) |m| {
        p.applyMask(@intCast(m));
        p.drawFormat(@intCast(m));
        const score = penalty(&p.code);
        try std.testing.expect(score >= chosen_penalty);
        if (m == chosen) try std.testing.expectEqualSlices(u8, &c.modules, &p.code.modules);
        p.applyMask(@intCast(m));
    }
}

test "qr: penalty rules on hand-made symbols" {
    // All light, 21 × 21: N1 = 42 lines × (3 + 16), N2 = 400 blocks × 3, N4 = 50 % off → 100.
    var c: Code = .{ .size = 21, .modules = @splat(0) };
    try std.testing.expectEqual(@as(u32, 42 * 19 + 400 * 3 + 100), penalty(&c));
    // A checkerboard has no runs and no blocks; 221 dark of 441 is within 5 % of half.
    for (0..21) |y| {
        for (0..21) |x| c.modules[y * 21 + x] = @intCast((x + y + 1) % 2);
    }
    try std.testing.expectEqual(@as(u32, 0), penalty(&c));
    // One finder-like row: 1011101 followed by four light modules, in a checkerboard row.
    const row = [21]u8{ 1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 };
    try std.testing.expectEqual(@as(u32, 40), blk: {
        var one: Code = .{ .size = 21, .modules = @splat(0) };
        @memcpy(one.modules[0..21], &row);
        const all_light: Code = .{ .size = 21, .modules = @splat(0) };
        // Compare the row alone with a light row: runs differ, the pattern adds 40.
        break :blk linePenalty(&one, 0, true) - (linePenalty(&all_light, 0, true) - 3 - 16);
    });
}
