// Linux platform layer for RDC (contract — ../platform.h): the process, log, files, network,
// prefs, permanent access, updates, start at login and keeping awake. Capture and input are in
// x11.c, the window in window.c. Nothing here links against a desktop library: the binary needs
// only glibc, and the X11 and GTK libraries are opened with dlopen when they are there.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <limits.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "linux.h"

extern char **environ;

// ---------------------------------------------------------------------------
// Paths

static const char *home_dir(void) {
    const char *h = getenv("HOME");
    if (h && h[0]) return h;
    struct passwd *pw = getpwuid(getuid());
    return pw && pw->pw_dir ? pw->pw_dir : "";
}

// $XDG_<name> or ~/<fallback>, e.g. XDG_CONFIG_HOME → ~/.config.
static void xdg_dir(char *out, size_t n, const char *env, const char *fallback) {
    const char *v = getenv(env);
    if (v && v[0] == '/')
        snprintf(out, n, "%s", v);
    else
        snprintf(out, n, "%s/%s", home_dir(), fallback);
}

static int mkdirs(const char *path, mode_t mode) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    return mkdir(tmp, mode) == 0 || errno == EEXIST ? 0 : -1;
}

static char g_config_dir[PATH_MAX];

static void config_dir_init(void) {
    char base[PATH_MAX - 8];
    xdg_dir(base, sizeof base, "XDG_CONFIG_HOME", ".config");
    snprintf(g_config_dir, sizeof g_config_dir, "%s/rdc", base);
    if (mkdirs(g_config_dir, 0700) != 0) g_config_dir[0] = 0;
}

const char *lx_config_dir(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, config_dir_init);
    return g_config_dir;
}

int lx_exe_path(char *buf, size_t n) {
    ssize_t len = readlink("/proc/self/exe", buf, n - 1);
    if (len <= 0) return -1;
    buf[len] = 0;
    // A binary replaced on disk while it runs reads as "… (deleted)".
    const char *tail = " (deleted)";
    size_t tl = strlen(tail);
    if ((size_t)len > tl && strcmp(buf + len - tl, tail) == 0) buf[len - tl] = 0;
    return 0;
}

// This process's arguments as an argv array (malloc, NULL-terminated; free the array and *store).
static char **own_argv(char **store) {
    *store = NULL;
    int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap + 1);
    ssize_t got;
    while (buf && (got = read(fd, buf + len, cap - len)) > 0) {
        len += (size_t)got;
        if (len == cap) {
            char *nb = realloc(buf, cap * 2 + 1);
            if (!nb) break;
            buf = nb;
            cap *= 2;
        }
    }
    close(fd);
    if (!buf) return NULL;
    buf[len] = 0;
    int count = 0;
    for (size_t i = 0; i < len; i++)
        if (buf[i] == 0) count++;
    char **argv = calloc((size_t)count + 1, sizeof(char *));
    if (!argv) {
        free(buf);
        return NULL;
    }
    int k = 0;
    for (size_t i = 0; i < len && k < count; i += strlen(buf + i) + 1) argv[k++] = buf + i;
    *store = buf;
    return argv;
}

int lx_has_arg(const char *arg) {
    char *store;
    char **argv = own_argv(&store);
    int found = 0;
    for (int i = 1; argv && argv[i]; i++)
        if (strcmp(argv[i], arg) == 0) found = 1;
    free(argv);
    free(store);
    return found;
}

int lx_in_path(const char *name) {
    const char *path = getenv("PATH");
    if (!path || !path[0]) path = "/usr/local/bin:/usr/bin:/bin";
    char buf[PATH_MAX];
    for (const char *p = path; *p;) {
        const char *end = strchr(p, ':');
        size_t n = end ? (size_t)(end - p) : strlen(p);
        if (n > 0 && n + strlen(name) + 2 < sizeof buf) {
            memcpy(buf, p, n);
            buf[n] = '/';
            strcpy(buf + n + 1, name);
            if (access(buf, X_OK) == 0) return 1;
        }
        if (!end) break;
        p = end + 1;
    }
    return 0;
}

