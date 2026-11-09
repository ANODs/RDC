// The writer's side of mic_shm.h: RDC.app (shim.m) and the test harness (mic_test.c) create the
// shared-memory segment and push 48 kHz 16-bit mono samples into it for RDCMicrophone.driver.
// Plain C, static inline, so both get the same code. Not thread-safe by itself: shim.m holds a
// mutex around these calls.
#pragma once
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "mic_shm.h"

typedef struct {
    void *shm;  // the mapped segment, or NULL
} rdc_mic_writer;

// Creates or opens the segment and makes sure its header is ours. 0 — ok; -1 — failed, with the
// reason in err. The segment stays until reboot: a plug-in that mapped it earlier keeps seeing it.
static inline int rdc_mic_writer_open(rdc_mic_writer *w, char *err, size_t errlen) {
    if (w->shm) return 0;
    for (int attempt = 0; attempt < 2; attempt++) {
        // 0644 regardless of the umask: coreaudiod runs as another user and only reads.
        mode_t old = umask(0);
        int fd = shm_open(RDC_MIC_SHM_NAME, O_CREAT | O_RDWR, 0644);
        umask(old);
        if (fd < 0) {
            snprintf(err, errlen, "shm_open: %s", strerror(errno));
            return -1;
        }
        struct stat st;
        if (fstat(fd, &st) != 0) {
            snprintf(err, errlen, "fstat: %s", strerror(errno));
            close(fd);
            return -1;
        }
        if (st.st_size == 0 && ftruncate(fd, RDC_MIC_SHM_SIZE) != 0) {
            snprintf(err, errlen, "ftruncate: %s", strerror(errno));
            close(fd);
            return -1;
        }
        if (st.st_size != 0 && st.st_size < (off_t)RDC_MIC_SHM_SIZE) {
            // A segment of another layout: start over once.
            close(fd);
            shm_unlink(RDC_MIC_SHM_NAME);
            continue;
        }
        void *p = mmap(NULL, RDC_MIC_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) {
            snprintf(err, errlen, "mmap: %s", strerror(errno));
            return -1;
        }
        rdc_mic_header *h = (rdc_mic_header *)p;
        if (h->magic != RDC_MIC_MAGIC || h->version != RDC_MIC_VERSION || h->sample_rate != RDC_MIC_RATE ||
            h->ring_frames != RDC_MIC_RING_FRAMES) {
            // Fresh (zero-filled) or of an older layout: write the header, the magic last.
            h->version = RDC_MIC_VERSION;
            h->sample_rate = RDC_MIC_RATE;
            h->ring_frames = RDC_MIC_RING_FRAMES;
            atomic_store_explicit(&h->generation, 0, memory_order_relaxed);
            atomic_store_explicit(&h->write_pos, 0, memory_order_relaxed);
            atomic_store_explicit(&h->heartbeat_us, 0, memory_order_relaxed);
            atomic_store_explicit(&h->live, 0, memory_order_relaxed);
            atomic_thread_fence(memory_order_release);
            h->magic = RDC_MIC_MAGIC;
        }
        w->shm = p;
        return 0;
    }
    snprintf(err, errlen, "the segment keeps the wrong size");
    return -1;
}

// A viewer's microphone starts: the plug-in drops whatever it had and waits for a fresh cushion.
static inline void rdc_mic_writer_start(rdc_mic_writer *w) {
    if (!w->shm) return;
    rdc_mic_header *h = (rdc_mic_header *)w->shm;
    atomic_fetch_add_explicit(&h->generation, 1, memory_order_release);
    atomic_store_explicit(&h->live, 1, memory_order_relaxed);
}

static inline void rdc_mic_writer_push(rdc_mic_writer *w, const int16_t *pcm, uint32_t frames, uint64_t now_us) {
    if (!w->shm || frames == 0) return;
    rdc_mic_header *h = (rdc_mic_header *)w->shm;
    int16_t *ring = rdc_mic_samples(w->shm);
    uint64_t pos = atomic_load_explicit(&h->write_pos, memory_order_relaxed);
    if (frames > RDC_MIC_RING_FRAMES) {  // keep the newest ring's worth
        pcm += frames - RDC_MIC_RING_FRAMES;
        frames = RDC_MIC_RING_FRAMES;
    }
    for (uint32_t i = 0; i < frames; i++) ring[(pos + i) & (RDC_MIC_RING_FRAMES - 1)] = pcm[i];
    atomic_store_explicit(&h->heartbeat_us, now_us, memory_order_relaxed);
    atomic_store_explicit(&h->write_pos, pos + frames, memory_order_release);
}

static inline void rdc_mic_writer_stop(rdc_mic_writer *w) {
    if (!w->shm) return;
    atomic_store_explicit(&((rdc_mic_header *)w->shm)->live, 0, memory_order_relaxed);
}

static inline void rdc_mic_writer_close(rdc_mic_writer *w) {
    if (w->shm) munmap(w->shm, RDC_MIC_SHM_SIZE);
    w->shm = NULL;
}
