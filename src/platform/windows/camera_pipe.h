// Shared by RDC.exe (shim.c) and rdc-camera.dll (camera.c): how the camera's media source gets
// its frames. RDC.exe serves the named pipe; each media source instance connects, says which
// size the app chose, and receives NV12 frames as the phone sends them. Byte-stream pipe, little
// endian, no padding in the structs.
#pragma once
#include <stdint.h>

#define RDC_CAMERA_PIPE L"\\\\.\\pipe\\rdc-camera"
#define RDC_CAMERA_CLSID_STR L"{726462D9-EE2A-4056-B130-8DE9AEA68CE7}"
#define RDC_CAMERA_DLL_NAME L"rdc-camera.dll"
#define RDC_CAMERA_FRIENDLY_NAME L"RDC Camera"
#define RDC_CAMERA_WANT 0x57434452u   // "RDCW"
#define RDC_CAMERA_FRAME 0x46434452u  // "RDCF"

// Media source → RDC.exe, once per connection: the format the app picked.
typedef struct {
    uint32_t magic;  // RDC_CAMERA_WANT
    uint32_t width, height, fps;
} rdc_camera_want;

// RDC.exe → media source: a frame header, then `size` bytes of NV12 (width × height × 3 / 2).
// size 0 — the phone's camera is off: show the dark frame.
typedef struct {
    uint32_t magic;  // RDC_CAMERA_FRAME
    uint32_t width, height, size;
} rdc_camera_frame;
