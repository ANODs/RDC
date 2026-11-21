// Linux capture and input through X11 (contract — ../platform.h): the root window of the X
// screen grabbed with MIT-SHM (XShmGetImage; plain XGetImage without it), the cursor from XFixes
// drawn on top, JPEG from src/core/jpeg.zig; input through XTest. libX11, libXext, libXtst and
// libXfixes are opened with dlopen, and the few types used are declared here, so nothing X11 is
// needed to build. Wayland: only XWayland's X11 windows can be seen and controlled this way.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <time.h>
#include <unistd.h>
#include "linux.h"

// --- The slice of Xlib, XShm, XTest and XFixes RDC uses (layouts as in X11/Xlib.h, XShm.h, Xfixes.h).

typedef struct _XDisplay Display;
typedef struct _Visual Visual;
typedef unsigned long XID;
typedef XID Window;
typedef XID Drawable;
typedef XID KeySym;
typedef unsigned char KeyCode;
typedef int Bool;
typedef int Status;

typedef struct _XImage {
    int width, height;
    int xoffset;
    int format;
    char *data;
    int byte_order;
    int bitmap_unit;
    int bitmap_bit_order;
    int bitmap_pad;
    int depth;
    int bytes_per_line;
    int bits_per_pixel;
    unsigned long red_mask;
    unsigned long green_mask;
    unsigned long blue_mask;
    void *obdata;
    struct {
        void *create_image;
        int (*destroy_image)(struct _XImage *);
        void *get_pixel, *put_pixel, *sub_image, *add_pixel;
    } f;
} XImage;

typedef struct {
    unsigned long shmseg;
    int shmid;
    char *shmaddr;
    Bool readOnly;
} XShmSegmentInfo;

typedef struct {
    short x, y;
    unsigned short width, height;
    unsigned short xhot, yhot;
    unsigned long cursor_serial;
    unsigned long *pixels;  // ARGB, premultiplied, one per unsigned long
} XFixesCursorImage;

typedef struct {
    int type;
    Display *display;
    XID resourceid;
    unsigned long serial;
    unsigned char error_code;
    unsigned char request_code;
    unsigned char minor_code;
} XErrorEvent;

typedef int (*XErrorHandler)(Display *, XErrorEvent *);

#define ZPixmap 2
#define AllPlanes (~0UL)
#define NoSymbol 0UL
#define XK_Return 0xff0dUL
#define XK_Tab 0xff09UL
#define XK_BackSpace 0xff08UL

static struct {
    int ok;
    int shm, xtest, xfixes;  // the extension libraries are there
    int (*InitThreads)(void);
    Display *(*OpenDisplay)(const char *);
    int (*CloseDisplay)(Display *);
    int (*DefaultScreen)(Display *);
    Window (*RootWindow)(Display *, int);
    Visual *(*DefaultVisual)(Display *, int);
    int (*DefaultDepth)(Display *, int);
    XImage *(*GetImage)(Display *, Drawable, int, int, unsigned, unsigned, unsigned long, int);
    Status (*GetGeometry)(Display *, Drawable, Window *, int *, int *, unsigned *, unsigned *, unsigned *, unsigned *);
    int (*Sync)(Display *, Bool);
    int (*Flush)(Display *);
    int (*Free)(void *);
    Bool (*QueryPointer)(Display *, Window, Window *, Window *, int *, int *, int *, int *, unsigned *);
    Bool (*QueryExtension)(Display *, const char *, int *, int *, int *);
    KeyCode (*KeysymToKeycode)(Display *, KeySym);
    KeySym *(*GetKeyboardMapping)(Display *, KeyCode, int, int *);
    int (*ChangeKeyboardMapping)(Display *, int, int, KeySym *, int);
    int (*DisplayKeycodes)(Display *, int *, int *);
    XErrorHandler (*SetErrorHandler)(XErrorHandler);
    Bool (*ShmQueryExtension)(Display *);
    XImage *(*ShmCreateImage)(Display *, Visual *, unsigned, int, char *, XShmSegmentInfo *, unsigned, unsigned);
    Bool (*ShmAttach)(Display *, XShmSegmentInfo *);
    Bool (*ShmDetach)(Display *, XShmSegmentInfo *);
    Bool (*ShmGetImage)(Display *, Drawable, XImage *, int, int, unsigned long);
    Bool (*TestQueryExtension)(Display *, int *, int *, int *, int *);
    int (*TestFakeMotionEvent)(Display *, int, int, int, unsigned long);
    int (*TestFakeButtonEvent)(Display *, unsigned, Bool, unsigned long);
    int (*TestFakeKeyEvent)(Display *, unsigned, Bool, unsigned long);
    Bool (*FixesQueryExtension)(Display *, int *, int *);
    XFixesCursorImage *(*FixesGetCursorImage)(Display *);
} X;

