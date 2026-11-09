// RDC Microphone: a CoreAudio HAL plug-in (AudioServerPlugIn) with one input-only device that
// plays the samples RDC.app writes into shared memory (mic_shm.h). Written from Apple's
// AudioServerPlugIn documentation (CoreAudio/AudioServerPlugIn.h), no code from other drivers.
// Zig compiles it into RDC.app/Contents/Resources/RDCMicrophone.driver; "Enable phone microphone"
// copies the bundle to /Library/Audio/Plug-Ins/HAL and restarts coreaudiod, which loads it.
//
// Objects: the plug-in (kAudioObjectPlugInObject), the device (2) and its input stream (3). The
// device runs at 48 kHz, one channel, Float32 toward the apps; its clock is mach_absolute_time().
// The IO thread touches only the ring in shared memory and a few atomics — nothing that blocks.
// The sandbox of coreaudiod allows POSIX shared memory; the plug-in opens the segment read-only,
// so RDC.app can create it with mode 0644 and the plug-in needs nothing of its own.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "mic_shm.h"

enum { kObjectID_Device = 2, kObjectID_Stream = 3 };
#define kDevice_UID "com.anods.rdc.mic"
#define kDevice_ModelUID "com.anods.rdc.mic:1"
#define kDevice_Name "RDC Microphone"
#define kManufacturer "RDC"
#define kBundleID "com.anods.rdc.microphone"
enum { kSampleRate = RDC_MIC_RATE, kRingBufferFrames = 16384 };  // ZeroTimeStampPeriod: at least 10923 frames
// The cushion against network jitter: play once this much is buffered, go back to the target
// when more than the high mark piles up (the phone's clock runs a little faster than ours).
enum { kStartFrames = 2880 /* 60 ms */, kTargetFrames = 4800 /* 100 ms */, kHighFrames = 14400 /* 300 ms */ };
enum { kRetryShmEveryUs = 500000 };

// ---------------------------------------------------------------------------
// State

static AudioServerPlugInHostRef gHost;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;  // ref count, IO count, the clock
static UInt32 gRefCount;
static UInt32 gIORunning;  // StartIO calls minus StopIO calls
static Float64 gHostTicksPerFrame;
static UInt64 gAnchorHostTime;
static UInt64 gTimeStamps;  // zero time stamps handed out since the anchor
static _Atomic UInt32 gStreamActive = 1;

// The shared memory, mapped once and kept. Reader state lives on the IO thread.
static _Atomic(void *) gShm;
static uint64_t gReadPos;
static uint64_t gGeneration;
static int gFlowing;
static uint64_t gLastShmTry;
static _Atomic uint64_t gUnderruns, gSkips;  // for the test harness (custom property "stat")

static void lock_state(void) { pthread_mutex_lock(&gStateMutex); }
static void unlock_state(void) { pthread_mutex_unlock(&gStateMutex); }

static uint64_t host_us(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom / 1000;
}

// Maps the segment RDC.app created, if it exists and has our layout. 1 — mapped.
static int shm_try_map(void) {
    if (atomic_load_explicit(&gShm, memory_order_acquire)) return 1;
    int fd = shm_open(RDC_MIC_SHM_NAME, O_RDONLY, 0);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)RDC_MIC_SHM_SIZE) {
        close(fd);
        return 0;
    }
    void *p = mmap(NULL, RDC_MIC_SHM_SIZE, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return 0;
    const rdc_mic_header *h = (const rdc_mic_header *)p;
    if (h->magic != RDC_MIC_MAGIC || h->version != RDC_MIC_VERSION || h->ring_frames != RDC_MIC_RING_FRAMES) {
        munmap(p, RDC_MIC_SHM_SIZE);
        return 0;
    }
    void *expected = NULL;
    if (!atomic_compare_exchange_strong(&gShm, &expected, p)) munmap(p, RDC_MIC_SHM_SIZE);
    return 1;
}

