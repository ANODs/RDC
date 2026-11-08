//! Инструмент релизов RDC: ключ подписи обновлений и подписанный манифест.
//!
//!   zig run tools/release.zig -- keygen <файл-секрета>
//!   zig run tools/release.zig -- manifest <версия> <папка-вывода> <заметки.md|-> <платформа>=<архив> ...
//!
//! Секрет берётся из переменной RDC_UPDATE_KEY (hex, 128 знаков) или из файла
//! ~/.config/rdc/update-signing.key. Открытый ключ вшит в RDC (src/core/update_key.zig):
//! RDC ставит обновление, только если подпись latest.json сошлась с ним.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

const usage =
    \\использование:
    \\  release keygen <файл-секрета>
    \\  release manifest <версия> <папка-вывода> <заметки.md|-> <платформа>=<архив> ...
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return fail(usage, .{});
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "keygen") and args.len == 3) return keygen(io, args[2]);
    if (std.mem.eql(u8, cmd, "manifest") and args.len >= 6) return manifest(io, arena, init.environ_map, args[2], args[3], args[4], args[5..]);
    return fail(usage, .{});
}

fn fail(comptime fmt: []const u8, args: anytype) error{Failed} {
    std.debug.print(fmt, args);
    return error.Failed;
}

fn keygen(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};
    const kp = Ed25519.KeyPair.generate(io);
    const secret = std.fmt.bytesToHex(kp.secret_key.toBytes(), .lower);
    cwd.writeFile(io, .{
        .sub_path = path,
        .data = &(secret ++ [_]u8{'\n'}),
        .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) },
    }) catch |err| return fail("не записать {s}: {t} (ключ уже есть?)\n", .{ path, err });
    const public = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    std.debug.print("секрет: {s}\nоткрытый ключ: {s}\n", .{ path, &public });
}

fn loadKey(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) !Ed25519.KeyPair {
    var text: []const u8 = env.get("RDC_UPDATE_KEY") orelse "";
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        const home = env.get("HOME") orelse return fail("нет HOME и RDC_UPDATE_KEY\n", .{});
        const path = try std.fs.path.join(arena, &.{ home, ".config/rdc/update-signing.key" });
        text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024)) catch |err|
            return fail("нет ключа подписи: {s} ({t}) и RDC_UPDATE_KEY пуст\n", .{ path, err });
    }
    var bytes: [Ed25519.SecretKey.encoded_length]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&bytes, std.mem.trim(u8, text, " \t\r\n")) catch return fail("ключ подписи — не hex\n", .{});
    if (decoded.len != bytes.len) return fail("ключ подписи — не 64 байта\n", .{});
    return Ed25519.KeyPair.fromSecretKey(try Ed25519.SecretKey.fromBytes(bytes));
}

fn appendJsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => {},
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (ch >= 0x20) try out.append(gpa, ch),
    };
    try out.append(gpa, '"');
}

fn manifest(
    io: std.Io,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    version: []const u8,
    out_dir: []const u8,
    notes_path: []const u8,
    assets: []const [:0]const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_dir);
    const kp = try loadKey(io, arena, env);
    const notes: []const u8 = if (std.mem.eql(u8, notes_path, "-")) "" else cwd.readFileAlloc(io, notes_path, arena, .limited(64 * 1024)) catch "";

    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(arena, "{\n  \"version\": ");
    try appendJsonString(&json, arena, version);
    try json.appendSlice(arena, ",\n  \"notes\": ");
    try appendJsonString(&json, arena, std.mem.trim(u8, notes, " \t\r\n"));
    try json.appendSlice(arena, ",\n  \"assets\": [");

    for (assets, 0..) |spec, i| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return fail("ожидалось платформа=архив: {s}\n", .{spec});
        const platform = spec[0..eq];
        const path = spec[eq + 1 ..];
        const data = cwd.readFileAlloc(io, path, arena, .limited(512 * 1024 * 1024)) catch |err| return fail("не прочитать {s}: {t}\n", .{ path, err });
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(data, &digest, .{});
        const name = std.fs.path.basename(path);
        const dest = try std.fs.path.join(arena, &.{ out_dir, name });
        try cwd.writeFile(io, .{ .sub_path = dest, .data = data });

        try json.appendSlice(arena, if (i == 0) "\n    {\"platform\": " else ",\n    {\"platform\": ");
        try appendJsonString(&json, arena, platform);
        try json.appendSlice(arena, ", \"file\": ");
        try appendJsonString(&json, arena, name);
        try json.print(arena, ", \"size\": {d}, \"sha256\": \"{s}\"}}", .{ data.len, &std.fmt.bytesToHex(digest, .lower) });
        std.debug.print("{s}: {s} ({d} Б)\n", .{ platform, name, data.len });
    }
    try json.appendSlice(arena, "\n  ]\n}\n");

    const sig = try kp.sign(json.items, null);
    var b64: [std.base64.standard.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    const sig_text = std.base64.standard.Encoder.encode(&b64, &sig.toBytes());

    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ out_dir, "latest.json" }), .data = json.items });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ out_dir, "latest.json.sig" }), .data = try std.mem.concat(arena, u8, &.{ sig_text, "\n" }) });
    const public = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    std.debug.print("latest.json подписан ключом {s}\n", .{&public});
}
