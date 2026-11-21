// macOS platform layer for RDC. Compiled by Zig with -fobjc-arc.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ImageIO/ImageIO.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/file.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>
#include "platform.h"
#include "mic_writer.h"

// ---------------------------------------------------------------------------
// Log

static FILE *g_log_file;
static pthread_mutex_t g_log_mutex = PTHREAD_MUTEX_INITIALIZER;

void rdc_init(void) {
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/RDC"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        g_log_file = fopen([dir stringByAppendingPathComponent:@"rdc.log"].fileSystemRepresentation, "a");
    }
}

void rdc_log(const char *msg) {
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    char stamp[16];
    strftime(stamp, sizeof stamp, "%H:%M:%S", &tm);
    pthread_mutex_lock(&g_log_mutex);
    fprintf(stderr, "[%s] %s\n", stamp, msg);
    if (g_log_file) {
        fprintf(g_log_file, "[%s] %s\n", stamp, msg);
        fflush(g_log_file);
    }
    pthread_mutex_unlock(&g_log_mutex);
}

static void rlog(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    rdc_log(buf);
}

static uint64_t now_us(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000; }

uint64_t rdc_now_us(void) { return now_us(); }

// ---------------------------------------------------------------------------
// Permissions

int rdc_screen_access(int prompt) {
    if (CGPreflightScreenCaptureAccess()) return 1;
    if (prompt) return CGRequestScreenCaptureAccess() ? 1 : 0;
    return 0;
}

int rdc_input_access(int prompt) {
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : prompt ? @YES : @NO};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts) ? 1 : 0;
}

void rdc_open_privacy(int which) {
    NSString *url = which == 0
        ? @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        : @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
    });
}

// ---------------------------------------------------------------------------
// Capture and encoding. All state below is changed only on g_queue.

@interface RDCStreamOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@end

static dispatch_queue_t g_queue;
static SCStream *g_stream;
static RDCStreamOutput *g_output;
static VTCompressionSessionRef g_h264;
static VTCompressionSessionRef g_jpeg;
static int g_want_h264 = 1, g_want_jpeg = 0;
static int g_w, g_h, g_fps = 60;
static int g_bitrate = 10000000;
static rdc_frame_cb g_cb;
static void *g_cb_ctx;
static CVPixelBufferRef g_last;      // last complete frame — for new viewers
static atomic_int g_force_key;
static uint64_t g_last_jpeg_us;
static int g_jpeg_pending;
static int g_switching;              // frames are dropped while the stream moves to another display
static atomic_uint g_display_id;     // the display to capture; 0 — the main one
static int g_max_width = 1920;
static const uint64_t kJpegIntervalUs = 40000;  // JPEG at most 25 fps

static void vt_output(void *refcon, void *frame_refcon, OSStatus status, VTEncodeInfoFlags flags,
                      CMSampleBufferRef sb) {
    @autoreleasepool {
        if (status != noErr) {
            rlog("encoding: error %d", (int)status);
            return;
        }
        if (!sb || (flags & kVTEncodeInfo_FrameDropped)) return;
        int codec = (int)(uintptr_t)frame_refcon;
        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
        if (!bb) return;
        size_t total = CMBlockBufferGetDataLength(bb);
        NSMutableData *raw = [NSMutableData dataWithLength:total];
        if (CMBlockBufferCopyDataBytes(bb, 0, total, raw.mutableBytes) != kCMBlockBufferNoErr) return;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        uint64_t ts = CMTIME_IS_VALID(pts) ? (uint64_t)CMTimeConvertScale(pts, 1000000, kCMTimeRoundingMethod_Default).value : now_us();
        int w = g_w, h = g_h;
        rdc_frame_cb cb = g_cb;
        if (!cb) return;

        if (codec == RDC_CODEC_JPEG) {
            cb(g_cb_ctx, RDC_CODEC_JPEG, raw.bytes, raw.length, 1, ts, w, h);
            return;
        }

        int key = 1;
        CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
        if (atts && CFArrayGetCount(atts) > 0) {
            CFDictionaryRef a = CFArrayGetValueAtIndex(atts, 0);
            CFBooleanRef not_sync = NULL;
            if (CFDictionaryGetValueIfPresent(a, kCMSampleAttachmentKey_NotSync, (const void **)&not_sync) &&
                not_sync == kCFBooleanTrue)
                key = 0;
        }

        // AVCC (4-byte NAL length) → Annex B (00 00 00 01). Keyframes get SPS and PPS up front.
        static const uint8_t start_code[4] = {0, 0, 0, 1};
        NSMutableData *out = [NSMutableData dataWithCapacity:total + 256];
        int nal_len_size = 4;
        if (key) {
            CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
            size_t count = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &count, &nal_len_size) == noErr) {
                for (size_t i = 0; i < count; i++) {
                    const uint8_t *ps = NULL;
                    size_t ps_len = 0;
                    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &ps_len, NULL, NULL) == noErr) {
                        [out appendBytes:start_code length:4];
                        [out appendBytes:ps length:ps_len];
                    }
                }
            }
        }
        const uint8_t *p = raw.bytes;
        size_t off = 0;
        while (off + (size_t)nal_len_size <= total) {
            uint32_t n = 0;
            for (int i = 0; i < nal_len_size; i++) n = (n << 8) | p[off + i];
            off += (size_t)nal_len_size;
            if (n == 0 || off + n > total) break;
            [out appendBytes:start_code length:4];
            [out appendBytes:p + off length:n];
            off += n;
        }
        cb(g_cb_ctx, RDC_CODEC_H264, out.bytes, out.length, key, ts, w, h);
    }
}

static void set_prop(VTCompressionSessionRef s, CFStringRef key, CFTypeRef value, const char *name) {
    OSStatus st = VTSessionSetProperty(s, key, value);
    if (st != noErr) rlog("VideoToolbox: property %s rejected (%d)", name, (int)st);
}

static VTCompressionSessionRef make_session(int codec) {
    VTCompressionSessionRef s = NULL;
    CMVideoCodecType type = codec == RDC_CODEC_H264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_JPEG;
    NSDictionary *spec = codec == RDC_CODEC_H264
        ? @{(__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl : @YES}
        : nil;
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, g_w, g_h, type, (__bridge CFDictionaryRef)spec,
                                             NULL, NULL, vt_output, NULL, &s);
    if (st != noErr && spec) {
        rlog("VideoToolbox: low-latency mode unavailable (%d), using normal", (int)st);
        st = VTCompressionSessionCreate(kCFAllocatorDefault, g_w, g_h, type, NULL, NULL, NULL, vt_output, NULL, &s);
    }
    if (st != noErr || !s) {
        rlog("VideoToolbox: cannot create encoder %d (%d)", codec, (int)st);
        return NULL;
    }
    set_prop(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime");
    if (codec == RDC_CODEC_H264) {
        set_prop(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel, "ProfileLevel");
        set_prop(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering");
        set_prop(s, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef) @(g_fps), "ExpectedFrameRate");
        set_prop(s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef) @(g_bitrate), "AverageBitRate");
        set_prop(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef) @(g_fps * 300), "MaxKeyFrameInterval");
    } else {
        set_prop(s, kVTCompressionPropertyKey_Quality, (__bridge CFNumberRef) @(0.55f), "Quality");
    }
    VTCompressionSessionPrepareToEncodeFrames(s);
    return s;
}

static void destroy_session(VTCompressionSessionRef *s) {
    if (!*s) return;
    VTCompressionSessionCompleteFrames(*s, kCMTimeInvalid);
    VTCompressionSessionInvalidate(*s);
    CFRelease(*s);
    *s = NULL;
}

// On g_queue.
static void sync_sessions(void) {
    if (g_w <= 0) return;
    if (g_want_h264 && !g_h264) g_h264 = make_session(RDC_CODEC_H264);
    if (!g_want_h264) destroy_session(&g_h264);
    if (g_want_jpeg && !g_jpeg) g_jpeg = make_session(RDC_CODEC_JPEG);
    if (!g_want_jpeg) destroy_session(&g_jpeg);
}

static void encode_jpeg(CVPixelBufferRef pb, uint64_t now);

// On g_queue.
static void encode_frame(CVPixelBufferRef pb, int force) {
    uint64_t now = now_us();
    CMTime pts = CMTimeMake((int64_t)now, 1000000);
    int key = force | atomic_exchange(&g_force_key, 0);
    if (g_h264) {
        NSDictionary *props = key ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES} : nil;
        OSStatus st = VTCompressionSessionEncodeFrame(g_h264, pb, pts, kCMTimeInvalid, (__bridge CFDictionaryRef)props,
                                                      (void *)(uintptr_t)RDC_CODEC_H264, NULL);
        if (st != noErr) rlog("H.264: frame rejected (%d)", (int)st);
    }
    if (g_jpeg) {
        if (key || now - g_last_jpeg_us >= kJpegIntervalUs) {
            encode_jpeg(pb, now);
        } else if (!g_jpeg_pending) {
            // The last frame of a burst must still go out: send it once the interval expires.
            g_jpeg_pending = 1;
            uint64_t wait = kJpegIntervalUs - (now - g_last_jpeg_us);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)wait * 1000), g_queue, ^{
                g_jpeg_pending = 0;
                if (g_jpeg && g_last) encode_jpeg(g_last, now_us());
            });
        }
    }
}

static void encode_jpeg(CVPixelBufferRef pb, uint64_t now) {
    g_last_jpeg_us = now;
    OSStatus st = VTCompressionSessionEncodeFrame(g_jpeg, pb, CMTimeMake((int64_t)now, 1000000), kCMTimeInvalid, NULL,
                                                  (void *)(uintptr_t)RDC_CODEC_JPEG, NULL);
    if (st != noErr) rlog("JPEG: frame rejected (%d)", (int)st);
}

@implementation RDCStreamOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sb)) return;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!atts || CFArrayGetCount(atts) == 0) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;  // screen unchanged
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb || g_switching) return;
    // A frame of the display being left, at its old size: the encoders are made for the new one.
    if ((int)CVPixelBufferGetWidth(pb) != g_w || (int)CVPixelBufferGetHeight(pb) != g_h) return;
    if (g_last) CVPixelBufferRelease(g_last);
    g_last = CVPixelBufferRetain(pb);
    encode_frame(pb, 0);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    rlog("capture stopped: %s", error.localizedDescription.UTF8String);
}
@end

// Displays: the active ones that are not mirrors of another.
static int active_displays(CGDirectDisplayID *ids, int max) {
    CGDirectDisplayID all[32];
    uint32_t n = 0;
    if (CGGetActiveDisplayList(32, all, &n) != kCGErrorSuccess) return 0;
    int k = 0;
    for (uint32_t i = 0; i < n && k < max; i++)
        if (CGDisplayMirrorsDisplay(all[i]) == kCGNullDirectDisplay) ids[k++] = all[i];
    return k;
}

static int display_active(CGDirectDisplayID id) {
    CGDirectDisplayID ids[RDC_MAX_DISPLAYS];
    int n = active_displays(ids, RDC_MAX_DISPLAYS);
    for (int i = 0; i < n; i++)
        if (ids[i] == id) return 1;
    return 0;
}

