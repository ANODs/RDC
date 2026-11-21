// The Linux window (contract — ../platform.h): GTK 3, opened with dlopen("libgtk-3.so.0") —
// present on practically every desktop — and the few types and constants used declared here.
// What the host sets from its threads is stored under a lock and shown on the GTK main thread
// (g_idle_add). Without GTK or a display RDC runs without a window, the code and links in the log.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include "linux.h"

typedef struct _GtkWidget GtkWidget;
typedef struct _cairo cairo_t;
typedef void *gpointer;
typedef int gboolean;
typedef unsigned int guint;
typedef unsigned long gulong;
typedef gboolean (*GSourceFunc)(gpointer);
typedef void (*GCallback)(void);

enum { GTK_WINDOW_TOPLEVEL = 0 };
enum { GTK_ORIENTATION_HORIZONTAL = 0, GTK_ORIENTATION_VERTICAL = 1 };
enum { GTK_WIN_POS_CENTER = 1 };
enum { GTK_JUSTIFY_CENTER = 2 };
enum { GTK_ALIGN_START = 1, GTK_ALIGN_CENTER = 3 };
enum { PANGO_ELLIPSIZE_MIDDLE = 2, PANGO_ELLIPSIZE_END = 3 };
enum { GTK_DIALOG_MODAL = 1, GTK_DIALOG_DESTROY_WITH_PARENT = 2 };
enum { GTK_MESSAGE_QUESTION = 2 };
enum { GTK_BUTTONS_NONE = 0 };
enum { GTK_RESPONSE_ACCEPT = -3, GTK_RESPONSE_CANCEL = -6 };
#define GDK_SELECTION_CLIPBOARD ((void *)(uintptr_t)69)

static struct {
    gboolean (*init_check)(int *, char ***);
    void (*main)(void);
    void (*main_quit)(void);
    GtkWidget *(*window_new)(int);
    void (*window_set_title)(GtkWidget *, const char *);
    void (*window_set_resizable)(GtkWidget *, gboolean);
    void (*window_set_position)(GtkWidget *, int);
    void (*window_set_default_size)(GtkWidget *, int, int);
    void (*window_iconify)(GtkWidget *);
    void (*window_present)(GtkWidget *);
    void (*window_set_transient_for)(GtkWidget *, GtkWidget *);
    void (*window_set_urgency_hint)(GtkWidget *, gboolean);
    void (*window_set_icon_name)(GtkWidget *, const char *);
    void (*container_add)(GtkWidget *, GtkWidget *);
    void (*container_set_border_width)(GtkWidget *, guint);
    GtkWidget *(*box_new)(int, int);
    void (*box_pack_start)(GtkWidget *, GtkWidget *, gboolean, gboolean, guint);
    void (*box_set_homogeneous)(GtkWidget *, gboolean);
    GtkWidget *(*label_new)(const char *);
    void (*label_set_text)(GtkWidget *, const char *);
    const char *(*label_get_text)(GtkWidget *);
    void (*label_set_markup)(GtkWidget *, const char *);
    void (*label_set_line_wrap)(GtkWidget *, gboolean);
    void (*label_set_justify)(GtkWidget *, int);
    void (*label_set_max_width_chars)(GtkWidget *, int);
    void (*label_set_selectable)(GtkWidget *, gboolean);
    void (*label_set_ellipsize)(GtkWidget *, int);
    GtkWidget *(*entry_new)(void);
    void (*entry_set_text)(GtkWidget *, const char *);
    const char *(*entry_get_text)(GtkWidget *);
    void (*entry_set_alignment)(GtkWidget *, float);
    void (*entry_set_width_chars)(GtkWidget *, int);
    void (*entry_set_placeholder_text)(GtkWidget *, const char *);
    void (*editable_set_editable)(GtkWidget *, gboolean);
    GtkWidget *(*button_new_with_label)(const char *);
    void (*button_set_label)(GtkWidget *, const char *);
    GtkWidget *(*check_button_new_with_label)(const char *);
    GtkWidget *(*radio_button_new_with_label_from_widget)(GtkWidget *, const char *);
    void (*toggle_button_set_active)(GtkWidget *, gboolean);
    gboolean (*toggle_button_get_active)(GtkWidget *);
    GtkWidget *(*separator_new)(int);
    GtkWidget *(*expander_new)(const char *);
    GtkWidget *(*drawing_area_new)(void);
    void (*widget_set_size_request)(GtkWidget *, int, int);
    void (*widget_queue_draw)(GtkWidget *);
    void (*widget_show_all)(GtkWidget *);
    void (*widget_hide)(GtkWidget *);
    void (*widget_set_visible)(GtkWidget *, gboolean);
    gboolean (*widget_get_visible)(GtkWidget *);
    void (*widget_set_sensitive)(GtkWidget *, gboolean);
    void (*widget_set_no_show_all)(GtkWidget *, gboolean);
    void (*widget_destroy)(GtkWidget *);
    void (*widget_set_halign)(GtkWidget *, int);
    void (*widget_set_margin_top)(GtkWidget *, int);
    int (*widget_get_allocated_width)(GtkWidget *);
    int (*widget_get_allocated_height)(GtkWidget *);
    GtkWidget *(*message_dialog_new)(GtkWidget *, int, int, int, const char *, ...);
    void (*message_dialog_format_secondary_text)(GtkWidget *, const char *, ...);
    GtkWidget *(*dialog_add_button)(GtkWidget *, const char *, int);
    int (*dialog_run)(GtkWidget *);
    void *(*clipboard_get)(void *);
    void (*clipboard_set_text)(void *, const char *, int);
    void (*clipboard_store)(void *);
    gboolean (*show_uri_on_window)(GtkWidget *, const char *, unsigned, void **);  // GTK 3.22+, optional
    gulong (*signal_connect_data)(void *, const char *, GCallback, gpointer, void *, int);
    guint (*idle_add)(GSourceFunc, gpointer);
    guint (*timeout_add)(guint, GSourceFunc, gpointer);
    void (*cairo_set_source_rgb)(cairo_t *, double, double, double);
    void (*cairo_rectangle)(cairo_t *, double, double, double, double);
    void (*cairo_fill)(cairo_t *);
    void (*cairo_paint)(cairo_t *);
} G;