#define LOAD(lib, field, name)                                         \
    do {                                                               \
        *(void **)&X.field = lib ? dlsym(lib, name) : NULL;            \
        if (!X.field) missing = name;                                  \
    } while (0)

static pthread_once_t g_load_once = PTHREAD_ONCE_INIT;

static void x11_load(void) {
    void *x11 = dlopen("libX11.so.6", RTLD_NOW | RTLD_GLOBAL);
    if (!x11) return;
    const char *missing = NULL;
    LOAD(x11, InitThreads, "XInitThreads");
    LOAD(x11, OpenDisplay, "XOpenDisplay");
    LOAD(x11, CloseDisplay, "XCloseDisplay");
    LOAD(x11, DefaultScreen, "XDefaultScreen");
    LOAD(x11, RootWindow, "XRootWindow");
    LOAD(x11, DefaultVisual, "XDefaultVisual");
    LOAD(x11, DefaultDepth, "XDefaultDepth");
    LOAD(x11, GetImage, "XGetImage");
    LOAD(x11, GetGeometry, "XGetGeometry");
    LOAD(x11, Sync, "XSync");
    LOAD(x11, Flush, "XFlush");
    LOAD(x11, Free, "XFree");
    LOAD(x11, QueryPointer, "XQueryPointer");
    LOAD(x11, QueryExtension, "XQueryExtension");
    LOAD(x11, KeysymToKeycode, "XKeysymToKeycode");
    LOAD(x11, GetKeyboardMapping, "XGetKeyboardMapping");
    LOAD(x11, ChangeKeyboardMapping, "XChangeKeyboardMapping");
    LOAD(x11, DisplayKeycodes, "XDisplayKeycodes");
    LOAD(x11, SetErrorHandler, "XSetErrorHandler");
    if (missing) {
        rlog("X11: libX11 has no %s", missing);
        return;
    }
    X.ok = 1;
    void *xext = dlopen("libXext.so.6", RTLD_NOW);
    missing = NULL;
    LOAD(xext, ShmQueryExtension, "XShmQueryExtension");
    LOAD(xext, ShmCreateImage, "XShmCreateImage");
    LOAD(xext, ShmAttach, "XShmAttach");
    LOAD(xext, ShmDetach, "XShmDetach");
    LOAD(xext, ShmGetImage, "XShmGetImage");
    X.shm = !missing;
    void *xtst = dlopen("libXtst.so.6", RTLD_NOW);
    missing = NULL;
    LOAD(xtst, TestQueryExtension, "XTestQueryExtension");
    LOAD(xtst, TestFakeMotionEvent, "XTestFakeMotionEvent");
    LOAD(xtst, TestFakeButtonEvent, "XTestFakeButtonEvent");
    LOAD(xtst, TestFakeKeyEvent, "XTestFakeKeyEvent");
    X.xtest = !missing;
    if (!X.xtest) rlog("X11: libXtst.so.6 is missing — viewers can watch but not control (install libxtst6)");
    void *xfixes = dlopen("libXfixes.so.3", RTLD_NOW);
    missing = NULL;
    LOAD(xfixes, FixesQueryExtension, "XFixesQueryExtension");
    LOAD(xfixes, FixesGetCursorImage, "XFixesGetCursorImage");
    X.xfixes = !missing;
}

void lx_x11_init(void) {
    pthread_once(&g_load_once, x11_load);
    if (X.ok) X.InitThreads();
}

int lx_x11_ready(void) { return X.ok; }

