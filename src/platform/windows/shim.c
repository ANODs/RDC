// Windows platform layer for RDC (contract — ../platform.h).
// Capture — DXGI Desktop Duplication (fallback — GDI), JPEG — WIC, input — SendInput,
// window — Win32, updates — WinHTTP. Built by Zig (mingw-w64), Windows 10 1809+.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <initguid.h>
#include <objbase.h>
#include <ole2.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wincodec.h>
#include <winhttp.h>
#include <iphlpapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <knownfolders.h>
#include <commctrl.h>
#include <winver.h>
#include <mfapi.h>
#include <mfidl.h>
#include <sddl.h>
#include <wincred.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "platform.h"
#include "camera_pipe.h"

// ---------------------------------------------------------------------------
// Strings, time, log

static void to_wide(const char *s, wchar_t *out, int out_len) {
    if (!s || MultiByteToWideChar(CP_UTF8, 0, s, -1, out, out_len) == 0) out[0] = 0;
}

static int to_utf8(const wchar_t *s, char *out, int out_len) {
    if (WideCharToMultiByte(CP_UTF8, 0, s, -1, out, out_len, NULL, NULL) > 0) return 0;
    if (out_len > 0) out[0] = 0;
    return -1;
}

static void wfmt(wchar_t *buf, size_t n, const wchar_t *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = _vsnwprintf(buf, n, fmt, ap);
    va_end(ap);
    if (r < 0 || (size_t)r >= n) buf[n - 1] = 0;
}

static SRWLOCK g_log_lock = SRWLOCK_INIT;
static HANDLE g_log_file = INVALID_HANDLE_VALUE;
static LARGE_INTEGER g_qpf;

// Where else to write the log: a redirected stderr or the console we were started from.
static HANDLE err_handle(int *is_console) {
    static HANDLE h;
    static int tried, console;
    if (!tried) {
        tried = 1;
        h = GetStdHandle(STD_ERROR_HANDLE);
        if (!h || h == INVALID_HANDLE_VALUE) {
            h = NULL;
            if (AttachConsole(ATTACH_PARENT_PROCESS)) {
                h = CreateFileW(L"CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
                if (h == INVALID_HANDLE_VALUE) h = NULL;
            }
        }
        DWORD mode;
        console = h && GetConsoleMode(h, &mode);
    }
    *is_console = console;
    return h;
}

void rdc_log(const char *msg) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    char line[1400];
    int n = snprintf(line, sizeof line, "[%02d:%02d:%02d] %s\r\n", st.wHour, st.wMinute, st.wSecond, msg);
    if (n < 0) return;
    if (n >= (int)sizeof line) n = (int)sizeof line - 1;
    AcquireSRWLockExclusive(&g_log_lock);
    DWORD written;
    if (g_log_file != INVALID_HANDLE_VALUE) WriteFile(g_log_file, line, (DWORD)n, &written, NULL);
    int console = 0;
    HANDLE err = err_handle(&console);
    if (err && console) {
        wchar_t wline[1400];
        int wn = MultiByteToWideChar(CP_UTF8, 0, line, n, wline, 1400);
        if (wn > 0) WriteConsoleW(err, wline, (DWORD)wn, &written, NULL);
    } else if (err) {
        WriteFile(err, line, (DWORD)n, &written, NULL);
    }
    ReleaseSRWLockExclusive(&g_log_lock);
}

static void rlog(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    rdc_log(buf);
}

uint64_t rdc_now_us(void) {
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    if (g_qpf.QuadPart == 0) QueryPerformanceFrequency(&g_qpf);
    uint64_t f = (uint64_t)g_qpf.QuadPart, t = (uint64_t)c.QuadPart;
    return t / f * 1000000ULL + t % f * 1000000ULL / f;
}

void rdc_init(void) {
    QueryPerformanceFrequency(&g_qpf);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);  // in case the manifest did not apply
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    PWSTR local = NULL;
    if (SUCCEEDED(SHGetKnownFolderPath(&FOLDERID_LocalAppData, 0, NULL, &local))) {
        wchar_t dir[MAX_PATH], path[MAX_PATH], old[MAX_PATH];
        wfmt(dir, MAX_PATH, L"%ls\\RDC", local);
        CoTaskMemFree(local);
        CreateDirectoryW(dir, NULL);
        wfmt(path, MAX_PATH, L"%ls\\rdc.log", dir);
        WIN32_FILE_ATTRIBUTE_DATA fa;
        if (GetFileAttributesExW(path, GetFileExInfoStandard, &fa) && (fa.nFileSizeHigh || fa.nFileSizeLow > (4u << 20))) {
            wfmt(old, MAX_PATH, L"%ls\\rdc.old.log", dir);
            MoveFileExW(path, old, MOVEFILE_REPLACE_EXISTING);
        }
        g_log_file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS,
                                 FILE_ATTRIBUTE_NORMAL, NULL);
    }
    // One window at a time is rdc_app_prepare's business: `rdc mcp` and a host without a window
    // run next to it freely.
}

// Windows has no separate permissions for screen capture and input.
int rdc_screen_access(int prompt) { return 1; }
int rdc_input_access(int prompt) { return 1; }
void rdc_open_privacy(int which) {}

// ---------------------------------------------------------------------------
// Frame in memory: a 32-bit top-down DIB section; GDI also draws the cursor into it.

typedef struct {
    HDC dc;
    HBITMAP bmp;
    HGDIOBJ old;
    uint8_t *bits;
    int w, h, stride;
} Frame;

static void frame_free(Frame *f) {
    if (f->dc) {
        if (f->old) SelectObject(f->dc, f->old);
        DeleteDC(f->dc);
    }
    if (f->bmp) DeleteObject(f->bmp);
    memset(f, 0, sizeof *f);
}

static int frame_ensure(Frame *f, int w, int h) {
    if (f->bmp && f->w == w && f->h == h) return 0;
    frame_free(f);
    BITMAPINFO bi;
    memset(&bi, 0, sizeof bi);
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    f->dc = CreateCompatibleDC(NULL);
    void *bits = NULL;
    f->bmp = f->dc ? CreateDIBSection(f->dc, &bi, DIB_RGB_COLORS, &bits, NULL, 0) : NULL;
    if (!f->bmp || !bits) {
        frame_free(f);
        return -1;
    }
    f->bits = bits;
    f->old = SelectObject(f->dc, f->bmp);
    f->w = w;
    f->h = h;
    f->stride = w * 4;
    return 0;
}

typedef struct {
    HCURSOR h;
    POINT p;
    DWORD flags;
} CursorState;

static int cursor_changed(CursorState *last) {
    CURSORINFO ci;
    ci.cbSize = sizeof ci;
    if (!GetCursorInfo(&ci)) return 0;
    int changed = ci.hCursor != last->h || ci.ptScreenPos.x != last->p.x || ci.ptScreenPos.y != last->p.y ||
                  ci.flags != last->flags;
    last->h = ci.hCursor;
    last->p = ci.ptScreenPos;
    last->flags = ci.flags;
    return changed;
}

// Neither DXGI nor GDI puts the cursor into the image — we draw it ourselves. (ox, oy) — where
// the frame's display starts on the virtual screen.
static void draw_cursor(Frame *f, int ox, int oy) {
    CURSORINFO ci;
    ci.cbSize = sizeof ci;
    if (!GetCursorInfo(&ci) || !(ci.flags & CURSOR_SHOWING) || !ci.hCursor) return;
    ICONINFO ii;
    if (!GetIconInfo(ci.hCursor, &ii)) return;
    DrawIconEx(f->dc, ci.ptScreenPos.x - ox - (int)ii.xHotspot, ci.ptScreenPos.y - oy - (int)ii.yHotspot, ci.hCursor, 0,
               0, 0, NULL, DI_NORMAL);
    if (ii.hbmMask) DeleteObject(ii.hbmMask);
    if (ii.hbmColor) DeleteObject(ii.hbmColor);
}

// ---------------------------------------------------------------------------
// Displays: monitors on the virtual screen. A display's id is the number of its GDI device
// (\\.\DISPLAY2 → 2), which DXGI outputs name too.

typedef struct {
    rdc_display list[RDC_MAX_DISPLAYS];
    wchar_t device[RDC_MAX_DISPLAYS][CCHDEVICENAME];
    int n;
} MonitorList;

static uint32_t device_number(const wchar_t *device) {
    const wchar_t *p = device + wcslen(device);
    while (p > device && p[-1] >= L'0' && p[-1] <= L'9') p--;
    return (uint32_t)wcstoul(p, NULL, 10);
}

static BOOL CALLBACK monitor_enum(HMONITOR mon, HDC dc, LPRECT rc, LPARAM arg) {
    MonitorList *ml = (MonitorList *)arg;
    if (ml->n >= RDC_MAX_DISPLAYS) return FALSE;
    MONITORINFOEXW mi;
    mi.cbSize = sizeof mi;
    if (!GetMonitorInfoW(mon, (MONITORINFO *)&mi)) return TRUE;
    rdc_display *d = &ml->list[ml->n];
    memset(d, 0, sizeof *d);
    d->id = device_number(mi.szDevice);
    if (d->id == 0) d->id = 0x100 + (uint32_t)ml->n;
    d->x = mi.rcMonitor.left;
    d->y = mi.rcMonitor.top;
    d->w = d->pw = mi.rcMonitor.right - mi.rcMonitor.left;
    d->h = d->ph = mi.rcMonitor.bottom - mi.rcMonitor.top;
    d->primary = (mi.dwFlags & MONITORINFOF_PRIMARY) ? 1 : 0;
    DISPLAY_DEVICEW dd;
    memset(&dd, 0, sizeof dd);
    dd.cb = sizeof dd;
    if (EnumDisplayDevicesW(mi.szDevice, 0, &dd, 0) && dd.DeviceString[0]) to_utf8(dd.DeviceString, d->name, sizeof d->name);
    if (!d->name[0]) snprintf(d->name, sizeof d->name, "Display %u", d->id);
    wcsncpy(ml->device[ml->n], mi.szDevice, CCHDEVICENAME - 1);
    ml->device[ml->n][CCHDEVICENAME - 1] = 0;
    ml->n++;
    return TRUE;
}

static void monitors(MonitorList *ml) {
    memset(ml, 0, sizeof *ml);
    EnumDisplayMonitors(NULL, NULL, monitor_enum, (LPARAM)ml);
    if (ml->n == 0) {  // no monitor list (a service session): the main screen as it was
        rdc_display *d = &ml->list[0];
        d->id = 1;
        d->w = d->pw = GetSystemMetrics(SM_CXSCREEN);
        d->h = d->ph = GetSystemMetrics(SM_CYSCREEN);
        d->primary = 1;
        strcpy(d->name, "Display 1");
        ml->n = d->w > 0 && d->h > 0 ? 1 : 0;
    }
}

int rdc_displays(rdc_display *out, int max) {
    MonitorList ml;
    monitors(&ml);
    int n = ml.n < max ? ml.n : max;
    memcpy(out, ml.list, (size_t)n * sizeof *out);
    return n;
}

// The monitor for a display id (0 or gone — the primary one): its rectangle and GDI device name.
static int monitor_for(uint32_t id, RECT *rect, wchar_t *device) {
    MonitorList ml;
    monitors(&ml);
    int pick = -1;
    for (int i = 0; i < ml.n; i++) {
        if (id && ml.list[i].id == id) pick = i;
        if (pick < 0 && !id && ml.list[i].primary) pick = i;
    }
    if (pick < 0 && id) return -1;
    if (pick < 0) pick = 0;
    if (ml.n == 0) return -1;
    rdc_display *d = &ml.list[pick];
    SetRect(rect, d->x, d->y, d->x + d->w, d->y + d->h);
    wcscpy(device, ml.device[pick]);
    return 0;
}

// ---------------------------------------------------------------------------
// DXGI Desktop Duplication of one monitor; frames arrive only when the screen changes.

typedef struct {
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    IDXGIOutputDuplication *dup;
    ID3D11Texture2D *staging;  // last desktop image, readable by the CPU
    int w, h;
    int have_image;
} Dup;

static void dup_close(Dup *d) {
    if (d->staging) ID3D11Texture2D_Release(d->staging);
    if (d->dup) IDXGIOutputDuplication_Release(d->dup);
    if (d->ctx) ID3D11DeviceContext_Release(d->ctx);
    if (d->dev) ID3D11Device_Release(d->dev);
    memset(d, 0, sizeof *d);
}

// device — the monitor's GDI name (\\.\DISPLAY2); "" — the main monitor, the one at (0, 0).
static int dup_open(Dup *d, int verbose, const wchar_t *device) {
    memset(d, 0, sizeof *d);
    IDXGIFactory1 *factory = NULL;
    if (FAILED(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory))) return -1;
    IDXGIAdapter1 *adapter = NULL;
    IDXGIOutput *output = NULL;
    for (UINT i = 0; !output && IDXGIFactory1_EnumAdapters1(factory, i, &adapter) == S_OK; i++) {
        IDXGIOutput *o = NULL;
        for (UINT j = 0; IDXGIAdapter1_EnumOutputs(adapter, j, &o) == S_OK; j++) {
            DXGI_OUTPUT_DESC od;
            if (SUCCEEDED(IDXGIOutput_GetDesc(o, &od)) && od.AttachedToDesktop &&
                (device[0] ? wcscmp(od.DeviceName, device) == 0
                           : od.DesktopCoordinates.left == 0 && od.DesktopCoordinates.top == 0)) {
                output = o;
                break;
            }
            IDXGIOutput_Release(o);
        }
        if (!output) {
            IDXGIAdapter1_Release(adapter);
            adapter = NULL;
        }
    }
    IDXGIFactory1_Release(factory);
    if (!output) {
        if (verbose) rlog("DXGI: monitor not found");
        return -2;
    }
    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDevice((IDXGIAdapter *)adapter, D3D_DRIVER_TYPE_UNKNOWN, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                   NULL, 0, D3D11_SDK_VERSION, &d->dev, &fl, &d->ctx);
    IDXGIAdapter1_Release(adapter);
    if (FAILED(hr)) {
        IDXGIOutput_Release(output);
        if (verbose) rlog("DXGI: D3D11 device not created (0x%08lx)", (unsigned long)hr);
        return -3;
    }
    IDXGIOutput1 *out1 = NULL;
    hr = IDXGIOutput_QueryInterface(output, &IID_IDXGIOutput1, (void **)&out1);
    IDXGIOutput_Release(output);
    if (FAILED(hr)) {
        dup_close(d);
        return -4;
    }
    hr = IDXGIOutput1_DuplicateOutput(out1, (IUnknown *)d->dev, &d->dup);
    IDXGIOutput1_Release(out1);
    if (FAILED(hr)) {
        if (verbose) rlog("DXGI: desktop duplication unavailable (0x%08lx)", (unsigned long)hr);
        dup_close(d);
        return -5;
    }
    DXGI_OUTDUPL_DESC dd;
    IDXGIOutputDuplication_GetDesc(d->dup, &dd);
    d->w = (int)dd.ModeDesc.Width;
    d->h = (int)dd.ModeDesc.Height;
    return 0;
}

// 1 — screen or cursor changed, 0 — nothing new, -1 — duplication lost
// (display mode change, lock screen, UAC prompt) and must be reopened.
static int dup_next(Dup *d, UINT timeout_ms) {
    DXGI_OUTDUPL_FRAME_INFO fi;
    IDXGIResource *res = NULL;
    HRESULT hr = IDXGIOutputDuplication_AcquireNextFrame(d->dup, timeout_ms, &fi, &res);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) return 0;
    if (FAILED(hr)) return -1;
    int changed = fi.LastMouseUpdateTime.QuadPart != 0;
    if (fi.LastPresentTime.QuadPart != 0 || fi.AccumulatedFrames > 0) {
        ID3D11Texture2D *tex = NULL;
        if (SUCCEEDED(IDXGIResource_QueryInterface(res, &IID_ID3D11Texture2D, (void **)&tex))) {
            D3D11_TEXTURE2D_DESC td;
            ID3D11Texture2D_GetDesc(tex, &td);
            if (d->staging) {
                D3D11_TEXTURE2D_DESC sd;
                ID3D11Texture2D_GetDesc(d->staging, &sd);
                if (sd.Width != td.Width || sd.Height != td.Height || sd.Format != td.Format) {
                    ID3D11Texture2D_Release(d->staging);
                    d->staging = NULL;
                }
            }
            if (!d->staging) {
                td.MipLevels = 1;
                td.ArraySize = 1;
                td.SampleDesc.Count = 1;
                td.SampleDesc.Quality = 0;
                td.Usage = D3D11_USAGE_STAGING;
                td.BindFlags = 0;
                td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                td.MiscFlags = 0;
                if (FAILED(ID3D11Device_CreateTexture2D(d->dev, &td, NULL, &d->staging))) d->staging = NULL;
            }
            if (d->staging) {
                ID3D11DeviceContext_CopyResource(d->ctx, (ID3D11Resource *)d->staging, (ID3D11Resource *)tex);
                d->w = (int)td.Width;
                d->h = (int)td.Height;
                d->have_image = 1;
                changed = 1;
            }
            ID3D11Texture2D_Release(tex);
        }
    }
    IDXGIResource_Release(res);
    IDXGIOutputDuplication_ReleaseFrame(d->dup);
    return changed;
}

static int dup_copy(Dup *d, Frame *f) {
    if (!d->staging || frame_ensure(f, d->w, d->h) != 0) return -1;
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ID3D11DeviceContext_Map(d->ctx, (ID3D11Resource *)d->staging, 0, D3D11_MAP_READ, 0, &m))) return -1;
    for (int y = 0; y < d->h; y++)
        memcpy(f->bits + (size_t)y * f->stride, (const uint8_t *)m.pData + (size_t)y * m.RowPitch, (size_t)d->w * 4);
    ID3D11DeviceContext_Unmap(d->ctx, (ID3D11Resource *)d->staging, 0);
    return 0;
}

// GDI: fallback capture (virtual machines, remote sessions, old drivers) of one monitor.
static int gdi_capture(Frame *f, const RECT *mon) {
    int w = mon->right - mon->left, h = mon->bottom - mon->top;
    if (w <= 0 || h <= 0 || frame_ensure(f, w, h) != 0) return -1;
    HDC screen = GetDC(NULL);
    if (!screen) return -1;
    BOOL ok = BitBlt(f->dc, 0, 0, w, h, screen, mon->left, mon->top, SRCCOPY);
    ReleaseDC(NULL, screen);
    GdiFlush();
    return ok ? 0 : -1;
}

// ---------------------------------------------------------------------------
// JPEG via WIC. The source is our own buffer with no extra copy: a custom IWICBitmapSource.

typedef struct {
    IWICBitmapSource iface;
    const uint8_t *bits;
    UINT w, h, stride;
} MemSource;