static void *reap_main(void *arg) {
    pid_t pid = (pid_t)(intptr_t)arg;
    int st;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
    }
    return NULL;
}

int lx_spawn_detached(const char *const argv[]) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    pid_t pid;
    int rc = posix_spawnp(&pid, argv[0], &fa, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) return -1;
    pthread_t t;
    if (pthread_create(&t, NULL, reap_main, (void *)(intptr_t)pid) == 0) pthread_detach(t);
    return 0;
}

// Runs argv (looked up in PATH), its stdout (and stderr, with merge) into out; waits at most timeout_ms.
// Returns the exit code, or -1 when it could not run or was killed.
static int run_capture(const char *const argv[], char *out, size_t out_len, int merge_stderr, int timeout_ms) {
    int p[2];
    if (pipe2(p, O_CLOEXEC) != 0) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, p[1], 1);
    if (merge_stderr)
        posix_spawn_file_actions_adddup2(&fa, p[1], 2);
    else
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    pid_t pid;
    int rc = posix_spawnp(&pid, argv[0], &fa, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(p[1]);
    if (rc != 0) {
        close(p[0]);
        return -1;
    }
    size_t len = 0;
    uint64_t deadline = rdc_now_us() + (uint64_t)timeout_ms * 1000;
    int killed = 0;
    for (;;) {
        uint64_t now = rdc_now_us();
        if (now >= deadline) {
            kill(pid, SIGKILL);
            killed = 1;
            break;
        }
        struct pollfd pf = {p[0], POLLIN, 0};
        int r = poll(&pf, 1, (int)((deadline - now) / 1000) + 1);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) continue;
        char tmp[4096];
        ssize_t got = read(p[0], tmp, sizeof tmp);
        if (got <= 0) break;
        if (out && len + 1 < out_len) {
            size_t take = (size_t)got < out_len - 1 - len ? (size_t)got : out_len - 1 - len;
            memcpy(out + len, tmp, take);
            len += take;
        }
    }
    close(p[0]);
    if (out && out_len) out[len] = 0;
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
    }
    if (killed || !WIFEXITED(st)) return -1;
    return WEXITSTATUS(st);
}

// ---------------------------------------------------------------------------
// Time, log

static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_log_fd = -1;

uint64_t rdc_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000;
}

void rdc_log(const char *msg) {
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    char line[1400];
    int n = snprintf(line, sizeof line, "[%02d:%02d:%02d] %s\n", tm.tm_hour, tm.tm_min, tm.tm_sec, msg);
    if (n < 0) return;
    if (n >= (int)sizeof line) {
        n = (int)sizeof line - 1;
        line[n - 1] = '\n';
    }
    pthread_mutex_lock(&g_log_lock);
    if (g_log_fd >= 0 && write(g_log_fd, line, (size_t)n) < 0) {
    }
    if (write(2, line, (size_t)n) < 0) {
    }
    pthread_mutex_unlock(&g_log_lock);
}

