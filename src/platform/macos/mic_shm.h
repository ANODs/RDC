// The shared-memory ring between RDC.app (the writer) and RDCMicrophone.driver, the HAL plug-in
// that runs inside coreaudiod (the reader). RDC.app creates /com.anods.rdc.mic with mode 0644; the
// plug-in only reads it — coreaudiod's sandbox allows POSIX shared memory, and nothing else is
// needed: no Mach service, socket or file. Positions are monotonic frame counts; a frame's slot is
// its position modulo RDC_MIC_RING_FRAMES. The writer stores samples, then write_pos with release
// order; the reader loads write_pos with acquire order and copies samples up to it.
#pragma once
#include <stdatomic.h>
#include <stdint.h>

#define RDC_MIC_SHM_NAME "/com.anods.rdc.mic"
#define RDC_MIC_MAGIC 0x4D434452u  // "RDCM"
#define RDC_MIC_VERSION 1u
#define RDC_MIC_RATE 48000
#define RDC_MIC_RING_FRAMES 65536  // 1.37 s of 16-bit mono
#define RDC_MIC_HEADER_SIZE 4096
#define RDC_MIC_SHM_SIZE (RDC_MIC_HEADER_SIZE + RDC_MIC_RING_FRAMES * 2)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t sample_rate;
    uint32_t ring_frames;
    _Atomic uint64_t generation;    // bumped when a viewer's microphone starts: the reader restarts from write_pos
    _Atomic uint64_t write_pos;     // frames written so far; samples before it are complete
    _Atomic uint64_t heartbeat_us;  // the writer's monotonic clock at the last push
    _Atomic uint32_t live;          // 1 while a viewer's microphone is on
} rdc_mic_header;

static inline int16_t *rdc_mic_samples(void *shm) { return (int16_t *)((uint8_t *)shm + RDC_MIC_HEADER_SIZE); }