// Fills an IO buffer from the ring, on the IO thread.
static void read_input(Float32 *out, UInt32 frames) {
    void *shm = atomic_load_explicit(&gShm, memory_order_acquire);
    if (!shm) {
        // RDC.app has not created the segment yet (it is not running, or no microphone has been
        // lent): look again now and then — a few microseconds twice a second.
        uint64_t now = host_us();
        if (now - gLastShmTry >= kRetryShmEveryUs) {
            gLastShmTry = now;
            if (shm_try_map()) shm = atomic_load_explicit(&gShm, memory_order_acquire);
        }
        if (!shm) {
            memset(out, 0, frames * sizeof(Float32));
            return;
        }
    }
    const rdc_mic_header *h = (const rdc_mic_header *)shm;
    const int16_t *ring = rdc_mic_samples(shm);
    uint64_t gen = atomic_load_explicit(&h->generation, memory_order_acquire);
    uint64_t wpos = atomic_load_explicit(&h->write_pos, memory_order_acquire);
    if (gen != gGeneration || wpos < gReadPos) {  // a new stream, or the writer started counting again
        gGeneration = gen;
        gReadPos = wpos;
        gFlowing = 0;
    }
    uint64_t avail = wpos - gReadPos;
    if (avail > kHighFrames) {  // too far behind (a stall, a fast clock): play the newest target's worth
        gReadPos = wpos - kTargetFrames;
        avail = kTargetFrames;
        atomic_fetch_add_explicit(&gSkips, 1, memory_order_relaxed);
    }
    if (!gFlowing) {
        if (avail < kStartFrames) {
            memset(out, 0, frames * sizeof(Float32));
            return;
        }
        gFlowing = 1;
    }
    UInt32 n = avail < frames ? (UInt32)avail : frames;
    for (UInt32 i = 0; i < n; i++) out[i] = (Float32)ring[(gReadPos + i) & (RDC_MIC_RING_FRAMES - 1)] * (1.0f / 32768.0f);
    gReadPos += n;
    if (n < frames) {
        memset(out + n, 0, (frames - n) * sizeof(Float32));
        gFlowing = 0;  // underrun: wait for a fresh cushion
        atomic_fetch_add_explicit(&gUnderruns, 1, memory_order_relaxed);
    }
}

static AudioStreamBasicDescription stream_format(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    f.mBytesPerPacket = 4;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4;
    f.mChannelsPerFrame = 1;
    f.mBitsPerChannel = 32;
    return f;
}

static Boolean same_format(const AudioStreamBasicDescription *a) {
    AudioStreamBasicDescription f = stream_format();
    return a->mSampleRate == f.mSampleRate && a->mFormatID == f.mFormatID && a->mFormatFlags == f.mFormatFlags &&
           a->mBytesPerPacket == f.mBytesPerPacket && a->mFramesPerPacket == f.mFramesPerPacket &&
           a->mBytesPerFrame == f.mBytesPerFrame && a->mChannelsPerFrame == f.mChannelsPerFrame &&
           a->mBitsPerChannel == f.mBitsPerChannel;
}

// ---------------------------------------------------------------------------
// Property answers. A query for the size passes out == NULL; arrays return as many items as fit.

typedef struct {
    void *out;
    UInt32 cap;
    UInt32 *size;
} Answer;

static OSStatus put(Answer *a, const void *src, UInt32 n) {
    *a->size = n;
    if (!a->out) return 0;
    if (a->cap < n) return kAudioHardwareBadPropertySizeError;
    if (n > 0) memcpy(a->out, src, n);
    return 0;
}

static OSStatus put_u32(Answer *a, UInt32 v) { return put(a, &v, sizeof v); }
static OSStatus put_f64(Answer *a, Float64 v) { return put(a, &v, sizeof v); }

