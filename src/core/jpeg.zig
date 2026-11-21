//! Baseline JPEG encoder (ITU T.81): 8-bit, YCbCr 4:2:0, the standard Huffman tables of Annex K,
//! optional bilinear downscaling on the way in. Pure Zig, no OS: the Linux host encodes its
//! frames with it (src/platform/linux/zig_export.zig hands it to the C shim), since Linux has no
//! image encoder every desktop is sure to carry.
const std = @import("std");

pub const PixelFormat = enum {
    /// Bytes B, G, R, X — a 32-bit X11 ZPixmap on a little-endian machine.
    bgrx,
    /// Bytes R, G, B, X.
    rgbx,
};

/// The picture to encode: 4 bytes a pixel, rows `stride` bytes apart.
pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    format: PixelFormat = .bgrx,
};

pub const Error = error{ OutOfMemory, BadSize };

/// The largest picture side: JPEG stores sizes in 16 bits.
pub const max_side = 65535;

const V = @Vector(8, f32);
const Block = [8]V;

/// Natural (row-major) index of the k-th coefficient in zigzag order.
const natural_order = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

/// The DCT below leaves the coefficients transposed (row = horizontal frequency): the index in
/// that layout of the k-th coefficient in zigzag order.
const zigzag_t: [64]u8 = blk: {
    var t: [64]u8 = undefined;
    for (natural_order, 0..) |n, k| t[k] = (n % 8) * 8 + n / 8;
    break :blk t;
};

// Annex K.1: the example quantization tables, natural order.
const base_luma = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};
const base_chroma = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

// Annex K.3: the typical Huffman tables — counts of codes of each length 1..16, then the symbols.
const dc_luma_bits = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const dc_chroma_bits = [16]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const dc_vals = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const ac_luma_bits = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const ac_luma_vals = [162]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};
const ac_chroma_bits = [16]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
const ac_chroma_vals = [162]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

/// Code and length of every symbol of a Huffman table (C.2: codes in order of length).
const Huff = struct {
    code: [256]u16,
    len: [256]u8,

    fn build(comptime bits: [16]u8, comptime vals: []const u8) Huff {
        @setEvalBranchQuota(10000);
        var h: Huff = .{ .code = @splat(0), .len = @splat(0) };
        var code: u16 = 0;
        var k: usize = 0;
        for (bits, 1..) |count, l| {
            for (0..count) |_| {
                h.code[vals[k]] = code;
                h.len[vals[k]] = l;
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
        if (k != vals.len) @compileError("Huffman table counts do not match its symbols");
        return h;
    }
};

const huff_dc_luma = Huff.build(dc_luma_bits, &dc_vals);
const huff_dc_chroma = Huff.build(dc_chroma_bits, &dc_vals);
const huff_ac_luma = Huff.build(ac_luma_bits, &ac_luma_vals);
const huff_ac_chroma = Huff.build(ac_chroma_bits, &ac_chroma_vals);

/// Scale factors of the AAN DCT (cos(k·π/16)·√2, 1 for k = 0).
const aan = [8]f32{ 1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379 };

/// IJG's quality scaling of a base table, natural order.
fn scaledTable(base: [64]u8, quality: u8) [64]u8 {
    const q: u32 = @max(1, @min(100, quality));
    const scale: u32 = if (q < 50) 5000 / q else 200 - 2 * q;
    var t: [64]u8 = undefined;
    for (base, 0..) |b, i| t[i] = @intCast(@max(1, @min(255, (@as(u32, b) * scale + 50) / 100)));
    return t;
}

/// Divisors for the AAN DCT's output, in its transposed layout.
fn divisors(table: [64]u8) [64]f32 {
    var d: [64]f32 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const n = row * 8 + col; // natural: row = vertical frequency
            d[col * 8 + row] = 1.0 / (@as(f32, @floatFromInt(table[n])) * aan[row] * aan[col] * 8.0);
        }
    }
    return d;
}