// The display capture should show: the chosen one while it is there, else the main one.
static CGDirectDisplayID wanted_display(void) {
    CGDirectDisplayID id = atomic_load(&g_display_id);
    return id && display_active(id) ? id : CGMainDisplayID();
}

// Names come from NSScreen; looked up once per display, they do not change while it is connected.
static NSMutableDictionary<NSNumber *, NSString *> *g_display_names;

static NSString *display_name(CGDirectDisplayID id, int index) {
    @synchronized([RDCStreamOutput class]) {
        if (!g_display_names) g_display_names = [NSMutableDictionary dictionary];
        NSString *name = g_display_names[@(id)];
        if (name) return name;
        for (NSScreen *screen in NSScreen.screens) {
            NSNumber *num = screen.deviceDescription[@"NSScreenNumber"];
            if (num && num.unsignedIntValue == id && screen.localizedName.length) name = screen.localizedName;
        }
        if (!name) name = CGDisplayIsBuiltin(id) ? @"Built-in display" : [NSString stringWithFormat:@"Display %d", index + 1];
        g_display_names[@(id)] = name;
        return name;
    }
}

int rdc_displays(rdc_display *out, int max) {
    @autoreleasepool {
        CGDirectDisplayID ids[RDC_MAX_DISPLAYS];
        int n = active_displays(ids, max < RDC_MAX_DISPLAYS ? max : RDC_MAX_DISPLAYS);
        for (int i = 0; i < n; i++) {
            rdc_display *d = &out[i];
            memset(d, 0, sizeof *d);
            CGRect b = CGDisplayBounds(ids[i]);
            d->id = ids[i];
            d->x = (int32_t)lround(b.origin.x);
            d->y = (int32_t)lround(b.origin.y);
            d->w = (int32_t)lround(b.size.width);
            d->h = (int32_t)lround(b.size.height);
            d->pw = d->w;
            d->ph = d->h;
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ids[i]);
            if (mode) {
                d->pw = (int32_t)CGDisplayModeGetPixelWidth(mode);
                d->ph = (int32_t)CGDisplayModeGetPixelHeight(mode);
                CGDisplayModeRelease(mode);
            }
            d->primary = CGDisplayIsMain(ids[i]) ? 1 : 0;
            strlcpy(d->name, display_name(ids[i], i).UTF8String ?: "", sizeof d->name);
        }
        return n;
    }
}

// The filter and configuration for one display, at most max_width pixels wide.
static SCStreamConfiguration *stream_config(SCDisplay *display, SCContentFilter *filter, int *out_w, int *out_h) {
    float scale = filter.pointPixelScale > 0 ? filter.pointPixelScale : 1;
    int w = (int)(display.width * scale), h = (int)(display.height * scale);
    if (g_max_width > 0 && w > g_max_width) {
        h = (int)((double)h * g_max_width / w);
        w = g_max_width;
    }
    w &= ~1;
    h &= ~1;
    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
    cfg.width = (size_t)w;
    cfg.height = (size_t)h;
    cfg.minimumFrameInterval = CMTimeMake(1, g_fps);
    cfg.pixelFormat = kCVPixelFormatType_32BGRA;
    cfg.showsCursor = YES;
    cfg.queueDepth = 6;
    cfg.colorSpaceName = kCGColorSpaceSRGB;
    *out_w = w;
    *out_h = h;
    return cfg;
}

int rdc_capture_start(int max_width, int fps, rdc_frame_cb cb, void *ctx) {
    if (!g_queue) g_queue = dispatch_queue_create("rdc.capture", DISPATCH_QUEUE_SERIAL);
    if (g_stream) return 0;
    g_cb = cb;
    g_cb_ctx = ctx;
    g_fps = fps > 0 ? fps : 60;
    g_max_width = max_width;
    __block int result = -4;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error || content.displays.count == 0) {
            rlog("no screen access: %s", error ? error.localizedDescription.UTF8String : "no displays");
            result = -1;
            dispatch_semaphore_signal(done);
            return;
        }
        CGDirectDisplayID want = wanted_display();
        SCDisplay *display = content.displays.firstObject;
        for (SCDisplay *d in content.displays)
            if (d.displayID == want) display = d;

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        int w = 0, h = 0;
        SCStreamConfiguration *cfg = stream_config(display, filter, &w, &h);

        dispatch_sync(g_queue, ^{
            g_w = w;
            g_h = h;
            sync_sessions();
        });

        g_output = [RDCStreamOutput new];
        g_stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:g_output];
        NSError *add_error = nil;
        if (![g_stream addStreamOutput:g_output type:SCStreamOutputTypeScreen sampleHandlerQueue:g_queue error:&add_error]) {
            rlog("capture: %s", add_error.localizedDescription.UTF8String);
            g_stream = nil;
            result = -2;
            dispatch_semaphore_signal(done);
            return;
        }
        [g_stream startCaptureWithCompletionHandler:^(NSError *start_error) {
            if (start_error) {
                rlog("capture failed to start: %s", start_error.localizedDescription.UTF8String);
                g_stream = nil;
                result = -3;
            } else {
                rlog("capture: display %u, %dx%d, up to %d fps", display.displayID, w, h, g_fps);
                result = 0;
            }
            dispatch_semaphore_signal(done);
        }];
    }];

    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) return -5;
    return result;
}

int rdc_capture_display(uint32_t id) {
    CGDirectDisplayID target = id ? id : CGMainDisplayID();
    if (!display_active(target)) return -1;
    atomic_store(&g_display_id, target);
    SCStream *stream = g_stream;
    if (!stream || !g_queue) return 0;
    __block int result = -4;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        SCDisplay *display = nil;
        for (SCDisplay *d in content.displays)
            if (d.displayID == target) display = d;
        if (!display) {
            rlog("capture: display %u is not shareable: %s", target, error ? error.localizedDescription.UTF8String : "not found");
            result = -2;
            dispatch_semaphore_signal(done);
            return;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        int w = 0, h = 0;
        SCStreamConfiguration *cfg = stream_config(display, filter, &w, &h);
        dispatch_sync(g_queue, ^{ g_switching = 1; });
        // The running stream moves to the other display: no restart, no new permission prompt.
        [stream updateContentFilter:filter completionHandler:^(NSError *filter_error) {
            if (filter_error) {
                rlog("capture: cannot move to display %u: %s", target, filter_error.localizedDescription.UTF8String);
                dispatch_sync(g_queue, ^{ g_switching = 0; });
                result = -3;
                dispatch_semaphore_signal(done);
                return;
            }
            [stream updateConfiguration:cfg completionHandler:^(NSError *cfg_error) {
                if (cfg_error) rlog("capture: new size for display %u rejected: %s", target, cfg_error.localizedDescription.UTF8String);
                dispatch_sync(g_queue, ^{
                    // Frames still in the encoders go out at the old size, then encoders for the new one.
                    destroy_session(&g_h264);
                    destroy_session(&g_jpeg);
                    if (g_last) CVPixelBufferRelease(g_last);
                    g_last = NULL;
                    g_w = w;
                    g_h = h;
                    sync_sessions();
                    atomic_store(&g_force_key, 1);
                    g_switching = 0;
                });
                rlog("capture: display %u, %dx%d", target, w, h);
                result = 0;
                dispatch_semaphore_signal(done);
                // The stream sends frames only when the screen changes, and a still display may not
                // change for a long time: take its picture once, so viewers see it right away.
                [SCScreenshotManager captureSampleBufferWithFilter:filter configuration:cfg
                                                 completionHandler:^(CMSampleBufferRef sb, NSError *shot_error) {
                    CVPixelBufferRef pb = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
                    if (!pb) return;
                    CVPixelBufferRetain(pb);
                    dispatch_async(g_queue, ^{
                        if (!g_last && (int)CVPixelBufferGetWidth(pb) == g_w && (int)CVPixelBufferGetHeight(pb) == g_h) {
                            g_last = CVPixelBufferRetain(pb);
                            encode_frame(pb, 1);
                        }
                        CVPixelBufferRelease(pb);
                    });
                }];
            }];
        }];
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) return -5;
    return result;
}

void rdc_capture_stop(void) {
    SCStream *s = g_stream;
    g_stream = nil;
    if (s) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [s stopCaptureWithCompletionHandler:^(NSError *e) { dispatch_semaphore_signal(done); }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    }
    if (!g_queue) return;
    dispatch_sync(g_queue, ^{
        destroy_session(&g_h264);
        destroy_session(&g_jpeg);
        if (g_last) CVPixelBufferRelease(g_last);
        g_last = NULL;
        g_w = g_h = 0;
    });
    g_output = nil;
    rlog("capture stopped");
}

void rdc_set_codecs(int h264, int jpeg) {
    if (!g_queue) g_queue = dispatch_queue_create("rdc.capture", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_queue, ^{
        g_want_h264 = h264 != 0;
        g_want_jpeg = jpeg != 0;
        sync_sessions();
    });
}

void rdc_request_keyframe(void) {
    if (!g_queue) return;
    dispatch_async(g_queue, ^{
        if (g_last)
            encode_frame(g_last, 1);
        else
            atomic_store(&g_force_key, 1);
    });
}

void rdc_set_bitrate(int bits_per_second) {
    if (!g_queue || bits_per_second <= 0) return;
    dispatch_async(g_queue, ^{
        g_bitrate = bits_per_second;
        if (g_h264) set_prop(g_h264, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef) @(g_bitrate), "AverageBitRate");
    });
}

// ---------------------------------------------------------------------------
// Input. All events go through one serial queue — order is preserved.

static dispatch_queue_t g_input_queue;
static CGEventSourceRef g_src;
static CGEventFlags g_flags;
static int g_buttons;           // bits: 1 left, 2 right, 4 middle
static uint8_t g_keys_down[128];
static uint64_t g_last_click_us;
static int g_last_click_button = -1;
static int g_click_count;
static CGPoint g_last_click_pos;

static dispatch_queue_t input_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_input_queue = dispatch_queue_create("rdc.input", DISPATCH_QUEUE_SERIAL);
        g_src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    });
    return g_input_queue;
}

// Desktop coordinates are CG's global ones already (points, origin at the main display's top left).
static CGPoint to_point(double x, double y) { return CGPointMake(x, y); }

