//! Update manifest: latest.json in the GitHub release + its signature latest.json.sig.
//! RDC trusts only a manifest whose Ed25519 signature matches the built-in key,
//! and only an archive whose size and SHA-256 match the manifest.
const std = @import("std");
const builtin = @import("builtin");
const update_key = @import("update_key.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_manifest = 64 * 1024;
pub const max_asset = 256 * 1024 * 1024;

pub const Asset = struct {
    platform: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,
};

pub const Manifest = struct {
    version: []const u8,
    notes: []const u8 = "",
    assets: []const Asset = &.{},
};

/// This build's platform in manifest terms: macos-arm64, windows-x86_64…
pub const platform = std.fmt.comptimePrint("{s}-{s}", .{
    switch (builtin.os.tag) {
        .macos => "macos",
        .windows => "windows",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    },
    switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => @tagName(builtin.cpu.arch),
    },
});

pub const Error = error{ BadSignature, BadManifest, NoAssetForPlatform, AssetMismatch };

/// Verifies the manifest signature (the signature text is base64 of 64 bytes).
pub fn verify(manifest_bytes: []const u8, sig_text: []const u8) Error!void {
    return verifyWith(manifest_bytes, sig_text, update_key.public_key_hex);
}

pub fn verifyWith(manifest_bytes: []const u8, sig_text: []const u8, public_hex: []const u8) Error!void {
    var pk_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk_bytes, public_hex) catch return error.BadSignature;
    const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch return error.BadSignature;
    var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    const trimmed = std.mem.trim(u8, sig_text, " \t\r\n");
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(trimmed) catch return error.BadSignature;
    if (n != sig_bytes.len) return error.BadSignature;
    decoder.decode(&sig_bytes, trimmed) catch return error.BadSignature;
    Ed25519.Signature.fromBytes(sig_bytes).verify(manifest_bytes, pk) catch return error.BadSignature;
}

/// Parses an already verified manifest. Strings point into the arena.
pub fn parse(arena: std.mem.Allocator, manifest_bytes: []const u8) Error!Manifest {
    return std.json.parseFromSliceLeaky(Manifest, arena, manifest_bytes, .{ .ignore_unknown_fields = true }) catch error.BadManifest;
}

pub fn assetFor(m: Manifest, plat: []const u8) Error!Asset {
    for (m.assets) |a| {
        if (std.mem.eql(u8, a.platform, plat)) {
            if (a.size == 0 or a.size > max_asset or a.sha256.len != 64) return error.BadManifest;
            if (std.mem.indexOfAny(u8, a.file, "/\\") != null or a.file.len == 0) return error.BadManifest;
            return a;
        }
    }
    return error.NoAssetForPlatform;
}

/// Checks that the downloaded archive is the one in the manifest.
pub fn checkAsset(a: Asset, data: []const u8) Error!void {
    if (data.len != a.size) return error.AssetMismatch;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&hex, a.sha256)) return error.AssetMismatch;
}

// ---------------------------------------------------------------------------
// Versions X.Y.Z (a leading "v" is allowed)

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) ?Version {
        var s = std.mem.trim(u8, text, " \t\r\n");
        if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
        if (std.mem.indexOfAny(u8, s, "-+")) |i| s = s[0..i];
        var it = std.mem.splitScalar(u8, s, '.');
        var parts: [3]u32 = .{ 0, 0, 0 };
        var count: usize = 0;
        while (it.next()) |p| {
            if (count == 3) return null;
            parts[count] = std.fmt.parseInt(u32, p, 10) catch return null;
            count += 1;
        }
        if (count == 0) return null;
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    pub fn newerThan(a: Version, b: Version) bool {
        if (a.major != b.major) return a.major > b.major;
        if (a.minor != b.minor) return a.minor > b.minor;
        return a.patch > b.patch;
    }
};

test "versions" {
    const v = Version.parse("v0.2.10").?;
    try std.testing.expectEqual(@as(u32, 10), v.patch);
    try std.testing.expect(Version.parse("0.3.0").?.newerThan(Version.parse("0.2.9").?));
    try std.testing.expect(!Version.parse("0.2.0").?.newerThan(Version.parse("0.2.0").?));
    try std.testing.expect(Version.parse("1.0.0").?.newerThan(Version.parse("0.99.99").?));
    try std.testing.expectEqual(@as(?Version, null), Version.parse("x.y"));
    try std.testing.expectEqual(@as(?Version, null), Version.parse("1.2.3.4"));
}

test "manifest: signature, parsing, archive" {
    const kp = Ed25519.KeyPair.generateDeterministic(@splat(7)) catch unreachable;
    const public_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    const data = "archive";
    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    var buf: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf, "{{\"version\":\"0.3.0\",\"notes\":\"n\",\"extra\":1,\"assets\":[{{\"platform\":\"macos-arm64\",\"file\":\"RDC.zip\",\"size\":{d},\"sha256\":\"{s}\"}}]}}", .{ data.len, &std.fmt.bytesToHex(digest, .lower) });
    const sig = try kp.sign(json, null);
    var b64: [88]u8 = undefined;
    const sig_text = std.base64.standard.Encoder.encode(&b64, &sig.toBytes());

    try verifyWith(json, sig_text, &public_hex);
    var tampered = buf;
    tampered[15] ^= 1;
    try std.testing.expectError(error.BadSignature, verifyWith(tampered[0..json.len], sig_text, &public_hex));
    try std.testing.expectError(error.BadSignature, verifyWith(json, "AAAA", &public_hex));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try parse(arena_state.allocator(), json);
    try std.testing.expectEqualStrings("0.3.0", m.version);
    const a = try assetFor(m, "macos-arm64");
    try checkAsset(a, data);
    try std.testing.expectError(error.AssetMismatch, checkAsset(a, "foreign"));
    try std.testing.expectError(error.NoAssetForPlatform, assetFor(m, "windows-x86_64"));
}
