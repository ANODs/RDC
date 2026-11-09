// Checks RDCMicrophone.driver the way coreaudiod would use it, without installing it: loads the
// bundle through CFPlugIn, plays the host (Initialize, properties, StartIO, IO cycles) and the
// writer (the same shared memory RDC.app writes, mic_writer.h), and compares what comes out.
// `zig build mic-check` builds and runs it. Uses the real segment name, so run it while no
// viewer lends a microphone to RDC.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "mic_writer.h"

static int failures;

#define CHECK(cond, ...)                                      \
    do {                                                      \
        if (!(cond)) {                                        \
            failures++;                                       \
            fprintf(stderr, "mic-check: FAIL line %d: ", __LINE__); \
            fprintf(stderr, __VA_ARGS__);                     \
            fprintf(stderr, "\n");                            \
        }                                                     \
    } while (0)

// The host's side of the interface: the plug-in never calls these in this test, but they must exist.
static OSStatus host_changed(AudioServerPlugInHostRef h, AudioObjectID id, UInt32 n, const AudioObjectPropertyAddress *a) { return 0; }
static OSStatus host_copy(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *out) { *out = NULL; return 0; }
static OSStatus host_write(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { return 0; }
static OSStatus host_delete(AudioServerPlugInHostRef h, CFStringRef k) { return 0; }
static OSStatus host_request(AudioServerPlugInHostRef h, AudioObjectID id, UInt64 a, void *i) { return 0; }
static AudioServerPlugInHostInterface host = {host_changed, host_copy, host_write, host_delete, host_request};

static UInt32 get_u32(AudioServerPlugInDriverRef d, AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    UInt32 v = 0xFFFFFFFF, size = 0;
    OSStatus st = (*d)->GetPropertyData(d, obj, 0, &a, 0, NULL, sizeof v, &size, &v);
    CHECK(st == 0 && size == sizeof v, "u32 property '%c%c%c%c' of %u: status %d size %u", (char)(sel >> 24), (char)(sel >> 16), (char)(sel >> 8), (char)sel, obj, (int)st, size);
    return v;
}

static int str_is(AudioServerPlugInDriverRef d, AudioObjectID obj, AudioObjectPropertySelector sel, const char *want) {
    AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef s = NULL;
    UInt32 size = 0;
    if ((*d)->GetPropertyData(d, obj, 0, &a, 0, NULL, sizeof s, &size, &s) != 0 || !s) return 0;
    char buf[256];
    int ok = CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8) && strcmp(buf, want) == 0;
    if (!ok) fprintf(stderr, "mic-check: string property is '%s', wanted '%s'\n", buf, want);
    CFRelease(s);
    return ok;
}

