// Платформенный слой macOS для RDC. Компилируется Zig'ом с -fobjc-arc.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ApplicationServices/ApplicationServices.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <time.h>
#include "shim.h"

// ---------------------------------------------------------------------------
// Лог

static FILE *g_log_file;
static pthread_mutex_t g_log_mutex = PTHREAD_MUTEX_INITIALIZER;

void rdc_mac_init(void) {
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/RDC"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        g_log_file = fopen([dir stringByAppendingPathComponent:@"rdc.log"].fileSystemRepresentation, "a");
    }
}

void rdc_mac_log(const char *msg) {
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
    rdc_mac_log(buf);
}

static uint64_t now_us(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000; }

uint64_t rdc_mac_now_us(void) { return now_us(); }

// ---------------------------------------------------------------------------
// Разрешения

int rdc_mac_screen_access(int prompt) {
    if (CGPreflightScreenCaptureAccess()) return 1;
    if (prompt) return CGRequestScreenCaptureAccess() ? 1 : 0;
    return 0;
}

int rdc_mac_input_access(int prompt) {
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : prompt ? @YES : @NO};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts) ? 1 : 0;
}

void rdc_mac_open_privacy(int which) {
    NSString *url = which == 0
        ? @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        : @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
    });
}

// ---------------------------------------------------------------------------
// Захват и кодирование. Всё состояние ниже меняется только на g_queue.

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
static CVPixelBufferRef g_last;      // последний полный кадр — для новых зрителей
static atomic_int g_force_key;
static uint64_t g_last_jpeg_us;
static int g_jpeg_pending;
static const uint64_t kJpegIntervalUs = 40000;  // JPEG не чаще 25 кадров/с

static void vt_output(void *refcon, void *frame_refcon, OSStatus status, VTEncodeInfoFlags flags,
                      CMSampleBufferRef sb) {
    @autoreleasepool {
        if (status != noErr) {
            rlog("кодирование: ошибка %d", (int)status);
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

        // AVCC (длина NAL в 4 байтах) → Annex B (00 00 00 01). На ключевых кадрах — SPS и PPS впереди.
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
    if (st != noErr) rlog("VideoToolbox: свойство %s не принято (%d)", name, (int)st);
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
        rlog("VideoToolbox: режим низкой задержки недоступен (%d), обычный", (int)st);
        st = VTCompressionSessionCreate(kCFAllocatorDefault, g_w, g_h, type, NULL, NULL, NULL, vt_output, NULL, &s);
    }
    if (st != noErr || !s) {
        rlog("VideoToolbox: не создать кодировщик %d (%d)", codec, (int)st);
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

// На g_queue.
static void sync_sessions(void) {
    if (g_w <= 0) return;
    if (g_want_h264 && !g_h264) g_h264 = make_session(RDC_CODEC_H264);
    if (!g_want_h264) destroy_session(&g_h264);
    if (g_want_jpeg && !g_jpeg) g_jpeg = make_session(RDC_CODEC_JPEG);
    if (!g_want_jpeg) destroy_session(&g_jpeg);
}

static void encode_jpeg(CVPixelBufferRef pb, uint64_t now);

// На g_queue.
static void encode_frame(CVPixelBufferRef pb, int force) {
    uint64_t now = now_us();
    CMTime pts = CMTimeMake((int64_t)now, 1000000);
    int key = force | atomic_exchange(&g_force_key, 0);
    if (g_h264) {
        NSDictionary *props = key ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES} : nil;
        OSStatus st = VTCompressionSessionEncodeFrame(g_h264, pb, pts, kCMTimeInvalid, (__bridge CFDictionaryRef)props,
                                                      (void *)(uintptr_t)RDC_CODEC_H264, NULL);
        if (st != noErr) rlog("H.264: кадр не принят (%d)", (int)st);
    }
    if (g_jpeg) {
        if (key || now - g_last_jpeg_us >= kJpegIntervalUs) {
            encode_jpeg(pb, now);
        } else if (!g_jpeg_pending) {
            // Последний кадр серии всё равно должен уйти: дошлём его, когда истечёт интервал.
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
    if (st != noErr) rlog("JPEG: кадр не принят (%d)", (int)st);
}

@implementation RDCStreamOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sb)) return;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!atts || CFArrayGetCount(atts) == 0) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;  // экран не менялся
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    if (g_last) CVPixelBufferRelease(g_last);
    g_last = CVPixelBufferRetain(pb);
    encode_frame(pb, 0);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    rlog("захват остановлен: %s", error.localizedDescription.UTF8String);
}
@end