static const GUID kIID_IUnknown = {0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

static HRESULT STDMETHODCALLTYPE ms_query(IWICBitmapSource *This, REFIID riid, void **ppv) {
    if (IsEqualGUID(riid, &kIID_IUnknown) || IsEqualGUID(riid, &IID_IWICBitmapSource)) {
        *ppv = This;
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE ms_addref(IWICBitmapSource *This) { return 2; }  // lives on the encoder's stack
static ULONG STDMETHODCALLTYPE ms_release(IWICBitmapSource *This) { return 1; }
static HRESULT STDMETHODCALLTYPE ms_size(IWICBitmapSource *This, UINT *w, UINT *h) {
    const MemSource *s = (const MemSource *)This;
    *w = s->w;
    *h = s->h;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE ms_format(IWICBitmapSource *This, WICPixelFormatGUID *pf) {
    *pf = GUID_WICPixelFormat32bppBGR;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE ms_resolution(IWICBitmapSource *This, double *x, double *y) {
    *x = *y = 96.0;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE ms_palette(IWICBitmapSource *This, IWICPalette *p) {
    return WINCODEC_ERR_PALETTEUNAVAILABLE;
}
static HRESULT STDMETHODCALLTYPE ms_copy(IWICBitmapSource *This, const WICRect *rc, UINT stride, UINT size, BYTE *buf) {
    const MemSource *s = (const MemSource *)This;
    WICRect full = {0, 0, (INT)s->w, (INT)s->h};
    if (!rc) rc = &full;
    if (rc->X < 0 || rc->Y < 0 || rc->Width <= 0 || rc->Height <= 0 || rc->X + rc->Width > (INT)s->w ||
        rc->Y + rc->Height > (INT)s->h)
        return E_INVALIDARG;
    UINT row = (UINT)rc->Width * 4;
    if (stride < row || size < stride * (UINT)(rc->Height - 1) + row) return E_INVALIDARG;
    for (INT y = 0; y < rc->Height; y++)
        memcpy(buf + (size_t)y * stride, s->bits + (size_t)(rc->Y + y) * s->stride + (size_t)rc->X * 4, row);
    return S_OK;
}
static IWICBitmapSourceVtbl ms_vtbl = {
    .QueryInterface = ms_query,
    .AddRef = ms_addref,
    .Release = ms_release,
    .GetSize = ms_size,
    .GetPixelFormat = ms_format,
    .GetResolution = ms_resolution,
    .CopyPalette = ms_palette,
    .CopyPixels = ms_copy,
};

static rdc_frame_cb g_cb;
static void *g_cb_ctx;

// Compress a frame (downscaled to max_width) and hand it to the host.
static int jpeg_encode(IWICImagingFactory *wic, const Frame *f, int max_width, float quality, uint64_t ts) {
    int w = f->w, h = f->h;
    if (max_width > 0 && w > max_width) {
        h = (int)(((long long)h * max_width + w / 2) / w) & ~1;
        w = max_width & ~1;
    }
    MemSource src = {{&ms_vtbl}, f->bits, (UINT)f->w, (UINT)f->h, (UINT)f->stride};
    IWICBitmapSource *source = &src.iface;
    IWICBitmapScaler *scaler = NULL;
    IWICFormatConverter *conv = NULL;
    IStream *stream = NULL;
    IWICBitmapEncoder *enc = NULL;
    IWICBitmapFrameEncode *frame = NULL;
    IPropertyBag2 *props = NULL;
    int rc = -1;
    if (w != f->w || h != f->h) {
        if (FAILED(IWICImagingFactory_CreateBitmapScaler(wic, &scaler))) goto done;
        if (FAILED(IWICBitmapScaler_Initialize(scaler, source, (UINT)w, (UINT)h, WICBitmapInterpolationModeFant))) goto done;
        source = (IWICBitmapSource *)scaler;
    }
    if (FAILED(IWICImagingFactory_CreateFormatConverter(wic, &conv))) goto done;
    if (FAILED(IWICFormatConverter_Initialize(conv, source, &GUID_WICPixelFormat24bppBGR, WICBitmapDitherTypeNone, NULL,
                                              0.0, WICBitmapPaletteTypeCustom)))
        goto done;
    if (FAILED(CreateStreamOnHGlobal(NULL, TRUE, &stream))) goto done;
    if (FAILED(IWICImagingFactory_CreateEncoder(wic, &GUID_ContainerFormatJpeg, NULL, &enc))) goto done;
    if (FAILED(IWICBitmapEncoder_Initialize(enc, stream, WICBitmapEncoderNoCache))) goto done;
    if (FAILED(IWICBitmapEncoder_CreateNewFrame(enc, &frame, &props))) goto done;
    {
        PROPBAG2 opt;
        memset(&opt, 0, sizeof opt);
        opt.pstrName = (LPOLESTR)L"ImageQuality";
        VARIANT v;
        VariantInit(&v);
        v.vt = VT_R4;
        v.fltVal = quality;
        IPropertyBag2_Write(props, 1, &opt, &v);
    }
    if (FAILED(IWICBitmapFrameEncode_Initialize(frame, props))) goto done;
    if (FAILED(IWICBitmapFrameEncode_SetSize(frame, (UINT)w, (UINT)h))) goto done;
    {
        WICPixelFormatGUID pf = GUID_WICPixelFormat24bppBGR;
        if (FAILED(IWICBitmapFrameEncode_SetPixelFormat(frame, &pf))) goto done;
    }
    if (FAILED(IWICBitmapFrameEncode_WriteSource(frame, (IWICBitmapSource *)conv, NULL))) goto done;
    if (FAILED(IWICBitmapFrameEncode_Commit(frame))) goto done;
    if (FAILED(IWICBitmapEncoder_Commit(enc))) goto done;
    {
        HGLOBAL hg = NULL;
        STATSTG st;
        if (FAILED(GetHGlobalFromStream(stream, &hg)) || FAILED(IStream_Stat(stream, &st, STATFLAG_NONAME))) goto done;
        const uint8_t *p = GlobalLock(hg);
        if (!p) goto done;
        rdc_frame_cb cb = g_cb;
        if (cb) cb(g_cb_ctx, RDC_CODEC_JPEG, p, (size_t)st.cbSize.QuadPart, 1, ts, w, h);
        GlobalUnlock(hg);
        rc = 0;
    }
done:
    if (props) IPropertyBag2_Release(props);
    if (frame) IWICBitmapFrameEncode_Release(frame);
    if (enc) IWICBitmapEncoder_Release(enc);
    if (stream) IStream_Release(stream);
    if (conv) IWICFormatConverter_Release(conv);
    if (scaler) IWICBitmapScaler_Release(scaler);
    return rc;
}

// Screenshots for AI agents: JPEG in, cropped and shrunk JPEG out.
void *rdc_jpeg_scale(const void *jpeg, size_t len, int crop_x, int crop_y, int crop_w, int crop_h, int max_w, int max_h,
                     int quality, size_t *out_len, int *out_w, int *out_h) {
    HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IWICImagingFactory *wic = NULL;
    IWICStream *in = NULL;
    IWICBitmapDecoder *dec = NULL;
    IWICBitmapFrameDecode *src_frame = NULL;
    IWICBitmapClipper *clip = NULL;
    IWICBitmapScaler *scaler = NULL;
    IWICFormatConverter *conv = NULL;
    IStream *stream = NULL;
    IWICBitmapEncoder *enc = NULL;
    IWICBitmapFrameEncode *frame = NULL;
    IPropertyBag2 *props = NULL;
    void *result = NULL;
    if (FAILED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory,
                                (void **)&wic)))
        goto done;
    if (FAILED(IWICImagingFactory_CreateStream(wic, &in))) goto done;
    if (FAILED(IWICStream_InitializeFromMemory(in, (BYTE *)jpeg, (DWORD)len))) goto done;
    if (FAILED(IWICImagingFactory_CreateDecoderFromStream(wic, (IStream *)in, NULL, WICDecodeMetadataCacheOnDemand, &dec)))
        goto done;
    if (FAILED(IWICBitmapDecoder_GetFrame(dec, 0, &src_frame))) goto done;
    UINT iw = 0, ih = 0;
    if (FAILED(IWICBitmapFrameDecode_GetSize(src_frame, &iw, &ih)) || !iw || !ih) goto done;
    WICRect rc = {0, 0, (INT)iw, (INT)ih};
    if (crop_w > 0 && crop_h > 0) {
        int x0 = crop_x < 0 ? 0 : crop_x, y0 = crop_y < 0 ? 0 : crop_y;
        int x1 = crop_x + crop_w > (int)iw ? (int)iw : crop_x + crop_w;
        int y1 = crop_y + crop_h > (int)ih ? (int)ih : crop_y + crop_h;
        if (x1 <= x0 || y1 <= y0) goto done;
        rc.X = x0;
        rc.Y = y0;
        rc.Width = x1 - x0;
        rc.Height = y1 - y0;
    }
    IWICBitmapSource *source = (IWICBitmapSource *)src_frame;
    if (FAILED(IWICImagingFactory_CreateBitmapClipper(wic, &clip))) goto done;
    if (FAILED(IWICBitmapClipper_Initialize(clip, source, &rc))) goto done;
    source = (IWICBitmapSource *)clip;
    double scale = 1;
    if (max_w > 0 && rc.Width * scale > max_w) scale = (double)max_w / rc.Width;
    if (max_h > 0 && rc.Height * scale > max_h) scale = (double)max_h / rc.Height;
    UINT w = (UINT)(rc.Width * scale + 0.5), h = (UINT)(rc.Height * scale + 0.5);
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (w != (UINT)rc.Width || h != (UINT)rc.Height) {
        if (FAILED(IWICImagingFactory_CreateBitmapScaler(wic, &scaler))) goto done;
        if (FAILED(IWICBitmapScaler_Initialize(scaler, source, w, h, WICBitmapInterpolationModeFant))) goto done;
        source = (IWICBitmapSource *)scaler;
    }
    if (FAILED(IWICImagingFactory_CreateFormatConverter(wic, &conv))) goto done;
    if (FAILED(IWICFormatConverter_Initialize(conv, source, &GUID_WICPixelFormat24bppBGR, WICBitmapDitherTypeNone, NULL,
                                              0.0, WICBitmapPaletteTypeCustom)))
        goto done;
    if (FAILED(CreateStreamOnHGlobal(NULL, TRUE, &stream))) goto done;
    if (FAILED(IWICImagingFactory_CreateEncoder(wic, &GUID_ContainerFormatJpeg, NULL, &enc))) goto done;
    if (FAILED(IWICBitmapEncoder_Initialize(enc, stream, WICBitmapEncoderNoCache))) goto done;
    if (FAILED(IWICBitmapEncoder_CreateNewFrame(enc, &frame, &props))) goto done;
    {
        PROPBAG2 opt;
        memset(&opt, 0, sizeof opt);
        opt.pstrName = (LPOLESTR)L"ImageQuality";
        VARIANT v;
        VariantInit(&v);
        v.vt = VT_R4;
        v.fltVal = (float)quality / 100.0f;
        IPropertyBag2_Write(props, 1, &opt, &v);
    }
    if (FAILED(IWICBitmapFrameEncode_Initialize(frame, props))) goto done;
    if (FAILED(IWICBitmapFrameEncode_SetSize(frame, w, h))) goto done;
    {
        WICPixelFormatGUID pf = GUID_WICPixelFormat24bppBGR;
        if (FAILED(IWICBitmapFrameEncode_SetPixelFormat(frame, &pf))) goto done;
    }
    if (FAILED(IWICBitmapFrameEncode_WriteSource(frame, (IWICBitmapSource *)conv, NULL))) goto done;
    if (FAILED(IWICBitmapFrameEncode_Commit(frame))) goto done;
    if (FAILED(IWICBitmapEncoder_Commit(enc))) goto done;
    {
        HGLOBAL hg = NULL;
        STATSTG st;
        if (FAILED(GetHGlobalFromStream(stream, &hg)) || FAILED(IStream_Stat(stream, &st, STATFLAG_NONAME))) goto done;
        const uint8_t *p = GlobalLock(hg);
        if (!p) goto done;
        size_t n = (size_t)st.cbSize.QuadPart;
        result = malloc(n);
        if (result) {
            memcpy(result, p, n);
            *out_len = n;
            *out_w = (int)w;
            *out_h = (int)h;
        }
        GlobalUnlock(hg);
    }
done:
    if (props) IPropertyBag2_Release(props);
    if (frame) IWICBitmapFrameEncode_Release(frame);
    if (enc) IWICBitmapEncoder_Release(enc);
    if (stream) IStream_Release(stream);
    if (conv) IWICFormatConverter_Release(conv);
    if (scaler) IWICBitmapScaler_Release(scaler);
    if (clip) IWICBitmapClipper_Release(clip);
    if (src_frame) IWICBitmapFrameDecode_Release(src_frame);
    if (dec) IWICBitmapDecoder_Release(dec);
    if (in) IWICStream_Release(in);
    if (wic) IWICImagingFactory_Release(wic);
    if (SUCCEEDED(co)) CoUninitialize();
    return result;
}

// ---------------------------------------------------------------------------
// Capture thread

#define JPEG_QUALITY 0.6f

static HANDLE g_cap_thread, g_cap_ready;
static volatile LONG g_cap_run, g_cap_status, g_want_jpeg = 1, g_force_key;
// The display to capture (0 — the main one) and the one the capture thread shows now.
static volatile LONG g_cap_want, g_cap_shown = -1;
static int g_max_width = 1920;
static uint64_t g_interval_us = 50000;  // JPEG — at most 20 fps

static DWORD WINAPI capture_main(LPVOID arg) {
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    IWICImagingFactory *wic = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory,
                                  (void **)&wic);
    Dup dup;
    Frame work;
    memset(&dup, 0, sizeof dup);
    memset(&work, 0, sizeof work);
    uint8_t *prev = NULL;  // previous GDI snapshot: has the screen changed
    size_t prev_len = 0;
    int have_dup = 0;
    LONG shown = g_cap_want;
    RECT mon;
    wchar_t device[CCHDEVICENAME] = L"";
    if (monitor_for((uint32_t)shown, &mon, device) != 0 && monitor_for(0, &mon, device) != 0) {
        SetRect(&mon, 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
        device[0] = 0;
    }
    if (FAILED(hr)) {
        rlog("capture: WIC unavailable (0x%08lx)", (unsigned long)hr);
        InterlockedExchange(&g_cap_status, -1);
        SetEvent(g_cap_ready);
        CoUninitialize();
        return 0;
    }
    have_dup = dup_open(&dup, 1, device) == 0;
    if (have_dup) {
        rlog("capture: DXGI, %dx%d", dup.w, dup.h);
    } else if (gdi_capture(&work, &mon) == 0) {
        rlog("capture: GDI, %dx%d", work.w, work.h);
    } else {
        rlog("capture: screen unavailable");
        InterlockedExchange(&g_cap_status, -2);
        SetEvent(g_cap_ready);
        frame_free(&work);
        IWICImagingFactory_Release(wic);
        CoUninitialize();
        return 0;
    }
    InterlockedExchange(&g_cap_status, 0);
    InterlockedExchange(&g_cap_shown, shown);
    SetEvent(g_cap_ready);

    CursorState cur;
    memset(&cur, 0, sizeof cur);
    uint64_t last_sent = 0, last_poll = 0, last_retry = rdc_now_us();
    int pending = 1, fresh = !have_dup, failures = 0;  // fresh — work holds a fresh GDI snapshot without the cursor
    while (g_cap_run) {
        // Another display: duplicate its output from now on (rdc_capture_display waits for this).
        LONG asked = g_cap_want;
        if (asked != shown) {
            RECT r;
            wchar_t dev[CCHDEVICENAME];
            if (monitor_for((uint32_t)asked, &r, dev) == 0) {
                mon = r;
                wcscpy(device, dev);
                dup_close(&dup);
                have_dup = dup_open(&dup, 1, device) == 0;
                rlog("capture: display %ld, %s %ldx%ld", (long)asked, have_dup ? "DXGI" : "GDI", (long)(r.right - r.left),
                     (long)(r.bottom - r.top));
                fresh = 0;
                pending = 1;
                last_retry = rdc_now_us();
            }
            shown = asked;
            InterlockedExchange(&g_cap_shown, shown);
        }
        uint64_t now = rdc_now_us();
        int want = g_want_jpeg != 0;
        if (have_dup) {
            UINT timeout = 100;
            if (pending && want) {
                uint64_t due = last_sent + g_interval_us;
                timeout = now >= due ? 0 : (UINT)((due - now + 999) / 1000);
            }
            int r = dup_next(&dup, timeout);
            if (r < 0) {
                dup_close(&dup);
                Sleep(100);
                // A mode change may have moved the monitor: look it up again.
                RECT r;
                wchar_t dev[CCHDEVICENAME];
                if (monitor_for((uint32_t)shown, &r, dev) == 0) {
                    mon = r;
                    wcscpy(device, dev);
                }
                have_dup = dup_open(&dup, 0, device) == 0;
                last_retry = rdc_now_us();
                pending = 1;
                if (!have_dup) rlog("capture: DXGI lost, using GDI for now");
                continue;
            }
            if (r > 0) pending = 1;
        } else {
            if (now - last_poll < g_interval_us) {
                Sleep((DWORD)((g_interval_us - (now - last_poll)) / 1000) + 1);
                continue;
            }
            last_poll = now;
            if (now - last_retry > 2000000ULL) {
                last_retry = now;
                if (dup_open(&dup, 0, device) == 0) {
                    have_dup = 1;
                    pending = 1;
                    rlog("capture: back to DXGI, %dx%d", dup.w, dup.h);
                    continue;
                }
            }
            if (want && gdi_capture(&work, &mon) == 0) {
                fresh = 1;
                size_t len = (size_t)work.stride * work.h;
                if (prev_len != len || memcmp(prev, work.bits, len) != 0) {
                    pending = 1;
                    if (prev_len != len) {
                        free(prev);
                        prev = malloc(len);
                        prev_len = prev ? len : 0;
                    }
                    if (prev) memcpy(prev, work.bits, len);
                }
            }
        }
        if (cursor_changed(&cur)) pending = 1;
        if (InterlockedExchange(&g_force_key, 0)) pending = 1;
        if (!pending || !want) continue;
        now = rdc_now_us();
        if (now - last_sent < g_interval_us) continue;
        last_sent = now;
        // Frame = clean desktop image + cursor on top.
        int ok;
        if (have_dup)
            ok = dup.have_image ? dup_copy(&dup, &work) == 0 : gdi_capture(&work, &mon) == 0;
        else
            ok = fresh || gdi_capture(&work, &mon) == 0;
        fresh = 0;
        if (ok) {
            draw_cursor(&work, mon.left, mon.top);
            GdiFlush();
            ok = jpeg_encode(wic, &work, g_max_width, JPEG_QUALITY, now) == 0;
        }
        if (ok) {
            pending = 0;
            failures = 0;
        } else if (++failures == 20) {
            rlog("capture: frames keep failing");
        }
    }
    free(prev);
    frame_free(&work);
    dup_close(&dup);
    IWICImagingFactory_Release(wic);
    CoUninitialize();
    return 0;
}

int rdc_capture_start(int max_width, int fps, rdc_frame_cb cb, void *ctx) {
    if (g_cap_thread) return 0;
    g_cb = cb;
    g_cb_ctx = ctx;
    g_max_width = max_width;
    g_interval_us = fps > 0 && 1000000 / fps > 50000 ? (uint64_t)(1000000 / fps) : 50000;
    InterlockedExchange(&g_cap_run, 1);
    InterlockedExchange(&g_cap_status, -9);
    g_cap_ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!g_cap_ready) return -1;
    g_cap_thread = CreateThread(NULL, 0, capture_main, NULL, 0, NULL);
    if (!g_cap_thread) {
        CloseHandle(g_cap_ready);
        g_cap_ready = NULL;
        return -1;
    }
    WaitForSingleObject(g_cap_ready, 10000);
    CloseHandle(g_cap_ready);
    g_cap_ready = NULL;
    int status = (int)g_cap_status;
    if (status != 0) {
        InterlockedExchange(&g_cap_run, 0);
        WaitForSingleObject(g_cap_thread, 3000);
        CloseHandle(g_cap_thread);
        g_cap_thread = NULL;
    }
    return status;
}

int rdc_capture_display(uint32_t id) {
    RECT r;
    wchar_t dev[CCHDEVICENAME];
    if (id && monitor_for(id, &r, dev) != 0) return -1;
    InterlockedExchange(&g_cap_want, (LONG)id);
    if (!g_cap_thread) return 0;
    // The capture thread takes it at the top of its loop; frames after that are the new display's.
    for (int i = 0; i < 300 && g_cap_shown != (LONG)id; i++) Sleep(5);
    return g_cap_shown == (LONG)id ? 0 : -5;
}

void rdc_capture_stop(void) {
    if (!g_cap_thread) return;
    InterlockedExchange(&g_cap_run, 0);
    WaitForSingleObject(g_cap_thread, 5000);
    CloseHandle(g_cap_thread);
    g_cap_thread = NULL;
    InterlockedExchange(&g_cap_shown, -1);
    rlog("capture stopped");
}

int rdc_codec_caps(void) { return 2; }  // JPEG only for now; H.264 (Media Foundation) is the next step
void rdc_set_codecs(int h264, int jpeg) { InterlockedExchange(&g_want_jpeg, jpeg ? 1 : 0); }
void rdc_request_keyframe(void) { InterlockedExchange(&g_force_key, 1); }
void rdc_set_bitrate(int bits_per_second) {}

// ---------------------------------------------------------------------------
// Input

static SRWLOCK g_in_lock = SRWLOCK_INIT;
static uint8_t g_keys_down[0x200];  // pressed keys: scan code, 0x100 — extended
static int g_buttons;
static double g_wheel_x, g_wheel_y;

static void send_mouse(DWORD flags, LONG dx, LONG dy, DWORD data) {
    INPUT in;
    memset(&in, 0, sizeof in);
    in.type = INPUT_MOUSE;
    in.mi.dx = dx;
    in.mi.dy = dy;
    in.mi.mouseData = data;
    in.mi.dwFlags = flags;
    SendInput(1, &in, sizeof in);
}

static double clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

// Desktop coordinates are virtual-screen pixels; with MOUSEEVENTF_VIRTUALDESK, 0..65535 spans
// the whole virtual screen, every monitor.
void rdc_mouse_move(double x, double y) {
    int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    double nx = vw > 1 ? clamp01((x - vx) / (vw - 1)) : 0, ny = vh > 1 ? clamp01((y - vy) / (vh - 1)) : 0;
    send_mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, (LONG)(nx * 65535.0 + 0.5),
               (LONG)(ny * 65535.0 + 0.5), 0);
}

void rdc_mouse_button(int button, int down, double x, double y) {
    rdc_mouse_move(x, y);
    DWORD f;
    int bit;
    switch (button) {
    case 2:
        f = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        bit = 2;
        break;
    case 1:
        f = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
        bit = 4;
        break;
    default:
        f = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
        bit = 1;
        break;
    }
    AcquireSRWLockExclusive(&g_in_lock);
    if (down)
        g_buttons |= bit;
    else
        g_buttons &= ~bit;
    ReleaseSRWLockExclusive(&g_in_lock);
    send_mouse(f, 0, 0, 0);
}

void rdc_scroll(double dx, double dy) {
    // The browser gives pixels; one Windows wheel notch is 120 units, about 100 pixels.
    AcquireSRWLockExclusive(&g_in_lock);
    g_wheel_y += -dy * 1.2;
    g_wheel_x += dx * 1.2;
    int wy = (int)g_wheel_y, wx = (int)g_wheel_x;
    g_wheel_y -= wy;
    g_wheel_x -= wx;
    ReleaseSRWLockExclusive(&g_in_lock);
    if (wy) send_mouse(MOUSEEVENTF_WHEEL, 0, 0, (DWORD)wy);
    if (wx) send_mouse(MOUSEEVENTF_HWHEEL, 0, 0, (DWORD)wx);
}

static void key_now(int code, int down) {
    INPUT in;
    memset(&in, 0, sizeof in);
    in.type = INPUT_KEYBOARD;
    in.ki.wScan = (WORD)(code & 0xFF);
    in.ki.dwFlags = KEYEVENTF_SCANCODE | (down ? 0 : KEYEVENTF_KEYUP) |
                    ((code & 0xFF00) == 0xE000 ? KEYEVENTF_EXTENDEDKEY : 0);
    SendInput(1, &in, sizeof in);
}

void rdc_key(int code, int down) {
    int idx = (code & 0xFF) | ((code & 0xFF00) == 0xE000 ? 0x100 : 0);
    AcquireSRWLockExclusive(&g_in_lock);
    g_keys_down[idx] = down ? 1 : 0;
    ReleaseSRWLockExclusive(&g_in_lock);
    key_now(code, down);
}

// Text as Unicode key events (KEYEVENTF_UNICODE): the keyboard layout does not matter.
void rdc_text(const char *utf8, size_t len) {
    if (len == 0 || len > 1 << 20) return;
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, (int)len, NULL, 0);
    if (n <= 0) return;
    wchar_t *w = malloc((size_t)n * sizeof(wchar_t));
    INPUT *in = calloc((size_t)n * 2, sizeof(INPUT));
    if (w && in && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, (int)len, w, n) == n) {
        for (int i = 0; i < n; i++) {
            in[2 * i].type = in[2 * i + 1].type = INPUT_KEYBOARD;
            in[2 * i].ki.wScan = in[2 * i + 1].ki.wScan = w[i];
            in[2 * i].ki.dwFlags = KEYEVENTF_UNICODE;
            in[2 * i + 1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        }
        // In batches, so slow apps keep up with long text.
        for (int done = 0; done < 2 * n;) {
            int batch = 2 * n - done < 64 ? 2 * n - done : 64;
            SendInput((UINT)batch, in + done, sizeof(INPUT));
            done += batch;
            if (done < 2 * n) Sleep(2);
        }
    }
    free(in);
    free(w);
}

void rdc_release_all(void) {
    uint8_t keys[0x200];
    AcquireSRWLockExclusive(&g_in_lock);
    memcpy(keys, g_keys_down, sizeof keys);
    memset(g_keys_down, 0, sizeof g_keys_down);
    int buttons = g_buttons;
    g_buttons = 0;
    ReleaseSRWLockExclusive(&g_in_lock);
    for (int i = 0; i < 0x200; i++)
        if (keys[i]) key_now((i & 0xFF) | (i & 0x100 ? 0xE000 : 0), 0);
    if (buttons & 1) send_mouse(MOUSEEVENTF_LEFTUP, 0, 0, 0);
    if (buttons & 2) send_mouse(MOUSEEVENTF_RIGHTUP, 0, 0, 0);
    if (buttons & 4) send_mouse(MOUSEEVENTF_MIDDLEUP, 0, 0, 0);
}

void rdc_cursor_pos(double *x, double *y) {
    POINT p = {0, 0};
    GetCursorPos(&p);
    *x = p.x;
    *y = p.y;
}

// ---------------------------------------------------------------------------
// Files, network, system

void *rdc_read_file(const char *path, size_t *len) {
    wchar_t wp[1024];
    to_wide(path, wp, 1024);
    HANDLE f = CreateFileW(wp, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return NULL;
    LARGE_INTEGER size;
    if (!GetFileSizeEx(f, &size) || size.QuadPart > (64LL << 20)) {
        CloseHandle(f);
        return NULL;
    }
    size_t want = (size_t)size.QuadPart, total = 0;
    uint8_t *buf = malloc(want ? want : 1);
    DWORD got = 0;
    while (buf && total < want && ReadFile(f, buf + total, (DWORD)(want - total), &got, NULL) && got) total += got;
    CloseHandle(f);
    if (!buf) return NULL;
    *len = total;
    return buf;
}

int rdc_lan_ipv4(char *buf, int buflen) {
    ULONG size = 32 * 1024, rc = ERROR_BUFFER_OVERFLOW;
    IP_ADAPTER_ADDRESSES *list = NULL;
    for (int tries = 0; tries < 3 && rc == ERROR_BUFFER_OVERFLOW; tries++) {
        free(list);
        list = malloc(size);
        if (!list) return -1;
        rc = GetAdaptersAddresses(AF_INET,
                                  GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER |
                                      GAA_FLAG_INCLUDE_GATEWAYS,
                                  NULL, list, &size);
    }
    int found = -1;
    // Adapters with a gateway first — usually the home network rather than virtual adapters.
    for (int pass = 0; pass < 2 && found < 0 && rc == NO_ERROR; pass++) {
        for (IP_ADAPTER_ADDRESSES *a = list; a && found < 0; a = a->Next) {
            if (a->OperStatus != IfOperStatusUp || a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
            if (pass == 0 && !a->FirstGatewayAddress) continue;
            for (IP_ADAPTER_UNICAST_ADDRESS *u = a->FirstUnicastAddress; u; u = u->Next) {
                struct sockaddr_in *sin = (struct sockaddr_in *)u->Address.lpSockaddr;
                if (!sin || sin->sin_family != AF_INET) continue;
                const uint8_t *b = (const uint8_t *)&sin->sin_addr;
                if (b[0] == 169 && b[1] == 254) continue;
                snprintf(buf, (size_t)buflen, "%u.%u.%u.%u", b[0], b[1], b[2], b[3]);
                found = 0;
                break;
            }
        }
    }
    free(list);
    return found;
}

int rdc_computer_name(char *buf, int buflen) {
    wchar_t name[256];
    DWORD n = 256;
    if (!GetComputerNameExW(ComputerNamePhysicalDnsHostname, name, &n)) return -1;
    return to_utf8(name, buf, buflen);
}

// ---------------------------------------------------------------------------
// Updates

void *rdc_http_get(const char *url, size_t max_len, size_t *len, int *status) {
    *status = -1;
    *len = 0;
    wchar_t wurl[2048], host[256], path[2048], extra[1024], full[3072];
    to_wide(url, wurl, 2048);
    URL_COMPONENTS uc;
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize = sizeof uc;
    uc.lpszHostName = host;
    uc.dwHostNameLength = 256;
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = 2048;
    uc.lpszExtraInfo = extra;
    uc.dwExtraInfoLength = 1024;
    if (!WinHttpCrackUrl(wurl, 0, 0, &uc)) return NULL;
    wfmt(full, 3072, L"%ls%ls", path, extra);
    uint8_t *buf = NULL;
    HINTERNET s = WinHttpOpen(L"RDC-updater", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                              WINHTTP_NO_PROXY_BYPASS, 0);
    HINTERNET c = s ? WinHttpConnect(s, host, uc.nPort, 0) : NULL;
    HINTERNET r = c ? WinHttpOpenRequest(c, L"GET", full, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                         uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)
                    : NULL;
    if (!r) goto done;
    WinHttpSetTimeouts(r, 15000, 15000, 30000, 120000);
    if (!WinHttpSendRequest(r, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(r, NULL)) {
        rlog("network: request failed (%lu)", (unsigned long)GetLastError());
        goto done;
    }
    DWORD code = 0, sz = sizeof code;
    WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &code, &sz,
                        WINHTTP_NO_HEADER_INDEX);
    *status = (int)code;
    size_t cap = 64 * 1024, total = 0;
    buf = malloc(cap);
    for (;;) {
        DWORD avail = 0, got = 0;
        if (!buf || !WinHttpQueryDataAvailable(r, &avail) || total + avail > max_len) {
            free(buf);
            buf = NULL;
            break;
        }
        if (avail == 0) break;
        if (total + avail > cap) {
            while (total + avail > cap) cap *= 2;
            uint8_t *nb = realloc(buf, cap);
            if (!nb) {
                free(buf);
                buf = NULL;
                break;
            }
            buf = nb;
        }
        if (!WinHttpReadData(r, buf + total, avail, &got)) {
            free(buf);
            buf = NULL;
            break;
        }
        total += got;
    }
    if (buf) *len = total;
done:
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    if (s) WinHttpCloseHandle(s);
    return buf;
}

static void temp_path(wchar_t *out, const wchar_t *name) {
    wchar_t tmp[MAX_PATH];
    GetTempPathW(MAX_PATH, tmp);
    wfmt(out, MAX_PATH, L"%ls%ls", tmp, name);
}

int rdc_write_temp(const char *name, const void *data, size_t len, char *path_out, int path_len) {
    wchar_t dir[MAX_PATH], wname[260], path[MAX_PATH];
    temp_path(dir, L"rdc-download");
    CreateDirectoryW(dir, NULL);
    to_wide(name, wname, 260);
    const wchar_t *base = wname;
    for (const wchar_t *p = wname; *p; p++)
        if (*p == L'\\' || *p == L'/') base = p + 1;
    wfmt(path, MAX_PATH, L"%ls\\%ls", dir, base);
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return -1;
    DWORD w = 0;
    BOOL ok = WriteFile(f, data, (DWORD)len, &w, NULL) && w == len;
    CloseHandle(f);
    if (!ok) return -1;
    return to_utf8(path, path_out, path_len);
}

int rdc_install_path(char *buf, int buflen) {
    wchar_t exe[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH)) return -1;
    return to_utf8(exe, buf, buflen);
}

void rdc_cleanup_old_install(void) {
    wchar_t exe[MAX_PATH], dir[MAX_PATH], pattern[MAX_PATH], path[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH)) return;
    wcscpy(dir, exe);
    wchar_t *slash = wcsrchr(dir, L'\\');
    if (!slash) return;
    *slash = 0;
    wfmt(pattern, MAX_PATH, L"%ls.old-*", exe);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        wfmt(path, MAX_PATH, L"%ls\\%ls", dir, fd.cFileName);
        DeleteFileW(path);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

static int run_hidden(wchar_t *cmd) {
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) return -1;
    WaitForSingleObject(pi.hProcess, 120000);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}

// Version from the exe resources (ProductVersion) — confirms the right file was downloaded.
static int exe_version(const wchar_t *path, char *out, int out_len) {
    DWORD dummy = 0, size = GetFileVersionInfoSizeW(path, &dummy);
    if (!size) return -1;
    void *buf = malloc(size);
    if (!buf) return -1;
    int rc = -1;
    wchar_t *val = NULL;
    UINT n = 0;
    if (GetFileVersionInfoW(path, 0, size, buf) &&
        VerQueryValueW(buf, L"\\StringFileInfo\\040904B0\\ProductVersion", (void **)&val, &n) && val && n)
        rc = to_utf8(val, out, out_len);
    free(buf);
    return rc;
}

int rdc_install_update(const char *file_path, const char *version) {
    wchar_t exe[MAX_PATH], wfile[MAX_PATH], fresh[MAX_PATH], old[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH)) return -1;
    to_wide(file_path, wfile, MAX_PATH);
    size_t n = strlen(file_path);
    if (n > 4 && _stricmp(file_path + n - 4, ".exe") == 0) {
        wcscpy(fresh, wfile);
    } else {
        // Archive: tar.exe ships with Windows 10 1803+ and unpacks zip.
        wchar_t work[MAX_PATH], sysdir[MAX_PATH], sub[64], cmd[2048];
        wfmt(sub, 64, L"rdc-update-%lu", (unsigned long)GetCurrentProcessId());
        temp_path(work, sub);
        CreateDirectoryW(work, NULL);
        GetSystemDirectoryW(sysdir, MAX_PATH);
        wfmt(cmd, 2048, L"\"%ls\\tar.exe\" -xf \"%ls\" -C \"%ls\"", sysdir, wfile, work);
        if (run_hidden(cmd) != 0) {
            rlog("update: archive failed to unpack");
            return -3;
        }
        wfmt(fresh, MAX_PATH, L"%ls\\rdc.exe", work);
    }
    char got[64];
    if (exe_version(fresh, got, sizeof got) != 0 || strcmp(got, version) != 0) {
        rlog("update: wrong version in file (expected %s)", version);
        return -4;
    }
    // A running exe cannot be overwritten, but it can be renamed.
    wfmt(old, MAX_PATH, L"%ls.old-%lu", exe, (unsigned long)GetCurrentProcessId());
    if (!MoveFileExW(exe, old, MOVEFILE_REPLACE_EXISTING)) {
        rlog("update: cannot move old version aside (%lu)", (unsigned long)GetLastError());
        return -6;
    }
    if (!MoveFileExW(fresh, exe, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED)) {
        rlog("update: cannot put new version in place (%lu)", (unsigned long)GetLastError());
        MoveFileExW(old, exe, MOVEFILE_REPLACE_EXISTING);
        return -7;
    }
    rlog("update %s installed, restarting", version);
    SetEnvironmentVariableW(L"RDC_RESTART", L"1");
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    wchar_t *line = _wcsdup(GetCommandLineW());
    if (line && CreateProcessW(exe, line, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    } else {
        rlog("update: cannot restart (%lu)", (unsigned long)GetLastError());
    }
    free(line);
    ExitProcess(0);
    return 0;
}

// Permanent access: the seed file, held open (and so by one RDC only) for as long as this process lives.
static HANDLE g_seed = INVALID_HANDLE_VALUE;

static int seed_open(void) {
    if (g_seed != INVALID_HANDLE_VALUE) return 0;
    wchar_t dir[MAX_PATH], path[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return -1;
    wfmt(path, MAX_PATH, L"%ls\\RDC", dir);
    CreateDirectoryW(path, NULL);
    wfmt(path, MAX_PATH, L"%ls\\RDC\\permanent", dir);
    HANDLE h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_SHARING_VIOLATION ? -2 : -1;
    g_seed = h;
    return 0;
}

int rdc_seed_load(void *buf, int cap) {
    int rc = seed_open();
    if (rc != 0) return rc;
    DWORD got = 0;
    SetFilePointer(g_seed, 0, NULL, FILE_BEGIN);
    if (!ReadFile(g_seed, buf, (DWORD)cap, &got, NULL)) return -1;
    return (int)got;
}

int rdc_seed_save(const void *data, int len) {
    if (seed_open() != 0) return -1;
    DWORD put = 0;
    SetFilePointer(g_seed, 0, NULL, FILE_BEGIN);
    if (!SetEndOfFile(g_seed) || !WriteFile(g_seed, data, (DWORD)len, &put, NULL) || put != (DWORD)len) return -1;
    FlushFileBuffers(g_seed);
    return 0;
}

int rdc_pref_bool(const char *key, int def) {
    wchar_t wk[128];
    to_wide(key, wk, 128);
    DWORD v = 0, sz = sizeof v;
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\RDC", wk, RRF_RT_REG_DWORD, NULL, &v, &sz) == ERROR_SUCCESS)
        return v != 0;
    return def;
}

void rdc_set_pref_bool(const char *key, int value) {
    wchar_t wk[128];
    to_wide(key, wk, 128);
    HKEY k;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\RDC", 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) != ERROR_SUCCESS)
        return;
    DWORD v = value != 0;
    RegSetValueExW(k, wk, 0, REG_DWORD, (const BYTE *)&v, sizeof v);
    RegCloseKey(k);
}

int rdc_pref_string(const char *key, char *buf, int buflen) {
    wchar_t wk[128], wv[1024];
    to_wide(key, wk, 128);
    DWORD sz = sizeof wv;
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\RDC", wk, RRF_RT_REG_SZ, NULL, wv, &sz) != ERROR_SUCCESS) return -1;
    int n = WideCharToMultiByte(CP_UTF8, 0, wv, -1, buf, buflen, NULL, NULL);
    return n > 0 ? n - 1 : -1;
}

void rdc_set_pref_string(const char *key, const char *value) {
    wchar_t wk[128], wv[1024];
    to_wide(key, wk, 128);
    HKEY k;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\RDC", 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) != ERROR_SUCCESS)
        return;
    if (!value || !value[0]) {
        RegDeleteValueW(k, wk);
    } else {
        to_wide(value, wv, 1024);
        RegSetValueExW(k, wk, 0, REG_SZ, (const BYTE *)wv, (DWORD)((wcslen(wv) + 1) * sizeof(wchar_t)));
    }
    RegCloseKey(k);
}

// ---------------------------------------------------------------------------
// Administrator rights. RDC with a window restarts itself as administrator through the UAC
// prompt (rdc_app_prepare): Windows delivers injected input only to windows of the same or a
// lower integrity level, so without the rights a viewer cannot click in Task Manager, an
// installer or any app that runs as administrator. With them RDC also opens Windows Firewall
// for viewers and registers the phone camera, with no more prompts. Declined, RDC runs as before.

static void post_refresh(void);
static HANDLE g_instance;  // held by the one RDC window of this session
static int g_elevated;
static UINT g_msg_show;    // "RDC.ShowWindow": a second launch asks the running window to come forward

static int is_elevated(void) {
    HANDLE token = NULL;
    TOKEN_ELEVATION e;
    DWORD n = 0;
    int yes = 0;
    memset(&e, 0, sizeof e);
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        if (GetTokenInformation(token, TokenElevation, &e, sizeof e, &n)) yes = e.TokenIsElevated != 0;
        CloseHandle(token);
    }
    return yes;
}

// The arguments this process was started with, without the program's own name.
static const wchar_t *own_args(void) {
    const wchar_t *p = GetCommandLineW();
    if (*p == L'"') {
        p++;
        while (*p && *p != L'"') p++;
        if (*p) p++;
    } else {
        while (*p && *p != L' ' && *p != L'\t') p++;
    }
    while (*p == L' ' || *p == L'\t') p++;
    return p;
}

// Settings → "Start RDC at login" started this process: its window stays hidden.
static int started_at_login(void) { return wcsstr(own_args(), L"--login") != NULL; }

// Starts this exe again as administrator with these arguments; with `wait`, until it exits.
// 0 — started (its exit code in *code), 1 — the person declined the UAC prompt, -1 — failed.
static int run_elevated(const wchar_t *args, int wait, DWORD *code) {
    wchar_t exe[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH)) return -1;
    SHELLEXECUTEINFOW sei;
    memset(&sei, 0, sizeof sei);
    sei.cbSize = sizeof sei;
    sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    sei.lpVerb = L"runas";
    sei.lpFile = exe;
    sei.lpParameters = args;
    sei.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&sei)) return GetLastError() == ERROR_CANCELLED ? 1 : -1;
    if (sei.hProcess) {
        if (wait) {
            WaitForSingleObject(sei.hProcess, 120000);
            if (code) GetExitCodeProcess(sei.hProcess, code);
        }
        CloseHandle(sei.hProcess);
    }
    return 0;
}

