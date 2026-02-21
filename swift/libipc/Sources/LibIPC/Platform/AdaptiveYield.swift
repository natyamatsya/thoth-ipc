// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Adaptive backoff — mirrors C++ `ipc::yield(k)` and Rust `adaptive_yield`.
//
// k < 4:   busy spin (no-op)
// k < 16:  CPU pause hint
// k < 32:  cooperative task yield
// k >= 32: sleep 1 ms

import Darwin.POSIX

/// Synchronous adaptive backoff — for use in non-async spin loops.
/// k < 4:  busy spin; k < 16: pause hint; k >= 16: sched_yield()
@inline(__always)
func adaptiveYieldSync(_ k: inout UInt32) {
    if k < 4 {
        // busy spin
    } else if k < 16 {
        for _ in 0..<1 { }
    } else {
        sched_yield()
    }
    k &+= 1
}

/// Adaptive backoff for spin loops.
/// Call in a loop, passing the same `k` each iteration.
@inline(__always)
func adaptiveYield(_ k: inout UInt32) async {
    if k < 4 {
        // busy spin — no suspension
    } else if k < 16 {
        // CPU pause hint — no suspension
        for _ in 0..<1 { }  // prevents the compiler from optimising the loop away
    } else if k < 32 {
        await Task.yield()
        return
    } else {
        try? await Task.sleep(for: .milliseconds(1))
        return
    }
    k &+= 1
}