static int gtk_load(void) {
    void *lib = dlopen("libgtk-3.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!lib) return -1;
    static const struct {
        size_t off;
        const char *name;
        int optional;
    } syms[] = {
#define S(field, name) {offsetof(__typeof__(G), field), name, 0}
#define O(field, name) {offsetof(__typeof__(G), field), name, 1}
        S(init_check, "gtk_init_check"),
        S(main, "gtk_main"),
        S(main_quit, "gtk_main_quit"),
        S(window_new, "gtk_window_new"),
        S(window_set_title, "gtk_window_set_title"),
        S(window_set_resizable, "gtk_window_set_resizable"),
        S(window_set_position, "gtk_window_set_position"),
        S(window_set_default_size, "gtk_window_set_default_size"),
        S(window_iconify, "gtk_window_iconify"),
        S(window_present, "gtk_window_present"),
        S(window_set_transient_for, "gtk_window_set_transient_for"),
        S(window_set_urgency_hint, "gtk_window_set_urgency_hint"),
        S(window_set_icon_name, "gtk_window_set_icon_name"),
        S(container_add, "gtk_container_add"),
        S(container_set_border_width, "gtk_container_set_border_width"),
        S(box_new, "gtk_box_new"),
        S(box_pack_start, "gtk_box_pack_start"),
        S(box_set_homogeneous, "gtk_box_set_homogeneous"),
        S(label_new, "gtk_label_new"),
        S(label_set_text, "gtk_label_set_text"),
        S(label_get_text, "gtk_label_get_text"),
        S(label_set_markup, "gtk_label_set_markup"),
        S(label_set_line_wrap, "gtk_label_set_line_wrap"),
        S(label_set_justify, "gtk_label_set_justify"),
        S(label_set_max_width_chars, "gtk_label_set_max_width_chars"),
        S(label_set_selectable, "gtk_label_set_selectable"),
        S(label_set_ellipsize, "gtk_label_set_ellipsize"),
        S(entry_new, "gtk_entry_new"),
        S(entry_set_text, "gtk_entry_set_text"),
        S(entry_get_text, "gtk_entry_get_text"),
        S(entry_set_alignment, "gtk_entry_set_alignment"),
        S(entry_set_width_chars, "gtk_entry_set_width_chars"),
        S(entry_set_placeholder_text, "gtk_entry_set_placeholder_text"),
        S(editable_set_editable, "gtk_editable_set_editable"),
        S(button_new_with_label, "gtk_button_new_with_label"),
        S(button_set_label, "gtk_button_set_label"),
        S(check_button_new_with_label, "gtk_check_button_new_with_label"),
        S(radio_button_new_with_label_from_widget, "gtk_radio_button_new_with_label_from_widget"),
        S(toggle_button_set_active, "gtk_toggle_button_set_active"),
        S(toggle_button_get_active, "gtk_toggle_button_get_active"),
        S(separator_new, "gtk_separator_new"),
        S(expander_new, "gtk_expander_new"),
        S(drawing_area_new, "gtk_drawing_area_new"),
        S(widget_set_size_request, "gtk_widget_set_size_request"),
        S(widget_queue_draw, "gtk_widget_queue_draw"),
        S(widget_show_all, "gtk_widget_show_all"),
        S(widget_hide, "gtk_widget_hide"),
        S(widget_set_visible, "gtk_widget_set_visible"),
        S(widget_get_visible, "gtk_widget_get_visible"),
        S(widget_set_sensitive, "gtk_widget_set_sensitive"),
        S(widget_set_no_show_all, "gtk_widget_set_no_show_all"),
        S(widget_destroy, "gtk_widget_destroy"),
        S(widget_set_halign, "gtk_widget_set_halign"),
        S(widget_set_margin_top, "gtk_widget_set_margin_top"),
        S(widget_get_allocated_width, "gtk_widget_get_allocated_width"),
        S(widget_get_allocated_height, "gtk_widget_get_allocated_height"),
        S(message_dialog_new, "gtk_message_dialog_new"),
        S(message_dialog_format_secondary_text, "gtk_message_dialog_format_secondary_text"),
        S(dialog_add_button, "gtk_dialog_add_button"),
        S(dialog_run, "gtk_dialog_run"),
        S(clipboard_get, "gtk_clipboard_get"),
        S(clipboard_set_text, "gtk_clipboard_set_text"),
        S(clipboard_store, "gtk_clipboard_store"),
        O(show_uri_on_window, "gtk_show_uri_on_window"),
        S(signal_connect_data, "g_signal_connect_data"),
        S(idle_add, "g_idle_add"),
        S(timeout_add, "g_timeout_add"),
        S(cairo_set_source_rgb, "cairo_set_source_rgb"),
        S(cairo_rectangle, "cairo_rectangle"),
        S(cairo_fill, "cairo_fill"),
        S(cairo_paint, "cairo_paint"),
#undef S
#undef O
    };
    for (size_t i = 0; i < sizeof syms / sizeof syms[0]; i++) {
        void *p = dlsym(lib, syms[i].name);
        if (!p) p = dlsym(RTLD_DEFAULT, syms[i].name);
        if (!p && !syms[i].optional) {
            rlog("window: GTK 3 has no %s", syms[i].name);
            return -1;
        }
        memcpy((char *)&G + syms[i].off, &p, sizeof p);
    }
    return 0;
}

#define CONNECT(obj, sig, fn, data) G.signal_connect_data((obj), (sig), (GCallback)(fn), (data), NULL, 0)

// ---------------------------------------------------------------------------
// State: written from any thread, shown on the GTK thread.

static pthread_mutex_t g_ui_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    char code[32], link[256], remote[512], remote_caption[160], status[512], media[160];
    char version[32], upd[512];
    int autoupd, can_install, busy, ai;
    int perm_on;
    char perm_link[512], perm_secret[160];
    uint8_t *link_qr, *auth_qr;
    int link_qr_size, auth_qr_size;
} S = {.code = "— — —", .status = "Starting…", .autoupd = 1};

