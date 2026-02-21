// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/proto/rt_prio.h.
// Real-time thread priority — macOS Mach time constraint policy.

import Darwin.POSIX
import LibIPCShim

// MARK: - audio_period_ns

/// Compute the audio period in nanoseconds from sample rate and buffer size.
public func audioPeriodNs(sampleRate: UInt32, framesPerBuffer: UInt32) -> UInt64 {
    UInt64(framesPerBuffer) * 1_000_000_000 / UInt64(sampleRate)
}

// MARK: - setRealtimePriority

/// Set real-time thread priority for the calling thread.
///
/// - Parameters:
///   - periodNs: Nominal period between callbacks (e.g. `audioPeriodNs(sampleRate:framesPerBuffer:)`).
///   - computationNs: Max computation time per period (default: `periodNs / 2`).
///   - constraintNs: Hard deadline (default: `periodNs`).
/// - Returns: `true` on success.
@discardableResult
public func setRealtimePriority(
    periodNs: UInt64,
    computationNs: UInt64? = nil,
    constraintNs: UInt64? = nil
) -> Bool {
    let comp = computationNs ?? (periodNs / 2)
    let constr = constraintNs ?? periodNs
    return setRealtimeMacOS(periodNs: periodNs, computationNs: comp, constraintNs: constr)
}

// MARK: - macOS Mach thread time constraint policy

private func setRealtimeMacOS(periodNs: UInt64, computationNs: UInt64, constraintNs: UInt64) -> Bool {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    guard tb.numer != 0 && tb.denom != 0 else { return false }

    let toAbs: (UInt64) -> UInt32 = { ns in
        UInt32(clamping: ns * UInt64(tb.denom) / UInt64(tb.numer))
    }

    var policy = thread_time_constraint_policy_data_t(
        period:      toAbs(periodNs),
        computation: toAbs(computationNs),
        constraint:  toAbs(constraintNs),
        preemptible: 1
    )

    let machThread = pthread_mach_thread_np(pthread_self())
    let kr = withUnsafeMutablePointer(to: &policy) {
        $0.withMemoryRebound(to: integer_t.self, capacity: MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size) { ptr in
            thread_policy_set(
                machThread,
                thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                ptr,
                mach_msg_type_number_t(libipc_thread_time_constraint_policy_count())
            )
        }
    }
    return kr == KERN_SUCCESS
}