static void post(CGEventRef e) {
    if (!e) return;
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static CGEventFlags modifier_flag(int keycode) {
    switch (keycode) {
    case 0x37: case 0x36: return kCGEventFlagMaskCommand;
    case 0x38: case 0x3C: return kCGEventFlagMaskShift;
    case 0x3A: case 0x3D: return kCGEventFlagMaskAlternate;
    case 0x3B: case 0x3E: return kCGEventFlagMaskControl;
    case 0x3F: return kCGEventFlagMaskSecondaryFn;
    default: return 0;
    }
}

static CGEventFlags extra_flags(int keycode) {
    switch (keycode) {
    case 0x7B: case 0x7C: case 0x7D: case 0x7E:  // arrows
        return kCGEventFlagMaskNumericPad | kCGEventFlagMaskSecondaryFn;
    case 0x73: case 0x74: case 0x75: case 0x77: case 0x79: case 0x72:  // Home, PgUp, Del, End, PgDn, Help
    case 0x7A: case 0x78: case 0x63: case 0x76: case 0x60: case 0x61:  // F1–F6
    case 0x62: case 0x64: case 0x65: case 0x6D: case 0x67: case 0x6F:  // F7–F12
        return kCGEventFlagMaskSecondaryFn;
    default: return 0;
    }
}

static void mouse_move_now(CGPoint p) {
    CGEventType type = kCGEventMouseMoved;
    CGMouseButton button = kCGMouseButtonLeft;
    if (g_buttons & 1) type = kCGEventLeftMouseDragged;
    else if (g_buttons & 2) { type = kCGEventRightMouseDragged; button = kCGMouseButtonRight; }
    else if (g_buttons & 4) { type = kCGEventOtherMouseDragged; button = kCGMouseButtonCenter; }
    CGEventRef e = CGEventCreateMouseEvent(g_src, type, p, button);
    if (e) CGEventSetFlags(e, g_flags);
    post(e);
}

void rdc_mouse_move(double nx, double ny) {
    dispatch_async(input_queue(), ^{ mouse_move_now(to_point(nx, ny)); });
}

void rdc_mouse_button(int button, int down, double nx, double ny) {
    dispatch_async(input_queue(), ^{
        CGPoint p = to_point(nx, ny);
        CGEventType type;
        CGMouseButton cg_button;
        int bit;
        switch (button) {
        case 2: type = down ? kCGEventRightMouseDown : kCGEventRightMouseUp; cg_button = kCGMouseButtonRight; bit = 2; break;
        case 1: type = down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp; cg_button = kCGMouseButtonCenter; bit = 4; break;
        default: type = down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp; cg_button = kCGMouseButtonLeft; bit = 1; break;
        }
        if (down) {
            uint64_t t = now_us();
            double dx = p.x - g_last_click_pos.x, dy = p.y - g_last_click_pos.y;
            if (button == g_last_click_button && t - g_last_click_us < 450000 && dx * dx + dy * dy < 25)
                g_click_count++;
            else
                g_click_count = 1;
            g_last_click_us = t;
            g_last_click_button = button;
            g_last_click_pos = p;
            g_buttons |= bit;
        } else {
            g_buttons &= ~bit;
        }
        CGEventRef e = CGEventCreateMouseEvent(g_src, type, p, cg_button);
        if (e) {
            CGEventSetIntegerValueField(e, kCGMouseEventClickState, g_click_count > 0 ? g_click_count : 1);
            CGEventSetFlags(e, g_flags);
        }
        post(e);
    });
}

void rdc_scroll(double dx, double dy) {
    dispatch_async(input_queue(), ^{
        int32_t vy = (int32_t)lround(-dy), vx = (int32_t)lround(-dx);
        if (vx == 0 && vy == 0) return;
        CGEventRef e = CGEventCreateScrollWheelEvent2(g_src, kCGScrollEventUnitPixel, 2, vy, vx, 0);
        if (e) CGEventSetFlags(e, g_flags);
        post(e);
    });
}

static void key_now(int keycode, int down) {
    if (keycode < 0 || keycode > 127) return;
    CGEventFlags mod = modifier_flag(keycode);
    CGEventRef e = CGEventCreateKeyboardEvent(g_src, (CGKeyCode)keycode, down ? true : false);
    if (!e) return;
    if (mod) {
        if (down) g_flags |= mod;
        else g_flags &= ~mod;
        CGEventSetType(e, kCGEventFlagsChanged);
        CGEventSetFlags(e, g_flags);
    } else {
        CGEventSetFlags(e, g_flags | extra_flags(keycode));
    }
    g_keys_down[keycode] = down ? 1 : 0;
    post(e);
}

void rdc_key(int mac_keycode, int down) {
    dispatch_async(input_queue(), ^{ key_now(mac_keycode, down); });
}

// Text goes in as Unicode strings on key events, one character (a surrogate pair stays whole)
// per event: apps that read only the first character of an event still get everything.
void rdc_text(const char *utf8, size_t len) {
    NSString *s = [[NSString alloc] initWithBytes:utf8 length:len encoding:NSUTF8StringEncoding];
    if (s.length == 0) return;
    dispatch_async(input_queue(), ^{
        NSUInteger n = s.length;
        for (NSUInteger i = 0; i < n;) {
            unichar chars[2];
            NSUInteger take = 1;
            chars[0] = [s characterAtIndex:i];
            if (CFStringIsSurrogateHighCharacter(chars[0]) && i + 1 < n) {
                chars[1] = [s characterAtIndex:i + 1];
                take = 2;
            }
            CGEventRef down = CGEventCreateKeyboardEvent(g_src, 0, true);
            CGEventRef up = CGEventCreateKeyboardEvent(g_src, 0, false);
            if (down) {
                CGEventSetFlags(down, 0);
                CGEventKeyboardSetUnicodeString(down, take, chars);
            }
            if (up) {
                CGEventSetFlags(up, 0);
                CGEventKeyboardSetUnicodeString(up, take, chars);
            }
            post(down);
            post(up);
            i += take;
            if (i % 64 == 0) usleep(4000);  // let slow apps keep up with long text
        }
    });
}

// ---------------------------------------------------------------------------
// Screenshots for AI agents: JPEG in, cropped and shrunk JPEG out (ImageIO).

void *rdc_jpeg_scale(const void *jpeg, size_t len, int crop_x, int crop_y, int crop_w, int crop_h,
                     int max_w, int max_h, int quality, size_t *out_len, int *out_w, int *out_h) {
    @autoreleasepool {
        CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, jpeg, (CFIndex)len, kCFAllocatorNull);
        if (!data) return NULL;
        CGImageSourceRef src = CGImageSourceCreateWithData(data, NULL);
        CFRelease(data);
        if (!src) return NULL;
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        CFRelease(src);
        if (!img) return NULL;
        CGRect rect = CGRectMake(0, 0, CGImageGetWidth(img), CGImageGetHeight(img));
        if (crop_w > 0 && crop_h > 0) rect = CGRectIntersection(rect, CGRectMake(crop_x, crop_y, crop_w, crop_h));
        rect = CGRectIntegral(rect);
        CGImageRef part = CGRectIsEmpty(rect) ? NULL : CGImageCreateWithImageInRect(img, rect);
        CGImageRelease(img);
        if (!part) return NULL;
        double scale = 1;
        if (max_w > 0 && rect.size.width * scale > max_w) scale = max_w / rect.size.width;
        if (max_h > 0 && rect.size.height * scale > max_h) scale = max_h / rect.size.height;
        size_t w = (size_t)MAX(1, lround(rect.size.width * scale));
        size_t h = (size_t)MAX(1, lround(rect.size.height * scale));
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);
        if (!ctx) {
            CGImageRelease(part);
            return NULL;
        }
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), part);
        CGImageRelease(part);
        CGImageRef scaled = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (!scaled) return NULL;
        void *result = NULL;
        CFMutableDataRef out = CFDataCreateMutable(NULL, 0);
        CGImageDestinationRef dst = out ? CGImageDestinationCreateWithData(out, CFSTR("public.jpeg"), 1, NULL) : NULL;
        if (dst) {
            NSDictionary *props = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality / 100.0)};
            CGImageDestinationAddImage(dst, scaled, (__bridge CFDictionaryRef)props);
            if (CGImageDestinationFinalize(dst)) {
                size_t n = (size_t)CFDataGetLength(out);
                result = malloc(n);
                if (result) {
                    memcpy(result, CFDataGetBytePtr(out), n);
                    *out_len = n;
                    *out_w = (int)w;
                    *out_h = (int)h;
                }
            }
            CFRelease(dst);
        }
        if (out) CFRelease(out);
        CGImageRelease(scaled);
        return result;
    }
}

void rdc_release_all(void) {
    dispatch_async(input_queue(), ^{
        for (int k = 0; k < 128; k++)
            if (g_keys_down[k] && !modifier_flag(k)) key_now(k, 0);
        for (int k = 0; k < 128; k++)
            if (g_keys_down[k]) key_now(k, 0);
        g_flags = 0;
        CGEventRef pos = CGEventCreate(NULL);
        CGPoint p = pos ? CGEventGetLocation(pos) : CGPointZero;
        if (pos) CFRelease(pos);
        if (g_buttons & 1) post(CGEventCreateMouseEvent(g_src, kCGEventLeftMouseUp, p, kCGMouseButtonLeft));
        if (g_buttons & 2) post(CGEventCreateMouseEvent(g_src, kCGEventRightMouseUp, p, kCGMouseButtonRight));
        if (g_buttons & 4) post(CGEventCreateMouseEvent(g_src, kCGEventOtherMouseUp, p, kCGMouseButtonCenter));
        g_buttons = 0;
    });
}

void rdc_cursor_pos(double *x, double *y) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = e ? CGEventGetLocation(e) : CGPointZero;
    if (e) CFRelease(e);
    *x = p.x;
    *y = p.y;
}

// ---------------------------------------------------------------------------
// Network and system

void *rdc_read_file(const char *path, size_t *len) {
    @autoreleasepool {
        NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
        if (!d) return NULL;
        void *buf = malloc(d.length ? d.length : 1);
        if (!buf) return NULL;
        memcpy(buf, d.bytes, d.length);
        *len = d.length;
        return buf;
    }
}

int rdc_lan_ipv4(char *buf, int buflen) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return -1;
    int found = -1;
    for (int pass = 0; pass < 3 && found < 0; pass++) {
        for (struct ifaddrs *i = list; i; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
            if (!(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK)) continue;
            if (pass == 0 && strcmp(i->ifa_name, "en0") != 0) continue;
            if (pass == 1 && strncmp(i->ifa_name, "en", 2) != 0) continue;
            struct in_addr a = ((struct sockaddr_in *)i->ifa_addr)->sin_addr;
            if ((ntohl(a.s_addr) >> 16) == 0xA9FE) continue;  // 169.254.x.x
            if (inet_ntop(AF_INET, &a, buf, (socklen_t)buflen)) {
                found = 0;
                break;
            }
        }
    }
    freeifaddrs(list);
    return found;
}

// ---------------------------------------------------------------------------
// Updates

void *rdc_http_get(const char *url, size_t max_len, size_t *len, int *status) {
    @autoreleasepool {
        *status = -1;
        *len = 0;
        NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
        if (!u) return NULL;
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:60];
        [req setValue:@"RDC-updater" forHTTPHeaderField:@"User-Agent"];
        static NSURLSession *session;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            cfg.timeoutIntervalForResource = 600;
            session = [NSURLSession sessionWithConfiguration:cfg];
        });
        __block NSData *body = nil;
        __block NSInteger code = -1;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [session dataTaskWithRequest:req
                                                completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                                                    if (!e && [r isKindOfClass:NSHTTPURLResponse.class]) {
                                                        code = ((NSHTTPURLResponse *)r).statusCode;
                                                        body = d;
                                                    } else if (e) {
                                                        rlog("network: %s", e.localizedDescription.UTF8String);
                                                    }
                                                    dispatch_semaphore_signal(done);
                                                }];
        [task resume];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 620 * NSEC_PER_SEC)) != 0) {
            [task cancel];
            return NULL;
        }
        *status = (int)code;
        if (!body || body.length > max_len) return NULL;
        void *buf = malloc(body.length ? body.length : 1);
        if (!buf) return NULL;
        memcpy(buf, body.bytes, body.length);
        *len = body.length;
        return buf;
    }
}