// X errors on RDC's own connections are logged, not fatal (Xlib's default handler exits); the
// others go to whoever had the handler before (GDK, which ignores displays it did not open).
static Display *_Atomic g_cap_dpy, *_Atomic g_in_dpy;
static XErrorHandler g_prev_handler;
static atomic_int g_x_errors;

static int on_x_error(Display *d, XErrorEvent *e) {
    if (d == atomic_load(&g_cap_dpy) || d == atomic_load(&g_in_dpy)) {
        if (atomic_fetch_add(&g_x_errors, 1) < 20)
            rlog("X11 error %d (request %d.%d)", e->error_code, e->request_code, e->minor_code);
        return 0;
    }
    return g_prev_handler ? g_prev_handler(d, e) : 0;
}

static pthread_once_t g_handler_once = PTHREAD_ONCE_INIT;
static void install_handler(void) { g_prev_handler = X.SetErrorHandler(on_x_error); }

static int is_wayland(void) {
    const char *w = getenv("WAYLAND_DISPLAY"), *t = getenv("XDG_SESSION_TYPE");
    return (w && w[0]) || (t && strcmp(t, "wayland") == 0);
}

// ---------------------------------------------------------------------------
// Capture thread

#define JPEG_QUALITY 60
#define MAX_FPS 30

static pthread_mutex_t g_cap_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cap_cond = PTHREAD_COND_INITIALIZER;
static pthread_t g_cap_thread;
static int g_cap_started;
static atomic_int g_cap_run, g_want_jpeg = 1, g_force_key;
static int g_cap_status;  // -9 — starting, 0 — running, < 0 — failed
static rdc_frame_cb g_cb;
static void *g_cb_ctx;
static int g_max_width = 1920;
static uint64_t g_interval_us = 1000000 / MAX_FPS;

typedef struct {
    XImage *img;
    XShmSegmentInfo shm;
    int use_shm;
    int w, h;
} Grab;

static void grab_close(Display *d, Grab *g) {
    if (g->img) {
        if (g->use_shm) X.ShmDetach(d, &g->shm);
        g->img->f.destroy_image(g->img);  // for an XShm image this frees the struct only
        if (g->use_shm) shmdt(g->shm.shmaddr);
    }
    memset(g, 0, sizeof *g);
}

static int grab_open(Display *d, int scr, Window root, int w, int h, Grab *g) {
    memset(g, 0, sizeof *g);
    g->w = w;
    g->h = h;
    if (!X.shm || !X.ShmQueryExtension(d)) return 0;  // XGetImage every frame instead
    Visual *vis = X.DefaultVisual(d, scr);
    XImage *img = X.ShmCreateImage(d, vis, (unsigned)X.DefaultDepth(d, scr), ZPixmap, NULL, &g->shm, (unsigned)w, (unsigned)h);
    if (!img) return 0;
    g->shm.shmid = shmget(IPC_PRIVATE, (size_t)img->bytes_per_line * (size_t)img->height, IPC_CREAT | 0600);
    if (g->shm.shmid < 0) {
        img->f.destroy_image(img);
        return 0;
    }
    g->shm.shmaddr = img->data = shmat(g->shm.shmid, NULL, 0);
    g->shm.readOnly = 0;
    if (g->shm.shmaddr == (char *)-1) {
        shmctl(g->shm.shmid, IPC_RMID, NULL);
        img->f.destroy_image(img);
        return 0;
    }
    int errors = atomic_load(&g_x_errors);
    int attached = X.ShmAttach(d, &g->shm);
    X.Sync(d, 0);
    shmctl(g->shm.shmid, IPC_RMID, NULL);  // gone once both sides detach, even after a crash
    if (!attached || atomic_load(&g_x_errors) != errors) {
        // A remote X server, or one in another IPC namespace: no shared memory with it.
        shmdt(g->shm.shmaddr);
        img->f.destroy_image(img);
        memset(&g->shm, 0, sizeof g->shm);
        return 0;
    }
    g->img = img;
    g->use_shm = 1;
    return 0;
}