static atomic_int g_mode;  // 0 — not running yet, 1 — GTK window, 2 — no window
static atomic_int g_refresh_queued;
static rdc_ctx_cb g_on_ready;
static rdc_action_cb g_on_action;
static void *g_app_ctx;

static void action(int a) {
    if (g_on_action) g_on_action(g_app_ctx, a);
}

static void copy_str(char *dst, size_t n, const char *src) { snprintf(dst, n, "%s", src ? src : ""); }

// ---------------------------------------------------------------------------
// Widgets

static GtkWidget *w_main, *w_code, *w_link, *w_copy, *w_remote_caption, *w_remote, *w_remote_row, *w_copy_remote;
static GtkWidget *w_status, *w_kick, *w_media, *w_media_stop, *w_upd_status, *w_check, *w_install;
static GtkWidget *w_auto, *w_perm, *w_perm_row, *w_login, *w_awake;
static GtkWidget *w_relay_default, *w_relay_off, *w_relay_own, *w_relay_url, *w_relay_apply;
static GtkWidget *w_perm_win, *w_perm_link_qr, *w_perm_link, *w_perm_show, *w_perm_auth_qr, *w_perm_key;
static int g_updating;  // the window is setting its own toggles: not the person's clicks
static int g_revealed;  // the authenticator key is shown

static GtkWidget *label(const char *text, int small, int wrap) {
    GtkWidget *l = G.label_new(text);
    if (small) {
        char *m = NULL;
        if (asprintf(&m, "<small>%s</small>", text) >= 0) {
            G.label_set_markup(l, m);
            free(m);
        }
    }
    if (wrap) {
        G.label_set_line_wrap(l, 1);
        G.label_set_justify(l, GTK_JUSTIFY_CENTER);
        G.label_set_max_width_chars(l, 56);
    }
    return l;
}

static void set_label(GtkWidget *l, const char *text) {
    const char *cur = G.label_get_text(l);
    if (!cur || strcmp(cur, text) != 0) G.label_set_text(l, text);
}

static void set_entry(GtkWidget *e, const char *text) {
    const char *cur = G.entry_get_text(e);
    if (!cur || strcmp(cur, text) != 0) G.entry_set_text(e, text);
}

static GtkWidget *row(GtkWidget *a, GtkWidget *b) {
    GtkWidget *r = G.box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    G.box_set_homogeneous(r, 1);
    G.box_pack_start(r, a, 1, 1, 0);
    if (b) G.box_pack_start(r, b, 1, 1, 0);
    return r;
}

static void add(GtkWidget *box, GtkWidget *w) { G.box_pack_start(box, w, 0, 0, 0); }

static void refresh(void) {
    if (!w_main) return;
    char code[32], link[256], remote[512], caption[160], status[512], media[160], ver[32], upd[512], title[64];
    char perm_link[512], perm_secret[160];
    pthread_mutex_lock(&g_ui_lock);
    memcpy(code, S.code, sizeof code);
    memcpy(link, S.link, sizeof link);
    memcpy(remote, S.remote, sizeof remote);
    memcpy(caption, S.remote_caption, sizeof caption);
    memcpy(status, S.status, sizeof status);
    memcpy(media, S.media, sizeof media);
    memcpy(ver, S.version, sizeof ver);
    memcpy(upd, S.upd, sizeof upd);
    memcpy(perm_link, S.perm_link, sizeof perm_link);
    memcpy(perm_secret, S.perm_secret, sizeof perm_secret);
    int autoupd = S.autoupd, can = S.can_install, busy = S.busy, ai = S.ai, perm = S.perm_on;
    pthread_mutex_unlock(&g_ui_lock);

    g_updating = 1;
    snprintf(title, sizeof title, "RDC%s%s", ver[0] ? " " : "", ver);
    G.window_set_title(w_main, title);
    char markup[96];
    snprintf(markup, sizeof markup, "<span size=\"xx-large\" weight=\"bold\">%s</span>", code);
    G.label_set_markup(w_code, markup);
    set_entry(w_link, link);
    set_label(w_remote_caption, caption);
    set_entry(w_remote, remote);
    G.widget_set_visible(w_remote, remote[0] != 0);
    G.widget_set_visible(w_remote_row, remote[0] != 0);
    set_label(w_status, status);
    G.button_set_label(w_kick, ai ? "Stop AI agent" : "Disconnect all");
    set_label(w_media, media);
    G.widget_set_visible(w_media, media[0] != 0);
    G.widget_set_visible(w_media_stop, media[0] != 0);
    set_label(w_upd_status, upd);
    G.widget_set_sensitive(w_check, !busy);
    G.widget_set_visible(w_install, can);
    G.widget_set_sensitive(w_install, can && !busy);
    G.toggle_button_set_active(w_auto, autoupd);
    G.toggle_button_set_active(w_perm, perm);
    G.widget_set_visible(w_perm_row, perm);
    G.toggle_button_set_active(w_login, lx_autostart_on());
    G.toggle_button_set_active(w_awake, rdc_pref_bool("keep_awake", 0));
    // Permanent access window.
    if (!perm) {
        g_revealed = 0;
        G.widget_hide(w_perm_win);
    }
    set_label(w_perm_link, perm_link);
    G.widget_set_visible(w_perm_show, !g_revealed);
    G.widget_set_visible(w_perm_auth_qr, g_revealed);
    G.widget_set_visible(w_perm_key, g_revealed);
    char key_text[200];
    snprintf(key_text, sizeof key_text, "Or type the key: %s", g_revealed ? perm_secret : "");
    set_label(w_perm_key, key_text);
    G.widget_queue_draw(w_perm_link_qr);
    G.widget_queue_draw(w_perm_auth_qr);
    g_updating = 0;
}