void rlog(const char *fmt, ...) {
    char buf[1200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    rdc_log(buf);
}

void rdc_init(void) {
    // ~/.local/state/rdc/rdc.log (XDG_STATE_HOME); over 4 MB it becomes rdc.old.log.
    char dir[PATH_MAX - 32], path[PATH_MAX], old[PATH_MAX];
    xdg_dir(dir, sizeof dir, "XDG_STATE_HOME", ".local/state");
    strncat(dir, "/rdc", sizeof dir - strlen(dir) - 1);
    if (mkdirs(dir, 0700) == 0) {
        snprintf(path, sizeof path, "%s/rdc.log", dir);
        struct stat st;
        if (stat(path, &st) == 0 && st.st_size > (4 << 20)) {
            snprintf(old, sizeof old, "%s/rdc.old.log", dir);
            rename(path, old);
        }
        int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
        pthread_mutex_lock(&g_log_lock);
        g_log_fd = fd;
        pthread_mutex_unlock(&g_log_lock);
    }
    signal(SIGPIPE, SIG_IGN);
    // Before any other Xlib call in the process, GTK's included: capture, input and the window
    // each have their own connection to the X server, on different threads.
    lx_x11_init();
}

// Linux asks for no permissions for screen capture or input under X11.
int rdc_screen_access(int prompt) { return 1; }
int rdc_input_access(int prompt) { return 1; }
void rdc_open_privacy(int which) {}

// ---------------------------------------------------------------------------
// Files, network, system

void *rdc_read_file(const char *path, size_t *len) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > (64LL << 20)) {
        close(fd);
        return NULL;
    }
    size_t want = (size_t)st.st_size, total = 0;
    uint8_t *buf = malloc(want ? want : 1);
    ssize_t got;
    while (buf && total < want && (got = read(fd, buf + total, want - total)) > 0) total += (size_t)got;
    close(fd);
    if (!buf) return NULL;
    *len = total;
    return buf;
}

// The interface of the default route, from /proc/net/route ("" if none).
static void default_iface(char *out, size_t n) {
    out[0] = 0;
    FILE *f = fopen("/proc/net/route", "re");
    if (!f) return;
    char line[256], name[64];
    unsigned long dest, gw, flags;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "%63s %lx %lx %lx", name, &dest, &gw, &flags) == 4 && dest == 0 && (flags & 1)) {
            snprintf(out, n, "%s", name);
            break;
        }
    }
    fclose(f);
}

static int virtual_iface(const char *name) {
    static const char *const prefixes[] = {"docker", "veth", "br-", "virbr", "vboxnet", "vmnet", "tun", "tap", "wg", "zt", "tailscale", "lxc", "cni", "flannel"};
    for (size_t i = 0; i < sizeof prefixes / sizeof prefixes[0]; i++)
        if (strncmp(name, prefixes[i], strlen(prefixes[i])) == 0) return 1;
    return 0;
}

int rdc_lan_ipv4(char *buf, int buflen) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return -1;
    char def[64];
    default_iface(def, sizeof def);
    int found = -1;
    // The interface of the default route first, then real interfaces, then anything up.
    for (int pass = 0; pass < 3 && found < 0; pass++) {
        for (struct ifaddrs *a = list; a && found < 0; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
            if (!(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK)) continue;
            if (pass == 0 && strcmp(a->ifa_name, def) != 0) continue;
            if (pass == 1 && virtual_iface(a->ifa_name)) continue;
            const uint8_t *b = (const uint8_t *)&((struct sockaddr_in *)a->ifa_addr)->sin_addr;
            if (b[0] == 169 && b[1] == 254) continue;
            snprintf(buf, (size_t)buflen, "%u.%u.%u.%u", b[0], b[1], b[2], b[3]);
            found = 0;
        }
    }
    freeifaddrs(list);
    return found;
}

int rdc_computer_name(char *buf, int buflen) {
    if (buflen <= 1 || gethostname(buf, (size_t)buflen) != 0) return -1;
    buf[buflen - 1] = 0;
    char *dot = strchr(buf, '.');
    if (dot) *dot = 0;
    return buf[0] ? 0 : -1;
}

// ---------------------------------------------------------------------------
// Updates

static void cache_dir(char *out, size_t n, const char *sub) {
    char base[PATH_MAX - 64];
    xdg_dir(base, sizeof base, "XDG_CACHE_HOME", ".cache");
    snprintf(out, n, "%s/rdc/%s", base, sub);
    mkdirs(out, 0700);
}

