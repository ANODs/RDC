//! Автообновление из релизов GitHub.
//!
//! Через 15 с после запуска и дальше раз в 6 часов RDC скачивает latest.json и
//! latest.json.sig из последнего релиза, проверяет подпись вшитым ключом Ed25519 и,
//! если версия новее, скачивает архив своей платформы, сверяет размер и SHA-256 и
//! ставит его, когда к компьютеру никто не подключён (сессии не рвутся). Вручную —
//! «Настройки → Обновить и перезапустить». Сборки из zig-out сами не обновляются.
const std = @import("std");
const c = std.c;
const mac = @import("platform/macos.zig");
const manifest = @import("core/manifest.zig");
const build_options = @import("build_options");

pub const current_version: []const u8 = build_options.version;

const releases = "https://github.com/ANODs/RDC/releases";
const first_check_us: u64 = 15 * 1_000_000;
const check_interval_us: u64 = 6 * 3600 * 1_000_000;
const pref_auto = "autoUpdate";

const log = @import("host.zig").log;

pub const State = enum { idle, checking, up_to_date, available, downloading, installing, failed };

pub const Updater = struct {
    gpa: std.mem.Allocator,
    base_url: ?[]const u8,
    ui: bool,
    mutex: c.pthread_mutex_t = .{},
    state: State = .idle,
    busy: bool = false,
    auto: bool = true,
    dev_build: bool = false,
    started_us: u64,
    last_check_us: u64 = 0,
    latest: [32]u8 = undefined,
    latest_len: usize = 0,
    file: [128]u8 = undefined,
    file_len: usize = 0,
    sha: [64]u8 = undefined,
    size: u64 = 0,
    message: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, base_url: ?[]const u8, ui: bool) Updater {
        var u: Updater = .{ .gpa = gpa, .base_url = base_url, .ui = ui, .started_us = mac.rdc_mac_now_us() };
        u.auto = mac.rdc_mac_pref_bool(pref_auto, 1) != 0;
        var path: [1024]u8 = undefined;
        if (mac.rdc_mac_bundle_path(&path, path.len) != 0) {
            u.dev_build = true; // не из бандла — менять нечего
        } else {
            const p = path[0 .. std.mem.indexOfScalar(u8, &path, 0) orelse 0];
            u.dev_build = std.mem.indexOf(u8, p, "/zig-out/") != null;
        }
        mac.rdc_mac_cleanup_old_bundles();
        u.setMessage("Установлена версия {s}", .{current_version});
        return u;
    }

    fn lock(u: *Updater) void {
        _ = c.pthread_mutex_lock(&u.mutex);
    }
    fn unlock(u: *Updater) void {
        _ = c.pthread_mutex_unlock(&u.mutex);
    }

    fn setMessage(u: *Updater, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(u.message[0 .. u.message.len - 1], fmt, args) catch u.message[0..0];
        u.message_len = s.len;
    }

    fn latestVersion(u: *const Updater) []const u8 {
        return u.latest[0..u.latest_len];
    }

    /// Вызывается раз в секунду из потока обслуживания.
    pub fn tick(u: *Updater, viewers: usize) void {
        const now = mac.rdc_mac_now_us();
        u.lock();
        const due = if (u.last_check_us == 0) now - u.started_us >= first_check_us else now - u.last_check_us >= check_interval_us;
        const check = u.auto and !u.busy and due;
        const install = u.auto and !u.dev_build and !u.busy and u.state == .available and viewers == 0;
        if (check or install) u.busy = true;
        u.unlock();
        if (check) u.spawn(checkThread) else if (install) u.spawn(installThread);
    }

    pub fn checkNow(u: *Updater) void {
        u.lock();
        const go = !u.busy;
        if (go) u.busy = true;
        u.unlock();
        if (go) u.spawn(checkThread);
    }

    pub fn installNow(u: *Updater) void {
        u.lock();
        const go = !u.busy and u.state == .available;
        if (go) u.busy = true;
        u.unlock();
        if (go) u.spawn(installThread);
    }

    pub fn setAuto(u: *Updater, on: bool) void {
        u.lock();
        u.auto = on;
        u.unlock();
        mac.rdc_mac_set_pref_bool(pref_auto, @intFromBool(on));
        u.publish();
    }

    fn spawn(u: *Updater, comptime f: fn (*Updater) void) void {
        const t = std.Thread.spawn(.{}, f, .{u}) catch {
            u.lock();
            u.busy = false;
            u.unlock();
            return;
        };
        t.detach();
    }

    /// Показывает состояние в окне «Настройки».
    pub fn publish(u: *Updater) void {
        if (!u.ui) return;
        var msg: [257]u8 = undefined;
        var ver: [33]u8 = undefined;
        u.lock();
        @memcpy(msg[0..u.message_len], u.message[0..u.message_len]);
        msg[u.message_len] = 0;
        const can_install = u.state == .available;
        const busy = u.busy;
        const auto = u.auto;
        const msg_len = u.message_len;
        u.unlock();
        @memcpy(ver[0..current_version.len], current_version);
        ver[current_version.len] = 0;
        mac.rdc_mac_settings_update(ver[0..current_version.len :0].ptr, @intFromBool(auto), msg[0..msg_len :0].ptr, @intFromBool(can_install), @intFromBool(busy));
    }

    fn finish(u: *Updater, state: State, comptime fmt: []const u8, args: anytype) void {
        u.lock();
        u.state = state;
        u.busy = false;
        u.setMessage(fmt, args);
        u.unlock();
        log("обновление: " ++ fmt, args);
        u.publish();
    }

    fn progress(u: *Updater, state: State, comptime fmt: []const u8, args: anytype) void {
        u.lock();
        u.state = state;
        u.setMessage(fmt, args);
        u.unlock();
        u.publish();
    }

    const FetchError = error{ Network, NotFound, Http, TooLarge, OutOfMemory };

    fn fetch(u: *Updater, arena: std.mem.Allocator, url: []const u8, max: usize) FetchError![]u8 {
        _ = u;
        const url_z = try arena.dupeSentinel(u8, url, 0);
        var len: usize = 0;
        var status: c_int = -1;
        const ptr = mac.rdc_mac_http_get(url_z.ptr, max, &len, &status) orelse {
            if (status == 404) return error.NotFound;
            if (status == 200) return error.TooLarge;
            return if (status < 0) error.Network else error.Http;
        };
        defer c.free(ptr);
        if (status == 404) return error.NotFound;
        if (status != 200) return error.Http;
        return arena.dupe(u8, ptr[0..len]);
    }

    fn urlFor(u: *Updater, arena: std.mem.Allocator, name: []const u8, version: ?[]const u8) ![]u8 {
        if (u.base_url) |b| return std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, b, "/"), name });
        if (version) |v| return std.fmt.allocPrint(arena, releases ++ "/download/v{s}/{s}", .{ v, name });
        return std.fmt.allocPrint(arena, releases ++ "/latest/download/{s}", .{name});
    }

    fn checkThread(u: *Updater) void {
        u.lock();
        u.last_check_us = mac.rdc_mac_now_us();
        u.unlock();
        u.progress(.checking, "Проверяю обновления…", .{});
        var arena_state = std.heap.ArenaAllocator.init(u.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const man_url = u.urlFor(arena, "latest.json", null) catch return u.finish(.failed, "нет памяти", .{});
        const sig_url = u.urlFor(arena, "latest.json.sig", null) catch return u.finish(.failed, "нет памяти", .{});
        const body = u.fetch(arena, man_url, manifest.max_manifest) catch |e| return u.fetchFailed(e);
        const sig = u.fetch(arena, sig_url, 1024) catch |e| return u.fetchFailed(e);
        manifest.verify(body, sig) catch return u.finish(.failed, "подпись обновления не сошлась — обновление отклонено", .{});
        const m = manifest.parse(arena, body) catch return u.finish(.failed, "манифест обновления повреждён", .{});
        const latest = manifest.Version.parse(m.version) orelse return u.finish(.failed, "непонятная версия в манифесте: {s}", .{m.version});
        const current = manifest.Version.parse(current_version) orelse unreachable;
        if (!latest.newerThan(current)) return u.finish(.up_to_date, "Установлена последняя версия ({s})", .{current_version});
        const asset = manifest.assetFor(m, manifest.platform) catch return u.finish(.failed, "в релизе {s} нет сборки для {s}", .{ m.version, manifest.platform });
        if (m.version.len > u.latest.len or asset.file.len > u.file.len) return u.finish(.failed, "манифест обновления повреждён", .{});

        u.lock();
        @memcpy(u.latest[0..m.version.len], m.version);
        u.latest_len = m.version.len;
        @memcpy(u.file[0..asset.file.len], asset.file);
        u.file_len = asset.file.len;
        @memcpy(&u.sha, asset.sha256[0..64]);
        u.size = asset.size;
        const auto = u.auto and !u.dev_build;
        u.unlock();
        if (auto)
            u.finish(.available, "Доступна версия {s} — установится, когда никто не подключён", .{m.version})
        else
            u.finish(.available, "Доступна версия {s}", .{m.version});
    }

    fn fetchFailed(u: *Updater, e: FetchError) void {
        switch (e) {
            error.NotFound => u.finish(.up_to_date, "Релизов на GitHub пока нет", .{}),
            error.Network => u.finish(.failed, "нет связи с GitHub", .{}),
            else => u.finish(.failed, "GitHub ответил ошибкой ({t})", .{e}),
        }
    }

    fn installThread(u: *Updater) void {
        var version_buf: [33]u8 = undefined;
        var file_buf: [129]u8 = undefined;
        u.lock();
        const version = version_buf[0..u.latest_len];
        @memcpy(version, u.latest[0..u.latest_len]);
        version_buf[u.latest_len] = 0;
        const file = file_buf[0..u.file_len];
        @memcpy(file, u.file[0..u.file_len]);
        file_buf[u.file_len] = 0;
        const asset: manifest.Asset = .{ .platform = manifest.platform, .file = file, .size = u.size, .sha256 = &u.sha };
        u.unlock();

        u.progress(.downloading, "Скачиваю версию {s}…", .{version});
        var arena_state = std.heap.ArenaAllocator.init(u.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const asset_url = u.urlFor(arena, file, version) catch return u.finish(.available, "нет памяти", .{});
        const data = u.fetch(arena, asset_url, @intCast(@min(asset.size + 1, manifest.max_asset))) catch |e| {
            u.lock();
            u.busy = false;
            u.unlock();
            return u.finish(.available, "Не удалось скачать версию {s} ({t}) — попробую позже", .{ version, e });
        };
        manifest.checkAsset(asset, data) catch return u.finish(.failed, "архив {s} не совпал с манифестом — отклонён", .{version});

        var path: [1024]u8 = undefined;
        if (mac.rdc_mac_write_temp(file_buf[0..file.len :0].ptr, data.ptr, data.len, &path, path.len) != 0)
            return u.finish(.available, "не записать архив во временную папку", .{});
        u.progress(.installing, "Устанавливаю версию {s} и перезапускаю…", .{version});
        log("обновление: ставлю {s}", .{version});
        const rc = mac.rdc_mac_install_update(@ptrCast(&path), version_buf[0..version.len :0].ptr);
        // Сюда попадаем только при ошибке: при успехе процесс перезапускается.
        u.finish(.failed, "не удалось установить версию {s} (код {d}) — подробности в журнале", .{ version, rc });
    }
};