// Lets viewers in through Windows Firewall: an inbound rule for this exe, written again on every
// start as administrator, since the file may have moved.
static void firewall_open(void) {
    wchar_t exe[MAX_PATH], sys[MAX_PATH], cmd[2048];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH) || !GetSystemDirectoryW(sys, MAX_PATH)) return;
    wfmt(cmd, 2048, L"\"%ls\\netsh.exe\" advfirewall firewall delete rule name=\"RDC\"", sys);
    run_hidden(cmd);
    wfmt(cmd, 2048, L"\"%ls\\netsh.exe\" advfirewall firewall add rule name=\"RDC\" dir=in action=allow program=\"%ls\" enable=yes profile=any",
         sys, exe);
    int rc = run_hidden(cmd);
    if (rc == 0)
        rlog("firewall: viewers are allowed in (rule \"RDC\")");
    else
        rlog("firewall: could not add the rule (netsh returned %d)", rc);
}

// ---------------------------------------------------------------------------
// "RDC Camera": the viewer's camera as a Windows 11 virtual camera (docs/PLAN.md, section 6).
// rdc-camera.dll (camera.c) is the media source that the Frame Server service loads; RDC.exe
// carries it, writes it to %ProgramData%\RDC\ and registers its class under HKLM, which takes
// administrator rights. While RDC runs it keeps the camera registered with the Frame Server
// (session lifetime: gone when RDC exits) and serves frames over the pipe of camera_pipe.h: each
// media source says which size its app picked and gets NV12 frames of that size, made from the
// viewer's JPEG with WIC. Windows has no user-mode way to add a microphone, so there is none.