// HTTP(S) through curl, which practically every distribution has: the body goes to a temporary
// file, the status code to stdout.
void *rdc_http_get(const char *url, size_t max_len, size_t *len, int *status) {
    *status = -1;
    *len = 0;
    if (!lx_in_path("curl")) {
        static int told;
        if (!told++) rlog("network: curl is not installed — RDC needs it to check for updates");
        return NULL;
    }
    char dir[PATH_MAX], file[PATH_MAX], max[32], code[64];
    cache_dir(dir, sizeof dir - 32, "http");
    snprintf(file, sizeof file, "%s/body-%d-%lu", dir, (int)getpid(), (unsigned long)pthread_self());
    snprintf(max, sizeof max, "%zu", max_len);
    const char *argv[] = {"curl", "-sS", "-L", "--proto", "=https,http", "--connect-timeout", "15", "--max-time", "600",
                          "-A", "RDC-updater", "--max-filesize", max, "-o", file, "-w", "%{http_code}", "--", url, NULL};
    int rc = run_capture(argv, code, sizeof code, 0, 610 * 1000);
    int http = atoi(code);
    if (http > 0) *status = http;
    uint8_t *body = NULL;
    if (rc == 0 && http > 0) {
        size_t n = 0;
        body = rdc_read_file(file, &n);
        if (body && n > max_len) {
            free(body);
            body = NULL;
        } else if (body) {
            *len = n;
        }
    } else if (rc != 63) {  // 63: bigger than --max-filesize
        rlog("network: request failed (curl %d)", rc);
    }
    unlink(file);
    return body;
}

int rdc_write_temp(const char *name, const void *data, size_t len, char *path_out, int path_len) {
    char dir[PATH_MAX - 300], path[PATH_MAX];
    cache_dir(dir, sizeof dir, "download");
    const char *base = strrchr(name, '/');
    base = base ? base + 1 : name;
    if (!base[0] || strcmp(base, ".") == 0 || strcmp(base, "..") == 0) return -1;
    snprintf(path, sizeof path, "%s/%s", dir, base);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    size_t done = 0;
    while (done < len) {
        ssize_t w = write(fd, (const uint8_t *)data + done, len - done);
        if (w <= 0) {
            close(fd);
            return -1;
        }
        done += (size_t)w;
    }
    close(fd);
    if ((int)strlen(path) >= path_len) return -1;
    strcpy(path_out, path);
    return 0;
}

// The binary to replace; -1 when RDC cannot replace it (a read-only folder, e.g. /usr/bin).
int rdc_install_path(char *buf, int buflen) {
    char exe[PATH_MAX], dir[PATH_MAX];
    if (lx_exe_path(exe, sizeof exe) != 0) return -1;
    snprintf(dir, sizeof dir, "%s", exe);
    char *slash = strrchr(dir, '/');
    if (!slash) return -1;
    *slash = 0;
    if (access(dir[0] ? dir : "/", W_OK) != 0 || (int)strlen(exe) >= buflen) return -1;
    strcpy(buf, exe);
    return 0;
}

// Leftovers of an update that did not finish: <binary>.update-<pid> next to the binary.
void rdc_cleanup_old_install(void) {
    char exe[PATH_MAX], dir[PATH_MAX], prefix[NAME_MAX + 16], path[PATH_MAX];
    if (lx_exe_path(exe, sizeof exe) != 0) return;
    snprintf(dir, sizeof dir, "%s", exe);
    char *slash = strrchr(dir, '/');
    if (!slash) return;
    *slash = 0;
    snprintf(prefix, sizeof prefix, "%s.update-", slash + 1);
    DIR *d = opendir(dir[0] ? dir : "/");
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, prefix, strlen(prefix)) != 0) continue;
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        unlink(path);
    }
    closedir(d);
}

