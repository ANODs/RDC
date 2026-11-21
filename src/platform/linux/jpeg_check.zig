//! `zig build jpeg-check -- <dir>`: checks the Linux host's JPEG encoder (src/core/jpeg.zig) on the
//! machine running the build. Times 1920×1080 frames (the host needs at least 15 a second on one
//! core), then has macOS decode the files (`sips`, i.e. ImageIO) and compares the pixels with the
//! source. Without `sips` (not a Mac) only the timing runs.
const std = @import("std");
const jpeg = @import("jpeg");

const Case = struct { name: []const u8, w: u32, h: u32, out_w: u32, out_h: u32, quality: u8, max_mean: f64, min_psnr: f64, gray: bool = false };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const dir_path = if (args.len > 1) args[1] else "zig-out/jpeg-check";
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);

    var failed = false;
    // Timing: a desktop-like 1080p picture, the host's quality.
    {
        const px = try desktop(gpa, 1920, 1080);
        defer gpa.free(px);
        var e = jpeg.Encoder.init(gpa, 60);
        defer e.deinit();
        const img: jpeg.Image = .{ .pixels = px, .width = 1920, .height = 1080, .stride = 1920 * 4 };
        _ = try e.encode(img, 1920, 1080); // warm up
        const runs = 30;
        const t0 = std.Io.Clock.awake.now(io);
        var bytes: usize = 0;
        for (0..runs) |_| bytes += (try e.encode(img, 1920, 1080)).len;
        const ns: u64 = @intCast(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
        const ms = @as(f64, @floatFromInt(ns)) / 1e6 / runs;
        std.debug.print("1920x1080 q60: {d:.1} ms a frame ({d:.0} fps on one core), {d} KB\n", .{ ms, 1000.0 / ms, bytes / runs / 1024 });
        if (1000.0 / ms < 15) failed = true;
        // Downscaled from 2560×1440, as with --max-width 1920 on a bigger screen.
        const big = try desktop(gpa, 2560, 1440);
        defer gpa.free(big);
        const img2: jpeg.Image = .{ .pixels = big, .width = 2560, .height = 1440, .stride = 2560 * 4 };
        const t1 = std.Io.Clock.awake.now(io);
        for (0..runs) |_| _ = try e.encode(img2, 1920, 1080);
        const ns2: u64 = @intCast(t1.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
        const ms2 = @as(f64, @floatFromInt(ns2)) / 1e6 / runs;
        std.debug.print("2560x1440 -> 1920x1080 q60: {d:.1} ms a frame ({d:.0} fps)\n", .{ ms2, 1000.0 / ms2 });
        if (1000.0 / ms2 < 15) failed = true;
    }

    // Pass marks: a decoder must read every file, and the pixels must come back close. Our quality
    // scale is IJG's; ImageIO's is a different one, so its own round trip is printed only as a hint.
    // A gray picture has no chroma to subsample: at q100 only the DCT's rounding is left, so it
    // checks the transform and the entropy coding bit for bit (ImageIO itself goes 4:4:4 at q100).
    const cases = [_]Case{
        .{ .name = "gray-q100", .w = 1920, .h = 1080, .out_w = 1920, .out_h = 1080, .quality = 100, .max_mean = 0.8, .min_psnr = 45, .gray = true },
        .{ .name = "desktop-q100", .w = 1920, .h = 1080, .out_w = 1920, .out_h = 1080, .quality = 100, .max_mean = 1.5, .min_psnr = 30 },
        .{ .name = "desktop-q90", .w = 1920, .h = 1080, .out_w = 1920, .out_h = 1080, .quality = 90, .max_mean = 3.0, .min_psnr = 30 },
        .{ .name = "desktop-q60", .w = 1920, .h = 1080, .out_w = 1920, .out_h = 1080, .quality = 60, .max_mean = 6.0, .min_psnr = 26 },
        .{ .name = "odd-q75", .w = 333, .h = 211, .out_w = 333, .out_h = 211, .quality = 75, .max_mean = 5.0, .min_psnr = 28 },
        .{ .name = "tiny-q100", .w = 5, .h = 3, .out_w = 5, .out_h = 3, .quality = 100, .max_mean = 12.0, .min_psnr = 24 },
        .{ .name = "scaled-q75", .w = 2560, .h = 1440, .out_w = 1920, .out_h = 1080, .quality = 75, .max_mean = 5.0, .min_psnr = 28 },
    };
    for (cases) |c| {
        const px = try desktop(gpa, c.w, c.h);
        defer gpa.free(px);
        if (c.gray) {
            var i: usize = 0;
            while (i < px.len) : (i += 4) {
                const y: u8 = @intCast((@as(u32, px[i]) * 29 + @as(u32, px[i + 1]) * 150 + @as(u32, px[i + 2]) * 77) >> 8);
                px[i..][0..3].* = .{ y, y, y };
            }
        }
        var e = jpeg.Encoder.init(gpa, c.quality);
        defer e.deinit();
        const jpg = try e.encode(.{ .pixels = px, .width = c.w, .height = c.h, .stride = @as(usize, c.w) * 4 }, c.out_w, c.out_h);
        const jpg_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}.jpg", .{ dir_path, c.name });
        const bmp_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}.bmp", .{ dir_path, c.name });
        try cwd.writeFile(io, .{ .sub_path = jpg_path, .data = jpg });
        const r = std.process.run(gpa, io, .{ .argv = &.{ "sips", "-s", "format", "bmp", jpg_path, "--out", bmp_path } }) catch |err| {
            std.debug.print("{s}: {d} bytes written; no sips to decode it ({t})\n", .{ c.name, jpg.len, err });
            continue;
        };
        gpa.free(r.stdout);
        gpa.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) {
            std.debug.print("{s}: sips could not decode it\n", .{c.name});
            failed = true;
            continue;
        }
        const bmp = try cwd.readFileAlloc(io, bmp_path, gpa, .limited(64 << 20));
        defer gpa.free(bmp);
        // The reference: the source itself, or for a scaled case the source box-averaged by 4:3.
        const ref = if (c.out_w == c.w) try gpa.dupe(u8, px) else try boxScale(gpa, px, c.w, c.h, c.out_w, c.out_h);
        defer gpa.free(ref);
        const cmp = compare(bmp, ref, c.out_w, c.out_h) catch |err| {
            std.debug.print("{s}: decoded picture unusable ({t})\n", .{ c.name, err });
            failed = true;
            continue;
        };
        // The bar: the same picture through ImageIO's own encoder at the same quality.
        const ref_cmp = imageIoRoundTrip(gpa, io, init.arena.allocator(), dir_path, c, ref) catch null;
        if (ref_cmp) |rc| std.debug.print("{s}: ImageIO's own encoder: mean error {d:.2}, PSNR {d:.1} dB\n", .{ c.name, rc.mean, rc.psnr });
        const ok = cmp.mean <= c.max_mean and cmp.psnr >= c.min_psnr;
        if (!ok) failed = true;
        std.debug.print("{s}: {d} bytes, decoded by ImageIO: mean error {d:.2}, PSNR {d:.1} dB, max {d} — {s}\n", .{ c.name, jpg.len, cmp.mean, cmp.psnr, cmp.max, if (ok) "ok" else "FAIL" });
    }
    if (failed) {
        std.debug.print("jpeg-check: FAILED\n", .{});
        std.process.exit(1);
    }
    std.debug.print("jpeg-check: all ok\n", .{});
}