static gboolean refresh_idle(gpointer data) {
    atomic_store(&g_refresh_queued, 0);
    refresh();
    return 0;
}

static void post_refresh(void) {
    if (atomic_load(&g_mode) == 1 && !atomic_exchange(&g_refresh_queued, 1)) G.idle_add(refresh_idle, NULL);
}

// --- Buttons

static gboolean copied_done(gpointer data) {
    G.button_set_label((GtkWidget *)data, "Copy link");
    return 0;
}

static void copy_text(GtkWidget *button, const char *text) {
    if (!text[0]) return;
    void *cb = G.clipboard_get(GDK_SELECTION_CLIPBOARD);
    G.clipboard_set_text(cb, text, -1);
    G.clipboard_store(cb);  // stays on the clipboard after RDC quits, where a clipboard manager runs
    G.button_set_label(button, "Copied ✓");
    G.timeout_add(1500, copied_done, button);
}

static void open_uri(const char *uri) {
    if (!uri[0]) return;
    if (G.show_uri_on_window && G.show_uri_on_window(w_main, uri, 0, NULL)) return;
    const char *argv[] = {"xdg-open", uri, NULL};
    if (lx_spawn_detached(argv) != 0) rlog("window: cannot open %s (no xdg-open)", uri);
}

static void on_copy(GtkWidget *b, gpointer remote) {
    char text[512];
    pthread_mutex_lock(&g_ui_lock);
    copy_str(text, sizeof text, remote ? S.remote : S.link);
    pthread_mutex_unlock(&g_ui_lock);
    copy_text(b, text);
}

static void on_open(GtkWidget *b, gpointer remote) {
    char text[512];
    pthread_mutex_lock(&g_ui_lock);
    copy_str(text, sizeof text, remote ? S.remote : S.link);
    pthread_mutex_unlock(&g_ui_lock);
    open_uri(text);
}

static void on_action_button(GtkWidget *b, gpointer a) { action((int)(intptr_t)a); }

static void on_kick(GtkWidget *b, gpointer data) {
    pthread_mutex_lock(&g_ui_lock);
    int ai = S.ai;
    pthread_mutex_unlock(&g_ui_lock);
    action(ai ? RDC_ACTION_STOP_AI : RDC_ACTION_DISCONNECT_ALL);
}

static void on_auto(GtkWidget *b, gpointer data) {
    if (!g_updating) action(G.toggle_button_get_active(b) ? RDC_ACTION_AUTO_UPDATE_ON : RDC_ACTION_AUTO_UPDATE_OFF);
}

static void on_perm(GtkWidget *b, gpointer data) {
    if (!g_updating) action(G.toggle_button_get_active(b) ? RDC_ACTION_PERMANENT_ON : RDC_ACTION_PERMANENT_OFF);
}

static void on_login(GtkWidget *b, gpointer data) {
    if (g_updating) return;
    lx_autostart_set(G.toggle_button_get_active(b));
    post_refresh();
}

static void on_awake(GtkWidget *b, gpointer data) {
    if (g_updating) return;
    int on = G.toggle_button_get_active(b);
    rdc_set_pref_bool("keep_awake", on);
    lx_keep_awake(on);
}

static void on_perm_setup(GtkWidget *b, gpointer data) {
    g_revealed = 0;  // every visit asks again before the key is shown
    refresh();
    G.widget_show_all(w_perm_win);
    G.window_present(w_perm_win);
    refresh();
}

static void on_perm_reveal(GtkWidget *b, gpointer data) {
    g_revealed = 1;
    refresh();
}

static void on_perm_copy(GtkWidget *b, gpointer data) {
    char text[512];
    pthread_mutex_lock(&g_ui_lock);
    copy_str(text, sizeof text, S.perm_link);
    pthread_mutex_unlock(&g_ui_lock);
    copy_text(b, text);
}

