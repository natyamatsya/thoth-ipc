// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cstdint>
#include <cstdio>

#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <mach/thread_act.h>
#include <pthread.h>
#endif

namespace ipc {
namespace proto {

// Set real-time thread priority for the calling thread.
//
// period_ns:      nominal period between callbacks (e.g. 5333333 for 256 frames at 48kHz)
// computation_ns: max computation time per period (typically period/2)
// constraint_ns:  hard deadline (typically == period)
//
// Returns true on success.
inline bool set_realtime_priority(uint64_t period_ns,
                                  uint64_t computation_ns = 0,
                                  uint64_t constraint_ns  = 0) {
    if (computation_ns == 0) computation_ns = period_ns / 2;
    if (constraint_ns  == 0) constraint_ns  = period_ns;

#ifdef __APPLE__
    // Convert nanoseconds to Mach absolute time units.
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    auto to_abs = [&](uint64_t ns) -> uint32_t {
        return static_cast<uint32_t>(ns * tb.denom / tb.numer);
    };

    thread_time_constraint_policy_data_t policy;
    policy.period      = to_abs(period_ns);
    policy.computation = to_abs(computation_ns);
    policy.constraint  = to_abs(constraint_ns);
    policy.preemptible = true;

    kern_return_t kr = thread_policy_set(
        pthread_mach_thread_np(pthread_self()),
        THREAD_TIME_CONSTRAINT_POLICY,
        reinterpret_cast<thread_policy_t>(&policy),
        THREAD_TIME_CONSTRAINT_POLICY_COUNT);

    if (kr != KERN_SUCCESS) {
        std::fprintf(stderr, "rt_prio: thread_policy_set failed (%d)\n", kr);
        return false;
    }
    return true;
#else
    // Linux: use SCHED_FIFO (requires CAP_SYS_NICE or root)
    (void)period_ns; (void)computation_ns; (void)constraint_ns;
    std::fprintf(stderr, "rt_prio: not implemented on this platform\n");
    return false;
#endif
}

// Convenience: compute period in nanoseconds from sample rate and buffer size.
inline uint64_t audio_period_ns(uint32_t sample_rate, uint32_t frames_per_buffer) {
    return static_cast<uint64_t>(frames_per_buffer) * 1'000'000'000ULL / sample_rate;
}

} // namespace proto
} // namespace ipc