int rdc_write_temp(const char *name, const void *data, size_t len, char *path_out, int path_len) {
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rdc-download"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name].lastPathComponent];
        NSData *d = [NSData dataWithBytesNoCopy:(void *)data length:len freeWhenDone:NO];
        if (![d writeToFile:path atomically:YES]) return -1;
        return [path getCString:path_out maxLength:(NSUInteger)path_len encoding:NSUTF8StringEncoding] ? 0 : -1;
    }
}

static int run_tool(NSString *path, NSArray<NSString *> *args) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args;
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) return -1;
    [t waitUntilExit];
    return t.terminationStatus;
}

int rdc_install_path(char *buf, int buflen) {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    if (![bundle.pathExtension isEqualToString:@"app"]) return -1;
    return [bundle getCString:buf maxLength:(NSUInteger)buflen encoding:NSUTF8StringEncoding] ? 0 : -1;
}

void rdc_cleanup_old_install(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundlePath;
        if (![bundle.pathExtension isEqualToString:@"app"]) return;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = bundle.stringByDeletingLastPathComponent;
        NSString *prefix = [bundle.lastPathComponent stringByAppendingString:@".old-"];
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if ([f hasPrefix:prefix]) [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
        [fm removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"rdc-download"] error:nil];
    }
}

int rdc_install_update(const char *zip_path, const char *version) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *bundle = NSBundle.mainBundle.bundlePath;
        if (![bundle.pathExtension isEqualToString:@"app"]) return -1;
        NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"rdc-update-%d", getpid()]];
        [fm removeItemAtPath:work error:nil];
        if (![fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil]) return -2;
        if (run_tool(@"/usr/bin/ditto", @[ @"-x", @"-k", [NSString stringWithUTF8String:zip_path], work ]) != 0) return -3;

        NSString *fresh = [work stringByAppendingPathComponent:@"RDC.app"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[fresh stringByAppendingPathComponent:@"Contents/Info.plist"]];
        if (![info[@"CFBundleIdentifier"] isEqual:@"com.anods.rdc"] ||
            ![info[@"CFBundleShortVersionString"] isEqual:[NSString stringWithUTF8String:version]]) {
            rlog("update: archive does not contain RDC %s", version);
            return -4;
        }
        if (run_tool(@"/usr/bin/codesign", @[ @"--verify", @"--strict", fresh ]) != 0) {
            rlog("update: bundle signature is invalid");
            return -5;
        }

        NSString *old = [bundle stringByAppendingFormat:@".old-%d", getpid()];
        NSError *err = nil;
        if (![fm moveItemAtPath:bundle toPath:old error:&err]) {
            rlog("update: cannot move old version aside: %s", err.localizedDescription.UTF8String);
            return -6;
        }
        if (![fm moveItemAtPath:fresh toPath:bundle error:&err]) {
            [fm moveItemAtPath:old toPath:bundle error:nil];
            rlog("update: cannot put new version in place: %s", err.localizedDescription.UTF8String);
            return -7;
        }

        // The new version starts a second later, once this process has exited and freed the port.
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-c", @"sleep 1; exec /usr/bin/open -n \"$0\" --args \"$@\"", bundle, nil];
        NSArray<NSString *> *mine = NSProcessInfo.processInfo.arguments;
        for (NSUInteger i = 1; i < mine.count; i++)
            if (![mine[i] hasPrefix:@"-psn_"]) [args addObject:mine[i]];
        NSTask *relaunch = [NSTask new];
        relaunch.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
        relaunch.arguments = args;
        if (![relaunch launchAndReturnError:&err]) rlog("update: cannot relaunch: %s", err.localizedDescription.UTF8String);
        rlog("update %s installed, restarting", version);
        exit(0);
    }
}

int rdc_pref_bool(const char *key, int def) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *k = [NSString stringWithUTF8String:key];
    return [d objectForKey:k] ? ([d boolForKey:k] ? 1 : 0) : def;
}

void rdc_set_pref_bool(const char *key, int value) {
    [NSUserDefaults.standardUserDefaults setBool:value != 0 forKey:[NSString stringWithUTF8String:key]];
}

int rdc_pref_string(const char *key, char *buf, int buflen) {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithUTF8String:key]];
    if (!v) return -1;
    const char *u = v.UTF8String;
    size_t n = strlen(u);
    if ((int)n >= buflen) return -1;
    memcpy(buf, u, n + 1);
    return (int)n;
}

void rdc_set_pref_string(const char *key, const char *value) {
    NSString *k = [NSString stringWithUTF8String:key];
    if (!value || !value[0]) return [NSUserDefaults.standardUserDefaults removeObjectForKey:k];
    [NSUserDefaults.standardUserDefaults setObject:[NSString stringWithUTF8String:value] forKey:k];
}

// ---------------------------------------------------------------------------
// Permanent access: the seed file, start at login, staying awake

static int g_seed_fd = -1;  // open and locked for as long as this process lives

static int seed_open(void) {
    if (g_seed_fd >= 0) return 0;
    @autoreleasepool {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/RDC"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions : @0700}
                                                        error:nil];
        int fd = open([dir stringByAppendingPathComponent:@"permanent"].fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
        if (fd < 0) {
            rlog("permanent access: cannot open the key file: %s", strerror(errno));
            return -1;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
            close(fd);
            return -2;
        }
        fchmod(fd, 0600);
        g_seed_fd = fd;
        return 0;
    }
}

int rdc_seed_load(void *buf, int cap) {
    int rc = seed_open();
    if (rc != 0) return rc;
    ssize_t n = pread(g_seed_fd, buf, (size_t)cap, 0);
    return n < 0 ? -1 : (int)n;
}

int rdc_seed_save(const void *data, int len) {
    if (seed_open() != 0) return -1;
    if (ftruncate(g_seed_fd, 0) != 0 || pwrite(g_seed_fd, data, (size_t)len, 0) != len) return -1;
    fsync(g_seed_fd);
    return 0;
}

// Start at login: a LaunchAgent that opens this copy of RDC with --login (the window stays hidden).
static NSString *const kAgentLabel = @"com.anods.rdc.login";

static NSString *agent_path(void) {
    return [NSHomeDirectory() stringByAppendingFormat:@"/Library/LaunchAgents/%@.plist", kAgentLabel];
}

static NSString *own_binary(void) {
    return NSBundle.mainBundle.executablePath ?: NSProcessInfo.processInfo.arguments.firstObject;
}

static int autostart_on(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:agent_path()];
}

static int autostart_set(int on) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!on) {
        NSError *e = nil;
        if ([fm fileExistsAtPath:agent_path()] && ![fm removeItemAtPath:agent_path() error:&e]) {
            rlog("start at login: cannot remove %s: %s", agent_path().UTF8String, e.localizedDescription.UTF8String);
            return -1;
        }
        rlog("start at login: off");
        return 0;
    }
    NSDictionary *job = @{
        @"Label" : kAgentLabel,
        @"ProgramArguments" : @[ own_binary(), @"--login" ],
        @"RunAtLoad" : @YES,
        @"ProcessType" : @"Interactive",
        @"LimitLoadToSessionType" : @"Aqua",
        @"AssociatedBundleIdentifiers" : @[ @"com.anods.rdc" ],
    };
    [fm createDirectoryAtPath:agent_path().stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *e = nil;
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:job format:NSPropertyListXMLFormat_v1_0 options:0 error:&e];
    if (!xml || ![xml writeToFile:agent_path() options:NSDataWritingAtomic error:&e]) {
        rlog("start at login: cannot write %s: %s", agent_path().UTF8String, e.localizedDescription.UTF8String);
        return -1;
    }
    rlog("start at login: on (%s)", own_binary().UTF8String);
    return 0;
}

// RDC was moved since the agent was written: point it at where RDC is now.
static void autostart_repair(void) {
    NSDictionary *job = [NSDictionary dictionaryWithContentsOfFile:agent_path()];
    NSString *program = [job[@"ProgramArguments"] firstObject];
    if (!job || (program && [NSFileManager.defaultManager isExecutableFileAtPath:program])) return;
    autostart_set(1);
}

// Keep awake: the computer does not fall asleep on its own while RDC runs (the display still may).
static IOPMAssertionID g_awake;

static void keep_awake(int on) {
    if (on && !g_awake) {
        if (IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelOn,
                                        CFSTR("RDC keeps this Mac reachable"), &g_awake) != kIOReturnSuccess)
            g_awake = 0;
    } else if (!on && g_awake) {
        IOPMAssertionRelease(g_awake);
        g_awake = 0;
    }
}

int rdc_computer_name(char *buf, int buflen) {
    NSString *name = [NSHost currentHost].localizedName ?: NSProcessInfo.processInfo.hostName;
    if (!name) return -1;
    return [name getCString:buf maxLength:(NSUInteger)buflen encoding:NSUTF8StringEncoding] ? 0 : -1;
}

// ---------------------------------------------------------------------------
// The viewer's microphone as "RDC Microphone": the HAL plug-in in Contents/Resources, copied to
// /Library/Audio/Plug-Ins/HAL on demand and fed through shared memory (mic_shm.h). The camera is
// not available on macOS: a camera extension needs an entitlement from a paid developer account.

static NSString *const kMicDriverName = @"RDCMicrophone.driver";
static NSString *const kMicDriverDir = @"/Library/Audio/Plug-Ins/HAL";
static NSString *const kMicDeviceUID = @"com.anods.rdc.mic";
static pthread_mutex_t g_mic_mutex = PTHREAD_MUTEX_INITIALIZER;
static rdc_mic_writer g_mic;

static NSString *mic_bundled_path(void) {
    return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:kMicDriverName];
}

static NSString *mic_installed_path(void) {
    return [kMicDriverDir stringByAppendingPathComponent:kMicDriverName];
}

static NSString *bundle_version(NSString *path) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
    return info[@"CFBundleVersion"];
}

// The device the plug-in publishes, if coreaudiod has loaded it.
static AudioObjectID mic_device(void) {
    CFStringRef uid = (__bridge CFStringRef)kMicDeviceUID;
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    AudioObjectPropertyAddress addr = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof uid, &uid, &size, &dev) != noErr) return kAudioObjectUnknown;
    return dev;
}

int rdc_media_status(void) {
    @autoreleasepool {
        int status = RDC_MEDIA_MIC_SETUP;
        if ([NSFileManager.defaultManager fileExistsAtPath:mic_installed_path()]) {
            status |= RDC_MEDIA_MIC_INSTALLED;
            NSString *installed = bundle_version(mic_installed_path()), *ours = bundle_version(mic_bundled_path());
            if (ours && installed && ![installed isEqualToString:ours]) status |= RDC_MEDIA_MIC_OUTDATED;
        }
        if (mic_device() != kAudioObjectUnknown) status |= RDC_MEDIA_MIC;
        return status;
    }
}