static void on_perm_reset(GtkWidget *b, gpointer data) {
    GtkWidget *dlg = G.message_dialog_new(w_main, GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, GTK_MESSAGE_QUESTION,
                                          GTK_BUTTONS_NONE, "%s", "Make a new link and key?");
    G.message_dialog_format_secondary_text(
        dlg, "%s", "The old link and the entry in the authenticator app stop working. You will set both up again.");
    G.dialog_add_button(dlg, "Cancel", GTK_RESPONSE_CANCEL);
    G.dialog_add_button(dlg, "New link and key", GTK_RESPONSE_ACCEPT);
    int r = G.dialog_run(dlg);
    G.widget_destroy(dlg);
    if (r != GTK_RESPONSE_ACCEPT) return;
    g_revealed = 0;
    action(RDC_ACTION_PERMANENT_RESET);
}

// Relay: "Default" removes the pref, "Off" is "off", "My own:" the https:// address in the entry.
static void relay_load(void) {
    char v[512];
    int n = rdc_pref_string("relay", v, sizeof v);
    g_updating = 1;
    if (n <= 0) {
        G.toggle_button_set_active(w_relay_default, 1);
    } else if (strcmp(v, "off") == 0) {
        G.toggle_button_set_active(w_relay_off, 1);
    } else {
        G.toggle_button_set_active(w_relay_own, 1);
        set_entry(w_relay_url, v);
    }
    G.widget_set_sensitive(w_relay_url, n > 0 && strcmp(v, "off") != 0);
    G.widget_set_sensitive(w_relay_apply, n > 0 && strcmp(v, "off") != 0);
    g_updating = 0;
}

static void relay_save(const char *value) {
    char cur[512];
    int n = rdc_pref_string("relay", cur, sizeof cur);
    if ((n <= 0 && !value[0]) || (n > 0 && strcmp(cur, value) == 0)) return;
    rdc_set_pref_string("relay", value);
    rlog("relay: %s", value[0] ? value : "default");
    action(RDC_ACTION_RELAY_CHANGED);
}

static void on_relay_apply(GtkWidget *b, gpointer data) {
    const char *url = G.entry_get_text(w_relay_url);
    while (url && *url == ' ') url++;
    if (!url || strncmp(url, "https://", 8) != 0 || strlen(url) < 12) {
        G.entry_set_placeholder_text(w_relay_url, "https://… — the address of your relay");
        G.entry_set_text(w_relay_url, "");
        return;
    }
    relay_save(url);
}

static void on_relay(GtkWidget *b, gpointer which) {
    if (g_updating || !G.toggle_button_get_active(b)) return;
    int w = (int)(intptr_t)which;
    G.widget_set_sensitive(w_relay_url, w == 2);
    G.widget_set_sensitive(w_relay_apply, w == 2);
    if (w == 0) relay_save("");
    if (w == 1) relay_save("off");
    if (w == 2) on_relay_apply(b, NULL);
}

// QR codes: modules row by row (1 — dark) with a quiet zone of four, black on white.
static gboolean on_draw_qr(GtkWidget *w, cairo_t *cr, gpointer auth) {
    pthread_mutex_lock(&g_ui_lock);
    const uint8_t *m = auth ? S.auth_qr : S.link_qr;
    int n = auth ? S.auth_qr_size : S.link_qr_size;
    int width = G.widget_get_allocated_width(w), height = G.widget_get_allocated_height(w);
    G.cairo_set_source_rgb(cr, 1, 1, 1);
    G.cairo_paint(cr);
    if (m && n > 0) {
        int side = width < height ? width : height;
        int scale = side / (n + 8);
        if (scale < 1) scale = 1;
        double x0 = (width - n * scale) / 2.0, y0 = (height - n * scale) / 2.0;
        G.cairo_set_source_rgb(cr, 0, 0, 0);
        for (int y = 0; y < n; y++)
            for (int x = 0; x < n; x++)
                if (m[y * n + x]) G.cairo_rectangle(cr, x0 + x * scale, y0 + y * scale, scale, scale);
        G.cairo_fill(cr);
    }
    pthread_mutex_unlock(&g_ui_lock);
    return 1;
}

static gboolean on_main_delete(GtkWidget *w, void *event, gpointer data) {
    // With start at login on, RDC stays reachable: closing the window leaves it running.
    if (lx_autostart_on()) {
        G.widget_hide(w);
        rlog("window closed; RDC keeps running (start at login is on) — start rdc again to show the window");
        return 1;
    }
    return 0;
}

static void on_main_destroy(GtkWidget *w, gpointer data) { G.main_quit(); }

static gboolean hide_on_delete(GtkWidget *w, void *event, gpointer data) {
    G.widget_hide(w);
    return 1;
}

