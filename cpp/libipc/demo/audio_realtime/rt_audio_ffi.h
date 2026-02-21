// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// C FFI wrapper for the rt_audio proto types.
// Allows non-C++ languages (Rust, etc.) to use the same IPC primitives.

#ifndef RT_AUDIO_FFI_H
#define RT_AUDIO_FFI_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Audio block (matches C++ audio_block layout exactly) ---

#define RT_FFI_MAX_FRAMES   1024
#define RT_FFI_MAX_CHANNELS 2

// Must match the C++ audio_block struct layout (repr(C) compatible).
// The C++ struct has alignas(16) on samples[], which inserts 8 bytes
// of implicit padding after pad_.  We replicate this with _align_pad.
typedef struct {
    uint64_t sequence;
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t frames;
    uint32_t pad_;
    uint32_t _align_pad[2];  // explicit padding for alignas(16) on samples
    float    samples[RT_FFI_MAX_FRAMES * RT_FFI_MAX_CHANNELS];
} rt_ffi_audio_block;

// --- Shared state ---

typedef void* rt_ffi_shared_state_handle;

rt_ffi_shared_state_handle rt_ffi_shared_state_open(const char *name);
void                       rt_ffi_shared_state_close(rt_ffi_shared_state_handle h);

// Atomic reads from shared state
uint32_t rt_ffi_state_sample_rate(rt_ffi_shared_state_handle h);
uint32_t rt_ffi_state_channels(rt_ffi_shared_state_handle h);
uint32_t rt_ffi_state_frames_per_buffer(rt_ffi_shared_state_handle h);
bool     rt_ffi_state_stream_active(rt_ffi_shared_state_handle h);
float    rt_ffi_state_gain(rt_ffi_shared_state_handle h);
float    rt_ffi_state_pan(rt_ffi_shared_state_handle h);

// Atomic writes
void     rt_ffi_state_add_blocks_produced(rt_ffi_shared_state_handle h, uint64_t n);
void     rt_ffi_state_touch_heartbeat(rt_ffi_shared_state_handle h);

// --- Ring buffer ---

typedef void* rt_ffi_ring_handle;

rt_ffi_ring_handle rt_ffi_ring_open(const char *name);
void               rt_ffi_ring_close(rt_ffi_ring_handle h);
void               rt_ffi_ring_write_overwrite(rt_ffi_ring_handle h, const rt_ffi_audio_block *blk);

// --- Service registry ---

typedef void* rt_ffi_registry_handle;

rt_ffi_registry_handle rt_ffi_registry_open(const char *domain);
void                   rt_ffi_registry_close(rt_ffi_registry_handle h);
bool                   rt_ffi_registry_register(rt_ffi_registry_handle h,
                                                const char *name,
                                                const char *ctrl,
                                                const char *reply);
bool                   rt_ffi_registry_unregister(rt_ffi_registry_handle h,
                                                  const char *name);

// --- Real-time priority ---

bool     rt_ffi_set_realtime_priority(uint64_t period_ns);
uint64_t rt_ffi_audio_period_ns(uint32_t sample_rate, uint32_t frames_per_buffer);

// --- Utility ---

int      rt_ffi_getpid(void);

#ifdef __cplusplus
}
#endif

#endif // RT_AUDIO_FFI_H