static NSString *sh_quote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *applescript_string(NSString *s) {
    return [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\""
                                                                                                withString:@"\\\""];
}

// Runs a shell command as administrator through the system's password dialog (osascript's
// "do shell script … with administrator privileges"), which shows `prompt`. 0 — done,
// 1 — cancelled, -1 — failed.
static int run_as_admin(NSString *command, NSString *prompt) {
    NSString *script = [NSString stringWithFormat:@"do shell script \"%@\" with prompt \"%@\" with administrator privileges",
                                                  applescript_string(command), applescript_string(prompt)];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    t.arguments = @[ @"-e", script ];
    NSPipe *errPipe = [NSPipe pipe];
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    t.standardError = errPipe;
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) {
        rlog("osascript: %s", e.localizedDescription.UTF8String);
        return -1;
    }
    NSData *errData = [errPipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    if (t.terminationStatus == 0) return 0;
    NSString *err = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
    if ([err containsString:@"-128"]) return 1;  // "User canceled."
    rlog("administrator command failed: %s",
         [err stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].UTF8String);
    return -1;
}

int rdc_mic_install(int install) {
    @autoreleasepool {
        NSString *dst = mic_installed_path();
        // launchd starts coreaudiod again at once; kickstart can be refused under SIP, killall cannot.
        NSString *restart = @"(/bin/launchctl kickstart -kp system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod)";
        NSString *cmd;
        if (install) {
            NSString *src = mic_bundled_path();
            if (![NSFileManager.defaultManager fileExistsAtPath:src]) {
                rlog("this build of RDC carries no %s", kMicDriverName.UTF8String);
                return -2;
            }
            // Copy, make it root's and strip any quarantine, then restart the audio system: it loads
            // plug-ins only at start (audio pauses for a second).
            cmd = [NSString stringWithFormat:@"/bin/mkdir -p %@ && /bin/rm -rf %@ && /bin/cp -R %@ %@ && "
                                             @"/usr/sbin/chown -R root:wheel %@ && /bin/chmod -R go-w %@ && "
                                             @"(/usr/bin/xattr -cr %@ || true) && %@",
                                             sh_quote(kMicDriverDir), sh_quote(dst), sh_quote(src), sh_quote(kMicDriverDir),
                                             sh_quote(dst), sh_quote(dst), sh_quote(dst), restart];
        } else {
            cmd = [NSString stringWithFormat:@"/bin/rm -rf %@ && %@", sh_quote(dst), restart];
        }
        int rc = run_as_admin(cmd, install ? @"RDC wants to install RDC Microphone: then a phone connected to RDC can be a microphone of this Mac. "
                                             @"Sound pauses for a second while the audio system restarts."
                                           : @"RDC wants to remove RDC Microphone. Sound pauses for a second while the audio system restarts.");
        if (rc == 0) rlog(install ? "RDC Microphone installed, the audio system restarted" : "RDC Microphone removed, the audio system restarted");
        return rc;
    }
}

void rdc_mic_start(void) {
    pthread_mutex_lock(&g_mic_mutex);
    char err[128];
    if (rdc_mic_writer_open(&g_mic, err, sizeof err) != 0) rlog("phone microphone: %s", err);
    rdc_mic_writer_start(&g_mic);
    pthread_mutex_unlock(&g_mic_mutex);
}

void rdc_mic_push(const int16_t *pcm, int frames) {
    if (frames <= 0) return;
    pthread_mutex_lock(&g_mic_mutex);
    rdc_mic_writer_push(&g_mic, pcm, (uint32_t)frames, now_us());
    pthread_mutex_unlock(&g_mic_mutex);
}

void rdc_mic_stop(void) {
    pthread_mutex_lock(&g_mic_mutex);
    rdc_mic_writer_stop(&g_mic);
    pthread_mutex_unlock(&g_mic_mutex);
}

int rdc_camera_install(int install, const void *dll, size_t dll_len) { return -1; }
int rdc_app_prepare(const void *camera_dll, size_t camera_dll_len) { return 0; }
void rdc_camera_start(void) {}
void rdc_camera_push(const uint8_t *jpeg, size_t len, int width, int height) {}
void rdc_camera_stop(void) {}

// ---------------------------------------------------------------------------
// App window
//
// One look with the viewer and the site (web/, site/): dark, a translucent background, grouped
// rows with a symbol, a title and one short line under it. The main window shows the code, the
// two links and what is happening now; everything set once lives in Settings.

static const CGFloat kMainWidth = 340, kSettingsWidth = 420;

static NSImage *sym(NSString *name, CGFloat size, NSFontWeight weight) {
    NSImage *i = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    return [i imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:weight]];
}

static NSButton *icon_button(NSString *symbol, NSString *tip, id target, SEL action) {
    NSButton *b = [NSButton buttonWithImage:sym(symbol, 13, NSFontWeightMedium) target:target action:action];
    b.bordered = NO;
    b.toolTip = tip;
    b.contentTintColor = NSColor.secondaryLabelColor;
    [b.widthAnchor constraintEqualToConstant:28].active = YES;
    [b.heightAnchor constraintEqualToConstant:28].active = YES;
    return b;
}

// A copy button answers with a check mark for a moment.
static void flash_done(NSButton *b) {
    NSImage *was = b.image;
    b.image = sym(@"checkmark", 13, NSFontWeightSemibold);
    b.contentTintColor = NSColor.systemGreenColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        b.image = was;
        b.contentTintColor = NSColor.secondaryLabelColor;
    });
}

static NSTextField *make_label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

static NSButton *push_button(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    return b;
}

static NSSwitch *make_switch(id target, SEL action) {
    NSSwitch *s = [NSSwitch new];
    s.controlSize = NSControlSizeSmall;
    s.target = target;
    s.action = action;
    return s;
}

// A row of a group: a symbol, a title with one line under it, and controls on the right.
@interface RDCRow : NSStackView
@property(nonatomic, strong) NSImageView *icon;
@property(nonatomic, strong) NSTextField *title;
@property(nonatomic, strong) NSTextField *detail;
- (void)setDetailText:(NSString *)text;
@end

@implementation RDCRow
- (void)setDetailText:(NSString *)text {
    self.detail.stringValue = text ?: @"";
    self.detail.toolTip = text.length > 40 ? text : nil;
    self.detail.hidden = text.length == 0;
}
@end

