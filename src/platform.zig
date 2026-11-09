//! Bindings to the platform layer (the contract is src/platform/platform.h).
//! The build picks the implementation: macos/shim.m or windows/shim.c.
pub const codec_h264: c_int = 1;
pub const codec_jpeg: c_int = 2;

pub const action_disconnect_all: c_int = 1;
pub const action_new_code: c_int = 2;
pub const action_check_update: c_int = 3;
pub const action_install_update: c_int = 4;
pub const action_auto_update_on: c_int = 5;
pub const action_auto_update_off: c_int = 6;
pub const action_stop_ai: c_int = 7;
pub const action_stop_media: c_int = 8;
pub const action_media_install: c_int = 9;
pub const action_media_remove: c_int = 10;

pub const media_mic: c_int = 1;
pub const media_camera: c_int = 2;
pub const media_mic_setup: c_int = 4;
pub const media_camera_setup: c_int = 8;
pub const media_mic_installed: c_int = 16;
pub const media_mic_outdated: c_int = 32;
pub const media_camera_installed: c_int = 64;
pub const media_camera_outdated: c_int = 128;

pub const FrameCallback = *const fn (ctx: ?*anyopaque, codec: c_int, data: [*]const u8, len: usize, keyframe: c_int, ts_us: u64, width: c_int, height: c_int) callconv(.c) void;
pub const CtxCallback = *const fn (ctx: ?*anyopaque) callconv(.c) void;
pub const ActionCallback = *const fn (ctx: ?*anyopaque, action: c_int) callconv(.c) void;

pub extern fn rdc_init() void;
pub extern fn rdc_log(msg: [*:0]const u8) void;
pub extern fn rdc_now_us() u64;

pub extern fn rdc_screen_access(prompt: c_int) c_int;
pub extern fn rdc_input_access(prompt: c_int) c_int;
pub extern fn rdc_open_privacy(which: c_int) void;

pub extern fn rdc_capture_start(max_width: c_int, fps: c_int, cb: FrameCallback, ctx: ?*anyopaque) c_int;
pub extern fn rdc_codec_caps() c_int;
pub extern fn rdc_capture_stop() void;
pub extern fn rdc_set_codecs(h264: c_int, jpeg: c_int) void;
pub extern fn rdc_request_keyframe() void;
pub extern fn rdc_set_bitrate(bits_per_second: c_int) void;

pub extern fn rdc_mouse_move(nx: f64, ny: f64) void;
pub extern fn rdc_mouse_button(button: c_int, down: c_int, nx: f64, ny: f64) void;
pub extern fn rdc_scroll(dx: f64, dy: f64) void;
pub extern fn rdc_key(keycode: c_int, down: c_int) void;
pub extern fn rdc_release_all() void;
pub extern fn rdc_text(utf8: [*]const u8, len: usize) void;
pub extern fn rdc_cursor_pos(nx: *f64, ny: *f64) void;
pub extern fn rdc_read_file(path: [*:0]const u8, len: *usize) ?[*]u8;

pub extern fn rdc_jpeg_scale(jpeg: [*]const u8, len: usize, crop_x: c_int, crop_y: c_int, crop_w: c_int, crop_h: c_int, max_w: c_int, max_h: c_int, quality: c_int, out_len: *usize, out_w: *c_int, out_h: *c_int) ?[*]u8;

pub extern fn rdc_lan_ipv4(buf: [*]u8, buflen: c_int) c_int;
pub extern fn rdc_computer_name(buf: [*]u8, buflen: c_int) c_int;

pub extern fn rdc_http_get(url: [*:0]const u8, max_len: usize, len: *usize, status: *c_int) ?[*]u8;
pub extern fn rdc_write_temp(name: [*:0]const u8, data: [*]const u8, len: usize, path_out: [*]u8, path_len: c_int) c_int;
pub extern fn rdc_install_update(zip_path: [*:0]const u8, version: [*:0]const u8) c_int;
pub extern fn rdc_install_path(buf: [*]u8, buflen: c_int) c_int;
pub extern fn rdc_cleanup_old_install() void;
pub extern fn rdc_pref_bool(key: [*:0]const u8, def: c_int) c_int;
pub extern fn rdc_set_pref_bool(key: [*:0]const u8, value: c_int) void;
pub extern fn rdc_settings_update(version: [*:0]const u8, auto_update: c_int, status: [*:0]const u8, can_install: c_int, busy: c_int) void;

pub extern fn rdc_app_prepare(camera_dll: ?[*]const u8, camera_dll_len: usize) c_int;
pub extern fn rdc_app_run(on_ready: ?CtxCallback, on_action: ?ActionCallback, ctx: ?*anyopaque) void;
pub extern fn rdc_app_set_info(code: [*:0]const u8, link: [*:0]const u8) void;
pub extern fn rdc_app_set_remote(caption: [*:0]const u8, link: [*:0]const u8) void;
pub extern fn rdc_app_set_status(text: [*:0]const u8) void;
pub extern fn rdc_app_set_permissions(screen_ok: c_int, input_ok: c_int) void;
pub extern fn rdc_app_set_ai(active: c_int) void;
pub extern fn rdc_app_set_media(text: [*:0]const u8) void;

pub extern fn rdc_media_status() c_int;
pub extern fn rdc_mic_install(install: c_int) c_int;
pub extern fn rdc_camera_install(install: c_int, dll: ?[*]const u8, dll_len: usize) c_int;
pub extern fn rdc_mic_start() void;
pub extern fn rdc_mic_push(pcm: [*]const i16, frames: c_int) void;
pub extern fn rdc_mic_stop() void;
pub extern fn rdc_camera_start() void;
pub extern fn rdc_camera_push(jpeg: [*]const u8, len: usize, width: c_int, height: c_int) void;
pub extern fn rdc_camera_stop() void;

/// free() from libc — for buffers handed out by the platform layer.
pub extern fn free(ptr: ?*anyopaque) void;
