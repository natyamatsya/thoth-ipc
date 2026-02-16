// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// C FFI wrapper implementation — delegates to the C++ proto types.

#include "rt_audio_ffi.h"
#include "rt_audio_common.h"
#include "libipc/proto/shm_ring.h"
#include "libipc/proto/service_registry.h"
#include "libipc/proto/rt_prio.h"

#include <cstring>

#ifdef _WIN32
#  include <process.h>
#else
#  include <unistd.h>
#endif

// --- Shared state ---

extern "C" rt_ffi_shared_state_handle rt_ffi_shared_state_open(const char *name) {
    auto *h = new shared_state_handle();
    if (!h->open_or_create(name)) {
        delete h;
        return nullptr;
    }
    return h;
}

extern "C" void rt_ffi_shared_state_close(rt_ffi_shared_state_handle h) {
    delete static_cast<shared_state_handle *>(h);
}

extern "C" uint32_t rt_ffi_state_sample_rate(rt_ffi_shared_state_handle h) {
    return static_cast<shared_state_handle *>(h)->get()->sample_rate.load(std::memory_order_relaxed);
}

extern "C" uint32_t rt_ffi_state_channels(rt_ffi_shared_state_handle h) {
    return static_cast<shared_state_handle *>(h)->get()->channels.load(std::memory_order_relaxed);
}

extern "C" uint32_t rt_ffi_state_frames_per_buffer(rt_ffi_shared_state_handle h) {
    return static_cast<shared_state_handle *>(h)->get()->frames_per_buffer.load(std::memory_order_relaxed);
}

extern "C" bool rt_ffi_state_stream_active(rt_ffi_shared_state_handle h) {
    return static_cast<shared_state_handle *>(h)->get()->stream_active.load(std::memory_order_acquire);
}

extern "C" float rt_ffi_state_gain(rt_ffi_shared_state_handle h) {
    return static_cast<shared_state_handle *>(h)->get()->gain.load(std::memory_order_relaxed);
}

extern "C" float rt_ffi_state_pan(rt_ffi_shared_state_handle h) {
    return static_cast<shared_state_handle *>(h)->get()->pan.load(std::memory_order_relaxed);
}

extern "C" void rt_ffi_state_add_blocks_produced(rt_ffi_shared_state_handle h, uint64_t n) {
    static_cast<shared_state_handle *>(h)->get()->blocks_produced.fetch_add(n, std::memory_order_relaxed);
}

extern "C" void rt_ffi_state_touch_heartbeat(rt_ffi_shared_state_handle h) {
    static_cast<shared_state_handle *>(h)->get()->touch_heartbeat();
}

// --- Ring buffer ---

using ring_type = ipc::proto::shm_ring<audio_block, 4>;

extern "C" rt_ffi_ring_handle rt_ffi_ring_open(const char *name) {
    auto *r = new ring_type(name);
    if (!r->open_or_create()) {
        delete r;
        return nullptr;
    }
    return r;
}

extern "C" void rt_ffi_ring_close(rt_ffi_ring_handle h) {
    delete static_cast<ring_type *>(h);
}

extern "C" void rt_ffi_ring_write_overwrite(rt_ffi_ring_handle h, const rt_ffi_audio_block *blk) {
    static_assert(sizeof(rt_ffi_audio_block) == sizeof(audio_block),
                  "FFI audio_block size mismatch");
    static_assert(offsetof(rt_ffi_audio_block, samples) == offsetof(audio_block, samples),
                  "FFI audio_block samples offset mismatch");
    audio_block cpp_blk;
    std::memcpy(&cpp_blk, blk, sizeof(audio_block));
    static_cast<ring_type *>(h)->write_overwrite(cpp_blk);
}

// --- Service registry ---

extern "C" rt_ffi_registry_handle rt_ffi_registry_open(const char *domain) {
    return new ipc::proto::service_registry(domain);
}

extern "C" void rt_ffi_registry_close(rt_ffi_registry_handle h) {
    delete static_cast<ipc::proto::service_registry *>(h);
}

extern "C" bool rt_ffi_registry_register(rt_ffi_registry_handle h,
                                         const char *name,
                                         const char *ctrl,
                                         const char *reply) {
    return static_cast<ipc::proto::service_registry *>(h)->register_service(name, ctrl, reply);
}

extern "C" bool rt_ffi_registry_unregister(rt_ffi_registry_handle h, const char *name) {
    return static_cast<ipc::proto::service_registry *>(h)->unregister_service(name);
}

// --- Real-time priority ---

extern "C" bool rt_ffi_set_realtime_priority(uint64_t period_ns) {
    return ipc::proto::set_realtime_priority(period_ns);
}

extern "C" uint64_t rt_ffi_audio_period_ns(uint32_t sample_rate, uint32_t frames_per_buffer) {
    return ipc::proto::audio_period_ns(sample_rate, frames_per_buffer);
}

// --- Utility ---

extern "C" int rt_ffi_getpid(void) {
#ifdef _WIN32
    return _getpid();
#else
    return ::getpid();
#endif
}