static RDCRow *make_row(NSString *symbol, NSString *title, NSString *detail, NSArray<NSView *> *controls) {
    RDCRow *r = [RDCRow new];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.alignment = NSLayoutAttributeCenterY;
    r.spacing = 10;
    r.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 10);
    r.distribution = NSStackViewDistributionFill;  // the text takes the slack: controls sit at the right edge
    if (symbol) {
        r.icon = [NSImageView imageViewWithImage:sym(symbol, 14, NSFontWeightRegular)];
        r.icon.contentTintColor = NSColor.secondaryLabelColor;
        [r.icon.widthAnchor constraintEqualToConstant:22].active = YES;
        [r.icon setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [r addArrangedSubview:r.icon];
    }
    r.title = make_label(title, 13, NSFontWeightMedium, NSColor.labelColor);
    r.detail = make_label(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    [r setDetailText:detail];
    NSStackView *text = [NSStackView stackViewWithViews:@[ r.title, r.detail ]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 1;
    for (NSView *v in @[ r.title, r.detail, text ]) {
        [v setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [v setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    [r addArrangedSubview:text];
    for (NSView *c in controls) {
        [c setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [r addArrangedSubview:c];
    }
    [r.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return r;
}

// Rows on one rounded plate, as in System Settings. A hidden row takes no room.
static NSStackView *make_group(NSArray<NSView *> *rows, CGFloat width) {
    NSStackView *g = [NSStackView stackViewWithViews:rows];
    g.orientation = NSUserInterfaceLayoutOrientationVertical;
    g.alignment = NSLayoutAttributeLeading;
    g.spacing = 0;
    g.wantsLayer = YES;
    g.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.055].CGColor;
    g.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.07].CGColor;
    g.layer.borderWidth = 1;
    g.layer.cornerRadius = 12;
    [g.widthAnchor constraintEqualToConstant:width].active = YES;
    for (NSView *r in rows) [r.widthAnchor constraintEqualToAnchor:g.widthAnchor].active = YES;
    return g;
}

static NSTextField *make_header(NSString *text) {
    NSTextField *l = make_label(text, 12, NSFontWeightSemibold, NSColor.secondaryLabelColor);
    return l;
}

// A dark window with a translucent background and the content right under the title bar.
static NSWindow *make_window(NSString *title, CGFloat width, BOOL miniaturizable, BOOL showTitle) {
    NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView;
    if (miniaturizable) mask |= NSWindowStyleMaskMiniaturizable;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, 300) styleMask:mask backing:NSBackingStoreBuffered defer:NO];
    w.title = title;
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = showTitle ? NSWindowTitleVisible : NSWindowTitleHidden;
    w.movableByWindowBackground = YES;
    w.releasedWhenClosed = NO;
    NSVisualEffectView *bg = [NSVisualEffectView new];
    bg.material = NSVisualEffectMaterialUnderWindowBackground;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    w.contentView = bg;
    return w;
}

static void set_content(NSWindow *w, NSStackView *stack) {
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *bg = w.contentView;
    [bg addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:bg.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor],
    ]];
}

// Each window is as tall as what it shows, with its top edge in place.
static void fit_window(NSWindow *w) {
    if (!w) return;
    NSView *stack = w.contentView.subviews.firstObject;
    [w.contentView layoutSubtreeIfNeeded];
    CGFloat want = stack.fittingSize.height;
    NSRect frame = w.frame;
    CGFloat have = [w contentRectForFrameRect:frame].size.height;
    if (fabs(want - have) < 1) return;
    frame.origin.y -= want - have;
    frame.size.height += want - have;
    [w setFrame:frame display:YES animate:w.visible];
}

static NSString *bare_link(NSString *link) {
    for (NSString *p in @[ @"https://", @"http://" ])
        if ([link hasPrefix:p]) return [link substringFromIndex:p.length];
    return link;
}

static void copy_text(NSString *s) {
    if (s.length == 0) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
}

@interface RDCAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSView *statusDot;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *codeLabel;
@property(nonatomic, strong) RDCRow *lanRow;
@property(nonatomic, strong) RDCRow *remoteRow;
@property(nonatomic, strong) NSButton *remoteCopy;
@property(nonatomic, strong) NSButton *remoteOpen;
@property(nonatomic, strong) NSStackView *permGroup;
@property(nonatomic, strong) RDCRow *screenRow;
@property(nonatomic, strong) RDCRow *inputRow;
@property(nonatomic, strong) NSStackView *mediaGroup;
@property(nonatomic, strong) RDCRow *mediaRow;
@property(nonatomic, strong) NSButton *kickButton;
@property(nonatomic, strong) NSButton *settingsButton;
@property(nonatomic) BOOL aiActive;
@property(nonatomic) BOOL remoteOff;
@property(nonatomic) BOOL connected;
@property(nonatomic) BOOL screenOk, inputOk;
@property(nonatomic, copy) NSString *peers;
@property(nonatomic, copy) NSString *link;
@property(nonatomic, copy) NSString *remoteLink;

@property(nonatomic, strong) NSWindow *settingsWindow;
@property(nonatomic, strong) NSSwitch *setPermanent;
@property(nonatomic, strong) RDCRow *permSetupRow;
@property(nonatomic, strong) NSSwitch *setLogin;
@property(nonatomic, strong) NSSwitch *setAwake;
@property(nonatomic, strong) RDCRow *micRow;
@property(nonatomic, strong) NSSwitch *setMic;
@property(nonatomic, strong) NSButton *micUpdate;
@property(nonatomic) BOOL micBusy;
@property(nonatomic) int mediaStatus;
@property(nonatomic, strong) RDCRow *relayRow;
@property(nonatomic, strong) NSPopUpButton *setRelay;
@property(nonatomic, strong) NSView *relayUrlRow;
@property(nonatomic, strong) NSTextField *setRelayUrl;
@property(nonatomic, strong) NSSwitch *setAuto;
@property(nonatomic, strong) RDCRow *versionRow;
@property(nonatomic, strong) NSButton *setCheck;
@property(nonatomic, strong) NSButton *setInstall;

@property(nonatomic, strong) NSWindow *permWindow;
@property(nonatomic, strong) NSImageView *permLinkQR;
@property(nonatomic, strong) NSImageView *permAuthQR;
@property(nonatomic, strong) NSTextField *permKeyLabel;
@property(nonatomic, strong) NSButton *permShow;
@property(nonatomic) BOOL permRevealed;
@property(nonatomic, strong) id activity;
- (void)refreshSettings;
- (void)refreshMedia;
- (void)refreshMain;
@end

// Settings window state (written from any thread, drawn on the main one).
static NSString *g_set_version = @"";
static NSString *g_set_status = @"";
static int g_set_auto = 1, g_set_can_install = 0, g_set_busy = 0;

// Permanent access, as the host last described it.
static int g_perm_on;
static NSString *g_perm_link = @"";
static NSString *g_perm_key = @"";
static NSImage *g_perm_link_qr, *g_perm_auth_qr;

static rdc_ctx_cb g_on_ready;
static rdc_action_cb g_on_action;
static void *g_app_ctx;
static RDCAppDelegate *g_app;

static void act(int action) {
    if (g_on_action) g_on_action(g_app_ctx, action);
}

// A QR code as an image: black on white whatever the theme, with the quiet zone scanners need.
static NSImage *qr_image(const uint8_t *modules, int size, CGFloat side) {
    if (!modules || size <= 0) return nil;
    NSData *data = [NSData dataWithBytes:modules length:(NSUInteger)(size * size)];
    return [NSImage imageWithSize:NSMakeSize(side, side)
                          flipped:YES
                   drawingHandler:^BOOL(NSRect r) {
                       const uint8_t *m = data.bytes;
                       CGFloat cell = r.size.width / (size + 8);
                       [NSColor.whiteColor setFill];
                       [[NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.width * 0.06 yRadius:r.size.width * 0.06] fill];
                       [NSColor.blackColor setFill];
                       for (int y = 0; y < size; y++)
                           for (int x = 0; x < size; x++)
                               if (m[y * size + x]) NSRectFill(NSMakeRect((x + 4) * cell, (y + 4) * cell, cell + 0.5, cell + 0.5));
                       return YES;
                   }];
}

@implementation RDCAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    NSMenuItem *prefs = [appMenu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
    prefs.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide RDC" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit RDC" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSMenuItem *editItem = [NSMenuItem new];
    [bar addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    NSApp.mainMenu = bar;

    const CGFloat inner = kMainWidth - 40;
    self.window = make_window(@"RDC", kMainWidth, YES, NO);

    // The title bar: the traffic lights on the left, Settings on the right.
    self.settingsButton = icon_button(@"gearshape", @"Settings (⌘,)", self, @selector(showSettings:));
    NSView *spring = [NSView new];
    [spring setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *top = [NSStackView stackViewWithViews:@[ spring, self.settingsButton ]];
    [top.widthAnchor constraintEqualToConstant:inner + 12].active = YES;

    // What is happening: a dot and a few words.
    self.statusDot = [NSView new];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius = 4;
    [self.statusDot.widthAnchor constraintEqualToConstant:8].active = YES;
    [self.statusDot.heightAnchor constraintEqualToConstant:8].active = YES;
    self.statusLabel = make_label(@"Starting…", 13, NSFontWeightMedium, NSColor.secondaryLabelColor);
    NSStackView *status = [NSStackView stackViewWithViews:@[ self.statusDot, self.statusLabel ]];
    status.spacing = 7;
    [self.statusLabel.widthAnchor constraintLessThanOrEqualToConstant:inner - 20].active = YES;

    // The code, with "new code" beside it; a blank of the same width keeps the digits centered.
    self.codeLabel = make_label(@"— — —", 34, NSFontWeightSemibold, NSColor.labelColor);
    self.codeLabel.font = [NSFont monospacedSystemFontOfSize:34 weight:NSFontWeightSemibold];
    // A click copies it: there is nothing else to do with a code.
    self.codeLabel.toolTip = @"Click to copy";
    [self.codeLabel addGestureRecognizer:[[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(copyCode:)]];
    NSButton *renew = icon_button(@"arrow.clockwise", @"New code — the old one and its links stop working", self, @selector(newCode:));
    NSView *balance = [NSView new];
    [balance.widthAnchor constraintEqualToConstant:28].active = YES;
    NSStackView *code = [NSStackView stackViewWithViews:@[ balance, self.codeLabel, renew ]];
    code.spacing = 6;

    // The two links.
    NSButton *copyLan = icon_button(@"doc.on.doc", @"Copy link", self, @selector(copyLink:));
    NSButton *openLan = icon_button(@"arrow.up.right", @"Open in browser", self, @selector(openLink:));
    self.lanRow = make_row(@"wifi", @"This network", @"", @[ copyLan, openLan ]);
    self.lanRow.detail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.remoteCopy = icon_button(@"doc.on.doc", @"Copy link", self, @selector(copyRemoteLink:));
    self.remoteOpen = icon_button(@"arrow.up.right", @"Open in browser", self, @selector(openRemoteLink:));
    self.remoteRow = make_row(@"globe", @"From anywhere", @"Connecting…", @[ self.remoteCopy, self.remoteOpen ]);
    self.remoteRow.detail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.remoteRow.toolTip = @"Works from mobile data and other networks";
    NSStackView *links = make_group(@[ self.lanRow, self.remoteRow ], inner);

    // Missing permissions: one orange row each, with the button that fixes it.
    self.screenRow = make_row(@"rectangle.dashed", @"Screen Recording", @"Needed to show the screen",
                              @[ push_button(@"Allow…", self, @selector(askScreen:)) ]);
    self.inputRow = make_row(@"cursorarrow.click", @"Accessibility", @"Needed for mouse and keyboard",
                             @[ push_button(@"Allow…", self, @selector(askInput:)) ]);
    for (RDCRow *r in @[ self.screenRow, self.inputRow ]) r.icon.contentTintColor = NSColor.systemOrangeColor;
    self.permGroup = make_group(@[ self.screenRow, self.inputRow ], inner);
    self.permGroup.hidden = YES;

    // A viewer's microphone, live on this Mac.
    self.mediaRow = make_row(@"mic.fill", @"Phone microphone", @"", @[ push_button(@"Stop", self, @selector(stopMedia:)) ]);
    self.mediaRow.icon.contentTintColor = NSColor.systemGreenColor;
    self.mediaGroup = make_group(@[ self.mediaRow ], inner);
    self.mediaGroup.hidden = YES;

    // Ending the session: there only while someone is connected.
    self.kickButton = [NSButton buttonWithTitle:@"Disconnect" target:self action:@selector(disconnectAll:)];
    self.kickButton.controlSize = NSControlSizeLarge;
    self.kickButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [self.kickButton.widthAnchor constraintEqualToConstant:inner].active = YES;
    self.kickButton.hidden = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        top, status, code, links, self.permGroup, self.mediaGroup, self.kickButton
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(6, 20, 22, 20);
    [stack setCustomSpacing:2 afterView:top];
    [stack setCustomSpacing:4 afterView:status];
    [stack setCustomSpacing:18 afterView:code];
    set_content(self.window, stack);
    [self refreshMedia];
    [self refreshMain];
    fit_window(self.window);
    [self.window center];
    // Waiting for connections in the background is this app's work: no App Nap.
    self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                 reason:@"Waiting for remote desktop connections"];
    autostart_repair();
    keep_awake(rdc_pref_bool("keep_awake", 0));
    // Started by the system at login: stay out of the way until the Dock icon is clicked.
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--login"]) {
        [self.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }

    if (g_on_ready) g_on_ready(g_app_ctx);
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    if (!visible) [self.window makeKeyAndOrderFront:nil];
    return YES;
}

// The dot, the words beside it, the permission rows and the Disconnect button.
- (void)refreshMain {
    BOOL missing = !self.screenOk || !self.inputOk;
    NSColor *dot = self.aiActive ? NSColor.systemRedColor
                 : self.connected ? NSColor.systemGreenColor
                 : missing ? NSColor.systemOrangeColor
                           : NSColor.tertiaryLabelColor;
    self.statusDot.layer.backgroundColor = dot.CGColor;
    NSString *text = self.connected ? self.peers : missing ? @"Needs permissions" : @"Ready to connect";
    self.statusLabel.stringValue = text ?: @"";
    self.statusLabel.textColor = self.connected ? NSColor.labelColor : NSColor.secondaryLabelColor;
    self.statusLabel.toolTip = self.connected ? self.peers : nil;
    self.screenRow.hidden = self.screenOk;
    self.inputRow.hidden = self.inputOk;
    self.permGroup.hidden = !missing;
    self.kickButton.hidden = !self.connected;
    self.kickButton.title = self.aiActive ? @"Stop AI Agent" : @"Disconnect";
    self.kickButton.bezelColor = self.aiActive ? NSColor.systemRedColor : nil;
    self.settingsButton.image = sym(g_set_can_install ? @"arrow.down.circle.fill" : @"gearshape", 13, NSFontWeightMedium);
    self.settingsButton.contentTintColor = g_set_can_install ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
    self.settingsButton.toolTip = g_set_can_install ? @"Update available" : @"Settings (⌘,)";
    fit_window(self.window);
}

- (void)refreshMedia {
    self.mediaStatus = rdc_media_status();
    [self refreshSettings];
}

- (void)installMic:(BOOL)install {
    if (self.micBusy) return;
    self.micBusy = YES;
    [self refreshSettings];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = rdc_mic_install(install);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.micBusy = NO;
            [self refreshMedia];
            if (rc < 0) {
                NSAlert *alert = [NSAlert new];
                alert.messageText = install ? @"Could not install RDC Microphone" : @"Could not remove RDC Microphone";
                alert.informativeText = @"Details are in ~/Library/Logs/RDC/rdc.log";
                [alert runModal];
            }
        });
    });
}

- (void)toggleMic:(NSSwitch *)sender {
    [self installMic:sender.state == NSControlStateValueOn];
}

