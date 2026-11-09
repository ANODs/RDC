// RDC Camera: the Media Foundation media source behind the virtual camera RDC.exe creates on
// Windows 11 with MFCreateVirtualCamera (docs/PLAN.md, section 6). The Frame Server service
// (Local Service, session 0) creates the COM class RDC registers under HKLM, gets an IMFActivate
// and activates the source. One video stream: NV12, 1280×720 or 640×480 at 30 frames a second.
// Its frames come from RDC.exe over the named pipe of camera_pipe.h, already scaled to the size
// the app picked; without RDC or a phone the stream shows a dark frame.
//
// Objects: the class factory (static), the activation object (IMFActivate over an attribute
// store), the media source (IMFMediaSourceEx, IMFGetService, IKsControl,
// IMFSampleAllocatorControl) and its stream (IMFMediaStream2). While it streams, the stream runs
// one worker thread: it reads frames from the pipe and answers the pipeline's sample requests at
// the frame rate. Interface IDs and attributes newer than the mingw headers are spelled out here,
// with values from the Windows SDK headers.
#include <windows.h>
#include <initguid.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "camera_pipe.h"

static const GUID kCLSID_RdcCamera = {0x726462D9, 0xEE2A, 0x4056, {0xB1, 0x30, 0x8D, 0xE9, 0xAE, 0xA6, 0x8C, 0xE7}};
static const GUID kGUID_NULL = {0, 0, 0, {0, 0, 0, 0, 0, 0, 0, 0}};
static const GUID kIID_IUnknown = {0x00000000, 0x0000, 0x0000, {0xC0, 0, 0, 0, 0, 0, 0, 0x46}};
static const GUID kIID_IClassFactory = {0x00000001, 0x0000, 0x0000, {0xC0, 0, 0, 0, 0, 0, 0, 0x46}};
static const GUID kIID_IKsControl = {0x28F54685, 0x06FD, 0x11D2, {0xB2, 0x7A, 0x00, 0xA0, 0xC9, 0x22, 0x31, 0x96}};
static const GUID kIID_IMFMediaStream2 = {0xC5BC37D6, 0x75C7, 0x46A1, {0xA1, 0x32, 0x81, 0xB5, 0xF7, 0x23, 0xC2, 0x0F}};
static const GUID kIID_IMFSampleAllocatorControl = {0xDA62B958, 0x3A38, 0x4A97, {0xBD, 0x27, 0x14, 0x9C, 0x64, 0x0C, 0x07, 0x71}};
static const GUID kMF_DEVICESTREAM_STREAM_CATEGORY = {0x2939E7B8, 0xA62E, 0x4579, {0xB6, 0x74, 0xD4, 0x07, 0x3D, 0xFA, 0xBB, 0xBA}};
static const GUID kMF_DEVICESTREAM_STREAM_ID = {0x11BD5120, 0xD124, 0x446B, {0x88, 0xE6, 0x17, 0x06, 0x02, 0x57, 0xFF, 0xF9}};
static const GUID kMF_DEVICESTREAM_FRAMESERVER_SHARED = {0x1CB378E9, 0xB279, 0x41D4, {0xAF, 0x97, 0x34, 0xA2, 0x43, 0xE6, 0x83, 0x20}};
static const GUID kMF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES = {0x17145FD1, 0x1B2B, 0x423C, {0x80, 0x01, 0x2B, 0x68, 0x33, 0xED, 0x35, 0x88}};
static const GUID kPINNAME_VIDEO_CAPTURE = {0xFB6C4281, 0x0353, 0x11D1, {0x90, 0x5F, 0x00, 0x00, 0xC0, 0xCC, 0x16, 0xBA}};

static const UINT32 kWidth[] = {1280, 640}, kHeight[] = {720, 480};
enum { kTypes = 2, kFps = 30, kMaxRequests = 16 };
static const DWORD kFourccNV12 = 0x3231564E;  // 'N' 'V' '1' '2'
enum { kFrameSourceColor = 1, kAllocatorCustom = 1 };  // MFFrameSourceTypes_Color, MFSampleAllocatorUsage_UsesCustomAllocator

// Live objects and server locks: the DLL stays loaded while there are any.
static volatile LONG g_objects;

static LONGLONG qpc(void) {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return t.QuadPart;
}

static LONGLONG qpf(void) {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    return f.QuadPart;
}

// ---------------------------------------------------------------------------
// Types

typedef struct Source Source;
typedef struct Stream Stream;

// IMFMediaStream2: IMFMediaStream plus the stream state.
typedef struct Stream2Vtbl {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(Stream *This, REFIID riid, void **ppv);
    ULONG(STDMETHODCALLTYPE *AddRef)(Stream *This);
    ULONG(STDMETHODCALLTYPE *Release)(Stream *This);
    HRESULT(STDMETHODCALLTYPE *GetEvent)(Stream *This, DWORD flags, IMFMediaEvent **ev);
    HRESULT(STDMETHODCALLTYPE *BeginGetEvent)(Stream *This, IMFAsyncCallback *cb, IUnknown *state);
    HRESULT(STDMETHODCALLTYPE *EndGetEvent)(Stream *This, IMFAsyncResult *result, IMFMediaEvent **ev);
    HRESULT(STDMETHODCALLTYPE *QueueEvent)(Stream *This, MediaEventType met, REFGUID ext, HRESULT status, const PROPVARIANT *value);
    HRESULT(STDMETHODCALLTYPE *GetMediaSource)(Stream *This, IMFMediaSource **source);
    HRESULT(STDMETHODCALLTYPE *GetStreamDescriptor)(Stream *This, IMFStreamDescriptor **sd);
    HRESULT(STDMETHODCALLTYPE *RequestSample)(Stream *This, IUnknown *token);
    HRESULT(STDMETHODCALLTYPE *SetStreamState)(Stream *This, MF_STREAM_STATE state);
    HRESULT(STDMETHODCALLTYPE *GetStreamState)(Stream *This, MF_STREAM_STATE *state);
} Stream2Vtbl;

typedef struct KsControlVtbl {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(void *This, REFIID riid, void **ppv);
    ULONG(STDMETHODCALLTYPE *AddRef)(void *This);
    ULONG(STDMETHODCALLTYPE *Release)(void *This);
    HRESULT(STDMETHODCALLTYPE *KsProperty)(void *This, void *property, ULONG property_len, void *data, ULONG data_len, ULONG *returned);
    HRESULT(STDMETHODCALLTYPE *KsMethod)(void *This, void *method, ULONG method_len, void *data, ULONG data_len, ULONG *returned);
    HRESULT(STDMETHODCALLTYPE *KsEvent)(void *This, void *event, ULONG event_len, void *data, ULONG data_len, ULONG *returned);
} KsControlVtbl;

typedef struct AllocControlVtbl {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(void *This, REFIID riid, void **ppv);
    ULONG(STDMETHODCALLTYPE *AddRef)(void *This);
    ULONG(STDMETHODCALLTYPE *Release)(void *This);
    HRESULT(STDMETHODCALLTYPE *SetDefaultAllocator)(void *This, DWORD out_stream, IUnknown *allocator);
    HRESULT(STDMETHODCALLTYPE *GetAllocatorUsage)(void *This, DWORD out_stream, DWORD *in_stream, int *usage);
} AllocControlVtbl;

struct Source {
    IMFMediaSourceEx iface;  // also IMFMediaSource and IMFMediaEventGenerator
    IMFGetService service;
    struct { const KsControlVtbl *lpVtbl; } ks;
    struct { const AllocControlVtbl *lpVtbl; } alloc;
    LONG refs;
    SRWLOCK lock;
    int shut;     // Shutdown was called
    int started;
    IMFMediaEventQueue *queue;
    IMFAttributes *attrs;
    IMFPresentationDescriptor *pd;
    Stream *stream;
};

#define SOURCE_OF(p, member) ((Source *)((char *)(p) - offsetof(Source, member)))