// mfvirtualcamera.h is newer than the mingw headers: the parts used here, from the Windows SDK.
typedef struct IMFVirtualCamera IMFVirtualCamera;
typedef struct IMFVirtualCameraVtbl {
    IMFAttributesVtbl attributes;  // IUnknown and IMFAttributes: 33 entries
    HRESULT(STDMETHODCALLTYPE *AddDeviceSourceInfo)(IMFVirtualCamera *This, LPCWSTR info);
    HRESULT(STDMETHODCALLTYPE *AddProperty)(IMFVirtualCamera *This, const void *key, ULONG type, const BYTE *data, ULONG size);
    HRESULT(STDMETHODCALLTYPE *AddRegistryEntry)(IMFVirtualCamera *This, LPCWSTR name, LPCWSTR subkey, DWORD type, const BYTE *data, ULONG size);
    HRESULT(STDMETHODCALLTYPE *Start)(IMFVirtualCamera *This, IMFAsyncCallback *callback);
    HRESULT(STDMETHODCALLTYPE *Stop)(IMFVirtualCamera *This);
    HRESULT(STDMETHODCALLTYPE *Remove)(IMFVirtualCamera *This);
    HRESULT(STDMETHODCALLTYPE *GetMediaSource)(IMFVirtualCamera *This, IMFMediaSource **source);
    HRESULT(STDMETHODCALLTYPE *SendCameraProperty)(IMFVirtualCamera *This, REFGUID set, ULONG id, ULONG flags, void *payload, ULONG payload_len, void *data, ULONG data_len, ULONG *written);
    HRESULT(STDMETHODCALLTYPE *CreateSyncEvent)(IMFVirtualCamera *This, REFGUID set, ULONG id, ULONG flags, HANDLE event, void **sync);
    HRESULT(STDMETHODCALLTYPE *CreateSyncSemaphore)(IMFVirtualCamera *This, REFGUID set, ULONG id, ULONG flags, HANDLE semaphore, LONG adjustment, void **sync);
    HRESULT(STDMETHODCALLTYPE *Shutdown)(IMFVirtualCamera *This);
} IMFVirtualCameraVtbl;
struct IMFVirtualCamera {
    const IMFVirtualCameraVtbl *lpVtbl;
};
// MFVirtualCameraType_SoftwareCameraSource, MFVirtualCameraLifetime_Session, MFVirtualCameraAccess_CurrentUser: all 0.
typedef HRESULT(WINAPI *MFCreateVirtualCameraFn)(int type, int lifetime, int access, LPCWSTR name, LPCWSTR source_id,
                                                 const GUID *categories, ULONG category_count, IMFVirtualCamera **camera);

#define CAMERA_KEY L"Software\\Classes\\CLSID\\" RDC_CAMERA_CLSID_STR
#define CAMERA_PREF "phoneCamera"  // 0 after "Remove phone camera": do not register it again on its own

static const void *g_cam_dll;  // rdc-camera.dll as RDC.exe carries it
static size_t g_cam_dll_len;
static SRWLOCK g_cam_control = SRWLOCK_INIT;  // starting and stopping the virtual camera
static HANDLE g_cam_thread, g_cam_quit;       // the thread that owns the IMFVirtualCamera
static volatile LONG g_cam_running;           // "RDC Camera" is in the apps' lists right now
static volatile LONG g_cam_live;              // a viewer's camera is on
static uint64_t g_cam_retry_us;               // do not ask the Frame Server again before this
static volatile LONG g_cam_state = -1;        // cached camera_registered()
static uint64_t g_cam_state_us;

static INIT_ONCE g_cam_api_once = INIT_ONCE_STATIC_INIT;
static MFCreateVirtualCameraFn g_cam_api;

static BOOL CALLBACK camera_api_init(PINIT_ONCE once, PVOID arg, PVOID *ctx) {
    HMODULE m = LoadLibraryW(L"mfsensorgroup.dll");
    if (m) g_cam_api = (MFCreateVirtualCameraFn)(void *)GetProcAddress(m, "MFCreateVirtualCamera");
    return TRUE;
}

// MFCreateVirtualCamera, or NULL before Windows 11.
static MFCreateVirtualCameraFn camera_api(void) {
    InitOnceExecuteOnce(&g_cam_api_once, camera_api_init, NULL, NULL);
    return g_cam_api;
}

static void camera_paths(wchar_t *dir, wchar_t *dll) {
    PWSTR pd = NULL;
    if (SUCCEEDED(SHGetKnownFolderPath(&FOLDERID_ProgramData, 0, NULL, &pd)) && pd) {
        wfmt(dir, MAX_PATH, L"%ls\\RDC", pd);
        CoTaskMemFree(pd);
    } else {
        wcscpy(dir, L"C:\\ProgramData\\RDC");
    }
    wfmt(dll, MAX_PATH, L"%ls\\%ls", dir, RDC_CAMERA_DLL_NAME);
}

// 0 — not registered; 1 — registered with the DLL this RDC carries; 2 — registered with another one.
static int camera_registered(void) {
    wchar_t dir[MAX_PATH], path[MAX_PATH], reg[MAX_PATH];
    camera_paths(dir, path);
    DWORD size = sizeof reg;
    if (RegGetValueW(HKEY_LOCAL_MACHINE, CAMERA_KEY L"\\InprocServer32", NULL, RRF_RT_REG_SZ, NULL, reg, &size) != ERROR_SUCCESS) return 0;
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    int same = _wcsicmp(reg, path) == 0;
    if (same && g_cam_dll && g_cam_dll_len) {
        LARGE_INTEGER len;
        same = GetFileSizeEx(f, &len) && (uint64_t)len.QuadPart == g_cam_dll_len;
        uint8_t *have = same ? malloc(g_cam_dll_len) : NULL;
        size_t total = 0;
        DWORD got = 0;
        while (have && total < g_cam_dll_len && ReadFile(f, have + total, (DWORD)(g_cam_dll_len - total), &got, NULL) && got) total += got;
        same = have && total == g_cam_dll_len && memcmp(have, g_cam_dll, g_cam_dll_len) == 0;
        free(have);
    }
    CloseHandle(f);
    return same ? 1 : 2;
}

// camera_registered(), looked up at most once in two seconds: the window asks often.
static int camera_state(void) {
    uint64_t now = rdc_now_us();
    LONG s = g_cam_state;
    if (s < 0 || now - g_cam_state_us > 2000000) {
        s = camera_registered();
        g_cam_state_us = now;
        InterlockedExchange(&g_cam_state, s);
    }
    return (int)s;
}

// As administrator: writes the DLL and its COM class, or removes them. 0 or a negative error.
static int camera_register(int install) {
    wchar_t dir[MAX_PATH], path[MAX_PATH], old[MAX_PATH];
    camera_paths(dir, path);
    InterlockedExchange(&g_cam_state, -1);
    if (!install) {
        LONG rc = RegDeleteTreeW(HKEY_LOCAL_MACHINE, CAMERA_KEY);
        // The Frame Server may still hold the file: then it goes at the next restart of Windows.
        if (!DeleteFileW(path) && GetLastError() != ERROR_FILE_NOT_FOUND) MoveFileExW(path, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
        if (rc != ERROR_SUCCESS && rc != ERROR_FILE_NOT_FOUND) {
            rlog("phone camera: cannot remove the registration (%ld)", (long)rc);
            return -4;
        }
        return 0;
    }
    if (!g_cam_dll || !g_cam_dll_len) return -2;
    CreateDirectoryW(dir, NULL);
    // A loaded DLL cannot be overwritten, but it can be renamed out of the way.
    if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES && !DeleteFileW(path)) {
        wfmt(old, MAX_PATH, L"%ls.old-%lu", path, (unsigned long)GetTickCount());
        if (MoveFileExW(path, old, MOVEFILE_REPLACE_EXISTING)) MoveFileExW(old, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
    }
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) {
        rlog("phone camera: cannot write the media source into ProgramData (%lu)", (unsigned long)GetLastError());
        return -3;
    }
    DWORD written = 0;
    BOOL ok = WriteFile(f, g_cam_dll, (DWORD)g_cam_dll_len, &written, NULL) && written == g_cam_dll_len;
    CloseHandle(f);
    if (!ok) return -3;
    static const wchar_t name[] = L"RDC Camera media source", both[] = L"Both";
    HKEY k;
    LONG rc = RegCreateKeyExW(HKEY_LOCAL_MACHINE, CAMERA_KEY, 0, NULL, 0, KEY_WRITE, NULL, &k, NULL);
    if (rc == ERROR_SUCCESS) {
        RegSetValueExW(k, NULL, 0, REG_SZ, (const BYTE *)name, sizeof name);
        RegCloseKey(k);
        rc = RegCreateKeyExW(HKEY_LOCAL_MACHINE, CAMERA_KEY L"\\InprocServer32", 0, NULL, 0, KEY_WRITE, NULL, &k, NULL);
    }
    if (rc == ERROR_SUCCESS) {
        rc = RegSetValueExW(k, NULL, 0, REG_SZ, (const BYTE *)path, (DWORD)((wcslen(path) + 1) * sizeof(wchar_t)));
        if (rc == ERROR_SUCCESS) rc = RegSetValueExW(k, L"ThreadingModel", 0, REG_SZ, (const BYTE *)both, sizeof both);
        RegCloseKey(k);
    }
    if (rc != ERROR_SUCCESS) {
        rlog("phone camera: cannot register the media source (%ld)", (long)rc);
        return -4;
    }
    return 0;
}

// --- Frames for the media sources: the pipe's server.

typedef struct CamClient {
    struct CamClient *next;
    HANDLE pipe, event;  // event: a frame or "camera off" waits to be sent
    uint32_t w, h;       // the size this app picked
    uint8_t *frame;      // NV12 of that size waiting to be sent: the newest one only
    int clear;           // say that the phone's camera is off
} CamClient;

static SRWLOCK g_cam_lock = SRWLOCK_INIT;  // the list and what waits in each client
static CamClient *g_cam_clients;
static HANDLE g_cam_server;

static BOOL pipe_read_all(HANDLE p, void *buf, DWORD len) {
    DWORD total = 0, n = 0;
    while (total < len) {
        if (!ReadFile(p, (uint8_t *)buf + total, len - total, &n, NULL) || n == 0) return FALSE;
        total += n;
    }
    return TRUE;
}

static BOOL pipe_write_all(HANDLE p, const void *buf, DWORD len) {
    DWORD total = 0, n = 0;
    while (total < len) {
        if (!WriteFile(p, (const uint8_t *)buf + total, len - total, &n, NULL)) return FALSE;
        total += n;
    }
    return TRUE;
}

static DWORD WINAPI camera_client_main(LPVOID arg) {
    CamClient *c = arg;
    rdc_camera_want want;
    int listed = 0;
    if (pipe_read_all(c->pipe, &want, sizeof want) && want.magic == RDC_CAMERA_WANT && want.width >= 16 && want.width <= 4096 &&
        want.height >= 16 && want.height <= 4096 && !((want.width | want.height) & 1)) {
        c->w = want.width;
        c->h = want.height;
        AcquireSRWLockExclusive(&g_cam_lock);
        c->next = g_cam_clients;
        g_cam_clients = c;
        ReleaseSRWLockExclusive(&g_cam_lock);
        listed = 1;
        for (;;) {
            DWORD r = WaitForSingleObject(c->event, 2000);
            if (r == WAIT_TIMEOUT) {
                // Nothing to send: is the media source still there?
                DWORD avail = 0;
                if (!PeekNamedPipe(c->pipe, NULL, 0, NULL, &avail, NULL)) break;
                continue;
            }
            AcquireSRWLockExclusive(&g_cam_lock);
            uint8_t *frame = c->frame;
            int clear = c->clear;
            c->frame = NULL;
            c->clear = 0;
            ReleaseSRWLockExclusive(&g_cam_lock);
            rdc_camera_frame hdr = {RDC_CAMERA_FRAME, c->w, c->h, frame ? c->w * c->h * 3 / 2 : 0};
            BOOL ok = TRUE;
            if (frame || clear) ok = pipe_write_all(c->pipe, &hdr, sizeof hdr) && (!frame || pipe_write_all(c->pipe, frame, hdr.size));
            free(frame);
            if (!ok) break;
        }
    }
    if (listed) {
        AcquireSRWLockExclusive(&g_cam_lock);
        for (CamClient **pp = &g_cam_clients; *pp; pp = &(*pp)->next) {
            if (*pp == c) {
                *pp = c->next;
                break;
            }
        }
        ReleaseSRWLockExclusive(&g_cam_lock);
    }
    DisconnectNamedPipe(c->pipe);
    CloseHandle(c->pipe);
    CloseHandle(c->event);
    free(c->frame);
    free(c);
    return 0;
}

static DWORD WINAPI camera_server_main(LPVOID arg) {
    // Anyone on this computer may connect and read: the Frame Server runs as Local Service in
    // session 0. Frames only flow out, and only to local clients.
    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, FALSE};
    PSECURITY_DESCRIPTOR sd = NULL;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:(A;;GRGW;;;WD)", SDDL_REVISION_1, &sd, NULL)) sa.lpSecurityDescriptor = sd;
    for (;;) {
        HANDLE p = CreateNamedPipeW(RDC_CAMERA_PIPE, PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                    PIPE_UNLIMITED_INSTANCES, 1 << 20, 4096, 0, &sa);
        if (p == INVALID_HANDLE_VALUE) {
            rlog("phone camera: cannot open the frame pipe (%lu)", (unsigned long)GetLastError());
            Sleep(5000);
            continue;
        }
        if (!ConnectNamedPipe(p, NULL) && GetLastError() != ERROR_PIPE_CONNECTED) {
            CloseHandle(p);
            continue;
        }
        CamClient *c = calloc(1, sizeof *c);
        HANDLE t = NULL;
        if (c) {
            c->pipe = p;
            c->event = CreateEventW(NULL, FALSE, FALSE, NULL);
            if (c->event) t = CreateThread(NULL, 0, camera_client_main, c, 0, NULL);
        }
        if (t) {
            CloseHandle(t);
        } else {
            if (c && c->event) CloseHandle(c->event);
            free(c);
            CloseHandle(p);
        }
    }
}

// --- The virtual camera itself.

static DWORD WINAPI camera_main(LPVOID arg) {
    MFCreateVirtualCameraFn create = camera_api();
    HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    HRESULT mf = MFStartup(MF_VERSION, MFSTARTUP_LITE);
    IMFVirtualCamera *cam = NULL;
    HRESULT hr = FAILED(mf) ? mf : create(0, 0, 0, RDC_CAMERA_FRIENDLY_NAME, RDC_CAMERA_CLSID_STR, NULL, 0, &cam);
    if (SUCCEEDED(hr)) hr = cam->lpVtbl->Start(cam, NULL);
    if (SUCCEEDED(hr)) {
        InterlockedExchange(&g_cam_running, 1);
        rlog("phone camera: \"RDC Camera\" is in the apps' camera lists");
        post_refresh();
        WaitForSingleObject(g_cam_quit, INFINITE);
        InterlockedExchange(&g_cam_running, 0);
    } else if (hr == E_ACCESSDENIED) {
        rlog("phone camera: Windows refused the virtual camera — camera access is off in Settings > Privacy & security > Camera");
    } else {
        rlog("phone camera: Windows did not start the virtual camera (0x%08lx)", (unsigned long)hr);
    }
    if (cam) {
        cam->lpVtbl->Shutdown(cam);  // a session camera leaves the apps' lists here
        cam->lpVtbl->attributes.Release((IMFAttributes *)cam);
    }
    if (SUCCEEDED(mf)) MFShutdown();
    if (SUCCEEDED(co)) CoUninitialize();
    post_refresh();
    return 0;
}

