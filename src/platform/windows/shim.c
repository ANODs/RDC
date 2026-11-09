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
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "platform.h"

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

// A second launch shows the first one's window. After an update (RDC_RESTART) the new
// version waits for the old one to exit.
static HANDLE g_instance;

static void single_instance(void) {
    if (wcsstr(GetCommandLineW(), L"--no-ui")) return;
    g_instance = CreateMutexW(NULL, FALSE, L"Local\\RDC-host");
    if (!g_instance) return;
    DWORD wait = GetEnvironmentVariableW(L"RDC_RESTART", NULL, 0) ? 15000 : 0;
    SetEnvironmentVariableW(L"RDC_RESTART", NULL);
    DWORD r = WaitForSingleObject(g_instance, wait);
    if (r == WAIT_OBJECT_0 || r == WAIT_ABANDONED) return;
    HWND other = FindWindowW(L"RDCWindow", NULL);
    if (other) {
        ShowWindow(other, SW_RESTORE);
        SetForegroundWindow(other);
    }
    ExitProcess(0);
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
    single_instance();
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

// Neither DXGI nor GDI puts the cursor into the image — we draw it ourselves.
static void draw_cursor(Frame *f) {
    CURSORINFO ci;
    ci.cbSize = sizeof ci;
    if (!GetCursorInfo(&ci) || !(ci.flags & CURSOR_SHOWING) || !ci.hCursor) return;
    ICONINFO ii;
    if (!GetIconInfo(ci.hCursor, &ii)) return;
    DrawIconEx(f->dc, ci.ptScreenPos.x - (int)ii.xHotspot, ci.ptScreenPos.y - (int)ii.yHotspot, ci.hCursor, 0, 0, 0,
               NULL, DI_NORMAL);
    if (ii.hbmMask) DeleteObject(ii.hbmMask);
    if (ii.hbmColor) DeleteObject(ii.hbmColor);
}

// ---------------------------------------------------------------------------
// DXGI Desktop Duplication: main monitor; frames arrive only when the screen changes.

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

static int dup_open(Dup *d, int verbose) {
    memset(d, 0, sizeof *d);
    IDXGIFactory1 *factory = NULL;
    if (FAILED(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory))) return -1;
    IDXGIAdapter1 *adapter = NULL;
    IDXGIOutput *output = NULL;
    // Main monitor — the one whose desktop starts at (0, 0).
    for (UINT i = 0; !output && IDXGIFactory1_EnumAdapters1(factory, i, &adapter) == S_OK; i++) {
        IDXGIOutput *o = NULL;
        for (UINT j = 0; IDXGIAdapter1_EnumOutputs(adapter, j, &o) == S_OK; j++) {
            DXGI_OUTPUT_DESC od;
            if (SUCCEEDED(IDXGIOutput_GetDesc(o, &od)) && od.AttachedToDesktop && od.DesktopCoordinates.left == 0 &&
                od.DesktopCoordinates.top == 0) {
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
        if (verbose) rlog("DXGI: main monitor not found");
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

// GDI: fallback capture (virtual machines, remote sessions, old drivers).
static int gdi_capture(Frame *f) {
    int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN);
    if (w <= 0 || h <= 0 || frame_ensure(f, w, h) != 0) return -1;
    HDC screen = GetDC(NULL);
    if (!screen) return -1;
    BOOL ok = BitBlt(f->dc, 0, 0, w, h, screen, 0, 0, SRCCOPY);
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
    if (FAILED(hr)) {
        rlog("capture: WIC unavailable (0x%08lx)", (unsigned long)hr);
        InterlockedExchange(&g_cap_status, -1);
        SetEvent(g_cap_ready);
        CoUninitialize();
        return 0;
    }
    have_dup = dup_open(&dup, 1) == 0;
    if (have_dup) {
        rlog("capture: DXGI, %dx%d", dup.w, dup.h);
    } else if (gdi_capture(&work) == 0) {
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
    SetEvent(g_cap_ready);

    CursorState cur;
    memset(&cur, 0, sizeof cur);
    uint64_t last_sent = 0, last_poll = 0, last_retry = rdc_now_us();
    int pending = 1, fresh = !have_dup, failures = 0;  // fresh — work holds a fresh GDI snapshot without the cursor
    while (g_cap_run) {
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
                have_dup = dup_open(&dup, 0) == 0;
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
                if (dup_open(&dup, 0) == 0) {
                    have_dup = 1;
                    pending = 1;
                    rlog("capture: back to DXGI, %dx%d", dup.w, dup.h);
                    continue;
                }
            }
            if (want && gdi_capture(&work) == 0) {
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
            ok = dup.have_image ? dup_copy(&dup, &work) == 0 : gdi_capture(&work) == 0;
        else
            ok = fresh || gdi_capture(&work) == 0;
        fresh = 0;
        if (ok) {
            draw_cursor(&work);
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

void rdc_capture_stop(void) {
    if (!g_cap_thread) return;
    InterlockedExchange(&g_cap_run, 0);
    WaitForSingleObject(g_cap_thread, 5000);
    CloseHandle(g_cap_thread);
    g_cap_thread = NULL;
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

void rdc_mouse_move(double nx, double ny) {
    // Without MOUSEEVENTF_VIRTUALDESK, 0..65535 is the main monitor, the one being captured.
    send_mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, (LONG)(clamp01(nx) * 65535.0 + 0.5),
               (LONG)(clamp01(ny) * 65535.0 + 0.5), 0);
}

void rdc_mouse_button(int button, int down, double nx, double ny) {
    rdc_mouse_move(nx, ny);
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

void rdc_cursor_pos(double *nx, double *ny) {
    POINT p = {0, 0};
    GetCursorPos(&p);
    int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN);
    *nx = w > 1 ? clamp01((double)p.x / (w - 1)) : 0.5;
    *ny = h > 1 ? clamp01((double)p.y / (h - 1)) : 0.5;
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

// ---------------------------------------------------------------------------
// App window

enum { ID_COPY = 101, ID_OPEN, ID_NEWCODE, ID_KICK, ID_AUTO, ID_CHECK, ID_INSTALL };
#define WM_RDC_REFRESH (WM_APP + 1)
#define WM_RDC_READY (WM_APP + 2)
#define TIMER_COPIED 1
#define CLIENT_W 440
#define CLIENT_H 388
static const DWORD kWindowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;

static HWND volatile g_hwnd;
static HWND g_code, g_link, g_copy, g_status, g_upd_status, g_auto, g_check, g_install, g_lbl_code, g_lbl_link, g_kick;
static volatile LONG g_ai_active;  // an AI agent is connected: the kick button stops it
static HFONT g_font, g_font_big, g_font_small;
static rdc_ctx_cb g_on_ready;
static rdc_action_cb g_on_action;
static void *g_app_ctx;
static int g_dpi = 96;

// Window state: written from any thread, shown on the window thread.
static SRWLOCK g_ui_lock = SRWLOCK_INIT;
static wchar_t g_ui_code[32] = L"— — —", g_ui_link[256] = L"", g_ui_status[512] = L"Starting…";
static wchar_t g_ui_version[32] = L"", g_ui_upd[512] = L"";
static int g_ui_auto = 1, g_ui_can_install, g_ui_busy;

static int px(int v) { return MulDiv(v, g_dpi, 96); }

static void set_text(HWND w, const wchar_t *text) {
    wchar_t cur[512];
    GetWindowTextW(w, cur, 512);
    if (wcscmp(cur, text) != 0) SetWindowTextW(w, text);
}

static void refresh_ui(void) {
    HWND hwnd = g_hwnd;
    if (!hwnd) return;
    wchar_t code[32], link[256], status[512], ver[32], upd[512], title[64];
    AcquireSRWLockShared(&g_ui_lock);
    wcscpy(code, g_ui_code);
    wcscpy(link, g_ui_link);
    wcscpy(status, g_ui_status);
    wcscpy(ver, g_ui_version);
    wcscpy(upd, g_ui_upd);
    int autoupd = g_ui_auto, can = g_ui_can_install, busy = g_ui_busy;
    ReleaseSRWLockShared(&g_ui_lock);
    set_text(g_code, code);
    set_text(g_link, link);
    set_text(g_status, status);
    set_text(g_upd_status, upd);
    if (ver[0])
        wfmt(title, 64, L"RDC %ls", ver);
    else
        wcscpy(title, L"RDC");
    set_text(hwnd, title);
    SendMessageW(g_auto, BM_SETCHECK, autoupd ? BST_CHECKED : BST_UNCHECKED, 0);
    EnableWindow(g_check, !busy);
    ShowWindow(g_install, can ? SW_SHOW : SW_HIDE);
    EnableWindow(g_install, can && !busy);
    set_text(g_kick, g_ai_active ? L"Stop AI agent" : L"Disconnect all");
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
    g_lbl_link = make(p, L"STATIC", L"Browser link", SS_CENTER, 0, 0, 90, CLIENT_W, 18, 0, g_font_small);
    g_link = make(p, L"EDIT", L"", ES_CENTER | ES_READONLY | ES_AUTOHSCROLL | WS_TABSTOP, WS_EX_CLIENTEDGE, 24, 110, 392, 26,
                  0, g_font);
    g_copy = make(p, L"BUTTON", L"Copy link", btn, 0, 45, 144, 170, 30, ID_COPY, g_font);
    make(p, L"BUTTON", L"Open in browser", btn, 0, 225, 144, 170, 30, ID_OPEN, g_font);
    g_status = make(p, L"STATIC", L"", SS_CENTER | SS_ENDELLIPSIS, 0, 12, 186, 416, 20, 0, g_font);
    make(p, L"BUTTON", L"New code", btn, 0, 45, 212, 170, 30, ID_NEWCODE, g_font);
    g_kick = make(p, L"BUTTON", L"Disconnect all", btn, 0, 225, 212, 170, 30, ID_KICK, g_font);
    make(p, L"STATIC", L"", SS_ETCHEDHORZ, 0, 24, 256, 392, 2, 0, g_font);
    g_auto = make(p, L"BUTTON", L"Update automatically", BS_AUTOCHECKBOX | WS_TABSTOP, 0, 28, 270, 210, 26, ID_AUTO, g_font);
    g_check = make(p, L"BUTTON", L"Check for updates", btn, 0, 245, 268, 170, 30, ID_CHECK, g_font);
    g_upd_status = make(p, L"STATIC", L"", SS_CENTER, 0, 12, 306, 416, 34, 0, g_font_small);
    g_install = make(p, L"BUTTON", L"Update and restart", btn, 0, 110, 344, 220, 30, ID_INSTALL, g_font);
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

static void copy_link(HWND hwnd) {
    wchar_t link[256];
    AcquireSRWLockShared(&g_ui_lock);
    wcscpy(link, g_ui_link);
    ReleaseSRWLockShared(&g_ui_lock);
    if (!link[0]) return;
    size_t bytes = (wcslen(link) + 1) * sizeof(wchar_t);
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!mem) return;
    void *dst = GlobalLock(mem);
    if (!dst) {
        GlobalFree(mem);
        return;
    }
    memcpy(dst, link, bytes);
    GlobalUnlock(mem);
    if (!OpenClipboard(hwnd)) {
        GlobalFree(mem);
        return;
    }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, mem)) GlobalFree(mem);
    CloseClipboard();
    SetWindowTextW(g_copy, L"Copied ✓");
    SetTimer(hwnd, TIMER_COPIED, 1500, NULL);
}

static void action(int a) {
    if (g_on_action) g_on_action(g_app_ctx, a);
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        g_hwnd = hwnd;
        g_dpi = (int)GetDpiForWindow(hwnd);
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
    case WM_TIMER:
        if (wp == TIMER_COPIED) {
            KillTimer(hwnd, TIMER_COPIED);
            SetWindowTextW(g_copy, L"Copy link");
        }
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_COPY:
            copy_link(hwnd);
            break;
        case ID_OPEN: {
            wchar_t link[256];
            AcquireSRWLockShared(&g_ui_lock);
            wcscpy(link, g_ui_link);
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
        }
        return 0;
    case WM_CTLCOLORSTATIC: {
        HDC dc = (HDC)wp;
        HWND c = (HWND)lp;
        SetBkMode(dc, TRANSPARENT);
        int gray = c == g_lbl_code || c == g_lbl_link || c == g_upd_status;
        SetTextColor(dc, GetSysColor(gray ? COLOR_GRAYTEXT : COLOR_WINDOWTEXT));
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
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) {
        if (IsDialogMessageW(hwnd, &m)) continue;
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    ExitProcess(0);
}

void rdc_app_set_info(const char *code, const char *link) {
    AcquireSRWLockExclusive(&g_ui_lock);
    to_wide(code, g_ui_code, 32);
    to_wide(link, g_ui_link, 256);
    ReleaseSRWLockExclusive(&g_ui_lock);
    post_refresh();
}

void rdc_app_set_status(const char *text) {
    AcquireSRWLockExclusive(&g_ui_lock);
    to_wide(text, g_ui_status, 512);
    ReleaseSRWLockExclusive(&g_ui_lock);
    post_refresh();
}

void rdc_app_set_permissions(int screen_ok, int input_ok) {}

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