// The caller (the host) releases the string.
static OSStatus put_str(Answer *a, const char *s) {
    *a->size = sizeof(CFStringRef);
    if (!a->out) return 0;
    if (a->cap < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
    *(CFStringRef *)a->out = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    return 0;
}

static OSStatus put_items(Answer *a, const void *items, UInt32 count, UInt32 item_size) {
    if (!a->out) {
        *a->size = count * item_size;
        return 0;
    }
    UInt32 n = a->cap / item_size;
    if (n > count) n = count;
    if (n > 0) memcpy(a->out, items, n * item_size);  // items is NULL for an empty list
    *a->size = n * item_size;
    return 0;
}

static OSStatus put_ids(Answer *a, const AudioObjectID *ids, UInt32 count) { return put_items(a, ids, count, sizeof(AudioObjectID)); }

static Boolean is_input_or_global(AudioObjectPropertyScope s) { return s == kAudioObjectPropertyScopeGlobal || s == kAudioObjectPropertyScopeInput; }

// Each object: does it have the property; is it settable; its value. `has` doubles as the list.
static Boolean plugin_has(const AudioObjectPropertyAddress *p) {
    switch (p->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyBoxList:
    case kAudioPlugInPropertyTranslateUIDToBox: case kAudioPlugInPropertyDeviceList:
    case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyResourceBundle: case kAudioPlugInPropertyBundleID:
        return true;
    default: return false;
    }
}

static OSStatus plugin_get(const AudioObjectPropertyAddress *p, UInt32 qsize, const void *qual, Answer *a) {
    static const AudioObjectID device = kObjectID_Device;
    switch (p->mSelector) {
    case kAudioObjectPropertyBaseClass: return put_u32(a, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return put_u32(a, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: return put_u32(a, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: return put_str(a, kManufacturer);
    case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: return put_ids(a, &device, 1);
    case kAudioPlugInPropertyBoxList: return put_ids(a, NULL, 0);
    case kAudioPlugInPropertyTranslateUIDToBox: return put_u32(a, kAudioObjectUnknown);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID id = kAudioObjectUnknown;
        if (qsize == sizeof(CFStringRef) && qual && *(CFStringRef *)qual) {
            CFStringRef uid = CFStringCreateWithCString(NULL, kDevice_UID, kCFStringEncodingUTF8);
            if (CFStringCompare(*(CFStringRef *)qual, uid, 0) == kCFCompareEqualTo) id = kObjectID_Device;
            CFRelease(uid);
        }
        return put_u32(a, id);
    }
    case kAudioPlugInPropertyResourceBundle: return put_str(a, "");
    case kAudioPlugInPropertyBundleID: return put_str(a, kBundleID);
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static Boolean device_has(const AudioObjectPropertyAddress *p) {
    switch (p->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
    case kAudioObjectPropertyIdentify: case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID:
    case kAudioDevicePropertyTransportType: case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyLatency: case kAudioDevicePropertyStreams: case kAudioObjectPropertyControlList:
    case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyNominalSampleRate:
    case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyPreferredChannelLayout:
    case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyClockAlgorithm: case kAudioDevicePropertyClockIsStable:
    case kAudioObjectPropertyCustomPropertyInfoList:
        return true;
    default: return false;
    }
}

// "stat": underruns and skips as a CFString "<underruns> <skips>" — the test harness reads it.
enum { kRDCPropertyStat = 'stat' };

static OSStatus device_get(const AudioObjectPropertyAddress *p, Answer *a) {
    static const AudioObjectID device = kObjectID_Device, stream = kObjectID_Stream;
    switch (p->mSelector) {
    case kAudioObjectPropertyBaseClass: return put_u32(a, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return put_u32(a, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: return put_u32(a, kAudioObjectPlugInObject);
    case kAudioObjectPropertyName: return put_str(a, kDevice_Name);
    case kAudioObjectPropertyManufacturer: return put_str(a, kManufacturer);
    case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams:
        return put_ids(a, &stream, is_input_or_global(p->mScope) ? 1 : 0);
    case kAudioObjectPropertyIdentify: return put_u32(a, 0);
    case kAudioDevicePropertyDeviceUID: return put_str(a, kDevice_UID);
    case kAudioDevicePropertyModelUID: return put_str(a, kDevice_ModelUID);
    case kAudioDevicePropertyTransportType: return put_u32(a, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: return put_ids(a, &device, 1);
    case kAudioDevicePropertyClockDomain: return put_u32(a, 0);
    case kAudioDevicePropertyDeviceIsAlive: return put_u32(a, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        lock_state();
        UInt32 running = gIORunning > 0;
        unlock_state();
        return put_u32(a, running);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: return put_u32(a, p->mScope == kAudioObjectPropertyScopeInput);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return put_u32(a, 0);
    case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset: return put_u32(a, 0);
    case kAudioObjectPropertyControlList: return put_ids(a, NULL, 0);
    case kAudioDevicePropertyNominalSampleRate: return put_f64(a, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange r = {kSampleRate, kSampleRate};
        return put_items(a, &r, 1, sizeof r);
    }
    case kAudioDevicePropertyIsHidden: return put_u32(a, 0);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        UInt32 ch[2] = {1, 1};
        return put(a, ch, sizeof ch);
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt8 buf[offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription)];
        memset(buf, 0, sizeof buf);
        AudioChannelLayout *l = (AudioChannelLayout *)buf;
        l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        l->mNumberChannelDescriptions = 1;
        l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
        return put(a, buf, sizeof buf);
    }
    case kAudioDevicePropertyZeroTimeStampPeriod: return put_u32(a, kRingBufferFrames);
    case kAudioDevicePropertyClockAlgorithm: return put_u32(a, kAudioDeviceClockAlgorithmSimpleIIR);
    case kAudioDevicePropertyClockIsStable: return put_u32(a, 1);
    case kAudioObjectPropertyCustomPropertyInfoList: {
        AudioServerPlugInCustomPropertyInfo info = {kRDCPropertyStat, kAudioServerPlugInCustomPropertyDataTypeCFString, kAudioServerPlugInCustomPropertyDataTypeNone};
        return put_items(a, &info, 1, sizeof info);
    }
    case kRDCPropertyStat: {
        char s[64];
        snprintf(s, sizeof s, "%llu %llu", (unsigned long long)atomic_load(&gUnderruns), (unsigned long long)atomic_load(&gSkips));
        return put_str(a, s);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static Boolean stream_has(const AudioObjectPropertyAddress *p) {
    switch (p->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        return true;
    default: return false;
    }
}

static OSStatus stream_get(const AudioObjectPropertyAddress *p, Answer *a) {
    switch (p->mSelector) {
    case kAudioObjectPropertyBaseClass: return put_u32(a, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return put_u32(a, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: return put_u32(a, kObjectID_Device);
    case kAudioObjectPropertyName: return put_str(a, kDevice_Name);
    case kAudioStreamPropertyIsActive: return put_u32(a, atomic_load(&gStreamActive));
    case kAudioStreamPropertyDirection: return put_u32(a, 1);  // input
    case kAudioStreamPropertyTerminalType: return put_u32(a, kAudioStreamTerminalTypeMicrophone);
    case kAudioStreamPropertyStartingChannel: return put_u32(a, 1);
    case kAudioStreamPropertyLatency: return put_u32(a, 0);
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
        AudioStreamBasicDescription f = stream_format();
        return put(a, &f, sizeof f);
    }
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription r;
        r.mFormat = stream_format();
        r.mSampleRateRange.mMinimum = kSampleRate;
        r.mSampleRateRange.mMaximum = kSampleRate;
        return put_items(a, &r, 1, sizeof r);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static Boolean settable(AudioObjectID obj, const AudioObjectPropertyAddress *p) {
    if (obj == kObjectID_Device)
        return p->mSelector == kAudioDevicePropertyNominalSampleRate || p->mSelector == kAudioObjectPropertyIdentify;
    if (obj == kObjectID_Stream)
        return p->mSelector == kAudioStreamPropertyIsActive || p->mSelector == kAudioStreamPropertyVirtualFormat ||
               p->mSelector == kAudioStreamPropertyPhysicalFormat;
    return false;
}

// ---------------------------------------------------------------------------
// The driver interface

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (!outInterface) return E_POINTER;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    Boolean ok = uuid && (CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID));
    if (uuid) CFRelease(uuid);
    if (!ok) {
        *outInterface = NULL;
        return E_NOINTERFACE;
    }
    lock_state();
    gRefCount++;
    unlock_state();
    *outInterface = gDriverRef;
    return S_OK;
}

static ULONG AddRef(void *inDriver) {
    lock_state();
    ULONG n = ++gRefCount;
    unlock_state();
    return n;
}

static ULONG Release(void *inDriver) {
    lock_state();
    ULONG n = gRefCount > 0 ? --gRefCount : 0;
    unlock_state();
    return n;  // static storage: nothing to free
}

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    gHost = inHost;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 host_hz = (Float64)tb.denom / (Float64)tb.numer * 1000000000.0;
    gHostTicksPerFrame = host_hz / (Float64)kSampleRate;
    shm_try_map();  // RDC.app may already be running
    return 0;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) { return 0; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) { return 0; }
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) { return 0; }
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) { return 0; }

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *p) {
    if (!p) return false;
    switch (obj) {
    case kAudioObjectPlugInObject: return plugin_has(p);
    case kObjectID_Device: return device_has(p) || p->mSelector == kRDCPropertyStat;
    case kObjectID_Stream: return stream_has(p);
    default: return false;
    }
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *p, Boolean *out) {
    if (!p || !out) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, obj, pid, p)) return kAudioHardwareUnknownPropertyError;
    *out = settable(obj, p);
    return 0;
}

static OSStatus get_property(AudioObjectID obj, const AudioObjectPropertyAddress *p, UInt32 qsize, const void *qual, Answer *a) {
    switch (obj) {
    case kAudioObjectPlugInObject: return plugin_get(p, qsize, qual, a);
    case kObjectID_Device: return device_get(p, a);
    case kObjectID_Stream: return stream_get(p, a);
    default: return kAudioHardwareBadObjectError;
    }
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *p, UInt32 qsize, const void *qual, UInt32 *out) {
    if (!p || !out) return kAudioHardwareIllegalOperationError;
    Answer a = {NULL, 0, out};
    return get_property(obj, p, qsize, qual, &a);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *p, UInt32 qsize, const void *qual, UInt32 cap, UInt32 *out_size, void *out) {
    if (!p || !out_size || !out) return kAudioHardwareIllegalOperationError;
    Answer a = {out, cap, out_size};
    return get_property(obj, p, qsize, qual, &a);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *p, UInt32 qsize, const void *qual, UInt32 size, const void *data) {
    if (!p || !data) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, obj, pid, p)) return kAudioHardwareUnknownPropertyError;
    if (!settable(obj, p)) return kAudioHardwareUnsupportedOperationError;
    switch (p->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
        if (size < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)data == (Float64)kSampleRate ? 0 : kAudioHardwareIllegalOperationError;
    case kAudioObjectPropertyIdentify: return 0;
    case kAudioStreamPropertyIsActive:
        if (size < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        atomic_store(&gStreamActive, *(const UInt32 *)data != 0);
        return 0;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        if (size < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        return same_format((const AudioStreamBasicDescription *)data) ? 0 : kAudioDeviceUnsupportedFormatError;
    default: return kAudioHardwareUnsupportedOperationError;
    }
}

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    lock_state();
    if (gIORunning == 0) {
        gTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        gFlowing = 0;
        shm_try_map();
        void *shm = atomic_load_explicit(&gShm, memory_order_acquire);
        if (shm) {  // start from the newest samples, with a fresh cushion
            const rdc_mic_header *h = (const rdc_mic_header *)shm;
            gGeneration = atomic_load_explicit(&h->generation, memory_order_acquire);
            gReadPos = atomic_load_explicit(&h->write_pos, memory_order_acquire);
        }
    }
    gIORunning++;
    unlock_state();
    return 0;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    lock_state();
    if (gIORunning > 0) gIORunning--;
    unlock_state();
    return 0;
}

// The device's time line: sample time advances by kRingBufferFrames each period of the host
// clock; the host maps it to mach_absolute_time() through these pairs.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    lock_state();
    UInt64 now = mach_absolute_time();
    Float64 ticks_per_ring = gHostTicksPerFrame * (Float64)kRingBufferFrames;
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gTimeStamps + 1) * ticks_per_ring);
    if (next <= now) gTimeStamps++;
    *outSampleTime = (Float64)gTimeStamps * (Float64)kRingBufferFrames;
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimeStamps * ticks_per_ring);
    *outSeed = 1;
    unlock_state();
    return 0;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean *will, Boolean *in_place) {
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    *will = op == kAudioServerPlugInIOOperationReadInput;
    *in_place = true;
    return 0;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) { return 0; }
static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) { return 0; }

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *main_buf, void *secondary_buf) {
    if (id != kObjectID_Device || stream != kObjectID_Stream) return kAudioHardwareBadObjectError;
    if (op == kAudioServerPlugInIOOperationReadInput && main_buf) read_input((Float32 *)main_buf, frames);
    return 0;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface, AddRef, Release,
    Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformDeviceConfigurationChange, AbortDeviceConfigurationChange,
    HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
    StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation,
};

// The CFPlugIn factory named in Info.plist: coreaudiod asks for kAudioServerPlugInTypeUUID.
void *RDCMicrophoneFactory(CFAllocatorRef allocator, CFUUIDRef requested_type) {
    if (!requested_type || !CFEqual(requested_type, kAudioServerPlugInTypeUUID)) return NULL;
    lock_state();
    gRefCount++;
    unlock_state();
    return gDriverRef;
}