static void build_permanent_window(void) {
    w_perm_win = G.window_new(GTK_WINDOW_TOPLEVEL);
    G.window_set_title(w_perm_win, "Permanent access");
    G.window_set_resizable(w_perm_win, 0);
    G.window_set_transient_for(w_perm_win, w_main);
    G.container_set_border_width(w_perm_win, 20);
    CONNECT(w_perm_win, "delete-event", hide_on_delete, NULL);
    GtkWidget *box = G.box_new(GTK_ORIENTATION_VERTICAL, 10);
    G.container_add(w_perm_win, box);
    add(box, label("1. Open the link on your phone — point its camera at this code — and keep it: add the page to the "
                   "home screen.",
                   0, 1));
    w_perm_link_qr = G.drawing_area_new();
    G.widget_set_size_request(w_perm_link_qr, 200, 200);
    G.widget_set_halign(w_perm_link_qr, GTK_ALIGN_CENTER);
    CONNECT(w_perm_link_qr, "draw", on_draw_qr, NULL);
    add(box, w_perm_link_qr);
    w_perm_link = G.label_new("");
    G.label_set_selectable(w_perm_link, 1);
    G.label_set_ellipsize(w_perm_link, PANGO_ELLIPSIZE_MIDDLE);
    G.label_set_max_width_chars(w_perm_link, 56);
    add(box, w_perm_link);
    GtkWidget *copy = G.button_new_with_label("Copy link");
    CONNECT(copy, "clicked", on_perm_copy, NULL);
    G.widget_set_halign(copy, GTK_ALIGN_CENTER);
    add(box, copy);
    GtkWidget *step2 = label("2. Add this computer to the authenticator app: in the app, scan the second code. Anyone "
                             "who sees it can make the codes, so it is shown only when you ask.",
                             0, 1);
    G.widget_set_margin_top(step2, 12);
    add(box, step2);
    w_perm_show = G.button_new_with_label("Show the code for the authenticator app");
    G.widget_set_halign(w_perm_show, GTK_ALIGN_CENTER);
    CONNECT(w_perm_show, "clicked", on_perm_reveal, NULL);
    add(box, w_perm_show);
    w_perm_auth_qr = G.drawing_area_new();
    G.widget_set_size_request(w_perm_auth_qr, 220, 220);
    G.widget_set_halign(w_perm_auth_qr, GTK_ALIGN_CENTER);
    G.widget_set_no_show_all(w_perm_auth_qr, 1);
    CONNECT(w_perm_auth_qr, "draw", on_draw_qr, (gpointer)1);
    add(box, w_perm_auth_qr);
    w_perm_key = G.label_new("");
    G.label_set_selectable(w_perm_key, 1);
    G.widget_set_no_show_all(w_perm_key, 1);
    add(box, w_perm_key);
}

