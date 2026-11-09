// RDC platform layer contract: capture, encoding, input, window, updates.
// Plain C ABI, the same on every OS. Implementations: macos/shim.m (ScreenCaptureKit,
// VideoToolbox, CGEvent, AppKit) and windows/shim.c (DXGI, WIC, SendInput, Win32).
// Zig declares these functions with `extern fn` in src/platform.zig.
#pragma once
#include <stddef.h>
#include <stdint.h>

#define RDC_CODEC_H264 1  // H.264 Annex B: each NAL prefixed with 00 00 00 01
#define RDC_CODEC_JPEG 2  // a single JPEG frame

// A finished compressed frame. Called from a VideoToolbox thread: the callback must be
// thread-safe and must not block for long. The data is valid only until it returns.
typedef void (*rdc_frame_cb)(void *ctx, int codec, const uint8_t *data, size_t len,
                             int keyframe, uint64_t ts_us, int width, int height);
typedef void (*rdc_ctx_cb)(void *ctx);
typedef void (*rdc_action_cb)(void *ctx, int action);

#define RDC_ACTION_DISCONNECT_ALL 1
#define RDC_ACTION_NEW_CODE 2
#define RDC_ACTION_CHECK_UPDATE 3
#define RDC_ACTION_INSTALL_UPDATE 4
#define RDC_ACTION_AUTO_UPDATE_ON 5
#define RDC_ACTION_AUTO_UPDATE_OFF 6
#define RDC_ACTION_STOP_AI 7  // disconnect the AI agents, keep people connected

// Process: the log goes to stderr and to a file (macOS — ~/Library/Logs/RDC/rdc.log,
// Windows — %LOCALAPPDATA%\RDC\rdc.log).
void rdc_init(void);
void rdc_log(const char *msg);
uint64_t rdc_now_us(void);  // monotonic time

// Permissions. 1 — granted, 0 — not. prompt != 0 — show the system prompt.
int rdc_screen_access(int prompt);
int rdc_input_access(int prompt);
void rdc_open_privacy(int which);  // 0 — Screen Recording, 1 — Accessibility

// Captures the main display. Returns 0 or a negative error code.
// Do not call from the main thread: waits up to 10 s for the capture thread to start.
int rdc_capture_start(int max_width, int fps, rdc_frame_cb cb, void *ctx);
int rdc_codec_caps(void);  // codecs the platform supports: bit 0 — H.264, bit 1 — JPEG
void rdc_capture_stop(void);
void rdc_set_codecs(int h264, int jpeg);
void rdc_request_keyframe(void);
void rdc_set_bitrate(int bits_per_second);

// Input. Coordinates are normalized to the captured frame: 0..1.
void rdc_mouse_move(double nx, double ny);
void rdc_mouse_button(int button, int down, double nx, double ny);  // 0 left, 1 middle, 2 right
void rdc_scroll(double dx, double dy);                              // pixels, as in the browser
void rdc_key(int keycode, int down);  // platform key code: kVK_* on macOS, scan code (0xE0xx — extended) on Windows
void rdc_release_all(void);
void rdc_text(const char *utf8, size_t len);  // types Unicode text, whatever the keyboard layout
void rdc_cursor_pos(double *nx, double *ny);  // current cursor position, 0..1

// Whole file in a malloc buffer (release with free) or NULL.
void *rdc_read_file(const char *path, size_t *len);

// JPEG → JPEG for an AI agent's screenshots: crop (crop_w <= 0 — whole image), then shrink to
// fit max_w × max_h (never enlarge). Result in a malloc buffer (release with free) or NULL.
void *rdc_jpeg_scale(const void *jpeg, size_t len, int crop_x, int crop_y, int crop_w, int crop_h,
                     int max_w, int max_h, int quality, size_t *out_len, int *out_w, int *out_h);

// Network and system.
int rdc_lan_ipv4(char *buf, int buflen);
int rdc_computer_name(char *buf, int buflen);

// Updates.
// HTTP GET (blocks the thread): body in a malloc buffer (release with free) or NULL; *status — HTTP code or -1.
void *rdc_http_get(const char *url, size_t max_len, size_t *len, int *status);
// Write to the temporary update folder; the path goes to path_out.
int rdc_write_temp(const char *name, const void *data, size_t len, char *path_out, int path_len);
// Unpack the archive, check its contents, replace the installed RDC with it and
// restart. Does not return on success.
int rdc_install_update(const char *zip_path, const char *version);
int rdc_install_path(char *buf, int buflen);  // path to RDC.app (macOS) or rdc.exe (Windows); -1 if there is nothing to replace
void rdc_cleanup_old_install(void);          // remove leftovers of the previous version after an update
int rdc_pref_bool(const char *key, int def);
void rdc_set_pref_bool(const char *key, int value);
// Settings window: version, auto-update, status, whether an update can be installed, whether work is in progress.
void rdc_settings_update(const char *version, int auto_update, const char *status, int can_install, int busy);

// App window. rdc_app_run blocks the main thread until exit.
void rdc_app_run(rdc_ctx_cb on_ready, rdc_action_cb on_action, void *ctx);
void rdc_app_set_info(const char *code, const char *link);
// The link that works from any network (GitHub Pages + WebRTC); "" — connections from anywhere are off.
void rdc_app_set_remote_link(const char *link);
void rdc_app_set_status(const char *text);
void rdc_app_set_permissions(int screen_ok, int input_ok);
// An AI agent is connected: the window shows a Stop button that sends RDC_ACTION_STOP_AI.
void rdc_app_set_ai(int active);