// Every property the plug-in or the HAL knows, on every object and in every scope, the way
// coreaudiod and apps ask: has it, its size, its value in a buffer of that size, and in buffers
// that are too small. Built with the C sanitizer, the plug-in traps here on any undefined behaviour.
static void sweep(AudioServerPlugInDriverRef d) {
    static const AudioObjectPropertySelector sels[] = {
        kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner, kAudioObjectPropertyName,
        kAudioObjectPropertyModelName, kAudioObjectPropertyManufacturer, kAudioObjectPropertyElementName,
        kAudioObjectPropertyElementCategoryName, kAudioObjectPropertyElementNumberName, kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyIdentify, kAudioObjectPropertySerialNumber, kAudioObjectPropertyFirmwareVersion,
        kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyControlList, kAudioPlugInPropertyBundleID,
        kAudioPlugInPropertyDeviceList, kAudioPlugInPropertyTranslateUIDToDevice, kAudioPlugInPropertyBoxList,
        kAudioPlugInPropertyTranslateUIDToBox, kAudioPlugInPropertyResourceBundle, kAudioDevicePropertyDeviceUID,
        kAudioDevicePropertyModelUID, kAudioDevicePropertyTransportType, kAudioDevicePropertyRelatedDevices,
        kAudioDevicePropertyClockDomain, kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning,
        kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
        kAudioDevicePropertyLatency, kAudioDevicePropertyStreams, kAudioDevicePropertySafetyOffset,
        kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyAvailableNominalSampleRates, kAudioDevicePropertyIcon,
        kAudioDevicePropertyIsHidden, kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyPreferredChannelLayout,
        kAudioDevicePropertyZeroTimeStampPeriod, kAudioDevicePropertyClockAlgorithm, kAudioDevicePropertyClockIsStable,
        kAudioDevicePropertyConfigurationApplication, kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
        kAudioStreamPropertyTerminalType, kAudioStreamPropertyStartingChannel, kAudioStreamPropertyLatency,
        kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyPhysicalFormat,
        kAudioStreamPropertyAvailablePhysicalFormats, 'stat', 'zzzz',
    };
    static const AudioObjectID objs[] = {kAudioObjectPlugInObject, 2, 3, 4, kAudioObjectUnknown};
    static const AudioObjectPropertyScope scopes[] = {kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeInput,
                                                      kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopePlayThrough};
    CFStringRef uid = CFSTR("com.anods.rdc.mic");
    int checked = 0;
    for (size_t o = 0; o < sizeof objs / sizeof *objs; o++)
        for (size_t s = 0; s < sizeof sels / sizeof *sels; s++)
            for (size_t c = 0; c < sizeof scopes / sizeof *scopes; c++) {
                AudioObjectPropertyAddress a = {sels[s], scopes[c], kAudioObjectPropertyElementMain};
                Boolean has = (*d)->HasProperty(d, objs[o], 0, &a);
                const void *qual = NULL;
                UInt32 qsize = 0;
                if (sels[s] == kAudioPlugInPropertyTranslateUIDToDevice || sels[s] == kAudioPlugInPropertyTranslateUIDToBox) {
                    qual = &uid;
                    qsize = sizeof uid;
                }
                UInt32 size = 0xFFFF;
                OSStatus st = (*d)->GetPropertyDataSize(d, objs[o], 0, &a, qsize, qual, &size);
                Boolean settable = false;
                OSStatus sst = (*d)->IsPropertySettable(d, objs[o], 0, &a, &settable);
                if (!has) {
                    CHECK(st != 0 && sst != 0, "object %u has no '%c%c%c%c' yet answers it", objs[o], (char)(sels[s] >> 24), (char)(sels[s] >> 16), (char)(sels[s] >> 8), (char)sels[s]);
                    continue;
                }
                CHECK(st == 0 && size < 4096 && sst == 0, "object %u '%c%c%c%c': size status %d, size %u", objs[o], (char)(sels[s] >> 24), (char)(sels[s] >> 16), (char)(sels[s] >> 8), (char)sels[s], (int)st, size);
                if (st != 0 || size >= 4096) continue;
                // The exact size, then every smaller one: never more than the buffer, never a crash.
                for (UInt32 cap = size + 1; cap-- > 0;) {
                    UInt8 *buf = calloc(1, size + 16);
                    UInt32 out = 0;
                    st = (*d)->GetPropertyData(d, objs[o], 0, &a, qsize, qual, cap, &out, buf);
                    if (st == 0) {
                        CHECK(out <= cap, "object %u '%c%c%c%c': %u bytes in a %u-byte buffer", objs[o], (char)(sels[s] >> 24), (char)(sels[s] >> 16), (char)(sels[s] >> 8), (char)sels[s], out, cap);
                        // Strings and other CF objects belong to the caller now.
                        if (out == sizeof(CFTypeRef) && cap == size && (sels[s] == kAudioObjectPropertyName || sels[s] == kAudioObjectPropertyManufacturer ||
                                                                        sels[s] == kAudioDevicePropertyDeviceUID || sels[s] == kAudioDevicePropertyModelUID ||
                                                                        sels[s] == kAudioPlugInPropertyResourceBundle || sels[s] == kAudioPlugInPropertyBundleID ||
                                                                        sels[s] == 'stat')) {
                            CFTypeRef ref = *(CFTypeRef *)buf;
                            if (ref) CFRelease(ref);
                        }
                    } else {
                        CHECK(cap < size, "object %u '%c%c%c%c': status %d with the full %u-byte buffer", objs[o], (char)(sels[s] >> 24), (char)(sels[s] >> 16), (char)(sels[s] >> 8), (char)sels[s], (int)st, cap);
                    }
                    free(buf);
                    checked++;
                }
            }
    printf("mic-check: %d property reads across every object and scope\n", checked);
}