static int copy_file(const char *from, const char *to, mode_t mode) {
    int in = open(from, O_RDONLY | O_CLOEXEC);
    if (in < 0) return -1;
    int out = open(to, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
    if (out < 0) {
        close(in);
        return -1;
    }
    char buf[65536];
    ssize_t got;
    int rc = 0;
    while ((got = read(in, buf, sizeof buf)) > 0) {
        for (ssize_t done = 0; done < got;) {
            ssize_t w = write(out, buf + done, (size_t)(got - done));
            if (w <= 0) {
                rc = -1;
                break;
            }
            done += w;
        }
        if (rc) break;
    }
    if (got < 0) rc = -1;
    if (fsync(out) != 0) rc = -1;
    close(in);
    close(out);
    fchmodat(AT_FDCWD, to, mode, 0);
    return rc;
}

// The release asset is the binary itself: it goes next to the running one, says its version when
// asked, replaces it with one rename (a running binary can be replaced, not overwritten) and
// this process becomes the new version with exec — the same pid, arguments and environment.
int rdc_install_update(const char *file_path, const char *version) {
    char exe[PATH_MAX], fresh[PATH_MAX + 32];
    if (lx_exe_path(exe, sizeof exe) != 0) return -1;
    uint8_t magic[4] = {0};
    int fd = open(file_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0 || read(fd, magic, 4) != 4 || memcmp(magic, "\x7f" "ELF", 4) != 0) {
        if (fd >= 0) close(fd);
        rlog("update: the download is not a Linux binary");
        return -3;
    }
    close(fd);
    snprintf(fresh, sizeof fresh, "%s.update-%d", exe, (int)getpid());
    unlink(fresh);
    if (copy_file(file_path, fresh, 0755) != 0) {
        rlog("update: cannot write %s: %s", fresh, strerror(errno));
        unlink(fresh);
        return -5;
    }
    // "rdc version" prints "RDC <version>" — and proves the new binary runs on this system.
    char out[512];
    const char *argv[] = {fresh, "version", NULL};
    int rc = run_capture(argv, out, sizeof out, 1, 10000);
    char want[64];
    snprintf(want, sizeof want, "RDC %s", version);
    const char *at = strstr(out, want);
    char after = at ? at[strlen(want)] : 0;
    if (rc != 0 || !at || (after != 0 && after != '\n' && after != ' ' && after != '\r')) {
        rlog("update: the new binary does not run or is not version %s", version);
        unlink(fresh);
        return -4;
    }
    if (rename(fresh, exe) != 0) {
        rlog("update: cannot put the new version in place: %s", strerror(errno));
        unlink(fresh);
        return -7;
    }
    unlink(file_path);
    rlog("update %s installed, restarting", version);
    char *store;
    char **args = own_argv(&store);
    if (args && args[0]) {
        execv(exe, args);
    } else {
        char *const fallback[] = {exe, NULL};
        execv(exe, fallback);
    }
    rlog("update: cannot restart: %s", strerror(errno));
    free(args);
    free(store);
    return -8;
}

// ---------------------------------------------------------------------------
// Prefs: key=value lines in ~/.config/rdc/prefs, read once, written whole on every change.

#define MAX_PREFS 64
static pthread_mutex_t g_pref_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_prefs_loaded, g_pref_count;
static char *g_pref_key[MAX_PREFS], *g_pref_val[MAX_PREFS];

static void prefs_path(char *out, size_t n) { snprintf(out, n, "%s/prefs", lx_config_dir()); }

static void prefs_load_locked(void) {
    if (g_prefs_loaded) return;
    g_prefs_loaded = 1;
    char path[PATH_MAX];
    prefs_path(path, sizeof path);
    FILE *f = fopen(path, "re");
    if (!f) return;
    char line[2048];
    while (fgets(line, sizeof line, f) && g_pref_count < MAX_PREFS) {
        line[strcspn(line, "\r\n")] = 0;
        char *eq = strchr(line, '=');
        if (!eq || eq == line) continue;
        *eq = 0;
        g_pref_key[g_pref_count] = strdup(line);
        g_pref_val[g_pref_count] = strdup(eq + 1);
        if (g_pref_key[g_pref_count] && g_pref_val[g_pref_count]) g_pref_count++;
    }
    fclose(f);
}

static void prefs_save_locked(void) {
    char path[PATH_MAX], tmp[PATH_MAX + 8];
    prefs_path(path, sizeof path);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "we");
    if (!f) {
        rlog("prefs: cannot write %s: %s", tmp, strerror(errno));
        return;
    }
    for (int i = 0; i < g_pref_count; i++) fprintf(f, "%s=%s\n", g_pref_key[i], g_pref_val[i]);
    int ok = fflush(f) == 0 && fsync(fileno(f)) == 0;
    fclose(f);
    if (!ok || rename(tmp, path) != 0) rlog("prefs: cannot save %s", path);
}