// The screen now: pixels and their row length, or NULL. *tmp — an XImage to destroy afterwards.
static const uint8_t *grab(Display *d, Window root, Grab *g, int *stride, XImage **tmp) {
    *tmp = NULL;
    if (g->use_shm) {
        if (!X.ShmGetImage(d, root, g->img, 0, 0, AllPlanes)) return NULL;
        *stride = g->img->bytes_per_line;
        return (const uint8_t *)g->img->data;
    }
    XImage *img = X.GetImage(d, root, 0, 0, (unsigned)g->w, (unsigned)g->h, AllPlanes, ZPixmap);
    if (!img) return NULL;
    *tmp = img;
    *stride = img->bytes_per_line;
    return (const uint8_t *)img->data;
}

// 32 bits a pixel, 8 bits a channel; 1 — the bytes are R G B X rather than B G R X.
static int pixel_layout(XImage *img, int *rgbx) {
    if (img->bits_per_pixel != 32 || img->byte_order != 0 /* LSBFirst */) return -1;
    if (img->red_mask == 0xff0000 && img->green_mask == 0xff00 && img->blue_mask == 0xff) {
        *rgbx = 0;
        return 0;
    }
    if (img->red_mask == 0xff && img->green_mask == 0xff00 && img->blue_mask == 0xff0000) {
        *rgbx = 1;
        return 0;
    }
    return -1;
}

// The cursor is not in the root window's pixels: XFixes gives its image, drawn on top here.
static void draw_cursor(uint8_t *px, int w, int h, int stride, int rgbx, const XFixesCursorImage *ci) {
    int x0 = ci->x - ci->xhot, y0 = ci->y - ci->yhot;
    for (int cy = 0; cy < ci->height; cy++) {
        int y = y0 + cy;
        if (y < 0 || y >= h) continue;
        uint8_t *row = px + (size_t)y * (size_t)stride;
        for (int cx = 0; cx < ci->width; cx++) {
            int x = x0 + cx;
            if (x < 0 || x >= w) continue;
            uint32_t argb = (uint32_t)ci->pixels[cy * ci->width + cx];
            uint32_t a = argb >> 24;
            if (a == 0) continue;
            uint32_t r = (argb >> 16) & 0xff, gr = (argb >> 8) & 0xff, b = argb & 0xff;  // premultiplied
            uint8_t *p = row + 4 * x;
            uint8_t *pr = rgbx ? p : p + 2, *pb = rgbx ? p + 2 : p;
            *pr = (uint8_t)(r + *pr * (255 - a) / 255);
            p[1] = (uint8_t)(gr + p[1] * (255 - a) / 255);
            *pb = (uint8_t)(b + *pb * (255 - a) / 255);
        }
    }
}

static void cap_ready(int status) {
    pthread_mutex_lock(&g_cap_lock);
    g_cap_status = status;
    pthread_cond_broadcast(&g_cap_cond);
    pthread_mutex_unlock(&g_cap_lock);
}

static void sleep_us(uint64_t us) {
    struct timespec ts = {(time_t)(us / 1000000), (long)(us % 1000000) * 1000};
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
}

