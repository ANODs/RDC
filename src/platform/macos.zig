//! Привязки к платформенному слою macOS (src/platform/macos/shim.m).
pub const codec_h264: c_int = 1;
pub const codec_jpeg: c_int = 2;

pub const action_disconnect_all: c_int = 1;
pub const action_new_code: c_int = 2;
pub const action_check_update: c_int = 3;
pub const action_install_update: c_int = 4;
pub const action_auto_update_on: c_int = 5;
pub const action_auto_update_off: c_int = 6;

pub const FrameCallback = *const fn (ctx: ?*anyopaque, codec: c_int, data: [*]const u8, len: usize, keyframe: c_int, ts_us: u64, width: c_int, height: c_int) callconv(.c) void;
pub const CtxCallback = *const fn (ctx: ?*anyopaque) callconv(.c) void;
pub const ActionCallback = *const fn (ctx: ?*anyopaque, action: c_int) callconv(.c) void;

pub extern fn rdc_mac_init() void;
pub extern fn rdc_mac_log(msg: [*:0]const u8) void;
pub extern fn rdc_mac_now_us() u64;

pub extern fn rdc_mac_screen_access(prompt: c_int) c_int;
pub extern fn rdc_mac_input_access(prompt: c_int) c_int;
pub extern fn rdc_mac_open_privacy(which: c_int) void;

pub extern fn rdc_mac_capture_start(max_width: c_int, fps: c_int, cb: FrameCallback, ctx: ?*anyopaque) c_int;
pub extern fn rdc_mac_capture_stop() void;
pub extern fn rdc_mac_set_codecs(h264: c_int, jpeg: c_int) void;
pub extern fn rdc_mac_request_keyframe() void;
pub extern fn rdc_mac_set_bitrate(bits_per_second: c_int) void;

pub extern fn rdc_mac_mouse_move(nx: f64, ny: f64) void;
pub extern fn rdc_mac_mouse_button(button: c_int, down: c_int, nx: f64, ny: f64) void;
pub extern fn rdc_mac_scroll(dx: f64, dy: f64) void;
pub extern fn rdc_mac_key(mac_keycode: c_int, down: c_int) void;
pub extern fn rdc_mac_release_all() void;
pub extern fn rdc_mac_cursor_pos(nx: *f64, ny: *f64) void;
pub extern fn rdc_mac_read_file(path: [*:0]const u8, len: *usize) ?[*]u8;

pub extern fn rdc_mac_lan_ipv4(buf: [*]u8, buflen: c_int) c_int;
pub extern fn rdc_mac_computer_name(buf: [*]u8, buflen: c_int) c_int;

pub extern fn rdc_mac_http_get(url: [*:0]const u8, max_len: usize, len: *usize, status: *c_int) ?[*]u8;
pub extern fn rdc_mac_write_temp(name: [*:0]const u8, data: [*]const u8, len: usize, path_out: [*]u8, path_len: c_int) c_int;
pub extern fn rdc_mac_install_update(zip_path: [*:0]const u8, version: [*:0]const u8) c_int;
pub extern fn rdc_mac_bundle_path(buf: [*]u8, buflen: c_int) c_int;
pub extern fn rdc_mac_cleanup_old_bundles() void;
pub extern fn rdc_mac_pref_bool(key: [*:0]const u8, def: c_int) c_int;
pub extern fn rdc_mac_set_pref_bool(key: [*:0]const u8, value: c_int) void;
pub extern fn rdc_mac_settings_update(version: [*:0]const u8, auto_update: c_int, status: [*:0]const u8, can_install: c_int, busy: c_int) void;

pub extern fn rdc_mac_app_run(on_ready: ?CtxCallback, on_action: ?ActionCallback, ctx: ?*anyopaque) void;
pub extern fn rdc_mac_app_set_info(code: [*:0]const u8, link: [*:0]const u8) void;
pub extern fn rdc_mac_app_set_status(text: [*:0]const u8) void;
pub extern fn rdc_mac_app_set_permissions(screen_ok: c_int, input_ok: c_int) void;