/// The AAN forward DCT (as in IJG's jfdctflt.c) along the 8 vectors: each lane is one column.
inline fn dct8(b: *Block) void {
    const t0 = b[0] + b[7];
    const t7 = b[0] - b[7];
    const t1 = b[1] + b[6];
    const t6 = b[1] - b[6];
    const t2 = b[2] + b[5];
    const t5 = b[2] - b[5];
    const t3 = b[3] + b[4];
    const t4 = b[3] - b[4];

    const t10 = t0 + t3;
    const t13 = t0 - t3;
    const t11 = t1 + t2;
    const t12 = t1 - t2;
    b[0] = t10 + t11;
    b[4] = t10 - t11;
    const z1 = (t12 + t13) * @as(V, @splat(0.707106781));
    b[2] = t13 + z1;
    b[6] = t13 - z1;

    const s10 = t4 + t5;
    const s11 = t5 + t6;
    const s12 = t6 + t7;
    const z5 = (s10 - s12) * @as(V, @splat(0.382683433));
    const z2 = @as(V, @splat(0.541196100)) * s10 + z5;
    const z4 = @as(V, @splat(1.306562965)) * s12 + z5;
    const z3 = s11 * @as(V, @splat(0.707106781));
    const z11 = t7 + z3;
    const z13 = t7 - z3;
    b[5] = z13 + z2;
    b[3] = z13 - z2;
    b[1] = z11 + z4;
    b[7] = z11 - z4;
}

inline fn transpose(b: *Block) void {
    const a: [64]f32 = @bitCast(b.*);
    var t: [64]f32 = undefined;
    inline for (0..8) |r| {
        inline for (0..8) |c| t[c * 8 + r] = a[r * 8 + c];
    }
    b.* = @bitCast(t);
}

/// Bits into bytes, with a 0 after every 0xFF (F.1.2.3). The caller reserves the room.
const BitWriter = struct {
    acc: u64 = 0,
    n: u32 = 0,

    inline fn put(w: *BitWriter, out: *std.ArrayList(u8), bits: u32, len: u32) void {
        w.acc = (w.acc << @intCast(len)) | bits;
        w.n += len;
        while (w.n >= 8) {
            w.n -= 8;
            const byte: u8 = @truncate(w.acc >> @intCast(w.n));
            out.appendAssumeCapacity(byte);
            if (byte == 0xFF) out.appendAssumeCapacity(0);
        }
    }

    /// Pads the last byte with 1 bits.
    fn finish(w: *BitWriter, out: *std.ArrayList(u8)) void {
        if (w.n > 0) w.put(out, (@as(u32, 1) << @intCast(8 - w.n)) - 1, 8 - w.n);
    }
};