static void *capture_main(void *arg) {
    Display *d = X.ok ? X.OpenDisplay(NULL) : NULL;
    if (!d) {
        const char *disp = getenv("DISPLAY");
        if (!X.ok)
            rlog("capture: libX11 is not installed — RDC on Linux shares an X11 desktop");
        else if (is_wayland())
            rlog("capture: no X server (DISPLAY=%s): this is a Wayland session, which RDC cannot share yet — "
                 "log in with an X11 (\"Xorg\") session",
                 disp ? disp : "");
        else
            rlog("capture: cannot open the X display (DISPLAY=%s)", disp ? disp : "not set");
        cap_ready(-2);
        return NULL;
    }
    atomic_store(&g_cap_dpy, d);
    pthread_once(&g_handler_once, install_handler);
    int scr = X.DefaultScreen(d);
    Window root = X.RootWindow(d, scr), r_root;
    int ev, er, op;
    if (X.QueryExtension(d, "XWAYLAND", &op, &ev, &er) || is_wayland())
        rlog("capture: this is a Wayland session — through XWayland RDC sees and controls only X11 apps, the rest "
             "of the screen stays black. Log in with an X11 (\"Xorg\") session to share the whole desktop; Wayland "
             "support is planned");
    int have_fixes = X.xfixes && X.FixesQueryExtension(d, &ev, &er);
    int gx, gy;
    unsigned gw = 0, gh = 0, bw, depth;
    X.GetGeometry(d, root, &r_root, &gx, &gy, &gw, &gh, &bw, &depth);
    Grab g;
    grab_open(d, scr, root, (int)gw, (int)gh, &g);
    int stride = 0, rgbx = 0;
    XImage *tmp = NULL;
    const uint8_t *px = gw && gh ? grab(d, root, &g, &stride, &tmp) : NULL;
    XImage *probe = g.use_shm ? g.img : tmp;
    if (!px || !probe || pixel_layout(probe, &rgbx) != 0) {
        if (probe)
            rlog("capture: unsupported X screen format (%d bits a pixel, depth %d)", probe->bits_per_pixel, probe->depth);
        else
            rlog("capture: cannot read the screen");
        if (tmp) tmp->f.destroy_image(tmp);
        grab_close(d, &g);
        atomic_store(&g_cap_dpy, NULL);
        X.CloseDisplay(d);
        cap_ready(-3);
        return NULL;
    }
    if (tmp) tmp->f.destroy_image(tmp);
    void *enc = rdc_linux_jpeg_new(JPEG_QUALITY);
    if (!enc) {
        grab_close(d, &g);
        atomic_store(&g_cap_dpy, NULL);
        X.CloseDisplay(d);
        cap_ready(-1);
        return NULL;
    }
    rlog("capture: X11%s, %ux%u%s", g.use_shm ? " (MIT-SHM)" : "", gw, gh, have_fixes ? "" : ", no cursor (no XFixes)");
    cap_ready(0);

    uint8_t *prev = NULL, *work = NULL;  // the last picture without the cursor; the one being sent
    size_t frame_len = 0;
    int have_prev = 0, failures = 0;
    unsigned long cur_serial = 0;
    int cur_x = -1, cur_y = -1;
    uint64_t next = rdc_now_us(), last_geometry = next;
    while (atomic_load(&g_cap_run)) {
        uint64_t now = rdc_now_us();
        if (now < next) {
            sleep_us(next - now);
            now = rdc_now_us();
        }
        next = next + g_interval_us > now ? next + g_interval_us : now + g_interval_us;
        // The screen changes size (xrandr, a resized VM window): start over at the new size.
        if (now - last_geometry > 1000000) {
            last_geometry = now;
            unsigned nw = 0, nh = 0;
            if (X.GetGeometry(d, root, &r_root, &gx, &gy, &nw, &nh, &bw, &depth) && nw && nh &&
                ((int)nw != g.w || (int)nh != g.h)) {
                rlog("capture: the screen is now %ux%u", nw, nh);
                grab_close(d, &g);
                grab_open(d, scr, root, (int)nw, (int)nh, &g);
                have_prev = 0;
            }
        }
        if (!atomic_load(&g_want_jpeg)) continue;
        px = grab(d, root, &g, &stride, &tmp);
        if (!px) {
            if (++failures == 20) rlog("capture: the screen keeps failing to read");
            continue;
        }
        size_t len = (size_t)stride * (size_t)g.h;
        if (len != frame_len) {
            free(prev);
            free(work);
            prev = malloc(len);
            work = malloc(len);
            frame_len = prev && work ? len : 0;
            have_prev = 0;
            if (!frame_len) {
                if (tmp) tmp->f.destroy_image(tmp);
                continue;
            }
        }
        // Zero traffic for a still screen: send only when the pixels or the cursor change.
        int changed = !have_prev || memcmp(px, prev, len) != 0;
        if (changed) memcpy(prev, px, len);
        have_prev = 1;
        if (tmp) tmp->f.destroy_image(tmp);
        XFixesCursorImage *ci = have_fixes ? X.FixesGetCursorImage(d) : NULL;
        if (ci && (ci->cursor_serial != cur_serial || ci->x != cur_x || ci->y != cur_y)) {
            cur_serial = ci->cursor_serial;
            cur_x = ci->x;
            cur_y = ci->y;
            changed = 1;
        }
        if (atomic_exchange(&g_force_key, 0)) changed = 1;
        if (!changed) {
            if (ci) X.Free(ci);
            continue;
        }
        memcpy(work, prev, len);
        if (ci) {
            draw_cursor(work, g.w, g.h, stride, rgbx, ci);
            X.Free(ci);
        }
        int out_w = g.w, out_h = g.h;
        if (g_max_width > 0 && out_w > g_max_width) {
            out_h = (int)(((long long)g.h * g_max_width + g.w / 2) / g.w) & ~1;
            out_w = g_max_width & ~1;
        }
        const uint8_t *jpg;
        size_t jpg_len;
        uint64_t ts = rdc_now_us();
        if (rdc_linux_jpeg_encode(enc, work, g.w, g.h, stride, rgbx, out_w, out_h, &jpg, &jpg_len) == 0) {
            failures = 0;
            rdc_frame_cb cb = g_cb;
            if (cb) cb(g_cb_ctx, RDC_CODEC_JPEG, jpg, jpg_len, 1, ts, out_w, out_h);
        } else if (++failures == 20) {
            rlog("capture: frames keep failing to encode");
        }
    }
    free(prev);
    free(work);
    rdc_linux_jpeg_free(enc);
    grab_close(d, &g);
    atomic_store(&g_cap_dpy, NULL);
    X.CloseDisplay(d);
    return NULL;
}