int rdc_mac_capture_start(int max_width, int fps, rdc_frame_cb cb, void *ctx) {
    if (!g_queue) g_queue = dispatch_queue_create("rdc.capture", DISPATCH_QUEUE_SERIAL);
    if (g_stream) return 0;
    g_cb = cb;
    g_cb_ctx = ctx;
    g_fps = fps > 0 ? fps : 60;
    __block int result = -4;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error || content.displays.count == 0) {
            rlog("нет доступа к экрану: %s", error ? error.localizedDescription.UTF8String : "дисплеев нет");
            result = -1;
            dispatch_semaphore_signal(done);
            return;
        }
        CGDirectDisplayID main_id = CGMainDisplayID();
        SCDisplay *display = content.displays.firstObject;
        for (SCDisplay *d in content.displays)
            if (d.displayID == main_id) display = d;

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        float scale = filter.pointPixelScale > 0 ? filter.pointPixelScale : 1;
        int w = (int)(display.width * scale), h = (int)(display.height * scale);
        if (max_width > 0 && w > max_width) {
            h = (int)((double)h * max_width / w);
            w = max_width;
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

        dispatch_sync(g_queue, ^{
            g_w = w;
            g_h = h;
            sync_sessions();
        });

        g_output = [RDCStreamOutput new];
        g_stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:g_output];
        NSError *add_error = nil;
        if (![g_stream addStreamOutput:g_output type:SCStreamOutputTypeScreen sampleHandlerQueue:g_queue error:&add_error]) {
            rlog("захват: %s", add_error.localizedDescription.UTF8String);
            g_stream = nil;
            result = -2;
            dispatch_semaphore_signal(done);
            return;
        }
        [g_stream startCaptureWithCompletionHandler:^(NSError *start_error) {
            if (start_error) {
                rlog("захват не запустился: %s", start_error.localizedDescription.UTF8String);
                g_stream = nil;
                result = -3;
            } else {
                rlog("захват: %dx%d, до %d кадров/с", w, h, g_fps);
                result = 0;
            }
            dispatch_semaphore_signal(done);
        }];
    }];

    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) return -5;
    return result;
}

void rdc_mac_capture_stop(void) {
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
    rlog("захват остановлен");
}

void rdc_mac_set_codecs(int h264, int jpeg) {
    if (!g_queue) g_queue = dispatch_queue_create("rdc.capture", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_queue, ^{
        g_want_h264 = h264 != 0;
        g_want_jpeg = jpeg != 0;
        sync_sessions();
    });
}

void rdc_mac_request_keyframe(void) {
    if (!g_queue) return;
    dispatch_async(g_queue, ^{
        if (g_last)
            encode_frame(g_last, 1);
        else
            atomic_store(&g_force_key, 1);
    });
}

void rdc_mac_set_bitrate(int bits_per_second) {
    if (!g_queue || bits_per_second <= 0) return;
    dispatch_async(g_queue, ^{
        g_bitrate = bits_per_second;
        if (g_h264) set_prop(g_h264, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef) @(g_bitrate), "AverageBitRate");
    });
}

// ---------------------------------------------------------------------------
// Ввод. Все события идут через одну последовательную очередь — порядок сохраняется.

static dispatch_queue_t g_input_queue;
static CGEventSourceRef g_src;
static CGEventFlags g_flags;
static int g_buttons;           // биты: 1 левая, 2 правая, 4 средняя
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

static CGPoint to_point(double nx, double ny) {
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    nx = nx < 0 ? 0 : nx > 1 ? 1 : nx;
    ny = ny < 0 ? 0 : ny > 1 ? 1 : ny;
    return CGPointMake(b.origin.x + nx * (b.size.width - 1), b.origin.y + ny * (b.size.height - 1));
}

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
    case 0x7B: case 0x7C: case 0x7D: case 0x7E:  // стрелки
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

void rdc_mac_mouse_move(double nx, double ny) {
    dispatch_async(input_queue(), ^{ mouse_move_now(to_point(nx, ny)); });
}