- (void)updateMic:(id)sender {
    [self installMic:YES];
}

- (void)stopMedia:(id)sender {
    act(RDC_ACTION_STOP_MEDIA);
}

// With "open at login" on, RDC is there to be reached: closing the window leaves it running.
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    return !autostart_on();
}

- (void)copyCode:(id)sender {
    NSString *code = self.codeLabel.stringValue;
    if (![code hasPrefix:@"—"]) {
        copy_text([code stringByReplacingOccurrencesOfString:@" " withString:@""]);
        self.codeLabel.textColor = NSColor.systemGreenColor;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.codeLabel.textColor = NSColor.labelColor;
        });
    }
}

- (void)copyLink:(NSButton *)sender {
    copy_text(self.link);
    flash_done(sender);
}

- (void)openLink:(id)sender {
    if (self.link.length) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:self.link]];
}

- (void)copyRemoteLink:(NSButton *)sender {
    copy_text(self.remoteLink);
    flash_done(sender);
}

- (void)openRemoteLink:(id)sender {
    if (self.remoteLink.length) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:self.remoteLink]];
}

- (void)askScreen:(id)sender {
    if (!rdc_screen_access(1)) rdc_open_privacy(0);
}

- (void)askInput:(id)sender {
    if (!rdc_input_access(1)) rdc_open_privacy(1);
}

- (void)disconnectAll:(id)sender {
    act(self.aiActive ? RDC_ACTION_STOP_AI : RDC_ACTION_DISCONNECT_ALL);
}

- (void)newCode:(id)sender {
    act(RDC_ACTION_NEW_CODE);
}

- (void)showSettings:(id)sender {
    if (!self.settingsWindow) {
        const CGFloat inner = kSettingsWidth - 40;
        NSWindow *w = make_window(@"Settings", kSettingsWidth, NO, YES);

        // Reaching this Mac when no one is at it.
        self.setPermanent = make_switch(self, @selector(togglePermanent:));
        RDCRow *perm = make_row(@"key", @"Permanent access", @"Your own link, opened with authenticator codes", @[ self.setPermanent ]);
        self.permSetupRow = make_row(@"qrcode", @"Phone", @"Scan the link and add the code to your authenticator",
                                     @[ push_button(@"Set Up…", self, @selector(showPermanent:)) ]);
        self.setLogin = make_switch(self, @selector(toggleLogin:));
        RDCRow *login = make_row(@"power", @"Open at login", @"Starts hidden and keeps running when closed", @[ self.setLogin ]);
        self.setAwake = make_switch(self, @selector(toggleAwake:));
        RDCRow *awake = make_row(@"moon.zzz", @"Keep Mac awake", @"A sleeping Mac can't be reached", @[ self.setAwake ]);
        NSStackView *access = make_group(@[ perm, self.permSetupRow, login, awake ], inner);

        // The viewer's phone as this Mac's microphone.
        self.setMic = make_switch(self, @selector(toggleMic:));
        self.micUpdate = push_button(@"Update", self, @selector(updateMic:));
        self.micRow = make_row(@"mic", @"Phone microphone", @"", @[ self.micUpdate, self.setMic ]);
        NSStackView *mic = make_group(@[ self.micRow ], inner);

        // The relay: the way through when a phone and this Mac cannot connect directly.
        self.setRelay = [NSPopUpButton new];
        self.setRelay.controlSize = NSControlSizeSmall;
        self.setRelay.font = [NSFont systemFontOfSize:12];
        [self.setRelay addItemsWithTitles:@[ @"RDC's", @"My own", @"Off" ]];
        self.setRelay.target = self;
        self.setRelay.action = @selector(relayChosen:);
        self.relayRow = make_row(@"arrow.triangle.branch", @"Relay", @"", @[ self.setRelay ]);
        self.setRelayUrl = [NSTextField textFieldWithString:@""];
        self.setRelayUrl.placeholderString = @"https://rdc-relay.<you>.workers.dev";
        self.setRelayUrl.controlSize = NSControlSizeSmall;
        self.setRelayUrl.font = [NSFont systemFontOfSize:12];
        self.setRelayUrl.bezelStyle = NSTextFieldRoundedBezel;
        self.setRelayUrl.target = self;
        self.setRelayUrl.action = @selector(relayUrlEntered:);
        NSButton *relayHow = icon_button(@"questionmark.circle", @"How to set up your own relay", self, @selector(relayHowTo:));
        NSStackView *urlRow = [NSStackView stackViewWithViews:@[ self.setRelayUrl, relayHow ]];
        urlRow.spacing = 6;
        urlRow.edgeInsets = NSEdgeInsetsMake(0, 44, 10, 10);
        self.relayUrlRow = urlRow;
        NSStackView *relay = make_group(@[ self.relayRow, urlRow ], inner);

        // Updates.
        self.setAuto = make_switch(self, @selector(toggleAuto:));
        RDCRow *autoRow = make_row(@"arrow.down.circle", @"Automatic updates", @"Signed, installed when no one is connected", @[ self.setAuto ]);
        self.setCheck = push_button(@"Check", self, @selector(checkUpdate:));
        self.setInstall = push_button(@"Update", self, @selector(installUpdate:));
        self.setInstall.keyEquivalent = @"\r";
        self.versionRow = make_row(@"info.circle", @"RDC", @"", @[ self.setCheck, self.setInstall ]);
        NSStackView *updates = make_group(@[ autoRow, self.versionRow ], inner);

        NSTextField *h1 = make_header(@"Access"), *h2 = make_header(@"Phone"), *h3 = make_header(@"Connection"), *h4 = make_header(@"Updates");
        NSStackView *stack = [NSStackView stackViewWithViews:@[ h1, access, h2, mic, h3, relay, h4, updates ]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 8;
        stack.edgeInsets = NSEdgeInsetsMake(40, 20, 22, 20);
        for (NSView *g in @[ access, mic, relay ]) [stack setCustomSpacing:20 afterView:g];
        for (NSView *h in @[ h1, h2, h3, h4 ]) [h.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:24].active = YES;
        set_content(w, stack);
        self.settingsWindow = w;
        [self refreshSettings];
        fit_window(w);
        [w center];
    }
    [self refreshSettings];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)buildPermanentWindow {
    NSWindow *w = make_window(@"Permanent Access", 360, NO, YES);

    NSTextField *s1 = make_label(@"1  Open your link on the phone", 13, NSFontWeightSemibold, NSColor.labelColor);
    NSTextField *s1d = make_label(@"Point the camera here, then add the page to the Home Screen", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.permLinkQR = [NSImageView new];
    [self.permLinkQR.widthAnchor constraintEqualToConstant:176].active = YES;
    [self.permLinkQR.heightAnchor constraintEqualToConstant:176].active = YES;
    NSButton *copy = push_button(@"Copy Link", self, @selector(copyPermanentLink:));

    NSTextField *s2 = make_label(@"2  Add RDC to your authenticator", 13, NSFontWeightSemibold, NSColor.labelColor);
    NSTextField *s2d = make_label(@"Google Authenticator, 1Password or any other", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.permShow = push_button(@"Show Code…", self, @selector(revealPermanent:));
    self.permShow.image = sym(@"touchid", 12, NSFontWeightRegular);
    self.permShow.imagePosition = NSImageLeading;
    self.permAuthQR = [NSImageView new];
    [self.permAuthQR.widthAnchor constraintEqualToConstant:176].active = YES;
    [self.permAuthQR.heightAnchor constraintEqualToConstant:176].active = YES;
    self.permKeyLabel = make_label(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.permKeyLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.permKeyLabel.selectable = YES;
    self.permKeyLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.permKeyLabel.widthAnchor constraintLessThanOrEqualToConstant:300].active = YES;

    NSButton *reset = [NSButton buttonWithTitle:@"New Link and Key…" target:self action:@selector(resetPermanent:)];
    reset.bordered = NO;
    reset.font = [NSFont systemFontOfSize:12];
    reset.contentTintColor = NSColor.systemRedColor;

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        s1, s1d, self.permLinkQR, copy, s2, s2d, self.permShow, self.permAuthQR, self.permKeyLabel, reset
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(44, 24, 18, 24);
    [stack setCustomSpacing:2 afterView:s1];
    [stack setCustomSpacing:2 afterView:s2];
    [stack setCustomSpacing:26 afterView:copy];
    [stack setCustomSpacing:20 afterView:self.permKeyLabel];
    [stack setCustomSpacing:20 afterView:self.permShow];
    set_content(w, stack);
    self.permWindow = w;
}

- (void)refreshSettings {
    [self refreshMain];
    if (!self.settingsWindow) return;
    // Access
    if (!g_perm_on) self.permRevealed = NO;
    self.setPermanent.state = g_perm_on ? NSControlStateValueOn : NSControlStateValueOff;
    // The permanent link is a link from anywhere: without those connections there is none.
    self.setPermanent.enabled = !self.remoteOff;
    [(RDCRow *)self.setPermanent.superview setDetailText:self.remoteOff ? @"Needs connections from anywhere (started with --no-remote)"
                                                                        : @"Your own link, opened with authenticator codes"];
    self.permSetupRow.hidden = !g_perm_on;
    if (!g_perm_on) [self.permWindow orderOut:nil];
    self.setLogin.state = autostart_on() ? NSControlStateValueOn : NSControlStateValueOff;
    self.setAwake.state = rdc_pref_bool("keep_awake", 0) ? NSControlStateValueOn : NSControlStateValueOff;
    // Phone microphone
    int st = self.mediaStatus;
    BOOL installed = (st & RDC_MEDIA_MIC_INSTALLED) != 0;
    self.setMic.state = installed ? NSControlStateValueOn : NSControlStateValueOff;
    self.setMic.enabled = !self.micBusy;
    self.micUpdate.hidden = !(st & RDC_MEDIA_MIC_OUTDATED);
    self.micUpdate.enabled = !self.micBusy;
    [self.micRow setDetailText:self.micBusy ? @"Working…"
                               : (st & RDC_MEDIA_MIC) ? @"Pick “RDC Microphone” in any app"
                               : installed ? @"Restart the Mac to finish"
                                           : @"Asks for the administrator password once"];
    // Relay
    [self refreshRelay];
    // Updates
    NSString *version = g_set_version.length ? g_set_version : @"—";
    self.versionRow.title.stringValue = [NSString stringWithFormat:@"RDC %@", version];
    [self.versionRow setDetailText:g_set_status];
    self.setAuto.state = g_set_auto ? NSControlStateValueOn : NSControlStateValueOff;
    self.setCheck.hidden = g_set_can_install;
    self.setCheck.enabled = !g_set_busy;
    self.setInstall.hidden = !g_set_can_install;
    self.setInstall.enabled = g_set_can_install && !g_set_busy;
    // The setup window
    if (self.permWindow) {
        self.permLinkQR.image = g_perm_link_qr;
        self.permLinkQR.toolTip = g_perm_link;
        self.permShow.hidden = self.permRevealed;
        self.permAuthQR.hidden = !self.permRevealed;
        self.permKeyLabel.hidden = !self.permRevealed;
        self.permAuthQR.image = self.permRevealed ? g_perm_auth_qr : nil;
        self.permKeyLabel.stringValue = self.permRevealed ? g_perm_key : @"";
    }
    fit_window(self.settingsWindow);
    fit_window(self.permWindow);
}

- (void)showPermanent:(id)sender {
    if (!self.permWindow) [self buildPermanentWindow];
    self.permRevealed = NO;  // every visit asks again before the key is shown
    [self refreshSettings];
    fit_window(self.permWindow);
    [self.permWindow center];
    [self.permWindow makeKeyAndOrderFront:nil];
}

// The "relay" pref: not set — RDC's relay, "off" — none, otherwise the person's own.
- (void)refreshRelay {
    char buf[256];
    int n = rdc_pref_string("relay", buf, sizeof buf);
    NSString *v = n >= 0 ? @(buf) : @"";
    BOOL off = [v isEqualToString:@"off"], own = v.length > 0 && !off;
    if (self.setRelay.indexOfSelectedItem != 1 || own) [self.setRelay selectItemAtIndex:off ? 2 : own ? 1 : 0];
    BOOL ownShown = self.setRelay.indexOfSelectedItem == 1;
    self.relayUrlRow.hidden = !ownShown;
    if (own && ![self.setRelayUrl.stringValue isEqualToString:v] && self.settingsWindow.firstResponder != self.setRelayUrl.currentEditor)
        self.setRelayUrl.stringValue = v;
    [self.relayRow setDetailText:off ? @"Direct connections only"
                                 : ownShown ? (own ? @"Your Cloudflare Worker" : @"Enter its address and press Return")
                                            : @"When a phone can't connect directly"];
}

- (void)relayChosen:(NSPopUpButton *)sender {
    NSInteger i = sender.indexOfSelectedItem;
    if (i == 1) {
        // The address field takes over; until it holds an address, the choice stays as it was.
        [self refreshSettings];
        [self.settingsWindow makeFirstResponder:self.setRelayUrl];
        return;
    }
    rdc_set_pref_string("relay", i == 2 ? "off" : "");
    act(RDC_ACTION_RELAY_CHANGED);
    [self refreshSettings];
}

- (void)relayUrlEntered:(NSTextField *)sender {
    NSString *v = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([v hasSuffix:@"/"]) v = [v substringToIndex:v.length - 1];
    if (![v hasPrefix:@"https://"] || v.length < 12 || [v substringFromIndex:8].length == 0 ||
        [[v substringFromIndex:8] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#@ "]].location != NSNotFound) {
        [self.relayRow setDetailText:@"Needs https:// and no path"];
        return;
    }
    sender.stringValue = v;
    [self.relayRow setDetailText:@"Checking…"];
    // The relay answers {"rdc_relay":1} at its root.
    NSURL *u = [NSURL URLWithString:[v stringByAppendingString:@"/"]];
    [[NSURLSession.sharedSession dataTaskWithURL:u
                               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                                   BOOL ok = data && [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] containsString:@"rdc_relay"];
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                       if (!ok) {
                                           [self.relayRow setDetailText:err ? [@"Can't reach it: " stringByAppendingString:err.localizedDescription]
                                                                             : @"That is not an RDC relay"];
                                           return;
                                       }
                                       rdc_set_pref_string("relay", v.UTF8String);
                                       act(RDC_ACTION_RELAY_CHANGED);
                                       [self refreshSettings];
                                       [self.relayRow setDetailText:@"Your relay answers — in use"];
                                   });
                               }] resume];
}