int rdc_capture_start(int max_width, int fps, rdc_frame_cb cb, void *ctx) {
    if (g_cap_started) return 0;
    g_cb = cb;
    g_cb_ctx = ctx;
    g_max_width = max_width;
    int f = fps <= 0 || fps > MAX_FPS ? MAX_FPS : fps;
    g_interval_us = 1000000 / (uint64_t)f;
    atomic_store(&g_cap_run, 1);
    g_cap_status = -9;
    if (pthread_create(&g_cap_thread, NULL, capture_main, NULL) != 0) return -1;
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 10;
    pthread_mutex_lock(&g_cap_lock);
    while (g_cap_status == -9)
        if (pthread_cond_timedwait(&g_cap_cond, &g_cap_lock, &deadline) == ETIMEDOUT) break;
    int status = g_cap_status == -9 ? -4 : g_cap_status;
    pthread_mutex_unlock(&g_cap_lock);
    if (status != 0) {
        atomic_store(&g_cap_run, 0);
        pthread_join(g_cap_thread, NULL);
        return status;
    }
    g_cap_started = 1;
    return 0;
}

void rdc_capture_stop(void) {
    if (!g_cap_started) return;
    atomic_store(&g_cap_run, 0);
    pthread_join(g_cap_thread, NULL);
    g_cap_started = 0;
    rlog("capture stopped");
}

int rdc_codec_caps(void) { return 2; }  // JPEG only: no H.264 encoder RDC can count on (VAAPI is the plan)
void rdc_set_codecs(int h264, int jpeg) { atomic_store(&g_want_jpeg, jpeg ? 1 : 0); }
void rdc_request_keyframe(void) { atomic_store(&g_force_key, 1); }
void rdc_set_bitrate(int bits_per_second) {}

// ---------------------------------------------------------------------------
// Input: XTest on a connection of its own, guarded by a lock (calls come from viewers' threads).

static pthread_mutex_t g_in_lock = PTHREAD_MUTEX_INITIALIZER;
static Display *g_in;
static int g_in_tried, g_in_scr;
static Window g_in_root;
static int g_in_w = 1, g_in_h = 1;
static uint64_t g_in_size_at;
static uint8_t g_keys_down[256];
static int g_buttons;
static double g_wheel_x, g_wheel_y;

// The input connection (lock held), or NULL. The screen size is looked up again every second.
static Display *in_display(void) {
    if (!g_in && !g_in_tried) {
        g_in_tried = 1;
        if (!X.ok || !X.xtest) return NULL;
        Display *d = X.OpenDisplay(NULL);
        if (!d) {
            rlog("input: cannot open the X display");
            return NULL;
        }
        int ev, er, maj, min;
        if (!X.TestQueryExtension(d, &ev, &er, &maj, &min)) {
            rlog("input: the X server has no XTest extension — viewers can watch but not control");
            X.CloseDisplay(d);
            return NULL;
        }
        g_in = d;
        atomic_store(&g_in_dpy, d);
        pthread_once(&g_handler_once, install_handler);
        g_in_scr = X.DefaultScreen(d);
        g_in_root = X.RootWindow(d, g_in_scr);
    }
    if (g_in) {
        uint64_t now = rdc_now_us();
        if (now - g_in_size_at > 1000000 || g_in_size_at == 0) {
            g_in_size_at = now;
            Window r;
            int x, y;
            unsigned w, h, bw, depth;
            if (X.GetGeometry(g_in, g_in_root, &r, &x, &y, &w, &h, &bw, &depth) && w && h) {
                g_in_w = (int)w;
                g_in_h = (int)h;
            }
        }
    }
    return g_in;
}