struct Stream {
    const Stream2Vtbl *lpVtbl;
    LONG refs;
    CRITICAL_SECTION control;  // start, stop and shutdown, one at a time; taken before `lock`
    SRWLOCK lock;
    int shut;
    int selected;  // changed under the source's lock
    MF_STREAM_STATE state;
    Source *source;  // held until Shutdown
    IMFMediaEventQueue *queue;
    IMFStreamDescriptor *sd;
    IMFAttributes *attrs;
    UINT32 width, height;            // the current media type
    IUnknown *tokens[kMaxRequests];  // sample requests waiting, oldest first; NULL is a valid token
    int head, pending;
    HANDLE thread, stop, wake;
    // Only the worker thread touches these while it runs.
    HANDLE pipe, read_done;
    OVERLAPPED ov;
    int reading, in_payload, have_frame;
    rdc_camera_frame hdr;
    size_t got, frame_size;
    uint8_t *frame, *incoming;
};

static HRESULT stream_create(Source *source, Stream **out);
static void stream_stop(Stream *s, int send_event);
static void stream_shutdown(Stream *s);
static ULONG STDMETHODCALLTYPE st_Release(Stream *s);

// ---------------------------------------------------------------------------
// The media source

static HRESULT source_qi(Source *s, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualGUID(riid, &kIID_IUnknown) || IsEqualGUID(riid, &IID_IMFMediaEventGenerator) ||
        IsEqualGUID(riid, &IID_IMFMediaSource) || IsEqualGUID(riid, &IID_IMFMediaSourceEx))
        *ppv = &s->iface;
    else if (IsEqualGUID(riid, &IID_IMFGetService))
        *ppv = &s->service;
    else if (IsEqualGUID(riid, &kIID_IKsControl))
        *ppv = &s->ks;
    else if (IsEqualGUID(riid, &kIID_IMFSampleAllocatorControl))
        *ppv = &s->alloc;
    else {
        *ppv = NULL;
        return E_NOINTERFACE;
    }
    InterlockedIncrement(&s->refs);
    return S_OK;
}

static ULONG source_addref(Source *s) { return (ULONG)InterlockedIncrement(&s->refs); }

static ULONG source_release(Source *s) {
    LONG n = InterlockedDecrement(&s->refs);
    if (n == 0) {
        // Shutdown has released the stream (it held this source); what is left goes now.
        if (s->stream) st_Release(s->stream);
        if (s->queue) IMFMediaEventQueue_Release(s->queue);
        if (s->pd) IMFPresentationDescriptor_Release(s->pd);
        if (s->attrs) IMFAttributes_Release(s->attrs);
        free(s);
        InterlockedDecrement(&g_objects);
    }
    return (ULONG)n;
}

static int source_is_shut(Source *s) {
    AcquireSRWLockShared(&s->lock);
    int shut = s->shut;
    ReleaseSRWLockShared(&s->lock);
    return shut;
}

// The event queue with a reference, or NULL after Shutdown.
static IMFMediaEventQueue *source_queue(Source *s) {
    AcquireSRWLockShared(&s->lock);
    IMFMediaEventQueue *q = s->shut ? NULL : s->queue;
    if (q) IMFMediaEventQueue_AddRef(q);
    ReleaseSRWLockShared(&s->lock);
    return q;
}

static HRESULT STDMETHODCALLTYPE src_QueryInterface(IMFMediaSourceEx *This, REFIID riid, void **ppv) {
    return source_qi((Source *)This, riid, ppv);
}
static ULONG STDMETHODCALLTYPE src_AddRef(IMFMediaSourceEx *This) { return source_addref((Source *)This); }
static ULONG STDMETHODCALLTYPE src_Release(IMFMediaSourceEx *This) { return source_release((Source *)This); }