/// Something like a desktop: flat panels, a gradient wallpaper, "text" (thin dark strokes), a noisy photo.
fn desktop(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    for (0..h) |y| {
        for (0..w) |x| {
            const p = px[(y * w + x) * 4 ..][0..4];
            var b: u8 = @truncate(40 + x * 120 / w);
            var g: u8 = @truncate(60 + y * 100 / h);
            var r: u8 = 90;
            if (y < h / 20) { // a title bar
                b = 235;
                g = 235;
                r = 235;
            } else if (x > w / 10 and x < w / 2 and y > h / 8 and y < h * 7 / 8) { // a window with text
                b = 250;
                g = 250;
                r = 250;
                const ty = y % 18;
                if (ty > 4 and ty < 14 and (x / 3 + y / 18) % 7 != 0 and (x % 5 == 0 or ty == 9)) {
                    b = 30;
                    g = 30;
                    r = 30;
                }
            } else if (x > w * 6 / 10 and y > h / 4 and y < h * 3 / 4) { // a photo
                const n = rnd.int(u8) / 8;
                b = @truncate((x * 3 + y) % 200 + n);
                g = @truncate((x + y * 2) % 180 + n);
                r = @truncate((x * 2 + y * 3) % 220 + n);
            }
            p.* = .{ b, g, r, 0 };
        }
    }
    return px;
}

fn boxScale(gpa: std.mem.Allocator, px: []const u8, w: u32, h: u32, ow: u32, oh: u32) ![]u8 {
    const out = try gpa.alloc(u8, @as(usize, ow) * oh * 4);
    const fx = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(ow));
    const fy = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(oh));
    for (0..oh) |y| {
        for (0..ow) |x| {
            const sx = (@as(f64, @floatFromInt(x)) + 0.5) * fx - 0.5;
            const sy = (@as(f64, @floatFromInt(y)) + 0.5) * fy - 0.5;
            const x0: usize = @intFromFloat(@max(0, @floor(sx)));
            const y0: usize = @intFromFloat(@max(0, @floor(sy)));
            const x1 = @min(w - 1, x0 + 1);
            const y1 = @min(h - 1, y0 + 1);
            const ax = sx - @as(f64, @floatFromInt(x0));
            const ay = sy - @as(f64, @floatFromInt(y0));
            for (0..3) |ch| {
                const a: f64 = @floatFromInt(px[(y0 * w + x0) * 4 + ch]);
                const b: f64 = @floatFromInt(px[(y0 * w + x1) * 4 + ch]);
                const c: f64 = @floatFromInt(px[(y1 * w + x0) * 4 + ch]);
                const d: f64 = @floatFromInt(px[(y1 * w + x1) * 4 + ch]);
                const top = a + (b - a) * ax;
                const bot = c + (d - c) * ax;
                out[(y * ow + x) * 4 + ch] = @intFromFloat(@round(top + (bot - top) * ay));
            }
            out[(y * ow + x) * 4 + 3] = 0;
        }
    }
    return out;
}