static void build_window(void) {
    w_main = G.window_new(GTK_WINDOW_TOPLEVEL);
    G.window_set_title(w_main, "RDC");
    G.window_set_icon_name(w_main, "preferences-desktop-remote-desktop");
    G.window_set_resizable(w_main, 0);
    G.window_set_position(w_main, GTK_WIN_POS_CENTER);
    G.container_set_border_width(w_main, 18);
    CONNECT(w_main, "delete-event", on_main_delete, NULL);
    CONNECT(w_main, "destroy", on_main_destroy, NULL);
    GtkWidget *box = G.box_new(GTK_ORIENTATION_VERTICAL, 8);
    G.container_add(w_main, box);

    add(box, label("Connection code", 1, 0));
    w_code = G.label_new("");
    G.label_set_selectable(w_code, 1);
    add(box, w_code);
    add(box, label("Browser link on this network", 1, 0));
    w_link = G.entry_new();
    G.editable_set_editable(w_link, 0);
    G.entry_set_alignment(w_link, 0.5f);
    G.entry_set_width_chars(w_link, 40);
    add(box, w_link);
    w_copy = G.button_new_with_label("Copy link");
    GtkWidget *open = G.button_new_with_label("Open in browser");
    CONNECT(w_copy, "clicked", on_copy, NULL);
    CONNECT(open, "clicked", on_open, NULL);
    add(box, row(w_copy, open));

    // The link from anywhere: GitHub Pages finds this computer through public brokers, then WebRTC.
    w_remote_caption = G.label_new("");
    G.label_set_line_wrap(w_remote_caption, 1);
    G.label_set_justify(w_remote_caption, GTK_JUSTIFY_CENTER);
    G.widget_set_margin_top(w_remote_caption, 8);
    add(box, w_remote_caption);
    w_remote = G.entry_new();
    G.editable_set_editable(w_remote, 0);
    G.entry_set_alignment(w_remote, 0.5f);
    G.widget_set_no_show_all(w_remote, 1);
    add(box, w_remote);
    w_copy_remote = G.button_new_with_label("Copy link");
    GtkWidget *open_remote = G.button_new_with_label("Open in browser");
    CONNECT(w_copy_remote, "clicked", on_copy, (gpointer)1);
    CONNECT(open_remote, "clicked", on_open, (gpointer)1);
    w_remote_row = row(w_copy_remote, open_remote);
    G.widget_set_no_show_all(w_remote_row, 1);
    G.widget_show_all(w_remote_row);
    G.widget_hide(w_remote_row);
    add(box, w_remote_row);

    w_status = G.label_new("");
    G.label_set_ellipsize(w_status, PANGO_ELLIPSIZE_END);
    G.label_set_max_width_chars(w_status, 56);
    G.widget_set_margin_top(w_status, 8);
    add(box, w_status);
    GtkWidget *newcode = G.button_new_with_label("New code");
    w_kick = G.button_new_with_label("Disconnect all");
    CONNECT(newcode, "clicked", on_action_button, (gpointer)RDC_ACTION_NEW_CODE);
    CONNECT(w_kick, "clicked", on_kick, NULL);
    add(box, row(newcode, w_kick));
    w_media = G.label_new("");
    G.widget_set_no_show_all(w_media, 1);
    add(box, w_media);
    w_media_stop = G.button_new_with_label("Stop");
    G.widget_set_no_show_all(w_media_stop, 1);
    G.widget_set_halign(w_media_stop, GTK_ALIGN_CENTER);
    CONNECT(w_media_stop, "clicked", on_action_button, (gpointer)RDC_ACTION_STOP_MEDIA);
    add(box, w_media_stop);

    // Updates.
    add(box, G.separator_new(GTK_ORIENTATION_HORIZONTAL));
    w_upd_status = G.label_new("");
    G.label_set_line_wrap(w_upd_status, 1);
    G.label_set_justify(w_upd_status, GTK_JUSTIFY_CENTER);
    G.label_set_max_width_chars(w_upd_status, 56);
    add(box, w_upd_status);
    w_check = G.button_new_with_label("Check for updates");
    w_install = G.button_new_with_label("Update and restart");
    CONNECT(w_check, "clicked", on_action_button, (gpointer)RDC_ACTION_CHECK_UPDATE);
    CONNECT(w_install, "clicked", on_action_button, (gpointer)RDC_ACTION_INSTALL_UPDATE);
    G.widget_set_no_show_all(w_install, 1);
    GtkWidget *upd_row = G.box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    G.box_pack_start(upd_row, w_check, 1, 1, 0);
    G.box_pack_start(upd_row, w_install, 1, 1, 0);
    add(box, upd_row);

    // Settings: everything off until switched on here (but updates).
    GtkWidget *exp = G.expander_new("Settings");
    G.widget_set_margin_top(exp, 6);
    add(box, exp);
    GtkWidget *set = G.box_new(GTK_ORIENTATION_VERTICAL, 4);
    G.container_set_border_width(set, 6);
    G.container_add(exp, set);
    w_auto = G.check_button_new_with_label("Update automatically");
    CONNECT(w_auto, "toggled", on_auto, NULL);
    add(set, w_auto);
    add(set, label("New versions are downloaded from GitHub releases (ANODs/RDC), verified by signature and installed "
                   "when no one is connected.",
                   1, 1));

    w_perm = G.check_button_new_with_label("Permanent access");
    G.widget_set_margin_top(w_perm, 8);
    CONNECT(w_perm, "toggled", on_perm, NULL);
    add(set, w_perm);
    add(set, label("A link of your own that never changes. Whoever opens it must enter the current 6-digit code from "
                   "your authenticator app (Google Authenticator and the like), so the link alone lets no one in.",
                   1, 1));
    GtkWidget *setup = G.button_new_with_label("Set up the phone…");
    GtkWidget *reset = G.button_new_with_label("New link and key…");
    CONNECT(setup, "clicked", on_perm_setup, NULL);
    CONNECT(reset, "clicked", on_perm_reset, NULL);
    w_perm_row = row(setup, reset);
    G.widget_set_no_show_all(w_perm_row, 1);
    G.widget_show_all(w_perm_row);
    G.widget_hide(w_perm_row);
    add(set, w_perm_row);

    w_login = G.check_button_new_with_label("Start RDC at login");
    G.widget_set_margin_top(w_login, 8);
    CONNECT(w_login, "toggled", on_login, NULL);
    add(set, w_login);
    add(set, label("RDC starts minimized when you log in and keeps running when its window is closed.", 1, 1));
    w_awake = G.check_button_new_with_label("Keep this computer awake");
    G.widget_set_margin_top(w_awake, 8);
    CONNECT(w_awake, "toggled", on_awake, NULL);
    add(set, w_awake);
    add(set, label("A sleeping computer cannot be reached. The display may still turn off; a laptop with its lid "
                   "closed may sleep anyway.",
                   1, 1));

    GtkWidget *relay = G.label_new("Relay");
    G.widget_set_halign(relay, GTK_ALIGN_START);
    G.widget_set_margin_top(relay, 8);
    add(set, relay);
    w_relay_default = G.radio_button_new_with_label_from_widget(NULL, "Default");
    w_relay_off = G.radio_button_new_with_label_from_widget(w_relay_default, "Off");
    w_relay_own = G.radio_button_new_with_label_from_widget(w_relay_default, "My own:");
    GtkWidget *radios = G.box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    G.box_pack_start(radios, w_relay_default, 0, 0, 0);
    G.box_pack_start(radios, w_relay_off, 0, 0, 0);
    G.box_pack_start(radios, w_relay_own, 0, 0, 0);
    add(set, radios);
    w_relay_url = G.entry_new();
    G.entry_set_placeholder_text(w_relay_url, "https://…");
    w_relay_apply = G.button_new_with_label("Apply");
    GtkWidget *url_row = G.box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    G.box_pack_start(url_row, w_relay_url, 1, 1, 0);
    G.box_pack_start(url_row, w_relay_apply, 0, 0, 0);
    add(set, url_row);
    add(set, label("When the networks on both sides cannot connect directly, the connection from anywhere goes "
                   "through a relay. My own: the https:// address of your relay (relay/ in the RDC repository).",
                   1, 1));
    CONNECT(w_relay_default, "toggled", on_relay, (gpointer)0);
    CONNECT(w_relay_off, "toggled", on_relay, (gpointer)1);
    CONNECT(w_relay_own, "toggled", on_relay, (gpointer)2);
    CONNECT(w_relay_apply, "clicked", on_relay_apply, NULL);
    CONNECT(w_relay_url, "activate", on_relay_apply, NULL);

    build_permanent_window();
    relay_load();
}

// ---------------------------------------------------------------------------
// The window comes forward when a second launch asks (rdc_app_prepare's socket).

static gboolean present_idle(gpointer data) {
    if (w_main) {
        G.widget_show_all(w_main);
        refresh();
        G.window_present(w_main);
    }
    return 0;
}

static void *instance_main(void *arg) {
    int fd = lx_instance_fd();
    for (;;) {
        int c = accept4(fd, NULL, NULL, SOCK_CLOEXEC);
        if (c < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            return NULL;
        }
        char buf[16];
        if (read(c, buf, sizeof buf) < 0) {
        }
        close(c);
        if (atomic_load(&g_mode) == 1)
            G.idle_add(present_idle, NULL);
        else
            rlog("another launch of RDC asked for the window, but this one has none");
    }
    return NULL;
}