// Registers "RDC Camera" with the Frame Server if its media source is installed; no more than
// one try in half a minute while Windows refuses.
static void camera_open(void) {
    if (!camera_api() || camera_state() != 1) return;
    AcquireSRWLockExclusive(&g_cam_control);
    if (g_cam_thread && WaitForSingleObject(g_cam_thread, 0) == WAIT_OBJECT_0) {  // the last try has ended
        CloseHandle(g_cam_thread);
        CloseHandle(g_cam_quit);
        g_cam_thread = g_cam_quit = NULL;
    }
    uint64_t now = rdc_now_us();
    if (!g_cam_thread && now >= g_cam_retry_us) {
        g_cam_retry_us = now + 30000000;
        if (!g_cam_server) g_cam_server = CreateThread(NULL, 0, camera_server_main, NULL, 0, NULL);
        g_cam_quit = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (g_cam_quit) g_cam_thread = CreateThread(NULL, 0, camera_main, NULL, 0, NULL);
        if (!g_cam_thread && g_cam_quit) {
            CloseHandle(g_cam_quit);
            g_cam_quit = NULL;
        }
    }
    ReleaseSRWLockExclusive(&g_cam_control);
}

static void camera_close(void) {
    AcquireSRWLockExclusive(&g_cam_control);
    if (g_cam_thread) {
        SetEvent(g_cam_quit);
        WaitForSingleObject(g_cam_thread, 10000);
        CloseHandle(g_cam_thread);
        CloseHandle(g_cam_quit);
        g_cam_thread = g_cam_quit = NULL;
    }
    g_cam_retry_us = 0;
    ReleaseSRWLockExclusive(&g_cam_control);
}

int rdc_media_status(void) {
    if (!camera_api()) return 0;  // Windows 10: no virtual camera; no microphone on any Windows
    int status = RDC_MEDIA_CAMERA_SETUP;
    int state = camera_state();
    if (state) status |= RDC_MEDIA_CAMERA_INSTALLED;
    if (state == 2) status |= RDC_MEDIA_CAMERA_OUTDATED;
    if (g_cam_running)
        status |= RDC_MEDIA_CAMERA;
    else if (state == 1)
        camera_open();
    return status;
}

int rdc_mic_install(int install) { return -1; }
void rdc_mic_start(void) {}
void rdc_mic_push(const int16_t *pcm, int frames) {}
void rdc_mic_stop(void) {}

int rdc_camera_install(int install, const void *dll, size_t dll_len) {
    if (dll && dll_len) {
        g_cam_dll = dll;
        g_cam_dll_len = dll_len;
    }
    if (!camera_api()) {
        rlog("phone camera: this needs Windows 11");
        return -1;
    }
    if (!install) camera_close();  // let go of the camera before its media source is removed
    int rc;
    if (is_elevated()) {
        rc = camera_register(install);
    } else {
        DWORD code = 1;
        int r = run_elevated(install ? L"--register-camera" : L"--unregister-camera", 1, &code);
        rc = r == 1 ? 1 : r == 0 && code == 0 ? 0 : -1;
    }
    InterlockedExchange(&g_cam_state, -1);
    if (rc == 0) rdc_set_pref_bool(CAMERA_PREF, install);
    post_refresh();
    return rc;
}

void rdc_camera_start(void) { InterlockedExchange(&g_cam_live, 1); }

void rdc_camera_stop(void) {
    InterlockedExchange(&g_cam_live, 0);
    AcquireSRWLockExclusive(&g_cam_lock);
    for (CamClient *c = g_cam_clients; c; c = c->next) {
        free(c->frame);
        c->frame = NULL;
        c->clear = 1;
        SetEvent(c->event);
    }
    ReleaseSRWLockExclusive(&g_cam_lock);
}

// BGRA (bw × bh) into the middle of an NV12 frame (w × h), black around it. BT.601, video range.
static void bgra_to_nv12(const uint8_t *bgra, int stride, int bw, int bh, uint8_t *nv12, int w, int h) {
    uint8_t *yp = nv12, *uvp = nv12 + (size_t)w * h;
    memset(yp, 16, (size_t)w * h);
    memset(uvp, 128, (size_t)w * h / 2);
    int ox = ((w - bw) / 2) & ~1, oy = ((h - bh) / 2) & ~1;
    for (int y = 0; y < bh; y++) {
        const uint8_t *s = bgra + (size_t)y * stride;
        uint8_t *d = yp + (size_t)(oy + y) * w + ox;
        for (int x = 0; x < bw; x++, s += 4) d[x] = (uint8_t)((66 * s[2] + 129 * s[1] + 25 * s[0] + 128 + (16 << 8)) >> 8);
    }
    for (int y = 0; y + 1 < bh; y += 2) {
        const uint8_t *s0 = bgra + (size_t)y * stride, *s1 = s0 + stride;
        uint8_t *d = uvp + (size_t)((oy + y) / 2) * w + ox;
        for (int x = 0; x + 1 < bw; x += 2) {
            const uint8_t *a = s0 + x * 4, *b2 = s1 + x * 4;
            int b = a[0] + a[4] + b2[0] + b2[4], g = a[1] + a[5] + b2[1] + b2[5], r = a[2] + a[6] + b2[2] + b2[6];  // 2 × 2 pixels
            d[x] = (uint8_t)((-38 * r - 74 * g + 112 * b + 512 + (128 << 10)) >> 10);
            d[x + 1] = (uint8_t)((112 * r - 94 * g - 18 * b + 512 + (128 << 10)) >> 10);
        }
    }
}

// One JPEG frame from the viewer: decoded, fitted into each size the apps picked, handed to the
// media sources. Called on the viewer's thread, up to 15 times a second.
void rdc_camera_push(const uint8_t *jpeg, size_t len, int width, int height) {
    if (!g_cam_live || !jpeg || len == 0 || len > (8u << 20)) return;
    uint32_t sizes[4][2];
    int count = 0;
    AcquireSRWLockShared(&g_cam_lock);
    for (CamClient *c = g_cam_clients; c; c = c->next) {
        int known = 0;
        for (int i = 0; i < count; i++) known |= sizes[i][0] == c->w && sizes[i][1] == c->h;
        if (!known && count < 4) {
            sizes[count][0] = c->w;
            sizes[count][1] = c->h;
            count++;
        }
    }
    ReleaseSRWLockShared(&g_cam_lock);
    if (count == 0) return;  // no app has the camera open

    HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IWICImagingFactory *wic = NULL;
    IWICStream *in = NULL;
    IWICBitmapDecoder *dec = NULL;
    IWICBitmapFrameDecode *src = NULL;
    UINT iw = 0, ih = 0;
    if (FAILED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void **)&wic))) goto done;
    if (FAILED(IWICImagingFactory_CreateStream(wic, &in))) goto done;
    if (FAILED(IWICStream_InitializeFromMemory(in, (BYTE *)jpeg, (DWORD)len))) goto done;
    if (FAILED(IWICImagingFactory_CreateDecoderFromStream(wic, (IStream *)in, NULL, WICDecodeMetadataCacheOnDemand, &dec))) goto done;
    if (FAILED(IWICBitmapDecoder_GetFrame(dec, 0, &src))) goto done;
    if (FAILED(IWICBitmapFrameDecode_GetSize(src, &iw, &ih)) || iw < 2 || ih < 2 || iw > 8192 || ih > 8192) goto done;
    for (int i = 0; i < count; i++) {
        int w = (int)sizes[i][0], h = (int)sizes[i][1];
        // The whole picture, as large as fits, with even sides.
        double k = (double)w / iw < (double)h / ih ? (double)w / iw : (double)h / ih;
        int bw = (int)(iw * k + 0.5) & ~1, bh = (int)(ih * k + 0.5) & ~1;
        if (bw < 2) bw = 2;
        if (bh < 2) bh = 2;
        if (bw > w) bw = w;
        if (bh > h) bh = h;
        IWICBitmapScaler *scaler = NULL;
        IWICFormatConverter *conv = NULL;
        uint8_t *bgra = malloc((size_t)bw * bh * 4), *nv12 = malloc((size_t)w * h * 3 / 2);
        int ok = bgra && nv12 && SUCCEEDED(IWICImagingFactory_CreateBitmapScaler(wic, &scaler)) &&
                 SUCCEEDED(IWICBitmapScaler_Initialize(scaler, (IWICBitmapSource *)src, (UINT)bw, (UINT)bh, WICBitmapInterpolationModeLinear)) &&
                 SUCCEEDED(IWICImagingFactory_CreateFormatConverter(wic, &conv)) &&
                 SUCCEEDED(IWICFormatConverter_Initialize(conv, (IWICBitmapSource *)scaler, &GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, NULL, 0.0,
                                                          WICBitmapPaletteTypeCustom)) &&
                 SUCCEEDED(IWICFormatConverter_CopyPixels(conv, NULL, (UINT)bw * 4, (UINT)bw * (UINT)bh * 4, bgra));
        if (conv) IWICFormatConverter_Release(conv);
        if (scaler) IWICBitmapScaler_Release(scaler);
        if (ok) {
            bgra_to_nv12(bgra, bw * 4, bw, bh, nv12, w, h);
            size_t size = (size_t)w * h * 3 / 2;
            AcquireSRWLockExclusive(&g_cam_lock);
            for (CamClient *c = g_cam_clients; c; c = c->next) {
                if ((int)c->w != w || (int)c->h != h) continue;
                uint8_t *copy = malloc(size);
                if (!copy) continue;
                memcpy(copy, nv12, size);
                free(c->frame);  // an unsent older frame gives way
                c->frame = copy;
                SetEvent(c->event);
            }
            ReleaseSRWLockExclusive(&g_cam_lock);
        }
        free(bgra);
        free(nv12);
    }
done:
    if (src) IWICBitmapFrameDecode_Release(src);
    if (dec) IWICBitmapDecoder_Release(dec);
    if (in) IWICStream_Release(in);
    if (wic) IWICImagingFactory_Release(wic);
    if (SUCCEEDED(co)) CoUninitialize();
}

// What RDC does once it has administrator rights, off the window's thread.
static DWORD WINAPI admin_setup_main(LPVOID arg) {
    firewall_open();
    if (camera_api() && rdc_pref_bool(CAMERA_PREF, 1) && camera_registered() != 1) {
        if (camera_register(1) == 0) rlog("phone camera: the media source is installed");
    }
    camera_open();
    post_refresh();
    return 0;
}

int rdc_app_prepare(const void *camera_dll, size_t camera_dll_len) {
    g_cam_dll = camera_dll;
    g_cam_dll_len = camera_dll_len;
    int relaunched = wcsstr(GetCommandLineW(), L"--elevated") != NULL;  // the copy the UAC prompt started
    int restart = GetEnvironmentVariableW(L"RDC_RESTART", NULL, 0) != 0;  // an update: the old version is leaving
    SetEnvironmentVariableW(L"RDC_RESTART", NULL);
    g_elevated = is_elevated();
    g_msg_show = RegisterWindowMessageW(L"RDC.ShowWindow");
    if (!restart && !relaunched) {
        // Already running: its window comes forward, whatever rights either of the two has.
        HWND other = FindWindowW(L"RDCWindow", NULL);
        if (other) {
            PostMessageW(other, g_msg_show, 0, 0);
            return 1;
        }
    }
    // Started at login from the Run key: a UAC prompt there would hold the login up with no one to
    // answer it, so this run keeps the normal rights (the scheduled task starts RDC elevated already).
    if (!g_elevated && !relaunched && started_at_login()) {
        rlog("started at login without administrator rights: input will not reach apps that run as administrator");
    } else if (!g_elevated && !relaunched) {
        wchar_t args[2048];
        wfmt(args, 2048, L"%ls --elevated", own_args());
        int r = run_elevated(args, 0, NULL);
        if (r == 0) return 1;  // the administrator copy takes over
        if (r == 1)
            rlog("running without administrator rights (the UAC prompt was declined): input will not reach apps that run as administrator");
        else
            rlog("could not restart as administrator (%lu)", (unsigned long)GetLastError());
    }
    g_instance = CreateMutexW(NULL, FALSE, L"Local\\RDC-host");
    if (g_instance) {
        DWORD r = WaitForSingleObject(g_instance, restart || relaunched ? 15000 : 0);
        if (r != WAIT_OBJECT_0 && r != WAIT_ABANDONED) {
            HWND other = FindWindowW(L"RDCWindow", NULL);
            if (other) PostMessageW(other, g_msg_show, 0, 0);
            return 1;
        }
    }
    if (g_elevated) {
        HANDLE t = CreateThread(NULL, 0, admin_setup_main, NULL, 0, NULL);
        if (t) CloseHandle(t);
    } else {
        camera_open();  // registered by an earlier run as administrator
    }
    return 0;
}

// ---------------------------------------------------------------------------
// App window

enum { ID_COPY = 101, ID_OPEN, ID_NEWCODE, ID_KICK, ID_AUTO, ID_CHECK, ID_INSTALL, ID_COPY_REMOTE, ID_OPEN_REMOTE, ID_MEDIA_STOP, ID_CAMERA,
       ID_SETTINGS };
#define WM_RDC_REFRESH (WM_APP + 1)
#define WM_RDC_READY (WM_APP + 2)
#define WM_RDC_RELAY_DONE (WM_APP + 3)  // a relay check finished: lParam — its RelayCheck
#define TIMER_COPIED 1
#define IDM_QUIT 0x0110  // "Quit RDC" in the window menu (system command ids keep the low 4 bits clear)
#define CLIENT_W 440
#define CLIENT_H 600
static const DWORD kWindowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;

static HWND volatile g_hwnd;
static HWND g_code, g_link, g_copy, g_status, g_upd_status, g_auto, g_check, g_install, g_lbl_code, g_lbl_link, g_kick;
static HWND g_lbl_remote, g_remote, g_copy_remote, g_open_remote;
static HWND g_media, g_media_stop, g_cam_caption, g_cam_button, g_settings;
static volatile LONG g_ai_active;  // an AI agent is connected: the kick button stops it
static HFONT g_font, g_font_big, g_font_small;
static rdc_ctx_cb g_on_ready;
static rdc_action_cb g_on_action;
static void *g_app_ctx;
static int g_dpi = 96;

// Window state: written from any thread, shown on the window thread.
static SRWLOCK g_ui_lock = SRWLOCK_INIT;
static wchar_t g_ui_code[32] = L"— — —", g_ui_link[256] = L"", g_ui_remote[256] = L"", g_ui_status[512] = L"Starting…";
static wchar_t g_ui_remote_caption[128] = L"";
static wchar_t g_ui_media[160] = L"";  // what a viewer lends right now
static wchar_t g_ui_version[32] = L"", g_ui_upd[512] = L"";
static int g_ui_auto = 1, g_ui_can_install, g_ui_busy;
// Permanent access, from rdc_app_set_permanent: the link, its QR code, the authenticator's QR code and key.
#define QR_MAX (17 + 4 * 15)  // core/qr.zig: versions 1–15
static int g_perm_on, g_perm_serial;
static wchar_t g_perm_link[512] = L"", g_perm_key[96] = L"";
static uint8_t g_perm_link_qr[QR_MAX * QR_MAX], g_perm_auth_qr[QR_MAX * QR_MAX];
static int g_perm_link_qr_size, g_perm_auth_qr_size;

static void settings_refresh(void);
static void perm_refresh(void);

static int px(int v) { return MulDiv(v, g_dpi, 96); }

static void set_text(HWND w, const wchar_t *text) {
    wchar_t cur[512];
    GetWindowTextW(w, cur, 512);
    if (wcscmp(cur, text) != 0) SetWindowTextW(w, text);
}

static void refresh_ui(void) {
    HWND hwnd = g_hwnd;
    if (!hwnd) return;
    wchar_t code[32], link[256], remote[256], remote_caption[128], status[512], ver[32], upd[512], title[64], media[160];
    AcquireSRWLockShared(&g_ui_lock);
    wcscpy(media, g_ui_media);
    wcscpy(code, g_ui_code);
    wcscpy(link, g_ui_link);
    wcscpy(remote, g_ui_remote);
    wcscpy(remote_caption, g_ui_remote_caption);
    wcscpy(status, g_ui_status);
    wcscpy(ver, g_ui_version);
    wcscpy(upd, g_ui_upd);
    int autoupd = g_ui_auto, can = g_ui_can_install, busy = g_ui_busy;
    ReleaseSRWLockShared(&g_ui_lock);
    set_text(g_code, code);
    set_text(g_link, link);
    set_text(g_remote, remote);
    int has_remote = remote[0] != 0;
    set_text(g_lbl_remote, remote_caption);
    ShowWindow(g_remote, has_remote ? SW_SHOW : SW_HIDE);
    ShowWindow(g_copy_remote, has_remote ? SW_SHOW : SW_HIDE);
    ShowWindow(g_open_remote, has_remote ? SW_SHOW : SW_HIDE);
    set_text(g_status, status);
    set_text(g_upd_status, upd);
    wfmt(title, 64, L"RDC%ls%ls%ls", ver[0] ? L" " : L"", ver, g_elevated ? L" — administrator" : L"");
    set_text(hwnd, title);
    // The viewer's phone as this PC's camera: what is live, and the camera's state with its button.
    int ms = rdc_media_status();
    const wchar_t *caption, *cam_button = NULL;
    if (ms & RDC_MEDIA_CAMERA) {
        caption = L"Phone camera is ready: a phone connected to RDC can be this PC's camera — pick \"RDC Camera\" in any app. "
                  L"Windows has no way to add a phone microphone.";
        cam_button = L"Remove phone camera";
    } else if (ms & RDC_MEDIA_CAMERA_OUTDATED) {
        caption = L"Phone camera is installed from another version of RDC. Update it to use it with this one.";
        cam_button = L"Update phone camera";
    } else if (ms & RDC_MEDIA_CAMERA_INSTALLED) {
        caption = L"Phone camera is installed, but Windows has not started it — the reason is in the log.";
        cam_button = L"Remove phone camera";
    } else if (ms & RDC_MEDIA_CAMERA_SETUP) {
        caption = L"Phone camera is off. Enable it, and a phone connected to RDC can be this PC's camera (\"RDC Camera\" in any app).";
        cam_button = L"Enable phone camera";
    } else {
        caption = L"A phone as this PC's camera needs Windows 11. Windows has no way to add a phone microphone.";
    }
    set_text(g_cam_caption, caption);
    if (cam_button) set_text(g_cam_button, cam_button);
    ShowWindow(g_cam_button, cam_button ? SW_SHOW : SW_HIDE);
    set_text(g_media, media);
    ShowWindow(g_media_stop, media[0] ? SW_SHOW : SW_HIDE);
    SendMessageW(g_auto, BM_SETCHECK, autoupd ? BST_CHECKED : BST_UNCHECKED, 0);
    EnableWindow(g_check, !busy);
    ShowWindow(g_install, can ? SW_SHOW : SW_HIDE);
    EnableWindow(g_install, can && !busy);
    set_text(g_kick, g_ai_active ? L"Stop AI agent" : L"Disconnect all");
    settings_refresh();
    perm_refresh();
}