static void read_frames(AudioServerPlugInDriverRef d, Float32 *out, UInt32 frames) {
    AudioServerPlugInIOCycleInfo info;
    memset(&info, 0, sizeof info);
    OSStatus st = (*d)->DoIOOperation(d, 2, 3, 1, kAudioServerPlugInIOOperationReadInput, frames, &info, out, NULL);
    CHECK(st == 0, "DoIOOperation: %d", (int)st);
}

static int all_zero(const Float32 *b, UInt32 n) {
    for (UInt32 i = 0; i < n; i++)
        if (b[i] != 0) return 0;
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: mic_test <path to RDCMicrophone.driver>\n");
        return 2;
    }
    // Load the bundle as a CFPlugIn, the way coreaudiod does.
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], strlen(argv[1]), true);
    CFPlugInRef plugin = url ? CFPlugInCreate(NULL, url) : NULL;
    if (url) CFRelease(url);
    if (!plugin) {
        fprintf(stderr, "mic-check: cannot load %s as a plug-in\n", argv[1]);
        return 1;
    }
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    if (!factories || CFArrayGetCount(factories) == 0) {
        fprintf(stderr, "mic-check: Info.plist declares no AudioServerPlugIn factory\n");
        return 1;
    }
    CFUUIDRef factory = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);
    IUnknownVTbl **unknown = (IUnknownVTbl **)CFPlugInInstanceCreate(NULL, factory, kAudioServerPlugInTypeUUID);
    if (!unknown) {
        fprintf(stderr, "mic-check: the factory returned nothing\n");
        return 1;
    }
    AudioServerPlugInDriverRef d = NULL;
    HRESULT hr = (*unknown)->QueryInterface(unknown, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), (LPVOID *)&d);
    CHECK(hr == S_OK && d, "QueryInterface for the driver interface: %ld", (long)hr);
    if (!d) return 1;
    CHECK((*d)->Initialize(d, &host) == 0, "Initialize");
    sweep(d);

    // Objects and properties, as the HAL and apps read them.
    {
        AudioObjectPropertyAddress a = {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 size = 0;
        CHECK((*d)->GetPropertyDataSize(d, kAudioObjectPlugInObject, 0, &a, 0, NULL, &size) == 0 && size == sizeof(AudioObjectID), "device list size %u", size);
        AudioObjectID ids[4] = {0};
        CHECK((*d)->GetPropertyData(d, kAudioObjectPlugInObject, 0, &a, 0, NULL, sizeof ids, &size, ids) == 0 && size == 4 && ids[0] == 2, "device list");
        CFStringRef uid = CFSTR("com.anods.rdc.mic");
        a.mSelector = kAudioPlugInPropertyTranslateUIDToDevice;
        AudioObjectID found = 0;
        CHECK((*d)->GetPropertyData(d, kAudioObjectPlugInObject, 0, &a, sizeof uid, &uid, sizeof found, &size, &found) == 0 && found == 2, "UID → device: %u", found);
    }
    CHECK(str_is(d, 2, kAudioDevicePropertyDeviceUID, "com.anods.rdc.mic"), "device UID");
    CHECK(str_is(d, 2, kAudioObjectPropertyName, "RDC Microphone"), "device name");
    CHECK(str_is(d, 2, kAudioObjectPropertyManufacturer, "RDC"), "manufacturer");
    CHECK(get_u32(d, 2, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeVirtual, "transport");
    CHECK(get_u32(d, 2, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1, "can be default input");
    CHECK(get_u32(d, 2, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0, "cannot be default output");
    CHECK(get_u32(d, 2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0, "not running yet");
    CHECK(get_u32(d, 2, kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal) >= 10923, "zero time stamp period");
    {
        AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
        AudioObjectID ids[4] = {0};
        UInt32 size = 0;
        CHECK((*d)->GetPropertyData(d, 2, 0, &a, 0, NULL, sizeof ids, &size, ids) == 0 && size == 4 && ids[0] == 3, "input streams");
        a.mScope = kAudioObjectPropertyScopeOutput;
        CHECK((*d)->GetPropertyData(d, 2, 0, &a, 0, NULL, sizeof ids, &size, ids) == 0 && size == 0, "no output streams");
        a.mSelector = kAudioDevicePropertyNominalSampleRate;
        a.mScope = kAudioObjectPropertyScopeGlobal;
        Float64 rate = 0;
        CHECK((*d)->GetPropertyData(d, 2, 0, &a, 0, NULL, sizeof rate, &size, &rate) == 0 && rate == 48000, "rate %g", rate);
        Float64 other = 44100;
        CHECK((*d)->SetPropertyData(d, 2, 0, &a, 0, NULL, sizeof other, &other) != 0, "44.1 kHz must be refused");
        CHECK((*d)->SetPropertyData(d, 2, 0, &a, 0, NULL, sizeof rate, &rate) == 0, "48 kHz must be accepted");
        a.mSelector = kAudioStreamPropertyVirtualFormat;
        AudioStreamBasicDescription f;
        CHECK((*d)->GetPropertyData(d, 3, 0, &a, 0, NULL, sizeof f, &size, &f) == 0 && f.mSampleRate == 48000 && f.mChannelsPerFrame == 1 &&
                  f.mBitsPerChannel == 32 && (f.mFormatFlags & kAudioFormatFlagIsFloat),
              "stream format");
        AudioObjectPropertyAddress bogus = {'zzzz', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CHECK(!(*d)->HasProperty(d, 2, 0, &bogus), "unknown property");
        CHECK((*d)->GetPropertyDataSize(d, 2, 0, &bogus, 0, NULL, &size) == kAudioHardwareUnknownPropertyError, "unknown property size");
        CHECK((*d)->GetPropertyDataSize(d, 9, 0, &a, 0, NULL, &size) == kAudioHardwareBadObjectError, "unknown object");
    }

    // The writer: the segment RDC.app would create.
    rdc_mic_writer w = {NULL};
    char err[128];
    CHECK(rdc_mic_writer_open(&w, err, sizeof err) == 0, "writer open: %s", err);
    if (!w.shm) return 1;
    rdc_mic_writer_start(&w);

    // IO: the clock, then samples through the ring.
    CHECK((*d)->StartIO(d, 2, 1) == 0, "StartIO");
    CHECK(get_u32(d, 2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1, "running");
    {
        Float64 st1 = 0, st2 = 0;
        UInt64 ht1 = 0, ht2 = 0, seed = 0;
        CHECK((*d)->GetZeroTimeStamp(d, 2, 1, &st1, &ht1, &seed) == 0 && st1 == 0 && seed == 1, "first zero time stamp");
        usleep(400000);  // longer than one period (16384 frames ≈ 341 ms)
        CHECK((*d)->GetZeroTimeStamp(d, 2, 1, &st2, &ht2, &seed) == 0 && st2 == 16384 && ht2 > ht1, "second zero time stamp: %g", st2);
        Boolean will = false, in_place = false;
        CHECK((*d)->WillDoIOOperation(d, 2, 1, kAudioServerPlugInIOOperationReadInput, &will, &in_place) == 0 && will, "will read input");
        CHECK((*d)->WillDoIOOperation(d, 2, 1, kAudioServerPlugInIOOperationWriteMix, &will, &in_place) == 0 && !will, "no output");
    }
    enum { kFrames = 512 };
    Float32 out[kFrames];
    // Nothing pushed yet: silence.
    read_frames(d, out, kFrames);
    CHECK(all_zero(out, kFrames), "silence before any samples");
    // 200 ms of a ramp: comes out in order once the 60 ms cushion is there.
    enum { kRamp = 9600 };
    int16_t ramp[kRamp];
    for (int i = 0; i < kRamp; i++) ramp[i] = (int16_t)(i - 4800);
    rdc_mic_writer_push(&w, ramp, kRamp, 1);
    int pos = 0, mismatches = 0;
    for (int cycle = 0; cycle < kRamp / kFrames; cycle++) {
        read_frames(d, out, kFrames);
        for (int i = 0; i < kFrames; i++, pos++)
            if (fabsf(out[i] - (Float32)ramp[pos] / 32768.0f) > 1e-6f) mismatches++;
    }
    CHECK(mismatches == 0, "%d samples differ from the ramp", mismatches);
    // Past the end: the rest of the ramp, then zeros, and the flow stops until a new cushion.
    read_frames(d, out, kFrames);
    {
        int left = kRamp - pos;
        int ok = 1;
        for (int i = 0; i < left; i++) ok &= fabsf(out[i] - (Float32)ramp[pos + i] / 32768.0f) <= 1e-6f;
        CHECK(ok && all_zero(out + left, kFrames - left), "tail then silence on underrun");
    }
    // A small push does not restart the flow: still silence.
    rdc_mic_writer_push(&w, ramp, 480, 2);
    read_frames(d, out, kFrames);
    CHECK(all_zero(out, kFrames), "silence while the cushion rebuilds");
    // Too much queued (400 ms): the reader skips to the newest 100 ms.
    int16_t big[19200];
    for (int i = 0; i < 19200; i++) big[i] = (int16_t)(1000 + i % 1000);
    rdc_mic_writer_push(&w, big, 19200, 3);
    read_frames(d, out, kFrames);
    {
        // The reader is at write_pos - 4800: samples big[19200 - 4800 ...], or the tail of the 480 push
        // never shows. Expect the first value to come from inside `big` at index 14400.
        Float32 want = (Float32)big[14400] / 32768.0f;
        CHECK(fabsf(out[0] - want) <= 1e-6f, "skip ahead: got %g, wanted %g", out[0], want);
    }
    // A new generation (the next viewer): the old samples are dropped, silence until a new cushion.
    rdc_mic_writer_start(&w);
    read_frames(d, out, kFrames);
    CHECK(all_zero(out, kFrames), "silence after a new generation");
    rdc_mic_writer_push(&w, ramp, kRamp, 4);
    read_frames(d, out, kFrames);
    CHECK(fabsf(out[0] - (Float32)ramp[0] / 32768.0f) <= 1e-6f, "the new stream starts at its first sample");
    {
        AudioObjectPropertyAddress a = {'stat', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CFStringRef s = NULL;
        UInt32 size = 0;
        CHECK((*d)->GetPropertyData(d, 2, 0, &a, 0, NULL, sizeof s, &size, &s) == 0 && s, "stat property");
        if (s) {
            char buf[64];
            CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
            printf("mic-check: underruns and skips: %s\n", buf);
            CFRelease(s);
        }
    }
    CHECK((*d)->StopIO(d, 2, 1) == 0, "StopIO");
    CHECK(get_u32(d, 2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0, "stopped");
    rdc_mic_writer_stop(&w);
    rdc_mic_writer_close(&w);
    (*d)->Release(d);
    CFRelease(plugin);
    if (failures) {
        fprintf(stderr, "mic-check: %d failure(s)\n", failures);
        return 1;
    }
    printf("mic-check: OK — the plug-in loads as a CFPlugIn, answers the HAL's properties and plays the shared ring\n");
    return 0;
}