void rdc_mac_mouse_button(int button, int down, double nx, double ny) {
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

void rdc_mac_scroll(double dx, double dy) {
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

void rdc_mac_key(int mac_keycode, int down) {
    dispatch_async(input_queue(), ^{ key_now(mac_keycode, down); });
}

void rdc_mac_release_all(void) {
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

void rdc_mac_cursor_pos(double *nx, double *ny) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = e ? CGEventGetLocation(e) : CGPointZero;
    if (e) CFRelease(e);
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    double x = b.size.width > 1 ? (p.x - b.origin.x) / (b.size.width - 1) : 0.5;
    double y = b.size.height > 1 ? (p.y - b.origin.y) / (b.size.height - 1) : 0.5;
    *nx = x < 0 ? 0 : x > 1 ? 1 : x;
    *ny = y < 0 ? 0 : y > 1 ? 1 : y;
}

// ---------------------------------------------------------------------------
// Сеть и система

void *rdc_mac_read_file(const char *path, size_t *len) {
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

int rdc_mac_lan_ipv4(char *buf, int buflen) {
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
// Обновления

void *rdc_mac_http_get(const char *url, size_t max_len, size_t *len, int *status) {
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
                                                        rlog("сеть: %s", e.localizedDescription.UTF8String);
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

int rdc_mac_write_temp(const char *name, const void *data, size_t len, char *path_out, int path_len) {
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

int rdc_mac_bundle_path(char *buf, int buflen) {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    if (![bundle.pathExtension isEqualToString:@"app"]) return -1;
    return [bundle getCString:buf maxLength:(NSUInteger)buflen encoding:NSUTF8StringEncoding] ? 0 : -1;
}

void rdc_mac_cleanup_old_bundles(void) {
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

int rdc_mac_install_update(const char *zip_path, const char *version) {
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
            rlog("обновление: в архиве не RDC %s", version);
            return -4;
        }
        if (run_tool(@"/usr/bin/codesign", @[ @"--verify", @"--strict", fresh ]) != 0) {
            rlog("обновление: подпись бандла не цела");
            return -5;
        }

        NSString *old = [bundle stringByAppendingFormat:@".old-%d", getpid()];
        NSError *err = nil;
        if (![fm moveItemAtPath:bundle toPath:old error:&err]) {
            rlog("обновление: не убрать старую версию: %s", err.localizedDescription.UTF8String);
            return -6;
        }
        if (![fm moveItemAtPath:fresh toPath:bundle error:&err]) {
            [fm moveItemAtPath:old toPath:bundle error:nil];
            rlog("обновление: не поставить новую версию: %s", err.localizedDescription.UTF8String);
            return -7;
        }

        // Новая версия стартует через секунду, когда этот процесс уже вышел и освободил порт.
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-c", @"sleep 1; exec /usr/bin/open -n \"$0\" --args \"$@\"", bundle, nil];
        NSArray<NSString *> *mine = NSProcessInfo.processInfo.arguments;
        for (NSUInteger i = 1; i < mine.count; i++)
            if (![mine[i] hasPrefix:@"-psn_"]) [args addObject:mine[i]];
        NSTask *relaunch = [NSTask new];
        relaunch.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
        relaunch.arguments = args;
        if (![relaunch launchAndReturnError:&err]) rlog("обновление: не перезапустить: %s", err.localizedDescription.UTF8String);
        rlog("обновление %s установлено, перезапуск", version);
        exit(0);
    }
}

int rdc_mac_pref_bool(const char *key, int def) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *k = [NSString stringWithUTF8String:key];
    return [d objectForKey:k] ? ([d boolForKey:k] ? 1 : 0) : def;
}

void rdc_mac_set_pref_bool(const char *key, int value) {
    [NSUserDefaults.standardUserDefaults setBool:value != 0 forKey:[NSString stringWithUTF8String:key]];
}

int rdc_mac_computer_name(char *buf, int buflen) {
    NSString *name = [NSHost currentHost].localizedName ?: NSProcessInfo.processInfo.hostName;
    if (!name) return -1;
    return [name getCString:buf maxLength:(NSUInteger)buflen encoding:NSUTF8StringEncoding] ? 0 : -1;
}

// ---------------------------------------------------------------------------
// Окно приложения

@interface RDCAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *codeLabel;
@property(nonatomic, strong) NSTextField *linkLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *permLabel;
@property(nonatomic, strong) NSButton *screenButton;
@property(nonatomic, strong) NSButton *inputButton;
@property(nonatomic, strong) NSButton *settingsButton;
@property(nonatomic, copy) NSString *link;
@property(nonatomic, strong) NSWindow *settingsWindow;
@property(nonatomic, strong) NSTextField *setVersion;
@property(nonatomic, strong) NSButton *setAuto;
@property(nonatomic, strong) NSTextField *setStatus;
@property(nonatomic, strong) NSButton *setCheck;
@property(nonatomic, strong) NSButton *setInstall;
- (void)refreshSettings;
@end

// Состояние окна «Настройки» (пишется из любого потока, рисуется на главном).
static NSString *g_set_version = @"";
static NSString *g_set_status = @"";
static int g_set_auto = 1, g_set_can_install = 0, g_set_busy = 0;

static rdc_ctx_cb g_on_ready;
static rdc_action_cb g_on_action;
static void *g_app_ctx;
static RDCAppDelegate *g_app;

static NSTextField *make_label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.alignment = NSTextAlignmentCenter;
    return l;
}

@implementation RDCAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    NSMenuItem *prefs = [appMenu addItemWithTitle:@"Настройки…" action:@selector(showSettings:) keyEquivalent:@","];
    prefs.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Скрыть RDC" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Выйти из RDC" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = bar;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 360)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"RDC";

    NSTextField *caption = make_label(@"Код для подключения", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.codeLabel = make_label(@"— — —", 40, NSFontWeightSemibold, NSColor.labelColor);
    self.codeLabel.font = [NSFont monospacedDigitSystemFontOfSize:40 weight:NSFontWeightSemibold];
    self.codeLabel.selectable = YES;
    NSTextField *linkCaption = make_label(@"Ссылка для браузера", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.linkLabel = make_label(@"", 14, NSFontWeightRegular, NSColor.linkColor);
    self.linkLabel.selectable = YES;
    self.linkLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    NSButton *copy = [NSButton buttonWithTitle:@"Скопировать ссылку" target:self action:@selector(copyLink:)];
    NSButton *open = [NSButton buttonWithTitle:@"Открыть в браузере" target:self action:@selector(openLink:)];
    NSStackView *linkButtons = [NSStackView stackViewWithViews:@[ copy, open ]];
    linkButtons.spacing = 8;

    self.statusLabel = make_label(@"Запуск…", 13, NSFontWeightMedium, NSColor.labelColor);
    self.permLabel = make_label(@"", 12, NSFontWeightRegular, NSColor.systemOrangeColor);
    self.permLabel.hidden = YES;
    self.screenButton = [NSButton buttonWithTitle:@"Разрешить запись экрана" target:self action:@selector(askScreen:)];
    self.inputButton = [NSButton buttonWithTitle:@"Разрешить управление" target:self action:@selector(askInput:)];
    self.screenButton.hidden = YES;
    self.inputButton.hidden = YES;
    NSStackView *permButtons = [NSStackView stackViewWithViews:@[ self.screenButton, self.inputButton ]];
    permButtons.spacing = 8;

    NSButton *kick = [NSButton buttonWithTitle:@"Отключить всех" target:self action:@selector(disconnectAll:)];
    NSButton *renew = [NSButton buttonWithTitle:@"Новый код" target:self action:@selector(newCode:)];
    self.settingsButton = [NSButton buttonWithTitle:@"Настройки…" target:self action:@selector(showSettings:)];
    NSStackView *sessionButtons = [NSStackView stackViewWithViews:@[ renew, kick, self.settingsButton ]];
    sessionButtons.spacing = 8;

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        caption, self.codeLabel, linkCaption, self.linkLabel, linkButtons, self.statusLabel, self.permLabel, permButtons,
        sessionButtons
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(24, 24, 24, 24);
    [stack setCustomSpacing:2 afterView:caption];
    [stack setCustomSpacing:18 afterView:self.codeLabel];
    [stack setCustomSpacing:2 afterView:linkCaption];
    [stack setCustomSpacing:18 afterView:linkButtons];
    [self.linkLabel.widthAnchor constraintLessThanOrEqualToConstant:390].active = YES;
    self.window.contentView = stack;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (g_on_ready) g_on_ready(g_app_ctx);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    return YES;
}

- (void)copyLink:(id)sender {
    if (!self.link) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.link forType:NSPasteboardTypeString];
}

- (void)openLink:(id)sender {
    if (self.link) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:self.link]];
}