static void post_refresh(void) {
    HWND hwnd = g_hwnd;
    if (hwnd) PostMessageW(hwnd, WM_RDC_REFRESH, 0, 0);
}

static HWND make(HWND parent, const wchar_t *cls, const wchar_t *text, DWORD style, DWORD ex, int x, int y, int w, int h,
                 int id, HFONT font) {
    HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, px(x), px(y), px(w), px(h), parent,
                             (HMENU)(INT_PTR)id, GetModuleHandleW(NULL), NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)font, TRUE);
    return c;
}

static void create_fonts(void) {
    if (g_font) DeleteObject(g_font);
    if (g_font_big) DeleteObject(g_font_big);
    if (g_font_small) DeleteObject(g_font_small);
    g_font = CreateFontW(-px(15), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_small = CreateFontW(-px(13), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_big = CreateFontW(-px(40), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
}

static void build_controls(HWND p) {
    const DWORD btn = BS_PUSHBUTTON | WS_TABSTOP;
    g_lbl_code = make(p, L"STATIC", L"Connection code", SS_CENTER, 0, 0, 14, CLIENT_W, 18, 0, g_font_small);
    g_code = make(p, L"STATIC", L"— — —", SS_CENTER, 0, 0, 32, CLIENT_W, 52, 0, g_font_big);
    g_lbl_link = make(p, L"STATIC", L"Browser link on this network", SS_CENTER, 0, 0, 90, CLIENT_W, 18, 0, g_font_small);
    g_link = make(p, L"EDIT", L"", ES_CENTER | ES_READONLY | ES_AUTOHSCROLL | WS_TABSTOP, WS_EX_CLIENTEDGE, 24, 110, 392, 26,
                  0, g_font);
    g_copy = make(p, L"BUTTON", L"Copy link", btn, 0, 45, 144, 170, 30, ID_COPY, g_font);
    make(p, L"BUTTON", L"Open in browser", btn, 0, 225, 144, 170, 30, ID_OPEN, g_font);
    // The link from anywhere: GitHub Pages finds this computer through public brokers and connects over WebRTC.
    g_lbl_remote = make(p, L"STATIC", L"", SS_CENTER, 0, 0, 186, CLIENT_W, 18, 0, g_font_small);
    g_remote = make(p, L"EDIT", L"", ES_CENTER | ES_READONLY | ES_AUTOHSCROLL | WS_TABSTOP, WS_EX_CLIENTEDGE, 24, 206, 392, 26,
                    0, g_font);
    g_copy_remote = make(p, L"BUTTON", L"Copy link", btn, 0, 45, 240, 170, 30, ID_COPY_REMOTE, g_font);
    g_open_remote = make(p, L"BUTTON", L"Open in browser", btn, 0, 225, 240, 170, 30, ID_OPEN_REMOTE, g_font);
    g_status = make(p, L"STATIC", L"", SS_CENTER | SS_ENDELLIPSIS, 0, 12, 280, 416, 20, 0, g_font);
    make(p, L"BUTTON", L"New code", btn, 0, 45, 306, 170, 30, ID_NEWCODE, g_font);
    g_kick = make(p, L"BUTTON", L"Disconnect all", btn, 0, 225, 306, 170, 30, ID_KICK, g_font);
    // The viewer's phone as this PC's camera: what is live now, the camera's state, its buttons.
    g_media = make(p, L"STATIC", L"", SS_CENTER | SS_ENDELLIPSIS, 0, 12, 346, 416, 20, 0, g_font);
    g_cam_caption = make(p, L"STATIC", L"", SS_CENTER, 0, 24, 370, 392, 52, 0, g_font_small);
    g_cam_button = make(p, L"BUTTON", L"Enable phone camera", btn, 0, 45, 428, 170, 30, ID_CAMERA, g_font);
    g_media_stop = make(p, L"BUTTON", L"Stop phone camera", btn, 0, 225, 428, 170, 30, ID_MEDIA_STOP, g_font);
    ShowWindow(g_cam_button, SW_HIDE);
    ShowWindow(g_media_stop, SW_HIDE);
    make(p, L"STATIC", L"", SS_ETCHEDHORZ, 0, 24, 470, 392, 2, 0, g_font);
    g_auto = make(p, L"BUTTON", L"Update automatically", BS_AUTOCHECKBOX | WS_TABSTOP, 0, 28, 484, 210, 26, ID_AUTO, g_font);
    g_check = make(p, L"BUTTON", L"Check for updates", btn, 0, 245, 482, 170, 30, ID_CHECK, g_font);
    g_upd_status = make(p, L"STATIC", L"", SS_CENTER, 0, 12, 520, 416, 34, 0, g_font_small);
    g_settings = make(p, L"BUTTON", L"Settings…", btn, 0, 45, 558, 170, 30, ID_SETTINGS, g_font);
    g_install = make(p, L"BUTTON", L"Update and restart", btn, 0, 225, 558, 170, 30, ID_INSTALL, g_font);
    ShowWindow(g_install, SW_HIDE);
}

static void rebuild(HWND hwnd) {
    HWND c;
    while ((c = GetWindow(hwnd, GW_CHILD)) != NULL) DestroyWindow(c);
    create_fonts();
    build_controls(hwnd);
    refresh_ui();
}

static void window_size(int dpi, int *w, int *h) {
    RECT r = {0, 0, MulDiv(CLIENT_W, dpi, 96), MulDiv(CLIENT_H, dpi, 96)};
    AdjustWindowRectExForDpi(&r, kWindowStyle, FALSE, 0, (UINT)dpi);
    *w = r.right - r.left;
    *h = r.bottom - r.top;
}

static int clipboard_set(HWND hwnd, const wchar_t *text) {
    size_t bytes = (wcslen(text) + 1) * sizeof(wchar_t);
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!mem) return -1;
    void *dst = GlobalLock(mem);
    if (!dst) {
        GlobalFree(mem);
        return -1;
    }
    memcpy(dst, text, bytes);
    GlobalUnlock(mem);
    if (!OpenClipboard(hwnd)) {
        GlobalFree(mem);
        return -1;
    }
    EmptyClipboard();
    int rc = 0;
    if (!SetClipboardData(CF_UNICODETEXT, mem)) {
        GlobalFree(mem);
        rc = -1;
    }
    CloseClipboard();
    return rc;
}

static void copy_link(HWND hwnd, int remote) {
    wchar_t link[256];
    AcquireSRWLockShared(&g_ui_lock);
    wcscpy(link, remote ? g_ui_remote : g_ui_link);
    ReleaseSRWLockShared(&g_ui_lock);
    if (!link[0] || clipboard_set(hwnd, link) != 0) return;
    SetWindowTextW(remote ? g_copy_remote : g_copy, L"Copied ✓");
    SetTimer(hwnd, TIMER_COPIED, 1500, NULL);
}

static void action(int a) {
    if (g_on_action) g_on_action(g_app_ctx, a);
}

// ---------------------------------------------------------------------------
// Settings: permanent access (with the "Permanent access" window for setting up the phone), start
// at login, keep awake, the relay. Two more top-level windows on the window thread, each with its
// own DPI; their controls are laid out from the top down, so hidden ones leave no gap.

enum { ID_S_PERM = 201, ID_S_SETUP, ID_S_LOGIN, ID_S_AWAKE, ID_S_RELAY, ID_S_RELAY_URL, ID_S_RELAY_USE, ID_S_RELAY_HOW,
       ID_P_COPY, ID_P_SHOW, ID_P_RESET };
#define SUB_W 440
#define TIMER_P_COPIED 2
static const DWORD kSubStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
static const wchar_t kRelayHowTo[] = L"https://github.com/ANODs/RDC/tree/main/relay#readme";

typedef struct {
    HWND hwnd;
    int dpi;
    HFONT font, small, extra;  // extra: the underlined link (Settings), the monospaced key (Permanent access)
} SubWin;
static SubWin g_set, g_perm;
static HWND g_s_perm, g_s_perm_note, g_s_setup, g_s_login, g_s_login_note, g_s_awake, g_s_awake_note, g_s_line;
static HWND g_s_relay_title, g_s_relay, g_s_relay_url, g_s_relay_use, g_s_relay_note, g_s_relay_how;
static HWND g_p_step1, g_p_link, g_p_copy, g_p_step2, g_p_show, g_p_key, g_p_reset;
static RECT g_p_qr1, g_p_qr2;            // where the two QR codes are painted, in the window's pixels
static int g_perm_revealed;              // the authenticator's code is shown: only after the account password
static int g_perm_seen = -1;             // g_perm_serial the window last painted
static wchar_t g_perm_shown_key[96] = L"";
static wchar_t g_relay_msg[256] = L"";   // the result of "Use", shown instead of the usual note
static int g_relay_checking, g_relay_gen;
static volatile LONG g_login_state = -1;  // start at login: -1 — not known yet, 0 — off, 1 — on
static volatile LONG g_login_busy;

static int sx(const SubWin *w, int v) { return MulDiv(v, w->dpi, 96); }
static void perm_show_window(void);

static const wchar_t kPermNote[] =
    L"A link of your own that never changes. Whoever opens it must enter the current 6-digit code from your "
    L"authenticator app (Google Authenticator and the like), so the link alone lets no one in.";
static const wchar_t kLoginNote[] = L"RDC starts hidden when you log in and keeps running when its window is closed.";
static const wchar_t kAwakeNote[] =
    L"A sleeping computer cannot be reached. The display may still turn off; a laptop with its lid closed may sleep anyway.";
static const wchar_t kStep1[] =
    L"1. Open the link on your phone — point its camera at this code — and keep it: add the page to the home screen.";
static const wchar_t kStep2[] =
    L"2. Add this computer to the authenticator app: in the app, scan the second code. Anyone who sees it can make "
    L"the codes, so it is shown only when you ask.";

// --- Keep awake: the window thread lives as long as RDC, and the state belongs to the thread.
static void keep_awake(int on) { SetThreadExecutionState(on ? ES_CONTINUOUS | ES_SYSTEM_REQUIRED : ES_CONTINUOUS); }

// --- Start at login. As administrator: a scheduled task that starts RDC elevated at this user's
// logon, with no UAC prompt. Without the rights: the Run key (RDC then runs without them).
#define RUN_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Run"

static int login_command(wchar_t *out, size_t n) {
    wchar_t exe[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH)) return -1;
    wfmt(out, n, L"\"%ls\" --login", exe);
    return 0;
}

static int run_value_get(wchar_t *buf, DWORD bytes) {
    return RegGetValueW(HKEY_CURRENT_USER, RUN_KEY, L"RDC", RRF_RT_REG_SZ, NULL, buf, &bytes) == ERROR_SUCCESS ? 0 : -1;
}

static int run_value_set(int on) {
    if (!on) {
        LSTATUS r = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, L"RDC");
        return r == ERROR_SUCCESS || r == ERROR_FILE_NOT_FOUND ? 0 : -1;
    }
    wchar_t cmd[MAX_PATH + 16];
    if (login_command(cmd, MAX_PATH + 16) != 0) return -1;
    HKEY k;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) != ERROR_SUCCESS) return -1;
    LSTATUS r = RegSetValueExW(k, L"RDC", 0, REG_SZ, (const BYTE *)cmd, (DWORD)((wcslen(cmd) + 1) * sizeof(wchar_t)));
    RegCloseKey(k);
    return r == ERROR_SUCCESS ? 0 : -1;
}

static int schtasks(const wchar_t *args) {
    wchar_t sys[MAX_PATH], cmd[2048];
    if (!GetSystemDirectoryW(sys, MAX_PATH)) return -1;
    wfmt(cmd, 2048, L"\"%ls\\schtasks.exe\" %ls", sys, args);
    return run_hidden(cmd);
}

static int task_exists(void) { return schtasks(L"/query /tn RDC") == 0; }

static void xml_escape(const wchar_t *in, wchar_t *out, size_t n) {
    size_t o = 0;
    for (; *in && o + 7 < n; in++) {
        const wchar_t *rep = *in == L'&' ? L"&amp;" : *in == L'<' ? L"&lt;" : *in == L'>' ? L"&gt;" : NULL;
        if (rep) {
            while (*rep) out[o++] = *rep++;
        } else {
            out[o++] = *in;
        }
    }
    out[o] = 0;
}

// The task in XML: schtasks' own switches would stop RDC after 72 hours and skip it on battery.
static int task_create(void) {
    wchar_t exe[MAX_PATH], exe_xml[MAX_PATH * 5], path[MAX_PATH], args[MAX_PATH + 64];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH)) return -1;
    xml_escape(exe, exe_xml, MAX_PATH * 5);
    // The logon of this user only, by SID: names can hold anything.
    wchar_t *sid = NULL;
    HANDLE token = NULL;
    union {
        TOKEN_USER user;
        uint8_t bytes[256];
    } tu;
    DWORD got = 0;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        if (GetTokenInformation(token, TokenUser, &tu, sizeof tu, &got)) ConvertSidToStringSidW(tu.user.User.Sid, &sid);
        CloseHandle(token);
    }
    if (!sid) return -1;
    static wchar_t xml[8192];  // the window thread's helper threads take turns (g_login_busy)
    wfmt(xml, 8192,
         L"\xFEFF<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\n"
         L"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\r\n"
         L"<RegistrationInfo><Description>Starts RDC when you log in (RDC Settings: Start RDC at login).</Description></RegistrationInfo>\r\n"
         L"<Triggers><LogonTrigger><Enabled>true</Enabled><UserId>%ls</UserId></LogonTrigger></Triggers>\r\n"
         L"<Principals><Principal id=\"Author\"><UserId>%ls</UserId><LogonType>InteractiveToken</LogonType>"
         L"<RunLevel>HighestAvailable</RunLevel></Principal></Principals>\r\n"
         L"<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"
         L"<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>"
         L"<AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>false</StartWhenAvailable>"
         L"<IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>"
         L"<AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden>"
         L"<ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>5</Priority></Settings>\r\n"
         L"<Actions Context=\"Author\"><Exec><Command>%ls</Command><Arguments>--login</Arguments></Exec></Actions>\r\n"
         L"</Task>\r\n",
         sid, sid, exe_xml);
    LocalFree(sid);
    temp_path(path, L"rdc-login-task.xml");
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, NULL);
    if (f == INVALID_HANDLE_VALUE) return -1;
    DWORD bytes = (DWORD)(wcslen(xml) * sizeof(wchar_t)), put = 0;
    BOOL ok = WriteFile(f, xml, bytes, &put, NULL) && put == bytes;
    CloseHandle(f);
    int rc = -1;
    if (ok) {
        wfmt(args, MAX_PATH + 64, L"/create /tn RDC /xml \"%ls\" /f", path);
        rc = schtasks(args);
    }
    DeleteFileW(path);
    return rc;
}

static void autostart_set(int on) {
    if (!on) {
        if (run_value_set(0) != 0) rlog("start at login: cannot remove the Run key value");
        if (task_exists()) {
            int rc = schtasks(L"/delete /tn RDC /f");
            if (rc != 0) rlog("start at login: cannot remove the scheduled task \"RDC\" (schtasks returned %d)", rc);
        }
        rlog("start at login: off");
        return;
    }
    if (g_elevated) {
        int rc = task_create();
        if (rc == 0) {
            run_value_set(0);
            rlog("start at login: on (the scheduled task \"RDC\", as administrator)");
            return;
        }
        rlog("start at login: the scheduled task was not created (schtasks returned %d), using the Run key", rc);
    }
    if (run_value_set(1) == 0)
        rlog("start at login: on (the Run key, without administrator rights)");
    else
        rlog("start at login: cannot write the Run key value");
}

// On a helper thread: schtasks takes a moment. arg: 1 — turn on, 0 — off, -1 — only look.
static DWORD WINAPI login_main(LPVOID arg) {
    int want = (int)(INT_PTR)arg;
    if (want >= 0) autostart_set(want);
    wchar_t have[MAX_PATH + 16], cmd[MAX_PATH + 16];
    int run = run_value_get(have, sizeof have) == 0;
    // RDC was moved since the value was written: point it at where RDC is now.
    if (want < 0 && run && login_command(cmd, MAX_PATH + 16) == 0 && _wcsicmp(have, cmd) != 0) run_value_set(1);
    InterlockedExchange(&g_login_state, run || task_exists() ? 1 : 0);
    InterlockedExchange(&g_login_busy, 0);
    post_refresh();
    return 0;
}

static void login_start(int want) {
    if (InterlockedCompareExchange(&g_login_busy, 1, 0) != 0) return;
    HANDLE t = CreateThread(NULL, 0, login_main, (LPVOID)(INT_PTR)want, 0, NULL);
    if (t)
        CloseHandle(t);
    else
        InterlockedExchange(&g_login_busy, 0);
}

// --- The relay check, on a helper thread: the relay answers {"rdc_relay":1} at its root.
typedef struct {
    int gen, result;  // result: 1 — an RDC relay, 0 — something else answers, -1 — no answer
    char url[1024];
} RelayCheck;

static DWORD WINAPI relay_check_main(LPVOID arg) {
    RelayCheck *rc = arg;
    char url[1100];
    snprintf(url, sizeof url, "%s/", rc->url);
    size_t len = 0;
    int status = -1;
    uint8_t *body = rdc_http_get(url, 4096, &len, &status);
    rc->result = status < 0 ? -1 : 0;
    static const char mark[] = "\"rdc_relay\"";
    if (body && status == 200)
        for (size_t i = 0; i + sizeof mark - 1 <= len; i++)
            if (memcmp(body + i, mark, sizeof mark - 1) == 0) rc->result = 1;
    free(body);
    HWND h = g_hwnd;
    if (!h || !PostMessageW(h, WM_RDC_RELAY_DONE, 0, (LPARAM)rc)) free(rc);
    return 0;
}

// --- Window helpers.
static HWND make_sub(SubWin *w, const wchar_t *cls, const wchar_t *text, DWORD style, DWORD ex, int id, HFONT font) {
    HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 0, 0, w->hwnd, (HMENU)(INT_PTR)id,
                             GetModuleHandleW(NULL), NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)font, FALSE);
    return c;
}

static void place(const SubWin *w, HWND c, int x, int y, int cw, int ch) {
    RECT r;
    GetWindowRect(c, &r);
    MapWindowPoints(HWND_DESKTOP, w->hwnd, (POINT *)&r, 2);
    int nx = sx(w, x), ny = sx(w, y), nw = sx(w, cw), nh = sx(w, ch);
    // A drop-down list reports the height of its box, not the height it was given with its list.
    int same_h = r.bottom - r.top == nh || (c == g_s_relay && r.bottom - r.top > 0);
    if (r.left != nx || r.top != ny || r.right - r.left != nw || !same_h) MoveWindow(c, nx, ny, nw, nh, TRUE);
}

// The control's own visibility: IsWindowVisible is false for all of them while their window is hidden.
static void show(HWND c, int visible) {
    int now = (GetWindowLongW(c, GWL_STYLE) & WS_VISIBLE) != 0;
    if (now != !!visible) ShowWindow(c, visible ? SW_SHOW : SW_HIDE);
}