/// Room for one 16×16 MCU (six blocks): 64 codes of at most 27 bits each, every byte maybe stuffed.
const mcu_reserve = 6 * 64 * 27 / 8 * 2 + 64;

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    quality: u8,
    q_luma: [64]u8,
    q_chroma: [64]u8,
    div_luma: [64]f32,
    div_chroma: [64]f32,
    /// One strip of 16 picture rows: Y at full width, Cb and Cr at half, all minus 128.
    y: []f32 = &.{},
    cb: []f32 = &.{},
    cr: []f32 = &.{},
    /// Two picture rows in RGB, float.
    rgb: []f32 = &.{},
    /// For scaling: the source column and weight of every output column.
    xs: []u32 = &.{},
    wx: []f32 = &.{},
    padded_w: usize = 0,
    /// The last JPEG; valid until the next encode.
    out: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, quality: u8) Encoder {
        var e: Encoder = .{ .gpa = gpa, .quality = 0, .q_luma = undefined, .q_chroma = undefined, .div_luma = undefined, .div_chroma = undefined };
        e.setQuality(quality);
        return e;
    }

    pub fn deinit(e: *Encoder) void {
        e.gpa.free(e.y);
        e.gpa.free(e.cb);
        e.gpa.free(e.cr);
        e.gpa.free(e.rgb);
        e.gpa.free(e.xs);
        e.gpa.free(e.wx);
        e.out.deinit(e.gpa);
        e.* = undefined;
    }

    /// 1 (smallest) … 100 (best), as in IJG's cjpeg.
    pub fn setQuality(e: *Encoder, quality: u8) void {
        const q = @max(1, @min(100, quality));
        if (q == e.quality) return;
        e.quality = q;
        e.q_luma = scaledTable(base_luma, q);
        e.q_chroma = scaledTable(base_chroma, q);
        e.div_luma = divisors(e.q_luma);
        e.div_chroma = divisors(e.q_chroma);
    }

    fn ensureBuffers(e: *Encoder, out_w: u32) Error!void {
        const pw = (@as(usize, out_w) + 15) / 16 * 16;
        if (pw == e.padded_w) return;
        const gpa = e.gpa;
        gpa.free(e.y);
        gpa.free(e.cb);
        gpa.free(e.cr);
        gpa.free(e.rgb);
        e.y = &.{};
        e.cb = &.{};
        e.cr = &.{};
        e.rgb = &.{};
        e.padded_w = 0;
        e.y = try gpa.alloc(f32, 16 * pw);
        e.cb = try gpa.alloc(f32, 8 * pw / 2);
        e.cr = try gpa.alloc(f32, 8 * pw / 2);
        e.rgb = try gpa.alloc(f32, 6 * pw);
        e.padded_w = pw;
    }

    fn ensureScaleTables(e: *Encoder, src_w: u32, out_w: u32) Error!void {
        if (e.xs.len != out_w) {
            e.gpa.free(e.xs);
            e.gpa.free(e.wx);
            e.xs = &.{};
            e.wx = &.{};
            e.xs = try e.gpa.alloc(u32, out_w);
            e.wx = try e.gpa.alloc(f32, out_w);
        }
        const ratio = @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(out_w));
        for (0..out_w) |i| {
            const sx = @max(0, (@as(f32, @floatFromInt(i)) + 0.5) * ratio - 0.5);
            const x0: u32 = @min(src_w - 1, @as(u32, @intFromFloat(sx)));
            e.xs[i] = x0;
            e.wx[i] = if (x0 + 1 < src_w) sx - @as(f32, @floatFromInt(x0)) else 0;
        }
    }

    /// Encodes `img`, scaled to out_w × out_h (bilinear; the same size — no scaling).
    /// The JPEG stays in `e.out` until the next call.
    pub fn encode(e: *Encoder, img: Image, out_w: u32, out_h: u32) Error![]const u8 {
        if (img.width == 0 or img.height == 0 or out_w == 0 or out_h == 0 or out_w > max_side or out_h > max_side) return error.BadSize;
        if (img.stride < @as(usize, img.width) * 4 or img.pixels.len < img.stride * (img.height - 1) + @as(usize, img.width) * 4) return error.BadSize;
        try e.ensureBuffers(out_w);
        const scaled = out_w != img.width or out_h != img.height;
        if (scaled) try e.ensureScaleTables(img.width, out_w);

        const gpa = e.gpa;
        e.out.clearRetainingCapacity();
        try e.out.ensureTotalCapacity(gpa, 1024 + @as(usize, out_w) * out_h / 4);
        e.writeHeaders(out_w, out_h);

        const pw = e.padded_w;
        const hw = pw / 2;
        var bw: BitWriter = .{};
        var dc: [3]i32 = .{ 0, 0, 0 };
        const y_ratio = @as(f32, @floatFromInt(img.height)) / @as(f32, @floatFromInt(out_h));

        var strip: u32 = 0;
        while (strip < out_h) : (strip += 16) {
            // Picture rows → Y, Cb, Cr of this strip; rows past the bottom repeat the last one.
            var r: u32 = 0;
            while (r < 16) : (r += 2) {
                const r0 = @as(usize, r) * pw;
                const rgb0 = e.rgb[0 .. 3 * pw];
                const rgb1 = e.rgb[3 * pw .. 6 * pw];
                inline for (.{ rgb0, rgb1 }, 0..) |row_rgb, k| {
                    const oy = @min(out_h - 1, strip + r + k);
                    if (scaled) e.scaledRow(img, oy, y_ratio, out_w, row_rgb) else plainRow(img, oy, row_rgb);
                    // Columns past the right edge repeat the last one.
                    var x: usize = out_w;
                    while (x < pw) : (x += 1) {
                        row_rgb[3 * x] = row_rgb[3 * (out_w - 1)];
                        row_rgb[3 * x + 1] = row_rgb[3 * (out_w - 1) + 1];
                        row_rgb[3 * x + 2] = row_rgb[3 * (out_w - 1) + 2];
                    }
                    const yrow = e.y[r0 + k * pw ..][0..pw];
                    for (yrow, 0..) |*yv, x2| {
                        yv.* = 0.299 * row_rgb[3 * x2] + 0.587 * row_rgb[3 * x2 + 1] + 0.114 * row_rgb[3 * x2 + 2] - 128.0;
                    }
                }
                const cbrow = e.cb[(r / 2) * hw ..][0..hw];
                const crrow = e.cr[(r / 2) * hw ..][0..hw];
                for (0..hw) |cx| {
                    const a = 6 * cx;
                    const red = (rgb0[a] + rgb0[a + 3] + rgb1[a] + rgb1[a + 3]) * 0.25;
                    const green = (rgb0[a + 1] + rgb0[a + 4] + rgb1[a + 1] + rgb1[a + 4]) * 0.25;
                    const blue = (rgb0[a + 2] + rgb0[a + 5] + rgb1[a + 2] + rgb1[a + 5]) * 0.25;
                    cbrow[cx] = -0.168736 * red - 0.331264 * green + 0.5 * blue;
                    crrow[cx] = 0.5 * red - 0.418688 * green - 0.081312 * blue;
                }
            }
            // The strip's MCUs: four Y blocks, then Cb, then Cr.
            var mx: usize = 0;
            while (mx < pw) : (mx += 16) {
                try e.out.ensureUnusedCapacity(gpa, mcu_reserve);
                inline for (.{ .{ 0, 0 }, .{ 8, 0 }, .{ 0, 8 }, .{ 8, 8 } }) |off| {
                    var b: Block = undefined;
                    inline for (0..8) |row| b[row] = e.y[(off[1] + row) * pw + mx + off[0] ..][0..8].*;
                    e.block(&b, &e.div_luma, &dc[0], &huff_dc_luma, &huff_ac_luma, &bw);
                }
                inline for (.{ e.cb, e.cr }, 1..) |plane, ci| {
                    var b: Block = undefined;
                    inline for (0..8) |row| b[row] = plane[row * hw + mx / 2 ..][0..8].*;
                    e.block(&b, &e.div_chroma, &dc[ci], &huff_dc_chroma, &huff_ac_chroma, &bw);
                }
            }
        }
        try e.out.ensureUnusedCapacity(gpa, 8);
        bw.finish(&e.out);
        e.out.appendSliceAssumeCapacity(&.{ 0xFF, 0xD9 }); // EOI
        return e.out.items;
    }

    fn plainRow(img: Image, y: u32, rgb: []f32) void {
        const src = img.pixels[@as(usize, y) * img.stride ..][0 .. @as(usize, img.width) * 4];
        const ri: usize, const bi: usize = if (img.format == .bgrx) .{ 2, 0 } else .{ 0, 2 };
        for (0..img.width) |x| {
            const p = src[4 * x ..][0..4];
            rgb[3 * x] = @floatFromInt(p[ri]);
            rgb[3 * x + 1] = @floatFromInt(p[1]);
            rgb[3 * x + 2] = @floatFromInt(p[bi]);
        }
    }

    fn scaledRow(e: *const Encoder, img: Image, oy: u32, y_ratio: f32, out_w: u32, rgb: []f32) void {
        const sy = @max(0, (@as(f32, @floatFromInt(oy)) + 0.5) * y_ratio - 0.5);
        const y0: u32 = @min(img.height - 1, @as(u32, @intFromFloat(sy)));
        const y1 = @min(img.height - 1, y0 + 1);
        const wy = sy - @as(f32, @floatFromInt(y0));
        const row0 = img.pixels[@as(usize, y0) * img.stride ..];
        const row1 = img.pixels[@as(usize, y1) * img.stride ..];
        const ri: usize, const bi: usize = if (img.format == .bgrx) .{ 2, 0 } else .{ 0, 2 };
        const last = img.width - 1;
        for (0..out_w) |x| {
            const x0 = e.xs[x];
            const x1 = @min(last, x0 + 1);
            const wx = e.wx[x];
            inline for (.{ ri, 1, bi }, 0..) |ch, k| {
                const a: f32 = @floatFromInt(row0[4 * x0 + ch]);
                const b: f32 = @floatFromInt(row0[4 * x1 + ch]);
                const c: f32 = @floatFromInt(row1[4 * x0 + ch]);
                const d: f32 = @floatFromInt(row1[4 * x1 + ch]);
                const top = a + (b - a) * wx;
                const bottom = c + (d - c) * wx;
                rgb[3 * x + k] = top + (bottom - top) * wy;
            }
        }
    }

    /// DCT, quantization, Huffman coding of one 8×8 block (F.1.2).
    fn block(e: *Encoder, b: *Block, div: *const [64]f32, dc_pred: *i32, dc_huff: *const Huff, ac_huff: *const Huff, bw: *BitWriter) void {
        dct8(b);
        transpose(b);
        dct8(b);
        // Quantize, round, clamp to baseline's range.
        const flat: [8]V = b.*;
        var q: [64]i32 = undefined;
        inline for (0..8) |row| {
            const d: V = div[row * 8 ..][0..8].*;
            const v = flat[row] * d + @as(V, @splat(16384.5));
            var iv: @Vector(8, i32) = @intFromFloat(v);
            iv -= @splat(16384);
            iv = @max(@as(@Vector(8, i32), @splat(-1023)), @min(@as(@Vector(8, i32), @splat(1023)), iv));
            q[row * 8 ..][0..8].* = iv;
        }
        var zz: [64]i32 = undefined;
        inline for (0..64) |k| zz[k] = q[zigzag_t[k]];

        const out = &e.out;
        const diff = zz[0] - dc_pred.*;
        dc_pred.* = zz[0];
        const dn = bitLength(diff);
        bw.put(out, dc_huff.code[dn], dc_huff.len[dn]);
        if (dn > 0) bw.put(out, valueBits(diff, dn), dn);

        var last: usize = 63;
        while (last > 0 and zz[last] == 0) last -= 1;
        var run: u32 = 0;
        var k: usize = 1;
        while (k <= last) : (k += 1) {
            const v = zz[k];
            if (v == 0) {
                run += 1;
                continue;
            }
            while (run >= 16) : (run -= 16) bw.put(out, ac_huff.code[0xF0], ac_huff.len[0xF0]); // ZRL
            const n = bitLength(v);
            const sym = (run << 4) | n;
            bw.put(out, ac_huff.code[sym], ac_huff.len[sym]);
            bw.put(out, valueBits(v, n), n);
            run = 0;
        }
        if (last < 63) bw.put(out, ac_huff.code[0x00], ac_huff.len[0x00]); // EOB
    }

    fn writeHeaders(e: *Encoder, w: u32, h: u32) void {
        const o = &e.out;
        o.appendSliceAssumeCapacity(&.{ 0xFF, 0xD8 }); // SOI
        // APP0 JFIF 1.01, no density, no thumbnail.
        o.appendSliceAssumeCapacity(&.{ 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00 });
        // DQT: both tables, 8-bit, zigzag order.
        o.appendSliceAssumeCapacity(&.{ 0xFF, 0xDB, 0x00, 0x84, 0x00 });
        for (natural_order) |n| o.appendAssumeCapacity(e.q_luma[n]);
        o.appendAssumeCapacity(0x01);
        for (natural_order) |n| o.appendAssumeCapacity(e.q_chroma[n]);
        // SOF0: 8-bit, three components; Y sampled 2×2, Cb and Cr 1×1.
        o.appendSliceAssumeCapacity(&.{ 0xFF, 0xC0, 0x00, 0x11, 0x08, @truncate(h >> 8), @truncate(h), @truncate(w >> 8), @truncate(w), 0x03 });
        o.appendSliceAssumeCapacity(&.{ 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01 });
        // DHT: the four tables of Annex K.3.
        const tables = .{
            .{ 0x00, &dc_luma_bits, &dc_vals },
            .{ 0x10, &ac_luma_bits, &ac_luma_vals },
            .{ 0x01, &dc_chroma_bits, &dc_vals },
            .{ 0x11, &ac_chroma_bits, &ac_chroma_vals },
        };
        inline for (tables) |t| {
            const len: u16 = 2 + 1 + 16 + t[2].len;
            o.appendSliceAssumeCapacity(&.{ 0xFF, 0xC4, @truncate(len >> 8), @truncate(len), t[0] });
            o.appendSliceAssumeCapacity(t[1]);
            o.appendSliceAssumeCapacity(t[2]);
        }
        // SOS: three components with their tables, full spectral range.
        o.appendSliceAssumeCapacity(&.{ 0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00 });
    }
};