const Cmp = struct { mean: f64, psnr: f64, max: u32 };

/// Compares a BMP (24 or 32 bits, either row order) with BGRX pixels.
fn compare(bmp: []const u8, ref: []const u8, w: u32, h: u32) !Cmp {
    if (bmp.len < 54 or bmp[0] != 'B' or bmp[1] != 'M') return error.NotBmp;
    const off = std.mem.readInt(u32, bmp[10..14], .little);
    const bw = std.mem.readInt(i32, bmp[18..22], .little);
    const bh = std.mem.readInt(i32, bmp[22..26], .little);
    const bpp = std.mem.readInt(u16, bmp[28..30], .little);
    if (bw != w or @abs(bh) != h) return error.WrongSize;
    if (bpp != 24 and bpp != 32) return error.UnsupportedBmp;
    const bytes_pp: usize = bpp / 8;
    const row_len = (@as(usize, w) * bytes_pp + 3) / 4 * 4;
    if (bmp.len < off + row_len * h) return error.Truncated;
    var sum: f64 = 0;
    var sq: f64 = 0;
    var max: u32 = 0;
    for (0..h) |y| {
        const by = if (bh > 0) h - 1 - y else y;
        const row = bmp[off + by * row_len ..];
        for (0..w) |x| {
            for (0..3) |ch| {
                const a: i32 = row[x * bytes_pp + ch];
                const b: i32 = ref[(y * w + x) * 4 + ch];
                const d: u32 = @abs(a - b);
                sum += @floatFromInt(d);
                sq += @floatFromInt(d * d);
                max = @max(max, d);
            }
        }
    }
    const n: f64 = @floatFromInt(@as(u64, w) * h * 3);
    const mse = sq / n;
    return .{ .mean = sum / n, .psnr = if (mse == 0) 99 else 10 * std.math.log10(255.0 * 255.0 / mse), .max = max };
}

/// Writes `ref` as a BMP, has sips encode it as JPEG at the case's quality and decode it again.
fn imageIoRoundTrip(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, dir: []const u8, c: Case, ref: []const u8) !Cmp {
    const w = c.out_w;
    const h = c.out_h;
    const row_len = (@as(usize, w) * 3 + 3) / 4 * 4;
    const bmp = try gpa.alloc(u8, 54 + row_len * h);
    defer gpa.free(bmp);
    @memset(bmp, 0);
    bmp[0] = 'B';
    bmp[1] = 'M';
    std.mem.writeInt(u32, bmp[2..6], @intCast(bmp.len), .little);
    std.mem.writeInt(u32, bmp[10..14], 54, .little);
    std.mem.writeInt(u32, bmp[14..18], 40, .little);
    std.mem.writeInt(i32, bmp[18..22], @intCast(w), .little);
    std.mem.writeInt(i32, bmp[22..26], -@as(i32, @intCast(h)), .little);
    std.mem.writeInt(u16, bmp[26..28], 1, .little);
    std.mem.writeInt(u16, bmp[28..30], 24, .little);
    for (0..h) |y| {
        for (0..w) |x| @memcpy(bmp[54 + y * row_len + x * 3 ..][0..3], ref[(y * w + x) * 4 ..][0..3]);
    }
    const src = try std.fmt.allocPrint(arena, "{s}/{s}-src.bmp", .{ dir, c.name });
    const jpg = try std.fmt.allocPrint(arena, "{s}/{s}-imageio.jpg", .{ dir, c.name });
    const back = try std.fmt.allocPrint(arena, "{s}/{s}-imageio.bmp", .{ dir, c.name });
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = src, .data = bmp });
    const q = try std.fmt.allocPrint(arena, "{d}", .{c.quality});
    for ([_][]const []const u8{
        &.{ "sips", "-s", "format", "jpeg", "-s", "formatOptions", q, src, "--out", jpg },
        &.{ "sips", "-s", "format", "bmp", jpg, "--out", back },
    }) |argv| {
        const r = try std.process.run(gpa, io, .{ .argv = argv });
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    const dec = try cwd.readFileAlloc(io, back, gpa, .limited(64 << 20));
    defer gpa.free(dec);
    return compare(dec, ref, w, h);
}