// Height (in 96-dpi units) of wrapped text in this width; *text_w — the width of its longest line.
static int text_height(const SubWin *w, HFONT f, const wchar_t *text, int width, int *text_w) {
    HDC dc = GetDC(w->hwnd);
    HGDIOBJ old = SelectObject(dc, f);
    RECT r = {0, 0, sx(w, width), 0};
    DrawTextW(dc, text, -1, &r, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
    SelectObject(dc, old);
    ReleaseDC(w->hwnd, dc);
    if (text_w) *text_w = MulDiv(r.right, 96, w->dpi) + 2;
    return MulDiv(r.bottom, 96, w->dpi) + 2;
}

static void sub_fonts(SubWin *w, int mono) {
    if (w->font) DeleteObject(w->font);
    if (w->small) DeleteObject(w->small);
    if (w->extra) DeleteObject(w->extra);
    w->font = CreateFontW(-sx(w, 15), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    w->small = CreateFontW(-sx(w, 13), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    w->extra = mono ? CreateFontW(-sx(w, 13), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY,
                                  FIXED_PITCH | FF_MODERN, L"Consolas")
                    : CreateFontW(-sx(w, 13), 0, 0, 0, FW_NORMAL, 0, TRUE, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
}

// The window is as tall as what it shows, with its top edge in place.
static void sub_client_height(const SubWin *w, int h) {
    RECT want = {0, 0, sx(w, SUB_W), sx(w, h)}, have;
    GetClientRect(w->hwnd, &have);
    if (have.right == want.right && have.bottom == want.bottom) return;
    AdjustWindowRectExForDpi(&want, kSubStyle, FALSE, 0, (UINT)w->dpi);
    SetWindowPos(w->hwnd, NULL, 0, 0, want.right - want.left, want.bottom - want.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

// Centered over another window (or its monitor when that one is hidden), inside the work area.
static void center_over(HWND w, HWND over) {
    MONITORINFO mi = {sizeof mi};
    HMONITOR mon = MonitorFromWindow(over ? over : w, MONITOR_DEFAULTTOPRIMARY);
    if (!GetMonitorInfoW(mon, &mi)) return;
    RECT o = mi.rcWork, r;
    if (over && IsWindowVisible(over) && !IsIconic(over)) GetWindowRect(over, &o);
    GetWindowRect(w, &r);
    int ww = r.right - r.left, wh = r.bottom - r.top;
    int x = o.left + (o.right - o.left - ww) / 2, y = o.top + (o.bottom - o.top - wh) / 2;
    if (x + ww > mi.rcWork.right) x = mi.rcWork.right - ww;
    if (y + wh > mi.rcWork.bottom) y = mi.rcWork.bottom - wh;
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
    SetWindowPos(w, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

static LRESULT sub_ctlcolor(HDC dc, HWND c) {
    int gray = c == g_s_perm_note || c == g_s_login_note || c == g_s_awake_note || c == g_s_relay_note || c == g_p_step1 ||
               c == g_p_step2;
    int link = c == g_s_relay_how || c == g_p_link;
    SetTextColor(dc, GetSysColor(link ? COLOR_HOTLIGHT : gray ? COLOR_GRAYTEXT : COLOR_WINDOWTEXT));
    SetBkColor(dc, GetSysColor(COLOR_WINDOW));
    return (LRESULT)GetSysColorBrush(COLOR_WINDOW);
}

static int checked(HWND c) { return SendMessageW(c, BM_GETCHECK, 0, 0) == BST_CHECKED; }

// --- The Settings window.
static void settings_build(void) {
    SubWin *w = &g_set;
    const DWORD btn = BS_PUSHBUTTON | WS_TABSTOP, box = BS_AUTOCHECKBOX | WS_TABSTOP, note = SS_LEFT | SS_NOPREFIX;
    g_s_perm = make_sub(w, L"BUTTON", L"Permanent access", box, 0, ID_S_PERM, w->font);
    g_s_perm_note = make_sub(w, L"STATIC", kPermNote, note, 0, 0, w->small);
    g_s_setup = make_sub(w, L"BUTTON", L"Set up the phone…", btn, 0, ID_S_SETUP, w->font);
    g_s_login = make_sub(w, L"BUTTON", L"Start RDC at login", box, 0, ID_S_LOGIN, w->font);
    g_s_login_note = make_sub(w, L"STATIC", kLoginNote, note, 0, 0, w->small);
    g_s_awake = make_sub(w, L"BUTTON", L"Keep this computer awake", box, 0, ID_S_AWAKE, w->font);
    g_s_awake_note = make_sub(w, L"STATIC", kAwakeNote, note, 0, 0, w->small);
    g_s_line = make_sub(w, L"STATIC", L"", SS_ETCHEDHORZ, 0, 0, w->font);
    g_s_relay_title = make_sub(w, L"STATIC", L"Relay — when a phone cannot connect directly", SS_LEFT | SS_NOPREFIX, 0, 0, w->font);
    g_s_relay = make_sub(w, L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, 0, ID_S_RELAY, w->font);
    SendMessageW(g_s_relay, CB_ADDSTRING, 0, (LPARAM)L"RDC's relay");
    SendMessageW(g_s_relay, CB_ADDSTRING, 0, (LPARAM)L"My own relay");
    SendMessageW(g_s_relay, CB_ADDSTRING, 0, (LPARAM)L"Off");
    g_s_relay_url = make_sub(w, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, WS_EX_CLIENTEDGE, ID_S_RELAY_URL, w->font);
    SendMessageW(g_s_relay_url, EM_SETCUEBANNER, TRUE, (LPARAM)L"https://rdc-relay.<your-name>.workers.dev");
    SendMessageW(g_s_relay_url, EM_SETLIMITTEXT, 250, 0);
    g_s_relay_use = make_sub(w, L"BUTTON", L"Use", btn, 0, ID_S_RELAY_USE, w->font);
    g_s_relay_note = make_sub(w, L"STATIC", L"", note, 0, 0, w->small);
    g_s_relay_how = make_sub(w, L"STATIC", L"How to set up your own relay…", SS_LEFT | SS_NOPREFIX | SS_NOTIFY, 0, ID_S_RELAY_HOW, w->extra);
}

static void settings_layout(int perm_on, int own_shown) {
    SubWin *w = &g_set;
    int y = 18, h, tw;
    place(w, g_s_perm, 24, y, 392, 24);
    y += 26;
    h = text_height(w, w->small, kPermNote, 372, NULL);
    place(w, g_s_perm_note, 44, y, 372, h);
    y += h + 10;
    show(g_s_setup, perm_on);
    if (perm_on) {
        place(w, g_s_setup, 44, y, 200, 30);
        y += 30 + 10;
    }
    y += 8;
    place(w, g_s_login, 24, y, 392, 24);
    y += 26;
    h = text_height(w, w->small, kLoginNote, 372, NULL);
    place(w, g_s_login_note, 44, y, 372, h);
    y += h + 18;
    place(w, g_s_awake, 24, y, 392, 24);
    y += 26;
    h = text_height(w, w->small, kAwakeNote, 372, NULL);
    place(w, g_s_awake_note, 44, y, 372, h);
    y += h + 18;
    place(w, g_s_line, 24, y, 392, 2);
    y += 16;
    place(w, g_s_relay_title, 24, y, 392, 22);
    y += 26;
    place(w, g_s_relay, 24, y, 220, 200);  // the height of a drop-down list includes its list
    y += 36;
    show(g_s_relay_url, own_shown);
    show(g_s_relay_use, own_shown);
    if (own_shown) {
        place(w, g_s_relay_url, 24, y, 300, 28);
        place(w, g_s_relay_use, 332, y - 1, 84, 30);
        y += 38;
    }
    wchar_t text[512];
    GetWindowTextW(g_s_relay_note, text, 512);
    h = text_height(w, w->small, text, 392, NULL);
    place(w, g_s_relay_note, 24, y, 392, h);
    y += h + 10;
    text_height(w, w->extra, L"How to set up your own relay…", 392, &tw);
    place(w, g_s_relay_how, 24, y, tw, 20);
    y += 20 + 20;
    sub_client_height(w, y);
}

// The "relay" pref: not set — RDC's relay, "off" — none, otherwise the person's own.
static int relay_refresh(void) {
    char buf[256];
    wchar_t v[256];
    int n = rdc_pref_string("relay", buf, sizeof buf);
    to_wide(n >= 0 ? buf : "", v, 256);
    int off = wcscmp(v, L"off") == 0, own = v[0] && !off;
    // "My own relay" picked with no address yet: the field takes over until it holds one.
    if ((int)SendMessageW(g_s_relay, CB_GETCURSEL, 0, 0) != 1 || own) SendMessageW(g_s_relay, CB_SETCURSEL, off ? 2 : own ? 1 : 0, 0);
    int own_shown = (int)SendMessageW(g_s_relay, CB_GETCURSEL, 0, 0) == 1;
    if (own && GetFocus() != g_s_relay_url) set_text(g_s_relay_url, v);
    EnableWindow(g_s_relay_use, !g_relay_checking);
    set_text(g_s_relay_note, g_relay_msg[0] ? g_relay_msg
                             : off          ? L"Only direct connections. A phone on mobile data may not reach this PC."
                             : own_shown    ? L"Your own Cloudflare Worker: it sees only sealed bytes. Press Enter or Use to use the address."
                                            : L"If a direct connection fails, the phone and this PC meet on RDC's Cloudflare Worker. "
                                              L"It passes sealed bytes and cannot see the screen.");
    return own_shown;
}

static void settings_refresh(void) {
    if (!g_set.hwnd) return;
    AcquireSRWLockShared(&g_ui_lock);
    int on = g_perm_on;
    ReleaseSRWLockShared(&g_ui_lock);
    SendMessageW(g_s_perm, BM_SETCHECK, on ? BST_CHECKED : BST_UNCHECKED, 0);
    LONG login = g_login_state;
    SendMessageW(g_s_login, BM_SETCHECK, login == 1 ? BST_CHECKED : BST_UNCHECKED, 0);
    EnableWindow(g_s_login, login >= 0 && !g_login_busy);
    SendMessageW(g_s_awake, BM_SETCHECK, rdc_pref_bool("keep_awake", 0) ? BST_CHECKED : BST_UNCHECKED, 0);
    int own_shown = relay_refresh();
    settings_layout(on, own_shown);
}

static void relay_chosen(void) {
    int i = (int)SendMessageW(g_s_relay, CB_GETCURSEL, 0, 0);
    g_relay_msg[0] = 0;
    g_relay_gen++;  // a check still running no longer decides anything
    g_relay_checking = 0;
    if (i == 1) {
        settings_refresh();
        SetFocus(g_s_relay_url);
        return;
    }
    rdc_set_pref_string("relay", i == 2 ? "off" : "");
    action(RDC_ACTION_RELAY_CHANGED);
    settings_refresh();
}

static void relay_use(void) {
    if (g_relay_checking) return;
    wchar_t in[300];
    GetWindowTextW(g_s_relay_url, in, 300);
    wchar_t *v = in;
    while (*v == L' ' || *v == L'\t' || *v == L'\r' || *v == L'\n') v++;
    size_t n = wcslen(v);
    while (n > 0 && (v[n - 1] == L' ' || v[n - 1] == L'\t' || v[n - 1] == L'\r' || v[n - 1] == L'\n' || v[n - 1] == L'/')) v[--n] = 0;
    if (n < 12 || wcsncmp(v, L"https://", 8) != 0 || wcspbrk(v + 8, L"/?#@ \t") != NULL) {
        wcscpy(g_relay_msg, L"That does not look like a relay address: it starts with https:// and has no path.");
        settings_refresh();
        return;
    }
    RelayCheck *rc = calloc(1, sizeof *rc);
    if (!rc || to_utf8(v, rc->url, sizeof rc->url) != 0) {
        free(rc);
        return;
    }
    set_text(g_s_relay_url, v);
    rc->gen = ++g_relay_gen;
    HANDLE t = CreateThread(NULL, 0, relay_check_main, rc, 0, NULL);
    if (!t) {
        free(rc);
        wcscpy(g_relay_msg, L"Cannot check it right now. Try again.");
    } else {
        CloseHandle(t);
        g_relay_checking = 1;
        wcscpy(g_relay_msg, L"Checking…");
    }
    settings_refresh();
}

static void relay_done(RelayCheck *rc) {
    if (rc->gen == g_relay_gen) {
        g_relay_checking = 0;
        if (rc->result == 1) {
            rdc_set_pref_string("relay", rc->url);
            action(RDC_ACTION_RELAY_CHANGED);
            wcscpy(g_relay_msg, L"Your relay answers. RDC uses it from now on.");
        } else if (rc->result == 0) {
            wcscpy(g_relay_msg, L"Something answers there, but it is not an RDC relay.");
        } else {
            wcscpy(g_relay_msg, L"Cannot reach it: there is no answer at that address.");
        }
        settings_refresh();
    }
    free(rc);
}

static void sub_clear(SubWin *w) {
    HWND c;
    while ((c = GetWindow(w->hwnd, GW_CHILD)) != NULL) DestroyWindow(c);
}

static LRESULT CALLBACK settings_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE:
        g_set.hwnd = hwnd;
        g_set.dpi = (int)GetDpiForWindow(hwnd);
        sub_fonts(&g_set, 0);
        settings_build();
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_S_PERM:
            action(checked(g_s_perm) ? RDC_ACTION_PERMANENT_ON : RDC_ACTION_PERMANENT_OFF);
            settings_refresh();  // the host has answered through rdc_app_set_permanent by now, or will
            break;
        case ID_S_SETUP:
            perm_show_window();
            break;
        case ID_S_LOGIN:
            login_start(checked(g_s_login));
            settings_refresh();
            break;
        case ID_S_AWAKE: {
            int on = checked(g_s_awake);
            rdc_set_pref_bool("keep_awake", on);
            keep_awake(on);
            rlog("keep awake: %s", on ? "on" : "off");
            break;
        }
        case ID_S_RELAY:
            if (HIWORD(wp) == CBN_SELCHANGE) relay_chosen();
            break;
        case ID_S_RELAY_URL:
            // Typing a new address clears the last result.
            if (HIWORD(wp) == EN_CHANGE && GetFocus() == (HWND)lp && g_relay_msg[0] && !g_relay_checking) {
                g_relay_msg[0] = 0;
                settings_refresh();
            }
            break;
        case IDOK:  // Enter (IsDialogMessage) in the address field
            if (GetFocus() == g_s_relay_url) relay_use();
            break;
        case ID_S_RELAY_USE:
            relay_use();
            break;
        case ID_S_RELAY_HOW:
            if (HIWORD(wp) == STN_CLICKED) ShellExecuteW(hwnd, L"open", kRelayHowTo, NULL, NULL, SW_SHOWNORMAL);
            break;
        }
        return 0;
    case WM_SETCURSOR:
        if ((HWND)wp == g_s_relay_how) {
            SetCursor(LoadCursorW(NULL, (LPCWSTR)IDC_HAND));
            return TRUE;
        }
        break;
    case WM_CTLCOLORSTATIC:
        return sub_ctlcolor((HDC)wp, (HWND)lp);
    case WM_DPICHANGED: {
        // The address being typed and the picked item survive the new controls.
        wchar_t url[300];
        GetWindowTextW(g_s_relay_url, url, 300);
        LRESULT pick = SendMessageW(g_s_relay, CB_GETCURSEL, 0, 0);
        g_set.dpi = HIWORD(wp);
        sub_clear(&g_set);
        sub_fonts(&g_set, 0);
        settings_build();
        SetWindowTextW(g_s_relay_url, url);
        SendMessageW(g_s_relay, CB_SETCURSEL, (WPARAM)pick, 0);
        const RECT *r = (const RECT *)lp;
        SetWindowPos(hwnd, NULL, r->left, r->top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        settings_refresh();
        return 0;
    }
    case WM_CLOSE:
        ShowWindow(hwnd, SW_HIDE);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void settings_show(void) {
    if (!g_set.hwnd) {
        RECT r = {0, 0, 0, 0};
        if (g_hwnd) GetWindowRect(g_hwnd, &r);
        // Created over the main window, so it starts on that monitor with its DPI.
        if (!CreateWindowExW(0, L"RDCSettings", L"RDC Settings", kSubStyle, r.left, r.top, 100, 100, g_hwnd, NULL,
                             GetModuleHandleW(NULL), NULL)) {
            rlog("settings window not created (%lu)", (unsigned long)GetLastError());
            return;
        }
        settings_refresh();
        center_over(g_set.hwnd, g_hwnd);
    }
    login_start(-1);  // what is there now: the task or the Run key may have changed outside RDC
    settings_refresh();
    ShowWindow(g_set.hwnd, SW_SHOW);
    SetForegroundWindow(g_set.hwnd);
}

// --- The "Permanent access" window: the link's QR code for the phone's camera, and the
// authenticator's QR code once the person at the PC has proved it is them.

static void paint_qr(HDC dc, const RECT *r, const uint8_t *m, int n) {
    if (n <= 0) return;
    int total = n + 8, side = r->right - r->left;  // 4 light modules of quiet zone on each side
    FillRect(dc, r, (HBRUSH)GetStockObject(WHITE_BRUSH));
    HBRUSH black = (HBRUSH)GetStockObject(BLACK_BRUSH);
    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n;) {
            if (!m[y * n + x]) {
                x++;
                continue;
            }
            int x1 = x;
            while (x1 < n && m[y * n + x1]) x1++;  // one rectangle for a run of dark modules
            RECT c = {r->left + MulDiv(x + 4, side, total), r->top + MulDiv(y + 4, side, total), r->left + MulDiv(x1 + 4, side, total),
                      r->top + MulDiv(y + 5, side, total)};
            FillRect(dc, &c, black);
            x = x1;
        }
    }
}

static void perm_build(void) {
    SubWin *w = &g_perm;
    const DWORD btn = BS_PUSHBUTTON | WS_TABSTOP, note = SS_LEFT | SS_NOPREFIX;
    g_p_step1 = make_sub(w, L"STATIC", kStep1, note, 0, 0, w->small);
    g_p_link = make_sub(w, L"EDIT", L"", ES_CENTER | ES_READONLY | ES_AUTOHSCROLL, 0, 0, w->small);
    g_p_copy = make_sub(w, L"BUTTON", L"Copy link", btn, 0, ID_P_COPY, w->font);
    g_p_step2 = make_sub(w, L"STATIC", kStep2, note, 0, 0, w->small);
    g_p_show = make_sub(w, L"BUTTON", L"Show the code for the authenticator app", btn, 0, ID_P_SHOW, w->font);
    g_p_key = make_sub(w, L"EDIT", L"", ES_CENTER | ES_READONLY | ES_AUTOHSCROLL, 0, 0, w->extra);
    g_p_reset = make_sub(w, L"BUTTON", L"New link and key…", btn, 0, ID_P_RESET, w->font);
}

static void perm_layout(void) {
    SubWin *w = &g_perm;
    int y = 20, h;
    RECT q1 = g_p_qr1, q2 = g_p_qr2;
    h = text_height(w, w->small, kStep1, 392, NULL);
    place(w, g_p_step1, 24, y, 392, h);
    y += h + 12;
    g_p_qr1 = (RECT){sx(w, 135), sx(w, y), sx(w, 135) + sx(w, 170), sx(w, y) + sx(w, 170)};
    y += 170 + 10;
    place(w, g_p_link, 12, y, 416, 22);
    y += 22 + 8;
    place(w, g_p_copy, 135, y, 170, 30);
    y += 30 + 22;
    h = text_height(w, w->small, kStep2, 392, NULL);
    place(w, g_p_step2, 24, y, 392, h);
    y += h + 12;
    show(g_p_show, !g_perm_revealed);
    show(g_p_key, g_perm_revealed);
    if (!g_perm_revealed) {
        place(w, g_p_show, 60, y, 320, 30);
        y += 30 + 22;
        g_p_qr2 = (RECT){0, 0, 0, 0};
    } else {
        g_p_qr2 = (RECT){sx(w, 125), sx(w, y), sx(w, 125) + sx(w, 190), sx(w, y) + sx(w, 190)};
        y += 190 + 10;
        place(w, g_p_key, 12, y, 416, 22);
        y += 22 + 22;
    }
    place(w, g_p_reset, 120, y, 200, 30);
    y += 30 + 20;
    sub_client_height(w, y);
    if (!EqualRect(&q1, &g_p_qr1) || !EqualRect(&q2, &g_p_qr2)) InvalidateRect(w->hwnd, NULL, TRUE);
}

static void perm_refresh(void) {
    if (!g_perm.hwnd) return;
    wchar_t link[512], key[96], text[160];
    AcquireSRWLockShared(&g_ui_lock);
    int on = g_perm_on, serial = g_perm_serial;
    wcscpy(link, g_perm_link);
    wcscpy(key, g_perm_key);
    ReleaseSRWLockShared(&g_ui_lock);
    if (wcscmp(key, g_perm_shown_key) != 0) {  // a new key is hidden again
        g_perm_revealed = 0;
        wcscpy(g_perm_shown_key, key);
    }
    if (!on) {
        g_perm_revealed = 0;
        if (IsWindowVisible(g_perm.hwnd)) ShowWindow(g_perm.hwnd, SW_HIDE);
    }
    set_text(g_p_link, link);
    wfmt(text, 160, L"Or type the key: %ls", key);
    set_text(g_p_key, g_perm_revealed ? text : L"");
    perm_layout();
    if (serial != g_perm_seen) {
        g_perm_seen = serial;
        InvalidateRect(g_perm.hwnd, NULL, TRUE);
    }
}

// Whoever is merely connected must not see the authenticator's key: the Windows account password
// of the person at this PC first. 1 — it is them.
static int same_user(HANDLE logon) {
    union {
        TOKEN_USER user;
        uint8_t bytes[256];
    } a, b;
    DWORD n = 0;
    HANDLE own = NULL;
    int same = 0;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &own)) {
        if (GetTokenInformation(own, TokenUser, &a, sizeof a, &n) && GetTokenInformation(logon, TokenUser, &b, sizeof b, &n))
            same = EqualSid(a.user.User.Sid, b.user.User.Sid) != 0;
        CloseHandle(own);
    }
    return same;
}

#ifndef CRED_PACK_PROTECTED_CREDENTIALS
#define CRED_PACK_PROTECTED_CREDENTIALS 0x1
#endif

static int verify_user(HWND owner) {
    CREDUI_INFOW ui;
    memset(&ui, 0, sizeof ui);
    ui.cbSize = sizeof ui;
    ui.hwndParent = owner;
    ui.pszCaptionText = L"RDC";
    ui.pszMessageText = L"Enter the password of this Windows account to show the code for the authenticator app.";
    DWORD auth_error = 0;
    for (int attempt = 0; attempt < 3; attempt++) {
        ULONG package = 0, out_len = 0;
        void *out = NULL;
        BOOL save = FALSE;
        DWORD rc = CredUIPromptForWindowsCredentialsW(&ui, auth_error, &package, NULL, 0, &out, &out_len, &save,
                                                      CREDUIWIN_ENUMERATE_CURRENT_USER);
        if (rc != ERROR_SUCCESS) {
            if (rc != ERROR_CANCELLED) rlog("authenticator code: the password prompt failed (%lu)", (unsigned long)rc);
            return 0;
        }
        static wchar_t user[CREDUI_MAX_USERNAME_LENGTH + 1], domain[CREDUI_MAX_DOMAIN_TARGET_LENGTH + 1],
            pass[CREDUI_MAX_PASSWORD_LENGTH + 1], u[CREDUI_MAX_USERNAME_LENGTH + 1], d[CREDUI_MAX_DOMAIN_TARGET_LENGTH + 1];
        BOOL ok = FALSE;
        for (int flags = CRED_PACK_PROTECTED_CREDENTIALS; flags >= 0 && !ok; flags--) {
            DWORD nu = CREDUI_MAX_USERNAME_LENGTH + 1, nd = CREDUI_MAX_DOMAIN_TARGET_LENGTH + 1, np = CREDUI_MAX_PASSWORD_LENGTH + 1;
            ok = CredUnPackAuthenticationBufferW((DWORD)flags, out, out_len, user, &nu, domain, &nd, pass, &np);
        }
        SecureZeroMemory(out, out_len);
        CoTaskMemFree(out);
        if (!ok) {
            rlog("authenticator code: Windows gave RDC no password to check (%lu); sign in with the account password",
                 (unsigned long)GetLastError());
            SecureZeroMemory(pass, sizeof pass);
            MessageBoxW(owner, L"RDC can check only the account password. Try again and enter the password rather than a PIN.",
                        L"RDC", MB_OK | MB_ICONINFORMATION);
            continue;
        }
        // "DOMAIN\user" (or "MicrosoftAccount\name@example.com") when the domain came back empty.
        wcscpy(u, user);
        wcscpy(d, domain);
        if (!d[0] && CredUIParseUserNameW(user, u, CREDUI_MAX_USERNAME_LENGTH + 1, d, CREDUI_MAX_DOMAIN_TARGET_LENGTH + 1) != NO_ERROR) {
            wcscpy(u, user);
            d[0] = 0;
        }
        HANDLE token = NULL;
        BOOL good = LogonUserW(u, d[0] ? d : NULL, pass, LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, &token);
        DWORD err = good ? 0 : GetLastError();
        int blank = pass[0] == 0;
        SecureZeroMemory(pass, sizeof pass);
        if (good) {
            int same = same_user(token);
            CloseHandle(token);
            if (same) return 1;
            err = ERROR_LOGON_FAILURE;
        } else if (err == ERROR_ACCOUNT_RESTRICTION && blank) {
            // The right (empty) password of an account that has none: Windows lets it log on only at the console.
            wchar_t me[CREDUI_MAX_USERNAME_LENGTH + 1];
            DWORD n = CREDUI_MAX_USERNAME_LENGTH + 1;
            if (GetUserNameW(me, &n) && _wcsicmp(me, u) == 0) return 1;
        }
        rlog("authenticator code: the password was not accepted (%lu)", (unsigned long)err);
        auth_error = ERROR_LOGON_FAILURE;
    }
    return 0;
}

static void perm_reveal(void) {
    if (verify_user(g_perm.hwnd)) {
        g_perm_revealed = 1;
        rlog("authenticator code: shown on this PC");
    }
    perm_refresh();
}

static void perm_reset(void) {
    if (MessageBoxW(g_perm.hwnd,
                    L"Make a new link and key?\n\nThe old link and the entry in the authenticator app stop working. You will set both up again.",
                    L"RDC", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) != IDYES)
        return;
    g_perm_revealed = 0;
    action(RDC_ACTION_PERMANENT_RESET);
    perm_refresh();
}

static LRESULT CALLBACK perm_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE:
        g_perm.hwnd = hwnd;
        g_perm.dpi = (int)GetDpiForWindow(hwnd);
        sub_fonts(&g_perm, 1);
        perm_build();
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        AcquireSRWLockShared(&g_ui_lock);
        paint_qr(dc, &g_p_qr1, g_perm_link_qr, g_perm_link_qr_size);
        if (g_perm_revealed) paint_qr(dc, &g_p_qr2, g_perm_auth_qr, g_perm_auth_qr_size);
        ReleaseSRWLockShared(&g_ui_lock);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_P_COPY: {
            wchar_t link[512];
            AcquireSRWLockShared(&g_ui_lock);
            wcscpy(link, g_perm_link);
            ReleaseSRWLockShared(&g_ui_lock);
            if (link[0] && clipboard_set(hwnd, link) == 0) {
                SetWindowTextW(g_p_copy, L"Copied ✓");
                SetTimer(hwnd, TIMER_P_COPIED, 1500, NULL);
            }
            break;
        }
        case ID_P_SHOW:
            perm_reveal();
            break;
        case ID_P_RESET:
            perm_reset();
            break;
        }
        return 0;
    case WM_TIMER:
        if (wp == TIMER_P_COPIED) {
            KillTimer(hwnd, TIMER_P_COPIED);
            SetWindowTextW(g_p_copy, L"Copy link");
        }
        return 0;
    case WM_CTLCOLORSTATIC:
        return sub_ctlcolor((HDC)wp, (HWND)lp);
    case WM_DPICHANGED: {
        g_perm.dpi = HIWORD(wp);
        sub_clear(&g_perm);
        sub_fonts(&g_perm, 1);
        perm_build();
        const RECT *r = (const RECT *)lp;
        SetWindowPos(hwnd, NULL, r->left, r->top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        g_perm_seen = -1;
        perm_refresh();
        return 0;
    }
    case WM_CLOSE:
        ShowWindow(hwnd, SW_HIDE);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void perm_show_window(void) {
    AcquireSRWLockShared(&g_ui_lock);
    int on = g_perm_on;
    ReleaseSRWLockShared(&g_ui_lock);
    if (!on) return;
    if (!g_perm.hwnd) {
        RECT r = {0, 0, 0, 0};
        if (g_set.hwnd) GetWindowRect(g_set.hwnd, &r);
        if (!CreateWindowExW(0, L"RDCPermanent", L"Permanent access", kSubStyle, r.left, r.top, 100, 100, g_set.hwnd, NULL,
                             GetModuleHandleW(NULL), NULL)) {
            rlog("permanent access window not created (%lu)", (unsigned long)GetLastError());
            return;
        }
    }
    g_perm_revealed = 0;  // every visit asks again before the key is shown
    perm_refresh();
    center_over(g_perm.hwnd, g_set.hwnd);
    ShowWindow(g_perm.hwnd, SW_SHOW);
    SetForegroundWindow(g_perm.hwnd);
}

void rdc_app_set_permanent(int on, const char *link, const uint8_t *link_qr, int link_qr_size,
                           const uint8_t *auth_qr, int auth_qr_size, const char *secret_text) {
    if (!link_qr || link_qr_size < 0 || link_qr_size > QR_MAX) link_qr_size = 0;
    if (!auth_qr || auth_qr_size < 0 || auth_qr_size > QR_MAX) auth_qr_size = 0;
    AcquireSRWLockExclusive(&g_ui_lock);
    g_perm_on = on != 0;
    to_wide(link, g_perm_link, 512);
    to_wide(secret_text, g_perm_key, 96);
    g_perm_link_qr_size = link_qr_size;
    g_perm_auth_qr_size = auth_qr_size;
    if (link_qr_size) memcpy(g_perm_link_qr, link_qr, (size_t)link_qr_size * (size_t)link_qr_size);
    if (auth_qr_size) memcpy(g_perm_auth_qr, auth_qr, (size_t)auth_qr_size * (size_t)auth_qr_size);
    g_perm_serial++;
    ReleaseSRWLockExclusive(&g_ui_lock);
    post_refresh();
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (g_msg_show && msg == g_msg_show) {  // a second launch of RDC: come forward
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        return 0;
    }
    switch (msg) {
    case WM_CREATE: {
        g_hwnd = hwnd;
        // A launch without administrator rights may ask this window to come forward too.
        if (g_msg_show) ChangeWindowMessageFilterEx(hwnd, g_msg_show, MSGFLT_ALLOW, NULL);
        g_dpi = (int)GetDpiForWindow(hwnd);
        // With start at login on, closing the window only hides it: the window menu can still quit.
        HMENU sys = GetSystemMenu(hwnd, FALSE);
        if (sys) {
            AppendMenuW(sys, MF_SEPARATOR, 0, NULL);
            AppendMenuW(sys, MF_STRING, IDM_QUIT, L"Quit RDC");
        }
        rebuild(hwnd);
        int w, h;
        window_size(g_dpi, &w, &h);
        SetWindowPos(hwnd, NULL, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        PostMessageW(hwnd, WM_RDC_READY, 0, 0);
        return 0;
    }
    case WM_RDC_READY:
        if (g_on_ready) g_on_ready(g_app_ctx);
        refresh_ui();
        return 0;
    case WM_RDC_REFRESH:
        refresh_ui();
        return 0;
    case WM_RDC_RELAY_DONE:
        relay_done((RelayCheck *)lp);
        return 0;
    case WM_SYSCOMMAND:
        if ((wp & 0xFFF0) == IDM_QUIT) {
            DestroyWindow(hwnd);
            return 0;
        }
        break;
    case WM_CLOSE:
        // Start at login on: RDC is there to be reached, so closing the window leaves it running;
        // launching RDC again brings the window back.
        if (g_login_state == 1) {
            ShowWindow(hwnd, SW_HIDE);
            return 0;
        }
        DestroyWindow(hwnd);
        return 0;
    case WM_TIMER:
        if (wp == TIMER_COPIED) {
            KillTimer(hwnd, TIMER_COPIED);
            SetWindowTextW(g_copy, L"Copy link");
            SetWindowTextW(g_copy_remote, L"Copy link");
        }
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_COPY:
        case ID_COPY_REMOTE:
            copy_link(hwnd, LOWORD(wp) == ID_COPY_REMOTE);
            break;
        case ID_OPEN:
        case ID_OPEN_REMOTE: {
            wchar_t link[256];
            AcquireSRWLockShared(&g_ui_lock);
            wcscpy(link, LOWORD(wp) == ID_OPEN_REMOTE ? g_ui_remote : g_ui_link);
            ReleaseSRWLockShared(&g_ui_lock);
            if (link[0]) ShellExecuteW(hwnd, L"open", link, NULL, NULL, SW_SHOWNORMAL);
            break;
        }
        case ID_NEWCODE:
            action(RDC_ACTION_NEW_CODE);
            break;
        case ID_KICK:
            action(g_ai_active ? RDC_ACTION_STOP_AI : RDC_ACTION_DISCONNECT_ALL);
            break;
        case ID_AUTO:
            action(SendMessageW(g_auto, BM_GETCHECK, 0, 0) == BST_CHECKED ? RDC_ACTION_AUTO_UPDATE_ON
                                                                          : RDC_ACTION_AUTO_UPDATE_OFF);
            break;
        case ID_CHECK:
            action(RDC_ACTION_CHECK_UPDATE);
            break;
        case ID_INSTALL:
            action(RDC_ACTION_INSTALL_UPDATE);
            break;
        case ID_SETTINGS:
            settings_show();
            break;
        case ID_MEDIA_STOP:
            action(RDC_ACTION_STOP_MEDIA);
            break;
        case ID_CAMERA: {
            int ms = rdc_media_status();
            action((ms & RDC_MEDIA_CAMERA_INSTALLED) && !(ms & RDC_MEDIA_CAMERA_OUTDATED) ? RDC_ACTION_MEDIA_REMOVE : RDC_ACTION_MEDIA_INSTALL);
            break;
        }
        }
        return 0;
    case WM_CTLCOLORSTATIC: {
        HDC dc = (HDC)wp;
        HWND c = (HWND)lp;
        SetBkMode(dc, TRANSPARENT);
        int gray = c == g_lbl_code || c == g_lbl_link || c == g_upd_status || c == g_cam_caption;
        SetTextColor(dc, c == g_media ? RGB(0, 128, 64) : GetSysColor(gray ? COLOR_GRAYTEXT : COLOR_WINDOWTEXT));
        return (LRESULT)GetSysColorBrush(COLOR_WINDOW);
    }
    case WM_DPICHANGED: {
        g_dpi = HIWORD(wp);
        rebuild(hwnd);
        const RECT *r = (const RECT *)lp;
        SetWindowPos(hwnd, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

void rdc_app_run(rdc_ctx_cb on_ready, rdc_action_cb on_action, void *ctx) {
    g_on_ready = on_ready;
    g_on_action = on_action;
    g_app_ctx = ctx;
    INITCOMMONCONTROLSEX icc = {sizeof icc, ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW);
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    if (!wc.hIcon) wc.hIcon = LoadIconW(NULL, (LPCWSTR)IDI_APPLICATION);
    wc.lpszClassName = L"RDCWindow";
    RegisterClassExW(&wc);
    wc.lpfnWndProc = settings_proc;
    wc.lpszClassName = L"RDCSettings";
    RegisterClassExW(&wc);
    wc.lpfnWndProc = perm_proc;
    wc.lpszClassName = L"RDCPermanent";
    RegisterClassExW(&wc);
    keep_awake(rdc_pref_bool("keep_awake", 0));
    login_start(-1);  // is start at login on: closing the window hides it then
    // Centered in the work area of the main monitor.
    int w, h, x = CW_USEDEFAULT, y = CW_USEDEFAULT;
    window_size((int)GetDpiForSystem(), &w, &h);
    RECT area;
    if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0)) {
        x = area.left + (area.right - area.left - w) / 2;
        y = area.top + (area.bottom - area.top - h) / 2;
    }
    HWND hwnd = CreateWindowExW(0, L"RDCWindow", L"RDC", kWindowStyle, x, y, w, h, NULL, NULL, inst, NULL);
    if (!hwnd) {
        rlog("window not created (%lu)", (unsigned long)GetLastError());
        ExitProcess(1);
    }
    // Started at login: out of the way until RDC is launched again.
    if (started_at_login()) {
        rlog("started at login: the window stays hidden until RDC is launched again");
    } else {
        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);
    }
    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) {
        if (IsDialogMessageW(hwnd, &m)) continue;
        if (g_set.hwnd && IsDialogMessageW(g_set.hwnd, &m)) continue;
        if (g_perm.hwnd && IsDialogMessageW(g_perm.hwnd, &m)) continue;
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    camera_close();  // "RDC Camera" leaves the apps' lists with RDC
    ExitProcess(0);
}

void rdc_app_set_info(const char *code, const char *link) {
    AcquireSRWLockExclusive(&g_ui_lock);
    to_wide(code, g_ui_code, 32);
    to_wide(link, g_ui_link, 256);
    ReleaseSRWLockExclusive(&g_ui_lock);
    post_refresh();
}

void rdc_app_set_remote(const char *caption, const char *link) {
    AcquireSRWLockExclusive(&g_ui_lock);
    to_wide(caption, g_ui_remote_caption, 128);
    to_wide(link, g_ui_remote, 256);
    ReleaseSRWLockExclusive(&g_ui_lock);
    post_refresh();
}

void rdc_app_set_status(const char *text) {
    AcquireSRWLockExclusive(&g_ui_lock);
    to_wide(text, g_ui_status, 512);
    ReleaseSRWLockExclusive(&g_ui_lock);
    post_refresh();
}

// Windows asks for no permissions; the call comes every couple of seconds, so the window looks
// at the phone camera's state then.
void rdc_app_set_permissions(int screen_ok, int input_ok) { post_refresh(); }

void rdc_app_set_media(const char *text) {
    AcquireSRWLockExclusive(&g_ui_lock);
    to_wide(text, g_ui_media, 160);
    ReleaseSRWLockExclusive(&g_ui_lock);
    post_refresh();
}

void rdc_app_set_ai(int active) {
    LONG now = active ? 1 : 0;
    if (InterlockedExchange(&g_ai_active, now) == now) return;
    if (now) {
        HWND hwnd = g_hwnd;
        if (hwnd) {
            FLASHWINFO fi = {sizeof fi, hwnd, FLASHW_TRAY | FLASHW_TIMERNOFG, 3, 0};
            FlashWindowEx(&fi);
        }
    }
    post_refresh();
}

void rdc_settings_update(const char *version, int auto_update, const char *status, int can_install, int busy) {
    AcquireSRWLockExclusive(&g_ui_lock);
    to_wide(version, g_ui_version, 32);
    to_wide(status, g_ui_upd, 512);
    g_ui_auto = auto_update;
    g_ui_can_install = can_install;
    g_ui_busy = busy;
    ReleaseSRWLockExclusive(&g_ui_lock);
    post_refresh();
}