static gboolean ready_idle(gpointer data) {
    if (g_on_ready) g_on_ready(g_app_ctx);
    refresh();
    return 0;
}

void rdc_app_run(rdc_ctx_cb on_ready, rdc_action_cb on_action, void *ctx) {
    g_on_ready = on_ready;
    g_on_action = on_action;
    g_app_ctx = ctx;
    lx_autostart_repair();
    lx_keep_awake(rdc_pref_bool("keep_awake", 0));
    if (lx_instance_fd() >= 0) {
        pthread_t t;
        if (pthread_create(&t, NULL, instance_main, NULL) == 0) pthread_detach(t);
    }
    const char *display = getenv("DISPLAY"), *wayland = getenv("WAYLAND_DISPLAY");
    int have_display = (display && display[0]) || (wayland && wayland[0]);
    const char *why = NULL;
    if (!have_display)
        why = "no display";
    else if (gtk_load() != 0)
        why = "GTK 3 (libgtk-3.so.0) is not installed";
    else if (!G.init_check(NULL, NULL))
        why = "GTK cannot open the display";
    if (why) {
        // Like --no-ui: the host keeps running, the code and links go to the log.
        rlog("window: %s — running without a window; the code and links are in this log", why);
        atomic_store(&g_mode, 2);
        if (on_ready) on_ready(ctx);
        for (;;) pause();
    }
    build_window();
    atomic_store(&g_mode, 1);
    refresh();
    // Started at login: stay minimized until the person looks for it.
    if (lx_has_arg("--login")) G.window_iconify(w_main);
    G.widget_show_all(w_main);
    refresh();
    G.idle_add(ready_idle, NULL);
    G.main();
    rlog("window closed, RDC quits");
    exit(0);
}

void rdc_app_set_info(const char *code, const char *link) {
    pthread_mutex_lock(&g_ui_lock);
    int changed = strcmp(S.code, code) != 0 || strcmp(S.link, link) != 0;
    copy_str(S.code, sizeof S.code, code);
    copy_str(S.link, sizeof S.link, link);
    pthread_mutex_unlock(&g_ui_lock);
    if (changed && atomic_load(&g_mode) == 2) rlog("code %s, link %s", code, link);
    post_refresh();
}

void rdc_app_set_remote(const char *caption, const char *link) {
    pthread_mutex_lock(&g_ui_lock);
    copy_str(S.remote_caption, sizeof S.remote_caption, caption);
    copy_str(S.remote, sizeof S.remote, link);
    pthread_mutex_unlock(&g_ui_lock);
    post_refresh();
}

void rdc_app_set_status(const char *text) {
    pthread_mutex_lock(&g_ui_lock);
    copy_str(S.status, sizeof S.status, text);
    pthread_mutex_unlock(&g_ui_lock);
    post_refresh();
}

void rdc_app_set_permissions(int screen_ok, int input_ok) {}

void rdc_app_set_media(const char *text) {
    pthread_mutex_lock(&g_ui_lock);
    copy_str(S.media, sizeof S.media, text);
    pthread_mutex_unlock(&g_ui_lock);
    post_refresh();
}

static gboolean urgent_idle(gpointer data) {
    if (w_main) G.window_set_urgency_hint(w_main, 1);
    return 0;
}

void rdc_app_set_ai(int active) {
    pthread_mutex_lock(&g_ui_lock);
    int was = S.ai;
    S.ai = active != 0;
    pthread_mutex_unlock(&g_ui_lock);
    if (active && !was && atomic_load(&g_mode) == 1) G.idle_add(urgent_idle, NULL);  // the taskbar asks for a look
    post_refresh();
}

void rdc_settings_update(const char *version, int auto_update, const char *status, int can_install, int busy) {
    pthread_mutex_lock(&g_ui_lock);
    copy_str(S.version, sizeof S.version, version);
    copy_str(S.upd, sizeof S.upd, status);
    S.autoupd = auto_update;
    S.can_install = can_install;
    S.busy = busy;
    pthread_mutex_unlock(&g_ui_lock);
    post_refresh();
}

void rdc_app_set_permanent(int on, const char *link, const uint8_t *link_qr, int link_qr_size, const uint8_t *auth_qr,
                           int auth_qr_size, const char *secret_text) {
    uint8_t *lq = NULL, *aq = NULL;
    if (on && link_qr && link_qr_size > 0 && (lq = malloc((size_t)link_qr_size * (size_t)link_qr_size)) != NULL)
        memcpy(lq, link_qr, (size_t)link_qr_size * (size_t)link_qr_size);
    if (on && auth_qr && auth_qr_size > 0 && (aq = malloc((size_t)auth_qr_size * (size_t)auth_qr_size)) != NULL)
        memcpy(aq, auth_qr, (size_t)auth_qr_size * (size_t)auth_qr_size);
    pthread_mutex_lock(&g_ui_lock);
    S.perm_on = on != 0;
    copy_str(S.perm_link, sizeof S.perm_link, on ? link : "");
    copy_str(S.perm_secret, sizeof S.perm_secret, on ? secret_text : "");
    free(S.link_qr);
    free(S.auth_qr);
    S.link_qr = lq;
    S.link_qr_size = lq ? link_qr_size : 0;
    S.auth_qr = aq;
    S.auth_qr_size = aq ? auth_qr_size : 0;
    pthread_mutex_unlock(&g_ui_lock);
    if (on && atomic_load(&g_mode) == 2) rlog("permanent access: on, link %s", link);
    post_refresh();
}