static int pref_find_locked(const char *key) {
    for (int i = 0; i < g_pref_count; i++)
        if (strcmp(g_pref_key[i], key) == 0) return i;
    return -1;
}

static void pref_set_locked(const char *key, const char *value) {
    int i = pref_find_locked(key);
    if (!value || !value[0]) {
        if (i < 0) return;
        free(g_pref_key[i]);
        free(g_pref_val[i]);
        g_pref_count--;
        g_pref_key[i] = g_pref_key[g_pref_count];
        g_pref_val[i] = g_pref_val[g_pref_count];
    } else {
        char *v = strdup(value);
        if (!v) return;
        for (char *p = v; *p; p++)
            if (*p == '\n' || *p == '\r') *p = ' ';
        if (i >= 0) {
            free(g_pref_val[i]);
            g_pref_val[i] = v;
        } else if (g_pref_count < MAX_PREFS && (g_pref_key[g_pref_count] = strdup(key)) != NULL) {
            g_pref_val[g_pref_count++] = v;
        } else {
            free(v);
            return;
        }
    }
    prefs_save_locked();
}

int rdc_pref_bool(const char *key, int def) {
    pthread_mutex_lock(&g_pref_lock);
    prefs_load_locked();
    int i = pref_find_locked(key);
    int v = i < 0 ? def : atoi(g_pref_val[i]) != 0;
    pthread_mutex_unlock(&g_pref_lock);
    return v;
}

void rdc_set_pref_bool(const char *key, int value) {
    pthread_mutex_lock(&g_pref_lock);
    prefs_load_locked();
    pref_set_locked(key, value ? "1" : "0");
    pthread_mutex_unlock(&g_pref_lock);
}

int rdc_pref_string(const char *key, char *buf, int buflen) {
    pthread_mutex_lock(&g_pref_lock);
    prefs_load_locked();
    int i = pref_find_locked(key), n = -1;
    if (i >= 0 && (int)strlen(g_pref_val[i]) < buflen) {
        n = (int)strlen(g_pref_val[i]);
        memcpy(buf, g_pref_val[i], (size_t)n + 1);
    }
    pthread_mutex_unlock(&g_pref_lock);
    return n;
}

void rdc_set_pref_string(const char *key, const char *value) {
    pthread_mutex_lock(&g_pref_lock);
    prefs_load_locked();
    pref_set_locked(key, value);
    pthread_mutex_unlock(&g_pref_lock);
}

// ---------------------------------------------------------------------------
// Permanent access: the seed file, open and locked (flock) for as long as this process lives.

static int g_seed_fd = -1;
static pthread_mutex_t g_seed_lock = PTHREAD_MUTEX_INITIALIZER;

static int seed_open_locked(void) {
    if (g_seed_fd >= 0) return 0;
    const char *dir = lx_config_dir();
    if (!dir[0]) return -1;
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/permanent", dir);
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) {
        rlog("permanent access: cannot open the key file: %s", strerror(errno));
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        return -2;
    }
    if (fchmod(fd, 0600) != 0) {
    }
    g_seed_fd = fd;
    return 0;
}

int rdc_seed_load(void *buf, int cap) {
    pthread_mutex_lock(&g_seed_lock);
    int rc = seed_open_locked();
    if (rc == 0) {
        ssize_t n = pread(g_seed_fd, buf, (size_t)cap, 0);
        rc = n < 0 ? -1 : (int)n;
    }
    pthread_mutex_unlock(&g_seed_lock);
    return rc;
}