- (void)relayHowTo:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/ANODs/RDC/tree/main/relay#readme"]];
}

- (void)togglePermanent:(NSSwitch *)sender {
    BOOL on = sender.state == NSControlStateValueOn;
    // The key file is held by whichever RDC opened it first: a second copy (a build next to the
    // installed app) cannot serve the link, and says so instead of the switch just jumping back.
    if (on && seed_open() == -2) {
        sender.state = NSControlStateValueOff;
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Another RDC on this Mac has permanent access";
        alert.informativeText = @"Quit the other copy of RDC, then turn it on here.";
        [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
        return;
    }
    act(on ? RDC_ACTION_PERMANENT_ON : RDC_ACTION_PERMANENT_OFF);
}

- (void)copyPermanentLink:(NSButton *)sender {
    copy_text(g_perm_link);
    NSString *was = sender.title;
    sender.title = @"Copied";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sender.title = was; });
}

// The authenticator key is as good as the codes: it appears only for the person at this Mac —
// Touch ID or the account password — never for someone who is merely connected.
- (void)revealPermanent:(id)sender {
    LAContext *auth = [LAContext new];
    NSError *e = nil;
    if (![auth canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&e]) {
        self.permRevealed = YES;  // this Mac has no password at all
        return [self refreshSettings];
    }
    [auth evaluatePolicy:LAPolicyDeviceOwnerAuthentication
         localizedReason:@"show the code for the authenticator app"
                   reply:^(BOOL ok, NSError *err) {
                       dispatch_async(dispatch_get_main_queue(), ^{
                           if (ok) self.permRevealed = YES;
                           [self refreshSettings];
                       });
                   }];
}

- (void)resetPermanent:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Make a new link and key?";
    alert.informativeText = @"The old link and the authenticator entry stop working.";
    [alert addButtonWithTitle:@"New Link and Key"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    self.permRevealed = NO;
    act(RDC_ACTION_PERMANENT_RESET);
}

- (void)toggleLogin:(NSSwitch *)sender {
    autostart_set(sender.state == NSControlStateValueOn);
    [self refreshSettings];
}

- (void)toggleAwake:(NSSwitch *)sender {
    int on = sender.state == NSControlStateValueOn;
    rdc_set_pref_bool("keep_awake", on);
    keep_awake(on);
}

- (void)toggleAuto:(NSSwitch *)sender {
    act(sender.state == NSControlStateValueOn ? RDC_ACTION_AUTO_UPDATE_ON : RDC_ACTION_AUTO_UPDATE_OFF);
}

- (void)checkUpdate:(id)sender {
    act(RDC_ACTION_CHECK_UPDATE);
}

- (void)installUpdate:(id)sender {
    act(RDC_ACTION_INSTALL_UPDATE);
}
@end

void rdc_settings_update(const char *version, int auto_update, const char *status, int can_install, int busy) {
    NSString *v = [NSString stringWithUTF8String:version];
    NSString *s = [NSString stringWithUTF8String:status];
    dispatch_async(dispatch_get_main_queue(), ^{
        g_set_version = v;
        g_set_status = s;
        g_set_auto = auto_update;
        g_set_can_install = can_install;
        g_set_busy = busy;
        [g_app refreshSettings];
    });
}

void rdc_app_set_permanent(int on, const char *link, const uint8_t *link_qr, int link_qr_size,
                           const uint8_t *auth_qr, int auth_qr_size, const char *secret_text) {
    NSString *l = [NSString stringWithUTF8String:link] ?: @"";
    NSString *k = [NSString stringWithUTF8String:secret_text] ?: @"";
    NSImage *lq = qr_image(link_qr, link_qr_size, 176);
    NSImage *aq = qr_image(auth_qr, auth_qr_size, 176);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![g_perm_key isEqualToString:k]) g_app.permRevealed = NO;  // a new key is hidden again
        g_perm_on = on;
        g_perm_link = l;
        g_perm_key = k;
        g_perm_link_qr = lq;
        g_perm_auth_qr = aq;
        [g_app refreshSettings];
    });
}

void rdc_app_run(rdc_ctx_cb on_ready, rdc_action_cb on_action, void *ctx) {
    @autoreleasepool {
        g_on_ready = on_ready;
        g_on_action = on_action;
        g_app_ctx = ctx;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        // Dark, as the viewer and the site.
        NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        g_app = [RDCAppDelegate new];
        NSApp.delegate = g_app;
        [NSApp run];
    }
}

void rdc_app_set_info(const char *code, const char *link) {
    NSString *c = [NSString stringWithUTF8String:code];
    NSString *l = [NSString stringWithUTF8String:link];
    dispatch_async(dispatch_get_main_queue(), ^{
        g_app.codeLabel.stringValue = c;
        g_app.link = l;
        [g_app.lanRow setDetailText:bare_link(l)];
    });
}

// The host says what "from anywhere" is doing in a caption; the row keeps its own title and
// shows the link, or a word about why there is none.
void rdc_app_set_remote(const char *caption, const char *link) {
    NSString *c = [NSString stringWithUTF8String:caption] ?: @"";
    NSString *l = [NSString stringWithUTF8String:link] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        g_app.remoteLink = l;
        BOOL none = l.length == 0;
        g_app.remoteOff = [c localizedCaseInsensitiveContainsString:@"off"];
        NSString *why = g_app.remoteOff ? @"Off" : @"Connecting…";
        [g_app.remoteRow setDetailText:none ? why : bare_link(l)];
        g_app.remoteCopy.hidden = none;
        g_app.remoteOpen.hidden = none;
        g_app.remoteRow.title.textColor = none ? NSColor.secondaryLabelColor : NSColor.labelColor;
        [g_app refreshSettings];
    });
}

// "Connected: a, b" while someone is there; anything else means waiting.
void rdc_app_set_status(const char *text) {
    NSString *t = [NSString stringWithUTF8String:text] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL on = [t hasPrefix:@"Connected: "];
        g_app.connected = on;
        g_app.peers = on ? [t substringFromIndex:11] : @"";
        [g_app refreshMain];
    });
}

void rdc_app_set_permissions(int screen_ok, int input_ok) {
    // Every couple of seconds from housekeeping: a good moment to look at the driver's state too.
    int media = rdc_media_status();
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL changed = g_app.screenOk != (screen_ok != 0) || g_app.inputOk != (input_ok != 0);
        g_app.screenOk = screen_ok != 0;
        g_app.inputOk = input_ok != 0;
        if (media != g_app.mediaStatus) [g_app refreshMedia];
        else if (changed) [g_app refreshMain];
    });
}

// What a viewer lends right now ("Phone microphone live — <peer>"), or nothing.
void rdc_app_set_media(const char *text) {
    NSString *t = [NSString stringWithUTF8String:text] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        NSRange dash = [t rangeOfString:@" — "];
        NSString *what = dash.location == NSNotFound ? t : [t substringToIndex:dash.location];
        NSString *who = dash.location == NSNotFound ? @"" : [t substringFromIndex:NSMaxRange(dash)];
        if ([what hasSuffix:@" live"]) what = [what substringToIndex:what.length - 5];
        g_app.mediaRow.title.stringValue = what;
        [g_app.mediaRow setDetailText:who];
        g_app.mediaRow.icon.image = sym([what localizedCaseInsensitiveContainsString:@"camera"] ? @"video.fill" : @"mic.fill", 14, NSFontWeightRegular);
        g_app.mediaGroup.hidden = t.length == 0;
        fit_window(g_app.window);
    });
}

void rdc_app_set_ai(int active) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_app.aiActive == (active != 0)) return;
        g_app.aiActive = active != 0;
        [g_app refreshMain];
        if (active) [NSApp requestUserAttention:NSInformationalRequest];
    });
}

// VideoToolbox on macOS encodes both H.264 and JPEG.
int rdc_codec_caps(void) { return 3; }