static HRESULT STDMETHODCALLTYPE src_GetEvent(IMFMediaSourceEx *This, DWORD flags, IMFMediaEvent **ev) {
    IMFMediaEventQueue *q = source_queue((Source *)This);
    if (!q) return MF_E_SHUTDOWN;
    HRESULT hr = IMFMediaEventQueue_GetEvent(q, flags, ev);
    IMFMediaEventQueue_Release(q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE src_BeginGetEvent(IMFMediaSourceEx *This, IMFAsyncCallback *cb, IUnknown *state) {
    IMFMediaEventQueue *q = source_queue((Source *)This);
    if (!q) return MF_E_SHUTDOWN;
    HRESULT hr = IMFMediaEventQueue_BeginGetEvent(q, cb, state);
    IMFMediaEventQueue_Release(q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE src_EndGetEvent(IMFMediaSourceEx *This, IMFAsyncResult *result, IMFMediaEvent **ev) {
    IMFMediaEventQueue *q = source_queue((Source *)This);
    if (!q) return MF_E_SHUTDOWN;
    HRESULT hr = IMFMediaEventQueue_EndGetEvent(q, result, ev);
    IMFMediaEventQueue_Release(q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE src_QueueEvent(IMFMediaSourceEx *This, MediaEventType met, REFGUID ext, HRESULT status, const PROPVARIANT *value) {
    IMFMediaEventQueue *q = source_queue((Source *)This);
    if (!q) return MF_E_SHUTDOWN;
    HRESULT hr = IMFMediaEventQueue_QueueEventParamVar(q, met, ext, status, value);
    IMFMediaEventQueue_Release(q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE src_GetCharacteristics(IMFMediaSourceEx *This, DWORD *characteristics) {
    if (!characteristics) return E_POINTER;
    if (source_is_shut((Source *)This)) return MF_E_SHUTDOWN;
    *characteristics = MFMEDIASOURCE_IS_LIVE;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE src_CreatePresentationDescriptor(IMFMediaSourceEx *This, IMFPresentationDescriptor **out) {
    Source *s = (Source *)This;
    if (!out) return E_POINTER;
    *out = NULL;
    AcquireSRWLockShared(&s->lock);
    HRESULT hr = s->shut ? MF_E_SHUTDOWN : IMFPresentationDescriptor_Clone(s->pd, out);
    ReleaseSRWLockShared(&s->lock);
    return hr;
}

// The frame size of the media type the pipeline chose on the stream; one of ours.
static HRESULT current_size(IMFStreamDescriptor *sd, UINT32 *w, UINT32 *h) {
    IMFMediaTypeHandler *handler = NULL;
    IMFMediaType *type = NULL;
    UINT64 size = 0;
    HRESULT hr = IMFStreamDescriptor_GetMediaTypeHandler(sd, &handler);
    if (SUCCEEDED(hr)) hr = IMFMediaTypeHandler_GetCurrentMediaType(handler, &type);
    if (SUCCEEDED(hr)) hr = IMFMediaType_GetUINT64(type, &MF_MT_FRAME_SIZE, &size);
    if (SUCCEEDED(hr)) {
        *w = (UINT32)(size >> 32);
        *h = (UINT32)size;
        hr = MF_E_INVALIDMEDIATYPE;
        for (int i = 0; i < kTypes; i++)
            if (*w == kWidth[i] && *h == kHeight[i]) hr = S_OK;
    }
    if (type) IMFMediaType_Release(type);
    if (handler) IMFMediaTypeHandler_Release(handler);
    return hr;
}

static HRESULT stream_start(Stream *s, UINT32 w, UINT32 h, const PROPVARIANT *time);

static HRESULT STDMETHODCALLTYPE src_Start(IMFMediaSourceEx *This, IMFPresentationDescriptor *pd, const GUID *format, const PROPVARIANT *position) {
    Source *s = (Source *)This;
    if (!pd || !position) return E_INVALIDARG;
    if (format && !IsEqualGUID(format, &kGUID_NULL)) return MF_E_UNSUPPORTED_TIME_FORMAT;
    if (position->vt != VT_EMPTY && position->vt != VT_I8) return MF_E_UNSUPPORTED_TIME_FORMAT;
    DWORD count = 0;
    HRESULT hr = IMFPresentationDescriptor_GetStreamDescriptorCount(pd, &count);
    if (FAILED(hr)) return hr;
    if (count != 1) return E_INVALIDARG;
    BOOL selected = FALSE;
    IMFStreamDescriptor *sd = NULL;
    hr = IMFPresentationDescriptor_GetStreamDescriptorByIndex(pd, 0, &selected, &sd);
    if (FAILED(hr)) return hr;
    UINT32 w = kWidth[0], h = kHeight[0];
    if (selected) hr = current_size(sd, &w, &h);
    IMFStreamDescriptor_Release(sd);
    if (FAILED(hr)) return hr;

    AcquireSRWLockExclusive(&s->lock);
    if (s->shut) {
        ReleaseSRWLockExclusive(&s->lock);
        return MF_E_SHUTDOWN;
    }
    Stream *st = s->stream;
    PROPVARIANT now;
    PropVariantInit(&now);
    now.vt = VT_I8;
    now.hVal.QuadPart = MFGetSystemTime();
    if (selected) {
        // The stream object travels with the event; then it starts and says so on its own queue.
        IMFPresentationDescriptor_SelectStream(s->pd, 0);
        hr = IMFMediaEventQueue_QueueEventParamUnk(s->queue, st->selected ? MEUpdatedStream : MENewStream, &kGUID_NULL, S_OK, (IUnknown *)st);
        st->selected = 1;
        if (SUCCEEDED(hr)) hr = stream_start(st, w, h, &now);
    } else {
        IMFPresentationDescriptor_DeselectStream(s->pd, 0);
        st->selected = 0;
        stream_stop(st, 0);
    }
    if (SUCCEEDED(hr)) {
        s->started = 1;
        hr = IMFMediaEventQueue_QueueEventParamVar(s->queue, MESourceStarted, &kGUID_NULL, S_OK, &now);
    }
    ReleaseSRWLockExclusive(&s->lock);
    return hr;
}

static HRESULT STDMETHODCALLTYPE src_Stop(IMFMediaSourceEx *This) {
    Source *s = (Source *)This;
    HRESULT hr = S_OK;
    AcquireSRWLockExclusive(&s->lock);
    if (s->shut) {
        hr = MF_E_SHUTDOWN;
    } else if (!s->started) {
        hr = MF_E_INVALID_STATE_TRANSITION;
    } else {
        s->started = 0;
        if (s->stream->selected) {
            stream_stop(s->stream, 1);
            IMFPresentationDescriptor_DeselectStream(s->pd, 0);
            s->stream->selected = 0;
        }
        PROPVARIANT now;
        PropVariantInit(&now);
        now.vt = VT_I8;
        now.hVal.QuadPart = MFGetSystemTime();
        hr = IMFMediaEventQueue_QueueEventParamVar(s->queue, MESourceStopped, &kGUID_NULL, S_OK, &now);
    }
    ReleaseSRWLockExclusive(&s->lock);
    return hr;
}

// A camera does not pause and does not seek.
static HRESULT STDMETHODCALLTYPE src_Pause(IMFMediaSourceEx *This) {
    return source_is_shut((Source *)This) ? MF_E_SHUTDOWN : MF_E_INVALID_STATE_TRANSITION;
}

static HRESULT STDMETHODCALLTYPE src_Shutdown(IMFMediaSourceEx *This) {
    Source *s = (Source *)This;
    AcquireSRWLockExclusive(&s->lock);
    if (s->shut) {
        ReleaseSRWLockExclusive(&s->lock);
        return MF_E_SHUTDOWN;
    }
    s->shut = 1;
    Stream *st = s->stream;
    IMFMediaEventQueue *q = s->queue;
    IMFPresentationDescriptor *pd = s->pd;
    IMFAttributes *attrs = s->attrs;
    s->stream = NULL;
    s->queue = NULL;
    s->pd = NULL;
    s->attrs = NULL;
    ReleaseSRWLockExclusive(&s->lock);
    if (st) {
        stream_shutdown(st);
        st_Release(st);
    }
    if (q) {
        IMFMediaEventQueue_Shutdown(q);
        IMFMediaEventQueue_Release(q);
    }
    if (pd) IMFPresentationDescriptor_Release(pd);
    if (attrs) IMFAttributes_Release(attrs);
    return S_OK;
}

// The very store, not a copy: the pipeline reads what the virtual camera's creator put there.
static HRESULT STDMETHODCALLTYPE src_GetSourceAttributes(IMFMediaSourceEx *This, IMFAttributes **out) {
    Source *s = (Source *)This;
    if (!out) return E_POINTER;
    *out = NULL;
    AcquireSRWLockShared(&s->lock);
    HRESULT hr = s->shut ? MF_E_SHUTDOWN : S_OK;
    if (hr == S_OK) {
        *out = s->attrs;
        IMFAttributes_AddRef(s->attrs);
    }
    ReleaseSRWLockShared(&s->lock);
    return hr;
}

static HRESULT STDMETHODCALLTYPE src_GetStreamAttributes(IMFMediaSourceEx *This, DWORD id, IMFAttributes **out) {
    Source *s = (Source *)This;
    if (!out) return E_POINTER;
    *out = NULL;
    if (id != 0) return MF_E_INVALIDSTREAMNUMBER;
    AcquireSRWLockShared(&s->lock);
    HRESULT hr = s->shut ? MF_E_SHUTDOWN : S_OK;
    if (hr == S_OK) {
        *out = s->stream->attrs;
        IMFAttributes_AddRef(*out);
    }
    ReleaseSRWLockShared(&s->lock);
    return hr;
}

static HRESULT STDMETHODCALLTYPE src_SetD3DManager(IMFMediaSourceEx *This, IUnknown *manager) { return E_NOTIMPL; }

static IMFMediaSourceExVtbl kSourceVtbl = {
    .QueryInterface = src_QueryInterface,
    .AddRef = src_AddRef,
    .Release = src_Release,
    .GetEvent = src_GetEvent,
    .BeginGetEvent = src_BeginGetEvent,
    .EndGetEvent = src_EndGetEvent,
    .QueueEvent = src_QueueEvent,
    .GetCharacteristics = src_GetCharacteristics,
    .CreatePresentationDescriptor = src_CreatePresentationDescriptor,
    .Start = src_Start,
    .Stop = src_Stop,
    .Pause = src_Pause,
    .Shutdown = src_Shutdown,
    .GetSourceAttributes = src_GetSourceAttributes,
    .GetStreamAttributes = src_GetStreamAttributes,
    .SetD3DManager = src_SetD3DManager,
};

// IMFGetService: the Frame Server asks for it; there are no services.
static HRESULT STDMETHODCALLTYPE svc_QueryInterface(IMFGetService *This, REFIID riid, void **ppv) {
    return source_qi(SOURCE_OF(This, service), riid, ppv);
}
static ULONG STDMETHODCALLTYPE svc_AddRef(IMFGetService *This) { return source_addref(SOURCE_OF(This, service)); }
static ULONG STDMETHODCALLTYPE svc_Release(IMFGetService *This) { return source_release(SOURCE_OF(This, service)); }
static HRESULT STDMETHODCALLTYPE svc_GetService(IMFGetService *This, REFGUID service, REFIID riid, LPVOID *ppv) {
    if (ppv) *ppv = NULL;
    return MF_E_UNSUPPORTED_SERVICE;
}
static IMFGetServiceVtbl kServiceVtbl = {
    .QueryInterface = svc_QueryInterface,
    .AddRef = svc_AddRef,
    .Release = svc_Release,
    .GetService = svc_GetService,
};

// IKsControl: camera controls (focus, exposure…); this camera has none.
static HRESULT STDMETHODCALLTYPE ks_QueryInterface(void *This, REFIID riid, void **ppv) { return source_qi(SOURCE_OF(This, ks), riid, ppv); }
static ULONG STDMETHODCALLTYPE ks_AddRef(void *This) { return source_addref(SOURCE_OF(This, ks)); }
static ULONG STDMETHODCALLTYPE ks_Release(void *This) { return source_release(SOURCE_OF(This, ks)); }
static HRESULT STDMETHODCALLTYPE ks_KsProperty(void *This, void *property, ULONG property_len, void *data, ULONG data_len, ULONG *returned) {
    if (returned) *returned = 0;
    if (!property || property_len < sizeof(GUID) + 2 * sizeof(ULONG)) return E_INVALIDARG;
    return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
}
static HRESULT STDMETHODCALLTYPE ks_KsMethod(void *This, void *method, ULONG method_len, void *data, ULONG data_len, ULONG *returned) {
    if (returned) *returned = 0;
    return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
}
static HRESULT STDMETHODCALLTYPE ks_KsEvent(void *This, void *event, ULONG event_len, void *data, ULONG data_len, ULONG *returned) {
    if (returned) *returned = 0;
    return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
}
static const KsControlVtbl kKsVtbl = {ks_QueryInterface, ks_AddRef, ks_Release, ks_KsProperty, ks_KsMethod, ks_KsEvent};

// IMFSampleAllocatorControl: the stream makes its own samples.
static HRESULT STDMETHODCALLTYPE alloc_QueryInterface(void *This, REFIID riid, void **ppv) { return source_qi(SOURCE_OF(This, alloc), riid, ppv); }
static ULONG STDMETHODCALLTYPE alloc_AddRef(void *This) { return source_addref(SOURCE_OF(This, alloc)); }
static ULONG STDMETHODCALLTYPE alloc_Release(void *This) { return source_release(SOURCE_OF(This, alloc)); }
static HRESULT STDMETHODCALLTYPE alloc_SetDefaultAllocator(void *This, DWORD out_stream, IUnknown *allocator) {
    return out_stream == 0 ? S_OK : MF_E_INVALIDSTREAMNUMBER;
}
static HRESULT STDMETHODCALLTYPE alloc_GetAllocatorUsage(void *This, DWORD out_stream, DWORD *in_stream, int *usage) {
    if (!in_stream || !usage) return E_POINTER;
    if (out_stream != 0) return MF_E_INVALIDSTREAMNUMBER;
    *in_stream = out_stream;
    *usage = kAllocatorCustom;
    return S_OK;
}
static const AllocControlVtbl kAllocVtbl = {alloc_QueryInterface, alloc_AddRef, alloc_Release, alloc_SetDefaultAllocator, alloc_GetAllocatorUsage};

static HRESULT source_create(IMFAttributes *activate_attrs, Source **out) {
    *out = NULL;
    Source *s = calloc(1, sizeof *s);
    if (!s) return E_OUTOFMEMORY;
    s->iface.lpVtbl = &kSourceVtbl;
    s->service.lpVtbl = &kServiceVtbl;
    s->ks.lpVtbl = &kKsVtbl;
    s->alloc.lpVtbl = &kAllocVtbl;
    s->refs = 1;
    InitializeSRWLock(&s->lock);
    InterlockedIncrement(&g_objects);
    HRESULT hr = MFCreateEventQueue(&s->queue);
    if (SUCCEEDED(hr)) hr = MFCreateAttributes(&s->attrs, 4);
    if (SUCCEEDED(hr) && activate_attrs) hr = IMFAttributes_CopyAllItems(activate_attrs, s->attrs);
    if (SUCCEEDED(hr)) hr = stream_create(s, &s->stream);
    if (SUCCEEDED(hr)) hr = MFCreatePresentationDescriptor(1, &s->stream->sd, &s->pd);
    if (SUCCEEDED(hr)) hr = IMFPresentationDescriptor_SelectStream(s->pd, 0);
    if (FAILED(hr)) {
        src_Shutdown(&s->iface);  // the stream holds the source: break the cycle first
        source_release(s);
        return hr;
    }
    *out = s;
    return S_OK;
}

// ---------------------------------------------------------------------------
// The stream

static HRESULT make_type(UINT32 w, UINT32 h, IMFMediaType **out) {
    IMFMediaType *t = NULL;
    HRESULT hr = MFCreateMediaType(&t);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(t, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(t, &MF_MT_SUBTYPE, &MFVideoFormat_NV12);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_FIXED_SIZE_SAMPLES, TRUE);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_SAMPLE_SIZE, w * h * 3 / 2);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_DEFAULT_STRIDE, w);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT64(t, &MF_MT_FRAME_SIZE, ((UINT64)w << 32) | h);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT64(t, &MF_MT_FRAME_RATE, ((UINT64)kFps << 32) | 1);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT64(t, &MF_MT_PIXEL_ASPECT_RATIO, ((UINT64)1 << 32) | 1);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_AVG_BITRATE, w * h * 12 * kFps);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT601);  // RDC.exe converts with BT.601
    if (FAILED(hr)) {
        if (t) IMFMediaType_Release(t);
        return hr;
    }
    *out = t;
    return S_OK;
}

// What the Frame Server looks for on a camera stream, on the descriptor and on the stream's store.
static HRESULT set_stream_attrs(IMFAttributes *a) {
    HRESULT hr = IMFAttributes_SetGUID(a, &kMF_DEVICESTREAM_STREAM_CATEGORY, &kPINNAME_VIDEO_CAPTURE);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(a, &kMF_DEVICESTREAM_STREAM_ID, 0);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(a, &kMF_DEVICESTREAM_FRAMESERVER_SHARED, 1);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(a, &kMF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, kFrameSourceColor);
    return hr;
}

static void stream_free(Stream *s) {
    for (int i = 0; i < s->pending; i++) {
        IUnknown *t = s->tokens[(s->head + i) % kMaxRequests];
        if (t) IUnknown_Release(t);
    }
    if (s->queue) IMFMediaEventQueue_Release(s->queue);
    if (s->sd) IMFStreamDescriptor_Release(s->sd);
    if (s->attrs) IMFAttributes_Release(s->attrs);
    if (s->source) source_release(s->source);
    if (s->stop) CloseHandle(s->stop);
    if (s->wake) CloseHandle(s->wake);
    if (s->read_done) CloseHandle(s->read_done);
    DeleteCriticalSection(&s->control);
    free(s->frame);
    free(s->incoming);
    free(s);
    InterlockedDecrement(&g_objects);
}

static HRESULT STDMETHODCALLTYPE st_QueryInterface(Stream *s, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualGUID(riid, &kIID_IUnknown) || IsEqualGUID(riid, &IID_IMFMediaEventGenerator) ||
        IsEqualGUID(riid, &IID_IMFMediaStream) || IsEqualGUID(riid, &kIID_IMFMediaStream2)) {
        *ppv = s;
        InterlockedIncrement(&s->refs);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE st_AddRef(Stream *s) { return (ULONG)InterlockedIncrement(&s->refs); }

static ULONG STDMETHODCALLTYPE st_Release(Stream *s) {
    LONG n = InterlockedDecrement(&s->refs);
    if (n == 0) stream_free(s);
    return (ULONG)n;
}

static IMFMediaEventQueue *stream_queue(Stream *s) {
    AcquireSRWLockShared(&s->lock);
    IMFMediaEventQueue *q = s->shut ? NULL : s->queue;
    if (q) IMFMediaEventQueue_AddRef(q);
    ReleaseSRWLockShared(&s->lock);
    return q;
}

static HRESULT STDMETHODCALLTYPE st_GetEvent(Stream *s, DWORD flags, IMFMediaEvent **ev) {
    IMFMediaEventQueue *q = stream_queue(s);
    if (!q) return MF_E_SHUTDOWN;
    HRESULT hr = IMFMediaEventQueue_GetEvent(q, flags, ev);
    IMFMediaEventQueue_Release(q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE st_BeginGetEvent(Stream *s, IMFAsyncCallback *cb, IUnknown *state) {
    IMFMediaEventQueue *q = stream_queue(s);
    if (!q) return MF_E_SHUTDOWN;
    HRESULT hr = IMFMediaEventQueue_BeginGetEvent(q, cb, state);
    IMFMediaEventQueue_Release(q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE st_EndGetEvent(Stream *s, IMFAsyncResult *result, IMFMediaEvent **ev) {
    IMFMediaEventQueue *q = stream_queue(s);
    if (!q) return MF_E_SHUTDOWN;
    HRESULT hr = IMFMediaEventQueue_EndGetEvent(q, result, ev);
    IMFMediaEventQueue_Release(q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE st_QueueEvent(Stream *s, MediaEventType met, REFGUID ext, HRESULT status, const PROPVARIANT *value) {
    IMFMediaEventQueue *q = stream_queue(s);
    if (!q) return MF_E_SHUTDOWN;
    HRESULT hr = IMFMediaEventQueue_QueueEventParamVar(q, met, ext, status, value);
    IMFMediaEventQueue_Release(q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE st_GetMediaSource(Stream *s, IMFMediaSource **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    AcquireSRWLockShared(&s->lock);
    HRESULT hr = s->shut || !s->source ? MF_E_SHUTDOWN : S_OK;
    if (hr == S_OK) {
        *out = (IMFMediaSource *)&s->source->iface;
        source_addref(s->source);
    }
    ReleaseSRWLockShared(&s->lock);
    return hr;
}

static HRESULT STDMETHODCALLTYPE st_GetStreamDescriptor(Stream *s, IMFStreamDescriptor **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    AcquireSRWLockShared(&s->lock);
    HRESULT hr = s->shut ? MF_E_SHUTDOWN : S_OK;
    if (hr == S_OK) {
        *out = s->sd;
        IMFStreamDescriptor_AddRef(s->sd);
    }
    ReleaseSRWLockShared(&s->lock);
    return hr;
}

// The pipeline asks for a frame; the worker answers at the frame rate with this token attached.
static HRESULT STDMETHODCALLTYPE st_RequestSample(Stream *s, IUnknown *token) {
    HRESULT hr = S_OK;
    AcquireSRWLockExclusive(&s->lock);
    if (s->shut)
        hr = MF_E_SHUTDOWN;
    else if (s->state != MF_STREAM_STATE_RUNNING || !s->thread)
        hr = MF_E_INVALIDREQUEST;
    else if (s->pending == kMaxRequests)
        hr = MF_E_NOTACCEPTING;
    else {
        if (token) IUnknown_AddRef(token);
        s->tokens[(s->head + s->pending) % kMaxRequests] = token;
        s->pending++;
    }
    ReleaseSRWLockExclusive(&s->lock);
    if (hr == S_OK) SetEvent(s->wake);
    return hr;
}

// Takes the waiting requests out, under the lock; the caller releases their tokens.
static int take_requests_locked(Stream *s, IUnknown **out) {
    int n = s->pending;
    for (int i = 0; i < n; i++) out[i] = s->tokens[(s->head + i) % kMaxRequests];
    s->head = 0;
    s->pending = 0;
    return n;
}

static void release_tokens(IUnknown **tokens, int n) {
    for (int i = 0; i < n; i++)
        if (tokens[i]) IUnknown_Release(tokens[i]);
}

static DWORD WINAPI worker_main(LPVOID arg);

// Under `control` and `lock`: the worker thread for the current size, if it is not running.
static HRESULT worker_start_locked(Stream *s) {
    if (s->thread) return S_OK;
    size_t size = (size_t)s->width * s->height * 3 / 2;
    if (size != s->frame_size || !s->frame || !s->incoming) {
        free(s->frame);
        free(s->incoming);
        s->frame = malloc(size);
        s->incoming = malloc(size);
        s->frame_size = s->frame && s->incoming ? size : 0;
        if (!s->frame_size) return E_OUTOFMEMORY;
    }
    ResetEvent(s->stop);
    st_AddRef(s);  // the worker's own reference
    s->thread = CreateThread(NULL, 0, worker_main, s, 0, NULL);
    if (!s->thread) {
        InterlockedDecrement(&s->refs);  // never the last one: the caller holds the stream
        return HRESULT_FROM_WIN32(GetLastError());
    }
    return S_OK;
}

static HRESULT stream_start(Stream *s, UINT32 w, UINT32 h, const PROPVARIANT *time) {
    EnterCriticalSection(&s->control);
    AcquireSRWLockShared(&s->lock);
    int shut = s->shut;
    int restart = s->thread && (s->width != w || s->height != h);
    ReleaseSRWLockShared(&s->lock);
    if (shut) {
        LeaveCriticalSection(&s->control);
        return MF_E_SHUTDOWN;
    }
    if (restart) stream_stop(s, 0);  // another size: the pipe asks RDC for frames of the new one
    AcquireSRWLockExclusive(&s->lock);
    s->width = w;
    s->height = h;
    HRESULT hr = worker_start_locked(s);
    if (SUCCEEDED(hr)) s->state = MF_STREAM_STATE_RUNNING;
    IMFMediaEventQueue *q = s->queue;
    if (q) IMFMediaEventQueue_AddRef(q);
    ReleaseSRWLockExclusive(&s->lock);
    if (SUCCEEDED(hr) && q) hr = IMFMediaEventQueue_QueueEventParamVar(q, MEStreamStarted, &kGUID_NULL, S_OK, time);
    if (q) IMFMediaEventQueue_Release(q);
    LeaveCriticalSection(&s->control);
    return hr;
}

// Stops the worker and drops the waiting requests; with send_event, says so on the stream's queue.
static void stream_stop(Stream *s, int send_event) {
    IUnknown *tokens[kMaxRequests];
    EnterCriticalSection(&s->control);  // recursive: stream_start holds it when it restarts
    AcquireSRWLockExclusive(&s->lock);
    HANDLE thread = s->thread;
    s->thread = NULL;
    s->state = MF_STREAM_STATE_STOPPED;
    int n = take_requests_locked(s, tokens);
    IMFMediaEventQueue *q = send_event && !s->shut ? s->queue : NULL;
    if (q) IMFMediaEventQueue_AddRef(q);
    ReleaseSRWLockExclusive(&s->lock);
    if (thread) {
        SetEvent(s->stop);
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
    }
    release_tokens(tokens, n);
    if (q) {
        IMFMediaEventQueue_QueueEventParamVar(q, MEStreamStopped, &kGUID_NULL, S_OK, NULL);
        IMFMediaEventQueue_Release(q);
    }
    LeaveCriticalSection(&s->control);
}

static void stream_shutdown(Stream *s) {
    stream_stop(s, 0);
    EnterCriticalSection(&s->control);
    AcquireSRWLockExclusive(&s->lock);
    s->shut = 1;
    IMFMediaEventQueue *q = s->queue;
    Source *source = s->source;
    s->queue = NULL;
    s->source = NULL;
    ReleaseSRWLockExclusive(&s->lock);
    LeaveCriticalSection(&s->control);
    if (q) {
        IMFMediaEventQueue_Shutdown(q);
        IMFMediaEventQueue_Release(q);
    }
    if (source) source_release(source);
}

// Running: frames on request. Paused: the pipe stays, requests wait for Running. Stopped: no worker.
// No events: the pipeline changes the state itself.
static HRESULT STDMETHODCALLTYPE st_SetStreamState(Stream *s, MF_STREAM_STATE state) {
    IUnknown *tokens[kMaxRequests];
    int n = 0;
    HRESULT hr = S_OK;
    EnterCriticalSection(&s->control);
    AcquireSRWLockExclusive(&s->lock);
    if (s->shut) {
        hr = MF_E_SHUTDOWN;
    } else if (state == s->state) {
        hr = S_OK;
    } else if (state == MF_STREAM_STATE_RUNNING) {
        hr = worker_start_locked(s);
        if (SUCCEEDED(hr)) s->state = MF_STREAM_STATE_RUNNING;
    } else if (state == MF_STREAM_STATE_PAUSED) {
        if (s->state != MF_STREAM_STATE_RUNNING) {
            hr = MF_E_INVALID_STATE_TRANSITION;
        } else {
            s->state = MF_STREAM_STATE_PAUSED;
            n = take_requests_locked(s, tokens);
        }
    } else if (state != MF_STREAM_STATE_STOPPED) {
        hr = MF_E_INVALID_STATE_TRANSITION;
    }
    int stop = !s->shut && state == MF_STREAM_STATE_STOPPED && s->state != MF_STREAM_STATE_STOPPED;
    ReleaseSRWLockExclusive(&s->lock);
    if (stop) stream_stop(s, 0);
    release_tokens(tokens, n);
    LeaveCriticalSection(&s->control);
    return hr;
}

static HRESULT STDMETHODCALLTYPE st_GetStreamState(Stream *s, MF_STREAM_STATE *state) {
    if (!state) return E_POINTER;
    AcquireSRWLockShared(&s->lock);
    HRESULT hr = s->shut ? MF_E_SHUTDOWN : S_OK;
    *state = s->state;
    ReleaseSRWLockShared(&s->lock);
    return hr;
}

static const Stream2Vtbl kStreamVtbl = {
    .QueryInterface = st_QueryInterface,
    .AddRef = st_AddRef,
    .Release = st_Release,
    .GetEvent = st_GetEvent,
    .BeginGetEvent = st_BeginGetEvent,
    .EndGetEvent = st_EndGetEvent,
    .QueueEvent = st_QueueEvent,
    .GetMediaSource = st_GetMediaSource,
    .GetStreamDescriptor = st_GetStreamDescriptor,
    .RequestSample = st_RequestSample,
    .SetStreamState = st_SetStreamState,
    .GetStreamState = st_GetStreamState,
};

static HRESULT stream_create(Source *source, Stream **out) {
    *out = NULL;
    Stream *s = calloc(1, sizeof *s);
    if (!s) return E_OUTOFMEMORY;
    s->lpVtbl = &kStreamVtbl;
    s->refs = 1;
    InitializeCriticalSection(&s->control);
    InitializeSRWLock(&s->lock);
    s->state = MF_STREAM_STATE_STOPPED;
    s->width = kWidth[0];
    s->height = kHeight[0];
    s->pipe = INVALID_HANDLE_VALUE;
    s->source = source;
    source_addref(source);
    InterlockedIncrement(&g_objects);
    s->stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    s->wake = CreateEventW(NULL, FALSE, FALSE, NULL);
    s->read_done = CreateEventW(NULL, TRUE, FALSE, NULL);
    HRESULT hr = s->stop && s->wake && s->read_done ? S_OK : HRESULT_FROM_WIN32(GetLastError());
    if (SUCCEEDED(hr)) hr = MFCreateEventQueue(&s->queue);
    IMFMediaType *types[kTypes] = {NULL};
    for (int i = 0; i < kTypes && SUCCEEDED(hr); i++) hr = make_type(kWidth[i], kHeight[i], &types[i]);
    if (SUCCEEDED(hr)) hr = MFCreateStreamDescriptor(0, kTypes, types, &s->sd);
    if (SUCCEEDED(hr)) {
        IMFMediaTypeHandler *handler = NULL;
        hr = IMFStreamDescriptor_GetMediaTypeHandler(s->sd, &handler);
        if (SUCCEEDED(hr)) hr = IMFMediaTypeHandler_SetCurrentMediaType(handler, types[0]);
        if (handler) IMFMediaTypeHandler_Release(handler);
    }
    for (int i = 0; i < kTypes; i++)
        if (types[i]) IMFMediaType_Release(types[i]);
    if (SUCCEEDED(hr)) hr = set_stream_attrs((IMFAttributes *)s->sd);
    if (SUCCEEDED(hr)) hr = MFCreateAttributes(&s->attrs, 4);
    if (SUCCEEDED(hr)) hr = set_stream_attrs(s->attrs);
    if (FAILED(hr)) {
        st_Release(s);
        return hr;
    }
    *out = s;
    return S_OK;
}

// ---------------------------------------------------------------------------
// The worker: frames from RDC.exe over the pipe, samples for the pipeline at the frame rate.

static void pipe_close(Stream *s) {
    if (s->pipe == INVALID_HANDLE_VALUE) return;
    if (s->reading) {
        DWORD n = 0;
        CancelIoEx(s->pipe, &s->ov);
        GetOverlappedResult(s->pipe, &s->ov, &n, TRUE);  // the buffer stays ours until the read is gone
        s->reading = 0;
    }
    CloseHandle(s->pipe);
    s->pipe = INVALID_HANDLE_VALUE;
    s->in_payload = 0;
    s->got = 0;
    s->have_frame = 0;  // RDC is gone: the dark frame, not a frozen picture
}

// Connects to RDC.exe and says which size this app wants. RDC may not run: then the dark frame.
static void pipe_connect(Stream *s) {
    // Identification only: the pipe's server may not act as this service's account.
    HANDLE p = CreateFileW(RDC_CAMERA_PIPE, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                           FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, NULL);
    if (p == INVALID_HANDLE_VALUE) return;
    rdc_camera_want want = {RDC_CAMERA_WANT, s->width, s->height, kFps};
    OVERLAPPED ov;
    memset(&ov, 0, sizeof ov);
    ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    DWORD n = 0;
    BOOL ok = ov.hEvent && (WriteFile(p, &want, sizeof want, NULL, &ov) || GetLastError() == ERROR_IO_PENDING) &&
              GetOverlappedResult(p, &ov, &n, TRUE) && n == sizeof want;
    if (ov.hEvent) CloseHandle(ov.hEvent);
    if (!ok) {
        CloseHandle(p);
        return;
    }
    s->pipe = p;
    s->got = 0;
    s->in_payload = 0;
}

// Starts reading the rest of the header or of the frame.
static void pipe_read(Stream *s) {
    uint8_t *dst;
    size_t want;
    if (!s->in_payload) {
        dst = (uint8_t *)&s->hdr + s->got;
        want = sizeof s->hdr - s->got;
    } else {
        dst = s->incoming + s->got;
        want = s->hdr.size - s->got;
    }
    memset(&s->ov, 0, sizeof s->ov);
    s->ov.hEvent = s->read_done;
    ResetEvent(s->read_done);
    if (ReadFile(s->pipe, dst, (DWORD)want, NULL, &s->ov) || GetLastError() == ERROR_IO_PENDING) {
        s->reading = 1;
        return;
    }
    pipe_close(s);
}

static void pipe_read_done(Stream *s) {
    DWORD n = 0;
    s->reading = 0;
    if (!GetOverlappedResult(s->pipe, &s->ov, &n, FALSE) || n == 0) {
        pipe_close(s);
        return;
    }
    s->got += n;
    if (!s->in_payload) {
        if (s->got < sizeof s->hdr) return;
        s->got = 0;
        if (s->hdr.magic != RDC_CAMERA_FRAME) return pipe_close(s);
        if (s->hdr.size == 0) {  // the phone's camera is off
            s->have_frame = 0;
            return;
        }
        // Frames of another size than this app asked for: start over.
        if (s->hdr.width != s->width || s->hdr.height != s->height || s->hdr.size != s->frame_size) return pipe_close(s);
        s->in_payload = 1;
        return;
    }
    if (s->got < s->hdr.size) return;
    uint8_t *t = s->frame;
    s->frame = s->incoming;
    s->incoming = t;
    s->have_frame = 1;
    s->in_payload = 0;
    s->got = 0;
}

// The latest frame, or the dark one, into an NV12 buffer with this pitch.
static void fill(Stream *s, BYTE *dst, LONG pitch) {
    UINT32 w = s->width, h = s->height;
    for (UINT32 y = 0; y < h; y++) {
        BYTE *row = dst + (LONG_PTR)y * pitch;
        if (s->have_frame)
            memcpy(row, s->frame + (size_t)y * w, w);
        else
            memset(row, 16, w);
    }
    BYTE *uv = dst + (LONG_PTR)h * pitch;  // NV12: the interleaved chroma plane follows the luma
    for (UINT32 y = 0; y < h / 2; y++) {
        BYTE *row = uv + (LONG_PTR)y * pitch;
        if (s->have_frame)
            memcpy(row, s->frame + (size_t)w * h + (size_t)y * w, w);
        else
            memset(row, 128, w);
    }
}

static int requests_waiting(Stream *s) {
    AcquireSRWLockShared(&s->lock);
    int n = s->state == MF_STREAM_STATE_RUNNING ? s->pending : 0;
    ReleaseSRWLockShared(&s->lock);
    return n;
}

// Answers the oldest request with a sample of the current frame.
static void deliver(Stream *s) {
    IUnknown *token = NULL;
    AcquireSRWLockExclusive(&s->lock);
    int have = s->state == MF_STREAM_STATE_RUNNING && s->pending > 0;
    if (have) {
        token = s->tokens[s->head];
        s->head = (s->head + 1) % kMaxRequests;
        s->pending--;
    }
    IMFMediaEventQueue *q = have && !s->shut ? s->queue : NULL;
    if (q) IMFMediaEventQueue_AddRef(q);
    ReleaseSRWLockExclusive(&s->lock);
    if (!have) return;

    IMFSample *sample = NULL;
    IMFMediaBuffer *buf = NULL;
    IMF2DBuffer *buf2d = NULL;
    HRESULT hr = MFCreateSample(&sample);
    if (SUCCEEDED(hr)) hr = MFCreate2DMediaBuffer(s->width, s->height, kFourccNV12, FALSE, &buf);
    if (SUCCEEDED(hr)) hr = IMFMediaBuffer_QueryInterface(buf, &IID_IMF2DBuffer, (void **)&buf2d);
    if (SUCCEEDED(hr)) {
        DWORD length = 0;
        hr = IMF2DBuffer_GetContiguousLength(buf2d, &length);
        if (SUCCEEDED(hr) && length < s->frame_size) hr = E_UNEXPECTED;
        BYTE *scan0 = NULL;
        LONG pitch = 0;
        if (SUCCEEDED(hr)) hr = IMF2DBuffer_Lock2D(buf2d, &scan0, &pitch);
        if (SUCCEEDED(hr)) {
            if (pitch >= (LONG)s->width)
                fill(s, scan0, pitch);
            else
                hr = E_UNEXPECTED;
            IMF2DBuffer_Unlock2D(buf2d);
        }
        if (SUCCEEDED(hr)) hr = IMFMediaBuffer_SetCurrentLength(buf, length);
    }
    if (SUCCEEDED(hr)) hr = IMFSample_AddBuffer(sample, buf);
    if (SUCCEEDED(hr)) hr = IMFSample_SetSampleTime(sample, MFGetSystemTime());
    if (SUCCEEDED(hr)) hr = IMFSample_SetSampleDuration(sample, 10000000 / kFps);
    if (SUCCEEDED(hr) && token) hr = IMFSample_SetUnknown(sample, &MFSampleExtension_Token, token);
    if (q) {
        if (SUCCEEDED(hr))
            IMFMediaEventQueue_QueueEventParamUnk(q, MEMediaSample, &kGUID_NULL, S_OK, (IUnknown *)sample);
        else
            IMFMediaEventQueue_QueueEventParamVar(q, MEError, &kGUID_NULL, hr, NULL);
        IMFMediaEventQueue_Release(q);
    }
    if (buf2d) IMF2DBuffer_Release(buf2d);
    if (buf) IMFMediaBuffer_Release(buf);
    if (sample) IMFSample_Release(sample);
    if (token) IUnknown_Release(token);
}

static DWORD WINAPI worker_main(LPVOID arg) {
    Stream *s = arg;
    const LONGLONG freq = qpf(), interval = freq / kFps;
    LONGLONG next_frame = qpc(), next_connect = 0;
    s->have_frame = 0;
    s->reading = 0;
    for (;;) {
        LONGLONG now = qpc();
        if (s->pipe == INVALID_HANDLE_VALUE && now >= next_connect) {
            pipe_connect(s);
            next_connect = now + freq;  // once a second while RDC is away
        }
        if (s->pipe != INVALID_HANDLE_VALUE && !s->reading) pipe_read(s);
        int waiting = requests_waiting(s);
        if (waiting && now >= next_frame) {
            deliver(s);
            next_frame = next_frame + interval > now ? next_frame + interval : now + interval;
            continue;
        }
        LONGLONG until = waiting ? next_frame : s->pipe == INVALID_HANDLE_VALUE ? next_connect : now + freq;
        DWORD timeout = until > now ? (DWORD)((until - now) * 1000 / freq) + 1 : 0;
        HANDLE waits[3] = {s->stop, s->wake, s->read_done};
        DWORD r = WaitForMultipleObjects(s->reading ? 3 : 2, waits, FALSE, timeout);
        if (r == WAIT_OBJECT_0) break;
        if (r == WAIT_OBJECT_0 + 2) pipe_read_done(s);
    }
    pipe_close(s);
    st_Release(s);
    return 0;
}

// ---------------------------------------------------------------------------
// The activation object: the class registered for the virtual camera. The Frame Server copies the
// camera's attributes into its store, then activates the media source.

typedef struct Activate {
    IMFActivate iface;
    LONG refs;
    SRWLOCK lock;
    IMFAttributes *attrs;
    Source *source;
} Activate;

#define ATTRS(This) (((Activate *)(This))->attrs)

static HRESULT STDMETHODCALLTYPE ac_QueryInterface(IMFActivate *This, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualGUID(riid, &kIID_IUnknown) || IsEqualGUID(riid, &IID_IMFAttributes) || IsEqualGUID(riid, &IID_IMFActivate)) {
        *ppv = This;
        InterlockedIncrement(&((Activate *)This)->refs);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE ac_AddRef(IMFActivate *This) { return (ULONG)InterlockedIncrement(&((Activate *)This)->refs); }

static ULONG STDMETHODCALLTYPE ac_Release(IMFActivate *This) {
    Activate *a = (Activate *)This;
    LONG n = InterlockedDecrement(&a->refs);
    if (n == 0) {
        if (a->source) source_release(a->source);
        if (a->attrs) IMFAttributes_Release(a->attrs);
        free(a);
        InterlockedDecrement(&g_objects);
    }
    return (ULONG)n;
}

// IMFAttributes: the store.
static HRESULT STDMETHODCALLTYPE ac_GetItem(IMFActivate *This, REFGUID k, PROPVARIANT *v) { return IMFAttributes_GetItem(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_GetItemType(IMFActivate *This, REFGUID k, MF_ATTRIBUTE_TYPE *t) { return IMFAttributes_GetItemType(ATTRS(This), k, t); }
static HRESULT STDMETHODCALLTYPE ac_CompareItem(IMFActivate *This, REFGUID k, REFPROPVARIANT v, WINBOOL *r) { return IMFAttributes_CompareItem(ATTRS(This), k, v, r); }
static HRESULT STDMETHODCALLTYPE ac_Compare(IMFActivate *This, IMFAttributes *theirs, MF_ATTRIBUTES_MATCH_TYPE m, WINBOOL *r) { return IMFAttributes_Compare(ATTRS(This), theirs, m, r); }
static HRESULT STDMETHODCALLTYPE ac_GetUINT32(IMFActivate *This, REFGUID k, UINT32 *v) { return IMFAttributes_GetUINT32(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_GetUINT64(IMFActivate *This, REFGUID k, UINT64 *v) { return IMFAttributes_GetUINT64(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_GetDouble(IMFActivate *This, REFGUID k, double *v) { return IMFAttributes_GetDouble(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_GetGUID(IMFActivate *This, REFGUID k, GUID *v) { return IMFAttributes_GetGUID(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_GetStringLength(IMFActivate *This, REFGUID k, UINT32 *n) { return IMFAttributes_GetStringLength(ATTRS(This), k, n); }
static HRESULT STDMETHODCALLTYPE ac_GetString(IMFActivate *This, REFGUID k, LPWSTR v, UINT32 cap, UINT32 *n) { return IMFAttributes_GetString(ATTRS(This), k, v, cap, n); }
static HRESULT STDMETHODCALLTYPE ac_GetAllocatedString(IMFActivate *This, REFGUID k, LPWSTR *v, UINT32 *n) { return IMFAttributes_GetAllocatedString(ATTRS(This), k, v, n); }
static HRESULT STDMETHODCALLTYPE ac_GetBlobSize(IMFActivate *This, REFGUID k, UINT32 *n) { return IMFAttributes_GetBlobSize(ATTRS(This), k, n); }
static HRESULT STDMETHODCALLTYPE ac_GetBlob(IMFActivate *This, REFGUID k, UINT8 *v, UINT32 cap, UINT32 *n) { return IMFAttributes_GetBlob(ATTRS(This), k, v, cap, n); }
static HRESULT STDMETHODCALLTYPE ac_GetAllocatedBlob(IMFActivate *This, REFGUID k, UINT8 **v, UINT32 *n) { return IMFAttributes_GetAllocatedBlob(ATTRS(This), k, v, n); }
static HRESULT STDMETHODCALLTYPE ac_GetUnknown(IMFActivate *This, REFGUID k, REFIID riid, LPVOID *v) { return IMFAttributes_GetUnknown(ATTRS(This), k, riid, v); }
static HRESULT STDMETHODCALLTYPE ac_SetItem(IMFActivate *This, REFGUID k, REFPROPVARIANT v) { return IMFAttributes_SetItem(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_DeleteItem(IMFActivate *This, REFGUID k) { return IMFAttributes_DeleteItem(ATTRS(This), k); }
static HRESULT STDMETHODCALLTYPE ac_DeleteAllItems(IMFActivate *This) { return IMFAttributes_DeleteAllItems(ATTRS(This)); }
static HRESULT STDMETHODCALLTYPE ac_SetUINT32(IMFActivate *This, REFGUID k, UINT32 v) { return IMFAttributes_SetUINT32(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_SetUINT64(IMFActivate *This, REFGUID k, UINT64 v) { return IMFAttributes_SetUINT64(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_SetDouble(IMFActivate *This, REFGUID k, double v) { return IMFAttributes_SetDouble(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_SetGUID(IMFActivate *This, REFGUID k, REFGUID v) { return IMFAttributes_SetGUID(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_SetString(IMFActivate *This, REFGUID k, LPCWSTR v) { return IMFAttributes_SetString(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_SetBlob(IMFActivate *This, REFGUID k, const UINT8 *v, UINT32 n) { return IMFAttributes_SetBlob(ATTRS(This), k, v, n); }
static HRESULT STDMETHODCALLTYPE ac_SetUnknown(IMFActivate *This, REFGUID k, IUnknown *v) { return IMFAttributes_SetUnknown(ATTRS(This), k, v); }
static HRESULT STDMETHODCALLTYPE ac_LockStore(IMFActivate *This) { return IMFAttributes_LockStore(ATTRS(This)); }
static HRESULT STDMETHODCALLTYPE ac_UnlockStore(IMFActivate *This) { return IMFAttributes_UnlockStore(ATTRS(This)); }
static HRESULT STDMETHODCALLTYPE ac_GetCount(IMFActivate *This, UINT32 *n) { return IMFAttributes_GetCount(ATTRS(This), n); }
static HRESULT STDMETHODCALLTYPE ac_GetItemByIndex(IMFActivate *This, UINT32 i, GUID *k, PROPVARIANT *v) { return IMFAttributes_GetItemByIndex(ATTRS(This), i, k, v); }
static HRESULT STDMETHODCALLTYPE ac_CopyAllItems(IMFActivate *This, IMFAttributes *dst) { return IMFAttributes_CopyAllItems(ATTRS(This), dst); }

// The media source, made once and handed out again until it is shut down or detached.
static HRESULT STDMETHODCALLTYPE ac_ActivateObject(IMFActivate *This, REFIID riid, void **ppv) {
    Activate *a = (Activate *)This;
    if (!ppv) return E_POINTER;
    *ppv = NULL;
    HRESULT hr = S_OK;
    AcquireSRWLockExclusive(&a->lock);
    if (a->source && source_is_shut(a->source)) {
        source_release(a->source);
        a->source = NULL;
    }
    if (!a->source) hr = source_create(a->attrs, &a->source);
    if (SUCCEEDED(hr)) hr = source_qi(a->source, riid, ppv);
    ReleaseSRWLockExclusive(&a->lock);
    return hr;
}

static HRESULT STDMETHODCALLTYPE ac_ShutdownObject(IMFActivate *This) { return S_OK; }

static HRESULT STDMETHODCALLTYPE ac_DetachObject(IMFActivate *This) {
    Activate *a = (Activate *)This;
    AcquireSRWLockExclusive(&a->lock);
    Source *s = a->source;
    a->source = NULL;
    ReleaseSRWLockExclusive(&a->lock);
    if (s) source_release(s);
    return S_OK;
}

static IMFActivateVtbl kActivateVtbl = {
    .QueryInterface = ac_QueryInterface,
    .AddRef = ac_AddRef,
    .Release = ac_Release,
    .GetItem = ac_GetItem,
    .GetItemType = ac_GetItemType,
    .CompareItem = ac_CompareItem,
    .Compare = ac_Compare,
    .GetUINT32 = ac_GetUINT32,
    .GetUINT64 = ac_GetUINT64,
    .GetDouble = ac_GetDouble,
    .GetGUID = ac_GetGUID,
    .GetStringLength = ac_GetStringLength,
    .GetString = ac_GetString,
    .GetAllocatedString = ac_GetAllocatedString,
    .GetBlobSize = ac_GetBlobSize,
    .GetBlob = ac_GetBlob,
    .GetAllocatedBlob = ac_GetAllocatedBlob,
    .GetUnknown = ac_GetUnknown,
    .SetItem = ac_SetItem,
    .DeleteItem = ac_DeleteItem,
    .DeleteAllItems = ac_DeleteAllItems,
    .SetUINT32 = ac_SetUINT32,
    .SetUINT64 = ac_SetUINT64,
    .SetDouble = ac_SetDouble,
    .SetGUID = ac_SetGUID,
    .SetString = ac_SetString,
    .SetBlob = ac_SetBlob,
    .SetUnknown = ac_SetUnknown,
    .LockStore = ac_LockStore,
    .UnlockStore = ac_UnlockStore,
    .GetCount = ac_GetCount,
    .GetItemByIndex = ac_GetItemByIndex,
    .CopyAllItems = ac_CopyAllItems,
    .ActivateObject = ac_ActivateObject,
    .ShutdownObject = ac_ShutdownObject,
    .DetachObject = ac_DetachObject,
};

static HRESULT activate_create(REFIID riid, void **ppv) {
    Activate *a = calloc(1, sizeof *a);
    if (!a) return E_OUTOFMEMORY;
    a->iface.lpVtbl = &kActivateVtbl;
    a->refs = 1;
    InitializeSRWLock(&a->lock);
    InterlockedIncrement(&g_objects);
    HRESULT hr = MFCreateAttributes(&a->attrs, 8);
    if (SUCCEEDED(hr)) hr = ac_QueryInterface(&a->iface, riid, ppv);
    ac_Release(&a->iface);
    return hr;
}

// ---------------------------------------------------------------------------
// The class factory and the DLL's entry points

static HRESULT STDMETHODCALLTYPE cf_QueryInterface(IClassFactory *This, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualGUID(riid, &kIID_IUnknown) || IsEqualGUID(riid, &kIID_IClassFactory)) {
        *ppv = This;
        InterlockedIncrement(&g_objects);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE cf_AddRef(IClassFactory *This) {
    InterlockedIncrement(&g_objects);
    return 2;
}
static ULONG STDMETHODCALLTYPE cf_Release(IClassFactory *This) {
    InterlockedDecrement(&g_objects);
    return 1;
}
static HRESULT STDMETHODCALLTYPE cf_CreateInstance(IClassFactory *This, IUnknown *outer, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    *ppv = NULL;
    if (outer) return CLASS_E_NOAGGREGATION;
    return activate_create(riid, ppv);
}
static HRESULT STDMETHODCALLTYPE cf_LockServer(IClassFactory *This, WINBOOL lock) {
    if (lock)
        InterlockedIncrement(&g_objects);
    else
        InterlockedDecrement(&g_objects);
    return S_OK;
}
static IClassFactoryVtbl kFactoryVtbl = {
    .QueryInterface = cf_QueryInterface,
    .AddRef = cf_AddRef,
    .Release = cf_Release,
    .CreateInstance = cf_CreateInstance,
    .LockServer = cf_LockServer,
};
static IClassFactory g_factory = {&kFactoryVtbl};

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
    return TRUE;
}

HRESULT WINAPI DllGetClassObject(REFCLSID clsid, REFIID riid, LPVOID *ppv) {
    if (!ppv) return E_POINTER;
    *ppv = NULL;
    if (!IsEqualGUID(clsid, &kCLSID_RdcCamera)) return CLASS_E_CLASSNOTAVAILABLE;
    return cf_QueryInterface(&g_factory, riid, ppv);
}

HRESULT WINAPI DllCanUnloadNow(void) { return g_objects == 0 ? S_OK : S_FALSE; }
