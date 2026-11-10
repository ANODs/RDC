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
#define RDC_ACTION_STOP_MEDIA 8  // stop taking the viewer's microphone and camera
// Install or remove this OS's phone device (the camera on Windows): the host runs
// rdc_camera_install on a thread, since the DLL's bytes live on the Zig side.
#define RDC_ACTION_MEDIA_INSTALL 9
#define RDC_ACTION_MEDIA_REMOVE 10
// Settings → permanent access (docs/PLAN.md, section 6): on, off, a new link and authenticator key.
#define RDC_ACTION_PERMANENT_ON 11
#define RDC_ACTION_PERMANENT_OFF 12
#define RDC_ACTION_PERMANENT_RESET 13

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
// The seed of permanent access, kept between runs in a file only this user can read (macOS —
// ~/Library/Application Support/RDC/permanent, Windows — %LOCALAPPDATA%\RDC\permanent). The process
// that loads it holds it until it exits. Load: bytes read, 0 — none yet, -1 — failed, -2 — another
// RDC on this computer holds it. Save: 0 — saved.
int rdc_seed_load(void *buf, int cap);
int rdc_seed_save(const void *data, int len);
// Settings → permanent access: whether it is on, its link, and two QR codes (modules row by row,
// 1 — dark): the link for a phone's camera and the key for an authenticator app, with the same
// key as text for typing in by hand.
void rdc_app_set_permanent(int on, const char *link, const uint8_t *link_qr, int link_qr_size,
                           const uint8_t *auth_qr, int auth_qr_size, const char *secret_text);
// Settings window: version, auto-update, status, whether an update can be installed, whether work is in progress.
void rdc_settings_update(const char *version, int auto_update, const char *status, int can_install, int busy);

// The viewer's microphone and camera as capture devices on this computer — "RDC Microphone" and
// "RDC Camera" — fed by the host from one viewer's stream (docs/PLAN.md, section 6). macOS has the
// microphone (a HAL plug-in in RDC.app/Contents/Resources, installed on demand), Windows the camera
// (a Media Foundation virtual camera). The host keeps working when neither is installed.
#define RDC_MEDIA_MIC 1               // "RDC Microphone" is available to apps right now
#define RDC_MEDIA_CAMERA 2            // "RDC Camera" is available to apps right now
#define RDC_MEDIA_MIC_SETUP 4         // this OS can install the microphone (macOS)
#define RDC_MEDIA_CAMERA_SETUP 8      // this OS can install the camera (Windows 11)
#define RDC_MEDIA_MIC_INSTALLED 16    // the microphone driver is in place (loaded after the audio system restarts)
#define RDC_MEDIA_MIC_OUTDATED 32     // the installed microphone driver is older than the one in this RDC
#define RDC_MEDIA_CAMERA_INSTALLED 64 // the camera is registered
#define RDC_MEDIA_CAMERA_OUTDATED 128 // the registered camera is older than the one in this RDC
int rdc_media_status(void);
// Installs (1) or removes (0) the device with the OS's administrator prompt; blocks until done.
// 0 — done, 1 — cancelled by the person, negative — failed (details in the log).
int rdc_mic_install(int install);
// dll, dll_len — the camera's media source DLL embedded in the Zig side (Windows); NULL elsewhere.
int rdc_camera_install(int install, const void *dll, size_t dll_len);
// One viewer's microphone: 16-bit PCM, 48 kHz, mono, pushed from the viewer's thread about every 20 ms.
void rdc_mic_start(void);
void rdc_mic_push(const int16_t *pcm, int frames);
void rdc_mic_stop(void);
// One viewer's camera: whole JPEG frames from the viewer's thread, at most 15 a second.
void rdc_camera_start(void);
void rdc_camera_push(const uint8_t *jpeg, size_t len, int width, int height);
void rdc_camera_stop(void);

// The host with a window, after rdc_init and before anything else. Windows: restarts RDC as
// administrator through the UAC prompt (input then reaches apps that run as administrator, and
// RDC opens the firewall for viewers and registers the phone camera itself), lets only one
// window run, and starts the phone camera. camera_dll — the camera's media source DLL that
// RDC.exe carries (NULL elsewhere). 1 — this process must exit now: another RDC window runs,
// or the administrator copy has started.
int rdc_app_prepare(const void *camera_dll, size_t camera_dll_len);

// App window. rdc_app_run blocks the main thread until exit.
void rdc_app_run(rdc_ctx_cb on_ready, rdc_action_cb on_action, void *ctx);
void rdc_app_set_info(const char *code, const char *link);
// The link that works from any network (GitHub Pages + WebRTC) and the caption above it;
// link "" — no link to show (connections from anywhere are off, or no broker is connected yet).
void rdc_app_set_remote(const char *caption, const char *link);
void rdc_app_set_status(const char *text);
void rdc_app_set_permissions(int screen_ok, int input_ok);
// An AI agent is connected: the window shows a Stop button that sends RDC_ACTION_STOP_AI.
void rdc_app_set_ai(int active);
// What a viewer lends right now ("Phone microphone live — 1.2.3.4"; "" — nothing): shown with a
// Stop button that sends RDC_ACTION_STOP_MEDIA.
void rdc_app_set_media(const char *text);