- (void)askScreen:(id)sender {
    if (!rdc_mac_screen_access(1)) rdc_mac_open_privacy(0);
}

- (void)askInput:(id)sender {
    if (!rdc_mac_input_access(1)) rdc_mac_open_privacy(1);
}

- (void)disconnectAll:(id)sender {
    if (g_on_action) g_on_action(g_app_ctx, RDC_ACTION_DISCONNECT_ALL);
}

- (void)newCode:(id)sender {
    if (g_on_action) g_on_action(g_app_ctx, RDC_ACTION_NEW_CODE);
}

- (void)showSettings:(id)sender {
    if (!self.settingsWindow) {
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 230)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.title = @"Настройки RDC";
        w.releasedWhenClosed = NO;
        self.setVersion = make_label(@"", 15, NSFontWeightSemibold, NSColor.labelColor);
        self.setAuto = [NSButton checkboxWithTitle:@"Обновлять автоматически" target:self action:@selector(toggleAuto:)];
        NSTextField *hint = make_label(@"Новые версии скачиваются из релизов GitHub (ANODs/RDC), проверяются подписью\n"
                                       @"и ставятся, когда к компьютеру никто не подключён.",
                                       11, NSFontWeightRegular, NSColor.secondaryLabelColor);
        hint.maximumNumberOfLines = 3;
        self.setStatus = make_label(@"", 13, NSFontWeightRegular, NSColor.labelColor);
        self.setStatus.maximumNumberOfLines = 3;
        self.setCheck = [NSButton buttonWithTitle:@"Проверить обновления" target:self action:@selector(checkUpdate:)];
        self.setInstall = [NSButton buttonWithTitle:@"Обновить и перезапустить" target:self action:@selector(installUpdate:)];
        self.setInstall.keyEquivalent = @"\r";
        NSStackView *buttons = [NSStackView stackViewWithViews:@[ self.setCheck, self.setInstall ]];
        buttons.spacing = 8;
        NSStackView *stack = [NSStackView stackViewWithViews:@[ self.setVersion, self.setAuto, hint, self.setStatus, buttons ]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeCenterX;
        stack.spacing = 12;
        stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
        [hint.widthAnchor constraintLessThanOrEqualToConstant:400].active = YES;
        [self.setStatus.widthAnchor constraintLessThanOrEqualToConstant:400].active = YES;
        w.contentView = stack;
        [w center];
        self.settingsWindow = w;
    }
    [self refreshSettings];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshSettings {
    NSString *version = g_set_version.length ? g_set_version : @"—";
    self.settingsButton.title = g_set_can_install ? @"Есть обновление…" : @"Настройки…";
    if (!self.settingsWindow) return;
    self.setVersion.stringValue = [NSString stringWithFormat:@"RDC %@", version];
    self.setAuto.state = g_set_auto ? NSControlStateValueOn : NSControlStateValueOff;
    self.setStatus.stringValue = g_set_status;
    self.setCheck.enabled = !g_set_busy;
    self.setInstall.hidden = !g_set_can_install;
    self.setInstall.enabled = g_set_can_install && !g_set_busy;
}

- (void)toggleAuto:(NSButton *)sender {
    if (g_on_action) g_on_action(g_app_ctx, sender.state == NSControlStateValueOn ? RDC_ACTION_AUTO_UPDATE_ON : RDC_ACTION_AUTO_UPDATE_OFF);
}

- (void)checkUpdate:(id)sender {
    if (g_on_action) g_on_action(g_app_ctx, RDC_ACTION_CHECK_UPDATE);
}

- (void)installUpdate:(id)sender {
    if (g_on_action) g_on_action(g_app_ctx, RDC_ACTION_INSTALL_UPDATE);
}
@end

void rdc_mac_settings_update(const char *version, int auto_update, const char *status, int can_install, int busy) {
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

void rdc_mac_app_run(rdc_ctx_cb on_ready, rdc_action_cb on_action, void *ctx) {
    @autoreleasepool {
        g_on_ready = on_ready;
        g_on_action = on_action;
        g_app_ctx = ctx;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        g_app = [RDCAppDelegate new];
        NSApp.delegate = g_app;
        [NSApp run];
    }
}

void rdc_mac_app_set_info(const char *code, const char *link) {
    NSString *c = [NSString stringWithUTF8String:code];
    NSString *l = [NSString stringWithUTF8String:link];
    dispatch_async(dispatch_get_main_queue(), ^{
        g_app.codeLabel.stringValue = c;
        g_app.linkLabel.stringValue = l;
        g_app.link = l;
    });
}

void rdc_mac_app_set_status(const char *text) {
    NSString *t = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{ g_app.statusLabel.stringValue = t; });
}

void rdc_mac_app_set_permissions(int screen_ok, int input_ok) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *missing = [NSMutableArray array];
        if (!screen_ok) [missing addObject:@"«Запись экрана» — без неё зрители не видят экран"];
        if (!input_ok) [missing addObject:@"«Универсальный доступ» — без него нет управления"];
        g_app.permLabel.stringValue = [missing componentsJoinedByString:@"\n"];
        g_app.permLabel.hidden = missing.count == 0;
        g_app.screenButton.hidden = screen_ok != 0;
        g_app.inputButton.hidden = input_ok != 0;
    });
}
