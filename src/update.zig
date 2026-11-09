//! Auto-update from GitHub releases.
//!
//! 15 s after launch and then every 6 hours, RDC downloads latest.json and
//! latest.json.sig from the latest release, verifies the signature with the built-in
//! Ed25519 key and, if the version is newer, downloads the archive for its platform,
//! checks its size and SHA-256 and installs it when nobody is connected (sessions are
//! not cut off). Manually: "Settings → Update and Restart". zig-out builds do not self-update.
const std = @import("std");
const plat = @import("platform.zig");
const manifest = @import("core/manifest.zig");
const build_options = @import("build_options");

pub const current_version: []const u8 = build_options.version;

const releases = "https://github.com/ANODs/RDC/releases";
const first_check_us: u64 = 15 * 1_000_000;
const check_interval_us: u64 = 6 * 3600 * 1_000_000;
const pref_auto = "autoUpdate";

const host = @import("host.zig");
const log = host.log;

pub const State = enum { idle, checking, up_to_date, available, downloading, installing, failed };

pub const Updater = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_url: ?[]const u8,
    ui: bool,
    mutex: std.Io.Mutex = .init,
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

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base_url: ?[]const u8, ui: bool) Updater {
        var u: Updater = .{ .gpa = gpa, .io = io, .base_url = base_url, .ui = ui, .started_us = host.nowUs(io) };
        u.auto = plat.rdc_pref_bool(pref_auto, 1) != 0;
        var path: [1024]u8 = undefined;
        if (plat.rdc_install_path(&path, path.len) != 0) {
            u.dev_build = true; // not an installed copy — nothing to replace
        } else {
            const p = path[0 .. std.mem.indexOfScalar(u8, &path, 0) orelse 0];
            u.dev_build = std.mem.indexOf(u8, p, "/zig-out/") != null or std.mem.indexOf(u8, p, "\\zig-out\\") != null;
        }
        plat.rdc_cleanup_old_install();
        u.setMessage("Version {s} is installed", .{current_version});
        return u;
    }

    fn lock(u: *Updater) void {
        u.mutex.lockUncancelable(u.io);
    }
    fn unlock(u: *Updater) void {
        u.mutex.unlock(u.io);
    }

    fn setMessage(u: *Updater, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(u.message[0 .. u.message.len - 1], fmt, args) catch u.message[0..0];
        u.message_len = s.len;
    }

    fn latestVersion(u: *const Updater) []const u8 {
        return u.latest[0..u.latest_len];
    }

    /// Called once a second from the housekeeping thread.
    pub fn tick(u: *Updater, viewers: usize) void {
        const now = host.nowUs(u.io);
        u.lock();
        const due = if (u.last_check_us == 0) now -| u.started_us >= first_check_us else now -| u.last_check_us >= check_interval_us;
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
        plat.rdc_set_pref_bool(pref_auto, @intFromBool(on));
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

    /// Shows the state in the Settings window.
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
        plat.rdc_settings_update(ver[0..current_version.len :0].ptr, @intFromBool(auto), msg[0..msg_len :0].ptr, @intFromBool(can_install), @intFromBool(busy));
    }

    fn finish(u: *Updater, state: State, comptime fmt: []const u8, args: anytype) void {
        u.lock();
        u.state = state;
        u.busy = false;
        u.setMessage(fmt, args);
        u.unlock();
        log("update: " ++ fmt, args);
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
        const ptr = plat.rdc_http_get(url_z.ptr, max, &len, &status) orelse {
            if (status == 404) return error.NotFound;
            if (status == 200) return error.TooLarge;
            return if (status < 0) error.Network else error.Http;
        };
        defer plat.free(ptr);
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
        u.last_check_us = host.nowUs(u.io);
        u.unlock();
        u.progress(.checking, "Checking for updates…", .{});
        var arena_state = std.heap.ArenaAllocator.init(u.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const man_url = u.urlFor(arena, "latest.json", null) catch return u.finish(.failed, "out of memory", .{});
        const sig_url = u.urlFor(arena, "latest.json.sig", null) catch return u.finish(.failed, "out of memory", .{});
        const body = u.fetch(arena, man_url, manifest.max_manifest) catch |e| return u.fetchFailed(e);
        const sig = u.fetch(arena, sig_url, 1024) catch |e| return u.fetchFailed(e);
        manifest.verify(body, sig) catch return u.finish(.failed, "update signature does not match — update rejected", .{});
        const m = manifest.parse(arena, body) catch return u.finish(.failed, "update manifest is corrupt", .{});
        const latest = manifest.Version.parse(m.version) orelse return u.finish(.failed, "unrecognized version in the manifest: {s}", .{m.version});
        const current = manifest.Version.parse(current_version) orelse unreachable;
        if (!latest.newerThan(current)) return u.finish(.up_to_date, "The latest version is installed ({s})", .{current_version});
        const asset = manifest.assetFor(m, manifest.platform) catch return u.finish(.failed, "release {s} has no build for {s}", .{ m.version, manifest.platform });
        if (m.version.len > u.latest.len or asset.file.len > u.file.len) return u.finish(.failed, "update manifest is corrupt", .{});

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
            u.finish(.available, "Version {s} is available — it will install when nobody is connected", .{m.version})
        else
            u.finish(.available, "Version {s} is available", .{m.version});
    }

    fn fetchFailed(u: *Updater, e: FetchError) void {
        switch (e) {
            error.NotFound => u.finish(.up_to_date, "No releases on GitHub yet", .{}),
            error.Network => u.finish(.failed, "cannot reach GitHub", .{}),
            else => u.finish(.failed, "GitHub returned an error ({t})", .{e}),
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

        u.progress(.downloading, "Downloading version {s}…", .{version});
        var arena_state = std.heap.ArenaAllocator.init(u.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const asset_url = u.urlFor(arena, file, version) catch return u.finish(.available, "out of memory", .{});
        const data = u.fetch(arena, asset_url, @intCast(@min(asset.size + 1, manifest.max_asset))) catch |e| {
            u.lock();
            u.busy = false;
            u.unlock();
            return u.finish(.available, "Could not download version {s} ({t}) — will try again later", .{ version, e });
        };
        manifest.checkAsset(asset, data) catch return u.finish(.failed, "the {s} archive does not match the manifest — rejected", .{version});

        var path: [1024]u8 = undefined;
        if (plat.rdc_write_temp(file_buf[0..file.len :0].ptr, data.ptr, data.len, &path, path.len) != 0)
            return u.finish(.available, "cannot write the archive to the temp folder", .{});
        u.progress(.installing, "Installing version {s} and restarting…", .{version});
        log("update: installing {s}", .{version});
        const rc = plat.rdc_install_update(@ptrCast(&path), version_buf[0..version.len :0].ptr);
        // Only reached on failure: on success the process restarts.
        u.finish(.failed, "could not install version {s} (code {d}) — details in the log", .{ version, rc });
    }
};