int rdc_seed_save(const void *data, int len) {
    pthread_mutex_lock(&g_seed_lock);
    int rc = seed_open_locked() == 0 ? 0 : -1;
    if (rc == 0 && (ftruncate(g_seed_fd, 0) != 0 || pwrite(g_seed_fd, data, (size_t)len, 0) != len)) rc = -1;
    if (rc == 0) fsync(g_seed_fd);
    pthread_mutex_unlock(&g_seed_lock);
    return rc;
}

// ---------------------------------------------------------------------------
// Start at login: an XDG autostart entry (~/.config/autostart/rdc.desktop) that runs this binary
// with --login: the window starts minimized, and closing it leaves RDC running.

static void autostart_path(char *out, size_t n) {
    char base[PATH_MAX - 32];
    xdg_dir(base, sizeof base, "XDG_CONFIG_HOME", ".config");
    snprintf(out, n, "%s/autostart/rdc.desktop", base);
}

int lx_autostart_on(void) {
    char path[PATH_MAX];
    autostart_path(path, sizeof path);
    return access(path, F_OK) == 0;
}

int lx_autostart_set(int on) {
    char path[PATH_MAX], exe[PATH_MAX];
    autostart_path(path, sizeof path);
    if (!on) {
        if (unlink(path) != 0 && errno != ENOENT) {
            rlog("start at login: cannot remove %s: %s", path, strerror(errno));
            return -1;
        }
        rlog("start at login: off");
        return 0;
    }
    if (lx_exe_path(exe, sizeof exe) != 0) return -1;
    // Exec= quoting (Desktop Entry spec): inside "…", \ " ` $ get a backslash, which the string
    // escaping doubles; % becomes %%.
    char quoted[PATH_MAX * 3];
    size_t q = 0;
    for (const char *p = exe; *p && q + 4 < sizeof quoted; p++) {
        if (*p == '"' || *p == '`' || *p == '$' || *p == '\\') {
            quoted[q++] = '\\';
            quoted[q++] = '\\';
        } else if (*p == '%') {
            quoted[q++] = '%';
        }
        quoted[q++] = *p;
    }
    quoted[q] = 0;
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s", path);
    *strrchr(dir, '/') = 0;
    mkdirs(dir, 0755);
    char tmp[PATH_MAX + 8];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "we");
    if (!f) {
        rlog("start at login: cannot write %s: %s", tmp, strerror(errno));
        return -1;
    }
    fprintf(f,
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=RDC\n"
            "Comment=Remote desktop: share this computer by link or code\n"
            "Exec=\"%s\" --login\n"
            "Terminal=false\n"
            "X-GNOME-Autostart-enabled=true\n",
            quoted);
    int ok = fclose(f) == 0 && rename(tmp, path) == 0;
    if (!ok) {
        rlog("start at login: cannot write %s", path);
        unlink(tmp);
        return -1;
    }
    rlog("start at login: on (%s)", exe);
    return 0;
}

// RDC was moved since the entry was written: point it at where RDC is now.
void lx_autostart_repair(void) {
    char path[PATH_MAX], line[PATH_MAX * 3], exe[PATH_MAX];
    autostart_path(path, sizeof path);
    FILE *f = fopen(path, "re");
    if (!f) return;
    int stale = 0;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "Exec=\"", 6) != 0) continue;
        char *end = strstr(line + 6, "\" --login");
        if (!end) break;
        *end = 0;
        if (lx_exe_path(exe, sizeof exe) == 0 && strchr(line + 6, '\\') == NULL && strcmp(line + 6, exe) != 0 &&
            access(line + 6, X_OK) != 0)
            stale = 1;
    }
    fclose(f);
    if (stale) lx_autostart_set(1);
}

// Keep awake: `systemd-inhibit --what=idle:sleep --mode=block … cat` holds logind's lock for as
// long as cat runs, and cat runs until its stdin — a pipe only this process writes to — closes:
// when RDC turns it off, exits, crashes or execs into an update.
static pthread_mutex_t g_awake_lock = PTHREAD_MUTEX_INITIALIZER;
static pid_t g_awake_pid;
static int g_awake_fd = -1;