static double clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

static void move_locked(Display *d, double nx, double ny) {
    int x = (int)(clamp01(nx) * (g_in_w - 1) + 0.5), y = (int)(clamp01(ny) * (g_in_h - 1) + 0.5);
    X.TestFakeMotionEvent(d, g_in_scr, x, y, 0);
}

void rdc_mouse_move(double nx, double ny) {
    pthread_mutex_lock(&g_in_lock);
    Display *d = in_display();
    if (d) {
        move_locked(d, nx, ny);
        X.Flush(d);
    }
    pthread_mutex_unlock(&g_in_lock);
}

void rdc_mouse_button(int button, int down, double nx, double ny) {
    unsigned xb = button == 1 ? 2 : button == 2 ? 3 : 1;  // X: 1 left, 2 middle, 3 right
    int bit = 1 << (xb - 1);
    pthread_mutex_lock(&g_in_lock);
    Display *d = in_display();
    if (d) {
        move_locked(d, nx, ny);
        X.TestFakeButtonEvent(d, xb, down ? 1 : 0, 0);
        X.Flush(d);
        if (down)
            g_buttons |= bit;
        else
            g_buttons &= ~bit;
    }
    pthread_mutex_unlock(&g_in_lock);
}

// The browser gives pixels; X scrolls in clicks of buttons 4/5 (up/down) and 6/7 (left/right),
// each about three lines, so a click per 50 pixels.
#define SCROLL_PX 50.0

void rdc_scroll(double dx, double dy) {
    pthread_mutex_lock(&g_in_lock);
    Display *d = in_display();
    if (d) {
        g_wheel_y += dy / SCROLL_PX;
        g_wheel_x += dx / SCROLL_PX;
        int wy = (int)g_wheel_y, wx = (int)g_wheel_x;
        g_wheel_y -= wy;
        g_wheel_x -= wx;
        for (int i = 0; i < abs(wy) && i < 50; i++) {
            unsigned b = wy > 0 ? 5 : 4;
            X.TestFakeButtonEvent(d, b, 1, 0);
            X.TestFakeButtonEvent(d, b, 0, 0);
        }
        for (int i = 0; i < abs(wx) && i < 50; i++) {
            unsigned b = wx > 0 ? 7 : 6;
            X.TestFakeButtonEvent(d, b, 1, 0);
            X.TestFakeButtonEvent(d, b, 0, 0);
        }
        X.Flush(d);
    }
    pthread_mutex_unlock(&g_in_lock);
}

// keycode: an X keycode (evdev code + 8, src/core/keymap.zig), the physical key whatever the layout.
void rdc_key(int keycode, int down) {
    if (keycode < 8 || keycode > 255) return;
    pthread_mutex_lock(&g_in_lock);
    Display *d = in_display();
    if (d) {
        X.TestFakeKeyEvent(d, (unsigned)keycode, down ? 1 : 0, 0);
        X.Flush(d);
        g_keys_down[keycode] = down ? 1 : 0;
    }
    pthread_mutex_unlock(&g_in_lock);
}

void rdc_release_all(void) {
    pthread_mutex_lock(&g_in_lock);
    Display *d = in_display();
    if (d) {
        for (int k = 8; k < 256; k++)
            if (g_keys_down[k]) X.TestFakeKeyEvent(d, (unsigned)k, 0, 0);
        for (unsigned b = 1; b <= 3; b++)
            if (g_buttons & (1 << (b - 1))) X.TestFakeButtonEvent(d, b, 0, 0);
        X.Flush(d);
    }
    memset(g_keys_down, 0, sizeof g_keys_down);
    g_buttons = 0;
    pthread_mutex_unlock(&g_in_lock);
}

