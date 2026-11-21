//! The Linux host's JPEG encoder (src/core/jpeg.zig) for the C shim (x11.c): one encoder per
//! capture thread, its output reused from frame to frame.
const std = @import("std");
const jpeg = @import("jpeg");

const gpa = std.heap.c_allocator;

export fn rdc_linux_jpeg_new(quality: c_int) ?*jpeg.Encoder {
    const e = gpa.create(jpeg.Encoder) catch return null;
    e.* = .init(gpa, @intCast(std.math.clamp(quality, 1, 100)));
    return e;
}

export fn rdc_linux_jpeg_free(e: ?*jpeg.Encoder) void {
    const enc = e orelse return;
    enc.deinit();
    gpa.destroy(enc);
}

export fn rdc_linux_jpeg_quality(e: *jpeg.Encoder, quality: c_int) void {
    e.setQuality(@intCast(std.math.clamp(quality, 1, 100)));
}

/// Encodes 32-bit pixels (rgbx != 0: bytes R, G, B, X; otherwise B, G, R, X) scaled to out_w × out_h.
/// 0 — the JPEG is at *out, valid until the next call on this encoder; -1 — failed.
export fn rdc_linux_jpeg_encode(
    e: *jpeg.Encoder,
    pixels: [*]const u8,
    width: c_int,
    height: c_int,
    stride: c_int,
    rgbx: c_int,
    out_w: c_int,
    out_h: c_int,
    out: *[*]const u8,
    out_len: *usize,
) c_int {
    if (width <= 0 or height <= 0 or stride < width * 4 or out_w <= 0 or out_h <= 0) return -1;
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    const s: usize = @intCast(stride);
    const img: jpeg.Image = .{
        .pixels = pixels[0 .. s * (h - 1) + @as(usize, w) * 4],
        .width = w,
        .height = h,
        .stride = s,
        .format = if (rgbx != 0) .rgbx else .bgrx,
    };
    const data = e.encode(img, @intCast(out_w), @intCast(out_h)) catch return -1;
    out.* = data.ptr;
    out_len.* = data.len;
    return 0;
}