void lx_keep_awake(int on) {
    pthread_mutex_lock(&g_awake_lock);
    if (on && !g_awake_pid) {
        int p[2];
        if (!lx_in_path("systemd-inhibit")) {
            rlog("keep awake: systemd-inhibit is not installed — this computer may still fall asleep");
        } else if (pipe2(p, O_CLOEXEC) == 0) {
            posix_spawn_file_actions_t fa;
            posix_spawn_file_actions_init(&fa);
            posix_spawn_file_actions_adddup2(&fa, p[0], 0);
            posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
            const char *argv[] = {"systemd-inhibit", "--what=idle:sleep", "--mode=block", "--who=RDC",
                                  "--why=RDC keeps this computer reachable", "cat", NULL};
            pid_t pid;
            int rc = posix_spawnp(&pid, argv[0], &fa, NULL, (char *const *)argv, environ);
            posix_spawn_file_actions_destroy(&fa);
            close(p[0]);
            if (rc == 0) {
                g_awake_pid = pid;
                g_awake_fd = p[1];
                rlog("keep awake: on");
            } else {
                close(p[1]);
                rlog("keep awake: cannot start systemd-inhibit: %s", strerror(rc));
            }
        }
    } else if (!on && g_awake_pid) {
        close(g_awake_fd);
        g_awake_fd = -1;
        int st;
        while (waitpid(g_awake_pid, &st, 0) < 0 && errno == EINTR) {
        }
        g_awake_pid = 0;
        rlog("keep awake: off");
    }
    pthread_mutex_unlock(&g_awake_lock);
}

// ---------------------------------------------------------------------------
// One window at a time: the first RDC with a window listens on an abstract Unix socket; a second
// launch tells it to come forward and exits. The window, when closed with start at login on, is
// reached this way. `rdc --no-ui` and `rdc mcp` run next to it freely.

static int g_instance_fd = -1;

int lx_instance_fd(void) { return g_instance_fd; }

int rdc_app_prepare(const void *camera_dll, size_t camera_dll_len) {
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    int n = snprintf(a.sun_path + 1, sizeof a.sun_path - 1, "com.anods.rdc.window.%u", (unsigned)getuid());
    socklen_t alen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + (size_t)n);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 0;
    if (bind(fd, (struct sockaddr *)&a, alen) == 0 && listen(fd, 4) == 0) {
        g_instance_fd = fd;
        return 0;
    }
    int in_use = errno == EADDRINUSE;
    close(fd);
    if (!in_use) return 0;
    fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd >= 0 && connect(fd, (struct sockaddr *)&a, alen) == 0) {
        if (write(fd, "show\n", 5) < 0) {
        }
        close(fd);
        rlog("RDC is already running here: its window comes forward");
        return 1;
    }
    if (fd >= 0) close(fd);
    return 0;
}

// ---------------------------------------------------------------------------
// Not on Linux (yet)

// Screenshots for AI agents (`rdc mcp`) need a JPEG decoder; the Linux agent side is not done.
void *rdc_jpeg_scale(const void *jpeg, size_t len, int crop_x, int crop_y, int crop_w, int crop_h, int max_w, int max_h,
                     int quality, size_t *out_len, int *out_w, int *out_h) {
    return NULL;
}

// No phone microphone or camera on Linux.
int rdc_media_status(void) { return 0; }
int rdc_mic_install(int install) { return -1; }
int rdc_camera_install(int install, const void *dll, size_t dll_len) { return -1; }
void rdc_mic_start(void) {}
void rdc_mic_push(const int16_t *pcm, int frames) {}
void rdc_mic_stop(void) {}
void rdc_camera_start(void) {}
void rdc_camera_push(const uint8_t *jpeg, size_t len, int width, int height) {}
void rdc_camera_stop(void) {}