// Text, whatever the keyboard layout: each character's keysym goes onto a spare keycode (one
// with no symbols), which is then pressed — the trick xdotool uses. Several spares take turns, so
// an app still reading the previous key does not see it remapped under its feet.
#define MAX_SPARES 8

static uint32_t utf8_next(const unsigned char **p, const unsigned char *end) {
    const unsigned char *s = *p;
    uint32_t c = *s++;
    int extra = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
    if (extra) c &= 0x3F >> extra;
    for (int i = 0; i < extra && s < end && (*s & 0xC0) == 0x80; i++) c = (c << 6) | (*s++ & 0x3F);
    *p = s;
    return c;
}

void rdc_text(const char *utf8, size_t len) {
    if (len == 0 || len > (1 << 20)) return;
    pthread_mutex_lock(&g_in_lock);
    Display *d = in_display();
    if (!d) {
        pthread_mutex_unlock(&g_in_lock);
        return;
    }
    int min = 8, max = 255, per = 0;
    X.DisplayKeycodes(d, &min, &max);
    KeySym *map = X.GetKeyboardMapping(d, (KeyCode)min, max - min + 1, &per);
    int spares[MAX_SPARES], nspare = 0;
    for (int k = max; map && k >= min && nspare < MAX_SPARES; k--) {
        int empty = 1;
        for (int j = 0; j < per; j++)
            if (map[(k - min) * per + j] != NoSymbol) empty = 0;
        if (empty) spares[nspare++] = k;
    }
    if (map) X.Free(map);
    KeySym mapped[MAX_SPARES] = {0};
    KeyCode ret = X.KeysymToKeycode(d, XK_Return), tab = X.KeysymToKeycode(d, XK_Tab);
    if (nspare == 0) rlog("input: no spare key codes to type text with");
    const unsigned char *p = (const unsigned char *)utf8, *end = p + len;
    int turn = 0;
    while (p < end) {
        uint32_t c = utf8_next(&p, end);
        KeyCode kc = 0;
        if (c == '\n' || c == '\r') {
            kc = ret;
        } else if (c == '\t') {
            kc = tab;
        } else if (c >= 0x20 && c != 0x7f && c <= 0x10FFFF && nspare > 0) {
            // Latin-1 keysyms are the code points themselves; the rest are 0x01000000 + code point.
            KeySym ks = (c < 0x100) ? (KeySym)c : (KeySym)(0x01000000UL | c);
            int slot = -1;
            for (int i = 0; i < nspare; i++)
                if (mapped[i] == ks) slot = i;
            if (slot < 0) {
                slot = turn++ % nspare;
                KeySym syms[8];
                int n = per > 0 && per <= 8 ? per : 2;
                for (int j = 0; j < n; j++) syms[j] = ks;
                X.ChangeKeyboardMapping(d, spares[slot], n, syms, 1);
                X.Sync(d, 0);
                mapped[slot] = ks;
                sleep_us(8000);  // apps fetch the new keymap before the key arrives
            }
            kc = (KeyCode)spares[slot];
        }
        if (!kc) continue;
        X.TestFakeKeyEvent(d, kc, 1, 0);
        X.TestFakeKeyEvent(d, kc, 0, 0);
        X.Sync(d, 0);
        sleep_us(2000);
    }
    X.Flush(d);
    pthread_mutex_unlock(&g_in_lock);
}

void rdc_cursor_pos(double *nx, double *ny) {
    *nx = *ny = 0.5;
    pthread_mutex_lock(&g_in_lock);
    Display *d = in_display();
    Window r, child;
    int rx, ry, wx, wy;
    unsigned mask;
    if (d && X.QueryPointer(d, g_in_root, &r, &child, &rx, &ry, &wx, &wy, &mask)) {
        *nx = g_in_w > 1 ? clamp01((double)rx / (g_in_w - 1)) : 0.5;
        *ny = g_in_h > 1 ? clamp01((double)ry / (g_in_h - 1)) : 0.5;
    }
    pthread_mutex_unlock(&g_in_lock);
}
