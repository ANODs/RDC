//! RDC — Remote Desktop Control. Точка входа.
const std = @import("std");
const host = @import("host.zig");
const mac = @import("platform/macos.zig");

const usage =
    \\RDC — удалённый рабочий стол
    \\
    \\  rdc [host] [параметры]   показать этот компьютер по ссылке или коду
    \\  rdc version              версия
    \\
    \\Параметры:
    \\  --port N        порт (по умолчанию 7700)
    \\  --max-width N   ширина картинки (по умолчанию 1920)
    \\  --fps N         кадров в секунду (по умолчанию 60)
    \\  --no-ui         без окна: код и ссылка — в журнале
    \\  --web-dir DIR   для разработки: страница зрителя с диска (DIR — папка web)
    \\  --update-url U  для проверки: обновления из U, а не из релизов GitHub
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var opts: host.Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const eql = std.mem.eql;
        if (eql(u8, a, "host")) {
            continue;
        } else if (eql(u8, a, "--no-ui")) {
            opts.ui = false;
        } else if (eql(u8, a, "version") or eql(u8, a, "--version")) {
            host.log("RDC {s}", .{host.version});
            return;
        } else if (i + 1 < args.len and eql(u8, a, "--port")) {
            i += 1;
            opts.port = std.fmt.parseInt(u16, args[i], 10) catch return printUsage();
        } else if (i + 1 < args.len and eql(u8, a, "--max-width")) {
            i += 1;
            opts.max_width = std.fmt.parseInt(c_int, args[i], 10) catch return printUsage();
        } else if (i + 1 < args.len and eql(u8, a, "--fps")) {
            i += 1;
            opts.fps = std.fmt.parseInt(c_int, args[i], 10) catch return printUsage();
        } else if (i + 1 < args.len and eql(u8, a, "--web-dir")) {
            i += 1;
            opts.web_dir = args[i];
        } else if (i + 1 < args.len and eql(u8, a, "--update-url")) {
            i += 1;
            opts.update_url = args[i];
        } else if (std.mem.startsWith(u8, a, "-psn_")) {
            continue; // Finder иногда передаёт номер процесса
        } else {
            return printUsage();
        }
    }
    mac.rdc_mac_init();
    try host.run(init.gpa, opts);
}

fn printUsage() void {
    mac.rdc_mac_log(usage);
}

test {
    _ = @import("core/code.zig");
    _ = @import("core/keymap.zig");
    _ = @import("core/proto.zig");
    _ = @import("net/ws.zig");
    _ = @import("net/http.zig");
}