/// The magnitude category of a coefficient (F.1.2.1): bits needed for |v|.
fn bitLength(v: i32) u32 {
    const a: u32 = @abs(v);
    return 32 - @clz(a);
}

/// The value's bits: v itself when positive, v − 1 (ones' complement) when negative.
fn valueBits(v: i32, n: u32) u32 {
    const u: u32 = @bitCast(if (v < 0) v - 1 else v);
    return u & ((@as(u32, 1) << @intCast(n)) - 1);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testImage(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| {
        for (0..w) |x| {
            const p = px[(y * w + x) * 4 ..][0..4];
            p[0] = @truncate(x * 255 / w);
            p[1] = @truncate(y * 255 / h);
            p[2] = if ((x / 8 + y / 8) % 2 == 0) 230 else 20;
            p[3] = 0;
        }
    }
    return px;
}

/// A naive DCT-II by its definition, to check the AAN version against.
fn referenceDct(in: [64]f32) [64]f32 {
    var out: [64]f32 = undefined;
    for (0..8) |v| {
        for (0..8) |u| {
            var s: f64 = 0;
            for (0..8) |y| {
                for (0..8) |x| {
                    s += in[y * 8 + x] *
                        @cos((2.0 * @as(f64, @floatFromInt(x)) + 1) * @as(f64, @floatFromInt(u)) * std.math.pi / 16.0) *
                        @cos((2.0 * @as(f64, @floatFromInt(y)) + 1) * @as(f64, @floatFromInt(v)) * std.math.pi / 16.0);
                }
            }
            const cu: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1;
            const cv: f64 = if (v == 0) 1.0 / @sqrt(2.0) else 1;
            out[v * 8 + u] = @floatCast(0.25 * cu * cv * s);
        }
    }
    return out;
}

test "jpeg: AAN DCT with its scaling matches the textbook DCT" {
    var in: [64]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for (&in) |*v| v.* = @as(f32, @floatFromInt(prng.random().intRangeAtMost(i32, -128, 127)));
    const want = referenceDct(in);
    var b: Block = @bitCast(in);
    dct8(&b);
    transpose(&b);
    dct8(&b);
    const got: [64]f32 = @bitCast(b);
    // With a quantizer of 1 everywhere the divisor is 1 / (aan·aan·8).
    const ones: [64]u8 = @splat(1);
    const d = divisors(ones);
    for (0..8) |v| {
        for (0..8) |u| {
            const n = v * 8 + u;
            try testing.expectApproxEqAbs(want[n], got[u * 8 + v] * d[u * 8 + v], 0.01);
        }
    }
}

test "jpeg: Huffman tables are canonical" {
    try testing.expectEqual(@as(u8, 2), huff_dc_luma.len[0]);
    try testing.expectEqual(@as(u16, 0b00), huff_dc_luma.code[0]);
    try testing.expectEqual(@as(u8, 4), huff_ac_luma.len[0x00]); // EOB = 1010
    try testing.expectEqual(@as(u16, 0b1010), huff_ac_luma.code[0x00]);
    try testing.expectEqual(@as(u8, 11), huff_ac_luma.len[0xF0]); // ZRL = 11111111001
    try testing.expectEqual(@as(u16, 0b11111111001), huff_ac_luma.code[0xF0]);
    try testing.expectEqual(@as(u8, 2), huff_ac_chroma.len[0x00]); // EOB = 00
}

test "jpeg: value bits and categories" {
    try testing.expectEqual(@as(u32, 0), bitLength(0));
    try testing.expectEqual(@as(u32, 1), bitLength(-1));
    try testing.expectEqual(@as(u32, 3), bitLength(5));
    try testing.expectEqual(@as(u32, 11), bitLength(-1023 - 1000));
    try testing.expectEqual(@as(u32, 0b010), valueBits(-5, 3)); // -5 → 010
    try testing.expectEqual(@as(u32, 0b101), valueBits(5, 3));
}

test "jpeg: quality tables" {
    try testing.expectEqualSlices(u8, &base_luma, &scaledTable(base_luma, 50));
    const best = scaledTable(base_luma, 100);
    for (best) |q| try testing.expectEqual(@as(u8, 1), q);
    const worst = scaledTable(base_chroma, 1);
    for (worst) |q| try testing.expectEqual(@as(u8, 255), q);
}

test "jpeg: well-formed stream, odd sizes, scaling, no stray markers" {
    const gpa = testing.allocator;
    var e = Encoder.init(gpa, 75);
    defer e.deinit();
    for ([_][4]u32{ .{ 1, 1, 1, 1 }, .{ 17, 9, 17, 9 }, .{ 100, 37, 100, 37 }, .{ 640, 480, 320, 240 }, .{ 333, 211, 200, 127 } }) |s| {
        const px = try testImage(gpa, s[0], s[1]);
        defer gpa.free(px);
        const jpg = try e.encode(.{ .pixels = px, .width = s[0], .height = s[1], .stride = s[0] * 4 }, s[2], s[3]);
        try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8, 0xFF, 0xE0 }, jpg[0..4]);
        try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, jpg[jpg.len - 2 ..]);
        // The frame header carries the output size.
        const sof = std.mem.indexOf(u8, jpg, &.{ 0xFF, 0xC0 }).?;
        try testing.expectEqual(@as(u16, @intCast(s[3])), std.mem.readInt(u16, jpg[sof + 5 ..][0..2], .big));
        try testing.expectEqual(@as(u16, @intCast(s[2])), std.mem.readInt(u16, jpg[sof + 7 ..][0..2], .big));
        // In the entropy-coded data every 0xFF is followed by a stuffed 0.
        const sos = std.mem.indexOf(u8, jpg, &.{ 0xFF, 0xDA }).?;
        const data = jpg[sos + 14 .. jpg.len - 2];
        for (data, 0..) |byte, i| {
            if (byte == 0xFF) try testing.expectEqual(@as(u8, 0), data[i + 1]);
        }
    }
}

test "jpeg: the same picture gives the same bytes; quality changes the size" {
    const gpa = testing.allocator;
    const px = try testImage(gpa, 256, 128);
    defer gpa.free(px);
    const img: Image = .{ .pixels = px, .width = 256, .height = 128, .stride = 256 * 4 };
    var e = Encoder.init(gpa, 50);
    defer e.deinit();
    const a = try gpa.dupe(u8, try e.encode(img, 256, 128));
    defer gpa.free(a);
    try testing.expectEqualSlices(u8, a, try e.encode(img, 256, 128));
    e.setQuality(95);
    try testing.expect((try e.encode(img, 256, 128)).len > a.len);
    try testing.expectError(error.BadSize, e.encode(img, 0, 10));
    try testing.expectError(error.BadSize, e.encode(.{ .pixels = px[0..100], .width = 256, .height = 128, .stride = 1024 }, 256, 128));
}
