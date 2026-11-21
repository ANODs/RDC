// What the Linux platform layer's files share (the contract with the host is ../platform.h).
// shim.c — process, log, files, network, prefs, updates, start at login, keep awake;
// x11.c — capture and input through X11; window.c — the GTK 3 window.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "platform.h"

void rlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// The running binary (/proc/self/exe). 0 — ok.
int lx_exe_path(char *buf, size_t n);
// This process was started with the flag (/proc/self/cmdline).
int lx_has_arg(const char *arg);
// ~/.config/rdc (XDG_CONFIG_HOME), created on first use; "" if there is no home.
const char *lx_config_dir(void);
// A program by name in PATH.
int lx_in_path(const char *name);
// Starts argv[0] (looked up in PATH) without waiting for it; it is reaped in the background.
int lx_spawn_detached(const char *const argv[]);

// Start at login: ~/.config/autostart/rdc.desktop runs this binary with --login.
int lx_autostart_on(void);
int lx_autostart_set(int on);
void lx_autostart_repair(void);
// Keep awake: a systemd-inhibit idle:sleep lock held while on.
void lx_keep_awake(int on);

// The single-window socket made by rdc_app_prepare (-1 — none): a second launch connects to it.
int lx_instance_fd(void);

// X11 is loaded (rdc_init) and XInitThreads has run.
int lx_x11_ready(void);
void lx_x11_init(void);

// The JPEG encoder (src/core/jpeg.zig, exported by zig_export.zig).
void *rdc_linux_jpeg_new(int quality);
void rdc_linux_jpeg_free(void *enc);
void rdc_linux_jpeg_quality(void *enc, int quality);
int rdc_linux_jpeg_encode(void *enc, const uint8_t *pixels, int width, int height, int stride, int rgbx, int out_w,
                          int out_h, const uint8_t **out, size_t *out_len);
